# Memory pressure: graded extraction admission — normative contract v1

*Status: 0.15.1 (2026-10-10). Fixture: `Tests/fixtures/contracts/ingestion-memory-pressure-v1.json`. Executable reference: `tools/contracts/gen_memory_pressure_fixtures.py` (`--check` must pass). Swift (`IngestionAdmission`, `MemoryPressureLevel`) and C# (`IngestionAdmission`, `MemoryPressureLevels`) must reproduce every case exactly. Extends `folder-rag-v1.md` (frozen) without changing its traces: the boolean `setMemoryPressure(blocked)` keeps its meaning (`true` = `critical`, `false` = `normal`).*

## 1. Why

0.15.0 closed the extraction gate on any OS memory-pressure signal (macOS `warning` or `critical`, Windows ≥ 90 % of the GC high-load threshold) and reopened it only on an explicit "normal" event. A 16 GB Mac running Ollama next to a large notebook can sit at `warning` for hours, and the macOS event handler applied events through unordered tasks, so a `warning → normal` pair could land reversed. Either way, every due extract job stayed `queued` with no running extraction and no visible reason (hundreds of due jobs could go unclaimed for hours while the app was idle). Pressure must degrade throughput, never stop it silently.

## 2. Levels and admission

`MemoryPressureLevel ∈ normal | warning | critical`. The extraction concurrency limit is:

| Level | Concurrent extractions |
|---|---|
| `normal` | `maxExtractions` (default 2) |
| `warning` | `min(1, maxExtractions)` |
| `critical` | `0` (new extractions pause) |

- The memory budget, the reservation formula and the oversize rule (capped at the budget, runs alone) are unchanged.
- Strict FIFO is unchanged: a head waiter that cannot be granted is never overtaken.
- Changing the level never revokes a granted permit; running extractions finish. Lowering pressure drains waiters in FIFO order up to the new limit.
- Setting the same level again is a no-op apart from draining.
- Only extraction admission consults the level. Scans, embedding batches, chat and question embeddings never do.

## 3. Probing (no event can be missed)

The runtime samples a memory-pressure probe on every scheduler tick (both platforms tick every 100 ms; at least once per second is required) and applies the level to admission. OS notifications are not used as the source of truth, so a lost or reordered notification cannot keep the gate closed past the next tick. A probe that fails reports `normal` (fail open). Without a probe (tests, headless tools) the level only changes through explicit calls.

Probe mappings (pure functions, fixture-tested on both platforms):

- **macOS** (`MemoryPressureLevel.darwin(rawLevel:)`): `sysctl kern.memorystatus_vm_pressure_level` — `1 → normal`, `2 → warning`, `4 → critical`, anything else (including a failed read) → `normal`. This is the same kernel state the `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source reports.
- **Windows** (`MemoryPressureLevels.FromMemoryLoad(percent)`): `GlobalMemoryStatusEx` `dwMemoryLoad` — `≥ 95 → critical`, `≥ 85 → warning`, else `normal`. (`GC.GetGCMemoryInfo()` is not used: it describes the last GC, which an idle process may not run for a long time.)

## 4. Visibility

The admission's current level is a runtime fact of `indexing-status-v1` (addendum §6 there): while extraction work is pending, the status strip says that processing is slowed (`warning`) or paused (`critical`) because the system is low on memory.

## 5. Pre-claim failures never block the queue head

Audited alongside the pressure gate (same symptom: due jobs that nothing claims). The job queue picks the first due candidate (`ORDER BY coalesce(next_retry_at,0), id`) not already selected by a concurrent call. If computing its reservation, waiting for admission or claiming it throws (anything but cancellation), the error still propagates to the dispatch loop, and that candidate is additionally skipped by later selections of the same queue for `preClaimDeferral = 60` lease-clock seconds (in-process only, nothing durable changes). Before, the same row was re-selected every loop iteration and stalled every later job of its kind. A claimed job's failures are unchanged (fenced `failJob`).

The macOS extraction reservation no longer throws for a folder whose stored limits document does not parse: it reserves with the default limits, as Windows always did.

## 6. Fixture

`{contract, version, levels, warningConcurrency, warningLoadPercent, criticalLoadPercent, cases[]}`.

- `operation: "admission"` — `input {maxExtractions, memoryBytes, events[]}`; each event is `pressure {level}`, `blocked {blocked}` (the frozen boolean form), `acquire {requestId, bytes}` or `release {requestId}` (release of a granted request). After every event the projection `{level, reservations: [requestId…] in grant order, waiters: [requestId…] in FIFO order}` must equal `expected`.
- `operation: "darwin-level"` — `input` raw sysctl integer, `expected` level.
- `operation: "memory-load"` — `input` memory-load percent, `expected` level.

## Addendum A — adaptive extraction concurrency (0.15.3)

*Fixture: `Tests/fixtures/contracts/ingestion-adaptive-concurrency-v1.json`. Executable reference: `tools/contracts/gen_adaptive_concurrency_fixtures.py` (`--check` must pass). Swift (`AdaptiveConcurrency`, `IngestionAdmission.setConcurrencyLimit`) and C# (`AdaptiveConcurrency`, `IngestionAdmission.SetConcurrencyLimit`) reproduce every case. §2–§6 above are unchanged: every `ingestion-memory-pressure-v1` trace still holds, because the new limit defaults to `maxExtractions`. Benchmark: `ExtractionConcurrencyBenchmarkTests` on both platforms (opt-in, `AINOTEBOOK_CPU_BENCH=1`; corpus `tools/benchmark/gen_cpu_corpus.py`).*

### A.1 Why

Extraction ran on at most two workers with a fixed 512 MiB budget. Each Office/PDF reservation carries the 200 MiB expanded-bytes allowance, so two of them already filled the budget: a folder of PDFs and Office files extracted effectively one or two at a time on a 10-core machine that was otherwise idle. Background work may use more cores — but only while the computer is not busy, on power and cool, and it must step down at once when that changes.

### A.2 Capacity (production composition, fixed for the process)

| Function | Rule |
|---|---|
| `maxWorkers(logicalCores)` | `clamp(logicalCores / 2, 1, 6)` (integer division). The app creates `IngestionAdmission(maxExtractions: maxWorkers, …)` and runs that many extraction dispatch loops (no longer a fixed two). |
| `memoryBudget(physicalBytes)` | `clamp(physicalBytes × 6 / 100, 512 MiB, 1 GiB)` (integer arithmetic). 16 GB → 983 MiB (four Office/PDF reservations at once), 8 GB and below → 512 MiB as before. The reservation formula and the oversize rule are unchanged. |
| `hashWidth(limit)` | `clamp(limit, 1, 4)`: how many files the folder scanner hashes concurrently (§A.5). |

Half the logical cores, not "performance cores − 2": Apple's base M-series chips have 4 performance and 4–6 efficiency cores, and `.utility` work runs well on efficiency cores; the cap of 6 keeps two extraction workers plus the embedding loop, the UI and the database well inside a 10–12-core machine.

Tests and headless tools that construct `IngestionAdmission()` keep the defaults (2 extractions, 512 MiB) and therefore the previous behaviour.

### A.3 Target (pure function, fixture operation `target`)

`target(cores, loadMilli, ownWorkers, memory, thermal, lowPower, onBattery)`:

1. `memory == critical` → `0` (admission already pauses new extractions, §2).
2. `t = maxWorkers(cores)`.
3. `memory == warning`, `thermal ∈ {serious, critical}` or `lowPower` → `t = min(t, 1)`.
4. `onBattery` → `t = min(t, 2)`.
5. External load: `external = max(0, loadMilli − 1000 × max(ownWorkers, 0))` — the system's runnable load in thousandths of a core minus our own running extractions. With `capacity = 1000 × max(cores, 1)`: `external ≥ capacity` → `t = min(t, 1)`; else `2 × external ≥ capacity` → `t = min(t, 2)`.
6. Result `max(t, 1)`.

`thermal ∈ nominal | fair | serious | critical`. Probes (fail open = `nominal` / not on battery / not low power / load 0):

- **macOS**: `getloadavg` 1-minute value × 1000 (truncated); `ProcessInfo.thermalState` raw `0…3` → nominal/fair/serious/critical, anything else nominal (`darwin-thermal`); `ProcessInfo.isLowPowerModeEnabled`; on battery = the IOKit providing power source (`IOPSGetProvidingPowerSourceType`) is `Battery Power`.
- **Windows**: load from `GetSystemTimes` deltas between two samples (`windows-load`: kernel time includes idle; `total = kernel + user`, `busy = clamp(total − idle, 0, total)`, `loadMilli = busy × cores × 1000 / total`, 0 when `total ≤ 0`); `GetSystemPowerStatus`: `ACLineStatus == 0` → on battery (1 and 255 "unknown" are not), `SystemStatusFlag` bit 0 (battery saver) → low power (`windows-power`). Windows exposes no thermal state to unpackaged desktop apps; it reads `nominal` (Windows throttles the CPU itself).

### A.4 Governor (hysteresis, fixture operation `governor`)

The runtime samples the system probe at most every `sampleIntervalMs = 2000` on the scheduler tick (memory pressure is still sampled on every tick, §3), computes the target with `ownWorkers` = granted extraction permits and `memory` = the level just sampled, and feeds it to a governor with `cap = maxExtractions`:

- The limit starts at `min(cap, 2)` (the previous fixed concurrency).
- A target is clamped to `[1, cap]` (`0` reads as `1`: memory-critical pausing belongs to admission).
- A target at or below the current limit applies at once (step down immediately).
- A target above it applies only after targets above the limit were observed continuously for `raiseAfterMs = 30000`; the raise goes to the latest target. A target at or below the limit restarts the wait; a clock that moves backwards restarts it too.

The governor's limit goes to `IngestionAdmission.setConcurrencyLimit` / `SetConcurrencyLimit`. Without a probe (tests, headless tools) the limit stays `maxExtractions`.

### A.5 Admission and workers (fixture operation `admission`)

- Admission grants while `granted < min(limit, concurrency(level, maxExtractions))` and the budget allows (§2). `limit` is clamped to `[1, maxExtractions]`; a new admission has `limit = maxExtractions`.
- Lowering the limit never revokes a granted permit; raising it drains waiters in FIFO order. Projection: `{limit, level, reservations, waiters}`.
- The folder scanner hashes the files that need a read (new, changed, Verify all) `hashWidth(limit)` at a time; observations are still committed in walk order in the same batches (`ingestion-scan-perf-v1` §1), so a scan commits exactly what the sequential scan committed. A per-file hash failure keeps its per-file meaning; an unexpected one ends the walk after every earlier observation, as before.
- Database writes stay serialized (one writer); only reading, parsing, language detection and chunking run in parallel.
- Background work yields to the user: macOS dispatch loops run at `.utility` priority (QoS); on Windows the CPU-bound sections (parsing, detection/chunking, hashing) run with `ThreadPriority.BelowNormal` and restore the thread's priority afterwards.

### A.6 Measurements (`ExtractionConcurrencyBenchmarkTests`, 400-file synthetic corpus, release builds)

Development machine: Apple Silicon (12 cores, 32 GB), other builds running (1-minute load 9–14), so the absolute numbers are noisy; the ratios are what matter. "Cores" = process CPU time / wall time.

| | Swift wall (cores) | .NET wall (cores) |
|---|---|---|
| 1 worker | 55.1 s (0.97) | 22.5 s (1.14) |
| before: 2 workers, 512 MiB (production 0.15.2) | 28.3 s (1.9) | 14.0 s (1.6) |
| 2–8 workers, 512 MiB | 28.3–29.5 s (≈1.9) — the budget admits two Office/PDF reservations | 13.0–13.4 s (≈1.6) |
| 4 workers, 983 MiB (16 GB budget) | 20.3 s (2.9) | 10.5 s (2.2) |
| **5 workers, 983 MiB (a 16 GB machine, after)** | **14.6 s (3.7)** | **10.3 s (2.2)** |
| 6 workers, 8 GiB budget (CPU bound only) | 11.4 s (5.1) | 10.0 s (2.5) |
| first-scan hashing, width 1 → 4 | 0.31 → 0.17 s | 0.24 → 0.12 s |

One-core stage split (per file, mean): Swift parse 0.6–52 ms vs detect+chunk 17–195 ms (detection ≈ 75 % of Swift extraction CPU and 3.5× the .NET cost); .NET parse 0.6–27 ms vs detect+chunk 6–53 ms, with ≈ 15 % in the serialized publication — which is why .NET stops scaling near 2.2 cores (one store gate, by design).
