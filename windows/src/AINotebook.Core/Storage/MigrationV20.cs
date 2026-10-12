namespace AINotebook.Core.Storage;

/// <summary>
/// Schema v20 — dedup ledger of every vector a build stores (<c>embedding-plan-v1</c> §5). Adds one table and no
/// data; shared identifier <c>v20_embedding_dedup</c> with macOS <c>MigrationV20</c>. Statements are separated by
/// the Migrator's "@@" marker.
/// </summary>
internal static class MigrationV20
{
    internal const string Ddl = """
        CREATE TABLE generation_text_hashes (
         generation_id INTEGER NOT NULL REFERENCES index_generations(id) ON DELETE CASCADE,
         chunk_id INTEGER NOT NULL REFERENCES source_chunks(id) ON DELETE CASCADE,
         text_hash TEXT NOT NULL CHECK(length(text_hash)=64),
         copied INTEGER NOT NULL CHECK(copied IN (0,1)),
         PRIMARY KEY(generation_id,chunk_id)
        ) WITHOUT ROWID;
        @@
        CREATE INDEX idx_generation_text_hashes_hash ON generation_text_hashes(generation_id,text_hash);
        @@
        CREATE INDEX idx_generation_text_hashes_chunk ON generation_text_hashes(chunk_id);
        @@
        CREATE INDEX idx_generation_text_hashes_copied ON generation_text_hashes(generation_id) WHERE copied=1;
        """;
}
