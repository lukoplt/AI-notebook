import Foundation
import GRDB

/// Owns the SQLite database file and exposes synchronous CRUD operations
/// for notebooks. `@Published notebooks` drives the sidebar list — it is
/// refreshed from disk after every mutation.
///
/// Database methods are nonisolated: GRDB serializes writes and runs every
/// read on a snapshot, so background workers (scan, extraction, embedding,
/// job queue) call the store directly from their own executors instead of
/// hopping to the main actor — a long background transaction never freezes
/// the UI, and with the WAL pool UI/chat reads never wait behind it
/// (`docs/contracts/chat-during-scan-v1.md`). Only the published notebook
/// list, the note hooks and change notifications are main-actor state;
/// notifications are always posted on the main thread.
public final class NotebookStore: ObservableObject, @unchecked Sendable {
    /// File stores use a WAL `DatabasePool`: reads (chat, status, UI) run on
    /// reader connections against a committed snapshot and never wait behind a
    /// background write transaction, and background writes never wait behind
    /// a long read (contract `chat-during-scan-v1`). In-memory stores keep a
    /// single serialized `DatabaseQueue` (WAL needs a file).
    let dbQueue: any DatabaseWriter
    let retrievalInvalidation: RetrievalInvalidation
    /// Coalesces per-batch indexing progress signals (see `notifyIndexingProgress`).
    let indexingProgress = IndexingProgressThrottle()

    @MainActor @Published public private(set) var notebooks: [Notebook] = []

    /// Set by the app layer (typically after NoteIndexer is wired). Fires
    /// on every createNote / updateNote with the affected note id.
    @MainActor public var onNoteSaved: (@Sendable (Int64) async -> Void)?

    /// Fires after a note is deleted, with the deleted note's UUID. Used by
    /// the app layer to clean up attachment folders on disk.
    @MainActor public var onNoteDeleted: (@Sendable (String) async -> Void)?

    @MainActor public init(path: StorePath, language: AppLanguage = .english,
                configuredEmbeddingModelKey: String? = DefaultsProviderSelection().embeddingKey()) throws {
        if let url = path.fileURL {
            self.dbQueue = try DatabasePool(path: url.path, configuration: Self.fileConfiguration())
        } else {
            self.dbQueue = try DatabaseQueue()
        }
        retrievalInvalidation = RetrievalInvalidation.shared(databaseId: Self.generationDatabaseIdentity(dbQueue))
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        registerMigrationV2(on: &migrator)
        registerMigrationV3(on: &migrator)
        registerMigrationV4(on: &migrator)
        registerMigrationV5(on: &migrator)
        registerMigrationV6(on: &migrator)
        registerMigrationV7(on: &migrator)
        registerMigrationV8(on: &migrator)
        registerMigrationV9(on: &migrator)
        registerMigrationV10(on: &migrator)
        registerMigrationV11(on: &migrator)
        registerMigrationV12(on: &migrator)
        registerMigrationV13(on: &migrator)
        registerMigrationV14(on: &migrator)
        registerMigrationV15(on: &migrator)
        registerMigrationV18(on: &migrator)
        registerMigrationV19(on: &migrator, configuredEmbeddingModelKey: configuredEmbeddingModelKey)
        registerMigrationV20(on: &migrator)
        registerMigrationV21(on: &migrator)
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try BuiltinTransformations.seedIfNeeded(db, language: language)
            try FolderDefaultsUpgrade.apply(db, now: Int64(Date().timeIntervalSince1970))
        }
        try retrievalInvalidation.install(on: dbQueue)
        try refresh()
    }

    /// WAL pool configuration. `journal_size_limit` truncates the -wal file back
    /// to 64 MiB after each checkpoint reset, so hours of background writes on a
    /// multi-GB database cannot leave a huge -wal behind; every read is short, so
    /// SQLite's automatic PASSIVE checkpoints keep resetting it.
    static func fileConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA journal_size_limit = \(walSizeLimitBytes)")
            }
        }
        return configuration
    }

    /// Upper bound the -wal file is truncated to after a checkpoint.
    static let walSizeLimitBytes = 67_108_864

    @MainActor public func refresh() throws {
        notebooks = try dbQueue.read { db in
            try Notebook
                .order(Notebook.Columns.updatedAt.column.desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    @MainActor public func createNotebook(name: String, description: String = "") throws -> Notebook {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidNotebookName(name)
        }
        let now = Date()
        var notebook = Notebook(
            name: trimmed,
            description: description,
            createdAt: now,
            updatedAt: now
        )
        try dbQueue.write { db in
            try notebook.insert(db)
        }
        try refresh()
        return notebook
    }

    @discardableResult
    @MainActor public func renameNotebook(id: Int64, newName: String) throws -> Notebook {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidNotebookName(newName)
        }
        let updated = try dbQueue.write { db -> Notebook in
            guard var existing = try Notebook.fetchOne(db, key: id) else {
                throw StoreError.notebookNotFound(id: id)
            }
            existing.name = trimmed
            existing.updatedAt = Date()
            try existing.update(db)
            return existing
        }
        try refresh()
        return updated
    }

    @MainActor public func deleteNotebook(id: Int64) throws {
        let deleted = try dbQueue.write { db in
            try Notebook.deleteOne(db, key: id)
        }
        guard deleted else {
            throw StoreError.notebookNotFound(id: id)
        }
        try refresh()
    }

    /// Test affordance: run a closure on the underlying DB. Production callers
    /// must use the typed CRUD methods.
    public func runOnDatabase<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
}

/// Runs synchronous store work on the caller's executor. Background workers
/// (job queue, scanner, extraction, embedding, runtime, reconciler) use this
/// instead of `MainActor.run`: the store's database methods are nonisolated,
/// so a long background transaction never occupies the main thread.
@inline(__always)
func storeWork<T>(_ body: () throws -> T) rethrows -> T { try body() }
