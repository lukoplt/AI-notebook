// Sources/AINotebookApp/ChatView.swift
import SwiftUI
import AINotebookCore

struct ChatView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder
    @EnvironmentObject private var ollama: OllamaClientHolder
    @EnvironmentObject private var routerHolder: ProviderRouterHolder

    @State private var sessions: [ChatSession] = []
    @State private var selectedSessionId: Int64?
    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streamingDraft: String = ""
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var popoverCitation: Citation?
    @State private var popoverSourceTitle: String = ""
    @State private var popoverPageHint: Int?
    @State private var popoverPDFURL: URL?
    @State private var popoverNoteId: Int64?
    @State private var followups: [String] = []
    @State private var scopeSources: [Source] = []
    @State private var selectedSourceIds: Set<Int64> = []
    @State private var showingScopePopover = false

    private var t: AppText { settings.text }

    /// Lazily built from the same chat model + Ollama client the app uses for
    /// `ChatEngine`. Cheap actor — fine to construct per call.
    private func makeFollowupSuggester() -> FollowupSuggester {
        FollowupSuggester(chat: routerHolder.router, chatModel: settings.selectedChatModel)
    }

    /// Source ids to scope retrieval to. Empty when nothing is narrowed (i.e.
    /// every available source is selected) — preserving the default "all" path.
    private var effectiveSourceIds: Set<Int64> {
        if scopeSources.isEmpty { return [] }
        if selectedSourceIds.count == scopeSources.count { return [] }
        return selectedSourceIds
    }

    var body: some View {
        HSplitView {
            sessionsSidebar
            chatSurface
        }
        .task(id: notebook.id) {
            await ensureSessions()
            await loadScopeSources()
        }
        .popover(item: $popoverCitation) { c in
            CitationPopover(
                citation: c,
                sourceTitle: popoverSourceTitle,
                pageHint: popoverPageHint,
                pdfFileURL: popoverPDFURL,
                noteIdToOpen: popoverNoteId
            )
        }
    }

    private var sessionsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.string(.chatSessionsLabel)).font(.title3).bold()
                Spacer()
                Button {
                    Task { await newSession() }
                } label: { Image(systemName: "plus") }
                    .help(t.string(.chatNewSessionButton))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            List(selection: $selectedSessionId) {
                ForEach(sessions) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline)
                        Text(s.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(s.id ?? -1)
                    .contextMenu {
                        Button(role: .destructive) {
                            if let id = s.id { Task { await deleteSession(id) } }
                        } label: { Text(t.string(.chatDeleteSessionButton)) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedSessionId) { _, _ in
                clearFollowups()
                Task { await reloadMessages() }
            }
        }
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
    }

    private var chatSurface: some View {
        VStack(spacing: 0) {
            scopeToolbar
            messagesList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inputBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scopeToolbar: some View {
        HStack {
            Spacer()
            Button {
                showingScopePopover = true
            } label: {
                Label(scopeButtonTitle, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(scopeSources.isEmpty)
            .popover(isPresented: $showingScopePopover, arrowEdge: .top) {
                scopePopover
            }
        }
        .padding(.bottom, 8)
    }

    private var scopeButtonTitle: String {
        if effectiveSourceIds.isEmpty {
            return t.string(.chatScopeAllSources)
        }
        return "\(t.string(.chatScopeButton)) (\(selectedSourceIds.count))"
    }

    private var scopePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.string(.chatScopeTitle)).font(.headline)
            Divider()
            ForEach(scopeSources) { source in
                Toggle(isOn: bindingForSource(source)) {
                    Text(source.title).lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 360)
    }

    private func bindingForSource(_ source: Source) -> Binding<Bool> {
        guard let sid = source.id else { return .constant(false) }
        return Binding(
            get: { selectedSourceIds.contains(sid) },
            set: { isOn in
                if isOn { selectedSourceIds.insert(sid) }
                else { selectedSourceIds.remove(sid) }
            }
        )
    }

    @ViewBuilder
    private var messagesList: some View {
        if messages.isEmpty && streamingDraft.isEmpty {
            VStack {
                Spacer()
                Text(t.string(.chatEmptyState))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { m in
                        MessageBubble(
                            message: m,
                            language: settings.language,
                            onCitationTapped: { c in showCitation(c) },
                            onSaveAsNote: { Task { await saveAsNote(m) } }
                        )
                    }
                    if !streamingDraft.isEmpty {
                        MessageBubble(
                            message: ChatMessage(
                                sessionId: selectedSessionId ?? 0,
                                role: .assistant,
                                content: streamingDraft
                            ),
                            language: settings.language,
                            onCitationTapped: { _ in },
                            onSaveAsNote: nil
                        )
                    }
                    if let errorMessage {
                        Text(t.string(.chatErrorPrefix) + errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !followups.isEmpty && streamingDraft.isEmpty {
                        followupChips
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var followupChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.string(.chatFollowupsLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(followups, id: \.self) { question in
                    Button {
                        Task { await sendFollowup(question) }
                    } label: {
                        Text(question)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(sending)
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(t.string(.chatInputPlaceholder), text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(sending)

            Button(t.string(.chatSendButton)) {
                Task { await send() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 8)
    }

    @MainActor
    private func ensureSessions() async {
        do {
            sessions = try store.chatSessions(notebookId: notebook.id!)
            if let first = sessions.first {
                selectedSessionId = first.id
            } else {
                let new = try store.createChatSession(
                    notebookId: notebook.id!,
                    title: t.string(.chatNewSessionTitle)
                )
                sessions = [new]
                selectedSessionId = new.id
            }
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @MainActor
    private func newSession() async {
        do {
            let s = try store.createChatSession(
                notebookId: notebook.id!,
                title: t.string(.chatNewSessionTitle)
            )
            sessions.insert(s, at: 0)
            selectedSessionId = s.id
            await reloadMessages()
        } catch { errorMessage = String(describing: error) }
    }

    @MainActor
    private func deleteSession(_ id: Int64) async {
        do {
            try store.deleteChatSession(id: id)
            sessions.removeAll { $0.id == id }
            selectedSessionId = sessions.first?.id
            await reloadMessages()
        } catch { errorMessage = String(describing: error) }
    }

    @MainActor
    private func reloadMessages() async {
        guard let sid = selectedSessionId else {
            messages = []
            return
        }
        do {
            messages = try store.messages(sessionId: sid)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func clearFollowups() { followups = [] }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        await send(text: text)
    }

    private func sendFollowup(_ question: String) async {
        guard !sending else { return }
        await send(text: question)
    }

    private func send(text: String) async {
        guard let sid = selectedSessionId else { return }
        sending = true
        errorMessage = nil
        streamingDraft = ""
        followups = []
        defer { sending = false; streamingDraft = "" }
        do {
            let reply = try await chatHolder.engine.send(
                sessionId: sid,
                notebookId: notebook.id!,
                userText: text,
                sourceIds: effectiveSourceIds
            ) { token in
                Task { @MainActor in streamingDraft += token }
            }
            await reloadMessages()
            await generateFollowups(userText: text, answer: reply.content)
        } catch {
            errorMessage = providerErrorText(error, text: settings.text)
            await reloadMessages()
        }
    }

    @MainActor
    private func generateFollowups(userText: String, answer: String) async {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let suggester = makeFollowupSuggester()
            let suggestions = try await suggester.generate(userText: userText, answer: answer)
            // Only show if the conversation hasn't moved on.
            if !sending { followups = suggestions }
        } catch {
            // Follow-ups are best-effort; never surface an error for them.
            followups = []
        }
    }

    @MainActor
    private func loadScopeSources() async {
        do {
            let ready = try store.sources(notebookId: notebook.id!)
                .filter { $0.status == .ready && $0.id != nil }
            scopeSources = ready
            // Default = all selected (which maps to the unscoped path).
            selectedSourceIds = Set(ready.compactMap { $0.id })
        } catch {
            scopeSources = []
            selectedSourceIds = []
        }
    }

    private func showCitation(_ c: Citation) {
        Task { @MainActor in
            let source = try? store.source(id: c.sourceId)
            let chunks = (try? store.chunks(sourceId: c.sourceId)) ?? []
            let hint = chunks.first(where: { $0.id == c.chunkId })?.pageHint
            let isPDF = (source?.type == .pdf)
            let url: URL? = (isPDF && (source?.rawPath != nil))
                ? URL(fileURLWithPath: source!.rawPath!)
                : nil
            var noteId: Int64? = nil
            if source?.type == .note, let s = source {
                let allNotes = (try? store.notes(notebookId: s.notebookId)) ?? []
                noteId = allNotes.first(where: { $0.autoSourceId == s.id })?.id
            }
            popoverSourceTitle = source?.title ?? ""
            popoverPageHint = hint
            popoverPDFURL = url
            popoverNoteId = noteId
            popoverCitation = c
        }
    }

    @MainActor
    private func saveAsNote(_ msg: ChatMessage) async {
        do {
            _ = try store.createNote(
                notebookId: notebook.id!,
                title: "Chat reply — \(msg.createdAt.formatted(date: .abbreviated, time: .shortened))",
                bodyMd: msg.content,
                origin: .chat,
                originRef: msg.id
            )
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

// SwiftUI `.popover(item:)` requires Identifiable.
extension Citation: Identifiable {
    public var id: Int { marker * 1_000_000 + Int(chunkId % 999_999) }
}
