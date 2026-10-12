#!/usr/bin/env python3
"""ingestion-adaptive-concurrency-v1 reference: how many extractions run at once.

Background extraction uses more cores only while the computer is otherwise
idle, and steps down immediately when it is not. Normative text:
docs/contracts/ingestion-memory-pressure-v1.md, addendum A. Swift
(`AdaptiveConcurrency`, `IngestionAdmission.setConcurrencyLimit`) and C#
(`AdaptiveConcurrency`, `IngestionAdmission.SetConcurrencyLimit`) must
reproduce every case exactly.

Operations:
- `max-workers`: logical cores -> extraction worker cap;
- `memory-budget`: physical memory bytes -> admission memory budget;
- `hash-width`: current extraction limit -> scanner hash width;
- `target`: one system sample -> target worker count (0 = memory critical);
- `governor`: a trace of `{atMs, target}` samples -> applied limit after each;
- `admission`: `limit` / `pressure` / `acquire` / `release` events -> projection
  `{limit, level, reservations, waiters}` after each event;
- `darwin-thermal`: `ProcessInfo.ThermalState` raw value -> thermal name;
- `windows-power`: `SYSTEM_POWER_STATUS` (ACLineStatus, SystemStatusFlag) -> {onBattery, lowPower};
- `windows-load`: `GetSystemTimes` deltas -> load in thousandths of a core.
"""

import argparse
import json
from copy import deepcopy
from pathlib import Path

CONTRACT = "ingestion-adaptive-concurrency"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/ingestion-adaptive-concurrency-v1.json"

MiB = 1_048_576
MAX_WORKERS = 6
INITIAL_WORKERS = 2
BATTERY_WORKERS = 2
BUSY_WORKERS = 2
CONSTRAINED_WORKERS = 1
MAX_HASH_WIDTH = 4
MIN_BUDGET = 512 * MiB
MAX_BUDGET = 1024 * MiB
BUDGET_PERCENT = 6
RAISE_AFTER_MS = 30_000
SAMPLE_INTERVAL_MS = 2_000
THERMAL = ["nominal", "fair", "serious", "critical"]
LEVELS = ["normal", "warning", "critical"]


def max_workers(cores: int) -> int:
    return min(max(cores // 2, 1), MAX_WORKERS)


def memory_budget(physical: int) -> int:
    return min(max(physical * BUDGET_PERCENT // 100, MIN_BUDGET), MAX_BUDGET)


def hash_width(limit: int) -> int:
    return min(max(limit, 1), MAX_HASH_WIDTH)


def target(cores: int, loadMilli: int, ownWorkers: int, memory: str, thermal: str, lowPower: bool, onBattery: bool) -> int:
    assert memory in LEVELS and thermal in THERMAL
    if memory == "critical":
        return 0
    t = max_workers(cores)
    if memory == "warning" or thermal in ("serious", "critical") or lowPower:
        t = min(t, CONSTRAINED_WORKERS)
    if onBattery:
        t = min(t, BATTERY_WORKERS)
    # Our own running extractions are part of the system load; only the rest counts.
    external = max(0, loadMilli - 1000 * max(ownWorkers, 0))
    capacity = 1000 * max(cores, 1)
    if external >= capacity:
        t = min(t, CONSTRAINED_WORKERS)
    elif 2 * external >= capacity:
        t = min(t, BUSY_WORKERS)
    return max(t, 1)


class Governor:
    """Hysteresis: lower at once; raise only after the higher target held RAISE_AFTER_MS."""

    def __init__(self, cap: int):
        self.cap = cap
        self.limit = min(cap, INITIAL_WORKERS)
        self.since = None

    def observe(self, value: int, at: int) -> int:
        value = min(max(value, 1), self.cap)
        if value <= self.limit:
            self.limit = value
            self.since = None
        else:
            if self.since is None or at < self.since:
                self.since = at
            if at - self.since >= RAISE_AFTER_MS:
                self.limit = value
                self.since = None
        return self.limit


def concurrency(level: str, max_extractions: int) -> int:
    return {"normal": max_extractions, "warning": min(1, max_extractions), "critical": 0}[level]


class Admission:
    """ingestion-memory-pressure-v1 admission plus the adaptive limit (FIFO, never revokes)."""

    def __init__(self, max_extractions: int, memory_bytes: int):
        self.max = max_extractions
        self.budget = memory_bytes
        self.limit = max_extractions
        self.level = "normal"
        self.reservations = []
        self.waiters = []

    def can_grant(self, amount: int) -> bool:
        if len(self.reservations) >= min(self.limit, concurrency(self.level, self.max)):
            return False
        return amount <= self.budget - sum(b for _, b in self.reservations)

    def drain(self) -> None:
        while self.waiters and self.can_grant(self.waiters[0][1]):
            self.reservations.append(self.waiters.pop(0))

    def acquire(self, request: str, amount: int) -> None:
        amount = min(max(amount, 0), self.budget)
        if not self.waiters and self.can_grant(amount):
            self.reservations.append((request, amount))
        else:
            self.waiters.append((request, amount))

    def project(self) -> dict:
        return dict(limit=self.limit, level=self.level, reservations=[r for r, _ in self.reservations],
                    waiters=[w for w, _ in self.waiters])


def admission_trace(name: str, steps: list, max_extractions: int = 6, memory_bytes: int = 1024 * MiB) -> dict:
    admission = Admission(max_extractions, memory_bytes)
    events = []
    for step in steps:
        op = step[0]
        if op == "limit":
            admission.limit = min(max(step[1], 1), admission.max)
            admission.drain()
            event = dict(operation=op, limit=step[1])
        elif op == "pressure":
            admission.level = step[1]
            admission.drain()
            event = dict(operation=op, level=step[1])
        elif op == "acquire":
            admission.acquire(step[1], step[2])
            event = dict(operation=op, requestId=step[1], bytes=step[2])
        elif op == "release":
            admission.reservations = [r for r in admission.reservations if r[0] != step[1]]
            admission.drain()
            event = dict(operation=op, requestId=step[1])
        else:
            raise SystemExit("gen_adaptive_concurrency_fixtures: unknown operation " + op)
        event["expected"] = deepcopy(admission.project())
        events.append(event)
    return dict(name=name, operation="admission",
                input=dict(maxExtractions=max_extractions, memoryBytes=memory_bytes, events=events),
                expected=deepcopy(events[-1]["expected"]))


def sample(cores=10, loadMilli=0, ownWorkers=0, memory="normal", thermal="nominal", lowPower=False, onBattery=False) -> dict:
    return dict(cores=cores, loadMilli=loadMilli, ownWorkers=ownWorkers, memory=memory, thermal=thermal,
                lowPower=lowPower, onBattery=onBattery)


TARGETS = [
    ("idle-10-cores", sample()),
    ("idle-12-cores", sample(cores=12)),
    ("idle-16-cores-capped", sample(cores=16)),
    ("idle-4-cores", sample(cores=4)),
    ("idle-single-core", sample(cores=1)),
    ("own-load-is-not-external", sample(loadMilli=5_200, ownWorkers=5)),
    ("own-load-plus-light-external", sample(loadMilli=9_000, ownWorkers=5)),
    ("busy-half-cores", sample(loadMilli=5_000)),
    ("just-below-busy", sample(loadMilli=4_999)),
    ("overloaded", sample(loadMilli=10_000)),
    ("overloaded-net-of-own", sample(loadMilli=15_000, ownWorkers=5)),
    ("memory-warning", sample(memory="warning")),
    ("memory-critical", sample(memory="critical")),
    ("memory-critical-wins", sample(memory="critical", onBattery=True, thermal="critical")),
    ("thermal-fair", sample(thermal="fair")),
    ("thermal-serious", sample(thermal="serious")),
    ("thermal-critical", sample(thermal="critical")),
    ("low-power", sample(lowPower=True)),
    ("battery", sample(onBattery=True)),
    ("battery-4-cores", sample(cores=4, onBattery=True)),
    ("battery-busy", sample(onBattery=True, loadMilli=6_000)),
    ("battery-low-power", sample(onBattery=True, lowPower=True)),
    ("negative-own-workers", sample(loadMilli=6_000, ownWorkers=-3)),
    ("zero-cores", sample(cores=0, loadMilli=500)),
]

GOVERNORS = [
    ("starts-at-two-then-raises-after-hold", 5, [(0, 5), (10_000, 5), (29_999, 5), (30_000, 5), (40_000, 5)]),
    ("lowers-at-once", 5, [(0, 5), (30_000, 5), (31_000, 1), (31_100, 2)]),
    ("dip-restarts-hold", 6, [(0, 6), (20_000, 2), (25_000, 6), (50_000, 6), (55_000, 6)]),
    ("raise-to-latest-target", 6, [(0, 4), (15_000, 6), (30_000, 3)]),
    ("critical-reads-as-one", 5, [(0, 0), (1_000, 5), (31_000, 5)]),
    ("capped-by-max", 3, [(0, 9), (30_000, 9)]),
    ("single-core-cap", 1, [(0, 4), (60_000, 4)]),
    ("clock-back-restarts-hold", 5, [(10_000, 5), (5_000, 5), (34_999, 5), (35_000, 5)]),
]

ADMISSION = [
    admission_trace("raised-limit-drains-fifo", [
        ("limit", 2), ("acquire", "a", 10), ("acquire", "b", 10), ("acquire", "c", 10), ("acquire", "d", 10),
        ("limit", 4)]),
    admission_trace("lowered-limit-keeps-granted-work", [
        ("acquire", "a", 10), ("acquire", "b", 10), ("acquire", "c", 10), ("limit", 1), ("acquire", "d", 10),
        ("release", "a"), ("release", "b"), ("release", "c")]),
    admission_trace("limit-clamped-to-max", [
        ("limit", 9), ("acquire", "a", 10), ("acquire", "b", 10), ("acquire", "c", 10)], max_extractions=2),
    admission_trace("limit-at-least-one", [
        ("limit", 0), ("acquire", "a", 10), ("acquire", "b", 10)]),
    admission_trace("warning-below-limit", [
        ("limit", 4), ("pressure", "warning"), ("acquire", "a", 10), ("acquire", "b", 10), ("pressure", "normal")]),
    admission_trace("critical-overrides-limit", [
        ("limit", 6), ("pressure", "critical"), ("acquire", "a", 10), ("pressure", "normal")]),
    admission_trace("budget-still-bounds-office", [
        ("limit", 6), ("acquire", "a", 250 * MiB), ("acquire", "b", 250 * MiB), ("acquire", "c", 250 * MiB),
        ("acquire", "d", 250 * MiB), ("acquire", "e", 10), ("release", "a")], memory_bytes=983 * MiB),
]

DARWIN_THERMAL = [(0, "nominal"), (1, "fair"), (2, "serious"), (3, "critical"), (4, "nominal"), (-1, "nominal")]
WINDOWS_POWER = [(1, 0), (0, 0), (255, 0), (1, 1), (0, 1), (0, 9), (1, 8)]
WINDOWS_LOAD = [
    dict(idle=100, kernel=100, user=0, cores=8),
    dict(idle=0, kernel=50, user=50, cores=8),
    dict(idle=50, kernel=100, user=0, cores=8),
    dict(idle=600, kernel=800, user=200, cores=10),
    dict(idle=0, kernel=0, user=0, cores=4),
    dict(idle=150, kernel=100, user=0, cores=4),
    dict(idle=-5, kernel=100, user=0, cores=4),
]


def windows_load(idle: int, kernel: int, user: int, cores: int) -> int:
    # kernel time includes idle time; a negative or inconsistent delta clamps.
    total = kernel + user
    if total <= 0:
        return 0
    busy = min(max(total - idle, 0), total)
    return busy * max(cores, 1) * 1000 // total


def build() -> dict:
    cases = []
    cases += [dict(name=f"max-workers-{c}", operation="max-workers", input=c, expected=max_workers(c))
              for c in [0, 1, 2, 3, 4, 8, 10, 12, 14, 24]]
    cases += [dict(name=f"memory-budget-{label}", operation="memory-budget", input=b, expected=memory_budget(b))
              for label, b in [("0", 0), ("4gb", 4 << 30), ("8gb", 8 << 30), ("16gb", 16 << 30), ("32gb", 32 << 30),
                               ("64gb", 64 << 30)]]
    cases += [dict(name=f"hash-width-{n}", operation="hash-width", input=n, expected=hash_width(n)) for n in [0, 1, 2, 4, 6]]
    cases += [dict(name=f"target-{name}", operation="target", input=s, expected=target(**s)) for name, s in TARGETS]
    for name, cap, steps in GOVERNORS:
        governor = Governor(cap)
        samples = [dict(atMs=at, target=t, expected=governor.observe(t, at)) for at, t in steps]
        cases.append(dict(name=f"governor-{name}", operation="governor", input=dict(cap=cap, samples=samples),
                          expected=samples[-1]["expected"]))
    cases += ADMISSION
    cases += [dict(name=f"darwin-thermal-{raw}", operation="darwin-thermal", input=raw, expected=name)
              for raw, name in DARWIN_THERMAL]
    cases += [dict(name=f"windows-power-{ac}-{flag}", operation="windows-power", input=dict(acLineStatus=ac, systemStatusFlag=flag),
                   expected=dict(onBattery=ac == 0, lowPower=(flag & 1) == 1)) for ac, flag in WINDOWS_POWER]
    cases += [dict(name=f"windows-load-{i}", operation="windows-load", input=row, expected=windows_load(**row))
              for i, row in enumerate(WINDOWS_LOAD)]
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_adaptive_concurrency_fixtures: duplicate case name")
    return dict(contract=CONTRACT, version=VERSION, maxWorkers=MAX_WORKERS, initialWorkers=INITIAL_WORKERS,
                batteryWorkers=BATTERY_WORKERS, busyWorkers=BUSY_WORKERS, constrainedWorkers=CONSTRAINED_WORKERS,
                maxHashWidth=MAX_HASH_WIDTH, minBudgetBytes=MIN_BUDGET, maxBudgetBytes=MAX_BUDGET,
                budgetPercent=BUDGET_PERCENT, raiseAfterMs=RAISE_AFTER_MS, sampleIntervalMs=SAMPLE_INTERVAL_MS,
                thermal=THERMAL, cases=cases)


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check: bool = False) -> None:
    path = root / OUTPUT
    data = encoded()
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("ingestion-adaptive-concurrency-v1.json is stale")
        print("ingestion-adaptive-concurrency-v1.json is current")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
