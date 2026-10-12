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

    private var t: AppText { settings.text }

    var body: some View {
        VStack(spacing: 0) {
            if currentNote != nil {
                Label(t.string(.notesChatCurrentNoteHint), systemImage: DesignTokens.icon(.note))
                    .tokenFont(.caption)
                    .tokenForeground(.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.spacing(12))
                    .padding(.vertical, DesignTokens.spacing(8))
                Hairline()
            }
            messagesList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            inputBar
                .padding(DesignTokens.spacing(12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: notebook.id) { await ensureSession() }
        .popover(item: $popoverCitation) { c in
            // Same snapshot card and native resolver as the Citations panel; no rawPath launch.
            CitationCard(citation: c, notebookId: notebook.id!)
                .frame(width: DesignTokens.size(.panelMax))
                .padding(DesignTokens.spacing(8))
        }
    }

    @ViewBuilder
    private var messagesList: some View {
        if messages.isEmpty && streamingDraft.isEmpty && errorMessage == nil {
            PanelHint(icon: .chat, text: t.string(.notesChatPanelEmpty))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.spacing(16)) {
                    ForEach(messages) { m in
                        MessageRow(message: m, compact: true, actions: MessageRowActions(
                            onCite: { marker in
                                if let c = m.citations.first(where: { $0.marker == marker }) { showCitation(c) }
                            },
                            onSaveAsNote: m.role == .assistant ? { Task { await saveAsNote(m) } } : nil))
                    }
                    if !streamingDraft.isEmpty {
                        MessageRow(
                            message: ChatMessage(sessionId: sessionId ?? 0, role: .assistant, content: streamingDraft),
                            isStreaming: true, compact: true)
                    }
                    if let errorMessage {
                        ChatErrorRow(message: errorMessage, retryTitle: t.string(.chatRetry))
                    }
                }
                .padding(DesignTokens.spacing(12))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inputBar: some View {
        ComposerView(text: $input, placeholder: t.string(.notesChatPanelEmpty), isSending: sending,
                     onSubmit: { Task { await send() } }) {
            EmptyView()
        } trailing: {
            SendButton(isSending: sending,
                       isEnabled: !sending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       label: t.string(.chatSendButton)) {
                Task { await send() }
            }
        }
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
        guard let sid = sessionId, !sending else { return }
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
            if (error as? ContextPackError) == .contextTooSmall {
                // Preparation failed before any row was written: keep the draft.
                errorMessage = t.string(.contextTooSmall)
                if input.isEmpty { input = text }
            } else {
                errorMessage = providerErrorText(error, text: settings.text)
            }
            await reloadMessages()
        }
    }

    @MainActor
    private func saveAsNote(_ msg: ChatMessage) async {
        do {
            _ = try store.createNote(
                notebookId: notebook.id!,
                title: String(format: t.string(.chatReplyNoteTitle),
                              msg.createdAt.formatted(date: .abbreviated, time: .shortened)),
                bodyMd: msg.content,
                origin: .chat,
                originRef: msg.id
            )
        } catch { errorMessage = String(describing: error) }
    }

    private func showCitation(_ c: Citation) {
        popoverCitation = c
    }
}
