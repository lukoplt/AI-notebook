import SwiftUI
import AINotebookCore

struct NotesChatPanel: View {
    let notebook: Notebook
    let currentNote: Note?

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder

    @State private var sessionId: Int64?
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

    private var t: AppText { settings.text }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .padding(12)
        .task(id: notebook.id) { await ensureSession() }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.string(.notesChatPanelTitle)).font(.headline)
            if currentNote != nil {
                Text(t.string(.notesChatCurrentNoteHint))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var messagesList: some View {
        if messages.isEmpty && streamingDraft.isEmpty {
            VStack {
                Spacer()
                Text(t.string(.notesChatPanelEmpty))
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
                                sessionId: sessionId ?? 0,
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
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
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
        .padding(.top, 6)
    }

    @MainActor
    private func ensureSession() async {
        do {
            let existing = try store.chatSessions(notebookId: notebook.id!)
            if let s = existing.first {
                sessionId = s.id
            } else {
                sessionId = try store.createChatSession(
                    notebookId: notebook.id!,
                    title: t.string(.chatNewSessionTitle)
                ).id
            }
            await reloadMessages()
        } catch { errorMessage = String(describing: error) }
    }

    @MainActor
    private func reloadMessages() async {
        guard let sid = sessionId else { return }
        do { messages = try store.messages(sessionId: sid) }
        catch { errorMessage = String(describing: error) }
    }

    private func send() async {
        guard let sid = sessionId else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        sending = true
        errorMessage = nil
        streamingDraft = ""
        defer { sending = false; streamingDraft = "" }
        let noteCtx = currentNote?.bodyMd
        do {
            _ = try await chatHolder.engine.send(
                sessionId: sid,
                notebookId: notebook.id!,
                userText: text,
                currentNoteContent: noteCtx
            ) { token in
                Task { @MainActor in streamingDraft += token }
            }
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
            await reloadMessages()
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
        } catch { errorMessage = String(describing: error) }
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
}
