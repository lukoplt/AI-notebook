import Foundation
import GRDB

/// One invalidation epoch is shared by all open stores for a WP3 database identity.
/// The lock protects the epoch and connection observations; callbacks never enter
/// SQLite, an actor, the query-pin registry, or the matrix cache while holding it.
internal final class RetrievalInvalidation: @unchecked Sendable {
    private final class WeakState {
        weak var value: RetrievalInvalidation?
        init(_ value: RetrievalInvalidation) { self.value = value }
    }

    private struct Observation {
        weak var database: Database?
        let dataVersion: Int64
        let totalChanges: Int64
    }

    /// A process-wide clock prevents a closed and reopened database from reusing
    /// an epoch that may still appear in a cached matrix key. Only live database
    /// connections or readers retain their per-database invalidation state.
    private final class EpochClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.withLock {
                precondition(value < UInt64.max, "Retrieval invalidation epoch exhausted")
                value += 1
                return value
            }
        }
    }

    @MainActor private static var states: [String: WeakState] = [:]
    private static let clock = EpochClock()

    private let lock = NSLock()
    private var epoch: UInt64
    /// Keys resident matrices (retrieval-resident-v1 §2). Renewed whenever a store opens the
    /// database, so a reopened or replaced file (backup restore) never inherits rows loaded
    /// under ids that its own AUTOINCREMENT sequences may hand out again.
    private var instance = UUID().uuidString
    var instanceId: String { lock.withLock { instance } }
    private var observations: [ObjectIdentifier: Observation] = [:]

    private init() {
        epoch = Self.clock.next()
    }

    @MainActor
    static func shared(databaseId: String) -> RetrievalInvalidation {
        if let existing = states[databaseId]?.value { return existing }
        states = states.filter { $0.value.value != nil }
        let state = RetrievalInvalidation()
        states[databaseId] = WeakState(state)
        return state
    }

    /// Installs connection-local hooks only. This never changes the durable schema.
    func install(on queue: any DatabaseWriter) throws {
        let retired = lock.withLock { () -> String in
            defer { instance = UUID().uuidString }
            return instance
        }
        Task { await VectorMatrixCache.shared.dropResidents(databaseInstance: retired) }
        try queue.write { db in
            db.add(function: DatabaseFunction("rag_retrieval_changed", argumentCount: 0, pure: false) { [self] _ in
                didChange()
                return nil
            })
            let tables = [
                "notebooks", "sources", "source_chunks", "source_revisions",
                "chunk_embeddings", "index_generations", "index_generation_manifest",
                "folder_sources", "source_set_members", "source_set_folders",
            ]
            for table in tables {
                for event in ["INSERT", "UPDATE", "DELETE"] {
                    // Every interpolated identifier comes from the fixed lists above.
                    try db.execute(sql: """
                        CREATE TEMP TRIGGER IF NOT EXISTS rag_\(table)_\(event.lowercased())
                        AFTER \(event) ON main.\(table)
                        BEGIN SELECT rag_retrieval_changed(); END;
                        """)
                }
            }
            _ = try observe(db: db)
        }
    }

    /// Call inside the connection's read transaction before cache access and after
    /// a fill. SQLite's data_version is connection-relative, so each connection
    /// has its own baseline; total_changes catches writes without an installed hook.
    func observe(db: Database) throws -> UInt64 {
        let dataVersion = try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0
        let totalChanges = try Int64.fetchOne(db, sql: "SELECT total_changes()") ?? 0
        let identity = ObjectIdentifier(db)
        return lock.withLock {
            if let previous = observations[identity], previous.database === db {
                if previous.dataVersion != dataVersion || previous.totalChanges != totalChanges {
                    epoch = Self.clock.next()
                }
            } else {
                // Weak identities avoid retaining closed connections and prevent a
                // newly allocated Database from inheriting a recycled object's sample.
                observations = observations.filter { $0.value.database != nil }
                // A new connection has no comparable data_version baseline. An
                // external commit may have occurred since another store's sample.
                epoch = Self.clock.next()
            }
            observations[identity] = Observation(database: db, dataVersion: dataVersion, totalChanges: totalChanges)
            return epoch
        }
    }

    /// Safe from any executor. In particular, cache admission uses this without SQL.
    func observedEpoch() -> UInt64 {
        lock.withLock { epoch }
    }

    private func didChange() {
        lock.withLock { epoch = Self.clock.next() }
    }
}
