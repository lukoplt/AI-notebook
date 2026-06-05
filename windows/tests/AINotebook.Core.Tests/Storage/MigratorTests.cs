using AINotebook.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class MigratorTests
{
    private static SqliteConnection OpenMigrated()
    {
        var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        using (var pragma = conn.CreateCommand())
        {
            pragma.CommandText = "PRAGMA foreign_keys=ON";
            pragma.ExecuteNonQuery();
        }
        Migrator.Migrate(conn);
        return conn;
    }

    private static List<string> Tables(SqliteConnection c, string type = "table")
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT name FROM sqlite_master WHERE type=$t ORDER BY name";
        cmd.Parameters.AddWithValue("$t", type);
        var list = new List<string>();
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add(r.GetString(0));
        return list;
    }

    private static List<string> Columns(SqliteConnection c, string table)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = $"SELECT name FROM pragma_table_info('{table}') ORDER BY name";
        var list = new List<string>();
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add(r.GetString(0));
        return list;
    }

    [Fact]
    public void TracksAllTenIdentifiersInOrder()
    {
        using var c = OpenMigrated();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT identifier FROM grdb_migrations ORDER BY rowid";
        var ids = new List<string>();
        using var r = cmd.ExecuteReader();
        while (r.Read()) ids.Add(r.GetString(0));
        Assert.Equal(new[]
        {
            "v1_notebooks", "v2_sources_and_chunks", "v3_chunk_embeddings",
            "v4_chat_sessions_and_messages", "v5_notes_and_transformations",
            "v6_notes_auto_source_and_uuid", "v7_attachments",
            "v8_note_versions", "v9_transformations_description",
            "v10_source_summary"
        }, ids);
    }

    [Fact]
    public void MigrateIsIdempotent()
    {
        using var c = OpenMigrated();
        Migrator.Migrate(c); // second run is a no-op
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT count(*) FROM grdb_migrations";
        Assert.Equal(10L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void V1_NotebooksColumnsSorted()
    {
        using var c = OpenMigrated();
        Assert.Contains("notebooks", Tables(c));
        Assert.Equal(
            new[] { "created_at", "description", "id", "name", "updated_at" },
            Columns(c, "notebooks"));
    }

    [Fact]
    public void V1_NameIndexExists()
    {
        using var c = OpenMigrated();
        Assert.Contains("notebooks_name_idx", Tables(c, "index"));
    }

    [Fact]
    public void V2_CreatesAllExpectedTablesAndIndexes()
    {
        using var c = OpenMigrated();
        var tables = Tables(c);
        Assert.Contains("sources", tables);
        Assert.Contains("source_chunks", tables);
        Assert.Contains("sources_fts", tables);
        Assert.Contains("chunks_fts", tables);
        var idx = Tables(c, "index");
        Assert.Contains("idx_sources_notebook", idx);
        Assert.Contains("idx_chunks_source", idx);
    }

    [Fact]
    public void V2_SourcesFtsKeepsInSyncWithSources()
    {
        using var c = OpenMigrated();
        using (var nb = c.CreateCommand())
        {
            nb.CommandText =
                "INSERT INTO notebooks(name,description,created_at,updated_at) VALUES('n','','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')";
            nb.ExecuteNonQuery();
        }
        using (var src = c.CreateCommand())
        {
            src.CommandText =
                "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES(1,'text','Hello world','pending','2026-01-01 00:00:00.000')";
            src.ExecuteNonQuery();
        }
        using var q = c.CreateCommand();
        q.CommandText = "SELECT count(*) FROM sources_fts WHERE sources_fts MATCH 'hello'";
        Assert.Equal(1L, (long)q.ExecuteScalar()!);
    }

    private static void SeedNotebook(SqliteConnection c) =>
        Exec(c, "INSERT INTO notebooks(name,description,created_at,updated_at) VALUES('n','','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')");

    private static void Exec(SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static long Count(SqliteConnection c, string table)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = $"SELECT count(*) FROM {table}";
        return (long)cmd.ExecuteScalar()!;
    }

    [Fact]
    public void V3_CreatesChunkEmbeddingsTable()
    {
        using var c = OpenMigrated();
        Assert.Contains("chunk_embeddings", Tables(c));
    }

    [Fact]
    public void V3_CascadeDeleteWhenSourceDeleted_RequiresForeignKeysOn()
    {
        using var c = OpenMigrated();
        SeedNotebook(c);
        Exec(c, "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES(1,'text','t','ready','2026-01-01 00:00:00.000')");
        Exec(c, "INSERT INTO source_chunks(source_id,ord,text,token_count) VALUES(1,0,'x',1)");
        Exec(c, "INSERT INTO chunk_embeddings(chunk_id,dim,model,embedding) VALUES(1,4,'m',zeroblob(16))");
        Exec(c, "DELETE FROM sources WHERE id=1");
        Assert.Equal(0L, Count(c, "source_chunks"));
        Assert.Equal(0L, Count(c, "chunk_embeddings"));
    }

    [Fact]
    public void V6_AddsColumnsToNotes()
    {
        using var c = OpenMigrated();
        var cols = Columns(c, "notes");
        Assert.Contains("auto_source_id", cols);
        Assert.Contains("note_uuid", cols);
    }

    [Fact]
    public void V7_AttachmentsCascadeOnNoteDelete()
    {
        using var c = OpenMigrated();
        SeedNotebook(c);
        Exec(c, "INSERT INTO notes(notebook_id,title,body_md,origin,note_uuid,created_at,updated_at) VALUES(1,'t','b','manual','11111111-1111-1111-1111-111111111111','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')");
        Exec(c, "INSERT INTO attachments(note_id,note_uuid,filename,mime,byte_size,created_at) VALUES(1,'11111111-1111-1111-1111-111111111111','a.png','image/png',3,'2026-01-01 00:00:00.000')");
        Exec(c, "DELETE FROM notes WHERE id=1");
        Assert.Equal(0L, Count(c, "attachments"));
    }

    [Fact]
    public void V8_NoteVersionsCascadeOnNoteDelete()
    {
        using var c = OpenMigrated();
        SeedNotebook(c);
        Exec(c, "INSERT INTO notes(notebook_id,title,body_md,origin,note_uuid,created_at,updated_at) VALUES(1,'t','b','manual','22222222-2222-2222-2222-222222222222','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')");
        Exec(c, "INSERT INTO note_versions(note_id,title,body_md,saved_at,reason) VALUES(1,'t','b','2026-01-01 00:00:00.000','autosave')");
        Exec(c, "DELETE FROM notes WHERE id=1");
        Assert.Equal(0L, Count(c, "note_versions"));
    }

    [Fact]
    public void V9_ExistingRowsGetEmptyStringDefault()
    {
        using var c = OpenMigrated();
        Exec(c, "INSERT INTO transformations(name,prompt_template,scope,is_builtin) VALUES('x','{{source_text}}','source',0)");
        Assert.Contains("description", Columns(c, "transformations"));
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT description FROM transformations WHERE name='x'";
        Assert.Equal("", (string)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void V10_AddsSummaryColumnToSources()
    {
        using var c = OpenMigrated();
        Assert.Contains("summary", Columns(c, "sources"));
    }

    [Fact]
    public void V10_ExistingRowsGetNullSummary()
    {
        using var c = OpenMigrated();
        SeedNotebook(c);
        Exec(c, "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES(1,'text','t','ready','2026-01-01 00:00:00.000')");
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT summary FROM sources WHERE id=1";
        Assert.IsType<DBNull>(cmd.ExecuteScalar());
    }
}
