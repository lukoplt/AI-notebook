import AINotebookCore
import AppKit
import SwiftUI

/// The chat-first workspace (spec §2): sidebar · main area · right panel.
struct AppShellView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder
    @EnvironmentObject private var routerHolder: ProviderRouterHolder
    @EnvironmentObject private var noteJump: NoteJumpCoordinator
    @EnvironmentObject private var tabSwitch: TabSwitchCoordinator
    @EnvironmentObject private var folderWatch: FolderWatchController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nav = NavigationState()
    @State private var chat = ChatViewModel()
    /// Indexing status of the current notebook (Sources strip, top-bar panel dot).
    @StateObject private var indexing = IndexingStatusModel()

    private var t: AppText { settings.text }

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView {
            SidebarView(nav: nav)
                .navigationSplitViewColumnWidth(min: DesignTokens.size(.sidebarMin),
                                                ideal: (DesignTokens.size(.sidebarMin) + DesignTokens.size(.sidebarMax)) / 2,
                                                max: DesignTokens.size(.sidebarMax))
        } detail: {
            // The right panel is a resizable trailing column of the detail
            // (deterministic widths; the system inspector column clipped its
            // content on newer macOS).
            HStack(spacing: 0) {
                MainAreaView(nav: nav, chat: chat)
                if nav.panelVisible, !store.notebooks.isEmpty {
                    PanelResizeHandle(width: $nav.panelWidth)
                    RightPanelView(nav: nav, chat: chat)
                        .frame(width: nav.panelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(DesignTokens.animation(.slowMs, reduceMotion: reduceMotion), value: nav.panelVisible)
        }
        .environmentObject(indexing)
        .focusedSceneValue(\.shell, nav)
        #if DEBUG
        .modifier(QAScreen(nav: nav, chat: chat))
        #endif
        .sheet(isPresented: $nav.showSearch) {
            GlobalSearchPalette(
                isPresented: $nav.showSearch,
                onSelectNote: { notebookId, noteId in nav.openNote(notebookId: notebookId, noteId: noteId) },
                onSelectSource: { notebookId, _ in
                    if nav.currentNotebookId != notebookId { nav.openNotebook(notebookId) }
                    nav.showPanel(.sources)
                }
            )
            .environmentObject(settings)
            .environmentObject(store)
        }
        .sheet(isPresented: $nav.showNewNotebook) {
            NewNotebookSheet { created in
                nav.reloadSessions(store: store)
                nav.newChat(in: created.id)
            }
            .environmentObject(settings)
            .environmentObject(store)
        }
        .sheet(item: $nav.runToolRequest) { request in
            if let id = nav.currentNotebookId, let notebook = store.notebooks.first(where: { $0.id == id }) {
                RunToolSheet(notebook: notebook, preselected: request.transformationId, nav: nav)
                    .environmentObject(settings)
                    .environmentObject(store)
            }
        }
        .onReceive(noteJump.$target.compactMap { $0 }) { noteId in
            noteJump.clear()
            if let note = try? store.note(id: noteId) {
                nav.openNote(notebookId: note.notebookId, noteId: noteId)
            }
        }
        .onReceive(tabSwitch.$target.compactMap { $0 }) { tab in
            tabSwitch.clear()
            nav.apply(tab)
        }
        .onReceive(store.$notebooks) { notebooks in
            nav.reloadSessions(store: store, notebooks: notebooks)
            if let id = nav.currentNotebookId, !notebooks.contains(where: { $0.id == id }) {
                nav.notebookDeleted(id)
            } else if nav.currentNotebookId == nil, let first = notebooks.first?.id {
                nav.openNotebook(first)
            }
        }
        .task {
            nav.reloadSessions(store: store)
            if nav.currentNotebookId == nil, let first = store.notebooks.first?.id {
                nav.openNotebook(first)
            }
        }
        .task(id: nav.currentNotebookId) {
            indexing.bind(notebookId: nav.currentNotebookId, store: store, runtime: folderWatch.runtime)
        }
        .onDisappear { indexing.unbind() }
        .task(id: nav.currentNotebookId) {
            guard let id = nav.currentNotebookId else { return }
            chat.onSessionCreated = { notebookId, sessionId in
                nav.reloadSessions(notebookId: notebookId, store: store)
                nav.openChat(notebookId: notebookId, sessionId: sessionId)
            }
            await chat.load(notebookId: id, sessionId: nav.selection.sessionId, dependencies: .init(
                settings: settings, store: store, chatHolder: chatHolder, routerHolder: routerHolder))
        }
        .onChange(of: nav.selection) { _, selection in
            guard selection.notebookId == chat.notebookId, !selection.isDocument else { return }
            chat.select(sessionId: selection.sessionId)
        }
    }
}

/// 1 pt hairline between main area and right panel with a wider invisible
/// drag area; widths stay within the token panel range.
private struct PanelResizeHandle: View {
    @Binding var width: CGFloat
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(DesignTokens.color(.border))
            .frame(width: DesignTokens.size(.borderWidth))
            .overlay {
                Color.clear
                    .frame(width: DesignTokens.spacing(8))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                width = min(max(base - value.translation.width, DesignTokens.size(.panelMin)),
                                            DesignTokens.size(.panelMax))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}
