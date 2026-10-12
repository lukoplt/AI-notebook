#!/usr/bin/env python3
"""ingestion-memory-pressure-v1 reference: graded extraction admission.

Memory pressure degrades extraction instead of stopping it: `warning` admits
one concurrent extraction, `critical` admits none, `normal` restores the
configured limit. The runtime samples a probe on every scheduler tick, so a
missed or reordered OS event can never keep the gate closed. Swift
(`IngestionAdmission`, `MemoryPressureLevel`) and C# (`IngestionAdmission`,
`MemoryPressureLevels`) must reproduce every case exactly. Normative text:
docs/contracts/ingestion-memory-pressure-v1.md.

Operations:
- `admission`: a trace of `pressure` / `blocked` / `acquire` / `release`
  events; after each event the projection `{level, reservations, waiters}`
  (request ids in grant / FIFO order) must match;
- `darwin-level`: `kern.memorystatus_vm_pressure_level` -> level;
- `memory-load`: Windows `MEMORYSTATUSEX.dwMemoryLoad` percent -> level.
"""

import argparse
import json
from copy import deepcopy
from pathlib import Path

CONTRACT = "ingestion-memory-pressure"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/ingestion-memory-pressure-v1.json"

LEVELS = ["normal", "warning", "critical"]
WARNING_CONCURRENCY = 1
WARNING_LOAD_PERCENT = 85
CRITICAL_LOAD_PERCENT = 95
DARWIN = {1: "normal", 2: "warning", 4: "critical"}


def concurrency(level: str, max_extractions: int) -> int:
    return {"normal": max_extractions, "warning": min(WARNING_CONCURRENCY, max_extractions), "critical": 0}[level]


class Admission:
    """Strict-FIFO admission with a pressure-graded concurrency limit."""

    def __init__(self, max_extractions: int, memory_bytes: int):
        self.max = max_extractions
        self.budget = memory_bytes
        self.level = "normal"
        self.reservations = []  # (requestId, bytes)
        self.waiters = []

    def can_grant(self, amount: int) -> bool:
        if len(self.reservations) >= concurrency(self.level, self.max):
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

    def release(self, request: str) -> None:
        self.reservations = [r for r in self.reservations if r[0] != request]
        self.drain()

    def set_level(self, level: str) -> None:
        assert level in LEVELS
        self.level = level
        self.drain()

    def project(self) -> dict:
        return dict(level=self.level, reservations=[r for r, _ in self.reservations], waiters=[w for w, _ in self.waiters])


def trace(name: str, steps: list, max_extractions: int = 2, memory_bytes: int = 536870912) -> dict:
    admission = Admission(max_extractions, memory_bytes)
    events = []
    for step in steps:
        op = step[0]
        if op == "pressure":
            admission.set_level(step[1])
            event = dict(operation=op, level=step[1])
        elif op == "blocked":
            # folder-rag-v1 boolean form: true = critical, false = normal.
            admission.set_level("critical" if step[1] else "normal")
            event = dict(operation=op, blocked=step[1])
        elif op == "acquire":
            admission.acquire(step[1], step[2])
            event = dict(operation=op, requestId=step[1], bytes=step[2])
        elif op == "release":
            admission.release(step[1])
            event = dict(operation=op, requestId=step[1])
        else:
            raise SystemExit("gen_memory_pressure_fixtures: unknown operation " + op)
        event["expected"] = deepcopy(admission.project())
        events.append(event)
    return dict(name=name, operation="admission",
                input=dict(maxExtractions=max_extractions, memoryBytes=memory_bytes, events=events),
                expected=deepcopy(events[-1]["expected"]))


ADMISSION = [
    trace("warning-admits-one", [
        ("pressure", "warning"), ("acquire", "a", 10), ("acquire", "b", 10), ("release", "a"), ("release", "b")]),
    trace("warning-keeps-granted-work", [
        ("acquire", "a", 10), ("acquire", "b", 10), ("pressure", "warning"), ("acquire", "c", 10),
        ("release", "a"), ("release", "b"), ("release", "c")]),
    trace("critical-pauses-new-work", [
        ("acquire", "a", 10), ("pressure", "critical"), ("acquire", "b", 10), ("release", "a"),
        ("pressure", "normal")]),
    trace("critical-to-warning-grants-one", [
        ("pressure", "critical"), ("acquire", "a", 10), ("acquire", "b", 10), ("pressure", "warning"),
        ("release", "a"), ("pressure", "normal")]),
    trace("warning-to-normal-grants-second", [
        ("pressure", "warning"), ("acquire", "a", 10), ("acquire", "b", 10), ("pressure", "normal")]),
    trace("repeated-level-is-idempotent", [
        ("pressure", "warning"), ("pressure", "warning"), ("acquire", "a", 10), ("pressure", "warning"),
        ("acquire", "b", 10), ("pressure", "normal"), ("pressure", "normal")]),
    trace("warning-oversize-runs-alone", [
        ("pressure", "warning"), ("acquire", "a", 600000000), ("acquire", "b", 10), ("release", "a")]),
    trace("warning-keeps-fifo", [
        ("acquire", "a", 400000000), ("pressure", "warning"), ("acquire", "b", 400000000), ("acquire", "c", 10),
        ("release", "a"), ("release", "b")]),
    trace("blocked-flag-is-critical", [
        ("blocked", True), ("acquire", "a", 10), ("blocked", False), ("acquire", "b", 10)]),
    trace("single-slot-warning", [
        ("pressure", "warning"), ("acquire", "a", 10), ("acquire", "b", 10), ("release", "a")], max_extractions=1),
]

DARWIN_CASES = [(raw, DARWIN.get(raw, "normal")) for raw in [0, 1, 2, 3, 4, 8, -1]]
LOAD_CASES = [(p, "critical" if p >= CRITICAL_LOAD_PERCENT else "warning" if p >= WARNING_LOAD_PERCENT else "normal")
              for p in [0, 50, 84, 85, 90, 94, 95, 99, 100]]


def build() -> dict:
    cases = list(ADMISSION)
    cases += [dict(name=f"darwin-{raw}", operation="darwin-level", input=raw, expected=level) for raw, level in DARWIN_CASES]
    cases += [dict(name=f"load-{p}", operation="memory-load", input=p, expected=level) for p, level in LOAD_CASES]
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_memory_pressure_fixtures: duplicate case name")
    return dict(contract=CONTRACT, version=VERSION, levels=LEVELS, warningConcurrency=WARNING_CONCURRENCY,
                warningLoadPercent=WARNING_LOAD_PERCENT, criticalLoadPercent=CRITICAL_LOAD_PERCENT, cases=cases)


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check: bool = False) -> None:
    path = root / OUTPUT
    data = encoded()
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("ingestion-memory-pressure-v1.json is stale")
        print("ingestion-memory-pressure-v1.json is current")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
