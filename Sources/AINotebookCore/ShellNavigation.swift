import Foundation

/// Right-panel segments of the redesigned shell (spec §2.3, §2.4).
public enum ShellPanel: String, CaseIterable, Sendable {
    case sources, notes, context, citations, noteChat
}

/// Where a legacy tab request (`TabSwitchCoordinator`) lands in the new shell.
public enum ShellTabTarget: Equatable, Sendable {
    case panel(ShellPanel)
    case thread
    case runTool
}

/// Pure navigation rules of the macOS shell (UI redesign B3); the SwiftUI
/// `NavigationState` applies them.
public enum ShellNavigation {

    /// Sources → Sources panel, Notes → Notes panel, Chat → the current thread,
    /// Transformations → the "Run tool" sheet (spec §2.7).
    public static func target(for tab: TabSwitchCoordinator.Tab) -> ShellTabTarget {
        switch tab {
        case .sources: .panel(.sources)
        case .notes: .panel(.notes)
        case .chat: .thread
        case .transformations: .runTool
        }
    }

    /// Panel segments in display order; "Chat about note" exists only in document mode.
    public static func segments(documentMode: Bool) -> [ShellPanel] {
        documentMode ? [.sources, .notes, .noteChat, .citations]
                     : [.sources, .notes, .context, .citations]
    }

    /// A remembered segment that the current mode does not offer falls back to
    /// the closest one (note chat ↔ context), else Sources.
    public static func resolvedSegment(_ wanted: ShellPanel, documentMode: Bool) -> ShellPanel {
        let available = segments(documentMode: documentMode)
        if available.contains(wanted) { return wanted }
        switch wanted {
        case .noteChat where !documentMode: return .context
        case .context where documentMode: return .noteChat
        default: return .sources
        }
    }

    /// Newest-first chats of one notebook: at most `limit` unless expanded.
    public static func visibleSessions<T>(_ sessions: [T], showAll: Bool, limit: Int) -> (visible: [T], hidden: Int) {
        guard !showAll, sessions.count > limit, limit >= 0 else { return (sessions, 0) }
        return (Array(sessions.prefix(limit)), sessions.count - limit)
    }

    /// Title for a chat created by its first message: whitespace collapsed,
    /// at most `maxLength` characters (an ellipsis marks a cut), else `fallback`.
    public static func sessionTitle(firstMessage: String, fallback: String, maxLength: Int = 48) -> String {
        let words = firstMessage.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let collapsed = words.joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback }
        guard collapsed.count > maxLength, maxLength > 1 else { return collapsed }
        let cut = collapsed.prefix(maxLength - 1)
        let trimmed = cut.last == " " ? cut.dropLast() : cut[...]
        return String(trimmed) + "…"
    }

    /// The thread to show after one chat is deleted: the next one in the list,
    /// else the previous one, else none (new chat in that notebook).
    public static func selectionAfterDeleting(_ id: Int64, from sessionIds: [Int64]) -> Int64? {
        guard let index = sessionIds.firstIndex(of: id) else { return nil }
        if index + 1 < sessionIds.count { return sessionIds[index + 1] }
        return index > 0 ? sessionIds[index - 1] : nil
    }
}
