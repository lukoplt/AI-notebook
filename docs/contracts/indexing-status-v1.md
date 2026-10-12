# Indexing status — normative contract v1

*Status: 0.15.0 (2026-10-10). Spec: `docs/superpowers/specs/2026-10-10-indexing-progress-design.md` §1–3. Fixture: `Tests/fixtures/contracts/indexing-status-v1.json`. Executable reference: `tools/contracts/gen_indexing_status_fixtures.py` (`--check` must pass). Swift (`IndexingStatus.derive`) and C# (`IndexingStatusDerivation.Derive`) must reproduce every case exactly.*

One status per notebook, derived by a **pure function** from an input snapshot that the store reads in one read batch, plus two runtime facts (embedding availability, runtime start error). Times are integer epoch seconds (the ingestion lease clock).

## 1. Inputs (`IndexingInputs`)

| Field | Meaning (store query, notebook-scoped) |
|---|---|
| `now` | lease clock seconds |
| `runtimeError` | runtime start error code, or null (runtime fact) |
| `embeddingAvailability` | §4, runtime fact |
| `folders[]` | every folder of the notebook in id order: `folderId`, `scanState` (`idle\|scanning\|partial\|error\|unavailable`), `lastScanError`, `filesSeen` (scanning folders only: `scan_items` rows with `seen_generation = scan_generation`; null otherwise) |
| `scanJobsPending` | scan jobs of the notebook's folders in state `queued` or `running` |
| `extractQueued`, `extractRunning` | extract jobs of the notebook's sources in state `queued` / `running` |
| `sourcesTotal` | sources with `availability='present' AND eligible=1` |
| `sourcesReady`, `sourcesError` | of those, `status='ready'` / `status='error'` |
| `needsEmbedding` | an eligible present source has a published revision with chunks that is not `done` in the active generation (`notebookNeedsEmbedding`) |
| `embedJob` | the notebook's newest embed job (target `notebook:N` or a generation of N, highest id) as `{state, attempts, nextRetryAt, errorCode, bootstrap}` (`bootstrap` = notebook target), or null |
| `embedChunksDone`, `embedChunksTotal` | for a generation-target `embedJob`: embeddable chunks (`embedding-plan-v1` §3: capped spreadsheet rows excluded) of that generation's non-excluded manifest revisions, and how many of them have a vector in that generation; 0/0 otherwise |

## 2. Derivation (first match wins)

1. `runtimeError` ≠ null → `blocked(runtimeFailed)`, `errorCode = runtimeError`. *(Deviation from the spec's priority list: a runtime that never started runs nothing, so queued work must not read as progress.)*
2. a folder is `scanning` or `scanJobsPending > 0` → `scanning`; `filesSeen` = sum of non-null `filesSeen` of scanning folders, null when none is known.
3. `extractQueued + extractRunning > 0` → `extracting`; `total = sourcesTotal`, `done = min(total, sourcesReady + sourcesError)`.
4. `embedJob` **waiting** := (`state='failed'` ∧ `attempts < 5` ∧ `nextRetryAt` ≠ null) ∨ (`state='queued'` ∧ `nextRetryAt` ≠ null ∧ `nextRetryAt > now`).
   - not waiting and `state ∈ {running, queued}` → `embedding`: bootstrap → `preparing = true`, done/total null; else `embedChunksTotal ≤ 0` → done/total null; else `total = embedChunksTotal`, `done = min(total, embedChunksDone)`.
   - waiting → `retrying` with `retry = {code: errorCode ?? "unknown", retryAt: nextRetryAt, attempt: attempts, retryInSeconds: max(0, nextRetryAt − now)}`.
5. `sourcesTotal = 0` → `empty`.
6. `embeddingAvailability ≠ ready` → `blocked` with reason: `noProvider|noModel|providerHasNoEmbeddings → noEmbeddingModel`; `providerDisabled`; `consentRequired`; `credentialUnavailable`. (Applies even when the index is current: question embedding needs the provider too.)
7. `embedJob.state = 'failed'` and not waiting (terminal) and `needsEmbedding` → `blocked(indexFailed)`, `errorCode = errorCode ?? "unknown"`.
8. `needsEmbedding = false` → `ready`.
9. otherwise → `lexicalOnly` (full-text search works; no current vector index and no known reason — "Build index" = `retryIndexingNow`).

## 3. Output (`IndexingStatus`, canonical fixture projection)

`{phase, filesSeen, done, total, preparing, retry, blockedReason, errorCode, memoryPressure, sourceErrors, scanWarnings, isActive}` (`memoryPressure`: addendum §6) — every key present, null when not applicable, `preparing` false unless set.

- `phase ∈ scanning|extracting|embedding|retrying|blocked|ready|lexicalOnly|empty`.
- `blockedReason ∈ noEmbeddingModel|providerDisabled|consentRequired|credentialUnavailable|indexFailed|runtimeFailed` (only with `blocked`); `errorCode` only with `indexFailed`/`runtimeFailed`.
- `sourceErrors = sourcesError` (always).
- `scanWarnings` = folders (input order) whose `scanState ∈ partial|error|unavailable`: `{folderId, state, error: lastScanError}` (always, independent of phase).
- `isActive = phase ∈ {scanning, extracting, embedding, retrying}` (UI polls ~1 s while active; right-panel dot).

`done`/`total` of `embedding` count **chunks**; of `extracting` count **sources**.

## 4. Embedding availability (`operation: "availability"`)

The embedding-session factory returns a reason instead of nil. Checks, in order: no configured provider → `noProvider`; provider type has no embeddings endpoint → `providerHasNoEmbeddings`; disabled → `providerDisabled`; blank model (whitespace-trimmed) → `noModel`; cloud provider without privacy acknowledgement → `consentRequired`; loading the API key throws → `credentialUnavailable`; otherwise `ready`. Any other capture error (e.g. malformed endpoint) maps to `noProvider`. The key is loaded only after every earlier check passed.

A `credentialUnavailable` selection is treated as "no selection" by extraction: the extraction still publishes (no embed job) and the status shows `blocked(credentialUnavailable)`; embed jobs that capture a session fail with the retryable code `credentialUnavailable`.

## 5. Behaviour (store/runtime, both platforms; not fixture-driven)

- Live updates: a status signal — macOS `Notification.Name.indexingStatusDidChange` (`userInfo["notebookId"]`), Windows `NotebookStore.IndexingStatusChanged(notebookId)` — fires after every `folderIngestionDidChange` / `FolderIngestionChanged` and additionally after a committed claim, fenced failure, lease recovery, retry requeue, fenced/user cancel, exhausted-job retry, fenced completion (empty bootstrap) and runtime start/scan outcomes (once per affected notebook). *Deviation from the spec text ("post `folderIngestionDidChange` from claim/fail/…"): `ingestion-pipeline-v1.json` (frozen) asserts that lease expiry and re-claim post no `folderIngestionDidChange`, so job-lifecycle changes use the status-only signal. UIs observe `indexingStatusDidChange` / `IndexingStatusChanged` for indexing progress.*
- Embedding batch commits post only the status signal (no `folderIngestionDidChange` / `FolderIngestionChanged`), coalesced to at most one per second per notebook: one immediately, plus one trailing post so the last batch is never missed. Bootstrap, activation, failure and invalidation post immediately. UIs keep a 1 s poll while `isActive`.
- After each finished scan job and on runtime start, `ensureIndexBuild(notebookId)`: when `needsEmbedding`, no **unfinished** embed job exists (`queued|running|paused`, or `failed` with an automatic retry pending) and a session is available → incremental build. Scan now therefore builds a missing index on an unchanged folder.
- `retryIndexingNow(notebookId)`: restarts a failed runtime start; makes the notebook's waiting embed job due now (failed-with-retry → queued, queued-with-future-deadline → deadline cleared); otherwise `ensureIndexBuild`.
- A building generation whose remaining pending manifest rows cannot be embedded yet (a source whose current revision is not published) defers activation and ends the attempt instead of re-polling (macOS previously spun; now matches Windows). Lease recovery or the next publication resumes the build.
- Runtime start sets `started` only after the reconciler started; a failure is kept as `startError` (code) and surfaces as `blocked(runtimeFailed)`.
- `lastScanOutcome(folderId)` (runtime memory, not durable): `{folderId, changedFiles, filesSeen, finishedAt}` of the last finished scan job — `changedFiles` = extract jobs queued for the folder's sources during that scan, `filesSeen` = eligible `scan_items` seen in the folder's current scan generation.

## 6. Addendum 0.15.1 — memory pressure (`ingestion-memory-pressure-v1`)

*Additive; every earlier rule is unchanged. Fixture and reference generator are the same files; every derive case now carries the new input and output key.*

- **Input** `memoryPressure ∈ normal|warning|critical` (runtime fact, default `normal`): extraction admission's current level, which the runtime re-samples on every scheduler tick (`ingestion-memory-pressure-v1` §3). macOS `FolderIngestionRuntime.indexingStatus` / Windows `IndexingStatusAsync` read it from `IngestionAdmission` (`memoryPressureLevel` / `PressureLevel`); the store's own `indexingStatus(…)` leaves it `normal`.
- **Output** `memoryPressure`: the input level when the derived phase is `extracting` and the level is not `normal`; `null` otherwise (scanning, embedding, blocked, ready … never carry it — only extraction is gated). Phase, counts and `isActive` are unaffected, so the strip keeps polling and clears the notice on the first status after pressure drops.
- **Strip**: `warning` → `indexingExtractingSlowed` ("Processing files d / t · slowed, the system is low on memory"), file icon, active tone; `critical` → `indexingExtractingPaused` ("Paused: the system is low on memory · files d / t"), warning icon and tone, progress bar kept, no action. Both platforms, EN/CS.

## 7. Addendum 0.15.2 — a scan never hides indexing progress (`ingestion-scan-perf-v1`)

*Same fixture and reference generator; every derive case now carries the new output key. Two existing cases change phase on purpose — `scanning-beats-extracting` and `scanning-ignores-memory-pressure` now derive `extracting` (names kept for traceability); seven `scan-*` cases were added.*

- **Output** `scanInProgress` (bool, always present, default false).
- **Derivation step 2** becomes: a folder is `scanning` or `scanJobsPending > 0` → `filesSeen` = sum of the scanning folders' non-null `filesSeen` (null when none is known); then, if step 3 (`extracting`) or the non-waiting part of step 4 (`embedding`) applies, that phase is the result with `scanInProgress = true` and that `filesSeen`; otherwise `scanning(filesSeen)` with `scanInProgress = true`. A waiting embed job (`retrying`) stays behind the scan as before. Step 1 (`runtimeFailed`) still wins and reports `scanInProgress = false`.
- **Projection**: `filesSeen` is the scan's count whenever `scanInProgress` (also for `extracting`/`embedding`), null otherwise. `memoryPressure`, `done`/`total`, `preparing` and `isActive` follow the derived phase unchanged.
- Swift `IndexingStatus.scanInProgress` / `scanFilesSeen`; C# `IndexingStatus.ScanInProgress` / `FilesSeen`.
- **Strip**: an `extracting`/`embedding` line with `scanInProgress` keeps its icon, tone and progress bar and appends the scan: `indexingWithScan` = "{status} · checking folder…" / "{status} · kontroluji složku…" (e.g. "Indexing 210 / 530 chunks · checking folder…"). The `scanning` line is unchanged. Both platforms, EN/CS.

## 8. Addendum 0.15.3 — the embed job behind the status (`ingestion-build-merge-v1`)

*Same fixture and reference generator; new operation `embedJob`. Every derive case and every earlier rule is unchanged except §1 `embedJob` / `embedChunksDone` / `embedChunksTotal`, which this section replaces.*

- **Candidates**: the notebook's embed jobs (target `notebook:N` or a generation of N). A job is **unfinished** when `queued|running|paused`, or `failed` with `attempts < 5` and `nextRetryAt ≠ null`.
- **Selection**: a `running` job first, then any other unfinished job, then finished jobs; the highest id within a class. *(Before: the highest id overall — a bootstrap queued behind a running generation build hid that build's progress behind "Preparing index…".)*
- **`bootstrap`** = the selected job targets `notebook:N` **unless** its options decode with `copyExisting = true` and a `building` generation of the notebook is compatible with its selection (`ingestion-build-merge-v1` §1): then `bootstrap = false` and that generation (the newest such) feeds the counts. *("Preparing" only while no generation exists for the selection.)*
- **Progress generation**: the selected job's target generation, or the one adopted above; null otherwise. `embedChunksDone` / `embedChunksTotal` are counted on it exactly as in §1; 0/0 when null.
- **Fixture** (`operation: "embedJob"`): input `{jobs: [{id, target, state, attempts, nextRetryAt, error, options: {copyExisting, selection} | null}], generations: [{id, state, identity}]}`; expected `{embedJob: {state, attempts, nextRetryAt, errorCode, bootstrap} | null, progressGenerationId}`. A store may pass only the unfinished jobs plus the newest job — the result is the same.
- **`generationProgress`** (Settings › index builds; not fixture-driven) uses the same selected job: `preparing` = unfinished ∧ `bootstrap`; `jobId` = the selected job (so "Discard build" targets the running build, not a queued bootstrap).
