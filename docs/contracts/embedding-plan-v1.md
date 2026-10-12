# Embedding build plan — normative contract v1

*Status: 0.15.x (2026-10-11). Fixture: `Tests/fixtures/contracts/embedding-plan-v1.json`. Executable reference: `tools/contracts/gen_embedding_plan_fixtures.py` (`--check` must pass). Schema: migration `v20_embedding_dedup`, fixture `Tests/fixtures/contracts/storage-v20.json` (`tools/contracts/gen_storage_fixtures.py`). Swift (`FolderIndexCoordinator`, `NotebookStore.captureEmbeddingRound`, `EmbeddingPlan`) and C# (`FolderIndexCoordinator`, `NotebookStore.CaptureEmbeddingRound`, `EmbeddingPlan`) seed every `build` case into a fresh store, run the real coordinator with a recording fake provider and must reproduce the provider requests, the copy count and the progress exactly. Extends `folder-rag-v1.md` (frozen) and `indexing-status-v1.md` without changing their other rules.*

## 1. Why

A large notebook dominated by spreadsheets (many of them identical template copies) can need many hours of background embedding at a provider rate of a few dozen chunks per second. Spreadsheet rows add little to semantic search and full-text search already covers them; identical chunk texts produce identical vectors. Three rules shorten the build without changing what retrieval can find.

## 2. Constants

| Name | Value |
|---|---|
| `spreadsheetTypes` | `xlsx` (the stored source type; `.xlsx` and `.xlsm` both detect as `xlsx`) |
| `spreadsheetChunkCap` | `64` |
| `roundScanFactor` | `16` (a round examines at most `16 × batchSize` candidates) |
| `textHash` | lowercase hex SHA-256 of the chunk text's exact UTF-8 bytes (no Unicode normalization, no trimming) |

## 3. Embeddable chunks

A chunk is **embeddable** when its source is not a spreadsheet, or its `ord < spreadsheetChunkCap` (chunks are numbered `0…n−1` in revision order, so this is "the first 64 chunks"). SQL form, index-friendly on `idx_chunks_revision_ord`:

    c.ord < CASE WHEN s.type='xlsx' THEN 64 ELSE 9223372036854775807 END

Every completeness rule of a building generation counts embeddable chunks only:

- a manifest row becomes `done` (and a generation can activate) when every **embeddable** chunk of the published manifest revision has a vector of the generation's width (`markComplete`, `revisionComplete`);
- `indexing-status-v1` `embedChunksTotal` / `embedChunksDone` count embeddable chunks of the non-excluded manifest revisions (so the strip reaches `d = t` and the build finishes);
- `GenerationProgress.done/total` (manifest rows) are unchanged.

Non-embeddable spreadsheet chunks never get a vector, stay in `chunks_fts`, and are found by the lexical arm of retrieval. Vector retrieval already reads only stored vectors of `done` manifest revisions, so a missing vector for a capped chunk is never an error or "missing index"; `needsEmbedding` stays false once the source is `done`.

## 4. Priority order

`priorityClass` = 1 for spreadsheet sources, 0 otherwise. Pending candidates — embeddable chunks of `pending` manifest rows whose source is present, eligible and published at the manifest revision, without a vector in the generation — are processed in the order `(priorityClass, manifest source_id, ord)`. The dimension bootstrap (unknown dims) takes its first round from the same order over published sources.

**Keyset pagination.** The coordinator keeps a cursor `(priorityClass, sourceId, ord)` of the last consumed candidate and each round resumes strictly after it (per class: `m.source_id >= ? AND (m.source_id > ? OR c.ord > ?)` on the manifest primary key), so a round never re-reads finished sources. The cursor resets to the start when settling the generation changed the manifest or pruned vectors, and once more before concluding that nothing is pending (wrap-around), so work behind the cursor (a re-published source) is never lost. Within a static corpus the cursor changes nothing observable.

## 5. Rounds and dedup

A round walks candidates in order inside one fenced write transaction (after settling the generation) and classifies each:

1. its exact text already has a vector in this generation (lookup `generation_text_hashes` by `(generation_id, text_hash)`, then verify `source_chunks.text` equality and that the vector exists) → the vector bytes are **copied** now, no provider input;
2. its text equals an input already collected in this round → it **joins** that input (gets the same vector when the request is committed);
3. fewer than `batchSize` inputs collected → it becomes a new input;
4. otherwise the round stops before it (it stays pending).

A round also stops after examining `roundScanFactor × batchSize` candidates. If the round collected inputs, they are sent as one provider request; the commit stores each input's vector and copies it byte-for-byte to the joined chunks in the same fenced transaction (stale members are dropped as before). A round with copies but no inputs makes no provider call. The bootstrap round has no generation yet, so only rule 2–4 apply.

Why the raw chunk text is the key: the document-format prefix and every other input transformation a session applies are a pure function of the generation identity (doc format, profile) and the chunk text, so within one generation equal chunk text ⇔ equal provider input ⇔ equal vector. Dedup never crosses generations.

`generation_text_hashes` (migration `v20_embedding_dedup`) records `(generation_id, chunk_id, text_hash, copied)` for every vector a build stores (`copied = 0` for provider vectors, `1` for dedup copies). An incremental build that copies unchanged vectors from the identical active generation carries their rows with `copied = 0`. Rows cascade with their generation and chunk.

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

## 6. Progress

`GenerationProgress.copied` (Swift and C#) = rows of the latest building/failed generation with `copied = 1` whose vector still exists. Copies are vectors, so they count toward `embedChunksDone`; `done` still reaches `total`. The fixture's `copied` counts both immediate copies and joined duplicates.

## 7. Fixture

`classify` (`sourceType → {priorityClass, embedCap}`), `textHash` (`text → {hash}`) and `build` cases. A `build` case seeds one notebook with the listed sources (explicit ids, given type, one published revision whose chunks are the listed texts with `ord` = index), builds a generation with batch size `batchSize` from an empty state, and expects: `calls` (the input texts of each provider request, in order), `providerInputs`, `copied`, `chunkProgress` (indexing-status done/total after the build), `sourceProgress` (manifest done/total), `unembedded` (`[sourceId, ord]` without a vector). Every chunk with a vector holds exactly the vector its text was embedded to (byte-equal across copies). Running the same case through the dimension bootstrap yields the same requests.
