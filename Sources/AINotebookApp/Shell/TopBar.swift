import AINotebookCore
import SwiftUI

/// Window toolbar of the main area (spec §2.2 top bar): thread title, notebook
/// label, the "…" menu and the right-panel toggle.
struct TopBar: ViewModifier {
    let nav: NavigationState
    let chat: ChatViewModel

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder
    @EnvironmentObject private var indexing: IndexingStatusModel

    @State private var renaming: ChatRenameTarget?

    private var t: AppText { settings.text }

    private var notebookName: String {
        store.notebooks.first(where: { $0.id == nav.currentNotebookId })?.name ?? ""
    }

    private var threadTitle: String {
        switch nav.selection {
        case .chat(let nb, let sid):
            nav.sessions[nb]?.first(where: { $0.id == sid })?.title ?? t.string(.shellNewChat)
        case .newChat(let nb):
            nb == nil ? t.string(.appName) : t.string(.shellNewChat)
        case .note(_, let noteId):
            (try? store.note(id: noteId))?.title ?? t.string(.notes)
        }
    }

    /// The window title is editable in place for a chat thread (spec §2.2: the
    /// thread title renames the chat); other states ignore edits, so their
    /// title stays as shown.
    private var editableTitle: Binding<String> {
        Binding(
            get: { threadTitle },
            set: { newTitle in
                guard case .chat(let nb, let sid) = nav.selection else { return }
                if nav.renameChat(sid, notebookId: nb, to: newTitle, store: store) { chat.refreshNotebookData() }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .navigationTitle(editableTitle)
            .navigationSubtitle(notebookName)
            .chatRenameAlert($renaming, nav: nav) { chat.refreshNotebookData() }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if case .chat(let nb, let sid) = nav.selection {
                        Menu {
                            Button {
                                if let last = chat.lastAssistantMessage {
                                    chat.showSentPreview(last)
                                    nav.showPanel(.context)
                                }
                            } label: {
                                Label(t.string(.contextPreviewSent), systemImage: DesignTokens.icon(.sentContext))
                            }
                            .disabled(chat.lastAssistantMessage == nil)
                            Button {
                                renaming = ChatRenameTarget(id: sid, notebookId: nb, title: threadTitle)
                            } label: {
                                Label(t.string(.renameChat) + "…", systemImage: DesignTokens.icon(.edit))
                            }
                            Divider()
                            Button(role: .destructive) { deleteChat(sid, notebookId: nb) } label: {
                                Label(t.string(.chatDeleteSessionButton), systemImage: DesignTokens.icon(.delete))
                            }
                        } label: {
                            Label(t.string(.shellMore), systemImage: DesignTokens.icon(.more))
                        }
                        .help(t.string(.shellMore))
                    }
                    if !store.notebooks.isEmpty {
                        Button { nav.togglePanel() } label: {
                            Label {
                                Text(t.string(.shellTogglePanel))
                            } icon: {
                                Image(systemName: DesignTokens.icon(.togglePanel))
                                    .overlay(alignment: .topTrailing) {
                                        if let dot = panelDot {
                                            Circle()
                                                .fill(DesignTokens.color(dot))
                                                .frame(width: DesignTokens.spacing(8) * 0.75,
                                                       height: DesignTokens.spacing(8) * 0.75)
                                                .offset(x: DesignTokens.spacing(4) * 0.75, y: -DesignTokens.spacing(4) * 0.5)
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                        }
                        .help(panelHelp)
                        .accessibilityValue(panelDot == nil ? "" : panelStatusText ?? "")
                    }
                }
            }
    }

    /// Indexing needs attention while the right panel is closed: a dot on its
    /// toggle (focus = working, warning/danger = blocked), nil otherwise.
    private var panelDot: DesignTokens.ColorToken? {
        guard !nav.panelVisible, indexing.presentationDot, let status = indexing.status else { return nil }
        switch IndexingStatusPresentation.make(status, searchableFiles: indexing.searchableFiles, text: t)?.tone {
        case .warning: return .warning
        case .danger: return .danger
        default: return .focus
        }
    }

    private var panelStatusText: String? {
        indexing.status.flatMap { IndexingStatusPresentation.make($0, searchableFiles: indexing.searchableFiles, text: t)?.text }
    }

    private var panelHelp: String {
        guard panelDot != nil, let status = panelStatusText else { return t.string(.shellTogglePanel) }
        return t.string(.shellTogglePanel) + " — " + status
    }

    private func deleteChat(_ id: Int64, notebookId: Int64) {
        guard (try? store.deleteChatSession(id: id)) != nil else { return }
        let previews = chatHolder.previews
        Task { await previews.clear(sessionId: id) }
        nav.sessionDeleted(id, notebookId: notebookId, store: store)
    }
}

extension View {
    func shellTopBar(nav: NavigationState, chat: ChatViewModel) -> some View {
        modifier(TopBar(nav: nav, chat: chat))
    }
}
