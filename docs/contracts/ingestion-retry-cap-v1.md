# Extraction failure budget — normative contract v1

*Status: 2026-10-11; loose sources and §1a supersession added 2026-10-11 (user decision: loose files follow the same rule). Fixture: `Tests/fixtures/contracts/ingestion-retry-cap-v1.json`. Executable reference: `tools/contracts/gen_retry_cap_fixtures.py` (`--check` must pass). Swift (`NotebookStore`, `ExtractionRetryBudget`, `RetryBudgetSQL`) and C# (`NotebookStore`, `ExtractionRetryBudget`) run every case against a fresh store and must reproduce it exactly. Extends `folder-rag-v1.md` and `ingestion-reextract-v1.md` (both frozen, fixtures unchanged) — §6 is the addendum to the re-extraction contract. Schema v21 (`v21_extract_retry_budget`).*

## 1. Rule

"If a file fails, try three times and that's it." A source — folder member or loose file — whose extraction failed three times for the same content is **given up**: it stays `status='error'` with its last error code, scans treat it as settled (no read, no new extract job) and no automatic path re-queues it. It is extracted again only when its content changes or the user explicitly retries it.

| Name | Value |
|---|---|
| `failureBudget` (`ExtractionRetryBudget.failures`) | `3` failed attempts per source and content (notes excluded) |
| `extractMaxAttempts` (`ExtractionRetryBudget.extractMaxAttempts`) | `3` attempts of every extract job (folder, loose and note sources) |
| every other job (scan, embed, gc) | `5` attempts (unchanged, `folder-rag-v1` §1b) |

### 1a. Supersession of frozen job fixtures

`job-transitions-v1`, `storage-jobs-revisions-v1` and `storage-job-handoff-v1` pinned five attempts for extract jobs (their sources are loose). Those files stay byte-identical; the `supersedes` map of `ingestion-retry-cap-v1.json` (`{fixture file: {case name: whole replacement case}}`, same pattern as `ingestion-xlsx-v2`) replaces exactly the cases whose expectation changes, and every platform harness of those fixtures applies it (`RetryCapSupersession`). The generator re-runs each modelled frozen case through an oracle with the attempt cap as a parameter: with five it must reproduce the frozen case exactly (an edited frozen case fails the generator), with three the differing cases must equal the declared list:

| Frozen fixture | Superseded cases |
|---|---|
| `job-transitions-v1.json` | `fourth-failure-backoff-480-seconds` (terminal, no retry) |
| `storage-jobs-revisions-v1.json` | `exhaustion`, `expired-fifth` (three claims; later retries/claims rejected; `startTimes`/`retryTimes`/`expectedClaims` follow — `retryTimes` lists the deadline of each accepted failure) |
| `storage-job-handoff-v1.json` | the 16 `terminal-{failure,expiry}-{initial,refresh}-{current,newer-revision,newer-failed-job,newer-running-job}` traces |

A queued legacy extract job that already has three or four attempts may still be claimed (claim keeps `attempts<5`, `fifth-attempt-may-start` unchanged); its next failure is terminal.

## 2. Schema v21

```sql
CREATE TABLE source_extract_budget (
 source_id INTEGER PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
 failures INTEGER NOT NULL DEFAULT 0 CHECK(failures>=0),
 content_hash TEXT CHECK(content_hash IS NULL OR length(content_hash)>0)
);
```

A separate table, not columns on `sources`: the frozen `storage-v19` schema queries pin `pragma_table_info('sources')`. An absent row means `failures = 0` and an unknown content hash. **No backfill**: a source that failed before v21 starts with an empty budget, i.e. it gets at most three more attempts under the new rule (the next scan or the upgrade requeue triggers them).

*Given up* := `sources.status='error' AND failures >= failureBudget` (`RetryBudgetSQL.gaveUpPredicate`). `content_hash` is the SHA-256 of the content the budget applies to; NULL means only the stored `sources.mtime`/`size_bytes` stamp identifies it.

## 3. Counting failed attempts

In the transaction of `failJob` and of lease recovery (`recoverExpiredJobs`, also run by every claim), for an extract job of any non-note source:

1. If the job still owns the source status — `sources.current_revision IS job.target_revision` and no newer extract job of the same target has `attempts > 0` (the existing ownership rule) — the source's `failures` increases by one (row created when absent). A lease expiry counts: an extractor that crashes the process is exactly the file that must stop being retried.
2. The job is **exhausted** when `job.attempts >= extractMaxAttempts`, or when step 1 incremented and `failures >= failureBudget`. Attempts are therefore counted across jobs: a job a scan created after two failures of an earlier job is exhausted by its first failure.
3. An exhausted job becomes `failed` with `next_retry_at = NULL`; an owned source becomes `status='error'`, `error=<code>` (`leaseExpired` for lease recovery). A job that is not exhausted keeps the frozen behaviour: `failJob` → `failed`, retry at `now + 30·2^attempts`, source `error`; lease recovery → `queued` with that retry, source `pending`.

### 3a. Loose sources

Loose (non-folder) sources are counted exactly like folder members. Their automatic retries run in the folder worker, which — instead of cancelling a loose source's claimed retry as before — re-reads it:

- a loose file (`raw_path`, any type but `web`/`note`): the bounded canonical pipeline loose ingestion uses (`FolderRules.defaults`, streaming hash, language detection, `publishLooseExtraction`);
- a web source (`uri`): **only an explicit user action fetches** (user decision 2026-10-11, switch `ExtractionRetryBudget.backgroundWebRetry` / `BackgroundWebRetry` = `false`). The production worker always has the web extractor (`WebExtractor` / `WebTextExtractor`) but uses it only for the first attempt of a job queued by an explicit Retry (`options_json` `{"userRetry":true}`, §5), then the legacy revision assembly + `commitExtraction`. A loose web source's failed attempt is never retried automatically: `failJob`/lease recovery end its job terminally (no retry deadline) while the failure still counts (§3). Any other claimed URL job (e.g. a retry queued before this rule) is abandoned as below — no fetch, no attempt counted. With the switch on, every claimed URL job would be fetched and failures retried like files;
- anything else (pasted text without a file or URL): `abandonLooseExtraction` ends the owned job terminally (`failed`, no retry, error `retryUnavailable`, **no attempt counted**) and an owned source becomes `error`/`retryUnavailable` instead of staying `chunking`.

A foreground (re)ingestion (`beginExtraction`: add, re-ingest/refresh, note save) is a user action: a spent budget starts over, otherwise the attempt counts (§5). The extractor-upgrade requeue (§6) stays folder-only.

The `unfinished` predicate (`state ∈ {queued,running,paused}` or `failed ∧ attempts<5 ∧ next_retry_at` not null) is unchanged: an exhausted extract job has no retry deadline and is never unfinished.

## 4. Scans

**Fast path.** `FolderScanner.canSkipRead` / `FolderKnownSource.FastPath` (and the store's `FolderFastPath`) also skip the read of a given-up source whose stored mtime and size equal the observed stamp (no hashing; a batch row is only `seen_generation`-bumped). Verify all never skips.

**Content identity** (`observe`, for an existing eligible source after the frozen "committed bytes are on disk" rule):

- observed hash `H` (the file was read): same content when `content_hash = H`, or when `content_hash` is NULL and the stamp is unchanged (the hash is then recorded); otherwise the content changed: `failures = 0`, `content_hash = H`.
- no observed hash (fast path): same content when the stamp is unchanged; otherwise `failures = 0`, `content_hash = NULL`.

A new folder source records its observed hash with `failures = 0`.

**Queuing.** `requireExtraction` queues nothing for a source whose `failures >= failureBudget` (whatever the caller: scan, rule change, re-eligibility). So a plain scan, Verify all, a watcher event, the periodic reconciliation and a wake rescan never retry a given-up source while its content is unchanged. A same-mtime/size replacement is found only by Verify all or a forced-hash event (as for ready sources); its new hash then resets the budget.

**Settled.** When the committed bytes are on disk again (frozen rule: status back to `ready`), and on every publication, the budget row is deleted.

## 5. Explicit retry and resets

The budget resets (`failures = 0`, the content hash is kept) only when:

- the content changes (§4);
- the user retries: `retryFailedExtraction(sourceId, now)` / `RetryFailedExtraction` (Sources panel error row of a folder member or loose source, "Retry") and `retryFailedExtractions(notebookId, now)` / `RetryFailedExtractions` ("Retry all failed" in the indexing strip's "N files couldn't be read" view, folder and loose). A source qualifies when `status='error'`, `availability='present'`, `eligible=1`, `type<>'note'` and it can be re-read: a folder member, or a loose source with `raw_path` or `uri`. A **given-up** budget (`failures >= failureBudget`) starts over; a budget with attempts left is kept, so every user-initiated attempt counts toward the three. `requireExtraction` then queues a due job (status `pending`) that the folder worker runs (§3a), and every queued, unclaimed extract job of the source is marked `{"userRetry":true}` (`json_set` on `options_json`; `ExtractionRetryBudget.userRetryKey` / `UserRetryKey`). The single call returns whether the source was retried, the notebook call how many (ascending id). Both post `folderIngestionDidChange` / `FolderIngestionChanged` once when anything changed. The runtime commands `retryFailedSource` / `RetryFailedSourceAsync` and `retryFailedSources` / `RetryFailedSourcesAsync` wrap them;
- the user re-ingests the source (`requestSourceExtraction` / `RequestFolderExtraction` for a folder member; `beginExtraction` for a loose source) — like a Retry, this starts a given-up budget over and otherwise counts;
- the folder's limits or encoding fallback change (`applyFolderRules` with forced re-extraction): new extraction parameters may resolve the failure.

A successful publication forgets the budget (a transient failure followed by success leaves no count).

## 6. Addendum to `ingestion-reextract-v1`

§2 of that contract ("every folder scan re-reads a source whose status is not ready … Verify all is therefore an explicit manual retry") no longer holds for given-up sources: scans and Verify all skip them (§4 above); the explicit retry of §5 replaces Verify all as the manual retry.

§4 (upgrade requeue) gains a sixth qualification: **6. the source is not given up** (`failures < failureBudget`). Consistent with the user's rule, an app or extractor upgrade never retries a given-up file automatically; the error row's "Retry" and "Retry all failed" do. The requeue still applies to error sources with budget left — in practice failures recorded before v21 (empty budget) — and its job counts against the budget like any other.

§7 (spreadsheet upgrade) is unchanged: it only selects `ready` sources (no budget row). A failed upgrade job now retries at most three times in total and then leaves the source given up, so scans fast-path it until its file changes or the user retries; the published format-1 revision stays searchable throughout.

## 7. Status

`IndexingStatus.sourceErrors` keeps counting given-up sources (`status='error'`). They have no queued or running extract job, so they never make the status active (`indexing-status-v1` derivation unchanged). The "N files couldn't be read" chip carries the secondary text/tooltip "N files couldn't be read (gave up after 3 attempts)" (`indexingSourceErrorsGaveUp`).

## 8. Fixture

`{contract, version, failureBudget, extractMaxAttempts, leaseSeconds, migration, schemaDDL, seed, cases[{name, steps[{step, result, expected}]}]}`. Seed: notebook 1, folder 1 (`/docs`, default rules, watch disabled), file `a.docx` (its source is id 1). Steps (`at` = lease-clock seconds):

| `op` | Platform call | `result` |
|---|---|---|
| `observe {mtime,size,hash,verifyAll}` | request + claim a scan job, `beginFolderScan`, decide the read with the production fast-path predicate on `folderKnownSources` (hash passed only when read), `observeFolderFiles([file])`, `finishFolderScan(completed [""])` | `{read, queued}` (a new extract job exists) |
| `claim` | `claimJob(now)` (any due job; keep its fence) | `{claimed}` |
| `fail {code}` | `failJob(fence, code)` | `{failed}` |
| `expire` | `recoverExpiredJobs(now)` | `{recovered}` |
| `requeue` | `requeueRetryableJobs(now)` | `{requeued}` |
| `publish {hash}` | `publishFolderExtraction` of the claimed job (`extractionRequest`, text `abc`, one page, no embedding selection) | `{published}` |
| `retry` / `retryAll` | §5 store calls | `{retried}` (bool / count) |
| `upgrade` | `requeueUpgradedExtractions(now)` | `{requeued}` |
| `forget` | delete every budget row (a row written before v21) | `{}` |
| `loose {rawPath}` | `createSource` (type `text`, `raw_path` a path or null, no folder) | `{}` |
| `begin` | `beginExtraction(sourceId, now)` (keep its fence) | `{}` |
| `loose {rawPath, url}` with `url: true` | a web source (`uri` `https://example.org/`) | `{}` |
| `abandon` | `abandonLooseExtraction(fence)` | `{abandoned}` |

`publish` on a loose source uses `publishLooseExtraction`. `JobQueue.retryExhaustedJob` / `RetryExhaustedJob` is not reachable from any user path (tests only) and does not reset the budget.

After every step: `source {status, error, extractFailures, gaveUp}` (null before the first observation), `extractJobs [{state, attempts, nextRetryAt, error, options}]` in id order, and `indexing {active, sourceErrors}` from the store's indexing status at `at` (embedding availability `ready`).
