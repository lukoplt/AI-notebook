import Foundation

/// Where the SQLite database lives. Either an on-disk file URL or an
/// in-memory marker for tests. Pulled out so production code resolves the
/// Application Support path while tests inject a fully in-memory store.
public struct StorePath: Sendable {
    public let fileURL: URL?

    public var isInMemory: Bool { fileURL == nil }

    public static let inMemory = StorePath(fileURL: nil)

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Returns `~/Library/Application Support/AINotebook/db.sqlite`,
    /// creating the parent directory on demand.
    public static func production(
        fileManager: FileManager = .default
    ) throws -> StorePath {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let container = appSupport.appendingPathComponent("AINotebook", isDirectory: true)
        try fileManager.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        return StorePath(fileURL: container.appendingPathComponent("db.sqlite"))
    }
}
