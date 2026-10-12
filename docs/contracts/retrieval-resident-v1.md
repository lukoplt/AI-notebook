# Resident generation matrices — normative contract v1

*Status: 2026-10-11. Extends `folder-rag-v1.md` (frozen) and amends `retrieval-partial-index-v1.md` §3 (last paragraph: partial pins no longer stream). No schema change, no fixture change: `retrieval-cache-v1.json` still governs the epoch-keyed `VectorMatrixCache.acquire` API, which production retrieval no longer uses. Swift `VectorMatrixCache.residentTopK` / `ResidentVectorMatrix`, C# `VectorMatrixCache.ResidentTopK` / `ResidentVectorMatrix`; tests `ResidentVectorMatrixTests` (both platforms).*

## 1. Why

The epoch-keyed matrix was useless on a large folder: the epoch changes after any write (scan status, job polling, chat messages, embedding batches), so nearly every turn refilled the whole matrix, and a building generation (first index) never had a key at all and streamed every vector page from SQLite on every turn. A 250k × 768 fp32 matrix also exceeded the 512 MiB budget, so large folders always streamed.

## 2. Identity and validity

One resident matrix per `(databaseId, databaseInstance, notebookId, generationId, dims)`. `databaseInstance` is renewed whenever a store opens the database (Swift: per `RetrievalInvalidation.install`; C#: per `NotebookStore`), so a reopened or restored file never inherits rows. Rows are loaded per pinned `(sourceId, revisionId)` pair, by identity only: `chunk_embeddings` of the generation whose chunk has that source and revision. Revision and generation ids are `AUTOINCREMENT` and chunk rows of a revision are immutable, so a loaded pair stays valid for every later pin that names it. A query scores a row iff its revision equals the query pin's vector revision of its source **and** the source is in the query's permission mask. Superseded rows are garbage: never scored, compacted away when garbage exceeds `max(4096, rows / 2)`.

A query first loads the pins' missing pairs (one load per key at a time; concurrent queries wait), then scores. ≤ 64 missing pairs are read through the revision index, more by one ordered pass over `idx_chunk_embeddings_generation`. A load counts its rows first and reserves their bytes; a page that would exceed the count aborts the load (the query streams, nothing partial is kept).

## 3. Scoring

A stored row is decoded (little-endian fp32), L2-normalized with an fp64 sum of squares and an fp32 result (zero rows stay zero; any non-finite value invalidates the row), rounded to IEEE binary16 (round-to-nearest-even) and widened back to fp32. The score is the fp32 dot product with the normalized query (`vDSP_dotpr` / `TensorPrimitives.Dot`). The streamed fallback applies the identical rounding, so resident and streamed scans return identical candidates. Heap order is unchanged: score descending, then chunk id ascending.

## 4. Budget

Charge per row: `2 × dims + 32` bytes (binary16 row + chunk/source/revision ids and ordinal). The process-wide cache budget is `clamp(physicalMemory / 16, globalBudgetBytes, 1 GiB)` — 512 MiB on 8 GB, 1 GiB on ≥ 16 GB (a 500k × 768 generation needs ~784 MB). Injected caches keep their explicit budget. Reservations evict the least-recently-used unleased epoch matrices and idle resident generations, never the one being extended. A matrix that cannot fit is dropped and the query streams. macOS drops every idle resident matrix on a memory-pressure warning.

## 5. Building generations

A partial pin (`retrieval-partial-index-v1`) uses the same resident matrix: each query loads only the sources the build completed since the previous query, so semantic retrieval during a build no longer re-reads the generation per turn. Pin selection, statuses and all other partial-index rules are unchanged.
