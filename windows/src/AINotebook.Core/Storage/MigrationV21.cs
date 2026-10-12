namespace AINotebook.Core.Storage;

/// <summary>
/// Schema v21 — the per-source extraction failure budget (<c>ingestion-retry-cap-v1</c> §2). One table keyed by
/// source and no data (absent row = no failures, unknown content); shared identifier <c>v21_extract_retry_budget</c>
/// with macOS <c>MigrationV21</c>.
/// </summary>
internal static class MigrationV21
{
    internal const string Ddl = """
        CREATE TABLE source_extract_budget (
         source_id INTEGER PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
         failures INTEGER NOT NULL DEFAULT 0 CHECK(failures>=0),
         content_hash TEXT CHECK(content_hash IS NULL OR length(content_hash)>0)
        );
        """;
}
