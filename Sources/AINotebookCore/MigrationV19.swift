import Foundation
import CryptoKit
import GRDB

public enum StorageV19Error: String, Error, Equatable, Sendable {
    case notFound, invalidPath, overlappingRoot, notebookMismatch, invalidValue
    case immutableRevision, invalidSpan, staleLease, staleRevision, generationNotReady, invalidVector
    public var code: String { rawValue }
}

public struct V19MigrationReport: Equatable, Sendable {
    public let droppedMalformedByNotebook: [Int64: Int]
}

public func registerMigrationV19(on migrator: inout DatabaseMigrator,
                                configuredEmbeddingModelKey: String?) {
    migrator.registerMigration("v19_folder_rag") { db in
        _ = try migrateV19(db, configuredEmbeddingModelKey: configuredEmbeddingModelKey)
    }
}

// The caller owns the transaction. No preferences, extraction or provider calls occur here.
func migrateV19(_ db: Database, configuredEmbeddingModelKey: String?) throws -> V19MigrationReport {
    try db.execute(sql: v19Schema)
    try convertV19ProviderRoots(db)
    try backfillV19Revisions(db)
    let report = try backfillV19Vectors(db, configuredKey: configuredEmbeddingModelKey)
    try db.execute(sql: "DROP TABLE chunk_embeddings_v18")
    try db.execute(sql: v19FTS)
    try installV19Integrity(db)
    guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
        throw StorageV19Error.invalidValue
    }
    return report
}

private func convertV19ProviderRoots(_ db: Database) throws {
    // Materialize before updating; the v19 ledger makes this conversion one-time.
    let rows = try Row.fetchAll(db, sql: "SELECT id,type,base_url FROM providers")
    for row in rows {
        let id: String = row["id"]
        let type = ProviderType.fromStorage(row["type"])
        let baseURL: String = row["base_url"]
        let converted: String
        do {
            converted = try ProviderAPIRoot.convertLegacy(type: type, baseURL: baseURL)
        } catch ProviderConfigurationError.invalidBaseURL {
            // Preserve invalid legacy input for normal request validation.
            continue
        }
        try db.execute(sql: "UPDATE providers SET base_url=? WHERE id=?", arguments: [converted, id])
    }
}

private func backfillV19Revisions(_ db: Database) throws {
    let insert = try db.makeStatement(sql: """
        INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,
            text_format_version,chunker_version,created_at) VALUES (?,1,?,?,1,1,?)
        """)
    for source in try Row.fetchAll(db, sql: "SELECT id,content_hash,status,ingested_at FROM sources ORDER BY id") {
        let sourceId: Int64 = source["id"]
        let texts = try String.fetchAll(db, sql: "SELECT text FROM source_chunks WHERE source_id=? ORDER BY ord,id", arguments: [sourceId])
        let canonical = texts.joined(separator: "\n\n")
        let storedHash: String? = source["content_hash"]
        let hash = storedHash.flatMap { $0.isEmpty ? nil : $0 }
            ?? SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let date: String = source["ingested_at"]
        try insert.execute(arguments: [sourceId, hash, canonical, date])
        let revisionId = db.lastInsertedRowID
        let status: String = source["status"]
        let published: Int64? = !texts.isEmpty || status == "ready" ? revisionId : nil
        try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                       arguments: [revisionId, published, sourceId])
        try db.execute(sql: "UPDATE source_chunks SET revision_id=? WHERE source_id=?", arguments: [revisionId, sourceId])
    }
}

private func backfillV19Vectors(_ db: Database, configuredKey: String?) throws -> V19MigrationReport {
    struct Group: Hashable {
        let notebookId: Int64
        // Data preserves opaque UTF-8 identity instead of Swift canonical-equivalence equality.
        let modelBytes: Data
        let dims: Int64
    }
    let rows = try Row.fetchAll(db, sql: """
        SELECT s.notebook_id,e.model,e.dim,e.chunk_id,e.embedding,c.source_id,c.revision_id,n.created_at
        FROM chunk_embeddings_v18 e JOIN source_chunks c ON c.id=e.chunk_id
        JOIN sources s ON s.id=c.source_id JOIN notebooks n ON n.id=s.notebook_id
        ORDER BY s.notebook_id,CAST(e.model AS BLOB),e.dim,e.chunk_id
        """)
    var groups: [Group: [Row]] = [:]
    var dropped: [Int64: Int] = [:]
    for row in rows {
        let notebook: Int64 = row["notebook_id"]
        let dims: Int64 = row["dim"]
        let bytes: Data = row["embedding"]
        guard dims > 0, dims <= Int64.max / 4, Int64(bytes.count) == dims * 4 else {
            dropped[notebook, default: 0] += 1
            continue
        }
        let model: String = row["model"]
        groups[Group(notebookId: notebook, modelBytes: Data(model.utf8), dims: dims), default: []].append(row)
    }
    let ordered = groups.keys.sorted {
        if $0.notebookId != $1.notebookId { return $0.notebookId < $1.notebookId }
        if $0.modelBytes != $1.modelBytes { return $0.modelBytes.lexicographicallyPrecedes($1.modelBytes) }
        return $0.dims < $1.dims
    }
    var chosen: [Int64: (id: Int64, count: Int, dims: Int64, date: String)] = [:]
    let vectorInsert = try db.makeStatement(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES (?,?,?)")
    for key in ordered {
        let vectors = groups[key]!
        let model = String(decoding: key.modelBytes, as: UTF8.self)
        let date: String = vectors[0]["created_at"]
        try db.execute(sql: """
            INSERT INTO index_generations(notebook_id,provider_id,endpoint_revision,model,model_digest,
                dims,normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
            VALUES (?,'legacy','legacy',?,NULL,?,'legacy','legacy','legacy','legacy','retired',?)
            """, arguments: [key.notebookId, model, key.dims, date])
        let generationId = db.lastInsertedRowID
        var sourceCounts: [Int64: (revision: Int64, count: Int)] = [:]
        for row in vectors {
            let chunk: Int64 = row["chunk_id"]
            let bytes: Data = row["embedding"]
            try vectorInsert.execute(arguments: [chunk, generationId, bytes])
            let source: Int64 = row["source_id"]
            let revision: Int64 = row["revision_id"]
            sourceCounts[source] = (revision, (sourceCounts[source]?.count ?? 0) + 1)
        }
        for source in sourceCounts.keys.sorted() {
            let value = sourceCounts[source]!
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE revision_id=?", arguments: [value.revision])!
            let complete = total == value.count
            try db.execute(sql: """
                INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason)
                VALUES (?,?,?,?,?)
                """, arguments: [generationId, source, value.revision, complete ? "done" : "excluded",
                                  complete ? nil : "legacy-incomplete"])
        }
        if let configuredKey, key.modelBytes == Data(configuredKey.utf8) {
            let previous = chosen[key.notebookId]
            if previous == nil || vectors.count > previous!.count
                || (vectors.count == previous!.count && key.dims < previous!.dims) {
                chosen[key.notebookId] = (generationId, vectors.count, key.dims, date)
            }
        }
    }
    for value in chosen.values {
        try db.execute(sql: "UPDATE index_generations SET state='active',activated_at=? WHERE id=?", arguments: [value.date, value.id])
    }
    return V19MigrationReport(droppedMalformedByNotebook: dropped)
}

private func installV19Integrity(_ db: Database) throws {
    try db.execute(sql: """
        CREATE TRIGGER revisions_no_update BEFORE UPDATE ON source_revisions BEGIN
          SELECT RAISE(ABORT,'immutable revision');
        END;
        CREATE TRIGGER chunks_immutable BEFORE UPDATE OF id,source_id,ord,text,token_count,page_hint,
          revision_id,char_start,char_end,lang,lang_inherited ON source_chunks BEGIN
          SELECT RAISE(ABORT,'immutable revision');
        END;
        """)
    for event in ["INSERT", "UPDATE"] {
        let suffix = event.lowercased()
        try db.execute(sql: """
            CREATE TRIGGER sources_owner_\(suffix) BEFORE \(event) ON sources BEGIN
              SELECT CASE WHEN new.folder_id IS NOT NULL AND
                (SELECT notebook_id FROM folder_sources WHERE id=new.folder_id)<>new.notebook_id
                THEN RAISE(ABORT,'notebook mismatch') END;
              SELECT CASE WHEN (new.current_revision IS NOT NULL AND
                (SELECT source_id FROM source_revisions WHERE id=new.current_revision)<>new.id)
                OR (new.published_revision_id IS NOT NULL AND
                (SELECT source_id FROM source_revisions WHERE id=new.published_revision_id)<>new.id)
                THEN RAISE(ABORT,'revision mismatch') END;
              SELECT CASE WHEN (new.folder_id IS NULL AND new.rel_path IS NOT NULL)
                OR (new.folder_id IS NOT NULL AND (new.rel_path IS NULL OR length(new.rel_path)=0
                OR substr(new.rel_path,1,1)='/' OR instr(new.rel_path,'//')>0
                OR '/'||new.rel_path||'/' LIKE '%/../%' OR '/'||new.rel_path||'/' LIKE '%/./%'
                OR substr(new.rel_path,-1)='/' OR instr(new.rel_path,char(92))>0
                OR instr(new.rel_path,char(0))>0 OR new.rel_path GLOB '[A-Za-z]:*'))
                THEN RAISE(ABORT,'invalid path') END;
            END;
            CREATE TRIGGER chunks_owner_\(suffix) BEFORE \(event) ON source_chunks BEGIN
              SELECT CASE WHEN new.revision_id IS NOT NULL AND
                (SELECT source_id FROM source_revisions WHERE id=new.revision_id)<>new.source_id
                THEN RAISE(ABORT,'revision mismatch') END;
            END;
            CREATE TRIGGER manifest_owner_\(suffix) BEFORE \(event) ON index_generation_manifest BEGIN
              SELECT CASE WHEN (SELECT notebook_id FROM index_generations WHERE id=new.generation_id)
                <>(SELECT notebook_id FROM sources WHERE id=new.source_id)
                THEN RAISE(ABORT,'notebook mismatch') END;
              SELECT CASE WHEN (SELECT source_id FROM source_revisions WHERE id=new.revision_id)<>new.source_id
                THEN RAISE(ABORT,'revision mismatch') END;
            END;
            CREATE TRIGGER folder_members_owner_\(suffix) BEFORE \(event) ON source_set_folders BEGIN
              SELECT CASE WHEN (SELECT notebook_id FROM source_sets WHERE id=new.set_id)
                <>(SELECT notebook_id FROM folder_sources WHERE id=new.folder_id)
                THEN RAISE(ABORT,'notebook mismatch') END;
            END;
            """)
    }
}

private let v19Schema = """
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
CREATE INDEX idx_folder_sources_notebook ON folder_sources(notebook_id,id);
CREATE TABLE scan_items (
 folder_id INTEGER NOT NULL REFERENCES folder_sources(id) ON DELETE CASCADE,
 rel_path TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('eligible','skipped')),
 skip_reason TEXT CHECK(skip_reason IN ('ignored','unsupported_ext','over_limit')),
 mtime INTEGER, size_bytes INTEGER CHECK(size_bytes>=0), seen_generation INTEGER NOT NULL,
 PRIMARY KEY(folder_id,rel_path),
 CHECK((kind='eligible' AND skip_reason IS NULL) OR (kind='skipped' AND skip_reason IS NOT NULL))
);
CREATE TABLE source_revisions (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL CHECK(revision>0), content_hash TEXT NOT NULL,
 canonical_text TEXT NOT NULL, text_format_version INTEGER NOT NULL,
 chunker_version INTEGER NOT NULL, created_at TEXT NOT NULL,
 UNIQUE(source_id,revision)
);
CREATE TABLE revision_pages (
  revision_id INTEGER NOT NULL REFERENCES source_revisions(id) ON DELETE CASCADE,
  page INTEGER NOT NULL CHECK(page>0),
  char_start INTEGER NOT NULL CHECK(char_start>=0),
  char_end INTEGER NOT NULL CHECK(char_end>=char_start),
  PRIMARY KEY(revision_id,page)
);
CREATE TRIGGER revision_pages_no_update BEFORE UPDATE ON revision_pages
BEGIN SELECT RAISE(ABORT,'immutable revision page'); END;
ALTER TABLE sources ADD COLUMN folder_id INTEGER REFERENCES folder_sources(id) ON DELETE CASCADE;
ALTER TABLE sources ADD COLUMN rel_path TEXT;
ALTER TABLE sources ADD COLUMN mtime INTEGER;
ALTER TABLE sources ADD COLUMN size_bytes INTEGER CHECK(size_bytes>=0);
ALTER TABLE sources ADD COLUMN availability TEXT NOT NULL DEFAULT 'present' CHECK(availability IN ('present','missing','unavailable'));
ALTER TABLE sources ADD COLUMN eligible INTEGER NOT NULL DEFAULT 1 CHECK(eligible IN (0,1));
ALTER TABLE sources ADD COLUMN lang TEXT CHECK(lang IN ('cs','sk','en','de','und','mixed'));
ALTER TABLE sources ADD COLUMN lang_coverage TEXT;
ALTER TABLE sources ADD COLUMN descriptor TEXT;
ALTER TABLE sources ADD COLUMN current_revision INTEGER REFERENCES source_revisions(id) ON DELETE SET NULL;
ALTER TABLE sources ADD COLUMN published_revision_id INTEGER REFERENCES source_revisions(id) ON DELETE SET NULL;
ALTER TABLE sources ADD COLUMN encoding TEXT;
CREATE UNIQUE INDEX idx_sources_folder_path ON sources(folder_id,rel_path) WHERE folder_id IS NOT NULL;
ALTER TABLE source_chunks ADD COLUMN revision_id INTEGER REFERENCES source_revisions(id) ON DELETE CASCADE;
ALTER TABLE source_chunks ADD COLUMN char_start INTEGER;
ALTER TABLE source_chunks ADD COLUMN char_end INTEGER;
ALTER TABLE source_chunks ADD COLUMN lang TEXT CHECK(lang IN ('cs','sk','en','de','und'));
ALTER TABLE source_chunks ADD COLUMN lang_inherited INTEGER NOT NULL DEFAULT 0 CHECK(lang_inherited IN (0,1));
CREATE UNIQUE INDEX idx_chunks_revision_ord ON source_chunks(revision_id,ord);
CREATE TABLE source_set_folders (
 set_id INTEGER NOT NULL REFERENCES source_sets(id) ON DELETE CASCADE,
 folder_id INTEGER NOT NULL REFERENCES folder_sources(id) ON DELETE CASCADE,
 PRIMARY KEY(set_id,folder_id)
);
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
CREATE INDEX idx_ingest_jobs_claim ON ingest_jobs(state,next_retry_at,id);
ALTER TABLE notebooks ADD COLUMN evidence_budget_cap INTEGER CHECK(evidence_budget_cap>=0);
CREATE TABLE provider_model_limits (
 provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
 model TEXT NOT NULL CHECK(length(trim(model))>0), context_window INTEGER, runtime_context INTEGER NOT NULL,
 max_output_tokens INTEGER NOT NULL, source TEXT NOT NULL CHECK(source IN ('auto','user')),
 PRIMARY KEY(provider_id,model),
 CHECK(context_window IS NULL OR context_window>0),
 CHECK(runtime_context>0 AND max_output_tokens>0 AND max_output_tokens<runtime_context),
 CHECK(context_window IS NULL OR runtime_context<=context_window)
);
CREATE TABLE index_generations (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 notebook_id INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
 provider_id TEXT NOT NULL, endpoint_revision TEXT NOT NULL, model TEXT NOT NULL,
 model_digest TEXT, dims INTEGER NOT NULL CHECK(dims>0), normalization TEXT NOT NULL,
 query_format_version TEXT NOT NULL, doc_format_version TEXT NOT NULL, chunker_version TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('building','active','retired','failed')),
 created_at TEXT NOT NULL, activated_at TEXT
);
CREATE UNIQUE INDEX idx_one_active_generation ON index_generations(notebook_id) WHERE state='active';
CREATE TABLE index_generation_manifest (
 generation_id INTEGER NOT NULL REFERENCES index_generations(id) ON DELETE CASCADE,
 source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
 revision_id INTEGER NOT NULL REFERENCES source_revisions(id) ON DELETE CASCADE,
 state TEXT NOT NULL CHECK(state IN ('pending','done','excluded')), reason TEXT,
 PRIMARY KEY(generation_id,source_id),
 CHECK(state<>'excluded' OR (reason IS NOT NULL AND length(reason)>0))
);
ALTER TABLE chunk_embeddings RENAME TO chunk_embeddings_v18;
DROP INDEX idx_chunk_embeddings_model;
CREATE TABLE chunk_embeddings (
 chunk_id INTEGER NOT NULL REFERENCES source_chunks(id) ON DELETE CASCADE,
 generation_id INTEGER NOT NULL REFERENCES index_generations(id) ON DELETE CASCADE,
 embedding BLOB NOT NULL,
 PRIMARY KEY(chunk_id,generation_id)
);
CREATE INDEX idx_chunk_embeddings_generation ON chunk_embeddings(generation_id,chunk_id);
"""

private let v19FTS = """
DROP TRIGGER sources_ai;
DROP TRIGGER sources_ad;
DROP TRIGGER sources_au;
DROP TRIGGER chunks_ai;
DROP TRIGGER chunks_ad;
DROP TRIGGER chunks_au;
DROP TABLE sources_fts;
DROP TABLE chunks_fts;
CREATE VIRTUAL TABLE sources_fts USING fts5(title,source_id UNINDEXED,tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE chunks_fts USING fts5(text,chunk_id UNINDEXED,tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER sources_ai AFTER INSERT ON sources BEGIN
 INSERT INTO sources_fts(rowid,title,source_id) VALUES(new.id,new.title,new.id);
END;
CREATE TRIGGER sources_ad AFTER DELETE ON sources BEGIN
 DELETE FROM sources_fts WHERE rowid=old.id;
END;
CREATE TRIGGER sources_au AFTER UPDATE OF title ON sources BEGIN
 UPDATE sources_fts SET title=new.title WHERE rowid=old.id;
END;
CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
 INSERT INTO chunks_fts(rowid,text,chunk_id) VALUES(new.id,new.text,new.id);
END;
CREATE TRIGGER chunks_ad AFTER DELETE ON source_chunks BEGIN
 DELETE FROM chunks_fts WHERE rowid=old.id;
END;
CREATE TRIGGER chunks_au AFTER UPDATE OF text ON source_chunks BEGIN
 UPDATE chunks_fts SET text=new.text WHERE rowid=old.id;
END;
INSERT INTO sources_fts(rowid,title,source_id) SELECT id,title,id FROM sources;
INSERT INTO chunks_fts(rowid,text,chunk_id) SELECT id,text,id FROM source_chunks;
"""
