# Ingestion build merge — normative contract v1

*Status: 0.15.3 (2026-10-12). Fixture: `Tests/fixtures/contracts/ingestion-build-merge-v1.json`. Executable reference: `tools/contracts/gen_build_merge_fixtures.py` (`--check` must pass). Swift (`EmbedJobPlanning`, `IngestionGenerationSQL.enqueueBuild`, `NotebookStore.mergeRedundantBootstraps`) and C# (`EmbedJobPlanning`, `IngestionGenerationSQL.QueueEmbedding`, `NotebookStore.MergeRedundantBootstraps`) must reproduce every case exactly. Addendum to the generation build rules of `folder-rag-v1.md` and `ingestion-generations-v1.json` (both frozen, unchanged) and to `embedding-plan-v1.md`; no schema change.*

## 0. Problem

A raw provider selection (e.g. Ollama `nomic-embed-text`) carries no verified dimensions (`dims = null`). Every publication of such a selection queued a notebook-target **bootstrap** job (`notebook:N`), even while a generation of the same vector space was already building. The indexing strip read the newest embed job and showed "Preparing index…" for the whole build; after the build activated, the bootstrap probed the provider again and built a redundant second generation (copying every vector of the first).

## 1. Definitions

- **Compatible** (selection `s`, generation identity `g`): `providerId`, `endpointRevision`, `model`, `modelDigest` (null = null), `normalization`, `queryFormatVersion`, `docFormatVersion`, `chunkerVersion` byte-equal, and `s.dims` null or equal to `g.dims` (same rule as `FolderEmbeddingSession.compatible`).
- **Unclaimed bootstrap**: an embed job with target `notebook:N` in state `queued` or `paused`, or `failed` with `attempts < 5` and `nextRetryAt ≠ null`. A `running` bootstrap is owned and never touched.
- **Incremental bootstrap**: its options decode and `copyExisting = true`. An explicit re-index bootstrap (`copyExisting = false`) or undecodable options are never merged or superseded.

## 2. `resolve` — a build request adopts a verified identity

A build request (`enqueueBuild` / `QueueEmbedding`: publications, incremental builds, raw-format upgrades) with unknown dimensions (`dims` null or ≤ 0) and `copyExisting = true` adopts the identity of the **newest compatible `building` generation** of the notebook, else of the **compatible `active` generation**, else none. With an adopted identity the request takes the verified-dimension path unchanged: `ensureBuilding` (reuse the building generation, or a new one that copies unchanged vectors from the identical active one) and **one generation-target job** (an unfinished job of that generation is reused — the running build re-reads the pending manifest every round, so a newly published revision is covered). Without one, a bootstrap is queued as before. Known dimensions and `copyExisting = false` are unchanged.

## 3. `supersede` — no bootstrap beside a generation job

Whenever a request ends with a generation-target job for identity `g` (§2 or known dimensions), every unclaimed incremental bootstrap of the same notebook compatible with `g` completes as a **no-op** in the same transaction: `state='done'`, `error`, `next_retry_at` and the lease cleared. Fixture: the superseded job IDs in ascending order.

## 4. `startup` — existing databases

Runtime start (and every reconcile pass that recovers jobs: after `repairOrphanScans`, before `requeueUpgradedExtractions`) visits every unclaimed bootstrap in id order with the notebook's current generations and `needsEmbedding` (`indexing-status-v1` §1):

| Condition | Action |
|---|---|
| not an unclaimed incremental bootstrap | `keep` |
| `resolve` finds a `building` generation | `merge` |
| `resolve` finds the `active` generation and `needsEmbedding` | `merge` |
| `resolve` finds the `active` generation, nothing to embed | `noop` |
| no compatible generation | `keep` |

`merge` runs the §2 request with the bootstrap's selection (`copyExisting = true`) — joining the building generation's job, or starting one build beside the active generation — and completes the bootstrap as in §3; `noop` only completes it. Changed notebooks post `folderIngestionDidChange` / `FolderIngestionChanged`. A bootstrap is never turned into a second generation of a space that is already building.

## 5. Behaviour (store/runtime, both platforms; not fixture-driven)

- A publication during a running raw-provider build leaves exactly one unfinished embed job (the generation job); activation happens once and no second generation is created.
- The indexing status (`indexing-status-v1` §8) shows "Indexing d / t chunks" throughout such a build.
