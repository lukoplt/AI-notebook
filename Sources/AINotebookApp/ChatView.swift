// Sources/AINotebookApp/ChatView.swift
import SwiftUI
import AINotebookCore

struct ChatView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder

    @State private var sessions: [ChatSession] = []
    @State private var selectedSessionId: Int64?
    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streamingDraft: String = ""
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var popoverCitation: Citation?
    @State private var popoverSourceTitle: String = ""

    private var t: AppText { settings.text }

    var body: some View {
        HSplitView {
            sessionsSidebar
            chatSurface
        }
        .task(id: notebook.id) { await ensureSessions() }
        .popover(item: $popoverCitation) { c in
            CitationPopover(citation: c, sourceTitle: popoverSourceTitle)
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
                Task { await reloadMessages() }
            }
        }
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
    }

    private var chatSurface: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            inputBar
        }
        .padding(16)
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
                            onCitationTapped: { c in showCitation(c) }
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
                            onCitationTapped: { _ in }
                        )
                    }
                    if let errorMessage {
                        Text(t.string(.chatErrorPrefix) + errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
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

    private func send() async {
        guard let sid = selectedSessionId else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        sending = true
        errorMessage = nil
        streamingDraft = ""
        defer { sending = false; streamingDraft = "" }
        do {
            _ = try await chatHolder.engine.send(
                sessionId: sid,
                notebookId: notebook.id!,
                userText: text
            ) { token in
                Task { @MainActor in streamingDraft += token }
            }
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
            await reloadMessages()
        }
    }

    private func showCitation(_ c: Citation) {
        Task { @MainActor in
            let source = (try? store.source(id: c.sourceId))?.title ?? ""
            popoverSourceTitle = source
            popoverCitation = c
        }
    }
}

// SwiftUI `.popover(item:)` requires Identifiable.
extension Citation: Identifiable {
    public var id: Int { marker * 1_000_000 + Int(chunkId % 999_999) }
}
