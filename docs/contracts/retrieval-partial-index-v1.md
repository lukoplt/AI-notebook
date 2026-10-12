# Semantic retrieval during the first index build — normative contract v1

*Status: 2026-10-11. Fixture: `Tests/fixtures/contracts/retrieval-partial-v1.json`. Executable reference: `tools/contracts/gen_partial_index_fixtures.py` (`--check` must pass; `tools/contracts/test_partial_index_fixtures.py`). Swift (`NotebookStore.withQueryPin`, `ScopeResolver`, `Retriever.search`) and C# (`NotebookStore.WithQueryPin`, `ScopeResolver.Resolve`, `Retriever.SearchAsync`) seed every case into a fresh store, run one hybrid query through a scripted embedding session and must reproduce every expected output exactly. Extends `folder-rag-v1.md` (frozen) without changing it: no schema change, no change to activation, no new UI.*

## 1. Why

The first vector index of a large folder (generation `state='building'`) can take hours. Until `activateBuiltGeneration`, the notebook has no active generation, so retrieval used to be lexical-only for the whole build even though most sources were already embedded (the embed plan embeds documents first and spreadsheets last). This contract lets retrieval read the already completed part of that building generation — only while nothing is active.

## 2. Unchanged

- **An active generation exists** → the pin is exactly as before: the active generation when its storage model key equals the query's key, otherwise no generation (lexical only). A building generation is never read while any generation is active, so an index rebuild with a different model never mixes vector spaces and a same-model rebuild never shadows the active one.
- Lexical retrieval, fusion (integer RRF, `rrfK`), per-branch `fetchK`, revocation re-passes, evidence hydration, the context pack, citations and the evidence budget take the partial pin unchanged. Partial results are a subset of the full index's candidate space; no code path needs to know.
- Activation, the manifest, embedding writes and GC are untouched. A building generation is never retained or retired by a query.

## 3. Pin selection (no active generation)

Inside the query pin's single read transaction, when the notebook has no `state='active'` generation:

1. **Candidate**: the building generation (`state='building'`, same notebook) with the **highest id** whose storage model key (`providerId:model`, bare `model` for `providerId='legacy'`) equals the query's model key byte-for-byte. `failed` and `retired` generations are never candidates. If there is none → no generation.
2. **Vector revisions**: the manifest rows of that generation with `state='done'` whose source is `availability='present'`, `eligible=1`, and whose `revision_id` equals the source's **current** `published_revision_id`. A done row of a superseded revision is ignored (never return stale chunks); a `pending` source contributes nothing even if some of its chunks already have vectors — it remains reachable through the lexical branch.
3. If that set is empty → no generation (lexical only, no provider call, status `noActiveGeneration`).
4. Otherwise the pin carries the building generation id, its model key and dims, and these vector revisions. The vector branch reads exactly the `chunk_embeddings` of that generation whose chunk belongs to a pinned (source, revision) pair — the existing vector SQL, unchanged.

A partial pin has **no matrix cache key**: every vector write of the build bumps the retrieval epoch, so an admitted matrix would be invalidated at once. The vector branch streams bounded pages instead (diagnostics `streamed=true`); ranking is identical.

*Amended 2026-10-11 by `retrieval-resident-v1.md` §5: a partial pin still has no epoch cache key, but it is served by the generation's resident, revision-checked matrix (diagnostics `streamed=false` unless the matrix exceeds the budget); ranking is unchanged.*

## 4. Query embedding

The question is embedded exactly as for an active generation: one session prepared for the pinned generation's full identity (provider, endpoint revision, model, query format; dims checked on the returned vector). Therefore the "same selection" rule is: model key at pin time (§3.1), endpoint revision and query format at session preparation, dims at query-vector validation. Each failure is lexical-only with the existing status and no error beyond existing behaviour:

| Situation | `vectorStatus` | provider calls |
|---|---|---|
| no candidate / no usable rows | `noActiveGeneration` | 0 |
| endpoint revision differs | `endpointRevisionMismatch` | 0 |
| provider unavailable | `embeddingFailed` (+ `embeddingError`, as today) | 1 |
| wrong query dims | `invalidQueryVector` | 1 |
| success | `used` | 1 |

## 5. Fixture

`seed` holds notebook 1 with six sources; every chunk text has three FTS tokens so one-token matches tie on bm25 and order by chunk id. Each case adds `generations`, `manifest` and `embeddings` (integer vectors; both platforms L2-normalize row and query before scoring), the session endpoint revision and a scripted provider (`vector` or `failure`). The query is `query` with `fetchK`/`rrfK` from the envelope and model key `selection.providerId:selection.model`. `expected` lists the pinned generation id/state, vector revisions, `vectorStatus`, provider calls, whether `embeddingError` is set, lexical and vector chunk ids in branch order, and the fused `{chunkId, rrfMicro}` list.

Cases: `no-generation`, `building-partial` (stale revision, pending partial source and missing source ignored), `active-and-building` (active wins), `active-other-model-and-building` (active of another model: unchanged, lexical only), `stale-revision-only`, `mismatched-selection`, `mismatched-endpoint`, `mismatched-dims`, `provider-unavailable`, `newest-building` (highest building id wins; `failed` ignored).

## 6. UI

No new UI. The indexing status strip (`indexing-status-v1`) already reports the build. The chat context preview had no "index not ready" wording, so no string changed.
