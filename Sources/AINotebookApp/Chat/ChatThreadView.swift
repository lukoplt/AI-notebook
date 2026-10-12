import AINotebookCore
import SwiftUI

/// The conversation (spec §2.2): a centered column (max 760) of messages,
/// streaming answer, error row with retry, follow-up chips and the composer.
struct ChatThreadView: View {
    let model: ChatViewModel
    let nav: NavigationState
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }

    private var isEmpty: Bool {
        model.messages.isEmpty && model.streamingDraft.isEmpty && !model.sending
    }

    var body: some View {
        if isEmpty {
            NewChatEmptyState(model: model, nav: nav, notebook: notebook,
                              showsNotebookPicker: nav.selection.sessionId == nil)
        } else {
            VStack(spacing: 0) {
                conversation
                bottomBar
            }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.spacing(24)) {
                    ForEach(model.messages) { message in
                        if message.id != nil, message.id == model.stoppedMessageId {
                            VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
                                MessageRow(message: message, actions: actions(for: message))
                                Label(t.string(.chatStopped), systemImage: DesignTokens.icon(.stop))
                                    .tokenFont(.caption)
                                    .tokenForeground(.text3)
                            }
                        } else {
                            MessageRow(message: message, actions: actions(for: message))
                        }
                    }
                    if !model.streamingDraft.isEmpty {
                        MessageRow(
                            message: ChatMessage(sessionId: model.selectedSessionId ?? 0, role: .assistant,
                                                 content: model.streamingDraft),
                            isStreaming: true)
                    } else if model.sending {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(t.string(.contextPreviewPreparing))
                    }
                    if let error = model.errorMessage {
                        ChatErrorRow(message: error, retryTitle: t.string(.chatRetry),
                                     onRetry: model.retry == nil ? nil : { Task { await model.performRetry() } })
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: DesignTokens.size(.conversationMax))
                .padding(.horizontal, DesignTokens.spacing(24))
                .padding(.vertical, DesignTokens.spacing(24))
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: model.messages.count) { _, _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: model.streamingDraft) { _, _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: model.selectedSessionId) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private static let bottomAnchor = "thread-bottom"

    private func actions(for message: ChatMessage) -> MessageRowActions {
        var actions = MessageRowActions()
        let isLast = message.id != nil && message.id == model.messages.last?.id
        switch message.role {
        case .user:
            let lastUserId = model.messages.last(where: { $0.role == .user })?.id
            if model.canRegenerate, message.id == lastUserId {
                actions.onEdit = { model.editLastUserMessage() }
            }
        default:
            actions.onCite = { marker in
                model.focusCitation(in: message, marker: marker)
                nav.showPanel(.citations)
            }
            if message.id != nil {
                actions.onSaveAsNote = { Task { await model.saveAsNote(message) } }
                actions.onSentContext = {
                    model.showSentPreview(message)
                    nav.showPanel(.context)
                }
            }
            if isLast, model.canRegenerate {
                actions.onRegenerate = { Task { await model.regenerate() } }
                actions.regenerateProviders = model.chatProviders
                actions.onRegenerateWith = { provider in Task { await model.regenerate(via: provider) } }
            }
        }
        return actions
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            if !model.followups.isEmpty && model.streamingDraft.isEmpty {
                FlowLayout {
                    ForEach(model.followups, id: \.self) { question in
                        ChipButton(question) { Task { await model.sendFollowup(question) } }
                            .disabled(model.sending)
                    }
                }
                .accessibilityLabel(t.string(.chatFollowupsLabel))
            }
            if let noteId = model.savedNoteId {
                HStack(spacing: DesignTokens.spacing(8)) {
                    Label(t.string(.noteSavedNotice), systemImage: DesignTokens.icon(.success))
                        .tokenFont(.caption)
                        .tokenForeground(.text2)
                    Button(t.string(.openNote)) {
                        model.savedNoteId = nil
                        nav.openNote(notebookId: notebook.id ?? -1, noteId: noteId)
                    }
                    .buttonStyle(QuietButtonStyle(token: .focus))
                    .tokenFont(.caption)
                    IconButton(icon: .close, label: t.string(.close)) { model.savedNoteId = nil }
                }
                .task(id: noteId) {
                    try? await Task.sleep(for: .seconds(6))
                    if model.savedNoteId == noteId { model.savedNoteId = nil }
                }
            }
            if let notebookId = notebook.id {
                ChatComposer(model: model, nav: nav, notebookId: notebookId)
            }
        }
        .frame(maxWidth: DesignTokens.size(.conversationMax))
        .padding(.horizontal, DesignTokens.spacing(24))
        .padding(.bottom, DesignTokens.spacing(16))
        .frame(maxWidth: .infinity)
    }
}
