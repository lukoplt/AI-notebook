import Foundation
import GRDB

/// One-time upgrade of folders still on the pre-mail default include list to
/// the current `FolderRules.defaults.includeExts` (contract
/// `ingestion-formats-v1` §4, same rules as Windows `FolderDefaultsUpgrade`).
/// Runs on store open after the migrations; the marker row in
/// `grdb_migrations` makes it run once per database (unknown identifiers are
/// ignored by GRDB and the Windows migrator), so a user who later restores the
/// old list keeps it. Customized lists are never touched.
enum FolderDefaultsUpgrade {
    static let marker = "data_folder_include_exts_v2"
    static let oldDefault = ["pdf", "txt", "md", "markdown", "docx", "pptx", "xlsx"]
    static var added: [String] { FolderRules.defaults.includeExts.filter { !oldDefault.contains($0) } }

    /// True when `stored` is a permutation of the old default (same elements, same count).
    static func isOldDefault(_ stored: [String]) -> Bool { stored.sorted() == oldDefault.sorted() }

    /// Returns the notebook ids of upgraded folders, ascending by folder id.
    @discardableResult
    static func apply(_ db: Database, now: Int64) throws -> [Int64] {
        guard try db.tableExists("folder_sources") else { return [] }
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier=?)",
                                 arguments: [marker])! else { return [] }
        let encoded = String(decoding: try JSONEncoder().encode(FolderRules.defaults.includeExts), as: UTF8.self)
        let added = Set(self.added)
        var notebooks: [Int64] = []
        for row in try Row.fetchAll(db, sql: "SELECT id,notebook_id,include_exts,limits FROM folder_sources ORDER BY id") {
            let raw: String = row["include_exts"]
            guard let stored = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)), isOldDefault(stored) else { continue }
            let folderId: Int64 = row["id"]
            try db.execute(sql: "UPDATE folder_sources SET include_exts=? WHERE id=?", arguments: [encoded, folderId])
            if let limits = try? IngestionLimits(json: row["limits"]) {
                let items = try Row.fetchAll(db, sql: """
                    SELECT rel_path,size_bytes FROM scan_items
                    WHERE folder_id=? AND kind='skipped' AND skip_reason='unsupported_ext' ORDER BY rel_path
                    """, arguments: [folderId])
                for item in items {
                    let relPath: String = item["rel_path"]
                    guard let ext = FolderClassifier.extensionName(relPath), added.contains(ext) else { continue }
                    let size: Int64? = item["size_bytes"]
                    if let size, size > limits.fileBytes {
                        try db.execute(sql: "UPDATE scan_items SET skip_reason='over_limit' WHERE folder_id=? AND rel_path=?",
                                       arguments: [folderId, relPath])
                    } else {
                        try db.execute(sql: """
                            UPDATE scan_items SET kind='eligible',skip_reason=NULL WHERE folder_id=? AND rel_path=?
                            """, arguments: [folderId, relPath])
                    }
                }
            }
            // The scan turns newly included files into sources even though their mtime/size are unchanged.
            let queued = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='scan' AND target=? AND state='queued')
                """, arguments: ["folder:\(folderId)"])!
            if !queued {
                _ = try FolderIngestionSQL.enqueueDue(db, draft: IngestJobDraft(kind: "scan", target: "folder:\(folderId)",
                    targetRevision: nil, optionsJSON: #"{"verifyAll":false}"#), now: now)
            }
            notebooks.append(row["notebook_id"])
        }
        try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES(?)", arguments: [marker])
        return notebooks
    }
}
