import AINotebookCore
import AppKit
import SwiftUI

/// Sidebar (spec §2.1): New chat, Search, notebooks as collapsible groups with
/// their newest chats, "+ New notebook", the update indicator and Settings.
struct SidebarView: View {
    let nav: NavigationState

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder
    @EnvironmentObject private var updates: UpdateService
    @Environment(\.openSettings) private var openSettings

    @State private var renaming: Notebook?
    @State private var renamingChat: ChatRenameTarget?
    @State private var deleting: Notebook?
    @State private var instructionsFor: Notebook?
    @State private var restoreURL: URL?
    @State private var statusMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        // A sidebar List gets the platform's column insets (incl. the floating
        // sidebar on newer macOS); rows keep the token look.
        List {
            topActions
                .sidebarListRow()
            Text(t.string(.notebooks))
                .tokenFont(.caption)
                .tokenForeground(.text3)
                .padding(.horizontal, DesignTokens.spacing(8))
                .padding(.top, DesignTokens.spacing(16))
                .padding(.bottom, DesignTokens.spacing(4))
                .sidebarListRow()
            ForEach(store.notebooks) { notebook in
                if let id = notebook.id {
                    notebookGroup(notebook, id: id)
                }
            }
            Button { nav.showNewNotebook = true } label: {
                Label(t.string(.shellNewNotebook), systemImage: DesignTokens.icon(.add))
                    .tokenFont(.caption)
                    .padding(.horizontal, DesignTokens.spacing(8))
                    .padding(.vertical, DesignTokens.spacing(8))
            }
            .buttonStyle(QuietButtonStyle(token: .text3))
            .sidebarListRow()
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(DesignTokens.color(.bgSidebar))
        .sheet(item: $renaming) { notebook in
            RenameNotebookSheet(notebook: notebook)
        }
        .sheet(item: $instructionsFor) { notebook in
            NotebookInstructionsSheet(notebook: notebook)
        }
        .chatRenameAlert($renamingChat, nav: nav)
        .alert(t.string(.deleteNotebook), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { notebook in
            Button(t.string(.delete), role: .destructive) { delete(notebook) }
            Button(t.string(.cancel), role: .cancel) { deleting = nil }
        } message: { _ in
            Text(t.string(.confirmDeleteNotebook))
        }
        .alert(t.string(.restoreDatabase), isPresented: Binding(
            get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } }
        )) {
            Button(t.string(.cancel), role: .cancel) { restoreURL = nil }
            Button(t.string(.restoreDatabase), role: .destructive) {
                if let url = restoreURL {
                    statusMessage = NotebookActions.restore(from: url, store: store, text: t)
                    nav.reloadSessions(store: store)
                }
                restoreURL = nil
            }
        } message: {
            Text(t.string(.restoreConfirm))
        }
        .alert(statusMessage ?? "", isPresented: Binding(
            get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } }
        )) {
            Button(t.string(.doneButton)) { statusMessage = nil }
        }
    }

    // MARK: Top

    private var topActions: some View {
        VStack(spacing: 2) {
            Button { nav.newChat() } label: {
                SidebarRow(title: t.string(.shellNewChat), icon: .newChat, emphasized: true) {
                    shortcutHint("⌘N")
                }
            }
            .buttonStyle(.plain)
            Button { nav.showSearch = true } label: {
                SidebarRow(title: t.string(.shellSearch), icon: .search) {
                    shortcutHint("⌘K")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func shortcutHint(_ value: String) -> some View {
        Text(value).tokenFont(.caption).tokenForeground(.text3).accessibilityHidden(true)
    }

    // MARK: Notebook groups

    @ViewBuilder
    private func notebookGroup(_ notebook: Notebook, id: Int64) -> some View {
        let collapsed = nav.collapsedNotebooks.contains(id)
        NotebookHeaderRow(
            title: notebook.name,
            collapsed: collapsed,
            isCurrent: nav.currentNotebookId == id,
            labels: .init(newChat: t.string(.shellNewChat), more: t.string(.shellMore),
                          expand: t.string(.folderShowFiles), collapse: t.string(.folderHideFiles)),
            onToggle: {
                if collapsed { nav.collapsedNotebooks.remove(id) } else { nav.collapsedNotebooks.insert(id) }
            },
            onNewChat: { nav.newChat(in: id) },
            menu: { notebookMenu(notebook) }
        )
        .contextMenu { notebookMenu(notebook) }
        .sidebarListRow()
        if !collapsed {
            let all = nav.sessions[id] ?? []
            let shown = ShellNavigation.visibleSessions(
                all, showAll: nav.expandedChatLists.contains(id),
                limit: Int(DesignTokens.size(.sidebarChatsVisible)))
            ForEach(shown.visible) { session in
                if let sid = session.id {
                    Button { nav.openChat(notebookId: id, sessionId: sid) } label: {
                        SidebarRow(title: session.title, isSelected: nav.selection.sessionId == sid,
                                   indent: DesignTokens.spacing(24))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renamingChat = ChatRenameTarget(id: sid, notebookId: id, title: session.title)
                        } label: {
                            Label(t.string(.renameChat) + "…", systemImage: DesignTokens.icon(.edit))
                        }
                        Button(role: .destructive) { deleteSession(sid, notebookId: id) } label: {
                            Label(t.string(.chatDeleteSessionButton), systemImage: DesignTokens.icon(.delete))
                        }
                    }
                    .sidebarListRow()
                }
            }
            if shown.hidden > 0 {
                Button { nav.expandedChatLists.insert(id) } label: {
                    Text(String(format: t.string(.shellShowMore), shown.hidden))
                        .tokenFont(.caption)
                        .padding(.leading, DesignTokens.spacing(8) + DesignTokens.spacing(24))
                        .frame(height: DesignTokens.size(.sidebarRow) - DesignTokens.spacing(8))
                }
                .buttonStyle(QuietButtonStyle(token: .text3))
                .sidebarListRow()
            } else if nav.expandedChatLists.contains(id),
                      all.count > Int(DesignTokens.size(.sidebarChatsVisible)) {
                Button { nav.expandedChatLists.remove(id) } label: {
                    Text(t.string(.shellShowLess))
                        .tokenFont(.caption)
                        .padding(.leading, DesignTokens.spacing(8) + DesignTokens.spacing(24))
                        .frame(height: DesignTokens.size(.sidebarRow) - DesignTokens.spacing(8))
                }
                .buttonStyle(QuietButtonStyle(token: .text3))
                .sidebarListRow()
            }
        }
    }

    @ViewBuilder
    private func notebookMenu(_ notebook: Notebook) -> some View {
        Button { nav.newChat(in: notebook.id) } label: {
            Label(t.string(.shellNewChat), systemImage: DesignTokens.icon(.newChat))
        }
        Button { instructionsFor = notebook } label: {
            Label(t.string(.notebookInstructions) + "…", systemImage: DesignTokens.icon(.instructions))
        }
        Divider()
        Button { statusMessage = NotebookActions.exportZip(notebook, store: store, text: t) } label: {
            Label(t.string(.exportNotebookZip), systemImage: DesignTokens.icon(.export))
        }
        Button { statusMessage = NotebookActions.backup(store: store, text: t) } label: {
            Label(t.string(.backupDatabase), systemImage: DesignTokens.icon(.backup))
        }
        Button { restoreURL = NotebookActions.chooseRestoreFile() } label: {
            Label(t.string(.restoreDatabase), systemImage: DesignTokens.icon(.restore))
        }
        Divider()
        Button { renaming = notebook } label: {
            Label(t.string(.renameNotebook) + "…", systemImage: DesignTokens.icon(.edit))
        }
        Button(role: .destructive) { deleting = notebook } label: {
            Label(t.string(.deleteNotebook), systemImage: DesignTokens.icon(.delete))
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Hairline().padding(.bottom, DesignTokens.spacing(4))
            if let info = updates.availableInfo, !updates.bannerDismissed {
                Menu {
                    Text(String(format: t.string(.updateBannerTitle), info.latestVersion))
                    Button(t.string(.updateDownloadButton)) {
                        if let url = URL(string: info.downloadURL) { NSWorkspace.shared.open(url) }
                    }
                    Button(t.string(.updateLaterButton)) { updates.bannerDismissed = true }
                } label: {
                    HStack(spacing: DesignTokens.spacing(8)) {
                        Circle()
                            .fill(DesignTokens.color(.focus))
                            .frame(width: DesignTokens.spacing(8), height: DesignTokens.spacing(8))
                            .accessibilityHidden(true)
                        Text(t.string(.shellUpdateAvailable))
                            .tokenFont(.caption)
                            .tokenForeground(.text2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DesignTokens.spacing(8))
                    .frame(height: DesignTokens.size(.sidebarRow))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel(String(format: t.string(.updateBannerTitle), info.latestVersion))
            }
            Button { openSettings() } label: {
                SidebarRow(title: t.string(.settings), icon: .settings) { shortcutHint("⌘,") }
            }
            .buttonStyle(.plain)
        }
        // Matches the sidebar List's column inset above it.
        .padding(.leading, DesignTokens.spacing(16))
        .padding(.trailing, DesignTokens.spacing(8))
        .padding(.bottom, DesignTokens.spacing(8))
        .background(DesignTokens.color(.bgSidebar))
    }

    // MARK: Actions

    private func deleteSession(_ id: Int64, notebookId: Int64) {
        do {
            try store.deleteChatSession(id: id)
            let previews = chatHolder.previews
            Task { await previews.clear(sessionId: id) }
            nav.sessionDeleted(id, notebookId: notebookId, store: store)
        } catch {
            statusMessage = String(describing: error)
        }
    }

    private func delete(_ notebook: Notebook) {
        defer { deleting = nil }
        guard let id = notebook.id else { return }
        do {
            try store.deleteNotebook(id: id)
            nav.notebookDeleted(id)
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

/// Collapsible notebook group header with hover "+ new chat" and "…" menu.
private struct NotebookHeaderRow<MenuContent: View>: View {
    struct Labels {
        let newChat: String
        let more: String
        let expand: String
        let collapse: String
    }

    let title: String
    let collapsed: Bool
    let isCurrent: Bool
    let labels: Labels
    let onToggle: () -> Void
    let onNewChat: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            SidebarRow(title: title, icon: .notebook, emphasized: isCurrent) {
                Image(systemName: DesignTokens.icon(collapsed ? .chevronRight : .chevronDown))
                    .font(DesignTokens.font(.caption))
                    .tokenForeground(.text3)
                    .opacity(hovering ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(collapsed ? labels.expand : labels.collapse)
        // Overlaid so the hidden actions never truncate the notebook name.
        .overlay(alignment: .trailing) {
            HoverActions(isVisible: hovering) {
                IconButton(icon: .newChat, label: labels.newChat, action: onNewChat)
                IconMenu(icon: .more, label: labels.more, content: menu)
            }
            .background(DesignTokens.color(.bgSidebar).opacity(hovering ? 1 : 0))
        }
        .onHover { hovering = $0 }
    }
}

private extension View {
    /// Plain, inset-free list row: the row view draws its own selection/hover.
    func sidebarListRow() -> some View {
        listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
