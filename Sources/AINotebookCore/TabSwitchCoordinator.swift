import SwiftUI
import Combine

@MainActor
public final class TabSwitchCoordinator: ObservableObject {
    public enum Tab: Hashable, Sendable {
        case sources, chat, notes, transformations
    }

    @Published public var target: Tab?

    public init() {}

    public func request(_ tab: Tab) { target = tab }
    public func clear() { target = nil }
}
