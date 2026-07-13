import Foundation
import GRDB

/// Owns the SQLite database file and exposes synchronous CRUD operations
/// for notebooks. `@Published notebooks` drives the sidebar list — it is
/// refreshed from disk after every mutation.
///
/// `@MainActor` is correct here because GRDB queue reads/writes from this
/// type are short and the SwiftUI views consume the published list on the
/// main thread. Future high-throughput paths (e.g. embedding ingestion in
/// M4) will use GRDB's async APIs from background actors.
@MainActor
public final class NotebookStore: ObservableObject {
    let dbQueue: DatabaseQueue

    @Published public private(set) var notebooks: [Notebook] = []

    /// Set by the app layer (typically after NoteIndexer is wired). Fires
    /// on every createNote / updateNote with the affected note id.
    public var onNoteSaved: (@Sendable (Int64) async -> Void)?

    /// Fires after a note is deleted, with the deleted note's UUID. Used by
    /// the app layer to clean up attachment folders on disk.
    public var onNoteDeleted: (@Sendable (String) async -> Void)?

    public init(path: StorePath, language: AppLanguage = .english) throws {
        if let url = path.fileURL {
            self.dbQueue = try DatabaseQueue(path: url.path)
        } else {
            self.dbQueue = try DatabaseQueue()
        }
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
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try BuiltinTransformations.seedIfNeeded(db, language: language)
        }
        try refresh()
    }

    public func refresh() throws {
        notebooks = try dbQueue.read { db in
            try Notebook
                .order(Notebook.Columns.updatedAt.column.desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public func createNotebook(name: String, description: String = "") throws -> Notebook {
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
    public func renameNotebook(id: Int64, newName: String) throws -> Notebook {
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

    public func deleteNotebook(id: Int64) throws {
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
