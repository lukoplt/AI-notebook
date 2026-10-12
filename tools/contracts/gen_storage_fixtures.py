#!/usr/bin/env python3
"""Deterministic shared storage fixtures; no application migration is imported."""
import argparse
import copy
import hashlib
import json
import pathlib
import re
import sqlite3
import struct
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
STAMP = "2026-01-02 03:04:05.000"
OLLAMA = "00000000-0000-0000-0000-000000000000"
MODEL_A, MODEL_B = OLLAMA + ":model-a", OLLAMA + ":model-b"


def case(name, operation, expected, setup=None, **inputs):
    return dict(name=name, operation=operation, setupSql=setup or [],
                **inputs, expected=expected)


def envelope(name, cases, **metadata):
    return dict(contract=name, version=1, **metadata, cases=cases)


# BEGIN MIGRATION FIXTURES
# Frozen schema oracle, independent of either production v19 implementation.
# WP2 limits DDL is exact; retry nullability follows folder-rag-v1 §1b.
V19_SCHEMA = """
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
    model TEXT NOT NULL CHECK(length(trim(model)) > 0),
    context_window INTEGER NULL CHECK(context_window IS NULL OR context_window > 0),
    runtime_context INTEGER NOT NULL CHECK(runtime_context > 0),
    max_output_tokens INTEGER NOT NULL CHECK(max_output_tokens > 0),
    source TEXT NOT NULL CHECK(source IN ('auto', 'user')),
    PRIMARY KEY (provider_id, model),
    CHECK(context_window IS NULL OR runtime_context <= context_window),
    CHECK(max_output_tokens < runtime_context)
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
FTS_SCHEMA = """
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
NOTE_UUID = "00000000-0000-0000-0000-000000000021"
CITATIONS = '[ {"marker":1,"chunkId":1101,"sourceId":101,"snippet":"příliš ộ running"} ]'
SOURCE_IDS = list(range(101, 110)) + [201, 301, 302, 401]
# source, chunk, ordinal, text, model, dimension, malformed
LEGACY_CHUNKS = [
    (101, 1101, 0, "příliš ộ running", MODEL_A, 2, False),
    (102, 1102, 0, "legacy 102", MODEL_A, 2, False),
    (103, 1103, 0, "legacy 103", MODEL_A, 3, False),
    (104, 1104, 0, "legacy 104", MODEL_B, 2, False),
    (105, 1105, 0, "legacy 105", MODEL_A, 2, True),
    (108, 1108, 0, "first overlap", MODEL_A, 2, False),
    (108, 1109, 1, "overlap last", MODEL_B, 2, False),
    (201, 1201, 0, "legacy 201", MODEL_B, 2, False),
    (301, 1301, 0, "legacy 301", MODEL_A, 2, False),
    (302, 1302, 0, "legacy 302", MODEL_A, 3, False),
    (401, 1401, 0, "legacy 401", MODEL_A, 2, True),
]


def vector_blob(dims):
    return struct.pack("<" + "f" * dims, 1.0, *([0.0] * (dims - 1)))


def old_migrations():
    source = (ROOT / "windows/src/AINotebook.Core/Storage/Migrator.cs").read_text()
    literals = re.findall(r'private const string V(\d+) = """(.*?)""";', source, re.S)
    assert [int(n) for n, _ in literals] == list(range(1, 16)) + [18]
    identifiers = dict((int(n), name) for name, n in
                       re.findall(r'\("(v\d+_[a-z_]+)", V(\d+)\)', source))
    return [(int(n), identifiers[int(n)], sql) for n, sql in literals]


def build_v18(path: pathlib.Path) -> None:
    """Execute all shipped shared DDL, including fixed v6/v11 data steps."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    db = sqlite3.connect(path)
    try:
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)")
        for number, identifier, sql in old_migrations():
            for statement in sql.split("@@"):
                if statement.strip():
                    db.execute(statement)
            if number == 1:
                db.executemany("INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,?,?,?)",
                               [(n, f"notebook {n}", STAMP, STAMP) for n in range(1, 5)])
            if number == 5:
                db.execute("INSERT INTO notes(id,notebook_id,title,body_md,origin,created_at,updated_at) "
                           "VALUES(21,1,'legacy note','saved note body','manual',?,?)", (STAMP, STAMP))
            if number == 6:
                db.execute("UPDATE notes SET note_uuid=? WHERE id=21", (NOTE_UUID,))
            if number == 11:
                db.execute("INSERT INTO providers VALUES(?,'ollama','Ollama (local)',"
                           "'http://127.0.0.1:11434',1,1,?)", (OLLAMA, STAMP))
            if number == 12:
                db.execute("INSERT INTO notes_fts(rowid,title,body_md,note_id) "
                           "SELECT id,title,body_md,id FROM notes")
            db.execute("INSERT INTO grdb_migrations VALUES(?)", (identifier,))
        for sid in SOURCE_IDS:
            db.execute("INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,content_hash) "
                       "VALUES(?,?,'text',?,?,?,?)",
                       (sid, sid // 100, "příliš ộ running" if sid == 101 else f"legacy {sid}",
                        "pending" if sid == 106 else "ready", STAMP,
                        "stored-hash-101" if sid == 101 else "" if sid == 102 else None))
        for sid, cid, ordinal, value, model, dims, malformed in LEGACY_CHUNKS:
            db.execute("INSERT INTO source_chunks(id,source_id,ord,text,token_count,page_hint,context) "
                       "VALUES(?,?,?,?,3,2,'legacy context')", (cid, sid, ordinal, value))
            db.execute("INSERT INTO chunk_embeddings(chunk_id,dim,model,embedding) VALUES(?,?,?,?)",
                       (cid, dims, model, b"\x01\x02\x03" if malformed else vector_blob(dims)))
        db.execute("UPDATE notes SET auto_source_id=109 WHERE id=21")
        db.execute("INSERT INTO source_sets VALUES(11,1,'legacy set',?)", (STAMP,))
        db.execute("INSERT INTO source_set_members VALUES(11,101)")
        db.execute("INSERT INTO chat_sessions VALUES(31,1,'legacy chat',?)", (STAMP,))
        db.execute("INSERT INTO messages(id,session_id,role,content,citations_json,created_at) "
                   "VALUES(41,31,'assistant','saved answer',?,?)", (CITATIONS, STAMP))
        assert not db.execute("PRAGMA foreign_key_check").fetchall()
        assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert not db.execute("SELECT name FROM sqlite_master WHERE name IN "
                              "('folder_sources','scan_items','source_revisions','source_set_folders',"
                              "'ingest_jobs','provider_model_limits','index_generations','index_generation_manifest')").fetchall()
        db.commit()
    finally:
        db.close()


def logical_dump(path: pathlib.Path) -> dict:
    """Compare logical state, excluding writer-version bytes and FTS postings."""
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        schema = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master "
                            "WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
        fts_names = [name for kind, name, _, sql in schema
                     if kind == "table" and sql and "CREATE VIRTUAL TABLE" in sql.upper()]
        schema = [row for row in schema if not any(row[2].startswith(n + "_") for n in fts_names)]
        tables = {}
        for kind, name, _, _ in schema:
            if kind != "table":
                continue
            quoted = '"' + name.replace('"', '""') + '"'
            columns = [r[1] for r in db.execute(f"PRAGMA table_info({quoted})")]
            order = ",".join(str(n) for n in range(1, len(columns) + 1))
            rows = db.execute(f"SELECT * FROM {quoted} ORDER BY {order}").fetchall()
            tables[name] = [[{"hex": v.hex().upper()} if isinstance(v, bytes) else v
                             for v in row] for row in rows]
        fts_queries = {}
        for name in fts_names:
            for term in ["prilis", "o", "run", "legacy", "note"]:
                fts_queries[f"{name}:{term}"] = [r[0] for r in db.execute(
                    f'SELECT rowid FROM "{name}" WHERE "{name}" MATCH ? ORDER BY rowid', (term,))]
        return dict(schema=[list(r) for r in schema], tables=tables, ftsQueries=fts_queries)
    finally:
        db.close()


def query(name, sql, rows):
    return dict(name=name, sql=sql, rows=rows)


def schema_queries():
    """Schema-only reference: never run a production v19 migration/backfill."""
    tables = ["folder_sources", "scan_items", "source_revisions", "revision_pages", "sources", "source_chunks",
              "source_set_folders", "ingest_jobs", "notebooks", "provider_model_limits",
              "index_generations", "index_generation_manifest", "chunk_embeddings"]
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "schema.sqlite"
        build_v18(path)
        db = sqlite3.connect(path)
        try:
            # Only DDL is used for pragma expectations. Data projections below
            # are computed separately from fixed source rows and group arithmetic.
            db.executescript(V19_SCHEMA)
            db.execute("DROP TABLE chunk_embeddings_v18")
            queries = []
            for table in tables:
                # SQLite affinities, not platform-specific type spellings.
                sql = ("SELECT name,CASE WHEN upper(type) LIKE '%INT%' THEN 'INTEGER' "
                       "WHEN upper(type) LIKE '%CHAR%' OR upper(type) LIKE '%CLOB%' OR upper(type) LIKE '%TEXT%' THEN 'TEXT' "
                       "WHEN type='' OR upper(type) LIKE '%BLOB%' THEN 'BLOB' "
                       "WHEN upper(type) LIKE '%REAL%' OR upper(type) LIKE '%FLOA%' OR upper(type) LIKE '%DOUB%' THEN 'REAL' "
                       "ELSE 'NUMERIC' END,\"notnull\",dflt_value,pk "
                       f"FROM pragma_table_info('{table}') ORDER BY cid")
                queries.append(query(f"columns-{table}", sql, [list(r) for r in db.execute(sql)]))
                sql = (f'SELECT "from","table","to",on_update,on_delete,match '
                       f"FROM pragma_foreign_key_list('{table}') ORDER BY \"from\",\"table\",\"to\"")
                queries.append(query(f"foreign-keys-{table}", sql, [list(r) for r in db.execute(sql)]))
                # Compare PK/unique indexes by semantics; SQLite auto names are not a contract.
                sql = ("SELECT CASE WHEN il.origin='c' THEN il.name ELSE NULL END,"
                       "il.\"unique\",il.origin,il.partial,ii.seqno,ii.name "
                       f"FROM pragma_index_list('{table}') il JOIN pragma_index_info(il.name) ii "
                       "ORDER BY il.origin,il.\"unique\",il.partial,il.name,ii.seqno")
                queries.append(query(f"indexes-{table}", sql, [list(r) for r in db.execute(sql)]))
            sql = "SELECT name,pk FROM pragma_table_info('chunk_embeddings') ORDER BY cid"
            queries.append(query("schema-mismatch", sql, [["chunk_id", 1], ["generation_id", 2], ["embedding", 0]]))
            # Partial predicates are as material as the indexed columns.
            sql = ("SELECT name,lower(replace(replace(replace(substr(sql,instr(upper(sql),'WHERE')+5),"
                   "' ',''),char(10),''),char(13),'')) FROM sqlite_master "
                   "WHERE name IN ('idx_sources_folder_path','idx_one_active_generation') ORDER BY name")
            queries.append(query("partial-index-predicates", sql,
                                 [["idx_one_active_generation", "state='active'"],
                                  ["idx_sources_folder_path", "folder_idisnotnull"]]))
            return queries
        finally:
            db.close()


def legacy_groups(rows, configured):
    """The existing legacy-generation arithmetic, without importing its generator."""
    groups = {}
    for row in rows:
        count = row["vectorCount"] - row["malformedCount"]
        if count > 0:
            groups[(row["notebookId"], row["modelKey"], row["dims"])] = count
    active = {}
    for key, count in groups.items():
        nb, model, dims = key
        if model == configured:
            previous = active.get(nb)
            if previous is None or (-count, dims) < (-groups[previous], previous[2]):
                active[nb] = key
    return groups, active


def migration_contract():
    grouped = {}
    for sid, _, _, _, model, dims, malformed in LEGACY_CHUNKS:
        counts = grouped.setdefault((sid // 100, model, dims), [0, 0])
        counts[0] += 1
        counts[1] += int(malformed)
    inputs = [dict(notebookId=n, modelKey=m, dims=d, vectorCount=c[0], malformedCount=c[1])
              for (n, m, d), c in sorted(grouped.items())]
    base_queries = schema_queries()
    cases = []
    for name, configured in [("configured-a", MODEL_A), ("configured-b", MODEL_B),
                             ("unmatched", "not-configured"), ("no-selection", None)]:
        groups, active = legacy_groups(inputs, configured)
        queries = copy.deepcopy(base_queries)
        generation_rows, manifest_rows, vector_rows = [], [], []
        for key in sorted(groups, key=lambda k: (k[0], k[1].encode("utf-8"), k[2])):
            nb, model, dims = key
            state = "active" if active.get(nb) == key else "retired"
            generation_rows.append([nb, "legacy", "legacy", model, None, dims, "legacy",
                                    "legacy", "legacy", "legacy", state, STAMP,
                                    STAMP if state == "active" else None])
            members = [c for c in LEGACY_CHUNKS if (c[0] // 100, c[4], c[5]) == key and not c[6]]
            for sid in sorted({c[0] for c in members}):
                complete = sum(c[0] == sid for c in members) == sum(c[0] == sid for c in LEGACY_CHUNKS)
                manifest_rows.append([nb, model, dims, sid, sid, 1,
                                      "done" if complete else "excluded", None if complete else "legacy-incomplete"])
            for sid, cid, *_ in members:
                vector_rows.append([nb, model, dims, cid, vector_blob(dims).hex().upper()])
        queries += [
            query("generation-identity", "SELECT notebook_id,provider_id,endpoint_revision,model,model_digest,dims,"
                  "normalization,query_format_version,doc_format_version,chunker_version,state,created_at,activated_at "
                  "FROM index_generations ORDER BY notebook_id,CAST(model AS BLOB),dims", generation_rows),
            query("manifests", "SELECT g.notebook_id,g.model,g.dims,m.source_id,r.source_id,r.revision,m.state,m.reason "
                  "FROM index_generation_manifest m JOIN index_generations g ON g.id=m.generation_id "
                  "JOIN source_revisions r ON r.id=m.revision_id ORDER BY g.notebook_id,CAST(g.model AS BLOB),g.dims,m.source_id", manifest_rows),
            query("vector-bytes", "SELECT g.notebook_id,g.model,g.dims,e.chunk_id,hex(e.embedding) FROM chunk_embeddings e "
                  "JOIN index_generations g ON g.id=e.generation_id ORDER BY g.notebook_id,CAST(g.model AS BLOB),g.dims,e.chunk_id", vector_rows),
        ]
        revisions, pointers = [], []
        for sid in SOURCE_IDS:
            text = "\n\n".join(c[3] for c in sorted(LEGACY_CHUNKS, key=lambda c: (c[2], c[1])) if c[0] == sid)
            digest = "stored-hash-101" if sid == 101 else hashlib.sha256(text.encode()).hexdigest()
            revisions.append([sid, 1, digest, text, 1, 1, STAMP])
            pointers.append([sid, sid, 1, None if sid == 106 else sid, None if sid == 106 else 1])
        queries += [
            query("revision-backfill", "SELECT source_id,revision,content_hash,canonical_text,text_format_version,"
                  "chunker_version,created_at FROM source_revisions ORDER BY source_id,revision", revisions),
            query("source-pointers", "SELECT s.id,c.source_id,c.revision,p.source_id,p.revision FROM sources s "
                  "LEFT JOIN source_revisions c ON c.id=s.current_revision LEFT JOIN source_revisions p "
                  "ON p.id=s.published_revision_id ORDER BY s.id", pointers),
            query("source-additions", "SELECT id,folder_id,rel_path,mtime,size_bytes,availability,eligible,lang,"
                  "lang_coverage,descriptor,encoding FROM sources ORDER BY id",
                  [[sid, None, None, None, None, "present", 1, None, None, None, None] for sid in SOURCE_IDS]),
            query("chunks", "SELECT c.id,c.source_id,c.ord,c.text,c.token_count,c.page_hint,c.context,r.source_id,r.revision,"
                  "c.char_start,c.char_end,c.lang,c.lang_inherited FROM source_chunks c JOIN source_revisions r "
                  "ON r.id=c.revision_id ORDER BY c.id",
                  [[cid, sid, ordinal, value, 3, 2, "legacy context", sid, 1, None, None, None, 0]
                   for sid, cid, ordinal, value, *_ in sorted(LEGACY_CHUNKS, key=lambda c: c[1])]),
            query("citation-raw-bytes", "SELECT id,citations_json FROM messages WHERE id=41 ORDER BY id", [[41, CITATIONS]]),
            query("note-content", "SELECT id,title,body_md,auto_source_id,note_uuid FROM notes ORDER BY id",
                  [[21, "legacy note", "saved note body", 109, NOTE_UUID]]),
            query("members", "SELECT set_id,source_id FROM source_set_members ORDER BY set_id,source_id", [[11, 101]]),
            query("evidence-caps", "SELECT id,evidence_budget_cap FROM notebooks ORDER BY id", [[n, None] for n in range(1, 5)]),
            query("provider-unconverted", "SELECT id,type,name,base_url,enabled,privacy_acknowledged,created_at "
                  "FROM providers ORDER BY id", [[OLLAMA, "ollama", "Ollama (local)", "http://127.0.0.1:11434", 1, 1, STAMP]]),
            query("notes-fts-unchanged", "SELECT sql FROM sqlite_master WHERE name='notes_fts' ORDER BY name",
                  [["CREATE VIRTUAL TABLE notes_fts USING fts5(title, body_md, note_id UNINDEXED, tokenize = 'porter unicode61')"]]),
            query("v19-marker", "SELECT identifier FROM grdb_migrations WHERE identifier='v19_folder_rag' ORDER BY identifier", [["v19_folder_rag"]]),
            query("old-vector-table-removed", "SELECT name FROM sqlite_master WHERE name='chunk_embeddings_v18' ORDER BY name", []),
            query("immutability-triggers", "SELECT name,tbl_name FROM sqlite_master WHERE type='trigger' AND "
                  "name IN ('revisions_no_update','chunks_immutable','revision_pages_no_update') ORDER BY name",
                  [["chunks_immutable", "source_chunks"], ["revision_pages_no_update", "revision_pages"],
                   ["revisions_no_update", "source_revisions"]]),
        ]
        for table in ["folder_sources", "scan_items", "revision_pages", "source_set_folders", "ingest_jobs", "provider_model_limits"]:
            queries.append(query(f"empty-{table}", f"SELECT count(*) FROM {table}", [[0]]))
        for table in ["sources_fts", "chunks_fts"]:
            for term, rows in [("prilis", [[101]]), ("o", [[101]]), ("run", [])]:
                sql = (f"SELECT source_id FROM {table} WHERE {table} MATCH '{term}' ORDER BY source_id" if table == "sources_fts"
                       else f"SELECT c.source_id FROM chunks_fts JOIN source_chunks c ON c.id=chunks_fts.chunk_id "
                            f"WHERE chunks_fts MATCH '{term}' ORDER BY c.source_id,c.id")
                queries.append(query(f"{table}-{term}", sql, rows))
        cases.append(dict(name=name, configuredModelKey=configured, database="storage/v18.sqlite",
                          input=inputs, queries=queries, droppedMalformedByNotebook={"1": 1, "4": 1}))
    return envelope("storage-v19", cases,
                    schemaDDL=V19_SCHEMA, ftsDDL=FTS_SCHEMA,
                    decisions={"providerConfigConversion": "WP2 Tasks 4/5 invoke after v19; WP3 supplies schema only",
                               "jobRetryNullability": "folder-rag-v1 section 1b overrides WP3 NOT NULL",
                               "providerModelLimits": "exact WP2 plan DDL, including nonblank model CHECK"})
# END MIGRATION FIXTURES


# BEGIN V20 FIXTURES
# embedding-plan-v1 section 5: dedup ledger of every vector a build stores.
V20_SCHEMA = """
CREATE TABLE generation_text_hashes (
 generation_id INTEGER NOT NULL REFERENCES index_generations(id) ON DELETE CASCADE,
 chunk_id INTEGER NOT NULL REFERENCES source_chunks(id) ON DELETE CASCADE,
 text_hash TEXT NOT NULL CHECK(length(text_hash)=64),
 copied INTEGER NOT NULL CHECK(copied IN (0,1)),
 PRIMARY KEY(generation_id,chunk_id)
) WITHOUT ROWID;
CREATE INDEX idx_generation_text_hashes_hash ON generation_text_hashes(generation_id,text_hash);
CREATE INDEX idx_generation_text_hashes_chunk ON generation_text_hashes(chunk_id);
CREATE INDEX idx_generation_text_hashes_copied ON generation_text_hashes(generation_id) WHERE copied=1;
"""


def v20_contract():
    """Schema-only reference over the frozen v19 oracle; v20 adds one table and no data."""
    table = "generation_text_hashes"
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "schema.sqlite"
        build_v18(path)
        db = sqlite3.connect(path)
        try:
            db.executescript(V19_SCHEMA)
            db.execute("DROP TABLE chunk_embeddings_v18")
            db.executescript(V20_SCHEMA)
            queries = []
            sql = ("SELECT name,CASE WHEN upper(type) LIKE '%INT%' THEN 'INTEGER' "
                   "WHEN upper(type) LIKE '%TEXT%' THEN 'TEXT' ELSE 'OTHER' END,\"notnull\",dflt_value,pk "
                   f"FROM pragma_table_info('{table}') ORDER BY cid")
            queries.append(query(f"columns-{table}", sql, [list(r) for r in db.execute(sql)]))
            sql = (f'SELECT "from","table","to",on_update,on_delete,match '
                   f"FROM pragma_foreign_key_list('{table}') ORDER BY \"from\",\"table\",\"to\"")
            queries.append(query(f"foreign-keys-{table}", sql, [list(r) for r in db.execute(sql)]))
            sql = ("SELECT CASE WHEN il.origin='c' THEN il.name ELSE NULL END,"
                   "il.\"unique\",il.origin,il.partial,ii.seqno,ii.name "
                   f"FROM pragma_index_list('{table}') il JOIN pragma_index_info(il.name) ii "
                   "ORDER BY il.origin,il.\"unique\",il.partial,il.name,ii.seqno")
            queries.append(query(f"indexes-{table}", sql, [list(r) for r in db.execute(sql)]))
            sql = ("SELECT name,lower(replace(replace(replace(substr(sql,instr(upper(sql),'WHERE')+5),"
                   "' ',''),char(10),''),char(13),'')) FROM sqlite_master "
                   "WHERE name='idx_generation_text_hashes_copied' ORDER BY name")
            queries.append(query("partial-index-predicates", sql, [["idx_generation_text_hashes_copied", "copied=1"]]))
            sql = ("SELECT name,upper(replace(replace(replace(sql,' ',''),char(10),''),char(13),'')) LIKE '%)WITHOUTROWID' "
                   "FROM sqlite_master WHERE type='table' AND name='generation_text_hashes' ORDER BY name")
            queries.append(query("without-rowid", sql, [["generation_text_hashes", 1]]))
            sql = ("SELECT count(*) FROM pragma_table_info('generation_text_hashes') "
                   "WHERE name IN ('generation_id','chunk_id','text_hash','copied')")
            queries.append(query("column-count", sql, [[4]]))
            for name, sql in [
                ("columns-index_generations", "SELECT count(*) FROM pragma_table_info('index_generations')"),
                ("columns-source_chunks", "SELECT count(*) FROM pragma_table_info('source_chunks')"),
                ("columns-chunk_embeddings", "SELECT count(*) FROM pragma_table_info('chunk_embeddings')")]:
                queries.append(query(f"unchanged-{name}", sql, [list(r) for r in db.execute(sql)]))
        finally:
            db.close()
    cases = [dict(name="fresh-schema", queries=queries),
             dict(name="upgrade-from-v18", database="storage/v18.sqlite",
                  queries=[query("v20-marker", "SELECT identifier FROM grdb_migrations WHERE identifier "
                                 "IN ('v19_folder_rag','v20_embedding_dedup') ORDER BY identifier",
                                 [["v19_folder_rag"], ["v20_embedding_dedup"]]),
                           query("ledger-empty", "SELECT count(*) FROM generation_text_hashes", [[0]])])]
    return envelope("storage-v20", cases, schemaDDL=V20_SCHEMA, migration="v20_embedding_dedup",
                    decisions={"backfill": "none: vectors stored before v20 have no ledger row and are re-embedded "
                                           "at most once when a later duplicate needs them",
                               "contract": "docs/contracts/embedding-plan-v1.md section 5"})
# END V20 FIXTURES


# BEGIN CATALOG FIXTURES
def _catalog_insert(table, **values):
    """Render fixed fixture values, never platform-generated expected results."""
    def literal(value):
        if value is None:
            return "NULL"
        if isinstance(value, int):
            return str(value)
        return "'" + str(value).replace("'", "''") + "'"
    return ("INSERT INTO " + table + "(" + ",".join(values) + ") VALUES(" +
            ",".join(literal(value) for value in values.values()) + ");")


def _catalog_notebook(notebook_id):
    return _catalog_insert("notebooks", id=notebook_id,
                           name="catalog " + str(notebook_id),
                           created_at=STAMP, updated_at=STAMP)


def _catalog_folder(folder_id, notebook_id, state="idle"):
    return _catalog_insert(
        "folder_sources", id=folder_id, notebook_id=notebook_id,
        root_path="/docs" + str(folder_id),
        path_identity=json.dumps(dict(volumeId="volume-1",
                                      components=["docs" + str(folder_id)],
                                      rootFileId="root-" + str(folder_id)),
                                 ensure_ascii=False, separators=(",", ":")),
        display_name="Docs " + str(folder_id), include_exts='["md"]',
        ignore_globs="[]", limits="{}", scan_state=state, created_at=STAMP)


def _catalog_source(source_id, notebook_id=1, folder_id=1, status="ready",
                    availability="present", eligible=1):
    return _catalog_insert("sources", id=source_id, notebook_id=notebook_id,
                           type="text", title="source " + str(source_id),
                           status=status, ingested_at=STAMP,
                           folder_id=folder_id,
                           rel_path=str(source_id) + ".md" if folder_id else None,
                           availability=availability, eligible=eligible)


def _catalog_revision(source_id, revision_id, ordinal=1, published=True):
    text = "revision " + str(revision_id)
    statements = [_catalog_insert(
        "source_revisions", id=revision_id, source_id=source_id,
        revision=ordinal, content_hash=hashlib.sha256(text.encode()).hexdigest(),
        canonical_text=text, text_format_version=1, chunker_version=2,
        created_at=STAMP)]
    if published:
        statements.append(_catalog_insert(
            "source_chunks", id=revision_id + 1000, source_id=source_id,
            revision_id=revision_id, ord=0, text=text, token_count=3,
            char_start=0, char_end=len(text)))
    pointer = ",published_revision_id=" + str(revision_id) if published else ""
    statements.append("UPDATE sources SET current_revision=" + str(revision_id) +
                      pointer + " WHERE id=" + str(source_id) + ";")
    return statements


def _catalog_coverage_setup():
    statements = [_catalog_notebook(1), _catalog_notebook(2),
                  _catalog_folder(1, 1, "partial"), _catalog_folder(2, 2)]
    for source_id in range(1, 9):
        statements.append(_catalog_source(
            source_id, status={3: "error", 4: "pending", 5: "error"}.get(
                source_id, "ready"),
            availability={6: "missing", 7: "unavailable"}.get(source_id, "present"),
            eligible=0 if source_id == 8 else 1))
        statements.append(_catalog_insert(
            "scan_items", folder_id=1, rel_path=str(source_id) + ".md",
            kind="skipped" if source_id == 8 else "eligible",
            skip_reason="ignored" if source_id == 8 else None,
            mtime=1_000_000_000, size_bytes=10, seen_generation=1))
    for source_id in (1, 2, 3):
        statements += _catalog_revision(source_id, source_id * 100 + 1)
    for source_id in (2, 3):
        statements += _catalog_revision(source_id, source_id * 100 + 2,
                                        ordinal=2, published=False)
    statements += [
        _catalog_insert("scan_items", folder_id=1, rel_path="unsupported.bin",
                        kind="skipped", skip_reason="unsupported_ext",
                        mtime=1_000_000_000, size_bytes=10, seen_generation=1),
        _catalog_insert("scan_items", folder_id=1, rel_path="awaiting.md",
                        kind="eligible", skip_reason=None,
                        mtime=1_000_000_000, size_bytes=10, seen_generation=1),
        _catalog_source(20, notebook_id=2, folder_id=2),
    ]
    statements += _catalog_revision(20, 2001)
    statements.append(_catalog_insert(
        "index_generations", id=1, notebook_id=1, provider_id="legacy",
        endpoint_revision="legacy", model="m", dims=2,
        normalization="legacy", query_format_version="legacy",
        doc_format_version="legacy", chunker_version="legacy",
        state="active", created_at=STAMP, activated_at=STAMP))
    for source_id in (1, 2, 3):
        revision_id = source_id * 100 + 1
        statements.append(_catalog_insert(
            "index_generation_manifest", generation_id=1, source_id=source_id,
            revision_id=revision_id, state="done"))
        statements.append("INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) "
                          "VALUES(" + str(revision_id + 1000) + ",1,X'0000803F00000000');")
    return statements


def catalog_contract():
    cases = []
    overlap_inputs = [
        ("same-root", "/docs", "/docs/", ["docs"], ["docs"], True, {}),
        ("ancestor-root", "/docs", "/docs/a", ["docs"], ["docs", "a"], True, {}),
        ("descendant-root", "/docs/a", "/docs", ["docs", "a"], ["docs"], True, {}),
        ("component-boundary", "/docs", "/docs2", ["docs"], ["docs2"], False, {}),
        ("other-volume", "/docs", "/other/docs", ["docs"], ["docs"], False,
         dict(secondVolume="volume-2")),
        ("case-sensitive", "/Docs", "/docs", ["Docs"], ["docs"], False, {}),
        ("case-insensitive-alias", "/Docs", "/docs", ["docs"], ["docs"], True, {}),
        ("resolved-root-alias", "/alias", "/docs", ["docs"], ["docs"], True, {}),
        ("same-root-other-notebook", "/docs", "/docs/", ["docs"], ["docs"], False,
         dict(secondNotebookId=2)),
        ("persisted-root-identity", "/alias", "/docs", ["docs"], ["docs"], True,
         dict(reopen=True, afterReopenIdentities=[
             dict(rootPath="/alias", volumeId="volume-1", components=["elsewhere"], rootFileId="root-3"),
             dict(rootPath="/docs", volumeId="volume-1", components=["docs"], rootFileId="root-1")])),
        ("opaque-unicode-identity", "/é", "/é", ["é"], ["é"], False, {}),
    ]
    for name, first, second, first_components, second_components, rejected, extra in overlap_inputs:
        expected = dict(folderCount=1 if rejected else 2)
        if name == "same-root-other-notebook":
            expected["folderCountsByNotebook"] = {"1": 1, "2": 1}
        if name == "persisted-root-identity":
            expected["persistedIdentity"] = dict(volumeId="volume-1", components=["docs"], rootFileId="root-1")
            expected["resolvedPathsAfterReopen"] = ["/docs"]
        inputs = dict(firstPath=first, secondPath=second, volume="volume-1",
                      notebookId=1, firstComponents=first_components,
                      secondComponents=second_components, firstRootFileId="root-1",
                      secondRootFileId="root-1" if name == "opaque-unicode-identity" else "root-2", **extra)
        if rejected:
            inputs["expectedError"] = "overlappingRoot"
        cases.append(case(name, "overlap", expected, **inputs))

    relative_paths = ["/a", "../a", "a/../b", "a//b", "a/./b", "C:/a", "a\\b", "", "\x00"]
    cases.append(case(
        "relative-paths", "relative-paths", dict(acceptedPaths=["a/č😀.md"], rejectedCount=9),
        paths=[dict(path=path, valid=False, expectedError="invalidPath") for path in relative_paths] +
              [dict(path="a/č😀.md", valid=True)]))

    inventory_seed = [_catalog_notebook(1), _catalog_folder(1, 1)]
    inventory_inputs = [dict(folderId=1, relPath="a/č😀.md", kind="eligible", skipReason=None,
                             mtime=1_000_000_001, sizeBytes=10, seenGeneration=1),
                        dict(folderId=1, relPath="a/č😀.md", kind="eligible", skipReason=None,
                             mtime=1_000_000_002, sizeBytes=20, seenGeneration=2)]
    cases.append(case("inventory-upsert", "inventory-upsert",
                      dict(rowCount=1, items=[inventory_inputs[1]]), inventory_seed,
                      folderId=1, items=inventory_inputs))

    member_seed = [_catalog_notebook(1), _catalog_notebook(2),
                   _catalog_folder(1, 1), _catalog_folder(2, 2),
                   _catalog_source(1), _catalog_source(2, notebook_id=2, folder_id=None),
                   _catalog_insert("source_sets", id=1, notebook_id=1,
                                   name="selected", created_at=STAMP),
                   _catalog_insert("source_set_members", set_id=1, source_id=1),
                   _catalog_insert("source_set_folders", set_id=1, folder_id=1)]
    membership_expected = dict(sourceIds=[1], folderIds=[1], source2FolderId=None,
                               source2RelPath=None)
    cases.append(case(
        "cross-notebook-members", "membership", membership_expected, member_seed,
        events=[dict(op="setSourceSetMembers", setId=1, sourceIds=[1, 2],
                     expectedError="notebookMismatch", expected=membership_expected),
                dict(op="setSourceSetFolders", setId=1, folderIds=[1, 2],
                     expectedError="notebookMismatch", expected=membership_expected),
                dict(op="attachSource", sourceId=2, folderId=1, relPath="2.md",
                     expectedError="notebookMismatch", expected=membership_expected)]))

    remove_seed = member_seed + _catalog_revision(1, 101)
    remove_seed += [
        _catalog_insert("scan_items", folder_id=1, rel_path="1.md", kind="eligible",
                        seen_generation=1),
        _catalog_insert("index_generations", id=1, notebook_id=1, provider_id="legacy",
                        endpoint_revision="legacy", model="m", dims=2,
                        normalization="legacy", query_format_version="legacy",
                        doc_format_version="legacy", chunker_version="legacy",
                        state="active", created_at=STAMP, activated_at=STAMP),
        _catalog_insert("index_generation_manifest", generation_id=1, source_id=1,
                        revision_id=101, state="done"),
        "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(1101,1,X'0000803F00000000');",
        _catalog_insert("ingest_jobs", id=1, kind="extract", target="source:1",
                        target_revision=101, next_retry_at=None, state="done"),
    ]
    cases.append(case(
        "remove-folder", "remove-folder",
        dict(folderIds=[2], sourceIds=[2], scanItemCount=0, revisionCount=0,
             chunkCount=0, vectorCount=0, manifestCount=0, jobCount=0,
             sourceSetMemberIds=[], sourceSetFolderIds=[], sourceSetIds=[1],
             generationIds=[1], filesystemDeleteOperations=0, filesystemWriteOperations=0),
        remove_seed, folderId=1, filesystem=dict(existingPaths=["/docs1", "/docs1/1.md"])))

    coverage = dict(searchable=3, notSearchable=3, current=1, pending=2, error=1,
                    missing=1, unavailable=1, skipped=2,
                    refreshPending=3, refreshError=2, isLowerBound=True)
    empty = {field: False if field == "isLowerBound" else 0 for field in coverage}
    all_scope = dict(kind="all")
    coverage_seed = _catalog_coverage_setup()
    cases.append(case("coverage", "coverage", coverage, coverage_seed,
                      notebookId=1, scope=all_scope))
    cases.append(case("coverage-no-generation", "coverage", coverage,
                      coverage_seed + ["DELETE FROM index_generations;"],
                      notebookId=1, scope=all_scope))
    cases.append(case("empty-selection", "coverage", empty, coverage_seed,
                      notebookId=1, scope=dict(kind="selection", sourceIds=[], folderIds=[])))
    cases.append(case("other-notebook", "coverage",
                      dict(empty, searchable=1, current=1), coverage_seed,
                      notebookId=2, scope=all_scope))
    cases.append(case("explicit-source", "coverage",
                      dict(empty, searchable=1, refreshPending=1, isLowerBound=True),
                      coverage_seed, notebookId=1,
                      scope=dict(kind="selection", sourceIds=[2], folderIds=[])))
    cases.append(case("folder-union", "coverage", coverage, coverage_seed,
                      notebookId=1,
                      scope=dict(kind="selection", sourceIds=[1, 2], folderIds=[1])))

    cases.append(case(
        "evidence-cap", "evidence-cap", dict(value=None), [_catalog_notebook(1)],
        notebookId=1, values=[None, 0, 4096, None, -1],
        expectedValues=[None, 0, 4096, None, None],
        expectedErrors=[None, None, None, None, "invalidValue"], expectedError="invalidValue"))

    other_provider = "00000000-0000-0000-0000-000000000001"
    limits_seed = [_catalog_insert("providers", id=other_provider, type="ollama",
                                   name="other", base_url="http://127.0.0.1:11435",
                                   created_at=STAMP)]
    automatic = dict(providerId=OLLAMA, model="model-a", contextWindow=None,
                     runtimeContext=8192, maxOutputTokens=1024, source="auto")
    override = dict(automatic, contextWindow=16384, maxOutputTokens=2048, source="user")
    second_model = dict(automatic, model="model-b", runtimeContext=4096)
    second_provider = dict(automatic, providerId=other_provider, runtimeContext=2048)
    invalid_inputs = [
        ("runtime-over-context", dict(override, runtimeContext=32768)),
        ("output-equals-runtime", dict(override, maxOutputTokens=8192)),
        ("output-over-runtime", dict(override, maxOutputTokens=8193)),
        ("zero-context", dict(override, contextWindow=0)),
        ("negative-context", dict(override, contextWindow=-1)),
        ("zero-runtime", dict(override, runtimeContext=0)),
        ("negative-runtime", dict(override, runtimeContext=-1)),
        ("zero-output", dict(override, maxOutputTokens=0)),
        ("negative-output", dict(override, maxOutputTokens=-1)),
        ("empty-model", dict(override, model="")),
        ("blank-model", dict(override, model="   ")),
    ]
    events = [dict(op="get", providerId=OLLAMA, model="model-a", expected=None),
              dict(op="set", limits=automatic, before=None, expected=automatic),
              dict(op="set", limits=override, before=automatic, expected=override),
              dict(op="set", limits=second_model, before=None, expected=second_model),
              dict(op="set", limits=second_provider, before=None, expected=second_provider)]
    final_records = [override, second_model, second_provider]
    for name, limits in invalid_inputs:
        events.append(dict(op="set", name=name, limits=limits, expectedError="invalidValue",
                           expectedRecords=final_records))
    cases.append(case("limits", "limits", dict(records=final_records), limits_seed,
                      before=automatic, after=override, events=events,
                      readKeys=[dict(providerId=record["providerId"], model=record["model"])
                                for record in final_records]))
    return envelope("storage-catalog", cases)
# END CATALOG FIXTURES


# BEGIN JOB FIXTURES
def revision_seed():
    """Concrete v19 rows shared by revision and generation API scenarios."""
    return [
        f"INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(1,'revisions','{STAMP}','{STAMP}')",
        f"INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(1,1,'text','source one','ready','{STAMP}')",
        f"INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at) VALUES(101,1,1,'old-hash','old',1,2,'{STAMP}')",
        "UPDATE sources SET current_revision=101,published_revision_id=101 WHERE id=1",
        "INSERT INTO source_chunks(id,source_id,ord,text,token_count,revision_id,char_start,char_end) VALUES(1001,1,0,'old',1,101,0,3)",
    ]


def jobs_revision_contract():
    """Hand-authored database inputs and normative job-transition snapshots."""
    seed = revision_seed()
    draft = dict(contentHash="new-hash", canonicalText="new", textFormatVersion=1,
                 chunkerVersion=2)
    chunk = dict(text="new", tokenCount=1, pageHint=None, charStart=0, charEnd=3,
                 lang=None, langInherited=False)

    def revision_case(name, expected, **inputs):
        return case(name, "publish", expected, seed, sourceId=1,
                    draft=copy.deepcopy(draft), chunks=[copy.deepcopy(chunk)],
                    now=0, leaseToken="owner", **inputs)

    cases = [case("scalar-spans", "publish",
                  dict(scalarCount=5, chunkCount=1, jobState="done", revisionId=102), seed,
                  sourceId=1, canonicalText="A😀éZ", chunkText="😀é", start=1, end=4,
                  draft=dict(contentHash="scalar-hash", canonicalText="A😀éZ",
                             textFormatVersion=1, chunkerVersion=2),
                  chunks=[dict(text="😀é", tokenCount=1, pageHint=None, charStart=1,
                               charEnd=4, lang=None, langInherited=False)],
                  now=0, leaseToken="owner"),
             case("immutable", "revision-update", dict(revisionId=101, canonicalText="old"),
                  seed, sql="UPDATE source_revisions SET canonical_text='changed' WHERE id=101",
                  expectedError="immutableRevision", expectedSqlError="immutable revision")]
    empty = revision_case("empty-publication", dict(currentRevision=102, publishedRevisionId=102,
                          visibleChunkIds=[], retainedChunkIds=[1001], jobState="done"))
    empty["draft"]["canonicalText"] = ""
    empty["draft"]["contentHash"] = "empty-hash"
    empty["chunks"] = []
    cases.extend([empty, revision_case("old-chunks-retained",
        dict(currentRevision=102, publishedRevisionId=102, visibleTexts=["new"],
             retainedChunkIds=[1001], chunkCount=1, jobState="done"))])
    wrong_setup = seed + [
        f"INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(2,1,'text','source two','ready','{STAMP}')",
        f"INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at) VALUES(102,1,2,'new-hash','new',1,2,'{STAMP}')",
        f"INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at) VALUES(201,2,1,'other-hash','other',1,2,'{STAMP}')",
        "UPDATE sources SET current_revision=102 WHERE id=1",
        "UPDATE sources SET current_revision=201,published_revision_id=201 WHERE id=2",
    ]
    cases.append(case("wrong-source", "publish", dict(publishedRevisionId=101,
        observedSourceId=1, revisionId=102, chunkCount=0), wrong_setup, sourceId=2,
        revisionId=102, chunks=[chunk], jobSourceId=1, target="source:1", targetRevision=102,
        now=0, leaseToken="owner", expectedError="staleRevision",
        expectedSqlError="revision mismatch"))
    for name in ("stale-revision-publication", "revision-not-current"):
        cases.append(revision_case(name, dict(result=False, currentRevision=103,
            publishedRevisionId=101, revisionId=102, chunkCount=0, jobState="cancelled"),
            revisionDrafts=[copy.deepcopy(draft), dict(contentHash="newer-hash",
                canonicalText="newer", textFormatVersion=1, chunkerVersion=2)],
            publishRevisionId=102, targetRevision=102))
    rollback = revision_case("publish-rollback", dict(revisionId=102, chunkCount=0,
        publishedRevisionId=101, jobState="running"), expectedError="invalidSpan")
    rollback["chunks"] = [dict(chunk, text="n", charEnd=1),
                          dict(chunk, text="wrong", charStart=1)]
    cases.extend([rollback, revision_case("double-publish", dict(results=[True, False],
        revisionId=102, chunkCount=1, publishedRevisionId=102, jobState="done"),
        publishTimes=[1, 2])])
    for name, text, part, start, end in [
        ("invalid-span-range", "A😀éZ", "😀é", 1, 6),
        ("invalid-span-order", "A😀éZ", "😀é", 4, 1),
        ("invalid-span-null", "A😀éZ", "😀é", 1, None),
        ("invalid-span-text", "é", "é", 0, 1),
    ]:
        c = revision_case(name, dict(revisionId=102, chunkCount=0,
            publishedRevisionId=101, jobState="running"), expectedError="invalidSpan",
            canonicalText=text, chunkText=part, start=start, end=end)
        c["draft"]["canonicalText"] = text
        c["chunks"] = [dict(chunk, text=part, charStart=start, charEnd=end)]
        cases.append(c)
    cases.append(case("superseded-extraction", "extraction", dict(resultA=None,
        resultB=102, publishedText="new", publishedRevisionId=102,
        currentRevision=102, newRevisionCount=1, jobStates={"A":"cancelled", "B":"done"},
        snapshots=[dict(currentRevision=101, publishedRevisionId=101, jobStates={"A":"running"}),
                   dict(currentRevision=101, publishedRevisionId=101, jobStates={"A":"cancelled","B":"running"}),
                   dict(currentRevision=102, publishedRevisionId=102, jobStates={"A":"cancelled","B":"done"}, result=102),
                   dict(currentRevision=102, publishedRevisionId=102, jobStates={"A":"cancelled","B":"done"}, result=None)]),
        seed, sourceId=1, events=[dict(op="begin", at=0, token="A"),
            dict(op="begin", at=1, token="B"),
            dict(op="commit", at=2, token="B", draft=copy.deepcopy(draft), chunks=[chunk]),
            dict(op="commit", at=3, token="A", draft=dict(draft, canonicalText="old"),
                 chunks=[dict(chunk, text="old")])]))
    cases.append(case("renew-running-extraction", "extraction", dict(leaseUntilBeforeCommit=360,
        attempts=1, revisionId=102, currentRevision=102, publishedRevisionId=102,
        jobState="done", returnedSource=dict(currentRevision=102, publishedRevisionId=102),
        snapshots=[dict(state="running",attempts=1,nextRetryAt=None,leaseUntil=300,leaseToken="A",result=True),
                   dict(state="running",attempts=1,nextRetryAt=None,leaseUntil=360,leaseToken="A",result=True),
                   dict(state="done",attempts=1,nextRetryAt=None,leaseUntil=None,leaseToken=None,result=102)]),
        seed, sourceId=1, events=[dict(op="begin", at=0, token="A"),
            dict(op="renew", at=60, token="A"),
            dict(op="commit", at=301, token="A", draft=copy.deepcopy(draft), chunks=[chunk])],
        withoutRenewal=dict(commitAt=300, result=None, newRevisionCount=0,
                            publishedRevisionId=101)))

    def snap(state, attempts, retry, until, token, result, error=None, **extra):
        return dict(state=state, attempts=attempts, nextRetryAt=retry, leaseUntil=until,
                    leaseToken=token, result=result, error=error, **extra)

    def event(op, at, token=None, **extra):
        return dict(op=op, at=at, token=token, **extra)

    def jobs(name, events, snapshots, **extra):
        assert len(events) == len(snapshots), name
        return case(name, "jobs", dict(snapshots=snapshots), seed,
            kind="extract", target="source:1", targetRevision=101, enqueueAt=0,
            events=events, **extra)

    cases.append(jobs("lease-timeline", [event("claim",0,"A"), event("renew",60,"A"),
        event("fail",61,"A",error="io"), event("claim",120,"B"), event("retry",121),
        event("claim",121,"C"), event("recover",421), event("claim",541,"D")], [
        snap("running",1,None,300,"A",True), snap("running",1,None,360,"A",True),
        snap("failed",1,121,None,None,True,"io"), snap("failed",1,121,None,None,False,"io"),
        snap("queued",1,121,None,None,True,"io"), snap("running",2,None,421,"C",True),
        snap("queued",2,541,None,None,True,"leaseExpired"), snap("running",3,None,841,"D",True)]))
    for name, at, token in (("token-fence",1,"B"), ("expiry-fence",300,"A")):
        events = [event("claim",0,"A")] + [event(op,at,token,**(
            {"error":"io"} if op == "fail" else {})) for op in ("renew","complete","fail","publish")]
        cases.append(jobs(name, events, [snap("running",1,None,300,"A",True)] +
            [snap("running",1,None,300,"A",False) for _ in range(4)],
            publishedRevisionIdBefore=101, expectedPublishedRevisionId=101))
    exhausted_events, exhausted_snapshots = [], []
    start_times, retry_times = [0,60,180,420,900], [60,180,420,900,None]
    for attempt, (at, retry) in enumerate(zip(start_times,retry_times),1):
        token = f"attempt-{attempt}"
        if attempt > 1:
            exhausted_events.append(event("retry",at))
            exhausted_snapshots.append(snap("queued",attempt-1,at,None,None,True,"io"))
        exhausted_events.extend([event("claim",at,token),event("fail",at,token,error="io")])
        exhausted_snapshots.extend([snap("running",attempt,None,at+300,token,True),
                                   snap("failed",attempt,retry,None,None,True,"io")])
    exhausted_events.extend([event("retry",1860),event("claim",1860,"attempt-6")])
    exhausted_snapshots.extend([snap("failed",5,None,None,None,False,"io") for _ in range(2)])
    cases.append(jobs("exhaustion",exhausted_events,exhausted_snapshots,
                      startTimes=start_times, retryTimes=retry_times, expectedClaims=5))
    fifth_events = copy.deepcopy(exhausted_events[:-4])
    fifth_snapshots = copy.deepcopy(exhausted_snapshots[:-4])
    fifth_events.extend([event("claim",900,"attempt-5"),event("recover",1200),
                         event("retry",2160),event("claim",2160,"attempt-6")])
    fifth_snapshots.extend([snap("running",5,None,1200,"attempt-5",True),
        snap("failed",5,None,None,None,True,"leaseExpired"),
        snap("failed",5,None,None,None,False,"leaseExpired"),
        snap("failed",5,None,None,None,False,"leaseExpired")])
    cases.append(jobs("expired-fifth",fifth_events,fifth_snapshots,expectedClaims=5))
    pause_events = [event("pause",1),event("resume",2),event("claim",2,"A"),
        event("pause",3,expectedError="invalidValue"),event("cancel",4),
        event("renew",5,"A"),event("complete",5,"A"),event("fail",5,"A",error="io"),
        event("publish",5,"A"),event("resume",6,expectedError="invalidValue")]
    pause_snaps = [snap("paused",0,0,None,None,True),snap("queued",0,0,None,None,True),
        snap("running",1,None,302,"A",True),
        snap("running",1,None,302,"A",False,expectedError="invalidValue"),
        snap("cancelled",1,None,None,None,True)] + [snap("cancelled",1,None,None,None,False)
        for _ in range(4)] + [snap("cancelled",1,None,None,None,False,expectedError="invalidValue")]
    cases.append(jobs("pause-resume-cancel",pause_events,pause_snaps))
    cases.append(case("claim-order", "jobs", dict(claimedJobIds=[2,3],
        snapshots=[dict(jobId=2,**snap("running",1,None,310,"A",True)),
                   dict(jobId=3,**snap("running",1,None,310,"B",True))]), seed,
        jobs=[dict(id=1,kind="extract",target="source:1",targetRevision=101,nextRetryAt=20),
              dict(id=2,kind="extract",target="source:1",targetRevision=101,nextRetryAt=10),
              dict(id=3,kind="extract",target="source:1",targetRevision=101,nextRetryAt=10)],
        events=[event("claim",10,"A"),event("claim",10,"B")]))
    cases.append(jobs("restart-reclaim", [event("claim",0,"A"),event("reopen",1),
        event("recover",300),event("claim",360,"B"),event("publish",361,"A")], [
        snap("running",1,None,300,"A",True),snap("running",1,None,300,"A",True),
        snap("queued",1,360,None,None,True,"leaseExpired"),snap("running",2,None,660,"B",True),
        snap("running",2,None,660,"B",False)], expectedPublishedRevisionId=101))
    cases.append(case("two-connections-single-claim", "jobs", dict(
        successfulClaims=1, attempts=1, state="running", nextRetryAt=None, leaseUntil=300,
        winningTokens=["A","B"]),seed,kind="extract",target="source:1",targetRevision=101,
        enqueueAt=0,events=[event("claim",0,"A",connection=1),event("claim",0,"B",connection=2)],
        synchronization="release-both-connections-before-claim"))
    return envelope("storage-jobs-revisions", cases,
        contractDecisions=[
            "folder-rag-v1 section 1b overrides the older WP3 job SQL and DTO: nextRetryAt is nullable and cleared on start and completion.",
            "Normal failure is failed with a retry deadline; a separate due retry moves it to queued. Fifth failure or expiry is failed with no deadline.",
            "Pause accepts queued jobs only; resume preserves the existing retry deadline. Running pause is invalidValue.",
            "wrong-source maps revision ownership mismatch to the existing staleRevision code; direct SQL trigger text remains revision mismatch.",
        ], snapshotResult="Boolean acceptance; recovery count is normalized to count > 0; thrown errors are false with expectedError.",
        nullableNextRetryAt=True)
# END JOB FIXTURES


# BEGIN GENERATION AND INTEGRATION FIXTURES
def generation_identity(**overrides):
    return dict(dict(providerId="legacy", endpointRevision="legacy", model="m",
                     modelDigest=None, dims=2, normalization="legacy",
                     queryFormatVersion="legacy", docFormatVersion="legacy",
                     chunkerVersion="legacy"), **overrides)


def generation_seed(building=True):
    statements = revision_seed() + [
        "INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,"
        "model_digest,dims,normalization,query_format_version,doc_format_version,"
        "chunker_version,state,created_at,activated_at) VALUES"
        f"(1,1,'legacy','legacy','m',NULL,2,'legacy','legacy','legacy','legacy','active','{STAMP}','{STAMP}')",
        "INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason) "
        "VALUES(1,1,101,'done',NULL)",
        "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) "
        "VALUES(1001,1,X'0000803F00000000')",
    ]
    if building:
        statements += [
            "INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,"
            "model_digest,dims,normalization,query_format_version,doc_format_version,"
            "chunker_version,state,created_at,activated_at) VALUES"
            f"(2,1,'legacy','legacy','m',NULL,2,'legacy','legacy','legacy','legacy','building','{STAMP}',NULL)",
            "INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason) "
            "VALUES(2,1,101,'pending',NULL)",
        ]
    return statements


def generation_contract():
    base = generation_seed()
    manifest = dict(sourceId=1, revisionId=101, state="done", reason=None)
    vector = dict(op="storeEmbedding", generationId=2, chunkId=1001, vector=[1, 0])
    finish = [vector, dict(op="setManifest", generationId=2, entries=[manifest]),
              dict(op="activate", generationId=2, at=2)]
    publish_new = dict(op="commitForegroundRevision", sourceId=1, at=1, token="new",
                       draft=dict(contentHash="new-hash", canonicalText="new",
                                  textFormatVersion=1, chunkerVersion=2),
                       chunks=[dict(text="new", tokenCount=1, pageHint=None,
                                    charStart=0, charEnd=3, lang=None, langInherited=False)])
    pin = dict(op="pinQuery", notebookId=1, modelKey="m", saveAs="oldPin")
    gc = dict(op="garbageCollect", notebookId=1)
    new_revision_sql = [
        "INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,"
        f"text_format_version,chunker_version,created_at) VALUES(102,1,2,'new-hash','new',1,2,'{STAMP}')",
        "INSERT INTO source_chunks(id,source_id,ord,text,token_count,revision_id,char_start,char_end) "
        "VALUES(1002,1,0,'new',1,102,0,3)",
        "UPDATE sources SET current_revision=102,published_revision_id=102 WHERE id=1",
    ]
    cases = [
        case("pending-blocks", "generation", {"activeId": 1, "manifestState": "pending"}, base,
             events=[dict(op="activate", generationId=2, at=1)], expectedError="generationNotReady"),
        case("changed-current-blocks", "generation",
             {"activeId": 1, "currentRevision": 102, "publishedRevisionId": 102,
              "manifestAfterReconcile": [dict(sourceId=1, revisionId=102, state="pending", reason=None)]}, base,
             events=finish[:2] + [publish_new, dict(op="activate", generationId=2, at=2,
                                       expectedError="generationNotReady"),
                     dict(op="reconcile", generationId=2)], expectedError="generationNotReady"),
        case("new-source-blocks", "generation",
             {"activeId": 1, "manifestAfterReconcile": [dict(sourceId=1, revisionId=101, state="done", reason=None),
                                                        dict(sourceId=2, revisionId=201, state="pending", reason=None)]}, base,
             events=finish[:2] + [dict(op="executeSql", sql=[
                 f"INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(2,1,'text','second','ready','{STAMP}')",
                 "INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,"
                 f"text_format_version,chunker_version,created_at) VALUES(201,2,1,'second-hash','second',1,2,'{STAMP}')",
                 "INSERT INTO source_chunks(id,source_id,ord,text,token_count,revision_id,char_start,char_end) "
                 "VALUES(2001,2,0,'second',2,201,0,6)",
                 "UPDATE sources SET current_revision=201,published_revision_id=201 WHERE id=2"]),
                 dict(op="activate", generationId=2, at=1, expectedError="generationNotReady"),
                 dict(op="reconcile", generationId=2)], expectedError="generationNotReady"),
        case("missing-vector-blocks", "generation", {"activeId": 1, "manifestState": "pending", "vectorCount": 0}, base,
             events=[dict(op="setManifest", generationId=2, entries=[manifest])], expectedError="generationNotReady"),
        case("wrong-dim-blocks", "generation", {"activeId": 1, "vectorCount": 0}, base,
             events=[dict(op="storeEmbedding", generationId=2, chunkId=1001, vector=[1, 0, 0])], expectedError="invalidVector"),
        case("cross-notebook-blocks", "generation", {"activeId": 1, "manifestRowCount": 1}, base + [
            f"INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(2,'other','{STAMP}','{STAMP}')",
            f"INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(3,2,'text','other','ready','{STAMP}')",
            "INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,"
            f"text_format_version,chunker_version,created_at) VALUES(301,3,1,'other-hash','other',1,2,'{STAMP}')",
            "UPDATE sources SET current_revision=301,published_revision_id=301 WHERE id=3"],
             events=[dict(op="setManifest", generationId=2,
                          entries=[dict(sourceId=3, revisionId=301, state="pending", reason=None)])],
             expectedError="notebookMismatch"),
        case("excluded-requires-reason", "generation",
             {"activeId": 2, "previousState": "retired", "manifestState": "excluded", "reason": "extract-error",
              "errors": ["invalidValue", "invalidValue", None]}, base,
             events=[dict(op="setManifest", generationId=2,
                          entries=[dict(sourceId=1, revisionId=101, state="excluded", reason=reason)],
                          expectedError="invalidValue" if reason in (None, "") else None)
                     for reason in (None, "", "extract-error")] + [dict(op="activate", generationId=2, at=1)]),
        case("single-active", "generation", {"activeCount": 1, "activeId": 2, "previousState": "retired", "newState": "active"},
             base, canonicalText="old", vector=[1, 0], events=finish),
        case("retire", "generation", {"state": "retired", "activeCount": 0}, generation_seed(False),
             events=[dict(op="retire", generationId=1), dict(op="retire", generationId=1)]),
        case("pin-retains-retired", "generation",
             {"activeId": 2, "generationIds": [1, 2], "pinnedChunkIds": [1001],
              "pinnedRevisionIds": [101], "oldVectorHex": "0000803F00000000",
              "gc": dict(generations=0, revisions=0, chunks=0, vectors=0)}, base,
             events=[pin] + finish + [gc, dict(op="pinnedEmbeddings", pin="oldPin")]),
        case("release-then-gc", "generation",
             {"activeId": 2, "generationIds": [2], "revisionIds": [101], "chunkIds": [1001],
              "gc": dict(generations=1, revisions=0, chunks=0, vectors=1)}, base,
             events=[pin] + finish + [gc, dict(op="releaseQuery", pin="oldPin"), gc]),
        case("published-lexical-retained", "generation",
             {"activeId": None, "generationIds": [], "publishedRevisionId": 101,
              "revisionIds": [101], "chunkIds": [1001],
              "gc": dict(generations=1, revisions=0, chunks=0, vectors=1)}, generation_seed(False),
             events=[dict(op="retire", generationId=1), gc]),
        case("building-retained", "generation",
             {"activeId": None, "generationIds": [2], "currentRevision": 102, "publishedRevisionId": 102,
              "revisionIds": [101, 102], "chunkIds": [1001, 1002],
              "gc": dict(generations=1, revisions=0, chunks=0, vectors=1)}, base + new_revision_sql,
             events=[dict(op="retire", generationId=1), gc]),
        case("cancelled-job-reference", "generation",
             {"activeId": None, "generationIds": [], "revisionIds": [102], "chunkIds": [1002], "jobIds": [],
              "gc": dict(generations=1, revisions=1, chunks=1, vectors=1)},
             generation_seed(False) + new_revision_sql + [
                 "INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token,error) "
                 "VALUES(1,'extract','source:1',101,1,NULL,'cancelled',NULL,NULL,NULL)"],
             events=[dict(op="retire", generationId=1), gc]),
        case("legacy-partial-preserved", "generation",
             {"vectors": [[1108, MODEL_A, 2, "0000803F00000000"], [1109, MODEL_B, 2, "0000803F00000000"]],
              "manifestRows": [[MODEL_A, 2, "excluded", "legacy-incomplete"],
                               [MODEL_B, 2, "excluded", "legacy-incomplete"]]},
             fixture="storage/v18.sqlite", configuredModelKey=MODEL_A, sourceId=108,
             events=[dict(op="upgrade", configuredModelKey=MODEL_A), dict(op="inspectSource", sourceId=108)]),
        case("copy-successor", "generation",
             {"activeId": 1, "initialVectorHex": "0000803F00000000", "initialManifestState": "done",
              "manifestAfterReconcile": [dict(sourceId=1, revisionId=102, state="pending", reason=None)],
              "buildingEvidenceChunkIds": [], "retainedCopiedChunkIds": [1001]}, base,
             events=[dict(op="copyUnchangedVectors", fromGenerationId=1, toGenerationId=2, excludingChunkId=None),
                     dict(op="inspect", generationId=2), publish_new,
                     dict(op="reconcile", generationId=2), dict(op="inspectEvidence", generationId=2)]),
        case("vector-normalization", "generation",
             {"activeId": 1, "embeddingHex": "9A99193FCDCC4C3F", "vectorCount": 1,
              "errors": [None, "invalidVector", "invalidVector", "invalidVector"]},
             base + ["UPDATE index_generations SET provider_id='provider-A',endpoint_revision='1',model='m',"
                     "normalization='l2',query_format_version='1',doc_format_version='1',chunker_version='2' WHERE id=2"],
             identity=generation_identity(providerId="provider-A", endpointRevision="1", normalization="l2",
                                          queryFormatVersion="1", docFormatVersion="1", chunkerVersion="2"),
             vectors=[[3, 4], [0, 0], ["NaN", 0], ["Infinity", 0]],
             events=[dict(op="storeEmbedding", generationId=2, chunkId=1001, vector=values,
                          expectedError=None if values == [3, 4] else "invalidVector")
                     for values in ([3, 4], [0, 0], ["NaN", 0], ["Infinity", 0])]),
        case("pin-cross-store", "generation",
             {"generationIdsWhilePinned": [1, 2], "generationIdsAfterRelease": [2],
              "pinnedChunkIds": [1001], "deadlock": False}, base,
             interleavings=[
                 ["storeA.pin.registryLock", "storeB.gc.waitRegistry", "storeA.pin.readAndRegister",
                  "storeA.pin.commitAndUnlock", "storeB.gc.lockReadCommit"],
                 ["storeB.gc.registryLock", "storeA.pin.waitRegistry", "storeB.gc.readCommitAndUnlock",
                  "storeA.pin.lockReadAndRegister"]],
             events=[dict(pin, store="A")] + [dict(event, store="A") for event in finish] +
                    [dict(gc, store="B"), dict(op="pinnedEmbeddings", pin="oldPin", store="A"),
                     dict(op="releaseQuery", pin="oldPin", store="A"), dict(gc, store="B")]),
    ]
    # The float oracle has no dependency on either platform's vector writer.
    norm = (3 * 3 + 4 * 4) ** 0.5
    assert struct.pack("<ff", 3 / norm, 4 / norm).hex().upper() == "9A99193FCDCC4C3F"
    return envelope("storage-generations", cases, identity=generation_identity(),
                    integerIdMeaning="source_revisions.id", blobEncoding="little-endian-float32")


def scalar_window_oracle(text, window, overlap, page_starts):
    """Independent scalar-index reference: enumerate legal window breakpoints."""
    assert window > overlap >= 0
    whitespace = set(range(9, 14)) | set(range(0x2000, 0x200B)) | {
        0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000}
    assert not any(0xD800 <= ord(c) <= 0xDFFF for c in text)
    start, result = 0, []
    while start < len(text):
        boundary = min(start + window, len(text))
        if boundary != len(text):
            floor = max(boundary - 200, start + 1)
            breaks = [offset for offset in range(floor + 1, boundary + 1)
                      if ord(text[offset - 1]) in whitespace]
            if breaks:
                boundary = breaks[-1]
        visible = [i for i in range(start, boundary) if ord(text[i]) not in whitespace]
        if visible:
            lo, hi = visible[0], visible[-1] + 1
            pages = [page for offset, page in page_starts if offset <= lo]
            result.append(dict(text=text[lo:hi], start=lo, end=hi,
                               pageHint=pages[-1] if pages else None,
                               tokenCount=max(1, (hi - lo + 3) // 4)))
        if boundary == len(text):
            break
        start = max(boundary - overlap, start + 1)
    return result


def integration_contract():
    cases = [
        case("replacement", "integration",
             {"retainedOldChunkCount": 1, "oldHits": 0, "newHits": 1,
              "visibleTexts": ["currentword"], "returnedSourcePointersEqual": True},
             old="obsoleteword", new="currentword",
             events=[dict(op="replaceChunks", text="obsoleteword"), dict(op="captureOldChunk"),
                     dict(op="replaceChunks", text="currentword"), dict(op="search", query="obsoleteword"),
                     dict(op="search", query="currentword")]),
        case("no-vector-provider-call", "integration", {"providerCalls": 0, "hits": 1},
             query="currentword", text="currentword", modelKey="unconfigured",
             events=[dict(op="publish", text="currentword"), dict(op="search", query="currentword")]),
        case("empty-note", "integration", {"visibleChunks": 0, "shadowSourceExists": True, "published": True},
             body="", initialBody="previous body", events=[dict(op="indexNote", body="previous body"),
                                                          dict(op="indexNote", body="")]),
        case("scalar-text", "integration",
             {"canonicalText": "  A😀éZ  ", "scalarCount": 9,
              "chunks": [dict(text="A😀éZ", start=2, end=7, pageHint=None, tokenCount=2)]},
             text="  A😀éZ  ", window=2048, overlap=256, pageStarts=[]),
        case("pdf-pages", "integration",
             {"canonicalText": "Část 😀\n\ndruhá", "pageStarts": [[0, 1], [8, 2]], "scalarCount": 13,
              "chunks": [dict(text="Část 😀\n\ndruhá", start=0, end=13, pageHint=1, tokenCount=4)]},
             pages=["Část 😀", "druhá"], extractedText="Část 😀\fdruhá", pageHints=[1, 2],
             window=2048, overlap=256),
        case("model-switch", "integration",
             {"expectedCalls": ["provider-A:m", "provider-B:m"], "activeModelKey": "provider-B:m",
              "onlyBActive": True, "activeCount": 1},
             keys=["provider-A:m", "provider-B:m"], vectors=[[1, 0], [0, 1]], text="currentword",
             events=[dict(op="publish", text="currentword"), dict(op="selectModel", key="provider-A:m"),
                     dict(op="drain", vector=[1, 0]), dict(op="selectModel", key="provider-B:m"),
                     dict(op="drain", vector=[0, 1])]),
        case("reingest-during-embedding", "integration",
             {"staleWrites": 0, "activeId": 1, "pendingRevisionId": 102, "publishedRevisionId": 102,
              "returnedSource": {"currentRevision": 102, "publishedRevisionId": 102}}, generation_seed(),
             capturedRevisionId=101, replacementText="new", vector=[1, 0],
             events=[dict(op="beginEmbedBatch", generationId=2, revisionId=101, chunkIds=[1001]),
                     dict(op="publish", sourceId=1, text="new", token="new", at=1),
                     dict(op="resumeEmbedBatch", generationId=2, revisionId=101, vectors=[[1, 0]]),
                     dict(op="reconcile", generationId=2)]),
        case("reindex-keeps-active", "integration",
             {"afterRequest": {"activeId": 1, "buildingId": 2, "buildingVectorCount": 0, "workVectorCount": 0},
              "afterFill": {"activeId": 2, "previousState": "retired", "newState": "active"}}, generation_seed(False),
             modelKey="m", vector=[1, 0], events=[dict(op="deleteAllEmbeddings", modelKey="m"),
                 dict(op="inspectWork", modelKey="m"), dict(op="drain", modelKey="m", vector=[1, 0])]),
        case("citation-after-gc", "integration", {"text": "saved evidence", "sourceExists": False},
             revisionId=101, sourceId=1, chunkId=1001, citationVersion=2,
             citation={"marker": 1, "sourceId": 1, "chunkId": 1001, "revisionId": 101,
                       "snippet": "saved evidence", "text": "saved evidence",
                       "spans": [{"start": 0, "end": 14}], "chunkIds": [1001]},
             events=[dict(op="persistCitation"), dict(op="deleteSource", sourceId=1),
                     dict(op="garbageCollect", notebookId=1), dict(op="reopen"), dict(op="readCitation")]),
        case("restart", "integration",
             {"before": {"currentRevision": 101, "publishedRevisionId": 101, "activeId": 1},
              "after": {"currentRevision": 101, "publishedRevisionId": 101, "activeId": 1}}, generation_seed(False),
             events=[dict(op="capturePointers"), dict(op="close"), dict(op="reopen"), dict(op="capturePointers")]),
    ]
    # These are hand-authored expected spans, independently checked below.
    scalar_inputs = [
        ("scalar-empty", "", 8, 2, [], []),
        ("scalar-whitespace", "  \t\n", 8, 2, [], []),
        ("scalar-combining", "A😀éZ", 8, 2, [], [("A😀éZ", 0, 5, None, 2)]),
        ("scalar-supplementary", "😀𐐀Z", 8, 2, [], [("😀𐐀Z", 0, 3, None, 1)]),
        ("scalar-repeated", "abababab", 4, 2, [], [("abab", 0, 4, None, 1), ("abab", 2, 6, None, 1), ("abab", 4, 8, None, 1)]),
        ("scalar-overlap", "aa bb cc", 5, 2, [], [("aa", 0, 2, None, 1), ("a bb", 1, 5, None, 1), ("b cc", 4, 8, None, 1)]),
        ("scalar-long-word", "abcdefgh", 4, 1, [], [("abcd", 0, 4, None, 1), ("defg", 3, 7, None, 1), ("gh", 6, 8, None, 1)]),
        ("scalar-pdf-crossing", "Část 😀\n\ndruhá", 20, 2, [[0, 1], [8, 2]], [("Část 😀\n\ndruhá", 0, 13, 1, 4)]),
    ]
    for name, text, window, overlap, page_starts, chunks in scalar_inputs:
        expected = [dict(zip(("text", "start", "end", "pageHint", "tokenCount"), chunk)) for chunk in chunks]
        assert scalar_window_oracle(text, window, overlap, page_starts) == expected, name
        cases.append(case(name, "scalar", {"chunks": expected}, text=text,
                          window=window, overlap=overlap, pageStarts=page_starts))
    for item in cases:
        if item["name"] not in ("scalar-text", "pdf-pages"):
            continue
        canonical = item["text"] if item["name"] == "scalar-text" else "\n\n".join(item["pages"])
        expected = item["expected"]
        assert canonical == expected["canonicalText"]
        assert len(canonical) == expected["scalarCount"]
        starts = expected.get("pageStarts", [])
        assert scalar_window_oracle(canonical, item["window"], item["overlap"], starts) == expected["chunks"]
        if item["name"] == "pdf-pages":
            assert len(item["pages"][0]) + 2 == starts[1][0]
    # The same extraction race/renewal events drive bridge and lower-level tests.
    revision_cases = {c["name"]: c for c in jobs_revision_contract()["cases"]}
    for name in ("superseded-extraction", "renew-running-extraction"):
        item = copy.deepcopy(revision_cases[name])
        item["operation"] = "integration"
        item["expected"]["returnedSource"] = {"currentRevision": 102, "publishedRevisionId": 102}
        cases.append(item)
    return envelope("storage-integration", cases, scalarOffsets="unicode-scalars",
                    tokenCountRule="max(1,ceil((end-start)/4))")
# END GENERATION AND INTEGRATION FIXTURES


# BEGIN HANDOFF FIXTURES
def handoff_contract():
    """Independent job/source trace oracle, including exhaustion and stale owners."""
    setup = [
        f"INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(1,'one','{STAMP}','{STAMP}'),(2,'two','{STAMP}','{STAMP}')",
        f"INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(1,1,'text','source','ready','{STAMP}')",
        "INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at) "
        f"VALUES(11,1,1,'old','old',1,2,'{STAMP}')",
        "UPDATE sources SET current_revision=11,published_revision_id=11 WHERE id=1",
        "INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at) "
        "VALUES(1,1,'/docs','{\"volumeId\":\"vol\",\"components\":[\"docs\"],\"rootFileId\":\"root-1\"}',"
        f"'docs','[]','[]','{{}}','{STAMP}')",
        "INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,dims,normalization,query_format_version,doc_format_version,chunker_version,state,created_at) "
        f"VALUES(1,1,'local','endpoint','model',2,'l2','1','1','2','building','{STAMP}')",
    ]
    extraction = dict(kind="extract", target="source:1", targetRevision=11, optionsJSON="{}")
    claim = dict(op="claim", at=0, token="owner")
    failure = dict(op="fail", at=10, token="owner", error="extract failed")
    supersede = dict(op="supersedeSource", at=20, sourceId=1,
                     contentHash="new", canonicalText="new", error="newer failure")
    initial_options, upgraded_options = '{"verifyAll":false}', '{"verifyAll":true}'
    selection = dict(providerId="local", endpointRevision="endpoint", model="model", modelDigest=None,
                     dims=None, normalization="l2", queryFormatVersion="1", docFormatVersion="1", chunkerVersion="2")
    bootstrap_options = json.dumps(dict(selection=selection, copyExisting=True), separators=(",", ":"))
    traces = [
        ("failure-due-retry-claim", dict(enqueueAt=0, draft=extraction, events=[
            claim, failure, dict(op="requeue", at=69), dict(op="requeue", at=70),
            dict(op="claim", at=70, token="retry-owner")])),
        ("stale-claim-preserves-newer-error", dict(enqueueAt=0, draft=extraction, events=[
            supersede, dict(op="claim", at=70, token="stale")])),
        ("stale-due-retry-preserves-newer-error", dict(enqueueAt=0, draft=extraction, events=[
            claim, failure, supersede, dict(op="requeue", at=70)])),
        ("options-upgrade-freezes-at-first-claim", dict(enqueueAt=0,
            draft=dict(kind="scan", target="folder:1", targetRevision=None, optionsJSON=initial_options), events=[
                dict(op="updateOptions", at=0, optionsJSON=upgraded_options), claim,
                dict(op="updateOptions", at=1, optionsJSON=initial_options),
                dict(op="fail", at=10, token="owner", error="scan failed"),
                dict(op="requeue", at=69), dict(op="requeue", at=70),
                dict(op="updateOptions", at=70, optionsJSON=initial_options),
                dict(op="claim", at=70, token="retry-owner")])),
        ("notebook-bootstrap-retarget-complete", dict(enqueueAt=0,
            draft=dict(kind="embed", target="notebook:1", targetRevision=None, optionsJSON=bootstrap_options), events=[
                claim, dict(op="retarget", at=1, token="stale", generationId=1),
                dict(op="retarget", at=2, token="owner", generationId=1),
                dict(op="complete", at=3, token="owner")])),
        ("notebook-orphan-claim-cancels", dict(enqueueAt=0,
            draft=dict(kind="embed", target="notebook:2", targetRevision=None, optionsJSON="{}"), events=[
                dict(op="deleteNotebook", at=0, notebookId=2), dict(op="claim", at=1, token="orphan")])),
    ]

    def trace(name, inputs, initial=False):
        draft = inputs["draft"]
        job = dict(id=1, **draft, state="queued", attempts=0, nextRetryAt=inputs["enqueueAt"],
                   leaseUntil=None, leaseToken=None, error=None)
        source = dict(id=1, status="pending" if initial else "ready", error=None,
                      currentRevision=None if initial else 11, publishedRevisionId=None if initial else 11)
        notebook_deleted = False
        newer_job_started = False
        snapshots = []
        for event in inputs["events"]:
            op, now = event["op"], event["at"]
            accepted, requeued, recovered = False, None, None
            live = (job["state"] == "running" and job["leaseUntil"] > now
                    and job["leaseToken"] == event.get("token"))
            current = source["currentRevision"] == draft["targetRevision"]
            if op == "claim":
                if job["state"] == "queued" and job["attempts"] < 5 and job["nextRetryAt"] <= now:
                    if notebook_deleted or (draft["kind"] == "extract" and (not current or newer_job_started)):
                        job.update(state="cancelled", nextRetryAt=None)
                    else:
                        accepted = True
                        job.update(state="running", attempts=job["attempts"] + 1,
                                   nextRetryAt=None, leaseUntil=now + 300,
                                   leaseToken=event["token"], error=None)
                        if draft["kind"] == "extract":
                            source.update(status="chunking", error=None)
            elif op in ("fail", "recover"):
                accepted = live if op == "fail" else (
                    job["state"] == "running" and job["leaseUntil"] <= now)
                if op == "recover":
                    recovered = int(accepted)
                if accepted:
                    exhausted = job["attempts"] == 5
                    error = event["error"] if op == "fail" else "leaseExpired"
                    job.update(state="failed" if op == "fail" or exhausted else "queued",
                               nextRetryAt=None if exhausted else now + 30 * 2 ** job["attempts"],
                               leaseUntil=None, leaseToken=None, error=error)
                    if draft["kind"] == "extract" and current and not newer_job_started:
                        if op == "recover" and not exhausted:
                            source.update(status="pending", error=None)
                        else:
                            source.update(status="error", error=error)
            elif op in ("requeue", "retry"):
                requeued = 0 if op == "requeue" else None
                if job["state"] == "failed" and job["attempts"] < 5 and job["nextRetryAt"] <= now:
                    if draft["kind"] == "extract" and (not current or newer_job_started):
                        job.update(state="cancelled", nextRetryAt=None)
                    else:
                        accepted = True
                        if op == "requeue":
                            requeued = 1
                        job["state"] = "queued"
                        if draft["kind"] == "extract":
                            source.update(status="pending", error=None)
            elif op == "updateOptions":
                accepted = job["state"] == "queued" and job["attempts"] == 0
                if accepted:
                    job["optionsJSON"] = event["optionsJSON"]
            elif op in ("retarget", "complete"):
                accepted = live
                if accepted:
                    if "generationId" in event:
                        job["target"] = f"generation:{event['generationId']}"
                    if op == "complete":
                        job.update(state="done", nextRetryAt=None, leaseUntil=None, leaseToken=None)
            elif op == "setSourceError":
                accepted = True
                source.update(status="error", error=event["error"])
            elif op == "supersedeSource":
                accepted = True
                source.update(currentRevision=12, status="error", error=event["error"])
            elif op == "supersedeJob":
                accepted, newer_job_started = True, True
                source.update(status="error" if event.get("error") else "chunking", error=event.get("error"))
            elif op == "deleteNotebook":
                accepted, notebook_deleted = True, True
            else:
                raise AssertionError(f"Unknown handoff event: {op}")
            snapshots.append(dict(accepted=accepted, requeuedCount=requeued, recoveredCount=recovered,
                                  job=copy.deepcopy(job), source=copy.deepcopy(source)))
        result = dict(name=name, operation="trace", input=inputs, expected=dict(snapshots=snapshots))
        if initial:
            result["setupSql"] = ["UPDATE sources SET current_revision=NULL,published_revision_id=NULL,status='pending' WHERE id=1"]
        return result

    cases = [trace(name, inputs) for name, inputs in traces]
    # Windows' refresh/options/bootstrap scenarios are already above. Null-revision
    # initial ingestion also needs retry and both stale-claim/stale-retry traces.
    for name, (_, inputs) in zip(("initial-retry", "stale-initial-claim", "stale-initial-due-retry"), traces[:3]):
        inputs = copy.deepcopy(inputs)
        inputs["draft"]["targetRevision"] = None
        cases.append(trace(name, inputs, initial=True))
    # A superseded queued/failed job must never take source ownership back: its
    # later failures are fenced too, so reclaiming would otherwise strand chunking.
    for initial in (True, False):
        for retry in (False, True):
            inputs = copy.deepcopy(traces[2 if retry else 1][1])
            inputs["draft"]["targetRevision"] = None if initial else 11
            inputs["events"][-2] = dict(op="supersedeJob", at=20, token="successor", error="newer failure")
            cases.append(trace(f"newer-job-cancels-{'initial' if initial else 'refresh'}-{'retry' if retry else 'claim'}",
                               inputs, initial))
    bootstrap = copy.deepcopy(traces[4][1])
    bootstrap["events"] = [dict(op="claim", at=0, token="owner"),
                           dict(op="complete", at=1, token="owner", generationId=1)]
    cases.append(trace("notebook-bootstrap-atomic-complete", bootstrap))

    # A retryable expiry is refreshPending, including when a prior source error
    # survived the worker. Only the matching revision/job owner may clear it.
    for initial in (True, False):
        for successor in ("current", "newer-revision", "newer-failed-job", "newer-running-job"):
            events = [claim, dict(op="recover", at=299)]
            if successor == "current":
                events.append(dict(op="setSourceError", at=299, sourceId=1, error="prior failure"))
            elif successor == "newer-revision":
                events.append(dict(supersede, at=299))
            else:
                events.append(dict(op="supersedeJob", at=299, token="successor",
                                   error="newer failure" if successor == "newer-failed-job" else None))
            events.extend([dict(op="recover", at=300), dict(op="recover", at=300),
                           dict(op="fail", at=300, token="owner", error="expired worker failure"),
                           dict(op="claim", at=359, token="early"),
                           dict(op="claim", at=360, token="retry-owner"),
                           dict(op="fail", at=361, token="owner", error="stale worker failure")])
            inputs = dict(enqueueAt=0,
                          draft=dict(extraction, targetRevision=None if initial else 11), events=events)
            cases.append(trace(f"nonterminal-expiry-{'initial' if initial else 'refresh'}-{successor}", inputs, initial))

    for mode in ("failure", "expiry"):
        for initial in (True, False):
            for successor in ("current", "newer-revision", "newer-failed-job", "newer-running-job"):
                events, now = [], 0
                for attempt in range(1, 6):
                    token = f"attempt-{attempt}"
                    events.append(dict(op="claim", at=now, token=token))
                    if attempt < 5:
                        events.append(dict(op="fail", at=now + 1, token=token, error=f"failure-{attempt}"))
                        now += 1 + 30 * 2 ** attempt
                        events.append(dict(op="requeue", at=now))
                if successor == "newer-revision":
                    events.append(dict(op="supersedeSource", at=now + 1, sourceId=1,
                                       contentHash="new", canonicalText="new", error="newer failure"))
                elif successor.startswith("newer-"):
                    events.append(dict(op="supersedeJob", at=now + 1, token="successor",
                                       error="newer failure" if successor == "newer-failed-job" else None))
                terminal_at = now + (300 if mode == "expiry" else 2)
                events.append(dict(op="recover", at=terminal_at) if mode == "expiry" else
                              dict(op="fail", at=terminal_at, token=token, error="terminal extraction failure"))
                events.extend([dict(op="retry", at=terminal_at),
                               dict(op="claim", at=terminal_at, token="exhausted")])
                inputs = dict(enqueueAt=0,
                              draft=dict(kind="extract", target="source:1", targetRevision=None if initial else 11,
                                         optionsJSON="{}"), events=events)
                cases.append(trace(f"terminal-{mode}-{'initial' if initial else 'refresh'}-{successor}", inputs, initial))
    return envelope("storage-job-handoff", cases,
                    description="Shared WP3 handoff traces, including initial ingestion and terminal extraction fencing.",
                    setupSql=setup)
# END HANDOFF FIXTURES


# BEGIN CLI
def make_contracts() -> dict[str, dict]:
    return {
        "storage-v19.json": migration_contract(),
        "storage-catalog-v1.json": catalog_contract(),
        "storage-jobs-revisions-v1.json": jobs_revision_contract(),
        "storage-generations-v1.json": generation_contract(),
        "storage-integration-v1.json": integration_contract(),
        "storage-job-handoff-v1.json": handoff_contract(),
        "storage-v20.json": v20_contract(),
    }


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def write_fixtures(directory):
    (directory / "contracts").mkdir(parents=True, exist_ok=True)
    build_v18(directory / "storage/v18.sqlite")
    for name, contract in make_contracts().items():
        (directory / "contracts" / name).write_bytes(json_bytes(contract))


def check_fixtures(directory):
    with tempfile.TemporaryDirectory() as temporary:
        generated = pathlib.Path(temporary)
        write_fixtures(generated)
        differences = []
        for path in sorted((generated / "contracts").glob("*.json")):
            committed = directory / "contracts" / path.name
            if not committed.exists() or path.read_bytes() != committed.read_bytes():
                differences.append("contracts/" + path.name)
        committed = directory / "storage/v18.sqlite"
        if not committed.exists() or logical_dump(generated / "storage/v18.sqlite") != logical_dump(committed):
            differences.append("storage/v18.sqlite (logical state)")
        return differences


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare without changing committed fixtures")
    args = parser.parse_args()
    print("SQLite runtime:", sqlite3.sqlite_version)
    directory = ROOT / "Tests/fixtures"
    if args.check:
        differences = check_fixtures(directory)
        if differences:
            raise SystemExit("Storage fixture drift: " + ", ".join(differences))
        print("Storage JSON bytes and SQLite logical state match.")
    else:
        write_fixtures(directory)
        print("Generated v18.sqlite and seven storage contracts.")


if __name__ == "__main__":
    main()
# END CLI
