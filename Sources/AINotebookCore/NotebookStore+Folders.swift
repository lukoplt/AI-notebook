import Foundation
import GRDB

extension NotebookStore {
    public func createFolder(notebookId: Int64, draft: FolderDraft,
                             identity: any FolderPathIdentity, now: Int64) throws -> FolderSource {
        try FolderSQL.validate(draft)
        let resolved = try identity.resolve(rootPath: draft.rootPath)
        return try dbQueue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else {
                throw StorageV19Error.notFound
            }
            try FolderSQL.checkOverlap(db, notebookId: notebookId, identity: resolved, excluding: nil)
            try db.execute(sql: """
                INSERT INTO folder_sources(notebook_id,root_path,path_identity,display_name,include_exts,
                    ignore_globs,limits,encoding_fallback,watch_enabled,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)
                """, arguments: [notebookId, draft.rootPath, try FolderSQL.json(resolved), draft.displayName,
                                  try FolderSQL.json(draft.includeExts), try FolderSQL.json(draft.ignoreGlobs),
                                  draft.limitsJSON, draft.encodingFallback, draft.watchEnabled, Date(timeIntervalSince1970: TimeInterval(now))])
            return try FolderSQL.folder(db, id: db.lastInsertedRowID)
        }
    }

    public func folders(notebookId: Int64) throws -> [FolderSource] {
        try dbQueue.read { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else {
                throw StorageV19Error.notFound
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM folder_sources WHERE notebook_id=? ORDER BY id", arguments: [notebookId]).map(FolderSQL.decode)
        }
    }

    public func updateFolder(id: Int64, draft: FolderDraft, identity: any FolderPathIdentity) throws {
        try FolderSQL.validate(draft)
        let previous = try dbQueue.read { try FolderSQL.folder($0, id: id) }
        let rootChanged = !previous.draft.rootPath.utf8.elementsEqual(draft.rootPath.utf8)
        let resolved = rootChanged ? try identity.resolve(rootPath: draft.rootPath) : previous.identity
        try dbQueue.write { db in
            let old = try FolderSQL.folder(db, id: id)
            // A second connection must not change the root between resolution and write.
            guard old.draft.rootPath.utf8.elementsEqual(previous.draft.rootPath.utf8) else {
                throw StorageV19Error.invalidValue
            }
            if rootChanged {
                let hasMembers = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM sources WHERE folder_id=?) OR EXISTS(SELECT 1 FROM scan_items WHERE folder_id=?)
                    """, arguments: [id, id])!
                guard !hasMembers else { throw StorageV19Error.invalidValue }
            }
            try FolderSQL.checkOverlap(db, notebookId: old.notebookId, identity: resolved, excluding: id)
            try db.execute(sql: """
                UPDATE folder_sources SET root_path=?,path_identity=?,display_name=?,include_exts=?,
                    ignore_globs=?,limits=?,encoding_fallback=?,watch_enabled=? WHERE id=?
                """, arguments: [draft.rootPath, try FolderSQL.json(resolved), draft.displayName,
                                  try FolderSQL.json(draft.includeExts), try FolderSQL.json(draft.ignoreGlobs),
                                  draft.limitsJSON, draft.encodingFallback, draft.watchEnabled, id])
        }
    }

    /// Only catalog rows are removed; this API has no filesystem mutation capability.
    public func deleteFolder(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM folder_sources WHERE id=?", arguments: [id])
            guard db.changesCount == 1 else { throw StorageV19Error.notFound }
        }
    }

    public func upsertScanItems(folderId: Int64, items: [ScanItem]) throws {
        try dbQueue.write { db in
            _ = try FolderSQL.folder(db, id: folderId)
            for item in items {
                guard item.folderId == folderId else { throw StorageV19Error.invalidValue }
                try FolderSQL.validatePath(item.relPath)
                guard item.seenGeneration >= 0, item.sizeBytes.map({ $0 >= 0 }) ?? true,
                      (item.kind == "eligible" && item.skipReason == nil) ||
                      (item.kind == "skipped" && ["ignored", "unsupported_ext", "over_limit"].contains(item.skipReason ?? "")) else {
                    throw StorageV19Error.invalidValue
                }
            }
            let statement = try db.makeStatement(sql: """
                INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
                VALUES(?,?,?,?,?,?,?) ON CONFLICT(folder_id,rel_path) DO UPDATE SET kind=excluded.kind,
                skip_reason=excluded.skip_reason,mtime=excluded.mtime,size_bytes=excluded.size_bytes,seen_generation=excluded.seen_generation
                """)
            for item in items {
                try statement.execute(arguments: [item.folderId, item.relPath, item.kind, item.skipReason,
                                                   item.mtime, item.sizeBytes, item.seenGeneration])
            }
        }
    }

    public func scanItems(folderId: Int64) throws -> [ScanItem] {
        try dbQueue.read { db in
            _ = try FolderSQL.folder(db, id: folderId)
            return try Row.fetchAll(db, sql: "SELECT * FROM scan_items WHERE folder_id=? ORDER BY rel_path", arguments: [folderId]).map {
                ScanItem(folderId: $0["folder_id"], relPath: $0["rel_path"], kind: $0["kind"], skipReason: $0["skip_reason"],
                         mtime: $0["mtime"], sizeBytes: $0["size_bytes"], seenGeneration: $0["seen_generation"])
            }
        }
    }

    public func attachSource(sourceId: Int64, folderId: Int64, relPath: String) throws {
        try FolderSQL.validatePath(relPath)
        try dbQueue.write { db in
            let folder = try FolderSQL.folder(db, id: folderId)
            guard let owner = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM sources WHERE id=?", arguments: [sourceId]) else {
                throw StorageV19Error.notFound
            }
            guard owner == folder.notebookId else { throw StorageV19Error.notebookMismatch }
            try db.execute(sql: "UPDATE sources SET folder_id=?,rel_path=? WHERE id=?", arguments: [folderId, relPath, sourceId])
        }
    }

    public func setSourceSetFolders(setId: Int64, folderIds: [Int64]) throws {
        try dbQueue.write { db in
            guard let owner = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM source_sets WHERE id=?", arguments: [setId]) else {
                throw StorageV19Error.notFound
            }
            for id in folderIds {
                guard try FolderSQL.folder(db, id: id).notebookId == owner else { throw StorageV19Error.notebookMismatch }
            }
            try db.execute(sql: "DELETE FROM source_set_folders WHERE set_id=?", arguments: [setId])
            for id in Set(folderIds).sorted() {
                try db.execute(sql: "INSERT INTO source_set_folders(set_id,folder_id) VALUES(?,?)", arguments: [setId, id])
            }
        }
    }

    public func sourceSetFolders(setId: Int64) throws -> [Int64] {
        try dbQueue.read { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM source_sets WHERE id=?", arguments: [setId]) != nil else { throw StorageV19Error.notFound }
            return try Int64.fetchAll(db, sql: "SELECT folder_id FROM source_set_folders WHERE set_id=? ORDER BY folder_id", arguments: [setId])
        }
    }
}

private enum FolderSQL {
    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func validate(_ draft: FolderDraft) throws {
        guard !draft.rootPath.isEmpty, !draft.rootPath.contains("\0"),
              !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["cp1250", "none"].contains(draft.encodingFallback),
              let object = try? JSONSerialization.jsonObject(with: Data(draft.limitsJSON.utf8)),
              object is [String: Any] else { throw StorageV19Error.invalidValue }
    }

    static func validatePath(_ path: String) throws {
        let bytes = Array(path.utf8)
        let drive = bytes.count >= 2 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])) && bytes[1] == 58
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"), !drive,
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StorageV19Error.invalidPath
        }
    }

    static func folder(_ db: Database, id: Int64) throws -> FolderSource {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM folder_sources WHERE id=?", arguments: [id]) else { throw StorageV19Error.notFound }
        return try decode(row)
    }

    static func decode(_ row: Row) throws -> FolderSource {
        let decoder = JSONDecoder()
        let identity: String = row["path_identity"], includes: String = row["include_exts"], ignores: String = row["ignore_globs"]
        let date: Date = row["created_at"]
        return FolderSource(id: row["id"], notebookId: row["notebook_id"], draft: FolderDraft(
            rootPath: row["root_path"], displayName: row["display_name"],
            includeExts: try decoder.decode([String].self, from: Data(includes.utf8)),
            ignoreGlobs: try decoder.decode([String].self, from: Data(ignores.utf8)), limitsJSON: row["limits"],
            encodingFallback: row["encoding_fallback"], watchEnabled: row["watch_enabled"]),
            identity: try decoder.decode(FolderIdentity.self, from: Data(identity.utf8)),
            scanState: row["scan_state"], scanGeneration: row["scan_generation"], lastFullScanAt: row["last_full_scan_at"],
            lastScanError: row["last_scan_error"], createdAt: Int64(date.timeIntervalSince1970))
    }

    static func checkOverlap(_ db: Database, notebookId: Int64, identity: FolderIdentity, excluding: Int64?) throws {
        for row in try Row.fetchAll(db, sql: "SELECT * FROM folder_sources WHERE notebook_id=? AND id IS NOT ?", arguments: [notebookId, excluding]) {
            let other = try decode(row).identity
            guard other.volumeId.utf8.elementsEqual(identity.volumeId.utf8) else { continue }
            let count = min(other.components.count, identity.components.count)
            if zip(other.components.prefix(count), identity.components.prefix(count)).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) {
                throw StorageV19Error.overlappingRoot
            }
        }
    }
}
