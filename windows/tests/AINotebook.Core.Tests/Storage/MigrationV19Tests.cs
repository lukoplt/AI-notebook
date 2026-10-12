using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class MigrationV19Tests
{
    [Fact]
    public void HandoffSchemaHasImmutableRevisionPagesAndDurableJobOptions()
    {
        using var store = V19TestStore.Create();
        lock (store.Gate)
        {
            Assert.Equal(new[] { "revision_id", "page", "char_start", "char_end" },
                store.Connection.Query<string>("SELECT name FROM pragma_table_info('revision_pages') ORDER BY cid").ToArray());
            Assert.Equal("revision_pages", store.Connection.ExecuteScalar<string>(
                "SELECT tbl_name FROM sqlite_master WHERE type='trigger' AND name='revision_pages_no_update'"));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>(
                "SELECT \"notnull\" FROM pragma_table_info('ingest_jobs') WHERE name='next_retry_at'"));
            Assert.Equal("'{}'", store.Connection.ExecuteScalar<string>(
                "SELECT dflt_value FROM pragma_table_info('ingest_jobs') WHERE name='options_json' AND type='TEXT' AND \"notnull\"=1"));
            store.Connection.Execute("INSERT INTO ingest_jobs(kind,target) VALUES('scan','folder:1')");
            Assert.Equal("{}", store.Connection.ExecuteScalar<string>("SELECT options_json FROM ingest_jobs"));
            Assert.Throws<SqliteException>(() => store.Connection.Execute(
                "INSERT INTO ingest_jobs(kind,target,options_json) VALUES('scan','folder:1',NULL)"));
        }
    }

    [Fact]
    public void SharedV18Upgrade()
    {
        var root = SharedFixtures.Json("contracts/storage-v19.json");
        Assert.NotEmpty(root.GetProperty("cases").EnumerateArray());
        foreach (var c in root.GetProperty("cases").EnumerateArray())
        {
            var key = c.GetProperty("configuredModelKey").GetString();
            var (store, directory, report) = V19TestStore.UpgradeCopy(key);
            try
            {
                var expectedDrops = c.GetProperty("droppedMalformedByNotebook").EnumerateObject()
                    .ToDictionary(p => long.Parse(p.Name), p => p.Value.GetInt32());
                Assert.Equal(expectedDrops.OrderBy(p => p.Key), report.DroppedMalformedByNotebook.OrderBy(p => p.Key));
                V19TestStore.AssertQueries(store, c.GetProperty("queries"));
                lock (store.Gate)
                {
                    Assert.Empty(store.Connection.Query("PRAGMA foreign_key_check"));
                    Assert.Equal("ok", store.Connection.ExecuteScalar<string>("PRAGMA integrity_check"));
                }
            }
            finally { store.Dispose(); Directory.Delete(directory, recursive: true); }
        }
    }

    [Fact]
    public void FTSMirrorsAndImmutability()
    {
        var fixture = SharedFixtures.Json("contracts/storage-v19.json").GetProperty("cases")[0];
        var (store, directory, _) = V19TestStore.UpgradeCopy(fixture.GetProperty("configuredModelKey").GetString());
        try
        {
            // Includes the accent-removal and no-Porter-stemming expectations for both FTS tables.
            V19TestStore.AssertQueries(store, fixture.GetProperty("queries"));
            lock (store.Gate)
            {
                var connection = store.Connection;
                var notesSchema = connection.Query<string>(
                    "SELECT sql FROM sqlite_master WHERE name='notes_fts' OR (type='trigger' AND tbl_name='notes') ORDER BY name").ToArray();
                var notesRows = connection.Query<string>(
                    "SELECT quote(rowid)||'|'||quote(title)||'|'||quote(body_md)||'|'||quote(note_id) FROM notes_fts ORDER BY rowid").ToArray();
                string original = connection.ExecuteScalar<string>("SELECT text FROM source_chunks WHERE id=1101")!;
                string replacement = connection.ExecuteScalar<string>("SELECT text FROM source_chunks WHERE id=1102")!;

                connection.Execute("""
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at)
                    SELECT 9001,notebook_id,type,title,status,ingested_at FROM sources WHERE id=101;
                    """);
                Assert.Equal(original, connection.ExecuteScalar<string>("SELECT title FROM sources_fts WHERE rowid=9001"));
                Assert.Contains(9001L, connection.Query<long>("SELECT source_id FROM sources_fts WHERE sources_fts MATCH 'prilis'").ToArray());
                connection.Execute("UPDATE sources SET title=$text WHERE id=9001", new { text = replacement });
                Assert.Equal(replacement, connection.ExecuteScalar<string>("SELECT title FROM sources_fts WHERE rowid=9001"));
                Assert.DoesNotContain(9001L, connection.Query<long>("SELECT source_id FROM sources_fts WHERE sources_fts MATCH 'prilis'").ToArray());

                long revision = connection.ExecuteScalar<long>("""
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    SELECT 9001,1,content_hash,canonical_text,text_format_version,chunker_version,created_at
                    FROM source_revisions WHERE source_id=101;
                    SELECT last_insert_rowid();
                    """);
                connection.Execute("""
                    INSERT INTO source_chunks(id,source_id,ord,text,token_count,page_hint,context,revision_id)
                    SELECT 9001,9001,0,text,token_count,page_hint,context,$revision FROM source_chunks WHERE id=1101;
                    """, new { revision });
                Assert.Equal(original, connection.ExecuteScalar<string>("SELECT text FROM chunks_fts WHERE rowid=9001"));
                Assert.Contains(9001L, connection.Query<long>("SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'prilis'").ToArray());

                // Every frozen column rejects an update, including an assignment of its existing value.
                foreach (string column in new[] { "source_id", "ord", "text", "token_count", "page_hint", "revision_id", "char_start", "char_end", "lang", "lang_inherited" })
                    Assert.Throws<SqliteException>(() => connection.Execute($"UPDATE source_chunks SET {column}={column} WHERE id=9001"));
                Assert.Throws<SqliteException>(() => connection.Execute(
                    "UPDATE source_revisions SET canonical_text=$text WHERE id=$revision", new { text = replacement, revision }));
                connection.Execute("UPDATE source_chunks SET context=$text WHERE id=9001", new { text = replacement });
                Assert.Equal(replacement, connection.ExecuteScalar<string>("SELECT context FROM source_chunks WHERE id=9001"));
                Assert.Equal(original, connection.ExecuteScalar<string>("SELECT text FROM chunks_fts WHERE rowid=9001"));

                using (var transaction = connection.BeginTransaction())
                {
                    connection.Execute("DROP TRIGGER chunks_immutable", transaction: transaction);
                    connection.Execute("UPDATE source_chunks SET text=$text WHERE id=9001", new { text = replacement }, transaction);
                    Assert.Equal(replacement, connection.ExecuteScalar<string>("SELECT text FROM chunks_fts WHERE rowid=9001", transaction: transaction));
                    Assert.DoesNotContain(9001L, connection.Query<long>(
                        "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'prilis'", transaction: transaction).ToArray());
                    transaction.Rollback();
                }
                Assert.Equal(original, connection.ExecuteScalar<string>("SELECT text FROM chunks_fts WHERE rowid=9001"));
                Assert.Throws<SqliteException>(() => connection.Execute(
                    "UPDATE source_chunks SET text=$text WHERE id=9001", new { text = replacement }));
                connection.Execute("DELETE FROM source_chunks WHERE id=9001");
                Assert.Equal(0, connection.ExecuteScalar<int>("SELECT count(*) FROM chunks_fts WHERE rowid=9001"));
                connection.Execute("DELETE FROM sources WHERE id=9001");
                Assert.Equal(0, connection.ExecuteScalar<int>("SELECT count(*) FROM sources_fts WHERE rowid=9001"));
                Assert.Equal(notesSchema, connection.Query<string>(
                    "SELECT sql FROM sqlite_master WHERE name='notes_fts' OR (type='trigger' AND tbl_name='notes') ORDER BY name").ToArray());
                Assert.Equal(notesRows, connection.Query<string>(
                    "SELECT quote(rowid)||'|'||quote(title)||'|'||quote(body_md)||'|'||quote(note_id) FROM notes_fts ORDER BY rowid").ToArray());
            }
            V19TestStore.AssertQueries(store, fixture.GetProperty("queries"));
        }
        finally { store.Dispose(); Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void UpgradeRollback()
    {
        foreach (string corruption in new[]
        {
            "INSERT INTO source_chunks(id,source_id,ord,text,token_count) VALUES(99999,99999,0,'orphan',1)",
            "INSERT INTO chunk_embeddings(chunk_id,dim,model,embedding) VALUES(99998,2,'orphan-key',X'0000803F00000000')"
        })
        {
        string directory = Path.Combine(Path.GetTempPath(), $"ainotebook-v19-rollback-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "db.sqlite");
        File.Copy(SharedFixtures.Path("storage/v18.sqlite"), path);
        try
        {
            var gate = new object();
            lock (gate)
            {
                using var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
                connection.Open();
                connection.Execute("PRAGMA foreign_keys=ON");
                V19TestStore.MigrateV18(connection);
                connection.Execute("PRAGMA foreign_keys=OFF");
                connection.Execute(corruption);
                connection.Execute("PRAGMA foreign_keys=ON");
                Assert.Equal(1, connection.ExecuteScalar<int>("PRAGMA foreign_keys"));

                const string vectorSql = "SELECT quote(chunk_id)||'|'||quote(dim)||'|'||quote(model)||'|'||hex(embedding) FROM chunk_embeddings ORDER BY chunk_id,model";
                string[] vectors = connection.Query<string>(vectorSql).ToArray();
                string[] columns = connection.Query<string>("SELECT name FROM pragma_table_info('chunk_embeddings') ORDER BY cid").ToArray();
                string[] citations = connection.Query<string>("SELECT citations_json FROM messages ORDER BY id").ToArray();
                string[] oldSchema = connection.Query<string>("SELECT sql FROM sqlite_master WHERE name IN ('sources','source_chunks','sources_fts','chunks_fts','notes_fts') ORDER BY name").ToArray();
                string[] markers = connection.Query<string>("SELECT identifier FROM grdb_migrations ORDER BY identifier").ToArray();
                Assert.NotEmpty(vectors);
                Assert.NotEmpty(citations);

                Assert.ThrowsAny<Exception>(() =>
                {
                    using var transaction = connection.BeginTransaction();
                    MigrationV19.Apply(connection, transaction, null);
                    connection.Execute("INSERT INTO grdb_migrations(identifier) VALUES('v19_folder_rag')", transaction: transaction);
                    transaction.Commit();
                });

                Assert.Equal(markers, connection.Query<string>("SELECT identifier FROM grdb_migrations ORDER BY identifier").ToArray());
                Assert.Equal(0, connection.ExecuteScalar<int>("SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'"));
                Assert.Equal(0, connection.ExecuteScalar<int>("""
                    SELECT count(*) FROM sqlite_master WHERE name IN
                    ('folder_sources','scan_items','source_revisions','revision_pages','revision_pages_no_update','source_set_folders','ingest_jobs',
                     'provider_model_limits','index_generations','index_generation_manifest','chunk_embeddings_v18')
                    """));
                Assert.Equal(columns, connection.Query<string>("SELECT name FROM pragma_table_info('chunk_embeddings') ORDER BY cid").ToArray());
                Assert.Equal(vectors, connection.Query<string>(vectorSql).ToArray());
                Assert.Equal(citations, connection.Query<string>("SELECT citations_json FROM messages ORDER BY id").ToArray());
                Assert.Equal(oldSchema, connection.Query<string>("SELECT sql FROM sqlite_master WHERE name IN ('sources','source_chunks','sources_fts','chunks_fts','notes_fts') ORDER BY name").ToArray());
                Assert.Single(connection.Query("PRAGMA foreign_key_check").ToArray());
            }
        }
        finally { Directory.Delete(directory, recursive: true); }
        }
    }

    [Fact]
    public void ReopenAndCitationPersistence()
    {
        var citationCase = SharedFixtures.Json("contracts/storage-integration-v1.json").GetProperty("cases")
            .EnumerateArray().Single(c => c.GetProperty("name").GetString() == "citation-after-gc");
        var storedCitation = citationCase.GetProperty("citation");
        var snapshot = Assert.Single(CitationsCodec.Decode($"[{storedCitation.GetRawText()}]"));
        foreach (var fixture in SharedFixtures.Json("contracts/storage-v19.json").GetProperty("cases").EnumerateArray())
        {
            string? key = fixture.GetProperty("configuredModelKey").GetString();
            var (store, directory, _) = V19TestStore.UpgradeCopy(key);
            try
            {
                store.Dispose();
                store = V19TestStore.Reopen(directory, key);
                V19TestStore.AssertQueries(store, fixture.GetProperty("queries"));
                var legacy = store.Messages(31).Single(message => message.Id == 41);
                var legacyCitation = Assert.Single(legacy.Citations);
                var rawQuery = fixture.GetProperty("queries").EnumerateArray().Single(q => q.GetProperty("name").GetString() == "citation-raw-bytes");
                string rawLegacy = rawQuery.GetProperty("rows")[0][1].GetString()!;
                using var legacyJson = JsonDocument.Parse(rawLegacy);
                var expectedLegacy = legacyJson.RootElement[0];
                Assert.Equal(expectedLegacy.GetProperty("marker").GetInt32(), legacyCitation.Marker);
                Assert.Equal(expectedLegacy.GetProperty("chunkId").GetInt64(), legacyCitation.ChunkId);
                Assert.Equal(expectedLegacy.GetProperty("sourceId").GetInt64(), legacyCitation.SourceId);
                Assert.Equal(expectedLegacy.GetProperty("snippet").GetString(), legacyCitation.Snippet);
                Assert.False(legacyCitation.IsV2);

                long revision;
                lock (store.Gate)
                    revision = store.Connection.ExecuteScalar<long>("SELECT published_revision_id FROM sources WHERE id=$id", new { id = legacyCitation.SourceId });
                var citation = snapshot with
                {
                    SourceId = legacyCitation.SourceId, ChunkId = legacyCitation.ChunkId,
                    RevisionId = revision, ChunkIds = new[] { legacyCitation.ChunkId }
                };
                store.AppendMessage(new ChatMessage(null, legacy.SessionId, ChatRole.Assistant,
                    "snapshot", new[] { citation }, legacy.CreatedAt.AddSeconds(1)));
                store.Dispose();
                store = V19TestStore.Reopen(directory, key);
                V19TestStore.AssertQueries(store, fixture.GetProperty("queries"));
                var reopened = Assert.Single(store.Messages(legacy.SessionId).Single(m => m.Content == "snapshot").Citations);
                Assert.True(reopened.IsV2);
                Assert.Equal(citationCase.GetProperty("expected").GetProperty("text").GetString(), reopened.Text);
                Assert.Equal(citation.Spans, reopened.Spans);
                Assert.Equal(citation.RevisionId, reopened.RevisionId);
                Assert.Equal(citation.ChunkIds, reopened.ChunkIds);
                store.DeleteSource(legacyCitation.SourceId);
                store.Dispose();
                store = V19TestStore.Reopen(directory, key);
                Assert.Null(store.Source(legacyCitation.SourceId));
                var afterDeletion = Assert.Single(store.Messages(legacy.SessionId).Single(m => m.Content == "snapshot").Citations);
                Assert.Equal(citation.Text, afterDeletion.Text);
                Assert.Equal(citation.Spans, afterDeletion.Spans);
                Assert.Equal(citation.RevisionId, afterDeletion.RevisionId);
                Assert.Equal(citation.ChunkIds, afterDeletion.ChunkIds);
                Assert.Equal(legacyCitation, Assert.Single(store.Messages(legacy.SessionId).Single(m => m.Id == legacy.Id).Citations));
                lock (store.Gate)
                {
                    Assert.Equal(rawLegacy, store.Connection.ExecuteScalar<string>("SELECT citations_json FROM messages WHERE id=41"));
                    Assert.Equal(1, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'"));
                    Assert.Empty(store.Connection.Query("PRAGMA foreign_key_check"));
                }
            }
            finally { store.Dispose(); Directory.Delete(directory, recursive: true); }
        }
    }
}
