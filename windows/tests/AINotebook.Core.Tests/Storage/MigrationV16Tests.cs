using AINotebook.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// v16 requalifies legacy raw `chunk_embeddings.model` keys left behind
/// because v11 seeded the provider registry but never requalified existing
/// rows (Windows-specific gap — macOS's MigrationV11 did the requalification
/// at the SAME migration that created the registry, so this problem never
/// existed there).
///
/// The harness stops at v16, then inserts historical model keys and re-runs
/// its unchanged data repair directly. It must never insert old-format vectors
/// into the generation-based v19 table.
/// </summary>
public class MigrationV16Tests
{
    private const string OllamaId = "00000000-0000-0000-0000-000000000000";

    private static readonly object Gate = new();

    private static SqliteConnection OpenMigrated()
    {
        var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        using (var pragma = conn.CreateCommand())
        {
            pragma.CommandText = "PRAGMA foreign_keys=ON";
            pragma.ExecuteNonQuery();
        }
        Migrator.MigrateThrough(conn, "v16_requalify_embedding_keys");
        return conn;
    }

    private static void Exec(SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static long SeedChunk(SqliteConnection c, string model)
    {
        Exec(c, "INSERT INTO notebooks(name,description,created_at,updated_at) VALUES('n','','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')");
        Exec(c, "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES(1,'text','t','ready','2026-01-01 00:00:00.000')");
        using var cmd = c.CreateCommand();
        cmd.CommandText = "INSERT INTO source_chunks(source_id,ord,text,token_count) VALUES(1,0,'x',1); SELECT last_insert_rowid();";
        var chunkId = (long)cmd.ExecuteScalar()!;
        using var ins = c.CreateCommand();
        ins.CommandText = "INSERT INTO chunk_embeddings(chunk_id,dim,model,embedding) VALUES($cid,4,$model,zeroblob(16))";
        ins.Parameters.AddWithValue("$cid", chunkId);
        ins.Parameters.AddWithValue("$model", model);
        ins.ExecuteNonQuery();
        return chunkId;
    }

    private static string ModelFor(SqliteConnection c, long chunkId)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT model FROM chunk_embeddings WHERE chunk_id = $id";
        cmd.Parameters.AddWithValue("$id", chunkId);
        return (string)cmd.ExecuteScalar()!;
    }

    [Fact]
    public void Raw_model_with_no_colon_gets_requalified_with_ollama_id()
    {
        lock (Gate)
        {
            using var c = OpenMigrated();
            var chunkId = SeedChunk(c, "nomic-embed-text");

            Migrator.RequalifyLegacyEmbeddingKeys(c);

            Assert.Equal($"{OllamaId}:nomic-embed-text", ModelFor(c, chunkId));
        }
    }

    [Fact]
    public void Raw_model_containing_a_colon_ollama_tag_still_gets_requalified()
    {
        lock (Gate)
        {
            // The central lesson (macOS MigrationV11): colon presence alone is
            // NOT a valid "already qualified" test. Ollama tags like
            // "llama3.2:3b" contain colons themselves and must still be
            // requalified, not skipped.
            using var c = OpenMigrated();
            var chunkId = SeedChunk(c, "llama3.2:3b");

            Migrator.RequalifyLegacyEmbeddingKeys(c);

            Assert.Equal($"{OllamaId}:llama3.2:3b", ModelFor(c, chunkId));
        }
    }

    [Fact]
    public void Existing_row_already_qualified_with_ollama_id_is_untouched()
    {
        lock (Gate)
        {
            using var c = OpenMigrated();
            var already = $"{OllamaId}:nomic-embed-text";
            var chunkId = SeedChunk(c, already);

            Migrator.RequalifyLegacyEmbeddingKeys(c);

            Assert.Equal(already, ModelFor(c, chunkId));
        }
    }

    [Fact]
    public void Composite_row_under_a_different_existing_provider_id_is_untouched()
    {
        lock (Gate)
        {
            using var c = OpenMigrated();
            const string otherProviderId = "11111111-1111-1111-1111-111111111111";
            Exec(c, $"""
                INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
                VALUES('{otherProviderId}', 'openai', 'OpenAI', 'https://api.openai.com', 1, 1, '2026-01-01 00:00:00.000')
                """);
            var already = $"{otherProviderId}:text-embedding-3-small";
            var chunkId = SeedChunk(c, already);

            Migrator.RequalifyLegacyEmbeddingKeys(c);

            Assert.Equal(already, ModelFor(c, chunkId));
        }
    }

    [Fact]
    public void Composite_row_under_a_deleted_provider_id_is_untouched()
    {
        lock (Gate)
        {
            // NotebookStore.DeleteProvider never cleans up chunk_embeddings, so a
            // composite row can be qualified under a provider GUID that no longer
            // exists in the providers table. The NOT EXISTS-against-providers
            // predicate alone would wrongly treat this as "unqualified" and
            // double-prefix it to "{ollamaId}:{deletedProviderId}:{model}". A
            // structural GUID-shape guard must catch this even though the
            // provider row is gone.
            using var c = OpenMigrated();
            const string deletedProviderId = "22222222-2222-2222-2222-222222222222";
            // Deliberately no INSERT INTO providers — simulates a provider that
            // was deleted after this row was written.
            var already = $"{deletedProviderId}:nomic-embed-text";
            var chunkId = SeedChunk(c, already);

            Migrator.RequalifyLegacyEmbeddingKeys(c);

            Assert.Equal(already, ModelFor(c, chunkId));
        }
    }
}
