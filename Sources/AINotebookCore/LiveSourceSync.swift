import Foundation
import CryptoKit

/// Epic E1/E2 — live sources. Folder sync forwards to the durable
/// `FolderIngestionRuntime` (E1); `recrawl` refreshes one URL/loose source in
/// place, keeping its identity and old revision evidence (E2).
public final class LiveSourceSync: @unchecked Sendable {
    private let store: NotebookStore
    private let ingestion: IngestionService

    public init(store: NotebookStore, ingestion: IngestionService) {
        self.store = store
        self.ingestion = ingestion
    }

    /// Legacy MD5 utility (kept for compatibility); no durable path calls it.
    public static func contentHash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public enum SyncError: Error, Equatable {
        /// Folder sync now runs only through the durable folder runtime.
        case folderRuntimeUnavailable
    }

    /// Deprecated facade: finds or adds the persisted folder, requests a scan
    /// through the durable runtime, awaits that folder's work and returns the
    /// number of sources that gained a new published revision. It never scans
    /// files itself.
    @available(*, deprecated, message: "Use FolderIngestionRuntime add/scan commands.")
    @discardableResult
    public func syncFolder(notebookId: Int64, folder: URL) async throws -> Int {
        guard let runtime = ingestion.folderRuntime else { throw SyncError.folderRuntimeUnavailable }
        return try await runtime.syncFolder(notebookId: notebookId, url: folder)
    }

    /// Re-crawls a web (or file) source and records the sync timestamp (E2).
    @discardableResult
    public func recrawl(sourceId: Int64) async throws -> Source {
        let src = try await ingestion.reIngest(sourceId: sourceId)
        // The timestamp records the published SHA-256; no MD5 override.
        try await MainActor.run {
            let published = try store.source(id: sourceId)?.contentHash ?? src.contentHash ?? ""
            try store.updateSourceSyncInfo(id: sourceId, lastSyncedAt: Date(), contentHash: published)
        }
        return try await MainActor.run { try store.source(id: sourceId) } ?? src
    }
}
