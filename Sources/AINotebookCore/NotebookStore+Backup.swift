import Foundation
import GRDB

/// Whole-database backup and restore (Epic B, FR-B3). Uses GRDB's SQLite
/// online-backup API, which is WAL-safe and works even for an in-memory store,
/// so — unlike the Windows file-copy approach — restore happens in place and
/// needs no app relaunch.
extension NotebookStore {

    /// Copies the entire live database into a new SQLite file at `url`,
    /// overwriting any existing file there.
    public func backupDatabase(to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        let dest = try DatabaseQueue(path: url.path)
        try dbQueue.backup(to: dest)
    }

    /// Replaces the live database contents with those of the backup file at
    /// `url`, then refreshes the published notebook list. Destructive — the
    /// caller must confirm first (FR-B3 confirm dialog).
    public func restoreDatabase(from url: URL) throws {
        let source = try DatabaseQueue(path: url.path)
        try source.backup(to: dbQueue)
        try refresh()
    }
}
