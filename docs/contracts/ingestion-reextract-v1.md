# Re-extraction after an extractor upgrade — normative contract v1

*Status: 0.15.0 (2026-10-10); §7 addendum 2026-10-11 (fixture `ingestion-reextract-v2.json`, same generator; the v1 fixture is unchanged). Fixture: `Tests/fixtures/contracts/ingestion-reextract-v1.json`. Executable reference: `tools/contracts/gen_reextract_fixtures.py` (`--check` must pass). Swift (`NotebookStore.requeueUpgradedExtractions`, `ExtractorRevision`) and C# (`NotebookStore.RequeueUpgradedExtractions`, `ExtractorRevision`) seed every case into a fresh store and must reproduce it exactly. Extends `folder-rag-v1.md` (frozen) without changing it: no schema change, no change to existing job options. **Addendum 2026-10-11:** `ingestion-retry-cap-v1.md` §6 amends §2 and §4 — a source whose extraction was given up after three failed attempts is neither re-read by scans nor requeued after an upgrade; only an explicit retry or a content change extracts it again (v1/v2 fixtures unchanged, new cases in `ingestion-retry-cap-v1.json`).*

## 1. Why

An extract job that fails five times is terminal (`folder-rag-v1` §1b) and the source stays `status='error'`. When a later release fixes the bounded extractor (revision 2: the OOXML/ZIP fixes of b543919, cafa154, c9d6cfd, 857e2d1), those sources should be retried once with the new extractor without the user touching every file.

## 2. What already retries (unchanged)

- **Every folder scan** — plain, Verify all, watcher-triggered or periodic — re-reads a source whose `status` is not `ready`: the metadata fast path (`FolderScanner.canSkipRead` / `FolderFastPath`) requires `status='ready'` and a current published revision. Unchanged bytes are hashed, and a source with no committed hash (never published) or a different hash gets a new extract job (`requireExtraction`). Verify all is therefore an explicit manual retry for every failed source. If the hash equals the committed hash of the current published revision, the source returns to `ready` without extraction (the published text already matches the file).
- Watch-enabled folders are scanned at runtime start and every 30 minutes (every 6 hours while their native watch is healthy, `ingestion-scan-perf-v1` §4), so their failed sources are retried then.
- Settings › Re-index (`requestReindex`) only rebuilds embeddings; it never re-extracts.

The new rule below covers folders that are **not** watched (they are never scanned automatically) and makes the upgrade retry independent of scans.

## 3. Constants

| Name | Value |
|---|---|
| `ExtractorRevision.current` | `2` (implicit revision of every job without the option: `1`) |
| `optionsKey` | `"extractorRevision"` |
| `retryableCodes` | `corruptArchive`, `invalidCell`, `invalidRelationship`, `missingMainPart`, `unexpectedError` |

Bump `current` whenever an extractor change may turn a former failure into a publication for unchanged bytes; adjust `retryableCodes` to the failures that change can resolve. Limit, encoding, path, `notDownloaded`, `cancelled` and `leaseExpired` failures are not extractor failures and are never requeued by this rule (scans still retry them, §2).

## 4. Upgrade requeue

`requeueUpgradedExtractions(now)` runs in one write transaction during reconciler recovery — at runtime start and on every periodic reconciliation, after lease recovery and the due-retry requeue, before watched folders are scheduled. A source qualifies when all hold:

1. `folder_id IS NOT NULL` (loose sources are not re-extracted by the folder worker);
2. `status='error'` and `error ∈ retryableCodes`;
3. `availability='present'` and `eligible=1`;
4. no **unfinished** extract job for `source:<id>`: `state ∈ {queued, running, paused}` or (`state='failed'` ∧ `attempts<5` ∧ `next_retry_at` not null);
5. no extract job for `source:<id>` whose revision is `≥ current`. A job's revision is the integer value of `options_json.extractorRevision`; absent, non-integer or unparsable options mean `1`.

For each qualifying source in ascending id order: enqueue `{kind:'extract', target:'source:<id>', target_revision: sources.current_revision, options_json:'{"extractorRevision":<current>}'}` with `state='queued'`, `attempts=0`, `next_retry_at=NULL` (immediately due), and set the source `status='pending'`, `error=NULL`. The published pointer is untouched (a failed refresh keeps its old published revision searchable). Returns the number of requeued sources.

Because the requeued job carries the current revision, a failure under the current extractor is never requeued again by this rule (exactly once per source per revision). Other extract jobs keep their options unchanged (`{}`), so a source first created and failed after the upgrade is requeued once on the next reconciliation — a bounded extra attempt.

## 5. Live updates and indexing

After commit, `folderIngestionDidChange` / `FolderIngestionChanged` is posted once per affected notebook in ascending id order, which also posts `indexingStatusDidChange` / `IndexingStatusChanged`. Nothing is posted when no source qualifies. A requeued source is then extracted by the ordinary worker; its publication queues embedding with the selected embedding session exactly like any other folder publication, and the runtime's start-time `ensureIndexBuild` covers a missing index.

## 6. Fixture

`{contract, version, extractorRevision, optionsKey, retryableCodes, seed{notebookId, folder}, cases[{name, input{source, revisions, jobs, now}, expected{requeued, source{status, error}, newJob|null, notified}}]}`. Platforms insert the notebook, folder (watch disabled), source, revisions and jobs with the given ids, call the requeue once, and compare the count, notifications (both events), the source status/error and the single new job (`kind, target, targetRevision, state, attempts, nextRetryAt, error, options`; options compared as canonical JSON).

## 7. Addendum (v2): spreadsheet canonical text upgrade

`ingestion-xlsx-v2.md` changes the canonical text of every XLSX/XLSM revision (`text_format_version` 2). Already published spreadsheets were produced with format 1; they are re-extracted once, in throttled batches, so the queue is never flooded and every published revision stays searchable until its replacement is published. No schema change: the producing format is the existing `source_revisions.text_format_version`, and the job stamp lives in `ingest_jobs.options_json`.

**Constants** (`ExtractorRevision`): `spreadsheetTextVersion = 2` (= `SpreadsheetText.formatVersion`), `spreadsheetOptionsKey = "spreadsheetTextVersion"`, `spreadsheetBatchSize = 8`. A job's *spreadsheet stamp* is the integer value of `options_json.spreadsheetTextVersion`; absent, non-integer or unparsable options mean `0`. A job is *unfinished* as in §4 rule 4.

**`requeueSpreadsheetUpgrades(now)`** runs in one write transaction:

1. `outstanding` = number of unfinished extract jobs (any source) whose stamp is `≥ spreadsheetTextVersion`; `room = spreadsheetBatchSize − outstanding`. If `room ≤ 0`, nothing happens.
2. A source qualifies when all hold: `folder_id IS NOT NULL` (loose spreadsheets keep their text until re-ingested); `type = 'xlsx'` (XLSM sources have type `xlsx`); `status = 'ready'`; `availability = 'present'`, `eligible = 1`; it has a published revision, `current_revision = published_revision_id` (no newer revision pending), and that revision's `text_format_version < spreadsheetTextVersion`; it has no unfinished extract job; and it has no extract job in state `failed` whose stamp is `≥ spreadsheetTextVersion` (an upgrade that failed — terminally or after its automatic retries — is not repeated).
3. The first `room` qualifying sources in ascending id each get `{kind:'extract', target:'source:<id>', target_revision: sources.current_revision, options_json:'{"spreadsheetTextVersion":2}'}`, `state='queued'`, `attempts=0`, `next_retry_at=NULL`. **The source row is not changed**: it stays `ready` with its published pointer, so scans keep fast-pathing it (a pending/failed source would be re-hashed and, with unchanged bytes, have its refresh cancelled — `folder-rag-v1` scan rules), retrieval keeps serving the format-1 revision, and the ordinary publication replaces it. A claim marks the source `chunking` as for every extraction; a failure marks it `error` while the old revision stays searchable.
4. After commit, `folderIngestionDidChange` / `FolderIngestionChanged` is posted once per affected notebook in ascending id order (which also posts the indexing-status change). Returns the number of requeued sources.

**When it runs:** at runtime start and on every periodic reconciliation, right after `requeueUpgradedExtractions` (§4), and after every finished extract job whose options carry the spreadsheet stamp (published, superseded or failed), so the batch refills as extraction drains instead of waiting 30 minutes. Each publication queues incremental embedding as usual; the new, smaller revision replaces the old one in the next build.

**Bounded retries.** A cancelled upgrade job (user cancel, superseded by a newer scan) does not block a later requeue, but the source is only reconsidered once it is `ready` again; a failed upgrade is never repeated by this rule; such a source keeps its searchable format-1 revision until its file changes (a scan then re-extracts it through the ordinary path).

**Fixture** `ingestion-reextract-v2.json`: `{contract, version: 2, spreadsheetTextVersion, spreadsheetOptionsKey, batchSize, seed{notebooks, folders}, cases[{name, input{sources[], revisions[], jobs[], now}, expected{requeued, newJobs[], sources[{id,status,error}], notified}}]}`. Jobs may carry `leaseToken`/`leaseUntil` (running jobs). Platforms seed every row with its id, call `requeueSpreadsheetUpgrades` once and compare the count, notifications, every source's status/error and the created jobs in id order (`kind, target, targetRevision, state, attempts, nextRetryAt, error, options` as canonical JSON).
