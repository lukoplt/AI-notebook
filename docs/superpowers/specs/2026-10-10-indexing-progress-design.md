# Indexing progress for folder RAG — design (2026-10-10)

Part of 0.15.0, branch `feat/ui-redesign`. Both platforms, strict parity.

## Problem

"Scan now" on a folder source gives no visible feedback. Root causes (investigation 2026-10-10):

1. Scan only enqueues a durable `scan` job; the panel never shows `folder_sources.scan_state`.
2. Unchanged files take the mtime+size fast path → no publication → no `embed` job. Embed work is only enqueued inside the extraction publication (and only if an embedding selection exists then), or via `wakeGenerationWork` / Settings › Re-index. A notebook whose vector index was never built stays "Not yet searchable" forever; Scan now cannot fix it.
3. Failures are silent: the embedding-session factory `try?`s away "no provider / disabled / no model / no consent"; Ollama-down retries ~15 min with backoff before the generation is marked failed; `GenerationProgress.errorCode` is never shown; `claimJob`/`failJob`/recover do not post `folderIngestionDidChange`; macOS `FolderIngestionRuntime.start()` sets `started = true` before `reconciler.start()` so a reconciler throw kills all loops silently (error lands in `FolderWatchController.errorMessage`, unread). Windows badge aggregates across all notebooks, any exception shows "failed", and `SourcesViewModel.Apply` wipes `ErrorMessage` on every reload.
4. "Not yet searchable" is misleading: lexical/FTS search works; it means "no active vector index".

## Design

### 1. Core: `IndexingStatus` (per notebook), contract `indexing-status-v1`

Pure derivation function on both platforms from an input snapshot (`IndexingInputs`) that the store can read in one query batch:

Inputs:
- folders: list of `{folderId, scanState (idle|scanning|partial|error|unavailable), lastScanError?, filesSeenThisScan?}`
- extract jobs for the notebook's sources: `queued`, `running`, `failedTerminal` counts; total eligible published+pending sources (`sourcesTotal`), `sourcesReady`, `sourcesError`
- generation progress (existing `GenerationProgress`: done/total/excluded/failed/preparing/hasActive/errorCode)
- embed job retry info: `attempts`, `nextRetryAt?`, `lastErrorCode?` for the notebook's unfinished embed/bootstrap job, if any
- embedding availability: `ready | noProvider | providerDisabled | noModel | consentRequired | providerHasNoEmbeddings`
- `now`

Output `IndexingStatus`:
- `phase`: one of
  - `scanning` (any folder scan_state == scanning, or a queued/running scan job) — `filesSeen?`
  - `extracting` — `done`, `total` (extract queued+running > 0)
  - `embedding` — `done`, `total` (generation building or bootstrap preparing; `preparing: Bool`)
  - `retrying` — `code`, `retryAt`, `attempt` (embed job waiting for next_retry_at)
  - `blocked` — `reason`: `noEmbeddingModel` (noProvider|noModel|providerHasNoEmbeddings), `providerDisabled`, `consentRequired`, `indexFailed(code)` (terminal failure)
  - `ready` — vector index active and nothing pending
  - `lexicalOnly` — nothing running, no active vector index and no reason known (should be rare after fix 3)
  - `empty` — notebook has no sources
- `sourceErrors`: count of sources with status error
- `scanWarnings`: folders with scan_state error/unavailable/partial (+ message key)
- `isActive: Bool` (scanning|extracting|embedding|retrying) for the right-panel toggle dot

Priority when several apply: scanning > extracting > embedding > retrying > blocked > ready > lexicalOnly > empty. Shared fixture `Tests/fixtures/contracts/indexing-status-v1.json` (Python reference generator `tools/contracts/gen_indexing_status_fixtures.py --check`), consumed by `swift test` and the .NET Core tests like the other contract fixtures.

Store API (both): `indexingStatus(notebookId:) -> IndexingStatus` (reads inputs + calls the pure function); runtime exposes embedding availability (see 3).

### 2. Live updates

Post `folderIngestionDidChange` / `FolderIngestionChanged` (with notebookId) from `claimJob`, `failJob`, `recoverExpiredJobs`, `requeueRetryableJobs`, `cancelOwnedExtraction`, `completeEmptyBootstrap` (per affected notebook; coalesced is fine). UI keeps its 1 s poll as fallback while `isActive`.

### 3. Behaviour fixes

- After `finishFolderScan` (and on runtime start / reconcile), if `notebookNeedsEmbedding(notebookId)` and no unfinished embed/bootstrap job exists and an embedding selection is available → `requestIncrementalBuild`. Scan now therefore always (re)builds a missing index.
- Embedding-session factory returns a reason instead of nil (`EmbeddingAvailability`), surfaced via runtime (`embeddingAvailability(notebookId)`), used by IndexingStatus. Keychain/secret errors must not fail extraction jobs: extraction publishes and the reason becomes `blocked`.
- "Retry now": runtime API `retryIndexingNow(notebookId)` → clears `next_retry_at` of the notebook's waiting embed job (or re-queues a terminally failed/cancelled one via incremental build) and wakes loops.
- macOS `FolderIngestionRuntime.start()`: set `started` only after successful start; a start failure is exposed as runtime `startError` and shown in the UI status (`blocked(reason: runtimeFailed)` — add this reason).
- Windows: badge per current notebook (not aggregate); exceptions show a real error, not "failed"; `SourcesViewModel` must not wipe a fresh action error on the follow-up reload; set `ErrorMessage` on UI thread.

### 4. UI (Sources panel, both platforms)

- **Status strip** at top of Sources panel (replaces the "Not yet searchable" header badge): icon + text + thin determinate progress bar when done/total known, indeterminate otherwise.
  - scanning: "Checking folder… N files"
  - extracting: "Processing files d / t"
  - embedding: "Indexing d / t chunks" (preparing: "Preparing index…")
  - retrying: "Embedding provider unavailable — retrying in Ns" + button "Retry now"
  - blocked noEmbeddingModel/providerDisabled/consentRequired: explanatory text + button "Open settings" (Settings › Providers or Indexing)
  - blocked indexFailed / runtimeFailed: "Indexing failed (code)" + "Retry now"
  - ready: "Searchable · N files" (quiet, text-3)
  - lexicalOnly: "Full-text search only" + "Build index" button
- **Folder row**: spinner + "Checking…" immediately on Scan now (optimistic local state until the next status shows scanning or a scan finished); after a scan with no changes, transient caption "No changes · N files up to date" (~4 s). Show scan warnings (partial/error/unavailable) with text.
- **Source rows**: status `error` shows the error text (tooltip/secondary line).
- **Right panel toggle** (top bar): small dot when `isActive` or blocked while the panel is closed.
- Strings EN/CS both platforms (Czech uses "notebook", not "blok"); string parity script must pass.

## Testing

- Shared fixture for the pure derivation (all phases, priority ordering, retry countdown, blocked reasons).
- Store tests (both): notifications from claim/fail/recover; Scan now on an unchanged folder with no active generation enqueues a build; availability reasons; retryIndexingNow; extraction succeeds when the secret load throws.
- UI: Swift view-model tests where feasible; Windows App.Tests for SourcesViewModel status mapping, error-not-wiped, per-notebook badge.
