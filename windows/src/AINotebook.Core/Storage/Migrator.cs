using System.Globalization;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Runs the 10 versioned migrations, tracked by identifier string in
/// grdb_migrations(identifier TEXT PK) — faithful to GRDB DatabaseMigrator.
/// DDL is verbatim from the live production DB schema.
/// </summary>
public static class Migrator
{
    private static readonly (string Id, string Sql)[] Migrations =
    {
        ("v1_notebooks", V1),
        ("v2_sources_and_chunks", V2),
        ("v3_chunk_embeddings", V3),
        ("v4_chat_sessions_and_messages", V4),
        ("v5_notes_and_transformations", V5),
        ("v6_notes_auto_source_and_uuid", V6),
        ("v7_attachments", V7),
        ("v8_note_versions", V8),
        ("v9_transformations_description", V9),
        ("v10_source_summary", V10),
        ("v11_providers", V11),
        ("v12_tags_and_notes_fts", V12),
        ("v13_instructions_and_sourcesets", V13),
        ("v14_chunk_context", V14),
        ("v15_live_sources", V15),
    };

    public static void Migrate(SqliteConnection conn)
    {
        EnsureTrackingTable(conn);
        var applied = AppliedIdentifiers(conn);
        foreach (var (id, sql) in Migrations)
        {
            if (applied.Contains(id)) continue;
            using var tx = conn.BeginTransaction();
            foreach (var stmt in SplitStatements(sql))
            {
                using var cmd = conn.CreateCommand();
                cmd.Transaction = tx;
                cmd.CommandText = stmt;
                cmd.ExecuteNonQuery();
            }
            RunCustom(conn, tx, id);
            using (var ins = conn.CreateCommand())
            {
                ins.Transaction = tx;
                ins.CommandText = "INSERT INTO grdb_migrations(identifier) VALUES($id)";
                ins.Parameters.AddWithValue("$id", id);
                ins.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }

    private static void EnsureTrackingTable(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)";
        cmd.ExecuteNonQuery();
    }

    private static HashSet<string> AppliedIdentifiers(SqliteConnection conn)
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT identifier FROM grdb_migrations";
        using var r = cmd.ExecuteReader();
        while (r.Read()) set.Add(r.GetString(0));
        return set;
    }

    /// <summary>
    /// Splits a migration body into individual statements on the literal
    /// "@@" separator we use between DDL statements (so CREATE TRIGGER bodies
    /// with embedded ';' are not broken apart).
    /// </summary>
    private static IEnumerable<string> SplitStatements(string sql)
    {
        foreach (var part in sql.Split("@@", StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = part.Trim();
            if (trimmed.Length > 0) yield return trimmed;
        }
    }

    /// <summary>v6 backfills note_uuid; v11 seeds the default Ollama provider.</summary>
    private static void RunCustom(SqliteConnection conn, SqliteTransaction tx, string id)
    {
        if (id == "v6_notes_auto_source_and_uuid")
        {
            var ids = new List<long>();
            using (var sel = conn.CreateCommand())
            {
                sel.Transaction = tx;
                sel.CommandText = "SELECT id FROM notes WHERE note_uuid IS NULL";
                using var r = sel.ExecuteReader();
                while (r.Read()) ids.Add(r.GetInt64(0));
            }
            foreach (var noteId in ids)
            {
                using var upd = conn.CreateCommand();
                upd.Transaction = tx;
                upd.CommandText = "UPDATE notes SET note_uuid = $u WHERE id = $id";
                upd.Parameters.AddWithValue("$u", Guid.NewGuid().ToString().ToLowerInvariant());
                upd.Parameters.AddWithValue("$id", noteId);
                upd.ExecuteNonQuery();
            }
        }
        else if (id == "v12_tags_and_notes_fts")
        {
            // Backfill notes_fts for all existing notes
            using var ins = conn.CreateCommand();
            ins.Transaction = tx;
            ins.CommandText = "INSERT INTO notes_fts(rowid, title, body_md, note_id) SELECT id, title, body_md, id FROM notes";
            ins.ExecuteNonQuery();
        }
        else if (id == "v11_providers")
        {
            // Seed the built-in Ollama provider with the well-known fixed ID.
            using var ins = conn.CreateCommand();
            ins.Transaction = tx;
            ins.CommandText = """
                INSERT OR IGNORE INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
                VALUES($id, 'ollama', 'Ollama (local)', 'http://127.0.0.1:11434', 1, 1, $now)
                """;
            ins.Parameters.AddWithValue("$id", "00000000-0000-0000-0000-000000000000");
            ins.Parameters.AddWithValue("$now", DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture));
            ins.ExecuteNonQuery();
        }
    }

    private const string V1 = """
        CREATE TABLE IF NOT EXISTS "notebooks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "description" TEXT NOT NULL DEFAULT '', "created_at" DATETIME NOT NULL, "updated_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "notebooks_name_idx" ON "notebooks"("name");
        """;

    private const string V2 = """
        CREATE TABLE IF NOT EXISTS "sources" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE, "type" TEXT NOT NULL, "title" TEXT NOT NULL, "uri" TEXT, "raw_path" TEXT, "status" TEXT NOT NULL, "error" TEXT, "ingested_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_sources_notebook" ON "sources"("notebook_id");
        @@
        CREATE TABLE IF NOT EXISTS "source_chunks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "source_id" INTEGER NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE, "ord" INTEGER NOT NULL, "text" TEXT NOT NULL, "token_count" INTEGER NOT NULL, "page_hint" INTEGER);
        @@
        CREATE INDEX "idx_chunks_source" ON "source_chunks"("source_id", "ord");
        @@
        CREATE VIRTUAL TABLE sources_fts USING fts5(title, source_id UNINDEXED, tokenize = 'porter unicode61');
        @@
        CREATE VIRTUAL TABLE chunks_fts USING fts5(text, chunk_id UNINDEXED, tokenize = 'porter unicode61');
        @@
        CREATE TRIGGER sources_ai AFTER INSERT ON sources BEGIN
          INSERT INTO sources_fts(rowid, title, source_id) VALUES (new.id, new.title, new.id);
        END;
        @@
        CREATE TRIGGER sources_ad AFTER DELETE ON sources BEGIN
          DELETE FROM sources_fts WHERE rowid = old.id;
        END;
        @@
        CREATE TRIGGER sources_au AFTER UPDATE ON sources BEGIN
          UPDATE sources_fts SET title = new.title WHERE rowid = old.id;
        END;
        @@
        CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
          INSERT INTO chunks_fts(rowid, text, chunk_id) VALUES (new.id, new.text, new.id);
        END;
        @@
        CREATE TRIGGER chunks_ad AFTER DELETE ON source_chunks BEGIN
          DELETE FROM chunks_fts WHERE rowid = old.id;
        END;
        @@
        CREATE TRIGGER chunks_au AFTER UPDATE ON source_chunks BEGIN
          UPDATE chunks_fts SET text = new.text WHERE rowid = old.id;
        END;
        """;

    private const string V3 = """
        CREATE TABLE IF NOT EXISTS "chunk_embeddings" ("chunk_id" INTEGER PRIMARY KEY REFERENCES "source_chunks"("id") ON DELETE CASCADE, "dim" INTEGER NOT NULL, "model" TEXT NOT NULL, "embedding" BLOB NOT NULL);
        @@
        CREATE INDEX "idx_chunk_embeddings_model" ON "chunk_embeddings"("model");
        """;

    private const string V4 = """
        CREATE TABLE IF NOT EXISTS "chat_sessions" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "created_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_chat_sessions_notebook" ON "chat_sessions"("notebook_id", "created_at");
        @@
        CREATE TABLE IF NOT EXISTS "messages" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "session_id" INTEGER NOT NULL REFERENCES "chat_sessions"("id") ON DELETE CASCADE, "role" TEXT NOT NULL, "content" TEXT NOT NULL, "citations_json" TEXT, "created_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_messages_session" ON "messages"("session_id", "created_at");
        """;

    private const string V5 = """
        CREATE TABLE IF NOT EXISTS "notes" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "body_md" TEXT NOT NULL, "origin" TEXT NOT NULL, "origin_ref" INTEGER, "created_at" DATETIME NOT NULL, "updated_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_notes_notebook" ON "notes"("notebook_id", "updated_at");
        @@
        CREATE TABLE IF NOT EXISTS "transformations" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "prompt_template" TEXT NOT NULL, "scope" TEXT NOT NULL, "is_builtin" INTEGER NOT NULL DEFAULT 0);
        @@
        CREATE INDEX "idx_transformations_name" ON "transformations"("name");
        @@
        CREATE TABLE IF NOT EXISTS "transformation_runs" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "transformation_id" INTEGER NOT NULL REFERENCES "transformations"("id") ON DELETE CASCADE, "source_id" INTEGER REFERENCES "sources"("id") ON DELETE SET NULL, "result_note_id" INTEGER REFERENCES "notes"("id") ON DELETE SET NULL, "ran_at" DATETIME NOT NULL);
        """;

    private const string V6 = """
        ALTER TABLE notes ADD COLUMN "auto_source_id" INTEGER REFERENCES "sources"("id") ON DELETE SET NULL;
        @@
        ALTER TABLE notes ADD COLUMN "note_uuid" TEXT;
        @@
        CREATE INDEX "idx_notes_auto_source" ON "notes"("auto_source_id");
        """;

    private const string V7 = """
        CREATE TABLE IF NOT EXISTS "attachments" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "note_id" INTEGER NOT NULL REFERENCES "notes"("id") ON DELETE CASCADE, "note_uuid" TEXT NOT NULL, "filename" TEXT NOT NULL, "mime" TEXT NOT NULL, "byte_size" INTEGER NOT NULL, "created_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_attachments_note" ON "attachments"("note_id");
        """;

    private const string V8 = """
        CREATE TABLE IF NOT EXISTS "note_versions" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "note_id" INTEGER NOT NULL REFERENCES "notes"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "body_md" TEXT NOT NULL, "saved_at" DATETIME NOT NULL, "reason" TEXT NOT NULL);
        @@
        CREATE INDEX "idx_note_versions_note" ON "note_versions"("note_id", "saved_at");
        """;

    private const string V9 = """
        ALTER TABLE transformations ADD COLUMN "description" TEXT NOT NULL DEFAULT '';
        """;

    private const string V10 = """
        ALTER TABLE sources ADD COLUMN "summary" TEXT;
        """;

    private const string V11 = """
        CREATE TABLE IF NOT EXISTS "providers" (
          "id" TEXT NOT NULL PRIMARY KEY,
          "type" TEXT NOT NULL,
          "name" TEXT NOT NULL,
          "base_url" TEXT NOT NULL,
          "enabled" INTEGER NOT NULL DEFAULT 1,
          "privacy_acknowledged" INTEGER NOT NULL DEFAULT 0,
          "created_at" TEXT NOT NULL
        );
        """;

    private const string V12 = """
        CREATE TABLE IF NOT EXISTS "tags" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL UNIQUE);
        @@
        CREATE TABLE IF NOT EXISTS "note_tags" ("note_id" INTEGER NOT NULL REFERENCES "notes"("id") ON DELETE CASCADE, "tag_id" INTEGER NOT NULL REFERENCES "tags"("id") ON DELETE CASCADE, PRIMARY KEY (note_id, tag_id));
        @@
        CREATE TABLE IF NOT EXISTS "source_tags" ("source_id" INTEGER NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE, "tag_id" INTEGER NOT NULL REFERENCES "tags"("id") ON DELETE CASCADE, PRIMARY KEY (source_id, tag_id));
        @@
        CREATE INDEX "idx_note_tags_tag" ON "note_tags"("tag_id");
        @@
        CREATE INDEX "idx_source_tags_tag" ON "source_tags"("tag_id");
        @@
        CREATE VIRTUAL TABLE notes_fts USING fts5(title, body_md, note_id UNINDEXED, tokenize = 'porter unicode61');
        @@
        CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, body_md, note_id) VALUES (new.id, new.title, new.body_md, new.id);
        END;
        @@
        CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
          DELETE FROM notes_fts WHERE rowid = old.id;
        END;
        @@
        CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN
          UPDATE notes_fts SET title = new.title, body_md = new.body_md WHERE rowid = old.id;
        END;
        """;

    private const string V13 = """
        ALTER TABLE notebooks ADD COLUMN "instructions" TEXT NOT NULL DEFAULT '';
        @@
        ALTER TABLE messages ADD COLUMN "model" TEXT;
        @@
        CREATE TABLE IF NOT EXISTS "source_sets" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE, "name" TEXT NOT NULL, "created_at" DATETIME NOT NULL);
        @@
        CREATE TABLE IF NOT EXISTS "source_set_members" ("set_id" INTEGER NOT NULL REFERENCES "source_sets"("id") ON DELETE CASCADE, "source_id" INTEGER NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE, PRIMARY KEY (set_id, source_id));
        @@
        CREATE INDEX "idx_source_sets_notebook" ON "source_sets"("notebook_id");
        """;

    private const string V14 = """
        ALTER TABLE source_chunks ADD COLUMN "context" TEXT;
        """;

    private const string V15 = """
        ALTER TABLE sources ADD COLUMN "last_synced_at" TEXT;
        @@
        ALTER TABLE sources ADD COLUMN "content_hash" TEXT;
        """;
}
