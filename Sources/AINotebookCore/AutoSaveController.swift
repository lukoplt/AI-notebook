import Foundation

@MainActor
public final class AutoSaveController: ObservableObject {
    public enum Status: Equatable, Sendable {
        case saved
        case unsaved
        case saving
        case error(String)
    }

    @Published public private(set) var status: Status = .saved

    private let debounceMillis: Int
    private let save: @Sendable (String) -> Void
    private var pendingBody: String?
    private var debounceTask: Task<Void, Never>?

    public init(
        debounceMillis: Int = 2_000,
        save: @escaping @Sendable (String) -> Void
    ) {
        self.debounceMillis = debounceMillis
        self.save = save
    }

    public func noteDidChange(_ markdown: String) {
        pendingBody = markdown
        status = .unsaved
        debounceTask?.cancel()
        let delay = UInt64(debounceMillis) * 1_000_000
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await self?.flush()
        }
    }

    public func manualSave() {
        debounceTask?.cancel()
        Task { [weak self] in await self?.flush() }
    }

    private func flush() async {
        guard let body = pendingBody else { return }
        status = .saving
        save(body)
        pendingBody = nil
        status = .saved
    }
}
