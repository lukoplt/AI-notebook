# Folder scan cost and cadence — normative contract v1

*Status: 0.15.2 (2026-10-11). Fixture: `Tests/fixtures/contracts/ingestion-scan-cadence-v1.json` (§4). Executable reference: `tools/contracts/gen_scan_cadence_fixtures.py` (`--check` must pass). Extends `folder-rag-v1.md` and the scan behaviour pinned by `Tests/fixtures/contracts/ingestion-scan-v1.json` (both frozen) without changing them: no schema change, the per-file store APIs and every scan fixture are unchanged. Swift (`FolderScanner`, `NotebookStore.observeFolderFiles`) and C# (`FolderScanner`, `NotebookStore.ObserveFolderFiles`) implement it identically; `FolderScanBatchTests` on both platforms pin the batch semantics. Benchmark: `FolderScanBenchmarkTests` (opt-in, `AINOTEBOOK_SCAN_BENCH=1`).*

## 0. Why

A large watched folder (thousands of files, hundreds of thousands of chunks, embedding running) could spend minutes in "Checking folder…" on every periodic rescan, and the strip hid embedding progress meanwhile. Root cause (synthetic 8,000-file benchmark, file-backed database, nothing changed on disk):

| | macOS before | Windows before |
|---|---|---|
| wall time | 41.0 s | 4.7 s |
| store transactions | 15,606 (8,005 writes) — a fast-path read plus a write per file, each a main-actor hop | 8,004 writes |
| `folderIngestionDidChange` | 8,003 (one per file), each followed by a status signal → a full status re-read on the main actor (27 s of the 41 s) | 3 |

Every unchanged file still rewrote its `scan_items` row and its `sources` row with identical values in its own transaction (rollback journal: one fsync each), and on macOS every one of those commits made the status strip re-read the whole notebook status.

## 1. Batched observations

- The scanner commits observations in batches of at most **`observeBatchSize = 256`** files, and commits a non-empty batch at the latest **`observeBatchInterval = 1 s`** after its previous commit (so a slow hash still shows progress). Each batch is one fenced write transaction (`observeFolderFiles` / `ObserveFolderFiles`); observations keep walk order.
- Every observation of a batch is validated before the transaction; an invalid one rejects the whole batch. A stale ticket rejects the batch with `staleLease`; nothing is written or signalled.
- **Unchanged rows**: an observation whose `scan_items` row already has the same `kind`, `skip_reason`, `mtime` and `size_bytes`, and
  - `skipped` → the path has no source;
  - `eligible` → the source is `present`, eligible, has the same `mtime`/`size_bytes`, a committed hash, a current published revision and `status='ready'`, and the observation either carries no hash (stat fast path) or carries exactly the committed hash,
  only gets `seen_generation` set to the scan generation — one bulk `UPDATE scan_items … WHERE rel_path IN (…)` per batch (≤ 400 paths per statement). No `sources` row is touched.
- **Every other row** takes exactly the per-file path (`observeFolderFile` / `ObserveFolderFile`; an interior link `observeInteriorLink`, i.e. recorded `skipped`/`ignored` only when the path has a source). A path repeated within a batch is never treated as unchanged twice.
- The batch is a pure optimisation: committing a batch leaves the database exactly as committing its observations one by one (pinned by `BatchMatchesPerFileObservations`).
- The scan commits its last batch before `finishFolderScan` (missing-marking needs every `seen_generation`). On cancellation or an unexpected error the pending batch is committed best effort before the scan is marked partial/error; a stale lease drops it.
- **Fast-path snapshot**: the scanner reads the folder's sources once at scan start (`folderKnownSources` / `FolderKnownSources`) to decide which files to hash, instead of one store round trip per file. A stale snapshot is harmless: the commit re-checks every row, a file hashed unnecessarily is merely read, and an outdated "skip" falls back to queuing extraction from the committed hash (the per-file rule).

## 2. Signals

- A batch with at least one changed row posts **one** `folderIngestionDidChange` / `FolderIngestionChanged` (macOS: any row through the per-file path; Windows: the per-file `changed` flag, as before) — at most one per batch instead of one per file.
- A batch with only unchanged rows posts no catalog signal, only the throttled status-only signal (`indexing-status-v1` §5: at most one per second per notebook plus one trailing post), so the strip's files-seen count still advances.
- An empty batch posts nothing. Begin, finish and cancel of a scan still post `folderIngestionDidChange` as before.
- The per-file APIs keep their signals (one per committed observation on macOS; one per change on Windows).

## 3. Results (same benchmark, after)

| | macOS | Windows |
|---|---|---|
| no-change rescan | 1.4 s, 39 transactions (37 writes), 3 `folderIngestionDidChange` | 0.39 s, 36 writes, 3 `FolderIngestionChanged` |
| 1 % changed (77 files) | 1.6 s, 34 `folderIngestionDidChange` (changes spread over every batch) | 0.68 s, 34 |

## 4. Periodic reconcile cadence

The reconciler keeps its 30-minute pass (`constants-v1` `periodicReconcileMinutes`, unchanged): lease recovery, due-retry requeue, orphan-scan repair (start only) and the upgrade requeue (`ingestion-reextract-v1` §4) still run on every pass. What changes is which watch-enabled folders a pass rescans.

| Constant | Value |
|---|---|
| `watchedVerifyHours` | `6` (`FolderReconciler.watchedVerifyHours` / `WatchedVerifyHours`) |
| `wakeGapSeconds` | `60` (`FolderIngestionRuntime.wakeGapSeconds` / `WakeGapSeconds`) |

- **Healthy watch**: the folder's native watch (FSEvents / `FileSystemWatcher`) started successfully and has reported no lost events (`overflow`; on Windows also any watcher `Error`, which the handle reports as `overflow`) since it started. A stopped, failed or degraded watch is not healthy; it becomes healthy again only when the watch is restarted (watching toggled, runtime restart).
- `verifyDue(startup, watchHealthy, lastFullScanAt, lastRequestedAt, now)` (fixture operation `verify-due`): true at runtime start; true for a folder without a healthy watch (every pass, the previous behaviour); otherwise true when neither a completed full scan (`last_full_scan_at`) nor a scan requested by this reconciler (in memory, per process) happened within the last `watchedVerifyHours` (a clock behind the last verification is not due). A due folder gets one plain (non-Verify-all) scan request, which the store coalesces with a queued one; with §1 that scan is a stat-only verification of unchanged files.
- Disabled (not watch-enabled) folders are still scanned only on request, as before.
- **Wake**: after system sleep every watched folder gets one debounced plain rescan through the watch-signal schedule (`systemDidWake` / `SystemDidWakeAsync`). Both runtimes detect a suspension themselves: two consecutive scheduler ticks (every 100 ms) whose lease-clock times are at least `wakeGapSeconds` apart (`suspendedBetween` / `SuspendedBetween`, fixture operation `wake-gap`; a clock set back is no wake). The macOS app additionally forwards `NSWorkspace.didWakeNotification` (both hints coalesce into one rescan); the unpackaged Windows app relies on the gap detection.
- **Lost events** keep their existing rule: an `overflow` signal forces a re-hashing rescan (`ingestion-ui-v1` `watch` cases), and now also degrades the watch so periodic passes rescan the folder again.

Consequence for `ingestion-reextract-v1` §2: terminal extraction failures of a folder with a healthy watch are retried by scans every 6 hours (and on start, wake and lost events) instead of every 30 minutes; the upgrade requeue itself still runs on every pass.

## 5. Addendum: a file that cannot be read during a scan (2026-10-11)

A file the scan must hash (new, changed stamp, or Verify all) whose read fails is **not observed**: no `scan_items` row is touched, no source is created, updated or re-extracted for it. Only the directory that contains it — and therefore every ancestor — becomes incomplete, so nothing inside them is marked missing in this scan; sibling subtrees complete normally and the scan finishes `partial` without a scan error. The next scan retries the read. This is the macOS behaviour (`FolderWalk` turns a visitor's permission or path-changed error into an incomplete directory) and Windows now matches it. Previously the Windows scanner recorded an unhashed `eligible` observation: for a new file the store rejected it (`invalidValue`), losing the whole observation batch and ending the scan with `unexpectedError`; for a known file it scheduled a re-extraction.

| Failure (fixture `error`) | macOS | Windows |
|---|---|---|
| `permissionDenied` | `CocoaError.fileReadNoPermission`, `EACCES`, `EPERM` | `UnauthorizedAccessException`, `SecurityException`, any other `IOException` (sharing / lock violation) |
| `vanished` | `ENOENT`, `ENOTDIR` | `FileNotFoundException`, `DirectoryNotFoundException` |
| `changedDuringRead` | `changedDuringExtraction`, `outsideRoot` | same codes |
| `becameLink` | `interiorLink` | same code |

A read that finds the file grown past the size limit keeps its existing meaning (`skipped` / `over_limit`), and a root that went offline or changed identity still makes the whole scan `unavailable`. Fixture: `ingestion-scan-cadence-v1.json` operation `unreadable-file` (8 cases, `tools/contracts/gen_scan_cadence_fixtures.py`); `FolderScanUnreadableTests` on both platforms replay it through the real scanner and store.
