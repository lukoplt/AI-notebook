using System.Security.Cryptography;
using System.Text;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed class StorageV19Exception(string code) : Exception(code)
{
    public string Code { get; } = code;
}

public sealed record V19MigrationReport(IReadOnlyDictionary<long, int> DroppedMalformedByNotebook);

/// <summary>Atomic v18 upgrade. Caller owns the connection gate and transaction.</summary>
internal static class MigrationV19
{
    internal static V19MigrationReport Apply(SqliteConnection connection,
        SqliteTransaction transaction, string? configuredEmbeddingModelKey)
    {
        void Exec(string sql, object? args = null) => connection.Execute(sql, args, transaction);
        void Script(string sql)
        {
            foreach (var statement in sql.Split("@@", StringSplitOptions.RemoveEmptyEntries))
                Exec(statement);
        }

        // Check before rebuilding: inner joins must not erase corrupt orphan vectors.
        if (connection.Query("PRAGMA foreign_key_check", transaction: transaction).Any())
            throw new StorageV19Exception("invalidValue");
        Script(Schema);
        var sources = connection.Query("SELECT id,status,content_hash,ingested_at FROM sources ORDER BY id",
            transaction: transaction).ToArray();
        foreach (var source in sources)
        {
            long sourceId = source.id;
            var chunks = connection.Query<string>("SELECT text FROM source_chunks WHERE source_id=$sourceId ORDER BY ord,id",
                new { sourceId }, transaction).ToArray();
            string text = string.Join("\n\n", chunks);
            string hash = source.content_hash as string ?? "";
            if (hash.Length == 0) hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
            long revisionId = connection.ExecuteScalar<long>("""
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES($sourceId,1,$hash,$text,1,1,$created); SELECT last_insert_rowid();
                """, new { sourceId, hash, text, created = (string)source.ingested_at }, transaction);
            Exec("UPDATE sources SET current_revision=$revisionId,published_revision_id=$published WHERE id=$sourceId",
                new { sourceId, revisionId, published = chunks.Length > 0 || (string)source.status == "ready" ? (long?)revisionId : null });
            Exec("UPDATE source_chunks SET revision_id=$revisionId WHERE source_id=$sourceId", new { sourceId, revisionId });
        }

        var dropped = new Dictionary<long, int>();
        var vectors = connection.Query("""
            SELECT s.notebook_id,s.id AS source_id,s.current_revision,c.id AS chunk_id,e.model,e.dim,e.embedding,n.created_at
            FROM chunk_embeddings_v18 e JOIN source_chunks c ON c.id=e.chunk_id
            JOIN sources s ON s.id=c.source_id JOIN notebooks n ON n.id=s.notebook_id
            ORDER BY s.notebook_id,CAST(e.model AS BLOB),e.dim,c.id
            """, transaction: transaction).ToArray();
        var accepted = new List<(long Notebook, long Source, long Revision, long Chunk, string Model, long Dims, byte[] Bytes, string Created)>();
        foreach (var row in vectors)
        {
            long notebook = row.notebook_id, dims = row.dim;
            byte[] bytes = (byte[])row.embedding;
            if (dims <= 0 || dims > int.MaxValue || bytes.LongLength != dims * 4)
            {
                dropped[notebook] = dropped.GetValueOrDefault(notebook) + 1;
                continue;
            }
            accepted.Add((notebook, (long)row.source_id, (long)row.current_revision, (long)row.chunk_id,
                (string)row.model, dims, bytes, (string)row.created_at));
        }
        var choices = new Dictionary<long, (long Id, int Count, long Dims, string Created)>();
        // GroupBy preserves the SQLite UTF-8 binary ordering above, including non-BMP model keys.
        foreach (var group in accepted.GroupBy(v => (v.Notebook, v.Model, v.Dims)))
        {
            var first = group.First();
            long generation = connection.ExecuteScalar<long>("""
                INSERT INTO index_generations(notebook_id,provider_id,endpoint_revision,model,model_digest,dims,
                    normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
                VALUES($notebook,'legacy','legacy',$model,NULL,$dims,'legacy','legacy','legacy','legacy','retired',$created);
                SELECT last_insert_rowid();
                """, new { notebook = first.Notebook, model = first.Model, dims = first.Dims, created = first.Created }, transaction);
            foreach (var member in group.GroupBy(v => (v.Source, v.Revision)))
            {
                int total = connection.ExecuteScalar<int>("SELECT count(*) FROM source_chunks WHERE revision_id=$revision",
                    new { revision = member.Key.Revision }, transaction);
                bool complete = total == member.Count();
                Exec("""
                    INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason)
                    VALUES($generation,$source,$revision,$state,$reason)
                    """, new { generation, source = member.Key.Source, revision = member.Key.Revision,
                        state = complete ? "done" : "excluded", reason = complete ? null : "legacy-incomplete" });
            }
            foreach (var vector in group)
                Exec("INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES($chunk,$generation,$bytes)",
                    new { chunk = vector.Chunk, generation, bytes = vector.Bytes });
            int count = group.Count();
            if (StringComparer.Ordinal.Equals(first.Model, configuredEmbeddingModelKey) &&
                (!choices.TryGetValue(first.Notebook, out var choice) || count > choice.Count ||
                 count == choice.Count && first.Dims < choice.Dims))
                choices[first.Notebook] = (generation, count, first.Dims, first.Created);
        }
        foreach (var choice in choices.Values)
            Exec("UPDATE index_generations SET state='active',activated_at=$created WHERE id=$id",
                new { id = choice.Id, created = choice.Created });
        Exec("DROP TABLE chunk_embeddings_v18");
        Script(Fts);
        Exec("CREATE TRIGGER revisions_no_update BEFORE UPDATE ON source_revisions BEGIN SELECT RAISE(ABORT,'immutable revision'); END");
        Exec("""
            CREATE TRIGGER chunks_immutable BEFORE UPDATE OF source_id,ord,text,token_count,page_hint,revision_id,char_start,char_end,lang,lang_inherited
            ON source_chunks BEGIN SELECT RAISE(ABORT,'immutable revision'); END
            """);
        foreach (var operation in new[] { "INSERT", "UPDATE" })
        {
            string suffix = operation.ToLowerInvariant();
            Exec($"""
                CREATE TRIGGER sources_owner_{suffix} BEFORE {operation} ON sources BEGIN
                SELECT CASE WHEN new.folder_id IS NOT NULL AND EXISTS(
                    SELECT 1 FROM folder_sources f WHERE f.id=new.folder_id AND f.notebook_id<>new.notebook_id)
                    THEN RAISE(ABORT,'notebook mismatch') END;
                SELECT CASE WHEN EXISTS(SELECT 1 FROM source_revisions r
                    WHERE r.id IN (new.current_revision,new.published_revision_id) AND r.source_id<>new.id)
                    THEN RAISE(ABORT,'revision mismatch') END;
                SELECT CASE WHEN (new.folder_id IS NULL AND new.rel_path IS NOT NULL)
                    OR (new.folder_id IS NOT NULL AND (new.rel_path IS NULL OR length(new.rel_path)=0
                    OR substr(new.rel_path,1,1)='/' OR instr(new.rel_path,char(92))>0 OR instr(new.rel_path,char(0))>0
                    OR instr(new.rel_path,'//')>0 OR substr(new.rel_path,-1)='/'
                    OR '/'||new.rel_path||'/' LIKE '%/../%' OR '/'||new.rel_path||'/' LIKE '%/./%'
                    OR new.rel_path GLOB '[A-Za-z]:*')) THEN RAISE(ABORT,'invalid path') END;
                END
                """);
            Exec($"""
                CREATE TRIGGER chunks_owner_{suffix} BEFORE {operation} ON source_chunks BEGIN
                SELECT CASE WHEN EXISTS(SELECT 1 FROM source_revisions r WHERE r.id=new.revision_id AND r.source_id<>new.source_id)
                    THEN RAISE(ABORT,'revision mismatch') END;
                END
                """);
            Exec($"""
                CREATE TRIGGER manifest_owner_{suffix} BEFORE {operation} ON index_generation_manifest BEGIN
                SELECT CASE WHEN EXISTS(SELECT 1 FROM sources s JOIN index_generations g ON g.id=new.generation_id
                    WHERE s.id=new.source_id AND s.notebook_id<>g.notebook_id) THEN RAISE(ABORT,'notebook mismatch') END;
                SELECT CASE WHEN EXISTS(SELECT 1 FROM source_revisions r WHERE r.id=new.revision_id AND r.source_id<>new.source_id)
                    THEN RAISE(ABORT,'revision mismatch') END;
                END
                """);
            Exec($"""
                CREATE TRIGGER source_set_folders_owner_{suffix} BEFORE {operation} ON source_set_folders BEGIN
                SELECT CASE WHEN EXISTS(SELECT 1 FROM source_sets s JOIN folder_sources f ON f.id=new.folder_id
                    WHERE s.id=new.set_id AND s.notebook_id<>f.notebook_id) THEN RAISE(ABORT,'notebook mismatch') END;
                END
                """);
        }
        if (connection.Query("PRAGMA foreign_key_check", transaction: transaction).Any())
            throw new StorageV19Exception("invalidValue");
        return new V19MigrationReport(dropped);
    }

    private const string Schema = """
CREATE TABLE folder_sources (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 notebook_id INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
 root_path TEXT NOT NULL, path_identity TEXT NOT NULL, display_name TEXT NOT NULL,
 include_exts TEXT NOT NULL, ignore_globs TEXT NOT NULL, limits TEXT NOT NULL,
 encoding_fallback TEXT NOT NULL DEFAULT 'cp1250' CHECK(encoding_fallback IN ('cp1250','none')),
 watch_enabled INTEGER NOT NULL DEFAULT 1 CHECK(watch_enabled IN (0,1)),
 scan_state TEXT NOT NULL DEFAULT 'idle' CHECK(scan_state IN ('idle','scanning','partial','error','unavailable')),
 scan_generation INTEGER NOT NULL DEFAULT 0 CHECK(scan_generation>=0),
 last_full_scan_at INTEGER, last_scan_error TEXT, created_at TEXT NOT NULL
);
@@
CREATE INDEX idx_folder_sources_notebook ON folder_sources(notebook_id,id);
@@
CREATE TABLE scan_items (
 folder_id INTEGER NOT NULL REFERENCES folder_sources(id) ON DELETE CASCADE,
 rel_path TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('eligible','skipped')),
 skip_reason TEXT CHECK(skip_reason IN ('ignored','unsupported_ext','over_limit')),
 mtime INTEGER, size_bytes INTEGER CHECK(size_bytes>=0), seen_generation INTEGER NOT NULL,
 PRIMARY KEY(folder_id,rel_path),
 CHECK((kind='eligible' AND skip_reason IS NULL) OR (kind='skipped' AND skip_reason IS NOT NULL))
);
@@
CREATE TABLE source_revisions (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL CHECK(revision>0), content_hash TEXT NOT NULL,
 canonical_text TEXT NOT NULL, text_format_version INTEGER NOT NULL,
 chunker_version INTEGER NOT NULL, created_at TEXT NOT NULL,
 UNIQUE(source_id,revision)
);
@@
CREATE TABLE revision_pages (
  revision_id INTEGER NOT NULL REFERENCES source_revisions(id) ON DELETE CASCADE,
  page INTEGER NOT NULL CHECK(page>0),
  char_start INTEGER NOT NULL CHECK(char_start>=0),
  char_end INTEGER NOT NULL CHECK(char_end>=char_start),
  PRIMARY KEY(revision_id,page)
);
@@
CREATE TRIGGER revision_pages_no_update BEFORE UPDATE ON revision_pages
BEGIN SELECT RAISE(ABORT,'immutable revision page'); END;
@@
ALTER TABLE sources ADD COLUMN folder_id INTEGER REFERENCES folder_sources(id) ON DELETE CASCADE;
@@
ALTER TABLE sources ADD COLUMN rel_path TEXT;
@@
ALTER TABLE sources ADD COLUMN mtime INTEGER;
@@
ALTER TABLE sources ADD COLUMN size_bytes INTEGER CHECK(size_bytes>=0);
@@
ALTER TABLE sources ADD COLUMN availability TEXT NOT NULL DEFAULT 'present' CHECK(availability IN ('present','missing','unavailable'));
@@
ALTER TABLE sources ADD COLUMN eligible INTEGER NOT NULL DEFAULT 1 CHECK(eligible IN (0,1));
@@
ALTER TABLE sources ADD COLUMN lang TEXT CHECK(lang IN ('cs','sk','en','de','und','mixed'));
@@
ALTER TABLE sources ADD COLUMN lang_coverage TEXT;
@@
ALTER TABLE sources ADD COLUMN descriptor TEXT;
@@
ALTER TABLE sources ADD COLUMN current_revision INTEGER REFERENCES source_revisions(id) ON DELETE SET NULL;
@@
ALTER TABLE sources ADD COLUMN published_revision_id INTEGER REFERENCES source_revisions(id) ON DELETE SET NULL;
@@
ALTER TABLE sources ADD COLUMN encoding TEXT;
@@
CREATE UNIQUE INDEX idx_sources_folder_path ON sources(folder_id,rel_path) WHERE folder_id IS NOT NULL;
@@
ALTER TABLE source_chunks ADD COLUMN revision_id INTEGER REFERENCES source_revisions(id) ON DELETE CASCADE;
@@
ALTER TABLE source_chunks ADD COLUMN char_start INTEGER;
@@
ALTER TABLE source_chunks ADD COLUMN char_end INTEGER;
@@
ALTER TABLE source_chunks ADD COLUMN lang TEXT CHECK(lang IN ('cs','sk','en','de','und'));
@@
ALTER TABLE source_chunks ADD COLUMN lang_inherited INTEGER NOT NULL DEFAULT 0 CHECK(lang_inherited IN (0,1));
@@
CREATE UNIQUE INDEX idx_chunks_revision_ord ON source_chunks(revision_id,ord);
@@
CREATE TABLE source_set_folders (
 set_id INTEGER NOT NULL REFERENCES source_sets(id) ON DELETE CASCADE,
 folder_id INTEGER NOT NULL REFERENCES folder_sources(id) ON DELETE CASCADE,
 PRIMARY KEY(set_id,folder_id)
);
@@
CREATE TABLE ingest_jobs (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 kind TEXT NOT NULL CHECK(kind IN ('scan','extract','embed','gc')),
 target TEXT NOT NULL,
 target_revision INTEGER REFERENCES source_revisions(id) ON DELETE CASCADE,
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 next_retry_at INTEGER,
 state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','paused','done','failed','cancelled')),
 lease_until INTEGER, lease_token TEXT, error TEXT,
 options_json TEXT NOT NULL DEFAULT '{}',
 CHECK((state='running' AND lease_until IS NOT NULL AND lease_token IS NOT NULL)
    OR (state<>'running' AND lease_until IS NULL AND lease_token IS NULL))
);
@@
CREATE INDEX idx_ingest_jobs_claim ON ingest_jobs(state,next_retry_at,id);
@@
ALTER TABLE notebooks ADD COLUMN evidence_budget_cap INTEGER CHECK(evidence_budget_cap>=0);
@@
CREATE TABLE provider_model_limits (
    provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
    model TEXT NOT NULL CHECK(length(trim(model)) > 0),
    context_window INTEGER NULL CHECK(context_window IS NULL OR context_window > 0),
    runtime_context INTEGER NOT NULL CHECK(runtime_context > 0),
    max_output_tokens INTEGER NOT NULL CHECK(max_output_tokens > 0),
    source TEXT NOT NULL CHECK(source IN ('auto', 'user')),
    PRIMARY KEY (provider_id, model),
    CHECK(context_window IS NULL OR runtime_context <= context_window),
    CHECK(max_output_tokens < runtime_context)
);
@@
CREATE TABLE index_generations (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 notebook_id INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
 provider_id TEXT NOT NULL, endpoint_revision TEXT NOT NULL, model TEXT NOT NULL,
 model_digest TEXT, dims INTEGER NOT NULL CHECK(dims>0), normalization TEXT NOT NULL,
 query_format_version TEXT NOT NULL, doc_format_version TEXT NOT NULL, chunker_version TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('building','active','retired','failed')),
 created_at TEXT NOT NULL, activated_at TEXT
);
@@
CREATE UNIQUE INDEX idx_one_active_generation ON index_generations(notebook_id) WHERE state='active';
@@
CREATE TABLE index_generation_manifest (
 generation_id INTEGER NOT NULL REFERENCES index_generations(id) ON DELETE CASCADE,
 source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
 revision_id INTEGER NOT NULL REFERENCES source_revisions(id) ON DELETE CASCADE,
 state TEXT NOT NULL CHECK(state IN ('pending','done','excluded')), reason TEXT,
 PRIMARY KEY(generation_id,source_id),
 CHECK(state<>'excluded' OR (reason IS NOT NULL AND length(reason)>0))
);
@@
ALTER TABLE chunk_embeddings RENAME TO chunk_embeddings_v18;
@@
DROP INDEX idx_chunk_embeddings_model;
@@
CREATE TABLE chunk_embeddings (
 chunk_id INTEGER NOT NULL REFERENCES source_chunks(id) ON DELETE CASCADE,
 generation_id INTEGER NOT NULL REFERENCES index_generations(id) ON DELETE CASCADE,
 embedding BLOB NOT NULL,
 PRIMARY KEY(chunk_id,generation_id)
);
@@
CREATE INDEX idx_chunk_embeddings_generation ON chunk_embeddings(generation_id,chunk_id);
""";

    private const string Fts = """
DROP TRIGGER sources_ai;
@@
DROP TRIGGER sources_ad;
@@
DROP TRIGGER sources_au;
@@
DROP TRIGGER chunks_ai;
@@
DROP TRIGGER chunks_ad;
@@
DROP TRIGGER chunks_au;
@@
DROP TABLE sources_fts;
@@
DROP TABLE chunks_fts;
@@
CREATE VIRTUAL TABLE sources_fts USING fts5(title,source_id UNINDEXED,tokenize='unicode61 remove_diacritics 2');
@@
CREATE VIRTUAL TABLE chunks_fts USING fts5(text,chunk_id UNINDEXED,tokenize='unicode61 remove_diacritics 2');
@@
CREATE TRIGGER sources_ai AFTER INSERT ON sources BEGIN
 INSERT INTO sources_fts(rowid,title,source_id) VALUES(new.id,new.title,new.id);
END;
@@
CREATE TRIGGER sources_ad AFTER DELETE ON sources BEGIN
 DELETE FROM sources_fts WHERE rowid=old.id;
END;
@@
CREATE TRIGGER sources_au AFTER UPDATE OF title ON sources BEGIN
 UPDATE sources_fts SET title=new.title WHERE rowid=old.id;
END;
@@
CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
 INSERT INTO chunks_fts(rowid,text,chunk_id) VALUES(new.id,new.text,new.id);
END;
@@
CREATE TRIGGER chunks_ad AFTER DELETE ON source_chunks BEGIN
 DELETE FROM chunks_fts WHERE rowid=old.id;
END;
@@
CREATE TRIGGER chunks_au AFTER UPDATE OF text ON source_chunks BEGIN
 UPDATE chunks_fts SET text=new.text WHERE rowid=old.id;
END;
@@
INSERT INTO sources_fts(rowid,title,source_id) SELECT id,title,id FROM sources;
@@
INSERT INTO chunks_fts(rowid,text,chunk_id) SELECT id,text,id FROM source_chunks;
""";
}
