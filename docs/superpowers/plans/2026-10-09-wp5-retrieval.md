# WP5 — Retrieval Implementation Plan

**Goal:** Return a scoped, revision-pinned hybrid candidate pool on macOS and Windows, retain working chat and eval callers, hydrate complete evidence, bound vector memory, and expose reproducible performance measurements for WP7.

**Architecture:** One SQL scope snapshot and WP3 query pin precede embedding. Published revisions feed lexical retrieval; the pinned generation's done manifest feeds vectors. A process-wide leased LRU serves normalized matrices; oversized or temporarily uncacheable matrices stream in bounded pages. Both branches select their own fetchK, then integer RRF produces the complete union. Evidence hydration keeps the query lease until the consumer has copied evidence. WP3 remains the sole owner of revision retention and GC policy.

**Tech Stack:** Swift 6, GRDB system SQLite, Accelerate/vDSP, XCTest; .NET 10, Microsoft.Data.Sqlite, SQLitePCLRaw e_sqlite3, System.Numerics.Tensors 9.0.0, xUnit; Python 3 for shared deterministic fixtures. No new service and no new database migration.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md` §6 and §9. **Master:** `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md`. **Contracts:** `docs/contracts/folder-rag-v1.md` §1, §3–4, §7, §9 and Perf protocol; `docs/contracts/lang-detector-v1.md` §2. **Prerequisites:** `2026-10-09-wp1-eval-assets.md`, `2026-10-09-wp2-providers.md`, `2026-10-09-wp3-storage-v19.md`, and UnicodeTables Tasks 2/3 of `2026-10-09-wp4-language-detector.md`, all under `docs/superpowers/plans/`. **Format exemplar:** `docs/superpowers/plans/2026-10-09-wp0-contracts.md`. This plan invokes no installed skill.

## Global Constraints

- This is an implementation plan, not an implementation. Planning baseline measured 2026-10-09: Swift **381 passed, 0 failed**; Windows Core **459 passed, 0 failed, 0 skipped**. Later implementation branches record their own before/after totals; concurrent prerequisites will increase these counts.
- Each task runs in its own worktree from merged prerequisites. Touch only its listed files. “Parallel with” means files are disjoint, subject to both tasks' dependencies. No implementation worker edits this plan. No VERSION, migration, localization, context pack, or detector model changes.
- TDD: add the supplied test first, run the filtered command and retain the red result, implement, run filtered green, then run **both** complete suites before every commit. On Windows-only steps, collect the matching-tree Swift run from the macOS worker before committing; an unavailable runner is a pending check, never a passing result. Additional regression cases listed in a task are mandatory. Never replace real SQLite assertions with a tokenizer mock or relax an expected ranking.
- All Core behavior uses shared JSON fixtures through existing `SharedFixtures` loaders. Fixture integers describe scores, ranks, offsets, vectors and memory sizes; actual SIMD floating results use a tolerance only in numerical tests. No live provider, hardware timing assertion, or network download in unit tests.
- Binding WP0 decision 7 overrides the original spec's current-revision/active-only wording. `revisionId` means `source_revisions.id`, not its per-source ordinal. Published lexical evidence works without an active generation. Language never filters a source. Scope selection is a union; empty selection performs **zero SQL and zero embedding calls**.
- Every Windows connection operation, including reader iteration, transactions and fixture seeding, holds `lock (_gate)` or `lock (store.Gate)`. Never await with that lock or a transaction held. Swift's long scans run on GRDB's background executor, not MainActor. Keep a maximum page of 1024 rows and at most 8 MiB vector payload per page, lowering row count when dimensions require it.
- Scope is captured at query start; sources added to a folder later join the next query. Availability/eligibility or membership revocation is checked again before exposing results and hydration. Publication during a query does not replace pinned revisions. Invalidation changes future cache admission, not the identity of a running query's retained evidence.
- WP3 `QueryPin`/registry/GC are reused, including cross-store database identity and registry-before-SQLite lock ordering. No second registry and no persisted query pins. Success transfers lease ownership; failure/cancellation closes it. A consumer must close/dispose a pool after copying evidence; prepared requests retain the lease until their evidence is copied or abandoned.
- Preserve WP1 `RetrievalCandidates` and existing four-field `RetrievalHit`. Only the legacy adapter converts integer score to Float; that value is never used for ranking. Keep WP1 `includeVectors:false` entirely offline. Legacy search's omitted/empty sourceIds continues to mean all; typed `RetrievalScope.selection([],[])` and WP1 candidates' explicit empty collection mean empty.
- Networking remains under `Providers/`. WP2 chat-only endpoint rejection, one-time embedding selection conversion and embedding-capable picker remain intact. No Ollama substitution on query failure. Embedding sessions capture provider configuration once, with privacy permission checked by the existing router.
- WP5 does not implement diversity, budgeting, citation numbering, Overview selection or model selection. It supplies candidate revisions, evidence, neighbours and metadata to WP8; WP7 owns benchmark results and model-specific format choices.
- New tasks below require WP1 Tasks 4/5, WP2 Core/router integration and WP3 Tasks 10/11 to be merged before editing their files. Windows App bridge work also waits for WP2 Task 11 and WP3 Task 12. If WP4 Task 2/3 is absent, the respective FTS task **waits**, never substitutes host Unicode APIs.
- Each commit's last line is `Co-Authored-By: Codex <noreply@openai.com>`. Stage exact files. Leave the worktree clean.

## File Structure

Paths are relative to the repository root. A path marked new has no current line number. Anchors refer to the planning checkout; predecessor plans are cited for files not yet implemented.

| Task | Files owned | Responsibility / existing anchor |
|---|---|---|
| 1 [Shared] | New `tools/contracts/gen_retrieval_fixtures.py`, `tools/contracts/test_retrieval_fixtures.py`; new `Tests/fixtures/contracts/retrieval-{scope,rank,cache,evidence,session,perf}-v1.json` | Deterministic shared oracles; fixture envelope rules `Tests/fixtures/README.md:1`; do not edit WP0 generator here. |
| 2 [Swift] | New `Sources/AINotebookCore/FTSQueryBuilder.swift`, `Tests/AINotebookCoreTests/FTSQueryBuilderTests.swift` | Pinned Unicode tokenizer; replaces the behavior currently at `Retriever.swift:179` only when Task 12 integrates it. |
| 3 [Windows] | New `windows/src/AINotebook.Core/Rag/FtsQueryBuilder.cs`, `windows/tests/AINotebook.Core.Tests/Rag/FtsQueryBuilderTests.cs` | Same tokenizer; current quote-whole-query code `Rag/Retriever.cs:170`. |
| 4 [Swift] | New `Sources/AINotebookCore/ScopeResolver.swift`, `RetrievalStorageTypes.swift`, `NotebookStore+Retrieval.swift`, `RetrievalInvalidation.swift`; new `Tests/AINotebookCoreTests/RetrievalScopeSQLTests.swift`, `RetrievalFixtureStore.swift`; modify `Sources/AINotebookCore/NotebookStore.swift`, WP3 `NotebookStore+Generations.swift` | Atomic scoped pin, background pages, store epoch. Existing DB ownership `NotebookStore.swift:12–14,26–54,115`; WP3 pin seam plan:1153–1205. |
| 5 [Windows] | New `windows/src/AINotebook.Core/Rag/ScopeResolver.cs`, `Storage/RetrievalStorageTypes.cs`, `Storage/NotebookStore.Retrieval.cs`, `Storage/RetrievalInvalidation.cs`; new `windows/tests/AINotebook.Core.Tests/Rag/RetrievalScopeSQLTests.cs`, `Helpers/RetrievalFixtureStore.cs`; modify `Storage/NotebookStore.cs`, WP3 `Storage/NotebookStore.Generations.cs` | Same SQL/leases/pages. Existing gate/connection at `NotebookStore.cs:34,42,50–74,138`. |
| 6 [Swift] | New `Sources/AINotebookCore/RetrievalRanking.swift`; new `Tests/AINotebookCoreTests/RetrievalRankingTests.swift` | Heap, integer RRF, vDSP scans. Existing allocation/sort `Retriever.swift:51–66`; vDSP example `Cosine.swift:11`. |
| 7 [Windows] | New `windows/src/AINotebook.Core/Rag/RetrievalRanking.cs`; new `windows/tests/AINotebook.Core.Tests/Rag/RetrievalRankingTests.cs`; modify `windows/src/AINotebook.Core/AINotebook.Core.csproj`, and `packages.lock.json` in Core, Core.Tests, App, App.Tests project directories | SIMD heap/cache. Current full sort `Rag/Retriever.cs:44–52`; package pins `AINotebook.Core.csproj:18–28`; existing Tensors 9.0.0 in App lock:205 and App.Tests lock:253. |
| 6a [Swift] | New `Sources/AINotebookCore/VectorMatrixCache.swift`, `Tests/AINotebookCoreTests/VectorMatrixCacheTests.swift` | Budget, leases, single-flight loading, invalidation. |
| 7a [Windows] | New `windows/src/AINotebook.Core/Rag/VectorMatrixCache.cs`, `windows/tests/AINotebook.Core.Tests/Rag/VectorMatrixCacheTests.cs` | Matching cache state machine. |
| 8 [Swift] | New `Sources/AINotebookCore/EvidenceHydrator.swift`, `Tests/AINotebookCoreTests/EvidenceHydratorTests.swift` | Full scalar evidence, independent display snippet, published neighbours, GC integration. Current snippet-only read `Retriever.swift:158–174`. |
| 9 [Windows] | New `windows/src/AINotebook.Core/Rag/EvidenceHydrator.cs`, `windows/tests/AINotebook.Core.Tests/Rag/EvidenceHydratorTests.cs` | Matching evidence path; current UTF-16 truncation `Rag/Retriever.cs:168`. |
| 10 [Swift] | New `Sources/AINotebookCore/Providers/ProviderEmbeddingSession.swift`, `Tests/AINotebookCoreTests/ProviderEmbeddingSessionTests.swift`; modify `Sources/AINotebookCore/Providers/ProviderRouter.swift` | Capture embedding adapter/model/config, reuse WP2 routing/privacy machinery. |
| 11 [Windows] | New `windows/src/AINotebook.Core/Providers/ProviderEmbeddingSession.cs`, `windows/tests/AINotebook.Core.Tests/Providers/ProviderEmbeddingSessionTests.cs`; modify WP2 `windows/src/AINotebook.Core/Providers/ProviderRouter.cs` | Same immutable embedding session; WP2 Tasks 5/11 handoff. |
| 12 [Swift] | Modify `Sources/AINotebookCore/Retriever.swift`; new `Sources/AINotebookCore/PinnedRetrievalCandidates.swift`, `Tests/AINotebookCoreTests/PinnedRetrieverTests.swift` | One query orchestration + compatibility adapters; preserve WP1 methods added at `Retriever.swift:114`, SQL tie at :141. |
| 13 [Windows] | Modify `windows/src/AINotebook.Core/Rag/Retriever.cs`; new `windows/src/AINotebook.Core/Rag/PinnedRetrievalCandidates.cs`, `windows/tests/AINotebook.Core.Tests/Rag/PinnedRetrieverTests.cs` | One generation snapshot, adapters; current reread bug :41/:44; WP1 edits :90/:119. |
| 14 [Win-UI] | Modify `windows/src/AINotebook.App/Services/ProviderRouter.cs`; new `windows/tests/AINotebook.App.Tests/ProviderEmbeddingBridgeTests.cs` | Forward session preparation through WP2's thin App bridge. No view, binding or localization change. |
| 15 [Swift] | New `Sources/AINotebookCore/RetrievalPerformance.swift`, `Tests/AINotebookCoreTests/RetrievalPerformanceTests.swift` | Synthetic corpus + post-embedding timing hook. Existing eval quality API `RetrievalEval.swift:52–65` and runner are untouched. |
| 16 [Windows] | New `windows/src/AINotebook.Core/Rag/RetrievalPerformance.cs`, `windows/tests/AINotebook.Core.Tests/Rag/RetrievalPerformanceTests.cs` | Same generated corpus and measurement protocol. |
| 17 [Shared] | Modify `docs/contracts/folder-rag-v1.md:140–151`, `tools/contracts/gen_fixtures.py:395`; `Tests/fixtures/contracts/fts-query-v1.json:4` | Freeze §7 only after actual production SQLite tests pass on both operating systems. |

Tasks 2/3, 4/5 and 10/11 can start after Task 1 and their WP prerequisites. Tasks 6/7 and 8/9 follow the corresponding scope task and can run together; cache Tasks6a/7a follow their ranking task. The split keeps heap/ranking and cache concurrency independently reviewable in one session each. Tasks 12/13 join the respective lanes; 14 follows 11/13; 15/16 follow 12/13; 17 is last. Task 7 waits for WP4's Core csproj edit and any WP2 lock updates. No tasks permitted in parallel share a writable file.

## Frozen WP5 interfaces and ownership

These are additions, not claims that these symbols already exist. Give Swift stored DTOs public memberwise initializers with exactly the field order shown; C# uses sealed records with the PascalCase equivalents. All Swift DTOs are Sendable; Task4 declares `ChunkReference` and `RetrievalCacheKey` Equatable/Hashable. Task5 declares their C# record equality. IDs are Int64/long; scalar offsets and counts are Int/int; scores are Int64/long.

| DTO | Swift fields, in initializer order; C# capitalization is the only spelling difference |
|---|---|
| `ChunkReference` | `chunkId:Int64, sourceId:Int64, revisionId:Int64, ord:Int` |
| `ScopedSource` | `sourceId:Int64, folderId:Int64?, relPath:String?, displayName:String, publishedRevisionId:Int64?, vectorRevisionId:Int64?` |
| `VectorRow` | `reference:ChunkReference, values:[Float]` (C#: `float[] Values`) |
| `ScoredChunk` | `reference:ChunkReference, score:Float` (C#: `float Score`) |
| `RankedChunk` | `reference:ChunkReference, rrfMicro:Int64` |
| `RetrievalCacheKey` | `databaseId:String, notebookId:Int64, generationId:Int64, epoch:UInt64` (C#: `ulong Epoch`) |
| `ChunkEvidenceRow` | `reference:ChunkReference, canonicalText:String, chunkText:String, charStart:Int?, charEnd:Int?, pageHint:Int?, chunkerVersion:Int` |
| `EvidencePassage` | `reference:ChunkReference, text:String, displaySnippet:String, spans:[CitationSpan], isNeighbour:Bool` |

C# record constructors owned by Task5 are explicit (under `AINotebook.Core.Storage`, importing Models for CitationSpan):

```csharp
public sealed record ChunkReference(long ChunkId,long SourceId,long RevisionId,int Ord);
public sealed record ScopedSource(long SourceId,long? FolderId,string? RelPath,string DisplayName,
    long? PublishedRevisionId,long? VectorRevisionId);
public sealed record VectorRow(ChunkReference Reference,float[] Values);
public sealed record ScoredChunk(ChunkReference Reference,float Score);
public sealed record RankedChunk(ChunkReference Reference,long RrfMicro);
public sealed record RetrievalCacheKey(string DatabaseId,long NotebookId,long GenerationId,ulong Epoch);
public sealed record ChunkEvidenceRow(ChunkReference Reference,string CanonicalText,string ChunkText,
    int? CharStart,int? CharEnd,int? PageHint,int ChunkerVersion);
public sealed record EvidencePassage(ChunkReference Reference,string Text,string DisplaySnippet,
    IReadOnlyList<CitationSpan> Spans,bool IsNeighbour);
```

`ResolvedRetrievalScope` is a lease, not a Codable value. It contains `pin:QueryPin`, `scope:RetrievalScope`, `sources:[ScopedSource]`, `generation:IndexGeneration?`, `cacheKey:RetrievalCacheKey?`; C# implements IDisposable. It exposes `close() async` / `Dispose()`, idempotently releasing the WP3 pin. Empty scope is represented by `nil` / null, so constructing it cannot accidentally query. Database identity is part of the cache key because notebook/generation IDs repeat in different test and production databases.

WP3 APIs consumed verbatim: Swift `pinQuery(notebookId:Int64,modelKey:String) throws -> QueryPin`, `releaseQuery(_ pin:QueryPin)`, `generation(id:Int64) throws -> IndexGeneration?`, `garbageCollect(notebookId:Int64) throws -> GarbageCollectionResult`; C# `QueryPin PinQuery(long,string)`, `void ReleaseQuery(QueryPin)`, `IndexGeneration? Generation(long)`, `GarbageCollectionResult GarbageCollect(long)`. QueryPin has `token,notebookId,generationId?,modelKey?,dims?,lexicalRevisions,vectorRevisions` (WP3 plan:1153). WP5 never calls WP3's unbounded `pinnedEmbeddings` in the production scan.

## Task 1: [Shared] Freeze retrieval fixtures and independent integer oracles

**Depends on:** corrected WP0 and WP3 schema/fixture commit. **Parallel with:** no WP5 task until this commit; other WPs outside these files.

**Files:** exactly the eight Task 1 paths in the table.

**Interfaces — Consumes:** Swift `SharedFixtures.data(_ relativePath:String) throws -> Data`, `.json(_:) throws -> [String:Any]`; C# `SharedFixtures.Json(string) -> JsonElement`, `.Path(string) -> string`. **Produces:** Python `make_contracts() -> dict[str,dict]`, `rrf(lexical:list[int], vector:list[int], k:int=60) -> list[dict]`; CLI `python3 -B tools/contracts/gen_retrieval_fixtures.py [--check]`. Both platforms consume the same case shapes below.

- [ ] **Step 1: Add the generator test and run red.**

```python
import unittest
from gen_retrieval_fixtures import make_contracts, rrf

class RetrievalFixturesTests(unittest.TestCase):
    def test_integer_rrf(self):
        self.assertEqual([
            {"chunkId": 20, "rrfMicro": 32522},
            {"chunkId": 10, "rrfMicro": 16393},
            {"chunkId": 30, "rrfMicro": 16129}], rrf([20, 30], [10, 20]))
    def test_contracts(self):
        fs = make_contracts()
        self.assertEqual(6, len(fs))
        for f in fs.values():
            self.assertEqual(1, f['version'])
            names = [c['name'] for c in f['cases']]
            self.assertTrue(names)
            self.assertEqual(len(names), len(set(names)))
        self.assertEqual(make_contracts(), fs)

if __name__ == '__main__': unittest.main()
```

Run `python3 -B -m unittest discover -s tools/contracts -p 'test_retrieval_fixtures.py' -v` → FAIL, missing module. Implement this independent reference, not an import of either runtime:

```python
def rrf(lexical, vector, k=60):
    scores = {}
    for branch in (lexical, vector):
        seen = set()
        rank = 0
        for chunk in branch:
            if chunk in seen:
                continue
            seen.add(chunk)
            rank += 1
            scores[chunk] = scores.get(chunk, 0) + 1_000_000 // (k + rank)
    return [dict(chunkId=i, rrfMicro=s) for i, s in
            sorted(scores.items(), key=lambda item: (-item[1], item[0]))]
```

- [ ] **Step 2: Author these exact fixture payloads.** Each file has `contract` equal to its basename without `-v1.json`, `version:1`, and `cases`. JSON uses UTF-8 literal scalars, sorted keys, two-space indentation and final LF. Generator `--check` compares regenerated bytes and exits 1 on any difference; generation writes only these six named files. No timestamps, host Unicode classification, SQLite version or absolute paths in bytes.

`retrieval-scope-v1.json` has a shared `seed` object with these table rows. Typed fixture helpers insert these into an empty, migrated WP3 test store with explicit IDs and valid existing defaults. Sources are type `text`, status `ready`, timestamps `2026-01-01 00:00:00.000`; notebook names n1/n2. Folders use root `/fixture/f10` and `/fixture/f20`, `path_identity` JSON `{"volumeId":"fixture","components":["fixture","f10"]}` / `{"volumeId":"fixture","components":["fixture","f20"]}`, display names f10/f20, include_exts `["txt"]`, ignore_globs `[]`, limits `{}`. Source rel_path is `<id>.txt` for folder sources, null otherwise. No source file is read.

| sourceId | notebookId | folderId | availability | eligible | current | published | active done manifest |
|---|---|---|---|---|---|---|---|
| 1 | 1 | 10 | present | 1 | 102 | 102 | 101 |
| 2 | 1 | 10 | missing | 1 | 201 | 201 | 201 |
| 3 | 1 | 20 | present | 0 | 301 | 301 | 301 |
| 4 | 1 | null | present | 1 | 402 | 401 | 401 |
| 5 | 2 | null | present | 1 | 501 | 501 | none |
| 6 | 1 | 20 | present | 1 | 601 | null | none |
| 7 | 1 | 20 | unavailable | 1 | 701 | 701 | 701 |

For each revision in the table, canonical text is `needle revision <revisionId>`, hash `fixture-<revisionId>`, format1/chunker1, one chunk `id=revisionId*10, ord=0, text=canonicalText, token_count=4`, spans null. Revision ordinal is 1 or 2 as its last digit indicates. Insert sources with null pointers, then revisions/chunks, then pointers. Source4 status is `error` to prove failed refresh retains published evidence. Generation90 in notebook1 has legacy identity, model `m`, dims2, state active; manifest rows listed above are done, with vectors `[1,0]` for their chunks. Generation91 is retired with source1/revision102/vector `[0,1]`; it is not selected. Seed via raw SQL under the store gate/transaction: fixture state intentionally describes an already activated old generation, not a new activation that must include every current revision.

Scope cases (`scope`, `notebookId`, `active`=90 or null, `publishedChunkIds`, `vectorChunkIds`): `all` → [1020,4010]/[1010,4010]; `folder10` → [1020]/[1010]; `union-source4-folder10` → [1020,4010]/[1010,4010]; `empty` → []/[] with `sqlCalls:0`; `other-notebook` notebook2/all → [5010]/[]; `wrong-notebook-ids` notebook1/selection sources[5],folders[] → []/[]; `unpublished` source6 → []/[]; `no-active` all active null → [1020,4010]/[]. Include `events` cases: `revoke-availability` source1→missing, `revoke-eligible` source1→0, `revoke-membership` source1 folder10→20 under folder10 scope: after pin, expect no source1 result; `publish-during-query` source1 published→new103 after pin, expect old lexical1020/vector1010; `switch-during-query` retire90/activate91 after pin, expect generation90/vector1010. Each event has explicit before/after expected arrays, and lifecycle assertions reference retained IDs, never counts alone.

`retrieval-rank-v1.json` cases: `union` lexical[20,30],vector[10,20]; `tie` lexical[9],vector[3] → [3,9] each16393; `dedupe` lexical[20,20,30],vector[20] → [(20,32786),(30,16129)]; `empty` both[]; `full-pool` lexical[1,2],vector[3,4] → [1,3,2,4]. Add vectors cases `mask-before-heap` query[1,0], rows (1:[1,0],eligible0),(2:[0,1],eligible1),(3:[-1,0],eligible1), k2 → [2,3]; `tie-id` rows9/3 both[1,0], k1→[3]; `zero-legacy` rows1:[0,0],2:[-1,0],k2→[1,2]; `nonfinite` byte-level Float32 bits 0x7fc00000/0x7f800000 and wrong length → skipped, diagnostic invalidVectorCount3. Invalid query vectors empty/zero/wrongDims/nonfinite produce empty vector branch plus diagnostic, never a dot-product assertion failure. Rank fixture values are integer micro-units; vector fixtures use exactly representable integer values.

`retrieval-cache-v1.json` contains `budgetBytes:160`, `dims:2`, `rowsPerMatrix:2`, charged bytes per matrix80 (=2*(2*4+32)). Cases `lru` acquire A/release, B/release, acquire A/release, C/release → keys[A,C]; `leased-eviction` acquire A and B, invalidate A, request C → stream, resident160, release A → resident80, acquire C→resident160; `oversize` rows5 charged200→stream resident0; `epoch-race` reserve A epoch0, invalidate, complete old load→not admitted; `single-flight` two simultaneous acquire A→one loader and two leases; `load-failure` reservation cancelled→resident0; `databases-isolated` same notebook1/generation90 with database IDs db1/db2→two entries. The 32 bytes per row cover chunk/source/revision/ord as Int64 columns. Track matrix/column capacity, not only logical length; staging pages and heap have separately reported bounded bytes.

`retrieval-evidence-v1.json` contains canonical text `A😀B é C\nneedle tail`, source1/revision102, chunks (1020,ord0,start0,end7),(1021,ord1,start4,end12),(1022,ord2,start12,end20); expected text computed by Python scalar slice, not UTF-16. Cases `full-text`, `supplementary-prefix`, `published-neighbours` center1021/radius1→[1020,1022]; `old-vector` center1010/ord0/revision101 while published102, radius1 → candidates[(1020,102),(1021,102)]; neither may merge with revision101; `legacy` null spans/chunker1/chunkText=`legacy whole text`→text unchanged, spans[]; `invalid-span` end99→error `invalidSpan`; `wrong-revision` chunk1020 requested101→error `revisionMismatch`; `snippet` text=`😀`*241→240 scalar snippet and241 scalar evidence; `revoked` source1 missing after pin→no passage; `gc-pin` old101 retained across retirement/GC while lease exists, then collected after close with current/published102; fields `reference:{"chunkId":1010,"sourceId":1,"revisionId":101,"ord":0}`, `expectedText:"needle revision 101"`, `retireGenerationId:90`, `deletedRevisionId:101`. Neighbours are returned as candidates, never joined or budgeted here.

`retrieval-session-v1.json`: cases `root` type ollama root `http://localhost:11434` and `proxy` type openai_compatible root `https://unit.example/proxy/v1`; expected endpoint revision is `endpoint-v1:` + SHA256(type UTF8 + zero byte + normalized root UTF8). `key-rotation` oldKey a/newKey b → same endpoint revision, old captured session sends a; `root-change` old root above/new root `https://other.example/v1` → mismatch, requests0; `chat-only-anthropic`/`chat-only-openwebui` → unsupportedEndpoint, requests0; `legacy` modelKey `provider-a:qwen3:0.6b` → provider-a/rawModel `qwen3:0.6b`; `unknown-format` queryFormatVersion99 → unsupportedQueryFormat, requests0. Normal query format `1` and `legacy` mean unchanged input. New model-specific prefixes are versioned by WP7; do not infer them from a substring of the model name.

`retrieval-perf-v1.json`: `small` count8,dims4,seed17; `large100k` count100000,dims256,seed17; `large200k` count200000,dims256,seed17; `timing` clockTicks[100,130,180,230], frequency1000 → queryEmbeddingMs30,warmRetrievalMs50,hydrationMs50. For every row i (zero-based), sourceId=1+i//100, chunkId=i+1, ord=i%100, text=`synthetic <i> needle<i%97>`, vector all0 except index `(i+seed)%dims`=1. Store the first eight vectors/texts and expected hash of their Float32 little-endian bytes. Large fixtures specify counts/dimensions, never giant matrices. Include scenarios `concurrent-ingestion`, `streaming-budget`, `warm-cache`; timing assertions use a fake clock and no milliseconds threshold.

**Exact additional fixture shapes.** Every scope case has `name`, `scope` in existing scope-v1 JSON form, `notebookId`, `active`, `publishedChunkIds`, `vectorChunkIds`. Event cases add an `events` array and `afterPublishedChunkIds`/`afterVectorChunkIds`; initial arrays remain as above. The following generator data is normative. `applyEvent` executes these operations in one transaction; setFolder writes folder_id and rel_path together. For publication, create source1 revision103/chunk1030 with canonical `needle revision 103`, then set current/published103. For switch, retire90 and activate fixture91 by seed SQL (this is a simulated already-published transition, not a test of WP3 activation preconditions).

```python
scope_events = [
    dict(name="revoke-availability", scope={"kind":"all"},
         events=[dict(kind="setAvailability", sourceId=1, value="missing")],
         afterPublishedChunkIds=[4010], afterVectorChunkIds=[4010]),
    dict(name="revoke-eligible", scope={"kind":"all"},
         events=[dict(kind="setEligible", sourceId=1, value=0)],
         afterPublishedChunkIds=[4010], afterVectorChunkIds=[4010]),
    dict(name="revoke-membership", scope={"kind":"selection","sourceIds":[],"folderIds":[10]},
         events=[dict(kind="setFolder", sourceId=1, folderId=20, relPath="1.txt")],
         afterPublishedChunkIds=[], afterVectorChunkIds=[]),
    dict(name="join-membership", scope={"kind":"selection","sourceIds":[],"folderIds":[10]},
         events=[dict(kind="setFolder", sourceId=4, folderId=10, relPath="4.txt")],
         afterPublishedChunkIds=[1020], afterVectorChunkIds=[1010]),
    dict(name="publish-during-query", scope={"kind":"all"},
         events=[dict(kind="publish", sourceId=1, revisionId=103)],
         afterPublishedChunkIds=[1020,4010], afterVectorChunkIds=[1010,4010]),
    dict(name="switch-during-query", scope={"kind":"all"},
         events=[dict(kind="switchGeneration", oldId=90, newId=91)],
         afterPublishedChunkIds=[1020,4010], afterVectorChunkIds=[1010,4010])]
for case in scope_events:
    folder_only = case["scope"]["kind"] == "selection"
    case.update(notebookId=1, active=90,
                publishedChunkIds=[1020] if folder_only else [1020,4010],
                vectorChunkIds=[1010] if folder_only else [1010,4010])
```

For `retrieval-rank`, vector cases use `query`, `dims`, `rows:[{chunkId,sourceId,revisionId,ord,vector,eligible}]`, `k`, `expectedIds`, `expectedScoreMicros` (cosine×1e6 for exact fixture values); corrupt rows instead use `float32Bits` or `blobHex`. Add `oversized-generation` with `dims:2097153`, `expectedStatus:"oversizedVector"`, `expectedBlobReads:0`, `expectedEmbeddingCalls:0`; consumers test metadata only and never allocate that vector. Include k0→[], k9 with three rows→all sorted, forward/reversed input tied rows→identical IDs, and [3,4]/[4,3]→score960000.

Cache keys A/B/C map to `(databaseId:"db-A"/"db-B"/"db-C",notebookId:1,generationId:90,epoch:0)` so invalidating A cannot accidentally invalidate B. `databases-isolated` uses db-A and db-B with the same numeric IDs. Each action has `op`, `key` where applicable, named `lease` for acquisition/release, and `expected:{residentBytes,reservedBytes,entryCount,loadCount,residentKeys}`. Acquire adds `rows` (default2), `expectedMode:"cached"|"stream"`; `startAcquire` adds `barrier` and pauses the fill before completion; `completeFill`/`failFill` release that named barrier; `cancelWaiter` names the waiting lease. Freeze this concrete LRU script in the generator:

```python
def stats(resident, reserved, entries, loads, keys):
    return dict(residentBytes=resident, reservedBytes=reserved,
                entryCount=entries, loadCount=loads, residentKeys=keys)
lru_actions = [
    dict(op="acquire",key="A",lease="a",rows=2,expectedMode="cached",expected=stats(80,0,1,1,["A"])),
    dict(op="release",lease="a",expected=stats(80,0,1,1,["A"])),
    dict(op="acquire",key="B",lease="b",rows=2,expectedMode="cached",expected=stats(160,0,2,2,["A","B"])),
    dict(op="release",lease="b",expected=stats(160,0,2,2,["A","B"])),
    dict(op="acquire",key="A",lease="a2",rows=2,expectedMode="cached",expected=stats(160,0,2,2,["A","B"])),
    dict(op="release",lease="a2",expected=stats(160,0,2,2,["A","B"])),
    dict(op="acquire",key="C",lease="c",rows=2,expectedMode="cached",expected=stats(160,0,2,3,["A","C"])),
    dict(op="release",lease="c",expected=stats(160,0,2,3,["A","C"]))]
```

The remaining six scripts use those identical action fields. An invalidated live entry counts in residentBytes but not entryCount/residentKeys. `loadCount` increments only when fill is invoked, including failed fills; no-admission streaming increments it by0. Reservations show80 from startAcquire until completion/refund. Single-flight has loadCount1 and resident80 after both waiters complete. Epoch-race completes with all byte counts0; load-failure also refunds to0. These stats are integer oracles produced by a separate Python dictionary/counter simulator; it stores no Float32 matrix and imports neither platform implementation.

Session cases always carry explicit type/root/model/expectedError/request count fields for the operation they test. Add `legacy-bare` storedKey `m`, selectedProviderId `provider-a`, selectedModel `new-model`→rawModel `m`; `legacy-unresolved` storedKey `deleted:qwen3:0.6b`→legacyProviderUnresolved,requests0. Key rotation includes old/new roots equal to `https://unit.example/proxy/v1`, old/new keys `key-A`/`key-B`, rawModel `m:tag`, newModel `new:model`, providerId `provider-a`. Store those as `oldRoot`, `newRoot`, `oldKey`, `newKey`, `rawModel`, `newModel`, `providerId` keys. Canonical endpoint expected hashes are Python `hashlib.sha256` outputs; no host URL/Unicode rewriting is part of this oracle.

- [ ] **Step 3: Check generated bytes and both loaders, then commit.**

```bash
python3 -B -m unittest discover -s tools/contracts -p 'test_retrieval_fixtures.py' -v
python3 -B tools/contracts/gen_retrieval_fixtures.py
python3 -B tools/contracts/gen_retrieval_fixtures.py --check
swift test --filter SharedFixturesTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/contracts/gen_retrieval_fixtures.py tools/contracts/test_retrieval_fixtures.py Tests/fixtures/contracts/retrieval-scope-v1.json Tests/fixtures/contracts/retrieval-rank-v1.json Tests/fixtures/contracts/retrieval-cache-v1.json Tests/fixtures/contracts/retrieval-evidence-v1.json Tests/fixtures/contracts/retrieval-session-v1.json Tests/fixtures/contracts/retrieval-perf-v1.json
git commit -m "test(shared): freeze scoped retrieval ranking cache and evidence fixtures" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: two Python tests OK; generator check exit0; both envelope suites and complete suites green. The fixture commit does not freeze FTS yet.

## Task 2: [Swift] Build FTS expressions with pinned Unicode and real SQLite tests

**Depends on:** Task 1, WP3 integration, **WP4 Task 2 merged**. **Parallel with:** 3–11 as their prerequisites permit.

**Files:** the two Task 2 files only.

**Interfaces — Consumes:** Swift `UnicodeTables.bundled() throws`, `.nfc([UInt32])->[UInt32]`, `.generalCategory(UInt32)->String`; C# counterparts `LoadBundled()`, `Nfc(IReadOnlyList<int>)->int[]`, `GeneralCategory(int)->string`. **Produces:** Swift `FTSQueryBuilder.init(tables:UnicodeTables)`, `matchExpression(_ query:String) -> String?`; C# peer `FtsQueryBuilder(UnicodeTables tables)`, `string? MatchExpression(string query)`. No database access in the builder.

- [ ] **Step 1: Add this test, run red.**

```swift
import XCTest
import GRDB
@testable import AINotebookCore

final class FTSQueryBuilderTests: XCTestCase {
    func testSharedCasesOnSystemSQLite() throws {
        let builder = FTSQueryBuilder(tables: try UnicodeTables.bundled())
        let queue = try DatabaseQueue()
        let cases = try XCTUnwrap(SharedFixtures.json("contracts/fts-query-v1.json")["cases"] as? [[String: Any]])
        try queue.write { db in
            print("FTS provider=GRDB-system platform=macOS sqlite=\(try String.fetchOne(db, sql: "SELECT sqlite_version()")!)")
            try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(text, tokenize='unicode61 remove_diacritics 2')")
            for c in cases {
                let name = c["name"] as! String
                let expression = builder.matchExpression(c["query"] as! String)
                XCTAssertEqual(expression, c["expectedMatchExpr"] as? String, name)
                try db.execute(sql: "DELETE FROM probe")
                try db.execute(sql: "INSERT INTO probe(text) VALUES(?)", arguments: [c["documentText"] as! String])
                if let expression {
                    let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM probe WHERE probe MATCH ?", arguments: [expression])!
                    XCTAssertEqual(count == 1, c["shouldMatchDocument"] as? Bool, name)
                } else {
                    XCTAssertTrue(c["shouldMatchDocument"] is NSNull, name)
                }
            }
            XCTAssertEqual(cases.count, 24)
        }
    }
}
```

`swift test --filter FTSQueryBuilderTests` → FAIL, missing FTSQueryBuilder. An absent UnicodeTables is a missing prerequisite, not this task's red proof.

- [ ] **Step 2: Implement the complete builder.**

```swift
public struct FTSQueryBuilder: Sendable {
    private let tables: UnicodeTables
    public init(tables: UnicodeTables) { self.tables = tables }
    public func matchExpression(_ query: String) -> String? {
        let scalars = tables.nfc(query.unicodeScalars.map(\.value))
        var tokens: [String] = [], run: [UInt32] = []
        var seen = Set<[UInt32]>()
        func flush() {
            guard !run.isEmpty else { return }
            if tokens.count < RagContractV1.Retrieval.maxFtsTokens,
               seen.insert(run).inserted {
                let token = String(String.UnicodeScalarView(run.map { UnicodeScalar($0)! }))
                tokens.append("\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            }
            run.removeAll(keepingCapacity: true)
        }
        for cp in scalars {
            let category = tables.generalCategory(cp)
            let base = category.hasPrefix("L") || category.hasPrefix("N") || category == "Co"
            if base || (!run.isEmpty && category.hasPrefix("M")) { run.append(cp) }
            else { flush() }
        }
        flush()
        return tokens.isEmpty ? nil : tokens.joined(separator: " OR ")
    }
}
```

Use exact scalar arrays as dedupe keys; Swift String equality is canonically equivalent and is not the explicit scalar comparison contract. NFC is pinned WP4 NFC. No lowercasing, stemming, regex, stoplist or prefix expansion.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter FTSQueryBuilderTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/FTSQueryBuilder.swift Tests/AINotebookCoreTests/FTSQueryBuilderTests.swift
git commit -m "feat(retrieval): pinned Swift FTS query builder and SQLite conformance" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: one test executes all24 expressions and21 real MATCH assertions; full suite green. Keep the SQLite version line for Task17; do not change provisional status here.

## Task 3: [Windows] Build FTS expressions and verify e_sqlite3

**Depends on:** Task 1, WP3 integration, **WP4 Task 3 merged**. **Parallel with:** 2,4–11 as their prerequisites permit.

**Files:** the two Task 3 files only.

**Interfaces — Consumes:** `UnicodeTables.LoadBundled`, `Nfc(IReadOnlyList<int>)`, `GeneralCategory(int)`; Swift peer APIs in Task2. **Produces:** `FtsQueryBuilder(UnicodeTables)`, `string? MatchExpression(string)`; Swift `FTSQueryBuilder.init(tables:)`, `matchExpression(_:) -> String?`.

- [ ] **Step 1: Write the real-engine Fact.**

```csharp
using System.Text.Json;
using AINotebook.Core.Language;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;
namespace AINotebook.Core.Tests.Rag;

public sealed class FtsQueryBuilderTests(ITestOutputHelper output)
{
    [Fact]
    public void SharedCasesOnESqlite3()
    {
        var builder = new FtsQueryBuilder(UnicodeTables.LoadBundled());
        var gate = new object();
        lock (gate)
        {
            using var connection = new SqliteConnection("Data Source=:memory:");
            connection.Open();
            using var cmd = connection.CreateCommand();
            cmd.CommandText = "SELECT sqlite_version()";
            output.WriteLine($"FTS provider=SQLitePCLRaw-e_sqlite3 os={Environment.OSVersion} sqlite={cmd.ExecuteScalar()}");
            cmd.CommandText = "CREATE VIRTUAL TABLE probe USING fts5(text, tokenize='unicode61 remove_diacritics 2')";
            cmd.ExecuteNonQuery();
            int rows = 0;
            foreach (var c in SharedFixtures.Json("contracts/fts-query-v1.json").GetProperty("cases").EnumerateArray())
            {
                rows++;
                var expression = builder.MatchExpression(c.GetProperty("query").GetString()!);
                Assert.Equal(c.GetProperty("expectedMatchExpr").GetString(), expression);
                cmd.Parameters.Clear();
                cmd.CommandText = "DELETE FROM probe";
                cmd.ExecuteNonQuery();
                cmd.CommandText = "INSERT INTO probe(text) VALUES($text)";
                cmd.Parameters.AddWithValue("$text", c.GetProperty("documentText").GetString()!);
                cmd.ExecuteNonQuery();
                cmd.Parameters.Clear();
                if (expression is null) Assert.Equal(JsonValueKind.Null, c.GetProperty("shouldMatchDocument").ValueKind);
                else
                {
                    cmd.CommandText = "SELECT count(*) FROM probe WHERE probe MATCH $q";
                    cmd.Parameters.AddWithValue("$q", expression);
                    Assert.Equal(c.GetProperty("shouldMatchDocument").GetBoolean(), Convert.ToInt64(cmd.ExecuteScalar()) == 1);
                }
            }
            Assert.Equal(24, rows);
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FtsQueryBuilderTests` → FAIL, builder missing.

- [ ] **Step 2: Implement this tokenizer.**

```csharp
using System.Text;
using AINotebook.Core.Language;
namespace AINotebook.Core.Rag;

public sealed class FtsQueryBuilder(UnicodeTables tables)
{
    public string? MatchExpression(string query)
    {
        var scalars = tables.Nfc(query.EnumerateRunes().Select(r => r.Value).ToArray());
        var tokens = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var run = new StringBuilder();
        void Flush()
        {
            if (run.Length == 0) return;
            var token = run.ToString();
            if (tokens.Count < RagContractV1.Retrieval.MaxFtsTokens && seen.Add(token))
                tokens.Add("\"" + token.Replace("\"", "\"\"") + "\"");
            run.Clear();
        }
        foreach (int cp in scalars)
        {
            string category = tables.GeneralCategory(cp);
            bool start = category[0] is 'L' or 'N' || category == "Co";
            if (start || (run.Length != 0 && category[0] == 'M')) run.Append(new Rune(cp));
            else Flush();
        }
        Flush();
        return tokens.Count == 0 ? null : string.Join(" OR ", tokens);
    }
}
```

- [ ] **Step 3: Green locally and on Windows, then commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FtsQueryBuilderTests --logger "console;verbosity=detailed"
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/FtsQueryBuilder.cs windows/tests/AINotebook.Core.Tests/Rag/FtsQueryBuilderTests.cs
git commit -m "feat(win-retrieval): pinned FTS query builder and e_sqlite3 conformance" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: one Fact,24 expression comparisons,21 MATCH queries; full suite green. Running e_sqlite3 on macOS is useful but **does not replace the Windows execution evidence** required by Task17.

## Shared storage design for Tasks 4 and 5

The following APIs are implemented independently by their platform owner. No platform task edits its counterpart.

```swift
@MainActor public enum ScopeResolver {
    public static func resolve(store: NotebookStore, notebookId: Int64,
        scope: RetrievalScope, modelKey: String) throws -> ResolvedRetrievalScope?
}
// Factor inside WP3 NotebookStore+Generations.swift; preserve existing public API.
internal func withQueryPin<T>(notebookId: Int64, modelKey: String,
    read: (Database, QueryPin) throws -> T) throws -> (pin: QueryPin, value: T)
@MainActor extension NotebookStore {
    public func makeRetrievalReader() -> RetrievalReadStore
}
public struct RetrievalReadStore: Sendable {
    public func lexical(_ snapshot: ResolvedRetrievalScope, expression: String?, limit: Int) async throws -> [ChunkReference]
    public func vectorCount(_ snapshot: ResolvedRetrievalScope) async throws -> Int
    public func vectorPage(_ snapshot: ResolvedRetrievalScope, afterChunkId: Int64, limit: Int) async throws -> [VectorRow]
    public func permittedSourceIds(_ snapshot: ResolvedRetrievalScope) async throws -> Set<Int64>
    public func evidenceRows(_ snapshot: ResolvedRetrievalScope, references: [ChunkReference]) async throws -> [ChunkEvidenceRow]
    public func neighbourReferences(_ snapshot: ResolvedRetrievalScope, center: ChunkReference, radius: Int) async throws -> [ChunkReference]
    public func metadata(_ snapshot: ResolvedRetrievalScope) async throws -> [ScopedSource]
}
```

```csharp
public static ResolvedRetrievalScope? ScopeResolver.Resolve(NotebookStore store,
    long notebookId, RetrievalScope scope, string modelKey);
internal (QueryPin Pin, T Value) WithQueryPin<T>(long notebookId, string modelKey,
    Func<SqliteConnection, SqliteTransaction, QueryPin, T> read);
public RetrievalReadStore NotebookStore.MakeRetrievalReader();
public sealed class RetrievalReadStore
{
    public IReadOnlyList<ChunkReference> Lexical(ResolvedRetrievalScope snapshot, string? expression, int limit);
    public int VectorCount(ResolvedRetrievalScope snapshot);
    public IReadOnlyList<VectorRow> VectorPage(ResolvedRetrievalScope snapshot, long afterChunkId, int limit);
    public IReadOnlySet<long> PermittedSourceIds(ResolvedRetrievalScope snapshot);
    public IReadOnlyList<ChunkEvidenceRow> EvidenceRows(ResolvedRetrievalScope snapshot, IReadOnlyList<ChunkReference> references);
    public IReadOnlyList<ChunkReference> NeighbourReferences(ResolvedRetrievalScope snapshot, ChunkReference center, int radius);
    public IReadOnlyList<ScopedSource> Metadata(ResolvedRetrievalScope snapshot);
}
```

`ResolvedRetrievalScope` uses immutable data and a synchronized lease state, Swift `@unchecked Sendable` only for that documented lock-protected close flag. It must retain the store for release. Reject **new borrows** of a closed lease with `closedSnapshot`; already acquired operation tokens remain valid until released. New errors are Swift `RetrievalError:Error,Equatable` and C# `RetrievalException.Code`: `invalidFetchK`, `closedSnapshot`, `revisionMismatch`, `invalidSpan`, `invalidRadius`, `unsupportedQueryFormat`, `endpointRevisionMismatch`, `embeddingSessionRequired`, `legacyProviderUnresolved`, `invalidMeasurementInput`.

Use this bound SQL scope predicate everywhere (including metadata and neighbours):

```sql
s.notebook_id = $nb AND s.availability = 'present' AND s.eligible = 1
AND ($all = 1
 OR s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($sourceIds))
 OR s.folder_id IN (SELECT CAST(value AS INTEGER) FROM json_each($folderIds)))
```

Sorted JSON arrays are parameters, never SQL interpolation. Assert json_each support on both real SQLite builds in scope tests. It avoids SQLite's variable limit for large source selections. Initial scope resolution is SQL over sources, never loading every notebook chunk to filter in application code.

`withQueryPin` acquires WP3 registry coordination **before** its read transaction, constructs a provisional pin, invokes the callback in that transaction and registers only on success before releasing coordination. Existing `pinQuery` delegates to it with an empty callback. The callback resolves sources and the pinned generation row, and records lexical/vector revision pairs as sorted bound JSON arrays of `{sourceId,revisionId}`. This avoids separate transactions for active generation and scope. Do not call public `generation()` recursively inside the callback; fetch the row using the callback connection/transaction. Empty selection returns before entering the kernel.

Lexical SQL uses the pin's **initial published pairs**, retaining those even if a newer revision is published. The current scope predicate applies as a revocation intersection with the initial source IDs:

```sql
WITH published AS (
 SELECT json_extract(value,'$.sourceId') AS source_id,
        json_extract(value,'$.revisionId') AS revision_id FROM json_each($published)
)
SELECT sc.id, sc.source_id, sc.revision_id, sc.ord
FROM chunks_fts
JOIN source_chunks sc ON sc.id=chunks_fts.chunk_id
JOIN published p ON p.source_id=sc.source_id AND p.revision_id=sc.revision_id
JOIN sources s ON s.id=sc.source_id
WHERE chunks_fts MATCH $query
 AND s.notebook_id=$nb AND s.availability='present' AND s.eligible=1
 AND s.id IN (SELECT value FROM json_each($initialSourceIds))
 AND ($all=1 OR s.id IN (SELECT value FROM json_each($sourceIds))
             OR s.folder_id IN (SELECT value FROM json_each($folderIds)))
ORDER BY bm25(chunks_fts), sc.id
LIMIT $limit
```

Return early for nil expression. For vectors, read pages from the pinned generation's immutable done manifest, sorted by `ce.chunk_id`, using `ce.chunk_id>$after LIMIT $limit`; join chunk revision to manifest revision and the captured vector pairs, plus notebook and current eligibility. To share matrices across **scopes**, the matrix loader reads the whole pinned generation, with initial all-generation manifest identities and no per-selection filter. Scope-specific permitted source IDs are a separate mask applied before heap selection; cache never stores a scope-filtered matrix under a generation-only key. Keep legacy malformed vector validation in the reader/loader and count discarded rows. For keyset progress, return an internal `lastScannedChunkId` even when an entire page is malformed; never terminate merely because decoded valid rows are empty.

Hydration SQL reads by chunkId, checks the actual `(chunk,source,revision)` against each request, then checks the lease's permitted lexical/vector pairs. It joins `source_revisions` for canonical text and uses explicit revisions, not WP3's published-only `chunks(sourceId:)`. Fetch neighbours from the initial published revision with `ord BETWEEN center.ord-radius AND center.ord+radius`, exclude only the exact center chunk ID. For old vector center1010/ord0/revision101 and published102, radius1 returns1020/1021 at revision102, separately from direct1010. Ord is a deterministic position hint, not proof that content in two revisions is semantically adjacent. WP8 may merge only equal revision IDs. Metadata returns only sources with an initial published revision; separately expose the full initial eligible-source count for WP8 coverage. `sources_fts` is title search, not evidence, and does not contribute a third RRF branch.

### Store-owned operation leases and paging kernels (Tasks 4/5)

The storage task owns all these APIs, so hydration/cache workers need no changes to its files. `sources` captures **every eligible source in the initial scope**, including source6 without published chunks. `filesInScope` is `sources.count`; published metadata is a separate subset. The WP3 pin maps remain notebook-wide for a generation-wide matrix. All result-producing readers intersect with the initial scope IDs as well as the current scope predicate; matrix pages intentionally have no selection predicate.

```swift
public final class RetrievalOperation: @unchecked Sendable {
    public let snapshot: ResolvedRetrievalScope
    public func close() async
}
extension ResolvedRetrievalScope {
    public func acquireOperation() throws -> RetrievalOperation
}
internal struct RawVectorRow: Sendable {
    let reference: ChunkReference
    let blob: Data?
}
internal struct RawVectorPage: Sendable {
    let rows: [RawVectorRow]
    let lastScannedChunkId: Int64
    let exhausted: Bool
    let payloadBytes: Int
}
extension RetrievalReadStore {
    internal func lexical(_ operation: RetrievalOperation, expression: String?, limit: Int,
        permittedSources: Set<Int64>) async throws -> [ChunkReference]
    internal func rawVectorPage(_ operation: RetrievalOperation,
        afterChunkId: Int64, rowLimit: Int) async throws -> RawVectorPage
    internal func evidenceRows(_ operation: RetrievalOperation,
        references: [ChunkReference]) async throws -> [ChunkEvidenceRow]
    internal func neighbourReferences(_ operation: RetrievalOperation,
        center: ChunkReference, radius: Int) async throws -> [ChunkReference]
    public func currentEpoch(_ snapshot: ResolvedRetrievalScope) async throws -> UInt64
    internal func currentEpoch(_ operation: RetrievalOperation) async throws -> UInt64
    public func observedEpoch() -> UInt64
}
```

```csharp
public sealed class RetrievalOperation : IDisposable
{
    public ResolvedRetrievalScope Snapshot { get; }
    public void Dispose();
}
public RetrievalOperation ResolvedRetrievalScope.AcquireOperation();
internal sealed record RawVectorRow(ChunkReference Reference, byte[]? Blob);
internal sealed record RawVectorPage(IReadOnlyList<RawVectorRow> Rows,
    long LastScannedChunkId, bool Exhausted, int PayloadBytes);
internal IReadOnlyList<ChunkReference> RetrievalReadStore.Lexical(RetrievalOperation operation,
    string? expression,int limit,IReadOnlySet<long> permittedSources);
internal RawVectorPage RetrievalReadStore.RawVectorPage(RetrievalOperation operation,
    long afterChunkId, int rowLimit);
internal IReadOnlyList<ChunkEvidenceRow> RetrievalReadStore.EvidenceRows(
    RetrievalOperation operation, IReadOnlyList<ChunkReference> references);
internal IReadOnlyList<ChunkReference> RetrievalReadStore.NeighbourReferences(
    RetrievalOperation operation, ChunkReference center, int radius);
public ulong RetrievalReadStore.CurrentEpoch(ResolvedRetrievalScope snapshot);
internal ulong RetrievalReadStore.CurrentEpoch(RetrievalOperation operation);
public ulong RetrievalReadStore.ObservedEpoch();
```

Snapshot and operation tokens share this state machine. Swift uses the following synchronous state under NSLock, then invokes WP3 release on MainActor **after unlocking** when a transition returns true. Windows uses the identical counter logic under a private lock and invokes ReleaseQuery after unlocking. Operation close has its own idempotent flag, so `end()` is called exactly once per successful `begin()`. Snapshot close calls `requestClose()`; a duplicate close is harmless.

```swift
internal final class RetrievalLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var closing = false
    private var borrowers = 0
    private var released = false
    func begin() throws {
        try lock.withLock {
            guard !closing else { throw RetrievalError.closedSnapshot }
            borrowers += 1
        }
    }
    func requestClose() -> Bool {
        lock.withLock { closing = true; return takeRelease() }
    }
    func end() -> Bool {
        lock.withLock { precondition(borrowers > 0); borrowers -= 1; return takeRelease() }
    }
    private func takeRelease() -> Bool {
        guard closing && borrowers == 0 && !released else { return false }
        released = true
        return true
    }
}
```

```csharp
internal sealed class RetrievalLeaseState
{
    private readonly object _leaseGate = new();
    private bool _closing, _released;
    private int _borrowers;
    internal void Begin()
    {
        lock (_leaseGate)
        {
            if (_closing) throw new RetrievalException("closedSnapshot");
            _borrowers++;
        }
    }
    internal bool RequestClose()
    {
        lock (_leaseGate) { _closing = true; return TakeRelease(); }
    }
    internal bool End()
    {
        lock (_leaseGate)
        {
            if (_borrowers <= 0) throw new InvalidOperationException("Unbalanced retrieval borrow");
            _borrowers--; return TakeRelease();
        }
    }
    private bool TakeRelease()
    {
        if (!_closing || _borrowers != 0 || _released) return false;
        _released = true; return true;
    }
}
```

The token-aware lexical overload additionally binds its supplied mask as JSON and appends `AND s.id IN (SELECT value FROM json_each($permittedSources))` before ORDER BY/LIMIT. This supports the shrinking-mask retry without post-filtering topK. Its public snapshot wrapper uses the current permitted IDs as that mask. The token-aware reader overload validates the token's own open flag, not its owner's closing flag. Public snapshot overloads acquire one token and release in success and catch/finally paths. Hydration takes **one outer token** and uses only token-aware overloads until all text is copied. Swift cannot `await` in defer: use explicit do/catch close paths. No lease lock is held while entering an actor, database, or WP3 registry.

`byteWidth=checked(dims*4)`, `effectiveLimit=min(max(rowLimit,1),1024,8_388_608/byteWidth)`. If dims≤0 or byteWidth>8MiB, return diagnostic `oversizedVector` and an empty vector branch without loading any BLOB. Count rows with the same joins below, omitting cursor/LIMIT; reservation includes invalid rows conservatively. Use the WP3 table column `embedding`, not a new column name:

```sql
WITH pinned AS (
 SELECT CAST(json_extract(value,'$.sourceId') AS INTEGER) source_id,
        CAST(json_extract(value,'$.revisionId') AS INTEGER) revision_id
 FROM json_each($vectorPairs)
)
SELECT sc.id, sc.source_id, sc.revision_id, sc.ord,
       CASE WHEN length(ce.embedding)=$byteWidth THEN ce.embedding ELSE NULL END AS embedding
FROM chunk_embeddings ce
JOIN source_chunks sc ON sc.id=ce.chunk_id
JOIN index_generation_manifest m ON m.generation_id=ce.generation_id
 AND m.source_id=sc.source_id AND m.revision_id=sc.revision_id AND m.state='done'
JOIN pinned p ON p.source_id=sc.source_id AND p.revision_id=sc.revision_id
JOIN sources s ON s.id=sc.source_id
WHERE ce.generation_id=$generation AND s.notebook_id=$nb
 AND s.availability='present' AND s.eligible=1 AND ce.chunk_id>$after
ORDER BY ce.chunk_id LIMIT $limit
```

`lastScannedChunkId` is the final SQL row ID even if every returned BLOB is NULL/nonfinite. `exhausted` is SQL row count<effectiveLimit; zero rows retain the incoming cursor. Wrong-sized BLOBs never cross the SQLite boundary; decoding finite little-endian Float32 runs outside the DB gate. Scoped `vectorPage` repeatedly advances raw pages until it has its requested valid **scoped** count or reaches exhausted; an invalid-only page is never EOF. Cached and streamed paths use raw pages and one operation token for the scan. Refresh `data_version`/`total_changes()` through `currentEpoch` before acquisition and its **token-aware overload** after the final fill page; the cache's synchronous `epoch` callback calls `reader.observedEpoch()` / `reader.ObservedEpoch()`, which reads the shared atomic counter only, performs no SQL/borrow, and is safe from any executor.

Hydration first joins bound request JSON to `source_chunks` by chunkId only, returning actual source/revision. Compare the requested source/revision **before** eligibility/pin filtering (otherwise mismatches silently disappear). It throws `revisionMismatch` for a chunk that exists but has a different source/revision. A missing/revoked source yields no passage. In the **same read transaction**, fetch `SELECT id,canonical_text,chunker_version FROM source_revisions WHERE id IN (SELECT value FROM json_each($revisionIds))`. Build one string value per revision and share it across rows; do not SELECT a multi-megabyte canonical text once per chunk. Metadata, neighbour and hydration SQL all include `$initialSourceIds`. Neighbours use the captured published pair and this predicate:

```sql
SELECT sc.id,sc.source_id,sc.revision_id,sc.ord
FROM source_chunks sc JOIN sources s ON s.id=sc.source_id
WHERE sc.source_id=$source AND sc.revision_id=$publishedRevision
 AND sc.ord BETWEEN $firstOrd AND $lastOrd AND sc.id<>$centerChunk
 AND s.notebook_id=$nb AND s.availability='present' AND s.eligible=1
 AND s.id IN (SELECT value FROM json_each($initialSourceIds))
 AND ($all=1 OR s.id IN (SELECT value FROM json_each($sourceIds))
             OR s.folder_id IN (SELECT value FROM json_each($folderIds)))
ORDER BY sc.ord,sc.id
```

Reject negative radius. Swift computes the upper bound with `Int64(center.ord).addingReportingOverflow(Int64(radius))` and saturates an overflow at Int64.max; lower bound is max(0,ord-radius). C# widens both int operands to long before addition/subtraction and clamps lower bound to0. For radius0, return no neighbours immediately, including across revisions. New publication never changes the captured published pair during a turn.

Install **connection-local TEMP triggers**, after migration, for INSERT/UPDATE/DELETE on `notebooks`, `sources`, `source_chunks`, `source_revisions`, `chunk_embeddings`, `index_generations`, `index_generation_manifest`, `folder_sources`, `source_set_members`, `source_set_folders`. Register UDF `rag_retrieval_changed()` that only atomically increments a shared per-database UInt64/ulong epoch. Example:

```sql
CREATE TEMP TRIGGER rag_sources_update AFTER UPDATE ON main.sources
BEGIN SELECT rag_retrieval_changed(); END;
```

The complete trigger name formula is `rag_<table>_<insert|update|delete>`, with event uppercased and identifier drawn exclusively from the fixed list above. Swift uses `DatabaseFunction(name:argumentCount:pure:function:)` and `db.add(function:)`; Windows `CreateFunction("rag_retrieval_changed", callback, isDeterministic:false)` under `_gate`. Trigger rollback may conservatively invalidate; it must not reenter SQL, pin registry, cache lock or actor. No durable schema changes. This catches WP6 writes and compatibility/raw test paths without editing their files. Check `PRAGMA data_version` and `total_changes()` on cache access as an external-connection fallback; a change invalidates this database's entries. Constructor and reader share the canonical identity already used by WP3. Runtime trigger overhead is measured in WP7.

## Task 4: [Swift] Atomic scope SQL, bounded read store and invalidation epoch

**Depends on:** Task 1 and WP3 Task10 merged. **Parallel with:** 2,3,5,10,11.

**Files:** the eight Task4 paths in the table. No other store extension edits.

**Interfaces — Consumes:** WP3 pin/generation APIs above, `DatabaseQueue` at `NotebookStore.swift:14`, `V19TestStore.make() throws -> NotebookStore`. C# peers `PinQuery`, `V19TestStore.Create()`. **Produces:** all Swift storage signatures above, parity C# signatures fixed in the same section. Test helper `RetrievalFixtureStore.make(_ caseName:String="all") throws -> NotebookStore`, `.cases() throws -> [[String:Any]]`, `.applyEvent(_ name:String,to store:NotebookStore) throws`, plus `sqlStatementCount` captured through GRDB Configuration trace in the fixture store.

- [ ] **Step 1: Write this red SQL test.**

```swift
import XCTest
@testable import AINotebookCore

@MainActor final class RetrievalScopeSQLTests: XCTestCase {
    func testAllSharedScopesAndRevisionRules() async throws {
        for c in try RetrievalFixtureStore.cases() where c["events"] == nil {
            let store = try RetrievalFixtureStore.make(c["name"] as! String)
            let scope = try JSONDecoder().decode(RetrievalScope.self,
                from: JSONSerialization.data(withJSONObject: c["scope"]!))
            let snapshot = try ScopeResolver.resolve(store: store,
                notebookId: (c["notebookId"] as! NSNumber).int64Value, scope: scope, modelKey: "m")
            if scope.isEmptySelection {
                XCTAssertNil(snapshot)
                XCTAssertEqual(RetrievalFixtureStore.sqlStatementCount(store), 0)
                continue
            }
            let lease = try XCTUnwrap(snapshot)
            let reader = store.makeRetrievalReader()
            let lexical = try await reader.lexical(lease, expression: "\"needle\"", limit: 32)
            var vector: [Int64] = [], after: Int64 = 0
            while true {
                let page = try await reader.vectorPage(lease, afterChunkId: after, limit: 1)
                if page.isEmpty { break }
                after = page.last!.reference.chunkId
                vector.append(contentsOf: page.map { $0.reference.chunkId })
            }
            XCTAssertEqual(lexical.map(\.chunkId).sorted(), (c["publishedChunkIds"] as! [NSNumber]).map(\.int64Value))
            XCTAssertEqual(vector.sorted(), (c["vectorChunkIds"] as! [NSNumber]).map(\.int64Value))
            await lease.close()
        }
    }
}
```

Run `swift test --filter RetrievalScopeSQLTests` → FAIL, helper/resolver missing. The test's public `vectorPage` is the **scoped valid-row facade**; implement an internal raw paging cursor for the cache loader so invalid-only pages still advance. Supply the same scoped facade on C#.

- [ ] **Step 2: Implement helpers and SQL.** Seed the shared source/revision/generation records with bound arguments in `store.runOnDatabase`, resetting tracing after setup. Use `JSONSerialization` decoding of all fixture rows; no per-platform expected result table. All production scope and revision predicates are those above. `makeRetrievalReader` captures the existing DatabaseQueue once on MainActor; async methods use `try await queue.read { db in ... }` and return materialized Sendable rows, never a cursor. Float decoding and normalization occur off the database queue. Snapshot creation/release remain on MainActor and reuse WP3 registry locks. Move no network or expensive vector arithmetic to MainActor.

Add this regression before implementing operation retention (imports also include GRDB). It consumes the shared GC identity and verifies actual WP3 collection:

```swift
func testOperationBorrowSurvivesOwnerClose() async throws {
    let fixture = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
    let c = (fixture["cases"] as! [[String:Any]]).first { $0["name"] as? String == "gc-pin" }!
    let r = c["reference"] as! [String:NSNumber]
    let ref = ChunkReference(chunkId:r["chunkId"]!.int64Value, sourceId:r["sourceId"]!.int64Value,
        revisionId:r["revisionId"]!.int64Value, ord:r["ord"]!.intValue)
    let store = try RetrievalFixtureStore.make()
    let snapshot = try XCTUnwrap(ScopeResolver.resolve(store:store,notebookId:1,scope:.all,modelKey:"m"))
    let operation = try snapshot.acquireOperation()
    await snapshot.close()
    XCTAssertThrowsError(try snapshot.acquireOperation())
    try store.retireGeneration(id:(c["retireGenerationId"] as! NSNumber).int64Value)
    _ = try store.garbageCollect(notebookId:1)
    let rows = try await store.makeRetrievalReader().evidenceRows(operation,references:[ref])
    XCTAssertEqual(rows.map(\.chunkText), [c["expectedText"] as! String])
    await operation.close()
    _ = try store.garbageCollect(notebookId:1)
    let remaining = try store.runOnDatabase { db in
        try Int.fetchOne(db,sql:"SELECT count(*) FROM source_revisions WHERE id=?",arguments:[ref.revisionId])!
    }
    XCTAssertEqual(remaining,0)
}
```

- [ ] **Step 3: Add and run these five regression methods using the shared event rows.** `testRevocationsAndPublication` executes every event, compares revalidated lexical/vector/source IDs, and asserts no newly joined source is admitted. `testEpochObservesAllMutationTablesAndRollback` loops the fixed10-table list with valid fixture writes, whole-table deletes where safe and transaction rollback, asserting epoch increases and no durable `rag_%` triggers exist. `testCrossStoreInvalidationAndGC` opens two stores on the same temporary file, pins with one, writes and runs GC with the other, proves old pinned IDs survive and data_version changes are observed. `testPagedReaderBoundAndInvalidBlobProgress` seeds2050 valid vectors plus1024 invalid middle rows, asks1024 pages, asserts each raw page≤1024/8MiB, last valid chunk returned and no infinite loop. Add `testCallbackFailureDoesNotRegisterPin` throwing inside withQueryPin, then GC deletes the unreferenced revision.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter RetrievalScopeSQLTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/ScopeResolver.swift Sources/AINotebookCore/RetrievalStorageTypes.swift Sources/AINotebookCore/NotebookStore+Retrieval.swift Sources/AINotebookCore/RetrievalInvalidation.swift Sources/AINotebookCore/NotebookStore.swift Sources/AINotebookCore/NotebookStore+Generations.swift Tests/AINotebookCoreTests/RetrievalScopeSQLTests.swift Tests/AINotebookCoreTests/RetrievalFixtureStore.swift
git commit -m "feat(retrieval): atomic Swift scope leases bounded reads and invalidation" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: seven methods green, all scope/event cases consumed; complete Swift suite green.

## Task 5: [Windows] Atomic scope SQL, bounded readers and invalidation epoch

**Depends on:** Task1 and WP3 Task11 merged. **Parallel with:** 2,3,4,10,11.

**Files:** the eight Task5 paths in the table.

**Interfaces — Consumes:** WP3 `QueryPin`, `Generation`, `V19TestStore.Create`, `_gate/_conn`. Swift peer `withQueryPin`, `V19TestStore.make`. **Produces:** all C# storage signatures above; Swift parity signatures are frozen there. Test helper `RetrievalFixtureStore.Create(string caseName="all") -> NotebookStore`, `Cases() -> IEnumerable<JsonElement>`, `ApplyEvent(string,NotebookStore)`, `SqlStatementCount(NotebookStore) -> int`. Count commands through a test-only reader diagnostic callback; empty resolution asserts it stays0 and no pin registry entry exists.

- [ ] **Step 1: Add red shared SQL Fact.**

```csharp
using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

public sealed class RetrievalScopeSQLTests
{
    [Fact]
    public void AllSharedScopesAndRevisionRules()
    {
        foreach (var c in RetrievalFixtureStore.Cases().Where(c => !c.TryGetProperty("events", out _)))
        {
            using var store = RetrievalFixtureStore.Create(c.GetProperty("name").GetString()!);
            var scope = RetrievalScopeJson.Deserialize(c.GetProperty("scope").GetRawText());
            using var snapshot = ScopeResolver.Resolve(store, c.GetProperty("notebookId").GetInt64(), scope, "m");
            if (scope.IsEmptySelection)
            {
                Assert.Null(snapshot);
                Assert.Equal(0, RetrievalFixtureStore.SqlStatementCount(store));
                continue;
            }
            Assert.NotNull(snapshot);
            var reader = store.MakeRetrievalReader();
            var lexical = reader.Lexical(snapshot, "\"needle\"", 32);
            var vector = new List<long>();
            long after = 0;
            while (true)
            {
                var page = reader.VectorPage(snapshot, after, 1);
                if (page.Count == 0) break;
                after = page[^1].Reference.ChunkId;
                vector.AddRange(page.Select(x => x.Reference.ChunkId));
            }
            Assert.Equal(c.GetProperty("publishedChunkIds").EnumerateArray().Select(x => x.GetInt64()), lexical.Select(x => x.ChunkId).Order());
            Assert.Equal(c.GetProperty("vectorChunkIds").EnumerateArray().Select(x => x.GetInt64()), vector.Order());
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~RetrievalScopeSQLTests` → FAIL, missing resolver/helper.

- [ ] **Step 2: Implement SQL and leases.** `WithQueryPin` holds `_gate`, then WP3 registry coordination, then the transaction; pass that transaction on every command. Register on callback success only. Never materialize a reader after releasing `_gate`. Read methods return copied rows and do CPU work after the lock. `Dispose` is Interlocked/idempotent and calls WP3 ReleaseQuery once. Seed fixtures with Dapper inside `lock(store.Gate)` and one transaction, respecting source/revision pointer ordering. TEMP triggers and UDF installation occur under `_gate` after migration, not in shipped DDL. The callback uses Interlocked.Increment on a long and an unchecked ulong projection; do not acquire any other lock from the UDF.

Add this Fact before implementing operation retention. Imports also include `Dapper`, `AINotebook.Core.Storage`.

```csharp
[Fact]
public void OperationBorrowSurvivesOwnerDispose()
{
    var c=SharedFixtures.Json("contracts/retrieval-evidence-v1.json").GetProperty("cases").EnumerateArray()
        .Single(x=>x.GetProperty("name").GetString()=="gc-pin");
    var r=c.GetProperty("reference");
    var reference=new ChunkReference(r.GetProperty("chunkId").GetInt64(),r.GetProperty("sourceId").GetInt64(),
        r.GetProperty("revisionId").GetInt64(),r.GetProperty("ord").GetInt32());
    using var store=RetrievalFixtureStore.Create();
    var snapshot=ScopeResolver.Resolve(store,1,new RetrievalScope.All(),"m")!;
    using var operation=snapshot.AcquireOperation();
    snapshot.Dispose();
    Assert.Throws<RetrievalException>(()=>snapshot.AcquireOperation());
    store.RetireGeneration(c.GetProperty("retireGenerationId").GetInt64());
    store.GarbageCollect(1);
    var rows=store.MakeRetrievalReader().EvidenceRows(operation,new[] {reference});
    Assert.Equal(new[] {c.GetProperty("expectedText").GetString()},rows.Select(x=>x.ChunkText));
    operation.Dispose();
    store.GarbageCollect(1);
    lock(store.Gate)
        Assert.Equal(0,store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM source_revisions WHERE id=$id",new {id=reference.RevisionId}));
}
```

- [ ] **Step 3: Add five concrete regression Facts.** `RevocationsAndPublication` loops the six event cases and compares every before/after array. `EpochObservesAllMutationTablesAndRollback` writes the10 tables, verifies epoch increases including cascades/DELETE and confirms main.sqlite_master has no new triggers. `CrossStoreInvalidationAndGC` uses two file-backed stores, Barrier-controlled pin/write/GC order and verifies retained IDs before and after Dispose. `PagedReaderBoundAndInvalidBlobProgress` seeds2050 valid+1024 invalid rows and verifies bounded pages and terminal cursor progress. `CallbackFailureDoesNotRegisterPin` throws in WithQueryPin then proves GC releases unreferenced IDs. All direct test connections/commands hold their store gate; no timing sleeps.

- [ ] **Step 4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~RetrievalScopeSQLTests
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/ScopeResolver.cs windows/src/AINotebook.Core/Storage/RetrievalStorageTypes.cs windows/src/AINotebook.Core/Storage/NotebookStore.Retrieval.cs windows/src/AINotebook.Core/Storage/RetrievalInvalidation.cs windows/src/AINotebook.Core/Storage/NotebookStore.cs windows/src/AINotebook.Core/Storage/NotebookStore.Generations.cs windows/tests/AINotebook.Core.Tests/Rag/RetrievalScopeSQLTests.cs windows/tests/AINotebook.Core.Tests/Helpers/RetrievalFixtureStore.cs
git commit -m "feat(win-retrieval): atomic scope leases bounded SQL and invalidation" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: seven Facts green, all shared scope/event rows consumed; complete Core suite green.

## Ranking/cache contract for Tasks 6 and 7

```swift
public enum RetrievalRanking {
    public static func fuse(lexical: [ChunkReference], vector: [ChunkReference], rrfK: Int = 60) throws -> [RankedChunk]
    public static func topK(rows: [VectorRow], query: [Float], permittedSources: Set<Int64>, k: Int) -> [ScoredChunk]
}
public actor VectorMatrixCache {
    public static let shared: VectorMatrixCache
    public init(budgetBytes: Int64 = RagContractV1.Cache.globalBudgetBytes)
    internal func acquire(key: RetrievalCacheKey, rowCount: Int, dims: Int,
        epoch: @escaping @Sendable () -> UInt64,
        load: @escaping @Sendable () async throws -> [VectorRow]) async throws -> VectorMatrixLease?
    public func invalidate(databaseId: String)
    public func statistics() -> VectorCacheStatistics
}
public struct VectorCacheStatistics: Sendable {
    public let residentBytes: Int64
    public let reservedBytes: Int64
    public let loadCount: Int
    public let entryCount: Int
}
public final class VectorMatrixLease: @unchecked Sendable {
    public func topK(query: [Float], permittedSources: Set<Int64>, k: Int) -> [ScoredChunk]
    public func close() async
}
```

```csharp
public static IReadOnlyList<RankedChunk> RetrievalRanking.Fuse(
    IReadOnlyList<ChunkReference> lexical, IReadOnlyList<ChunkReference> vector, int rrfK=60);
public static IReadOnlyList<ScoredChunk> RetrievalRanking.TopK(
    IReadOnlyList<VectorRow> rows, float[] query, IReadOnlySet<long> permittedSources, int k);
public sealed class VectorMatrixCache
{
    public static VectorMatrixCache Shared { get; }
    public VectorMatrixCache(long budgetBytes=536870912);
    internal Task<VectorMatrixLease?> AcquireAsync(RetrievalCacheKey key, int rowCount, int dims,
        Func<ulong> epoch, Func<CancellationToken,Task<IReadOnlyList<VectorRow>>> load, CancellationToken ct=default);
    public void Invalidate(string databaseId);
    public VectorCacheStatistics Statistics();
}
public sealed record VectorCacheStatistics(long ResidentBytes,long ReservedBytes,int LoadCount,int EntryCount);
public sealed class VectorMatrixLease : IDisposable
{
    public IReadOnlyList<ScoredChunk> TopK(float[] query,IReadOnlySet<long> permittedSources,int k);
    public void Dispose();
}
```

The array-loader overload above is **test-only/internal** on both platforms. The production overload has the same arguments except `load` writes pages into a preallocated builder:

```swift
public func acquire(key: RetrievalCacheKey, rowCount: Int, dims: Int,
    epoch: @escaping @Sendable () -> UInt64,
    fill: @escaping @Sendable (VectorMatrixBuilder) async throws -> Void) async throws -> VectorMatrixLease?
public final class VectorMatrixBuilder: @unchecked Sendable {
    public func append(_ page: [VectorRow]) throws
}
```

```csharp
public Task<VectorMatrixLease?> AcquireAsync(RetrievalCacheKey key,int rowCount,int dims,
    Func<ulong> epoch,Func<VectorMatrixBuilder,CancellationToken,Task> fill,CancellationToken ct=default);
public sealed class VectorMatrixBuilder { public void Append(IReadOnlyList<VectorRow> page); }
```

The builder's unchecked Sendable conformance covers its exclusively owned loading buffer: only the fill worker may call append and publication permanently seals it. The lease's unchecked conformance covers immutable buffers plus its lock-protected close flag. The builder owns exactly one Float32 slab and four Int64 columns, allocated after reservation. It has one writer while loading; publish makes it immutable. Expose no mutable arrays from a lease. Do not construct all `[VectorRow]` outside the budget and then copy them into a matrix. The internal test overload feeds one page into this production builder.

Cache state: key→loading task or immutable entry; entry tracks bytes, lease count, last-use monotonically increasing tick and invalidated flag. Global singleton spans all notebooks and databases. Charge `rowCapacity*(dims*4+32)` using checked Int64 arithmetic **before allocating**. Also retain reservations while loading and bytes for invalidated/evicted matrices with live leases. Evict only zero-lease entries, oldest tick first (key ordinal tie), until enough space; if impossible return nil and stream. Count/order diagnostics must not allocate an extra matrix. A failed/cancelled fill refunds its reservation. Completion compares captured and current epoch; a mismatch never publishes the entry. The fill owns a `RetrievalOperation` acquired before the first await and passes it to every raw page read; release it after fill completes/fails. It cannot borrow the caller-facing snapshot again after that caller cancels. Waiting callers share one in-flight fill; cancellation of one waiter must not cancel other waiters' successful fill. Shutdown/last-waiter cancellation cancels fill and refunds once.

Normalize each finite, correctly dimensioned vector using a Double accumulator and write Float32 values in place. Preserve legacy zero vectors as zero. Reject nonfinite and malformed stored vectors with diagnostic count; reject invalid query vectors as an empty vector branch. Dot product uses `vDSP_dotpr` on slice pointers on Swift; `TensorPrimitives.Dot<float>` on spans on Windows. Do not allocate a row slice. SIMD scores need not be bit-identical for arbitrary live embeddings, but tied exact fixture vectors must rank identically.

Heap comparator: “better” is higher score or equal score/smaller chunkId; root is the worst retained element. Check the eligible source mask **before** dot product and insertion. For every eligible row: append/sift-up until k; afterward replace root only if better and sift-down. Sort only the final ≤k entries by the same comparator. Streaming calls this same accumulator across pages, never per-page topK fusion and never sorting N scores. Dedupe branch IDs before assigning 1-based ranks; reject conflicting source/revision metadata for the same chunk identity as corruption. RRF has no final `prefix(fetchK)`.

### Masked scoring kernels owned by Tasks 6/7

The builder normalizes each stored row once using Double accumulation; zero legacy rows remain zero. Query initialization rejects zero/nonfinite/wrong-dimension input. Both cached and streamed scans use **one accumulator over the whole generation**. Streaming normalizes a bounded page in place, offers its rows, then discards it. The public `topK(rows:...)`/`TopK(...)` test facade derives dims from the first valid row, normalizes temporary rows, and calls this same kernel. The production cache knows generation dims and never derives them from an arbitrary row.

```swift
import Accelerate

internal struct MaskedVectorTopK {
    private let query: [Float]
    private let permitted: Set<Int64>
    private let k: Int
    private var heap: [ScoredChunk] = []
    static func normalize(_ row: UnsafeMutableBufferPointer<Float>, allowZero: Bool) -> Bool {
        guard !row.isEmpty else { return false }
        var squared: Double = 0
        for x in row {
            guard x.isFinite else { return false }
            squared += Double(x) * Double(x)
        }
        guard squared.isFinite else { return false }
        if squared == 0 { return allowZero }
        let norm = squared.squareRoot()
        for i in row.indices { row[i] = Float(Double(row[i]) / norm) }
        return true
    }
    init?(query: [Float], dims: Int, permittedSources: Set<Int64>, k: Int) {
        guard k > 0, dims > 0, query.count == dims else { return nil }
        var normalized = query
        guard normalized.withUnsafeMutableBufferPointer({ Self.normalize($0, allowZero: false) }) else { return nil }
        self.query = normalized; self.permitted = permittedSources; self.k = k
    }
    private static func better(_ a: ScoredChunk, _ b: ScoredChunk) -> Bool {
        a.score > b.score || (a.score == b.score && a.reference.chunkId < b.reference.chunkId)
    }
    mutating func offer(_ reference: ChunkReference, normalizedRow row: UnsafeBufferPointer<Float>) {
        guard permitted.contains(reference.sourceId), row.count == query.count else { return }
        var score: Float = 0
        query.withUnsafeBufferPointer { q in
            vDSP_dotpr(q.baseAddress!, 1, row.baseAddress!, 1, &score, vDSP_Length(q.count))
        }
        guard score.isFinite else { return }
        let candidate = ScoredChunk(reference: reference, score: score)
        if heap.count < k {
            heap.append(candidate)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard Self.better(heap[parent], heap[i]) else { break }
                heap.swapAt(parent, i); i = parent
            }
            return
        }
        guard Self.better(candidate, heap[0]) else { return }
        heap[0] = candidate
        var i = 0
        while 2 * i + 1 < heap.count {
            let left = 2 * i + 1, right = left + 1
            var worst = left
            if right < heap.count && Self.better(heap[left], heap[right]) { worst = right }
            guard Self.better(heap[i], heap[worst]) else { break }
            heap.swapAt(i, worst); i = worst
        }
    }
    func sorted() -> [ScoredChunk] { heap.sorted(by: Self.better) }
}
```

Borrow the slab's buffer once for the scan. Offer `UnsafeBufferPointer(start: slab.baseAddress!.advanced(by: rowIndex*dims), count: dims)` without allocating a row slice. Only builder-validated finite rows enter the slab; no second full-array finiteness pass is needed in the hot path.

```csharp
using System.Numerics.Tensors;
using AINotebook.Core.Storage;
namespace AINotebook.Core.Rag;

internal sealed class MaskedVectorTopK
{
    private readonly float[] _query;
    private readonly HashSet<long> _permitted;
    private readonly int _k;
    private readonly PriorityQueue<ScoredChunk,(float Score,long ReverseId)> _heap = new();
    private MaskedVectorTopK(float[] query,IReadOnlySet<long> permitted,int k)
    { _query=query; _permitted=permitted.ToHashSet(); _k=k; }
    internal static bool Normalize(Span<float> row,bool allowZero)
    {
        if(row.IsEmpty) return false;
        double squared=0;
        foreach(float x in row)
        { if(!float.IsFinite(x)) return false; squared+=(double)x*x; }
        if(!double.IsFinite(squared)) return false;
        if(squared==0) return allowZero;
        double norm=Math.Sqrt(squared);
        for(int i=0;i<row.Length;i++) row[i]=(float)(row[i]/norm);
        return true;
    }
    internal static MaskedVectorTopK? Create(float[] query,int dims,IReadOnlySet<long> permittedSources,int k)
    {
        if(k<=0 || dims<=0 || query.Length!=dims) return null;
        float[] normalized=(float[])query.Clone();
        return Normalize(normalized,false) ? new(normalized,permittedSources,k) : null;
    }
    private static bool Better(ScoredChunk a,ScoredChunk b) =>
        a.Score>b.Score || (a.Score==b.Score && a.Reference.ChunkId<b.Reference.ChunkId);
    internal void Offer(ChunkReference reference,ReadOnlySpan<float> normalizedRow)
    {
        if(!_permitted.Contains(reference.SourceId) || normalizedRow.Length!=_query.Length) return;
        float score=TensorPrimitives.Dot<float>(normalizedRow,_query);
        if(!float.IsFinite(score)) return;
        var candidate=new ScoredChunk(reference,score);
        var priority=(score,-reference.ChunkId);
        if(_heap.Count<_k) _heap.Enqueue(candidate,priority);
        else if(Better(candidate,_heap.Peek()))
        { _heap.Dequeue(); _heap.Enqueue(candidate,priority); }
    }
    internal IReadOnlyList<ScoredChunk> Sorted() => _heap.UnorderedItems.Select(x=>x.Element)
        .OrderByDescending(x=>x.Score).ThenBy(x=>x.Reference.ChunkId).ToArray();
}
```

Pass `slab.AsSpan(rowIndex*dims,dims)`; no per-row array. Neither implementation filters an already truncated topK result to implement scope.

### Cache accounting kernels owned by Tasks 6a/7a

`VectorCacheStatistics` exposes matrix payload+four-column capacity. The512MiB ceiling covers **all** matrices and reservations process-wide, including live invalidated leases. Paging/heap/query arrays are separately bounded and reported; this is not a claim to cap the entire process RSS. An empty generation bypasses acquisition. Additional internal diagnostics: Swift `residentKeys() -> [RetrievalCacheKey]` (actor-isolated), C# `IReadOnlyList<RetrievalCacheKey> ResidentKeys()`; sort by ordinal databaseId then notebookId/generationId/epoch.

Use this ledger under the cache actor/gate. A slot remains charged until freed; committing a successful fill transfers bytes from reserved to resident without changing the total. Eviction must remove an unleased entry before `dropResident`; failure uses `abandon`; no fill may allocate before a successful `reserve`.

```swift
internal struct MatrixBudget {
    let limit: Int64
    private(set) var resident: Int64 = 0
    private(set) var reserved: Int64 = 0
    static func charge(rows: Int, dims: Int) -> Int64? {
        guard rows > 0, dims > 0 else { return nil }
        let (floats, a) = Int64(dims).multipliedReportingOverflow(by: 4)
        let (width, b) = floats.addingReportingOverflow(32)
        let (bytes, c) = Int64(rows).multipliedReportingOverflow(by: width)
        return a || b || c ? nil : bytes
    }
    mutating func reserve(_ bytes: Int64) -> Bool {
        guard bytes > 0, bytes <= limit, resident <= limit - bytes,
              reserved <= limit - bytes - resident else { return false }
        reserved += bytes; return true
    }
    mutating func commit(_ bytes: Int64) { precondition(reserved >= bytes); reserved -= bytes; resident += bytes }
    mutating func abandon(_ bytes: Int64) { precondition(reserved >= bytes); reserved -= bytes }
    mutating func dropResident(_ bytes: Int64) { precondition(resident >= bytes); resident -= bytes }
}
```

```csharp
internal sealed class MatrixBudget(long limit)
{
    internal long Resident { get; private set; }
    internal long Reserved { get; private set; }
    internal static long? Charge(int rows,int dims)
    {
        if(rows<=0 || dims<=0) return null;
        try { return checked((long)rows*(checked((long)dims*4)+32)); }
        catch(OverflowException) { return null; }
    }
    internal bool Reserve(long bytes)
    {
        if(bytes<=0 || bytes>limit || Resident>limit-bytes || Reserved>limit-bytes-Resident) return false;
        Reserved+=bytes; return true;
    }
    internal void Commit(long bytes)
    { if(Reserved<bytes) throw new InvalidOperationException(); Reserved-=bytes; Resident+=bytes; }
    internal void Abandon(long bytes)
    { if(Reserved<bytes) throw new InvalidOperationException(); Reserved-=bytes; }
    internal void DropResident(long bytes)
    { if(Resident<bytes) throw new InvalidOperationException(); Resident-=bytes; }
}
```

Cache transition table (execute each mutation atomically under actor/gate):

| Event | Transition and returned value |
|---|---|
| Acquire ready key, current epoch | Increment lease count and monotonic touch tick; return immutable lease. |
| Acquire loading key | Add waiter registration to that fill; await outside the gate. |
| Acquire new key | Checked charge; evict oldest zero-lease entries until reserve succeeds. If none can free enough, return nil without invoking fill. Allocate builder only after reservation. |
| Fill succeeds, epoch agrees, ≥1 waiter | Commit reservation, insert immutable entry, grant one lease per uncancelled waiter atomically; then complete waiters outside gate. |
| Fill succeeds, epoch changed | Abandon reservation; release operation borrow; finish waiters with nil so they stream their pinned generation. |
| Fill fails | Abandon reservation exactly once; release borrow; propagate same failure to all remaining waiters. |
| One waiter cancels | Remove only that waiter; if no waiter remains cancel fill, which owns reservation until its completion handler refunds it. |
| Invalidate DB | Remove ready entries from lookup; free zero-lease payloads immediately, keep leased payloads charged in retired entries. Mark loading slots invalidated; they may not publish. |
| Release lease | Decrement once; if invalidated and count becomes0, free slab/columns and drop resident charge; otherwise retain for LRU. |

Staging row capacity cannot exceed reserved capacity. Reject a fill that appends too many rows instead of reallocating. The array test overload uses exactly the same builder/admission path. Treat its known rows as one bounded test page. `statistics` and `residentKeys` cannot keep matrices alive by returning their buffers.

## Task 6: [Swift] Integer fusion and masked SIMD heap

**Depends on:** Tasks1,4. **Parallel with:** 2,3,7–11 as their prerequisites permit.

**Files:** `Sources/AINotebookCore/RetrievalRanking.swift`, `Tests/AINotebookCoreTests/RetrievalRankingTests.swift` only.

**Interfaces — Consumes:** `ChunkReference`, `VectorRow`, `RetrievalCacheKey`, epoch function from4; Swift `RagContractV1.Cache.globalBudgetBytes`. C# equivalents defined above. **Produces:** Swift `RetrievalRanking` signatures and internal `MaskedVectorTopK` below; matching C# signatures frozen above.

- [ ] **Step 1: Add red fixture tests.**

```swift
import XCTest
@testable import AINotebookCore

final class RetrievalRankingTests: XCTestCase {
    func testIntegerRRFSharedCases() throws {
        let file = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        for c in file["cases"] as! [[String: Any]] where c["lexical"] != nil {
            func refs(_ key: String) -> [ChunkReference] {
                (c[key] as! [NSNumber]).map { .init(chunkId: $0.int64Value, sourceId: 1, revisionId: 1, ord: 0) }
            }
            let actual = try RetrievalRanking.fuse(lexical: refs("lexical"), vector: refs("vector"))
            let expected = c["expected"] as! [[String: NSNumber]]
            XCTAssertEqual(actual.map { $0.reference.chunkId }, expected.map { $0["chunkId"]!.int64Value })
            XCTAssertEqual(actual.map(\.rrfMicro), expected.map { $0["rrfMicro"]!.int64Value })
        }
    }
    func testMaskBeforeHeapSharedCase() throws {
        let file = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        let c = (file["cases"] as! [[String:Any]]).first { $0["name"] as? String == "mask-before-heap" }!
        let input = c["rows"] as! [[String:Any]]
        let rows = input.map { r in VectorRow(reference: .init(chunkId: (r["chunkId"] as! NSNumber).int64Value,
            sourceId: (r["sourceId"] as! NSNumber).int64Value, revisionId: (r["revisionId"] as! NSNumber).int64Value, ord: r["ord"] as! Int), values: (r["vector"] as! [NSNumber]).map(\.floatValue)) }
        let eligible = Set(input.filter { ($0["eligible"] as! Int) == 1 }.map { ($0["sourceId"] as! NSNumber).int64Value })
        let found = RetrievalRanking.topK(rows: rows, query: (c["query"] as! [NSNumber]).map(\.floatValue), permittedSources: eligible, k: c["k"] as! Int)
        XCTAssertEqual(found.map { $0.reference.chunkId }, (c["expectedIds"] as! [NSNumber]).map(\.int64Value))
    }
}
```

Run `swift test --filter RetrievalRankingTests` → missing ranking FAIL. Implement the fusion kernel exactly:

```swift
public static func fuse(lexical: [ChunkReference], vector: [ChunkReference], rrfK: Int = 60) throws -> [RankedChunk] {
    guard rrfK > 0 else { throw RetrievalError.invalidFetchK }
    var scores: [Int64: Int64] = [:], refs: [Int64: ChunkReference] = [:]
    for branch in [lexical, vector] {
        var seen = Set<Int64>(), rank = 0
        for ref in branch {
            if let previous = refs[ref.chunkId], previous != ref { throw RetrievalError.revisionMismatch }
            guard seen.insert(ref.chunkId).inserted else { continue }
            rank += 1
            refs[ref.chunkId] = ref
            scores[ref.chunkId, default: 0] += 1_000_000 / Int64(rrfK + rank)
        }
    }
    return scores.map { RankedChunk(reference: refs[$0.key]!, rrfMicro: $0.value) }
        .sorted { $0.rrfMicro == $1.rrfMicro ? $0.reference.chunkId < $1.reference.chunkId : $0.rrfMicro > $1.rrfMicro }
}
```

The public fusion method throws `revisionMismatch` for conflicting metadata even for a duplicate within one branch; no production precondition traps are used for database content. `ChunkReference` conforms to Equatable/Hashable on Swift and is a value record on C#.

- [ ] **Step 2: Implement the masked heap kernel in this plan, then add `testHeapFixtureCases` and `testSIMDDotWithinTolerance`.** Loop every vector fixture, including input permutations, k0, k>N, invalid rows and query dimensions. Assert ordered IDs and1e-6 scores. Compare normalized [3,4] versus[4,3] with the fixture's960000 score micro-units. Only the ≤k retained rows are sorted.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter RetrievalRankingTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/RetrievalRanking.swift Tests/AINotebookCoreTests/RetrievalRankingTests.swift
git commit -m "feat(retrieval): integer RRF and masked Swift SIMD heap" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four ranking methods green, every rank fixture consumed, both full suites green.

## Task 6a: [Swift] Leased global cache and bounded admission

**Depends on:** Tasks1,4,6. **Parallel with:** 3,7,7a,8,9,10,11 as their prerequisites permit.

**Files:** `Sources/AINotebookCore/VectorMatrixCache.swift`, `Tests/AINotebookCoreTests/VectorMatrixCacheTests.swift` only.

**Interfaces — Consumes:** Swift `MaskedVectorTopK`, `RetrievalOperation`, `RawVectorPage` and cache DTOs; C# peers `MaskedVectorTopK.Create/Offer/Sorted`, operation and raw page records. **Produces:** Swift cache, builder and lease signatures in the ranking/cache contract; C# equivalents `AcquireAsync`, `Append`, `TopK`, `Dispose` remain Task7a-owned.

- [ ] **Step 1: Add cache red test and implement state transitions.**

```swift
final class VectorMatrixCacheTests: XCTestCase {
    func testLeasedBytesRemainCharged() async throws {
        let f = try SharedFixtures.json("contracts/retrieval-cache-v1.json")
        let cache = VectorMatrixCache(budgetBytes: Int64(f["budgetBytes"] as! Int))
        let rows = (1...2).map { i in VectorRow(reference: .init(chunkId: Int64(i), sourceId: 1, revisionId: 1, ord: i-1), values: [1,0]) }
        func key(_ id: Int64) -> RetrievalCacheKey { .init(databaseId: "db", notebookId: id, generationId: 90, epoch: 0) }
        let first = try await cache.acquire(key: key(1), rowCount: 2, dims: 2, epoch: { 0 }, load: { rows })
        let second = try await cache.acquire(key: key(2), rowCount: 2, dims: 2, epoch: { 0 }, load: { rows })
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        await cache.invalidate(databaseId: "db")
        let blocked = try await cache.acquire(key: key(3), rowCount: 2, dims: 2, epoch: { 0 }, load: { rows })
        XCTAssertNil(blocked)
        let held = await cache.statistics()
        XCTAssertEqual(held.residentBytes, 160)
        await first?.close(); await second?.close()
        let released = await cache.statistics()
        XCTAssertEqual(released.residentBytes, 0)
    }
}
```

Run `swift test --filter VectorMatrixCacheTests` → missing cache FAIL. Implement the cache algorithm above. `VectorMatrixLease.close` uses a lock-protected flag so duplicate closes release once; a deinit schedules a best-effort actor release, but all production paths explicitly close. Cache does not retain leases. Matrix Float32 slab uses `ContiguousArray<Float>` or one allocated buffer, and Int64 columns; avoid Swift copy-on-write clones by exposing pointer scopes only.

- [ ] **Step 2: Add shared-case regressions.** `testCacheCaseTable` executes all seven action sequences and compares keys/resident/reserved/load counts after every action. `testFillCancellationAndSingleFlight` uses actor barriers, two waiters, one cancellation and one successful lease; assert one fill and budget release after last close. `testStreamingAndCachedRankingAgree` uses the same shared rows at budget0 and160 and compares ordered IDs/scores. No sleeps or latency thresholds.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter VectorMatrixCacheTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/VectorMatrixCache.swift Tests/AINotebookCoreTests/VectorMatrixCacheTests.swift
git commit -m "feat(retrieval): leased Swift vector matrix LRU" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four cache methods green; all shared cases run; complete Swift suite green.

## Task 7: [Windows] Integer fusion and Tensors heap

**Depends on:** Tasks1,5; WP4 Task3 and all WP2 project/lock changes merged. **Parallel with:** 2,3,6,8–11 as their prerequisites permit. App lock updates are owned only here.

**Files:** `windows/src/AINotebook.Core/Rag/RetrievalRanking.cs`, `windows/tests/AINotebook.Core.Tests/Rag/RetrievalRankingTests.cs`, Core csproj and four lockfiles in Task7's table row.

**Interfaces — Consumes:** storage DTOs, epochs, `RagContractV1.Cache.GlobalBudgetBytes`; Swift peers in ranking/cache contract. **Produces:** C# RetrievalRanking and internal MaskedVectorTopK signatures above; Swift peer signatures are fixed above. Pin `System.Numerics.Tensors` to **9.0.0**, already present in App's graph; use `TensorPrimitives.Dot<float>(ReadOnlySpan<float>,ReadOnlySpan<float>)`.

- [ ] **Step 1: Write red ranking Facts.**

```csharp
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

public sealed class RetrievalRankingTests
{
    [Fact]
    public void IntegerRrfSharedCases()
    {
        foreach (var c in SharedFixtures.Json("contracts/retrieval-rank-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("lexical", out _)) continue;
            ChunkReference[] Refs(string key) => c.GetProperty(key).EnumerateArray()
                .Select(x => new ChunkReference(x.GetInt64(),1,1,0)).ToArray();
            var actual = RetrievalRanking.Fuse(Refs("lexical"), Refs("vector"));
            var expected = c.GetProperty("expected").EnumerateArray().ToArray();
            Assert.Equal(expected.Select(x => x.GetProperty("chunkId").GetInt64()), actual.Select(x => x.Reference.ChunkId));
            Assert.Equal(expected.Select(x => x.GetProperty("rrfMicro").GetInt64()), actual.Select(x => x.RrfMicro));
        }
    }
}

```

`dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~RetrievalRankingTests` → missing types FAIL. Add a second ranking Fact that loops all `rows` cases and compares expected IDs with `TopK`; decode shared `eligible` flags before calling it.

- [ ] **Step 2: Implement fusion and the supplied masked SIMD heap.** Fusion kernel:

```csharp
public static IReadOnlyList<RankedChunk> Fuse(IReadOnlyList<ChunkReference> lexical,
    IReadOnlyList<ChunkReference> vector,int rrfK=60)
{
    ArgumentOutOfRangeException.ThrowIfNegativeOrZero(rrfK);
    var scores = new Dictionary<long,long>();
    var references = new Dictionary<long,ChunkReference>();
    foreach (var branch in new[] {lexical,vector})
    {
        var seen = new HashSet<long>(); int rank=0;
        foreach (var reference in branch)
        {
            if (references.TryGetValue(reference.ChunkId,out var previous) && previous != reference)
                throw new RetrievalException("revisionMismatch");
            if (!seen.Add(reference.ChunkId)) continue;
            rank++;
            references[reference.ChunkId]=reference;
            scores[reference.ChunkId]=scores.GetValueOrDefault(reference.ChunkId)+1_000_000L/(rrfK+rank);
        }
    }
    return scores.Select(x=>new RankedChunk(references[x.Key],x.Value))
        .OrderByDescending(x=>x.RrfMicro).ThenBy(x=>x.Reference.ChunkId).ToArray();
}
```

For heap use `PriorityQueue<ScoredChunk,(float Score,long ReverseId)>` with priority `(score,-chunkId)`; IDs are nonnegative JSON-safe so negation cannot overflow. Peek is the worst. Insert only masked rows; final sort is ≤k. Dot kernel reads `matrix.AsSpan(row*dims,dims)` without allocation. Normalize finite rows with Double norm; query normalization once. Slab plus metadata arrays are immutable after fill.

Add `<PackageReference Include="System.Numerics.Tensors" Version="9.0.0" />` to Core. Regenerate lockfiles through restore; do not handwrite content hashes or upgrade unrelated packages. Restore App graphs on Windows if platform targets prevent macOS restore.

- [ ] **Step 3: Add `HeapFixtureCases` and `SimdDotWithinTolerance`.** Read every shared vector row, including k0/k>N and input permutations, and compare expected IDs and scores within1e-6. [3,4] and[4,3] after normalization yield0.96; malformed/nonfinite rows are skipped and a zero query yields no vector result. Record invalid-row counts separately from heap output.

- [ ] **Step 4: Green, locked restore and commit.**

```bash
dotnet restore windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~RetrievalRankingTests
dotnet test windows/tests/AINotebook.Core.Tests
```

On Windows, before committing the lock graph:

```powershell
dotnet restore windows/src/AINotebook.App/AINotebook.App.csproj -p:Platform=x64
dotnet restore windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -p:Platform=x64
dotnet restore windows/AINotebook.sln --locked-mode -p:Platform=x64
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
```

```bash
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Rag/RetrievalRanking.cs windows/tests/AINotebook.Core.Tests/Rag/RetrievalRankingTests.cs windows/src/AINotebook.Core/AINotebook.Core.csproj windows/src/AINotebook.Core/packages.lock.json windows/tests/AINotebook.Core.Tests/packages.lock.json windows/src/AINotebook.App/packages.lock.json windows/tests/AINotebook.App.Tests/packages.lock.json
git commit -m "feat(win-retrieval): integer RRF and masked Tensors heap" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four ranking Facts and Core suite green, locked restore succeeds, Windows App build/tests green. A macOS worker hands off the concrete lockfile diff for Windows verification; the task is not gate-complete until that verification exists.

## Task 7a: [Windows] Leased global matrix cache

**Depends on:** Tasks1,5,7. **Parallel with:** 2,6,6a,8,9,10,11 as their prerequisites permit.

**Files:** new `windows/src/AINotebook.Core/Rag/VectorMatrixCache.cs`, `windows/tests/AINotebook.Core.Tests/Rag/VectorMatrixCacheTests.cs` only.

**Interfaces — Consumes:** C# `MaskedVectorTopK`, `RetrievalOperation`, raw page and cache DTOs; Swift `MaskedVectorTopK.init/offer/sorted`, operation and raw page equivalents. **Produces:** C# cache/builder/lease signatures in the contract above; Swift actor/builder/lease equivalents belong to Task6a.

- [ ] **Step 1: Add the red cache Fact.** Imports: `AINotebook.Core.Rag`, `AINotebook.Core.Storage`, `AINotebook.Core.Tests.Helpers`, `Xunit`; namespace `AINotebook.Core.Tests.Rag`.

```csharp
public sealed class VectorMatrixCacheTests
{
    [Fact]
    public async Task LeasedBytesRemainCharged()
    {
        var f = SharedFixtures.Json("contracts/retrieval-cache-v1.json");
        var cache = new VectorMatrixCache(f.GetProperty("budgetBytes").GetInt64());
        IReadOnlyList<VectorRow> rows = new[] { new VectorRow(new(1,1,1,0),[1,0]), new VectorRow(new(2,1,1,1),[1,0]) };
        RetrievalCacheKey Key(long n) => new("db", n, 90, 0);
        var first = await cache.AcquireAsync(Key(1),2,2,()=>0,_=>Task.FromResult(rows));
        var second = await cache.AcquireAsync(Key(2),2,2,()=>0,_=>Task.FromResult(rows));
        Assert.NotNull(first); Assert.NotNull(second);
        cache.Invalidate("db");
        using var blocked = await cache.AcquireAsync(Key(3),2,2,()=>0,_=>Task.FromResult(rows));
        Assert.Null(blocked);
        Assert.Equal(160,cache.Statistics().ResidentBytes);
        first.Dispose(); second.Dispose();
        Assert.Equal(0,cache.Statistics().ResidentBytes);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~VectorMatrixCacheTests` → missing cache FAIL.

- [ ] **Step 2: Implement the admission ledger and async state transitions specified above.** The private memory gate covers dictionaries/accounting only, never a fill, SQL, await or dot product. Builder writes one slab and four Int64 columns. `Dispose` uses Interlocked.Exchange to release exactly once. Production fills use pages; the array overload stays internal. Single-flight fill retains its own operation borrow, so the initiating query can cancel while another waiter finishes. Use TaskCompletionSource with RunContinuationsAsynchronously for each in-flight entry; waiter cancellation uses `WaitAsync(ct)` and decrements only that waiter's registration. Cancel fill only when no waiter remains.

- [ ] **Step 3: Add `CacheCaseTable`, `FillCancellationAndSingleFlight`, `StreamingAndCachedRankingAgree`.** Execute every shared cache action and compare resident/reserved/load counts and sorted resident keys after each action. Pause a fill with TaskCompletionSource, start two waiters, cancel one, complete the other, assert exactly one load and one surviving lease. Budgets0 and160 must yield identical ordered IDs using the same rank fixture; final disposal releases invalidated bytes. No sleeps or latency assertions.

- [ ] **Step 4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~VectorMatrixCacheTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Rag/VectorMatrixCache.cs windows/tests/AINotebook.Core.Tests/Rag/VectorMatrixCacheTests.cs
git commit -m "feat(win-retrieval): leased global vector matrix cache" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four cache Facts green, all shared action sequences consumed, both full suites green.

## Task 8: [Swift] Hydrate pinned evidence, published neighbours and GC retention

**Depends on:** Tasks1,4. **Parallel with:** 2,3,6,7,9,10,11.

**Files:** the two Task8 files only.

**Interfaces — Consumes:** `RetrievalReadStore.evidenceRows/neighbourReferences`, lease and `ChunkReference`; WP3 GC. C# peer reader APIs are fixed above. **Produces:** Swift `EvidenceHydrator.init(reader:RetrievalReadStore)`, `hydrate(_ snapshot:ResolvedRetrievalScope,references:[ChunkReference],neighborRadius:Int=1) async throws -> [EvidencePassage]`, `static passage(_ row:ChunkEvidenceRow,isNeighbour:Bool) throws -> EvidencePassage`; C# peer `EvidenceHydrator(RetrievalReadStore)`, `IReadOnlyList<EvidencePassage> Hydrate(ResolvedRetrievalScope,IReadOnlyList<ChunkReference>,int neighborRadius=1)`, `static EvidencePassage Passage(ChunkEvidenceRow,bool)`. Direct passage order follows input; neighbours follow centers in input order and ord/chunkId order, deduplicated by chunkId, excluding already direct hits. No merging or truncation of evidence.

- [ ] **Step 1: Add red scalar hydration test.**

```swift
import XCTest
@testable import AINotebookCore

final class EvidenceHydratorTests: XCTestCase {
    func testScalarEvidenceFixture() throws {
        let f = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
        let canonical = f["canonicalText"] as! String
        for c in f["cases"] as! [[String:Any]] where c["row"] != nil {
            let r = c["row"] as! [String:Any]
            let row = ChunkEvidenceRow(reference: .init(chunkId: 1020, sourceId: 1, revisionId: 102, ord: 0),
                canonicalText: r["canonicalText"] as? String ?? canonical,
                chunkText: r["chunkText"] as! String, charStart: r["start"] as? Int,
                charEnd: r["end"] as? Int, pageHint: r["pageHint"] as? Int,
                chunkerVersion: r["chunkerVersion"] as! Int)
            if c["expectedError"] != nil {
                XCTAssertThrowsError(try EvidenceHydrator.passage(row, isNeighbour: false))
            } else {
                let evidence = try EvidenceHydrator.passage(row, isNeighbour: false)
                XCTAssertEqual(evidence.text, c["expectedText"] as? String)
                XCTAssertEqual(evidence.displaySnippet, c["expectedSnippet"] as? String)
            }
        }
    }
}
```

Run `swift test --filter EvidenceHydratorTests` → missing hydrator FAIL. Implement the pure conversion:

```swift
public static func passage(_ row: ChunkEvidenceRow, isNeighbour: Bool) throws -> EvidencePassage {
    let text: String
    let spans: [CitationSpan]
    if row.chunkerVersion == 1 && row.charStart == nil && row.charEnd == nil {
        text = row.chunkText; spans = []
    } else {
        let scalars = Array(row.canonicalText.unicodeScalars)
        guard let start = row.charStart, let end = row.charEnd,
              start >= 0, end > start, end <= scalars.count else { throw RetrievalError.invalidSpan }
        text = String(String.UnicodeScalarView(scalars[start..<end]))
        spans = [CitationSpan(start: start, end: end, pageFrom: row.pageHint, pageTo: row.pageHint)]
    }
    let snippet = String(String.UnicodeScalarView(text.unicodeScalars.prefix(240)))
    return EvidencePassage(reference: row.reference, text: text, displaySnippet: snippet, spans: spans, isNeighbour: isNeighbour)
}
```

Page hints only claim the stored hint. WP3 has no multi-page boundary table; never fabricate page ranges from scalar offsets. WP6 can extend stored span metadata. Legacy text stays whole and has no mergeable spans.

- [ ] **Step 2: Implement batch hydration.** Reject radius<0 as invalidRadius. Borrow the snapshot for the whole operation. Resolve direct rows with explicit references, validate all requested identities before emitting anything, skip revoked sources, and get published neighbour references with ±radius. A neighbour of an old manifest hit can carry the newer published revision; keep it separate. Group row fetches by revision so a large canonical text is decoded once per revision in a call; avoid N copies of canonical text for N chunks. Hydrate only requested direct references and bounded neighbours, never every candidate's full revision. Full text and displaySnippet are separate fields, no prefix240 in the evidence path.

- [ ] **Step 3: Add database/GC regression methods.** `testPublishedNeighboursRetainTheirOwnRevision` consumes published-neighbours and old-vector and compares `(chunkId,revisionId,isNeighbour)` tuples. `testWrongRevisionFails` requests1020/101 and expects revisionMismatch. `testRevokedSourceReturnsNoEvidence` pins then marks missing, expects[]. `testQueryPinProtectsRetiredEvidenceUntilClose` pins101, publishes102/retires90, invokes GC, hydrates101 successfully, closes, invokes GC and verifies generation90/revision101/chunk1010/vector1010 are gone but published102 survives. `testCloseDuringHydrationKeepsOperationBorrow` pauses reader after borrow, closes pool and GC from second store, resumes and verifies text, then sees collection after borrow release. Use continuations/barriers, not sleep.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter EvidenceHydratorTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/EvidenceHydrator.swift Tests/AINotebookCoreTests/EvidenceHydratorTests.swift
git commit -m "feat(retrieval): full pinned Swift evidence and published neighbours" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: six methods green; full suite green. No changes to WP3 deletion SQL or WP8 packer.

## Task 9: [Windows] Full evidence hydration and pin-aware GC regressions

**Depends on:** Tasks1,5. **Parallel with:** 2,3,6,7,8,10,11.

**Files:** the two Task9 files only.

**Interfaces — Consumes:** `RetrievalReadStore`, `ChunkEvidenceRow`, `QueryPin`, WP3 `GarbageCollect`; Swift counterparts above. **Produces:** `EvidenceHydrator(RetrievalReadStore)`, `Hydrate(ResolvedRetrievalScope,IReadOnlyList<ChunkReference>,int=1)`, `Passage(ChunkEvidenceRow,bool)`; Swift peer `hydrate(_:references:neighborRadius:)` and `passage(_:isNeighbour:)`.

- [ ] **Step 1: Add the red scalar test.**

```csharp
using System.Text;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

public sealed class EvidenceHydratorTests
{
    [Fact]
    public void ScalarEvidenceFixture()
    {
        var f = SharedFixtures.Json("contracts/retrieval-evidence-v1.json");
        foreach (var c in f.GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("row",out var r)) continue;
            int? Optional(string key) => r.TryGetProperty(key,out var x) && x.ValueKind != System.Text.Json.JsonValueKind.Null ? x.GetInt32() : null;
            var row = new ChunkEvidenceRow(new(1020,1,102,0),
                r.TryGetProperty("canonicalText",out var text) ? text.GetString()! : f.GetProperty("canonicalText").GetString()!,
                r.GetProperty("chunkText").GetString()!,Optional("start"),Optional("end"),Optional("pageHint"),r.GetProperty("chunkerVersion").GetInt32());
            if (c.TryGetProperty("expectedError",out var error))
                Assert.Equal(error.GetString(),Assert.Throws<RetrievalException>(()=>EvidenceHydrator.Passage(row,false)).Code);
            else
            {
                var evidence=EvidenceHydrator.Passage(row,false);
                Assert.Equal(c.GetProperty("expectedText").GetString(),evidence.Text);
                Assert.Equal(c.GetProperty("expectedSnippet").GetString(),evidence.DisplaySnippet);
            }
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvidenceHydratorTests` → missing class FAIL.

- [ ] **Step 2: Implement the scalar converter and batch reader.**

```csharp
public static EvidencePassage Passage(ChunkEvidenceRow row,bool isNeighbour)
{
    string text;
    IReadOnlyList<CitationSpan> spans;
    if (row.ChunkerVersion==1 && row.CharStart is null && row.CharEnd is null)
    { text=row.ChunkText; spans=Array.Empty<CitationSpan>(); }
    else
    {
        var scalars=row.CanonicalText.EnumerateRunes().ToArray();
        if (row.CharStart is not int start || row.CharEnd is not int end || start<0 || end<=start || end>scalars.Length)
            throw new RetrievalException("invalidSpan");
        text=string.Concat(scalars.Skip(start).Take(end-start).Select(x=>x.ToString()));
        spans=new[] {new CitationSpan(start,end,row.PageHint,row.PageHint)};
    }
    string snippet=string.Concat(text.EnumerateRunes().Take(240).Select(x=>x.ToString()));
    return new(row.Reference,text,snippet,spans,isNeighbour);
}
```

Import `AINotebook.Core.Models` for CitationSpan. The batch method validates radius, takes an operation borrow, deduplicates references, groups by revision, materializes rows under `_gate`, then slices outside the lock. Wrong revision throws; revoked sources return no evidence. Published neighbours keep their own revision and are candidates, not automatically appended to a prompt. Validate all identities before returning any partial successful list.

- [ ] **Step 3: Add five regression Facts.** `PublishedNeighboursRetainTheirOwnRevision`, `WrongRevisionFails`, `RevokedSourceReturnsNoEvidence`, `QueryPinProtectsRetiredEvidenceUntilDispose`, `DisposeDuringHydrationKeepsOperationBorrow` implement the shared old-vector/wrong-revision/revoked/gc-pin cases. The last Fact uses TaskCompletionSource barriers and a second store's GC; all direct SQL assertions are under the corresponding gate. Verify exact retained/deleted IDs, not only zero errors. Verify a241-emoji evidence passage remains241 runes while snippet is240.

- [ ] **Step 4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvidenceHydratorTests
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/EvidenceHydrator.cs windows/tests/AINotebook.Core.Tests/Rag/EvidenceHydratorTests.cs
git commit -m "feat(win-retrieval): pinned full evidence published neighbours and GC retention" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: six Facts green, entire Core suite green.

## Embedding session contract for Tasks 10 and 11

WP2 exposes immutable **chat** sessions, not embedding sessions. Add this retrieval-specific companion without changing its chat API. WP3 `endpoint_revision` is an opaque string; this plan defines a deterministic creator shared with future WP6 generation builders: `endpoint-v1:` plus lowercase SHA256 of provider type storage value, a zero byte and WP2-normalized API root. Credentials are excluded, so key rotation does not demand re-embedding. A changed root/type does. Never send a query to a mismatched root just to test whether it works.

```swift
public protocol EmbeddingSessionPreparing: Sendable {
    func prepareEmbedding(identity: GenerationIdentity) async throws -> ProviderEmbeddingSession
}
public struct ProviderEmbeddingSession: Sendable {
    public let storageKey: String
    public let endpointRevision: String
    public func embed(inputs: [String]) async throws -> [[Float]]
}
public enum EmbeddingEndpointRevision {
    public static func make(type: ProviderType, normalizedRoot: String) -> String
}
```

```csharp
public interface IEmbeddingSessionPreparing
{
    Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity,CancellationToken ct=default);
}
public sealed class ProviderEmbeddingSession
{
    public string StorageKey { get; }
    public string EndpointRevision { get; }
    public Task<float[][]> EmbedAsync(IReadOnlyList<string> inputs,CancellationToken ct=default);
}
public static string EmbeddingEndpointRevision.Make(ProviderType type,string normalizedRoot);
```

A session owns the captured embedding adapter and raw model ID privately. For normal identity use its explicit providerId/model, **not current selected chat/embedding settings**. Normalize/capture config and key once before suspension, enforce existing remote privacy gate, verify identity endpointRevision, then return a session whose embed uses that adapter. Only queryFormatVersion `legacy` and `1` are implemented as identity input format; reject other versions before any request. WP7 adds named model-specific formats and fixtures jointly with generation creation, not inferred prefix rules here.

Legacy generations preserve a whole model key and have no provable historical endpoint. A recognized provider prefix is split only at the first colon; the remaining tagged raw model stays byte-for-byte unchanged. A bare key uses the selected embedding provider captured once, but preserves the stored model rather than substituting the selected model. An unrecognized colon prefix fails as `legacyProviderUnresolved` (lexical only), since it cannot distinguish a removed provider from a bare model tag. Capture today's configured adapter once; expose `legacyEndpointUnverified` in retrieval diagnostics. Unknown provider or unsupported capability yields lexical-only diagnostics, never a different provider. Direct injected non-router clients are supported only for legacy identities, retaining the captured whole model key; a modern identity without the session interface yields `embeddingSessionRequired`. Record this legacy policy for Claude's merge review; workers implement it as specified and do not request a new permission to start.

The immutable session implementations belong in the named new Providers files. Their constructors are internal: only a validated captured adapter reaches them. Existing adapters implement EmbeddingProducing/IEmbeddingProducing; the returned session stores the raw model separately from its qualified storage key.

```swift
public struct ProviderEmbeddingSession: Sendable {
    public let storageKey: String
    public let endpointRevision: String
    private let client: any EmbeddingProducing
    private let model: String
    internal init(client: any EmbeddingProducing, model: String,
                  storageKey: String, endpointRevision: String) {
        self.client=client; self.model=model
        self.storageKey=storageKey; self.endpointRevision=endpointRevision
    }
    public func embed(inputs: [String]) async throws -> [[Float]] {
        try await client.embed(model:model,inputs:inputs)
    }
}
```

```csharp
using AINotebook.Core.Ollama;
namespace AINotebook.Core.Providers;
public sealed class ProviderEmbeddingSession
{
    public string StorageKey { get; }
    public string EndpointRevision { get; }
    private readonly IEmbeddingProducing _client;
    private readonly string _model;
    internal ProviderEmbeddingSession(IEmbeddingProducing client,string model,string storageKey,string endpointRevision)
    { _client=client; _model=model; StorageKey=storageKey; EndpointRevision=endpointRevision; }
    public Task<float[][]> EmbedAsync(IReadOnlyList<string> inputs,CancellationToken ct=default)
        => _client.EmbedAsync(_model,inputs,ct);
}
```

Modern session preparation uses identity.providerId to read WP2's provider config, preserves identity.model as raw model, normalizes using `ProviderAPIRoot.normalize(_:)` / `ProviderApiRoot.Normalize(string)`, validates consent/capability and checks endpoint revision **before constructing a request**. A modern storageKey is providerId+":"+rawModel; a legacy key follows the explicit rule above. No adapter receives a mutable settings reference. Swift capture uses one MainActor.run closure (current router is a Sendable class, not an actor at `ProviderRouter.swift:23`); Windows snapshots config and key before consulting its WP2 synchronized adapter dictionary. Endpoint fingerprint excludes the secret; adapter cache identity still includes WP2's secret fingerprint. These are different purposes.

## Task 10: [Swift] Capture immutable embedding sessions

**Depends on:** Task1; WP2 provider/router final integration and WP3 GenerationIdentity merged. **Parallel with:** 2–9,11.

**Files:** three Task10 paths only. Existing router config/adapter logic is `Sources/AINotebookCore/Providers/ProviderRouter.swift`; build on the merged WP2 version rather than restoring the old file.

**Interfaces — Consumes:** WP2 normalized API root, `ProviderConfig`, privacy check and captured adapter factory; `EmbeddingProducing.embed(model:inputs:)`. C# peer `IEmbeddingProducing.EmbedAsync`. **Produces:** Swift session signatures above; C# peer signatures fixed there. Add router conformance to EmbeddingSessionPreparing.

- [ ] **Step 1: Write red endpoint identity test.**

```swift
import XCTest
@testable import AINotebookCore

final class ProviderEmbeddingSessionTests: XCTestCase {
    func testEndpointIdentityFixture() throws {
        let f = try SharedFixtures.json("contracts/retrieval-session-v1.json")
        for c in f["cases"] as! [[String:Any]] where c["expectedEndpointRevision"] != nil {
            let type = try XCTUnwrap(ProviderType(rawValue: c["type"] as! String))
            XCTAssertEqual(EmbeddingEndpointRevision.make(type: type, normalizedRoot: c["normalizedRoot"] as! String), c["expectedEndpointRevision"] as? String)
        }
    }
}
```

Run `swift test --filter ProviderEmbeddingSessionTests` → missing helper FAIL. Implement with CryptoKit:

```swift
public static func make(type: ProviderType, normalizedRoot: String) -> String {
    let bytes = Array(type.rawValue.utf8) + [UInt8(0)] + Array(normalizedRoot.utf8)
    return "endpoint-v1:" + SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}
```

Add this session test to the same file (imports also include Foundation). The local selection class is mutable only on this test's MainActor; the router captures its values before returning the session. Existing `InMemorySecretStore`, `MockURLProtocol`, `makeMockSession`, `httpResponse`, and URLRequest.bodyData come from the current provider test helpers (`ProviderRouterTests.swift:8–30,89`).

```swift
@MainActor
func testCapturedRootKeyAndModelSurviveSettingsMutation() async throws {
    final class Selection: ProviderSelectionReading, @unchecked Sendable {
        var value: (String,String)
        init(_ value: (String,String)) { self.value=value }
        func chatSelection() -> (providerId:String,model:String) { value }
        func embeddingSelection() -> (providerId:String,model:String) { value }
    }
    let rows = try SharedFixtures.json("contracts/retrieval-session-v1.json")["cases"] as! [[String:Any]]
    let c = rows.first { $0["name"] as? String == "key-rotation" }!
    let moved = rows.first { $0["name"] as? String == "root-change" }!
    let store = try NotebookStore(path:.inMemory)
    let id=c["providerId"] as! String, root=c["oldRoot"] as! String, model=c["rawModel"] as! String
    var config=ProviderConfig(id:id,type:.openaiCompatible,name:"P",baseURL:root,privacyAcknowledged:true)
    try store.saveProvider(config)
    let secrets=InMemorySecretStore()
    try secrets.save(providerId:id,secret:c["oldKey"] as! String)
    let selection=Selection((id,model))
    let router=ProviderRouter(store:store,secrets:secrets,selection:selection,session:makeMockSession())
    let identity=GenerationIdentity(providerId:id,endpointRevision:EmbeddingEndpointRevision.make(type:config.type,normalizedRoot:root),
        model:model,modelDigest:nil,dims:2,normalization:"l2",queryFormatVersion:"1",docFormatVersion:"1",chunkerVersion:"2")
    let session=try await router.prepareEmbedding(identity:identity)
    config.baseURL=moved["newRoot"] as! String
    try store.saveProvider(config)
    try secrets.save(providerId:id,secret:c["newKey"] as! String)
    selection.value=(id,c["newModel"] as! String)
    nonisolated(unsafe) var captured: URLRequest?
    MockURLProtocol.handler = { request in
        captured=request
        return (httpResponse(request.url!,status:200),Data(#"{"data":[{"embedding":[1,0]}]}"#.utf8))
    }
    defer { MockURLProtocol.handler=nil }
    _ = try await session.embed(inputs:["Q"])
    let request=try XCTUnwrap(captured)
    XCTAssertEqual(request.url?.absoluteString,root+"/embeddings")
    XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer " + (c["oldKey"] as! String))
    let body=try JSONSerialization.jsonObject(with:XCTUnwrap(request.bodyData)) as! [String:Any]
    XCTAssertEqual(body["model"] as? String,model)
}
```

- [ ] **Step 2: Add red session isolation tests before router changes.** `testCapturedRootKeyAndModelSurviveSettingsMutation` uses the real WP2 router and MockURLProtocol capture and shared key-rotation/legacy cases: prepare session with provider-a and keya, mutate config/key/model, embed, assert captured request URL, authorization and raw model. `testMismatchedEndpointAndChatOnlySendNothing` loops root-change and both chat-only cases, verifies error code and request count0. `testFormatsAndModelTags` checks query text unchanged for legacy/1, `qwen3:0.6b` remains intact, format99 errors without request. `testPrivacyGateRunsBeforeSessionCreation` rejects a remote identity under current privacy settings and asserts no request. Run red again; at least one session assertion must fail, not merely compile.

- [ ] **Step 3: Implement capture.** Factor the router's existing adapter construction into a synchronous captured config/key helper in one MainActor capture closure, so session preparation never consults settings again after it awaits. Retain an embedding-capable adapter; reject anthropic/openwebui using WP2's unsupportedEndpoint error. Use explicit captured raw model when calling embed. No extra listing/probe, no new URLSession outside Providers, no fallback Ollama. A query embedding failure is represented by the caller's lexical fallback diagnostic; cancellation remains cancellation.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter ProviderEmbeddingSessionTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/Providers/ProviderEmbeddingSession.swift Sources/AINotebookCore/Providers/ProviderRouter.swift Tests/AINotebookCoreTests/ProviderEmbeddingSessionTests.swift
git commit -m "feat(providers): capture generation-bound Swift embedding sessions" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: five methods green, existing WP2 provider tests and full Swift suite green.

## Task 11: [Windows] Capture immutable embedding sessions in Core router

**Depends on:** Task1, WP2 Core router final integration, WP3 GenerationIdentity. **Parallel with:** 2–10.

**Files:** three Task11 paths in the table. WP2 Task7 creates `windows/src/AINotebook.Core/Providers/ProviderRouter.cs` with namespace `AINotebook.Core.Providers.Routing` (WP2 plan:1268,1272,1360); the namespace does not add a Routing path component.

**Interfaces — Consumes:** WP2 `AINotebook.Core.Providers.Routing.ProviderRouter`, config/key/adapter factory and `IEmbeddingProducing`; Swift peer capture contract above. **Produces:** session contract above under `AINotebook.Core.Providers`; Core router implements `IEmbeddingSessionPreparing`.

- [ ] **Step 1: Add the red endpoint fixture Fact.**

```csharp
using AINotebook.Core.Providers;
using AINotebook.Core.Models;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Providers;

public sealed class ProviderEmbeddingSessionTests
{
    [Fact]
    public void EndpointIdentityFixture()
    {
        foreach (var c in SharedFixtures.Json("contracts/retrieval-session-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("expectedEndpointRevision",out var expected)) continue;
            var type=ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            Assert.Equal(expected.GetString(),EmbeddingEndpointRevision.Make(type,c.GetProperty("normalizedRoot").GetString()!));
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ProviderEmbeddingSessionTests` → helper missing FAIL. Hash with SHA256.HashData(UTF8(type.ToStorageString()+"\0"+normalizedRoot)) and Convert.ToHexStringLower; no credential bytes in the hash or diagnostics.

Add this real-router regression before implementing session preparation (imports include `System.Text.Json`, `AINotebook.Core.Storage`; alias CoreProviderRouter to `AINotebook.Core.Providers.Routing.ProviderRouter`). It uses the same public constructor WP2 freezes at its plan:1297.

```csharp
[Fact]
public async Task CapturedRootKeyAndModelSurviveSettingsMutation()
{
    var f=SharedFixtures.Json("contracts/retrieval-session-v1.json").GetProperty("cases").EnumerateArray().ToArray();
    var c=f.Single(x=>x.GetProperty("name").GetString()=="key-rotation");
    var moved=f.Single(x=>x.GetProperty("name").GetString()=="root-change");
    using var store=new NotebookStore(StorePath.InMemory);
    string id=c.GetProperty("providerId").GetString()!, root=c.GetProperty("oldRoot").GetString()!;
    string key=c.GetProperty("oldKey").GetString()!, model=c.GetProperty("rawModel").GetString()!;
    var config=new ProviderConfig(id,ProviderType.OpenAICompatible,"P",root,true,true,DateTime.UtcNow);
    store.SaveProvider(config);
    var handler=new StubHttpMessageHandler().Json("""{"data":[{"embedding":[1,0]}]}""");
    using var http=new HttpClient(handler);
    var router=new CoreProviderRouter(store,()=> (id,model),()=> (id,model),_=>key,http);
    var identity=new GenerationIdentity(id,EmbeddingEndpointRevision.Make(config.Type,root),model,null,2,"l2","1","1","2");
    var session=await router.PrepareEmbeddingAsync(identity);
    store.SaveProvider(config with {BaseUrl=moved.GetProperty("newRoot").GetString()!});
    key=c.GetProperty("newKey").GetString()!; model=c.GetProperty("newModel").GetString()!;
    _=await session.EmbedAsync(new[] {"Q"});
    Assert.Single(handler.AllRequests);
    Assert.Equal(root+"/embeddings",handler.LastRequest!.RequestUri!.AbsoluteUri);
    Assert.Equal(c.GetProperty("oldKey").GetString(),handler.LastRequest.Headers.Authorization!.Parameter);
    using var body=JsonDocument.Parse(handler.LastRequestBody!);
    Assert.Equal(c.GetProperty("rawModel").GetString(),body.RootElement.GetProperty("model").GetString());
}
```

- [ ] **Step 2: Add capture tests, run red, then implement.** `CapturedRootKeyAndModelSurviveSettingsMutation` prepares a session through the real Core router with WP2 fake config/key store, changes provider-a endpoint/key/model, invokes EmbedAsync and inspects StubHttpMessageHandler's URL/header/body. Expected values come from key-rotation/legacy fixtures. `MismatchedEndpointAndChatOnlySendNothing` loops the three rejection cases; assert zero HTTP requests and exact error code. `FormatsAndModelTags` checks legacy/1 identity input, model colon preservation and99 rejection. `PrivacyGateRunsBeforeSessionCreation` expects WP2 privacy error and zero requests. Capture config, key, normalized endpoint and adapter under the router's synchronization, then release before await. Do not hold NotebookStore._gate while preparing/sending a session.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ProviderEmbeddingSessionTests
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Providers/ProviderEmbeddingSession.cs windows/src/AINotebook.Core/Providers/ProviderRouter.cs windows/tests/AINotebook.Core.Tests/Providers/ProviderEmbeddingSessionTests.cs
git commit -m "feat(win-providers): immutable generation-bound embedding sessions" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: five Facts green; complete Core suite green. Task14 forwards this interface through App's existing wrapper.

## Retriever integration contract for Tasks 12 and 13

```swift
public struct PinnedRetrievalCandidate: Sendable, Equatable {
    public let reference: ChunkReference
    public let generationId: Int64?
    public let rrfMicro: Int64
}
public final class PinnedRetrievalCandidates: Sendable {
    public let lexical: [PinnedRetrievalCandidate]
    public let vector: [PinnedRetrievalCandidate]
    public let fused: [PinnedRetrievalCandidate]
    public let snapshot: ResolvedRetrievalScope?
    public let diagnostics: RetrievalDiagnostics
    public func close() async
}
public struct RetrievalDiagnostics: Sendable {
    public let vectorStatus: String
    public let invalidVectorCount: Int
    public let streamed: Bool
    public let peakPageBytes: Int64
}
// New overload, with no topK or sourceIds argument.
public func search(notebookId: Int64, query: String, scope: RetrievalScope,
    fetchK: Int = 32, includeVectors: Bool = true) async throws -> PinnedRetrievalCandidates
// WP7 timing seam: snapshot already owns a pin and vector is already embedded.
public func searchEmbedded(snapshot: ResolvedRetrievalScope, query: String,
    queryVector: [Float]?, fetchK: Int = 32) async throws -> PinnedRetrievalCandidates
```

```csharp
public sealed record PinnedRetrievalCandidate(ChunkReference Reference,long? GenerationId,long RrfMicro);
public sealed class PinnedRetrievalCandidates : IDisposable
{
    public IReadOnlyList<PinnedRetrievalCandidate> Lexical { get; }
    public IReadOnlyList<PinnedRetrievalCandidate> Vector { get; }
    public IReadOnlyList<PinnedRetrievalCandidate> Fused { get; }
    public ResolvedRetrievalScope? Snapshot { get; }
    public RetrievalDiagnostics Diagnostics { get; }
    public void Dispose();
}
public sealed record RetrievalDiagnostics(string VectorStatus,int InvalidVectorCount,bool Streamed,long PeakPageBytes);
public Task<PinnedRetrievalCandidates> SearchAsync(long notebookId,string query,RetrievalScope scope,
    int fetchK=32,bool includeVectors=true,CancellationToken ct=default);
public Task<PinnedRetrievalCandidates> SearchEmbeddedAsync(ResolvedRetrievalScope snapshot,string query,
    float[]? queryVector,int fetchK=32,CancellationToken ct=default);
```

Branch candidates store `rrfMicro=1_000_000/(60+rank)` for their own deduplicated 1-based rank; fused candidates store the sum. The legacy adapter uses the Retriever's existing configurable rrfK, whose default is60, so existing constructor behavior is preserved. Every candidate, including lexical-only candidates, carries its own revision and the query's nullable generation ID. `vectorStatus` is one of `used`, `disabled`, `noActiveGeneration`, `invalidQueryVector`, `embeddingFailed`, `endpointRevisionMismatch`, `unsupportedQueryFormat`, `embeddingSessionRequired`, `legacyEndpointUnverified`, `legacyProviderUnresolved`, `oversizedVector`. Do not include provider secrets or raw endpoint strings. An oversized generation (dims*4>8MiB or overflow) sets `oversizedVector` before session preparation, reads no BLOB and sends zero embedding requests. No usable active generation means zero embedding requests and working lexical results. Cancellation is propagated, never converted into lexical success. Invalid fetchK≤0 throws before any SQL/provider call; the compatibility topK adapter validates `fetchK>=topK>0` before delegation.

Orchestration order is fixed:

1. Validate arguments; empty selection returns an empty pool without reading model settings, SQL, Unicode resources or the provider.
2. Capture configured model key exactly once; resolve scoped pin in one read transaction. Read the pinned generation row inside it. No `activeGeneration` or modelGetter call after the first suspension.
3. If vectors requested and a matching usable generation exists, capture an immutable embedding session, then embed exactly one current question. Missing/mismatched endpoint/unsupported format or provider failure sets a diagnostic and leaves the lexical path available; preserve cancellation.
4. `searchEmbedded` builds the FTS expression, revalidates permitted sources, and runs lexical top fetchK. For vectors, read generation count/epoch, attempt budgeted cache acquisition with paged fill, otherwise scan bounded pages. Use the same heap and mask for both paths. After scoring, obtain the current permitted source set again and intersect it with the mask used for this pass. If it shrank, rerun both branch selections against that smaller mask and the same pinned revisions (reuse the matrix or repeat the bounded scan). Repeat until two successive masks agree, checking cancellation between passes. Masks only shrink, so newly admitted sources never enter the turn; a revocation still lets a lower-ranked valid row reach topK. The final mask check is the result's permission observation point; hydration performs its own later check.
5. Integer fuse the two branch lists, no final fetchK/topK truncation. Transfer the snapshot lease into the returned pool. Exceptions close the lease in catch/finally; cache lease is always released after scoring, independently of revision pin lifetime. `searchEmbedded` transfers snapshot ownership on success and closes on failure; callers must not close after transfer.
6. Compatibility adapters copy display snippets from explicit revisions while pool remains pinned, then close the pool. Preserve the original `RetrievalHit` shape, converting `Float(rrfMicro)/1_000_000` only for its display score. ChatEngine stays untouched until WP8 supplies full evidence to its prompt builder.

WP1 `candidates`/`CandidatesAsync` must expose the new production branches to WP7 with their original sourceIds nil/all versus empty/none semantics. Its `RetrievalCandidates` type stays unchanged. WP7 owns the next generated eval report and must set its backend label to `fts-or-pinned-rrf-v1` before reporting the new implementation. WP5 does not generate or republish WP1 baseline reports; their `legacy-fts-eval-rrf-v1` label and artifact bytes remain accurate historical records. Tasks15/16 provide timing APIs; runner/report files remain owned by WP7.

## Task 12: [Swift] Join retrieval and retain ChatEngine compatibility

**Depends on:** Tasks2,4,6,6a,8,10 and WP1 Task4 merged. **Parallel with:** 13 and completed independent platform tasks.

**Files:** three Task12 files only.

**Interfaces — Consumes:** FTS, scope, ranking/cache, hydrator, ProviderEmbeddingSession and WP1 `RetrievalCandidates(lexical:vector:fused:)`. C# peer `.SearchAsync/.CandidatesAsync` contracts are above. **Produces:** Swift pinned integration APIs above; retains `search(notebookId:query:topK:sourceIds:) async throws -> [RetrievalHit]`, `candidates(notebookId:query:fetchK:sourceIds:includeVectors:) async throws -> RetrievalCandidates`, and both existing constructors.

- [ ] **Step 1: Write red fallback/empty/snapshot tests.**

```swift
import XCTest
@testable import AINotebookCore

private actor WP5CountingEmbedder: EmbeddingProducing {
    var calls = 0
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls += 1; return [[1,0]]
    }
}
@MainActor final class PinnedRetrieverTests: XCTestCase {
    func testNoActiveGenerationIsLexicalOnly() async throws {
        let store = try RetrievalFixtureStore.make("no-active")
        let client = WP5CountingEmbedder()
        let retriever = Retriever(store: store, client: client, model: "m")
        let pool = try await retriever.search(notebookId: 1, query: "needle", scope: .all, fetchK: 2)
        XCTAssertEqual(pool.fused.map { $0.reference.chunkId }.sorted(), [1020,4010])
        XCTAssertTrue(pool.vector.isEmpty)
        XCTAssertEqual(pool.diagnostics.vectorStatus, "noActiveGeneration")
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
        await pool.close()
    }
    func testEmptyScopeDoesNothing() async throws {
        let store = try RetrievalFixtureStore.make()
        let client = WP5CountingEmbedder()
        let retriever = Retriever(store: store, client: client, modelKey: { fatalError("empty scope read model settings") })
        let pool = try await retriever.search(notebookId: 1, query: "needle",
            scope: .selection(sourceIds: [], folderIds: []), fetchK: 32)
        XCTAssertTrue(pool.fused.isEmpty)
        XCTAssertNil(pool.snapshot)
        XCTAssertEqual(RetrievalFixtureStore.sqlStatementCount(store),0)
        let calls = await client.calls
        XCTAssertEqual(calls,0)
    }
}
```

Run `swift test --filter PinnedRetrieverTests` → missing typed scope overload FAIL.

- [ ] **Step 2: Implement orchestration and adapters.** Add an initializer overload with `cache:VectorMatrixCache` default shared and `tables:UnicodeTables` optional injected; existing constructors delegate without breaking callers. Actual Unicode loading happens after the empty guard. Retain the captured configured key for pinQuery, not the generation's raw model; use the generation identity to prepare the session. Do not turn an unmatched configured model into another active generation. Lexical branch returns explicit pinned revisions. Retire the old float RRF/full sort/whole-query phrase implementations from production; keep no hidden rank path. Legacy search maps sourceIds.isEmpty to all, uses fetchK=topK to preserve `RetrievalEval.swift:42–65`'s explicit candidate window, returns fused.prefix(topK) with revision-correct snippets and closes. WP1 candidates maps nil to all and nonnil to selection, fetches each branch and copies **all fused candidates**; includeVectors false creates no provider session.

- [ ] **Step 3: Add six regression methods.** `testPerBranchFetchKAndIntegerPool` drives union/tie/full-pool and verifies up to2*fetchK with stable micro scores. `testOneGenerationAndModelReadAcrossAwait` barrier-pauses embedding, executes switch-during-query and publish-during-query, asserts every hit retains generation90 and original102/101 revisions and a modelGetter count1. `testRevocationBeforeReturnRemovesStaleHits` runs each revocation event while embedding/scan is paused and asserts no revoked IDs plus next valid masked hit. `testEmbeddingFailureFallsBackButCancellationThrows` injected throwing versus CancellationError clients, asserts lexical results for failure, no pool for cancellation, zero pins after error. `testLegacyAndEvalAdapters` verifies [] legacy search=all, [] candidates=empty, nil candidates=all, snippets240 scalars, integer ordering and no pool/pin leak. `testInvalidLimitsAndMalformedQueryVector` asserts fetchK0/negative rejected before SQL and wrong/zero/NaN query vectors leave lexical results with exact diagnostic; the shared oversized-generation case sends0 embeddings and reads0 vector BLOBs.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter PinnedRetrieverTests
swift test --filter 'ChatEngineTests|EvalRetrievalTests|RetrieverTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/Retriever.swift Sources/AINotebookCore/PinnedRetrievalCandidates.swift Tests/AINotebookCoreTests/PinnedRetrieverTests.swift
git commit -m "feat(retrieval): pinned scoped Swift candidate pools with chat adapters" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight new methods, existing ChatEngine/retrieval/eval assertions and full suite green. No ChatEngine/SystemPrompt edit.

## Task 13: [Windows] Join retrieval with one generation snapshot per query

**Depends on:** Tasks3,5,7,7a,9,11 and WP1 Task5 merged. **Parallel with:** 12,15 after its prerequisites.

**Files:** three Task13 paths only.

**Interfaces — Consumes:** C# storage/rank/cache/hydration/session APIs; Swift peers fixed above. **Produces:** pinned C# overloads above; retains original `SearchAsync(long,string,int=8,IReadOnlyCollection<long>?=null,CancellationToken=default)`, WP1 `CandidatesAsync(long,string,int=32,IReadOnlyCollection<long>?=null,bool=true,CancellationToken=default)`, and both constructors.

- [ ] **Step 1: Add the red no-active and empty Facts.**

```csharp
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

public sealed class PinnedRetrieverTests
{
    private sealed class CountingEmbedder : IEmbeddingProducing
    {
        public int Calls;
        public Task<float[][]> EmbedAsync(string model,IReadOnlyList<string> inputs,CancellationToken ct=default)
        { Interlocked.Increment(ref Calls); return Task.FromResult(new[] {new float[] {1,0}}); }
    }
    [Fact]
    public async Task NoActiveGenerationIsLexicalOnly()
    {
        using var store=RetrievalFixtureStore.Create("no-active");
        var client=new CountingEmbedder();
        var retriever=new Retriever(store,client,"m");
        using var pool=await retriever.SearchAsync(1,"needle",new RetrievalScope.All(),2);
        Assert.Equal(new long[] {1020,4010},pool.Fused.Select(x=>x.Reference.ChunkId).Order());
        Assert.Empty(pool.Vector);
        Assert.Equal("noActiveGeneration",pool.Diagnostics.VectorStatus);
        Assert.Equal(0,client.Calls);
    }
    [Fact]
    public async Task EmptyScopeDoesNothing()
    {
        using var store=RetrievalFixtureStore.Create();
        var client=new CountingEmbedder();
        var retriever=new Retriever(store,client,()=>throw new InvalidOperationException("empty scope read model"));
        using var pool=await retriever.SearchAsync(1,"needle",new RetrievalScope.Selection(new HashSet<long>(),new HashSet<long>()),32);
        Assert.Empty(pool.Fused); Assert.Null(pool.Snapshot);
        Assert.Equal(0,RetrievalFixtureStore.SqlStatementCount(store));
        Assert.Equal(0,client.Calls);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~PinnedRetrieverTests` → missing scope overload FAIL. The concrete constructors are `new RetrievalScope.All()` and `new RetrievalScope.Selection(IReadOnlySet<long>, IReadOnlySet<long>)`; the existing codec is `RetrievalScopeJson.Deserialize(string)` (`windows/src/AINotebook.Core/Rag/RetrievalScope.cs:13,15,67`).

- [ ] **Step 2: Implement the fixed orchestration.** Capture `_modelGetter()` once before Resolve. Never read `Model` after await. Inject cache and Unicode table through an additional constructor while preserving original constructors. SearchEmbeddedAsync runs the CPU scoring stage through `Task.Run(...,ct)` even when a warm cache acquisition completes synchronously; provider/cache awaits use ConfigureAwait(false); every reader method owns `_gate` only for SQL. No store lock spans embedding, SIMD or awaits. Dispose vector lease after ranking, transfer revision lease to pool, close on all failure/cancellation paths. Ordinary provider errors retain lexical results; OperationCanceledException propagates. Old SearchAsync maps null/empty IDs to all, validates positive topK and takes final prefix only in the compatibility adapter. WP1 CandidatesAsync maps null→all, explicit[]→empty and keeps full fused union; convert micro score to float only when constructing existing Models.RetrievalHit.

- [ ] **Step 3: Add six regression Facts.** `PerBranchFetchKAndIntegerPool` consumes rank fixture and checks lexical/vector branch lengths plus full fused union. `OneGenerationAndModelReadAcrossAwait` uses a TaskCompletionSource embedding barrier, applies switch/publication fixture events and asserts original generation/revisions plus getter count1. `RevocationBeforeReturnRemovesStaleHits` pauses scan before return, revokes availability/eligible/membership separately and asserts next eligible item enters the result. `EmbeddingFailureFallsBackButCancellationThrows` distinguishes ordinary failure from cancellation, verifies exact diagnostics and registry pin count0 on error. `LegacyAndEvalAdapters` asserts historical null/empty semantics, explicit candidates[] no query,240-rune snippets and no lease leak. `InvalidLimitsAndMalformedQueryVector` asserts invalid fetchK causes0 SQL/HTTP and invalid vector shapes preserve lexical results, and oversized-generation sends0 embeddings/reads0 BLOBs.

- [ ] **Step 4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~PinnedRetrieverTests
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~ChatEngineTests|FullyQualifiedName~EvalRetrievalTests|FullyQualifiedName~RetrieverTests'
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/Retriever.cs windows/src/AINotebook.Core/Rag/PinnedRetrievalCandidates.cs windows/tests/AINotebook.Core.Tests/Rag/PinnedRetrieverTests.cs
git commit -m "feat(win-retrieval): single-snapshot scoped pools and compatibility adapters" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight new Facts, existing ChatEngine/retrieval/eval tests and full Core suite green.

## Task 14: [Win-UI] Forward embedding sessions through the App router bridge

**Depends on:** Tasks11,13; WP2 Task11 and WP3 Task12 merged. **Parallel with:** 12,15,16. No overlap with Task7 lockfiles.

**Files:** `windows/src/AINotebook.App/Services/ProviderRouter.cs` and new `windows/tests/AINotebook.App.Tests/ProviderEmbeddingBridgeTests.cs` only. Current App DI injects this wrapper as IEmbeddingProducing (`App.xaml.cs:94,102–103,138–144`); changing Core alone would bypass modern session capture.

**Interfaces — Consumes:** C# `IEmbeddingSessionPreparing.PrepareEmbeddingAsync(GenerationIdentity,CancellationToken)`; Swift `EmbeddingSessionPreparing.prepareEmbedding(identity:)` is already provided directly by the Swift Core router. **Produces:** App wrapper implements IEmbeddingSessionPreparing and forwards the exact method to the existing private Core router field. No views/view models/XAML/bindings change. **Localized keys:** none (EN/CS localization files on both platforms remain untouched; this task adds no user-visible text).

- [ ] **Step 1: Write the Windows-only red App test.**

```csharp
using AINotebook.Core.Providers;
using Xunit;
public sealed class ProviderEmbeddingBridgeTests
{
    [Fact]
    public void AppRouterExposesEmbeddingSessions()
    {
        Assert.True(typeof(IEmbeddingSessionPreparing)
            .IsAssignableFrom(typeof(AINotebook.App.Services.ProviderRouter)));
    }
}
```

Run `dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64 --filter FullyQualifiedName~ProviderEmbeddingBridgeTests` on Windows → FAIL, interface not implemented.

- [ ] **Step 2: Add interface and forwarding method.** Rename no existing constructor, DI registration or field. With the merged WP2 Core router field named `_core`, add:

```csharp
public Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity,
    CancellationToken ct=default) => _core.PrepareEmbeddingAsync(identity,ct);
```

If WP2's field has another name, reference that actual existing field; create no second router. Import `AINotebook.Core.Storage` for GenerationIdentity and `AINotebook.Core.Providers` for session types. Add a second App test using the WP2 bridge test fixture: prepare a session, mutate settings, send through the session and assert captured root/key/model once. The Core fake HTTP handler records traffic; no live endpoint.

- [ ] **Step 3: Verify on Windows and commit.**

```powershell
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.App/Services/ProviderRouter.cs windows/tests/AINotebook.App.Tests/ProviderEmbeddingBridgeTests.cs
git commit -m "fix(win-app): forward generation-bound embedding sessions" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: two App Facts and complete App/Core suites green. Manual Windows checklist: existing notebook chat succeeds; switching embedding selection affects the next query; an in-flight query stays on its captured provider/model; unmatched generation still yields lexical evidence. Claude manually checks the corresponding macOS chat adapter after Task12 by running the app; no Swift UI implementation task is required.

## Task 15: [Swift] Synthetic corpus and post-embedding performance hooks

**Depends on:** Tasks1,12. **Parallel with:** 13,14,16.

**Files:** `Sources/AINotebookCore/RetrievalPerformance.swift`, `Tests/AINotebookCoreTests/RetrievalPerformanceTests.swift` only. WP1's CLI (`Sources/RetrievalEvalRunner/main.swift:25,368`) remains unchanged; WP7 calls these public Core hooks when extending it.

**Interfaces — Consumes:** typed searchEmbedded, evidence hydrator and WP3 revision/generation writes; C# counterparts below. **Produces:**

```swift
public struct SyntheticRetrievalChunk: Sendable {
    public let chunkId: Int64; public let sourceId: Int64; public let ord: Int
    public let text: String; public let vector: [Float]
}
public struct SyntheticRetrievalHandle: Sendable {
    public let notebookId: Int64; public let generationId: Int64
    public let chunkCount: Int; public let dims: Int
}
public enum SyntheticRetrievalCorpus {
    public static func row(index: Int, dims: Int, seed: Int = 17) -> SyntheticRetrievalChunk
    @MainActor public static func populate(store: NotebookStore, chunkCount: Int,
        dims: Int, seed: Int = 17) throws -> SyntheticRetrievalHandle
}
public struct RetrievalPerformanceSample: Sendable {
    public let queryEmbeddingMs: Double
    public let warmRetrievalMs: Double
    public let hydrationMs: Double
}
public enum RetrievalPerformance {
    @MainActor public static func measure(snapshot: ResolvedRetrievalScope, embedding: () async throws -> [Float],
        retrieval: ([Float]) async throws -> PinnedRetrievalCandidates,
        hydration: (PinnedRetrievalCandidates) async throws -> Void,
        ticksPerSecond: UInt64, now: () -> UInt64) async throws -> RetrievalPerformanceSample
    public static func percentile95(_ samples: [Double]) -> Double
}
```

C# peer: `SyntheticRetrievalChunk(long ChunkId,long SourceId,int Ord,string Text,float[] Vector)`, `SyntheticRetrievalHandle(long NotebookId,long GenerationId,int ChunkCount,int Dims)`; `SyntheticRetrievalCorpus.Row(int index,int dims,int seed=17)`, `.Populate(NotebookStore,int chunkCount,int dims,int seed=17)`; `RetrievalPerformanceSample(double QueryEmbeddingMs,double WarmRetrievalMs,double HydrationMs)`; `Task<RetrievalPerformanceSample> MeasureAsync(ResolvedRetrievalScope snapshot,Func<Task<float[]>> embedding,Func<float[],Task<PinnedRetrievalCandidates>> retrieval,Func<PinnedRetrievalCandidates,Task> hydration,long ticksPerSecond,Func<long> now)`; `double Percentile95(IReadOnlyList<double>)`.

- [ ] **Step 1: Add red generator and timing tests.**

```swift
import XCTest
@testable import AINotebookCore

@MainActor final class RetrievalPerformanceTests: XCTestCase {
    func testSharedSyntheticRows() throws {
        let f=try SharedFixtures.json("contracts/retrieval-perf-v1.json")
        let c=(f["cases"] as! [[String:Any]]).first { $0["name"] as? String == "small" }!
        for (i,r) in (c["rows"] as! [[String:Any]]).enumerated() {
            let row=SyntheticRetrievalCorpus.row(index:i,dims:c["dims"] as! Int,seed:c["seed"] as! Int)
            XCTAssertEqual(row.text,r["text"] as? String)
            XCTAssertEqual(row.vector,(r["vector"] as! [NSNumber]).map(\.floatValue))
            XCTAssertEqual(row.chunkId,Int64(i+1)); XCTAssertEqual(row.ord,i%100)
        }
    }
    func testTimingExcludesEmbeddingFromWarmRetrieval() async throws {
        let store=try RetrievalFixtureStore.make("no-active")
        let snapshot=try XCTUnwrap(ScopeResolver.resolve(store:store,notebookId:1,scope:.all,modelKey:"m"))
        let retriever=Retriever(store:store,client:WP5PerfEmbedder(),model:"m")
        var times:[UInt64]=[100,130,180,230]
        let sample=try await RetrievalPerformance.measure(snapshot:snapshot,embedding:{ [1,0] },
            retrieval:{ vector in try await retriever.searchEmbedded(snapshot:snapshot,query:"needle",queryVector:vector) },
            hydration:{ pool in
                _ = try await EvidenceHydrator(reader:store.makeRetrievalReader()).hydrate(
                    pool.snapshot!,references:pool.fused.map(\.reference),neighborRadius:0)
            },ticksPerSecond:1000,now:{ times.removeFirst() })
        XCTAssertEqual(sample.queryEmbeddingMs,30)
        XCTAssertEqual(sample.warmRetrievalMs,50)
        XCTAssertEqual(sample.hydrationMs,50)
        XCTAssertTrue(times.isEmpty)
    }
}
private struct WP5PerfEmbedder: EmbeddingProducing {
    func embed(model:String,inputs:[String]) async throws -> [[Float]] { [[1,0]] }
}
```

Run `swift test --filter RetrievalPerformanceTests` → types missing FAIL. The declared `@MainActor measure` owns its callbacks, so the test captures of MainActor store/ticks remain isolated under Swift6. Production ranking still awaits the background reader/actor; timestamps are collected on the harness coordinator.

- [ ] **Step 2: Implement the deterministic generator and timer.**

```swift
public static func row(index: Int, dims: Int, seed: Int = 17) -> SyntheticRetrievalChunk {
    precondition(index >= 0 && dims > 0 && seed >= 0)
    var vector = [Float](repeating: 0, count: dims)
    vector[(index % dims + seed % dims) % dims] = 1
    return SyntheticRetrievalChunk(chunkId: Int64(index + 1), sourceId: Int64(1 + index / 100),
        ord: index % 100, text: "synthetic \(index) needle\(index % 97)", vector: vector)
}
```

Implement the owning Swift timer as follows; its C# peer below uses `using` for the same ownership:

```swift
@MainActor public static func measure(snapshot: ResolvedRetrievalScope,
    embedding: () async throws -> [Float],
    retrieval: ([Float]) async throws -> PinnedRetrievalCandidates,
    hydration: (PinnedRetrievalCandidates) async throws -> Void,
    ticksPerSecond: UInt64, now: () -> UInt64) async throws -> RetrievalPerformanceSample {
    var pool: PinnedRetrievalCandidates?
    do {
        guard ticksPerSecond > 0 else { throw RetrievalError.invalidMeasurementInput }
        let t0=now(), vector=try await embedding(), t1=now()
        let result=try await retrieval(vector); pool=result
        let t2=now()
        try await hydration(result)
        let t3=now()
        guard t0<=t1 && t1<=t2 && t2<=t3 else { throw RetrievalError.invalidMeasurementInput }
        let sample=RetrievalPerformanceSample(queryEmbeddingMs:Double(t1-t0)*1000/Double(ticksPerSecond),
            warmRetrievalMs:Double(t2-t1)*1000/Double(ticksPerSecond),
            hydrationMs:Double(t3-t2)*1000/Double(ticksPerSecond))
        await result.close(); await snapshot.close()
        return sample
    } catch {
        await pool?.close(); await snapshot.close()
        throw error
    }
}
```

Populate a fresh benchmark notebook only,100 chunks/source. For each source, concatenate row texts with LF, compute scalar spans while appending, publish one version2 revision, add it to a building legacy generation with model `synthetic`, dims from input. Insert normalized one-hot embeddings in transactions of≤1024 rows using the WP3 generation SQL kernel and finalize manifest done; activate only after all sources are complete. Keep a source's≤100 generated vectors in memory; never create the whole100K array. Return actual generated DB IDs in the handle; fixture logical row IDs are independent of unrelated existing notebook IDs. Reject counts other than positive integers and dimensions that overflow the page bound. Add internal test seed batching through the task's new file, not changes to WP3 migration/store files.

Measure owns the explicit snapshot from method entry, including when embedding throws. Execute `t0=now(); vector=await embedding(); t1=now(); pool=await retrieval(vector); t2=now(); await hydration(pool); t3=now()`, close pool and snapshot on success/failure, and return each difference×1000/frequency. Clock must be monotonic and frequency>0; throw invalid measurement input on decreasing ticks. Use DispatchTime.now().uptimeNanoseconds/frequency1_000_000_000 in the actual Mac harness. p95 uses sorted samples index `ceil(0.95*n)-1`, requiring nonempty samples. Expose embedding, warm retrieval and hydration separately; also report their sum for end-to-end, never include query embedding in warm p95.

- [ ] **Step 3: Add small real-path and percentile tests.** `testGeneratedStoreTraversesProductionRetrieval` populates1000 chunks/dims16, searches by precomputed one-hot vector twice, asserts warm and streamed budget0 runs have identical ordered IDs, query-scoped revocation works, and max page bytes≤8MiB. `testPercentileAndFailureClosesPool` uses1...200→190, and separate embedding/hydration closures throwing a fixture error; after catch, retire/GC proves no leaked pin. `testLargeCorpusSpecification` checks fixture counts100000/200000 and dimensions256, then generates row99999/199999 only; large corpora are opt-in performance runs, not every unit test.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter RetrievalPerformanceTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/RetrievalPerformance.swift Tests/AINotebookCoreTests/RetrievalPerformanceTests.swift
git commit -m "feat(eval): Swift synthetic retrieval corpus and phase timing hooks" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: five methods green; full suite green. WP7's reference-hardware protocol: build100K then200K, warm once, run200 pre-embedded queries, report p50/p95, cache residency/peak page bytes, generation/dims/CPU/OS, separate concurrent-ingestion and budget0 runs. Do not claim the<300ms gate from fake-clock tests.

## Task 16: [Windows] Synthetic corpus and identical timing hooks

**Depends on:** Tasks1,13. **Parallel with:** 12,14,15.

**Files:** the two Task16 files only. No eval CLI/project file change.

**Interfaces — Consumes:** `SearchEmbeddedAsync`, evidence hydration and WP3 lifecycle; Swift counterparts in Task15. **Produces:** all C# synthetic/timing signatures explicitly listed in Task15, implemented under `AINotebook.Core.Rag`. Public `MeasureAsync` disposes the snapshot from entry and the returned pool in finally; both releases are idempotent.

- [ ] **Step 1: Add the red shared generator/timing Facts.**

```csharp
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

public sealed class RetrievalPerformanceTests
{
    private sealed class Embedder : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model,IReadOnlyList<string> inputs,CancellationToken ct=default)
            =>Task.FromResult(new[] {new float[] {1,0}});
    }
    [Fact]
    public void SharedSyntheticRows()
    {
        var c=SharedFixtures.Json("contracts/retrieval-perf-v1.json").GetProperty("cases").EnumerateArray()
            .Single(x=>x.GetProperty("name").GetString()=="small");
        int i=0;
        foreach(var r in c.GetProperty("rows").EnumerateArray())
        {
            var row=SyntheticRetrievalCorpus.Row(i,c.GetProperty("dims").GetInt32(),c.GetProperty("seed").GetInt32());
            Assert.Equal(r.GetProperty("text").GetString(),row.Text);
            Assert.Equal(r.GetProperty("vector").EnumerateArray().Select(x=>x.GetSingle()),row.Vector);
            Assert.Equal(i+1,row.ChunkId); Assert.Equal(i%100,row.Ord); i++;
        }
        Assert.Equal(8,i);
    }
    [Fact]
    public async Task TimingExcludesEmbeddingFromWarmRetrieval()
    {
        using var store=RetrievalFixtureStore.Create("no-active");
        var snapshot=ScopeResolver.Resolve(store,1,new RetrievalScope.All(),"m")!;
        var retriever=new Retriever(store,new Embedder(),"m");
        var times=new Queue<long>([100,130,180,230]);
        var sample=await RetrievalPerformance.MeasureAsync(snapshot,()=>Task.FromResult(new float[] {1,0}),
            vector=>retriever.SearchEmbeddedAsync(snapshot,"needle",vector),
            pool=> { _=new EvidenceHydrator(store.MakeRetrievalReader()).Hydrate(pool.Snapshot!,pool.Fused.Select(x=>x.Reference).ToArray(),0); return Task.CompletedTask; },
            1000,()=>times.Dequeue());
        Assert.Equal(30,sample.QueryEmbeddingMs); Assert.Equal(50,sample.WarmRetrievalMs);
        Assert.Equal(50,sample.HydrationMs); Assert.Empty(times);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~RetrievalPerformanceTests` → types missing FAIL.

- [ ] **Step 2: Implement generator/timing kernels.**

```csharp
public static SyntheticRetrievalChunk Row(int index,int dims,int seed=17)
{
    ArgumentOutOfRangeException.ThrowIfNegative(index);
    ArgumentOutOfRangeException.ThrowIfNegativeOrZero(dims);
    ArgumentOutOfRangeException.ThrowIfNegative(seed);
    var vector=new float[dims]; vector[(index%dims+seed%dims)%dims]=1;
    return new(index+1L,1+index/100,index%100,$"synthetic {index} needle{index%97}",vector);
}
public static async Task<RetrievalPerformanceSample> MeasureAsync(ResolvedRetrievalScope snapshot,Func<Task<float[]>> embedding,
    Func<float[],Task<PinnedRetrievalCandidates>> retrieval,Func<PinnedRetrievalCandidates,Task> hydration,
    long ticksPerSecond,Func<long> now)
{
    using var ownedSnapshot=snapshot;
    ArgumentOutOfRangeException.ThrowIfNegativeOrZero(ticksPerSecond);
    long t0=now(); var vector=await embedding(); long t1=now();
    using var pool=await retrieval(vector); long t2=now();
    await hydration(pool); long t3=now();
    if(t1<t0 || t2<t1 || t3<t2) throw new ArgumentException("Nonmonotonic clock");
    return new((t1-t0)*1000.0/ticksPerSecond,(t2-t1)*1000.0/ticksPerSecond,(t3-t2)*1000.0/ticksPerSecond);
}
```

Populate one new benchmark notebook:100 chunks/source, LF-joined canonical text, scalar spans, version2 revisions, building legacy generation model synthetic, one-hot vectors, done manifests then activation. Materialize at most100 vectors for a source and insert batches≤1024 in gated transactions using the existing generation kernel. Actual DB IDs are returned by the store; do not assume the database was globally empty. Use Stopwatch.GetTimestamp/Frequency in production. Percentile95 sorts only the200 timing samples, returns item ceil(.95*n)-1 and rejects empty input. The synthetic corpus iterator never allocates100K/200K vectors at once.

- [ ] **Step 3: Add real-path and lifetime regressions.** `GeneratedStoreTraversesProductionRetrieval` creates1000 chunks/dims16, compares cached and budget0 stream ordered IDs, verifies page byte bound and current eligibility. `PercentileAndFailureDisposesPool` asserts1..200→190 and separate injected embedding/hydration failures allow old revision GC. `LargeCorpusSpecification` reads both large fixture rows and validates row99999/199999 directly without a heavy benchmark. Every Windows connection operation during generation or assertions is under the store gate.

- [ ] **Step 4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~RetrievalPerformanceTests
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/RetrievalPerformance.cs windows/tests/AINotebook.Core.Tests/Rag/RetrievalPerformanceTests.cs
git commit -m "feat(win-eval): synthetic corpus and post-embedding retrieval timing" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: five Facts green and complete Core suite green. WP7 executes200 warm queries on100K and200K, records Windows CPU/dims/OS/cache statistics and repeats with ingestion/budget0. Unit tests prove timing boundaries, not hardware latency.

## Task 17: [Shared] Freeze contract §7 against both production SQLite engines

**Depends on:** Tasks1–16 (including6a/7a) green, actual Windows FTS test log and macOS FTS test log available. **Parallel with:** none inside WP5. Wait for outstanding WP0 edits to `gen_fixtures.py` before branching.

**Files:** exactly the three Task17 paths in the table.

**Interfaces — Consumes:** Swift `FTSQueryBuilder.matchExpression(_:) -> String?`, C# `FtsQueryBuilder.MatchExpression(string) -> string?`, existing24-case `fts-query-v1.json`; generator `python3 tools/contracts/gen_fixtures.py --check`. **Produces:** §7 frozen with unchanged algorithms/case results; fixture `provisional:false`; generator produces that same flag. No fixture version bump because this section was explicitly provisional before release.

- [ ] **Step 1: Obtain conformance evidence.**

macOS:

```bash
swift test --filter FTSQueryBuilderTests
python3 -B tools/contracts/gen_fixtures.py --check
```

Windows, using the App's locked Microsoft.Data.Sqlite/e_sqlite3 graph:

```powershell
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FtsQueryBuilderTests --logger "console;verbosity=detailed"
```

Expected:24 expression cases and21 nonnull MATCH outcomes per platform,0 failures. Record OS, provider and SQLite version **in review evidence only**, not fixture bytes. A Python run, or Windows Core tests run only on macOS, cannot satisfy the Windows evidence requirement.

- [ ] **Step 2: Freeze the status only after evidence agrees.** Rename contract heading to `## 7. FTS query — frozen v1`; replace its closing provisional sentence with “Frozen after the WP5 GRDB system SQLite and Windows e_sqlite3 conformance runs; runtime versions are retained in the platform conformance logs.” Change generator's FTS envelope to `provisional:False`, regenerate the one FTS fixture, and inspect the diff: only provisional flag changes. If either SQLite engine disagrees, do not alter expectedMatchExpr/shouldMatchDocument just to go green. Report exact failing fixture name and both actual values to Claude; keep §7 provisional until a jointly reviewed contract correction and rerun.

- [ ] **Step 3: Green and commit.**

```bash
python3 -B tools/contracts/gen_fixtures.py --check
python3 -B tools/contracts/gen_retrieval_fixtures.py --check
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git diff --check
git add docs/contracts/folder-rag-v1.md tools/contracts/gen_fixtures.py Tests/fixtures/contracts/fts-query-v1.json
git commit -m "contracts: freeze FTS v1 against GRDB and Windows e_sqlite3" -m "Both production SQLite conformance runs passed all 24 cases; platform test logs are attached to the review." -m "Co-Authored-By: Codex <noreply@openai.com>"
```

The worker's final report must include the collected platform/version strings and actual Windows CI run URL. Keep the conformance logs with the review; never claim a Windows result from the macOS run.

## WP gate

Run from the merged WP5 tree:

```bash
python3 -B -m unittest discover -s tools/contracts -p 'test_retrieval_fixtures.py' -v
python3 -B tools/contracts/gen_retrieval_fixtures.py --check
python3 -B tools/contracts/gen_fixtures.py --check
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git diff --check
git status --short
```

Windows gate:

```powershell
dotnet restore windows/AINotebook.sln --locked-mode -p:Platform=x64
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FtsQueryBuilderTests --logger "console;verbosity=detailed"
```

Acceptance criteria:

- Every shared case executes on both platforms, both full suites green, no skipped contract tests; clean worktree with all commits carrying the required trailer.
- Empty selection causes0 SQL and0 embedding calls. Notebook/scope/availability/eligibility predicates match for lexical, vector, metadata and neighbours. Published lexical and older manifest vector revisions survive a refresh and hydrate their own text. No active generation still retrieves published evidence.
- Per-branch fetchK,1-based integer RRF, dedupe and chunkId ties pass; production uses masked heap top-K and never sorts all scored rows. WP1 eval adapter/report and today's ChatEngine remain green with documented compatibility semantics.
- Cache budget includes reservations and invalidated leased matrices. Oversized or pinned-out entries stream bounded pages; invalidated fills never reenter the cache. Every write category and cross-store invalidation test passes. Revision pins outlive hydration, protect concurrent GC, and release on cancellation/error/adapter paths.
- Provider/model/generation snapshots survive Settings changes; endpoint mismatch emits no request; chat-only providers are rejected without substitution. Windows App forwards session capture; no new networking outside Providers.
- FTS §7 has actual macOS and Windows engine evidence and is frozen. UnicodeTables comes from merged WP4 Tasks2/3. No host Unicode fallback or changed frozen match expectations.
- WP7 can generate100K/200K deterministically and measure200 warmed queries after embedding, with separate hydration/ingestion/streaming measurements. The<300ms reference-hardware target remains a WP7 measurement gate; WP5 does not claim a result from unit tests.
- Claude reviews the explicit endpoint fingerprint/legacyEndpointUnverified policy, conservative database-wide cache epoch invalidation, neighbour behavior across revisions, and the WP7 report backend identifier handoff. Review is part of merging these implementation decisions, not permission to skip prerequisite work.

Each worker's final report contains commit IDs, exact files, baseline/final test counts for both suites (unrun platform commands explicitly stated), Windows CI link where applicable, and only remaining review decisions. This planning commit changes this plan file alone; it does not mark any WP5 implementation gate complete.
