import AINotebookCore
import Foundation
import Observation
import SwiftUI

/// What the main area shows (spec §2.2, §2.4).
enum ShellSelection: Hashable {
    /// Empty "what are we working on" state; the chat is created by its first message.
    case newChat(notebookId: Int64?)
    case chat(notebookId: Int64, sessionId: Int64)
    case note(notebookId: Int64, noteId: Int64)

    var notebookId: Int64? {
        switch self {
        case .newChat(let id): id
        case .chat(let id, _), .note(let id, _): id
        }
    }

    var sessionId: Int64? {
        if case .chat(_, let sid) = self { return sid }
        return nil
    }

    var noteId: Int64? {
        if case .note(_, let nid) = self { return nid }
        return nil
    }

    var isDocument: Bool { noteId != nil }
}

/// Shell navigation: main-area selection, right panel, sidebar chat lists and
/// sheets requested from anywhere. Pure rules live in Core `ShellNavigation`.
@MainActor
@Observable
final class NavigationState {
    var selection: ShellSelection = .newChat(notebookId: nil) {
        didSet {
            guard oldValue != selection else { return }
            if !selection.isDocument { lastThread = selection }
            if selection.isDocument, !oldValue.isDocument { previousThread = oldValue }
        }
    }

    /// Right panel visibility and segment are remembered across launches.
    var panelVisible: Bool {
        didSet { Self.defaults.set(panelVisible, forKey: Self.panelVisibleKey) }
    }
    var panelSegment: ShellPanel {
        didSet { Self.defaults.set(panelSegment.rawValue, forKey: Self.panelSegmentKey) }
    }
    /// Right panel width (token range 320–420), remembered.
    var panelWidth: CGFloat {
        didSet { Self.defaults.set(Double(panelWidth), forKey: Self.panelWidthKey) }
    }

    /// Newest-first chats per notebook (sidebar).
    private(set) var sessions: [Int64: [ChatSession]] = [:]
    @ObservationIgnored private var notebookOrder: [Int64] = []
    var collapsedNotebooks: Set<Int64> = []
    var expandedChatLists: Set<Int64> = []

    // Sheets / palettes requested from menus, shortcuts or the composer.
    var showSearch = false
    var showNewNotebook = false
    var runToolRequest: RunToolRequest?

    /// The thread to return to from a document (⌘[).
    @ObservationIgnored private var previousThread: ShellSelection?
    @ObservationIgnored private(set) var lastThread: ShellSelection = .newChat(notebookId: nil)

    @ObservationIgnored private static let defaults = UserDefaults.standard
    @ObservationIgnored private static let panelVisibleKey = "ui.rightPanel.visible"
    @ObservationIgnored private static let panelSegmentKey = "ui.rightPanel.segment"
    @ObservationIgnored private static let panelWidthKey = "ui.rightPanel.width"

    init() {
        panelVisible = Self.defaults.object(forKey: Self.panelVisibleKey) == nil
            ? true : Self.defaults.bool(forKey: Self.panelVisibleKey)
        panelSegment = Self.defaults.string(forKey: Self.panelSegmentKey).flatMap(ShellPanel.init) ?? .sources
        let stored = Self.defaults.double(forKey: Self.panelWidthKey)
        panelWidth = stored > 0
            ? min(max(CGFloat(stored), DesignTokens.size(.panelMin)), DesignTokens.size(.panelMax))
            : DesignTokens.size(.panelMin) + DesignTokens.spacing(32)
    }

    var currentNotebookId: Int64? { selection.notebookId }

    /// The segment actually shown for the current mode.
    var visibleSegment: ShellPanel {
        ShellNavigation.resolvedSegment(panelSegment, documentMode: selection.isDocument)
    }

    func showPanel(_ segment: ShellPanel) {
        panelSegment = segment
        panelVisible = true
    }

    func togglePanel() { panelVisible.toggle() }

    // MARK: Sessions

    /// `notebooks` overrides `store.notebooks` (a `@Published` sink runs before the value is stored).
    func reloadSessions(store: NotebookStore, notebooks: [Notebook]? = nil) {
        var all: [Int64: [ChatSession]] = [:]
        notebookOrder = (notebooks ?? store.notebooks).compactMap(\.id)
        for id in notebookOrder {
            all[id] = (try? store.chatSessions(notebookId: id)) ?? []
        }
        sessions = all
    }

    func reloadSessions(notebookId: Int64, store: NotebookStore) {
        sessions[notebookId] = (try? store.chatSessions(notebookId: notebookId)) ?? []
    }

    // MARK: Navigation

    /// New chat in the given (or current, or first) notebook.
    func newChat(in notebookId: Int64? = nil) {
        let target = notebookId ?? currentNotebookId ?? notebookOrder.first
        selection = .newChat(notebookId: target)
    }

    func openChat(notebookId: Int64, sessionId: Int64) {
        selection = .chat(notebookId: notebookId, sessionId: sessionId)
    }

    func openNote(notebookId: Int64, noteId: Int64) {
        selection = .note(notebookId: notebookId, noteId: noteId)
    }

    /// Back from a document to the thread it was opened from.
    func back() {
        guard selection.isDocument else { return }
        selection = previousThread ?? lastThread
    }

    /// The notebook's newest chat, else its new-chat state.
    func openNotebook(_ notebookId: Int64) {
        if let first = sessions[notebookId]?.first?.id {
            selection = .chat(notebookId: notebookId, sessionId: first)
        } else {
            selection = .newChat(notebookId: notebookId)
        }
    }

    /// Applies a legacy `TabSwitchCoordinator` request (spec §2.7).
    func apply(_ tab: TabSwitchCoordinator.Tab) {
        switch ShellNavigation.target(for: tab) {
        case .panel(let segment): showPanel(segment)
        case .thread: if selection.isDocument { back() }
        case .runTool: runToolRequest = RunToolRequest(transformationId: nil)
        }
    }

    /// A chat was deleted: keep a sensible selection.
    func sessionDeleted(_ id: Int64, notebookId: Int64, store: NotebookStore) {
        let before = sessions[notebookId]?.compactMap(\.id) ?? []
        reloadSessions(notebookId: notebookId, store: store)
        guard selection.sessionId == id else { return }
        if let next = ShellNavigation.selectionAfterDeleting(id, from: before) {
            selection = .chat(notebookId: notebookId, sessionId: next)
        } else {
            selection = .newChat(notebookId: notebookId)
        }
    }

    /// Renames a chat (sidebar menu, top bar title or "…" menu). Blank or
    /// unchanged titles are ignored; returns whether a new title was saved.
    @discardableResult
    func renameChat(_ id: Int64, notebookId: Int64, to title: String, store: NotebookStore) -> Bool {
        let current = sessions[notebookId]?.first(where: { $0.id == id })?.title ?? ""
        guard let newTitle = ChatSessionState.renamedTitle(title, current: current),
              (try? store.renameChatSession(id: id, title: newTitle)) != nil else { return false }
        reloadSessions(notebookId: notebookId, store: store)
        return true
    }

    /// A notebook was deleted: drop everything that pointed into it.
    func notebookDeleted(_ id: Int64) {
        sessions[id] = nil
        notebookOrder.removeAll { $0 == id }
        if selection.notebookId == id {
            selection = .newChat(notebookId: notebookOrder.first)
        }
    }
}

/// "Run tool" sheet request (optionally preselecting a template).
struct RunToolRequest: Identifiable, Equatable {
    let id = UUID()
    let transformationId: Int64?
}

/// Lets menu-bar commands reach the focused window's shell.
struct ShellFocusKey: FocusedValueKey {
    typealias Value = NavigationState
}

extension FocusedValues {
    var shell: NavigationState? {
        get { self[ShellFocusKey.self] }
        set { self[ShellFocusKey.self] = newValue }
    }
}
