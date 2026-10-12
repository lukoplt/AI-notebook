# Chat while a folder check runs — normative contract v1

*Status: 2026-10-11. Fixture: `Tests/fixtures/contracts/chat-during-scan-v1.json`. Executable reference: `tools/contracts/gen_chat_scan_fixtures.py` (`--check` must pass). Swift (`PackCorpusCoverage.normalized`, `NotebookStore.contextScopeFingerprint`, `ChatSessionState.staleRepreparations`) and C# (`CompatibilityPackDataSource.NormalizedCoverage`, `NotebookStore.ContextScopeFingerprint`, `ChatSessionState.StaleRepreparations`) must reproduce every case. Extends `folder-rag-v1.md` (frozen) without changing it: no schema change, no change to the context-pack builder, its invariants or its fixtures.*

## 1. Why

The periodic folder check (scan) of a large watched folder runs together with extraction, spreadsheet re-extraction and embedding. A chat turn during it must work and must answer from the last completed (published) state — as if it had run just before the check started. Before this contract the turn could fail with `stalePreparedRequest` (the check changed the scope fingerprint between capture and send) and the UI hung because store work ran on, or waited for, the UI thread.

## 2. Snapshot reads and concurrency

- **One snapshot per phase.** A turn's capture (notebook instructions, evidence cap, history and scope fingerprints) and its pin (session validation, fingerprints, history, coverage, folders) each read from ONE read transaction (`NotebookStore.contextReadSnapshot`). The retrieval pin keeps its own single read (unchanged).
- **macOS.** File stores use a GRDB `DatabasePool` (`journal_mode=WAL`, persistent; an existing rollback database converts on first open; `journal_size_limit` = 64 MiB). Reads run on reader connections against a committed snapshot and never wait for a writer. `NotebookStore` database methods are nonisolated: background workers (scanner, extraction, index coordinator, job queue, runtime, reconciler) call them from their own executors; only the published notebook list, note hooks and notifications are main-actor state, and notifications are always posted on the main thread. Read-only methods use read transactions. In-memory stores keep a `DatabaseQueue`.
- **Windows.** The store keeps exactly one connection and the `_gate` invariant (every connection access inside `lock (_gate)`; v0.13 crash fix). A separate read-only connection is NOT introduced. The chat view model runs capture, prepare and send on the thread pool, so the UI thread never waits for the gate while a background batch holds it; the pin's reads already happen inside one gate scope (one snapshot).
- **Coverage never fails a turn.** Coverage is read before the retrieval pin; a concurrent check can only make them disagree. The data source normalizes it (operation `coverage`): negative counts read as zero, a shortfall against the pinned files counts as searchable, `refreshPending` is clamped to the files in scope and `refreshError` to the remainder. The builder stays strict (`invalid-coverage` in `context-pack-v1` still rejects).

## 3. What a turn answers from, and when it is stale

- Retrieval, the folder map and citations use **published revisions only** (unchanged). During a check: a changed file is answered from its previous published revision until the new extraction publishes; a file not yet reached in this check stays `present` (missing-marking happens only when the check finishes, `folder-rag-v1` §1b); a newly discovered file contributes no evidence until its first publication; a turn pinned after a publication may use it.
- **Scope fingerprint** = SHA-256 over the selection, the notebook's folder IDs and the scope's **revoked** sources (`availability <> 'present'` or `eligible = 0`) with their folder, availability and eligibility (operation `scope-stale`). Usable sources, publications, refreshes and newly discovered files never change it; a source becoming missing/unavailable/ineligible, a missing source reappearing, or a folder being added/removed does. A loose source deleted while a turn is in flight is not detected (its citation resolves as unavailable).
- **Re-preparation.** `stalePreparedRequest` is raised before any row or network call. A send (UI send, `ChatEngine.send`/`regenerate`) then captures and prepares the same turn again from the new snapshot, at most `staleRepreparations` = 3 more times, with the turn's mode and web flag captured once; only then is the error shown. A previewed handle whose key no longer matches a fresh capture is re-prepared silently (unchanged UI behaviour).

## 4. Admission

Chat never waits for extraction admission or a scan lease. While a chat phase holds its admission token no new background embedding batch starts (unchanged); the question embedding waits at most for the one batch already in flight at the provider.

## 5. UI

No gating: the composer, scope chips and preview stay enabled while folders scan, extract or embed (both platforms were verified to have none). No string changed.
