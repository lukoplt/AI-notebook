// Sources/AINotebookApp/ChatView.swift
import SwiftUI
import AINotebookCore

struct ChatView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder

    @State private var session: ChatSession?
    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streamingDraft: String = ""
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var popoverCitation: Citation?
    @State private var popoverSourceTitle: String = ""

    private var t: AppText { settings.text }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            inputBar
        }
        .padding(16)
        .task(id: notebook.id) { await ensureSession() }
        .popover(item: $popoverCitation) { c in
            CitationPopover(citation: c, sourceTitle: popoverSourceTitle)
        }
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
                                sessionId: session?.id ?? 0,
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
    private func ensureSession() async {
        do {
            let existing = try store.chatSessions(notebookId: notebook.id!)
            if let s = existing.first {
                session = s
            } else {
                session = try store.createChatSession(
                    notebookId: notebook.id!,
                    title: t.string(.chatNewSessionTitle)
                )
            }
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @MainActor
    private func reloadMessages() async {
        guard let s = session else { return }
        do {
            messages = try store.messages(sessionId: s.id!)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func send() async {
        guard let s = session else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        sending = true
        errorMessage = nil
        streamingDraft = ""
        defer { sending = false; streamingDraft = "" }
        do {
            _ = try await chatHolder.engine.send(
                sessionId: s.id!,
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
