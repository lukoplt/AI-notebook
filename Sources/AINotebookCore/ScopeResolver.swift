import Foundation
import GRDB

/// Nonisolated: the store's database methods and the query-pin registry are thread-safe.
public enum ScopeResolver {
    public static func resolve(store: NotebookStore, notebookId: Int64,
        scope: RetrievalScope, modelKey: String) throws -> ResolvedRetrievalScope? {
        guard !scope.isEmptySelection else { return nil }
        let captured = try store.withQueryPin(notebookId: notebookId, modelKey: modelKey) { db, pin in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id,s.folder_id,s.rel_path,s.title,s.mtime/1000000000 AS mtime_s FROM sources s
                WHERE \(RetrievalSQL.predicate) ORDER BY s.id
                """, arguments: RetrievalSQL.arguments(notebookId: notebookId, scope: scope))
            let sources = rows.map { row -> ScopedSource in
                let id: Int64 = row["id"]
                return ScopedSource(sourceId: id, folderId: row["folder_id"], relPath: row["rel_path"],
                    displayName: row["title"], publishedRevisionId: pin.lexicalRevisions[id], vectorRevisionId: pin.vectorRevisions[id],
                    mtime: row["mtime_s"])
            }
            let generation = try pin.generationId.flatMap { try GenerationSQL.generation(db, id: $0) }
            let epoch = try store.retrievalInvalidation.observe(db: db)
            // A building (partial) pin streams: every build write bumps the epoch, so an
            // admitted matrix would be stale at once (retrieval-partial-index-v1 §3).
            let key = generation.flatMap { $0.state == "building" ? nil : RetrievalCacheKey(
                databaseId: store.generationDatabaseIdentity, notebookId: notebookId, generationId: $0.id, epoch: epoch) }
            return (sources, generation, key)
        }
        return ResolvedRetrievalScope(store: store, pin: captured.pin, scope: scope,
            sources: captured.value.0, generation: captured.value.1, cacheKey: captured.value.2)
    }
}
