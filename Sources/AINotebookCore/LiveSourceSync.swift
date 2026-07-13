import Foundation
import CryptoKit

/// Epic E1/E2 — keeps live sources in sync. Scans a watched folder and
/// re-ingests only files whose content hash changed (E1), and re-crawls a
/// single URL source on demand (E2). The App layer drives `syncFolder` from an
/// FSEvents/timer watcher; this type holds the testable change-detection logic.
public final class LiveSourceSync: @unchecked Sendable {
    private let store: NotebookStore
    private let ingestion: IngestionService

    public init(store: NotebookStore, ingestion: IngestionService) {
        self.store = store
        self.ingestion = ingestion
    }

    /// MD5 of the file's bytes, lowercase hex. MD5 is fine here — this is a
    /// change detector, not a security primitive.
    public static func contentHash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Scans `folder` (non-recursive): ingests new files, re-ingests changed
    /// ones (by hash), and skips unchanged. Deleted files are left as stale
    /// (not removed). Returns how many files were (re)ingested.
    @discardableResult
    public func syncFolder(notebookId: Int64, folder: URL) async throws -> Int {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let existing = try await MainActor.run { try store.sourcesIncludingShadow(notebookId: notebookId) }
        var changed = 0
        for file in entries where SourceType.detect(filename: file.lastPathComponent) != nil {
            let hash = try Self.contentHash(of: file)
            if let match = existing.first(where: { $0.rawPath == file.path }) {
                if match.contentHash == hash { continue } // unchanged — skip
                try await ingestion.reIngest(sourceId: match.id!)
                try await MainActor.run {
                    try store.updateSourceSyncInfo(id: match.id!, lastSyncedAt: Date(), contentHash: hash)
                }
            } else {
                let src = try await ingestion.ingestFile(file, into: notebookId)
                try await MainActor.run {
                    try store.updateSourceSyncInfo(id: src.id!, lastSyncedAt: Date(), contentHash: hash)
                }
            }
            changed += 1
        }
        return changed
    }

    /// Re-crawls a web (or file) source and records the sync timestamp (E2).
    @discardableResult
    public func recrawl(sourceId: Int64) async throws -> Source {
        let src = try await ingestion.reIngest(sourceId: sourceId)
        let hash: String
        if let raw = src.rawPath, let h = try? Self.contentHash(of: URL(fileURLWithPath: raw)) {
            hash = h
        } else {
            hash = src.contentHash ?? ""
        }
        try await MainActor.run {
            try store.updateSourceSyncInfo(id: sourceId, lastSyncedAt: Date(), contentHash: hash)
        }
        return try await MainActor.run { try store.source(id: sourceId) } ?? src
    }
}
