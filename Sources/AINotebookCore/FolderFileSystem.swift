import Foundation

public struct FolderEntry: Sendable, Equatable {
    public let relPath: String
    public let isDirectory: Bool
    public let isLink: Bool
    public let stamp: FileStamp

    public init(relPath: String, isDirectory: Bool, isLink: Bool, stamp: FileStamp) {
        self.relPath = relPath
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.stamp = stamp
    }
}

public struct FolderRead: Sendable, Equatable {
    /// Streaming hashes retain no payload: native `hash` always returns empty
    /// bytes. This field remains available to bounded fake/small-file adapters.
    public let bytes: Data
    public let stamp: FileStamp
    public let sha256: String

    public init(bytes: Data, stamp: FileStamp, sha256: String) {
        self.bytes = bytes
        self.stamp = stamp
        self.sha256 = sha256
    }
}

public protocol FolderFileSystem: FolderPathIdentity {
    func caseSensitive(root: FolderSource) throws -> Bool
    func list(root: FolderSource, directory: String) throws -> [FolderEntry]
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot
}

/// Owns a private temporary copy produced through the validated no-follow file
/// handle. PDF/ZIP readers use this copy rather than reopening the user path.
public final class FolderFileSnapshot: @unchecked Sendable {
    public let url: URL
    public let stamp: FileStamp
    public let hash: String
    private let gate = NSLock()
    private var closed = false

    init(url: URL, stamp: FileStamp, hash: String) {
        self.url = url
        self.stamp = stamp
        self.hash = hash
    }

    public func close() {
        gate.lock()
        defer { gate.unlock() }
        guard !closed else { return }
        closed = true
        try? FileManager.default.removeItem(at: url)
    }

    deinit { close() }
}
