#!/usr/bin/env python3
"""ingestion-scan-cadence-v1 reference: when the periodic reconciler rescans a watched folder.

The reconciler still runs every `periodicReconcileMinutes` (lease recovery,
retry requeue, upgrade requeue). A watch-enabled folder whose native watch is
healthy is only re-verified (a plain stat-only scan) every
`watchedVerifyHours`; a folder without a healthy watch keeps the old cadence
(every pass). Runtime start always scans every watch-enabled folder. Swift and
C# (`FolderReconciler.verifyDue` / `FolderReconciler.VerifyDue`) must
reproduce every case exactly. Normative text:
docs/contracts/ingestion-scan-perf-v1.md §4.

Operation `verify-due`: input `{startup, watchHealthy, lastFullScanAt,
lastRequestedAt, now}` (epoch seconds, null = never) -> expected bool.

Operation `wake-gap`: input `{previous, now}` — lease-clock seconds of two
consecutive runtime scheduler ticks (which run every 100 ms) -> whether the
process was suspended (system sleep) and every watched folder gets one
debounced stat-only rescan (`FolderIngestionRuntime.suspendedBetween` /
`SuspendedBetween`).

Operation `unreadable-file` (addendum §5): one scan of the fixed tree
`{a.md, b.md, sub/{b.md, c.md}}` with published sources seeded for `known`
(paths absent from disk are seeded too) where reading `failing` fails with
`error` (`permissionDenied`, `vanished`, `changedDuringRead`, `becameLink`).
The failing file is not observed at all: only its directory and ancestors
become incomplete (so nothing in them is marked missing), sibling subtrees
complete normally, a known source keeps its published state and is not
re-extracted, and the scan finishes `partial` without an error. Expected:
`{folder: {scanState, lastScanError}, inventory, sources, queuedExtracts}`
(inventory = paths observed by this scan; sources = every folder source
sorted by path; queuedExtracts = paths of queued extract jobs).
"""

import argparse
import json
from pathlib import Path

CONTRACT = "ingestion-scan-cadence"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/ingestion-scan-cadence-v1.json"

PERIODIC_RECONCILE_MINUTES = 30
WATCHED_VERIFY_HOURS = 6
VERIFY_SECONDS = WATCHED_VERIFY_HOURS * 3600
WAKE_GAP_SECONDS = 60


def verify_due(startup: bool, watch_healthy: bool, last_full_scan_at, last_requested_at, now: int) -> bool:
    if startup or not watch_healthy:
        return True
    known = [t for t in (last_full_scan_at, last_requested_at) if t is not None]
    if not known:
        return True
    return now - max(known) >= VERIFY_SECONDS


def suspended_between(previous: int, now: int) -> bool:
    return now - previous >= WAKE_GAP_SECONDS


def wake(name: str, previous: int, now: int) -> dict:
    return dict(name=name, operation="wake-gap", input=dict(previous=previous, now=now),
                expected=suspended_between(previous, now))


def case(name: str, startup: bool, healthy: bool, full, requested, now: int) -> dict:
    return dict(name=name, operation="verify-due",
                input=dict(startup=startup, watchHealthy=healthy, lastFullScanAt=full, lastRequestedAt=requested, now=now),
                expected=verify_due(startup, healthy, full, requested, now))


T = 1_800_000_000
CASES = [
    case("startup-healthy-recent", True, True, T, T, T + 60),
    case("startup-unhealthy", True, False, None, None, T),
    case("unhealthy-every-pass", False, False, T, T, T + 1800),
    case("unhealthy-never-scanned", False, False, None, None, T),
    case("healthy-never-scanned", False, True, None, None, T),
    case("healthy-recent-full-scan", False, True, T, None, T + 1800),
    case("healthy-just-before-interval", False, True, T, None, T + VERIFY_SECONDS - 1),
    case("healthy-at-interval", False, True, T, None, T + VERIFY_SECONDS),
    case("healthy-recent-request-partial-scan", False, True, None, T, T + 3600),
    case("healthy-old-full-recent-request", False, True, T - 86400, T, T + 3600),
    case("healthy-recent-full-old-request", False, True, T, T - 86400, T + 3600),
    case("healthy-both-old", False, True, T - 86400, T - 43200, T),
    case("healthy-clock-behind", False, True, T, None, T - 100),
    wake("wake-steady-ticks", T, T),
    wake("wake-slow-tick", T, T + 5),
    wake("wake-just-below-gap", T, T + WAKE_GAP_SECONDS - 1),
    wake("wake-at-gap", T, T + WAKE_GAP_SECONDS),
    wake("wake-overnight", T, T + 8 * 3600),
    wake("wake-clock-set-back", T, T - 3600),
]


TREE_FILES = ["a.md", "b.md", "sub/b.md", "sub/c.md"]
UNREADABLE_ERRORS = ["permissionDenied", "vanished", "changedDuringRead", "becameLink"]


def parent(path: str) -> str:
    return path.rsplit("/", 1)[0] if "/" in path else ""


def ancestors(path: str) -> set:
    found, current = set(), parent(path)
    while True:
        found.add(current)
        if current == "":
            return found
        current = parent(current)


def unreadable(name: str, failing: str, error: str, known: list) -> dict:
    assert failing in TREE_FILES and error in UNREADABLE_ERRORS
    incomplete = ancestors(failing)
    observed = sorted(p for p in TREE_FILES if p != failing)
    sources = []
    for path in sorted(set(known) | set(observed)):
        if path in known:
            on_disk = path in TREE_FILES
            # Missing-marking only inside completed directories; an unobserved file in an incomplete one is kept.
            missing = not on_disk and parent(path) not in incomplete
            sources.append(dict(relPath=path, status="ready", availability="missing" if missing else "present",
                                eligible=True))
        else:
            sources.append(dict(relPath=path, status="pending", availability="present", eligible=True))
    queued = sorted(p for p in observed if p not in known)
    return dict(name=name, operation="unreadable-file", input=dict(failing=failing, error=error, known=sorted(known)),
                expected=dict(folder=dict(scanState="partial" if incomplete else "idle", lastScanError=None),
                              inventory=observed, sources=sources, queuedExtracts=queued))


GONE = ["gone.md", "sub/gone.md"]
CASES += [
    unreadable("unreadable-new-permission-denied", "b.md", "permissionDenied", GONE),
    unreadable("unreadable-known-permission-denied", "b.md", "permissionDenied", GONE + ["b.md"]),
    unreadable("unreadable-new-in-subdirectory", "sub/b.md", "permissionDenied", GONE),
    unreadable("unreadable-known-in-subdirectory", "sub/b.md", "permissionDenied", GONE + ["sub/b.md"]),
    unreadable("unreadable-new-vanished", "b.md", "vanished", GONE),
    unreadable("unreadable-known-vanished", "sub/b.md", "vanished", GONE + ["sub/b.md"]),
    unreadable("unreadable-known-changed-during-read", "b.md", "changedDuringRead", GONE + ["b.md"]),
    unreadable("unreadable-new-became-link", "sub/b.md", "becameLink", GONE),
]


def build() -> dict:
    names = [c["name"] for c in CASES]
    if len(set(names)) != len(names):
        raise SystemExit("gen_scan_cadence_fixtures: duplicate case name")
    return dict(contract=CONTRACT, version=VERSION, periodicReconcileMinutes=PERIODIC_RECONCILE_MINUTES,
                watchedVerifyHours=WATCHED_VERIFY_HOURS, wakeGapSeconds=WAKE_GAP_SECONDS, cases=CASES)


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check: bool = False) -> None:
    path = root / OUTPUT
    data = encoded()
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("ingestion-scan-cadence-v1.json is stale")
        print("ingestion-scan-cadence-v1.json is current")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
