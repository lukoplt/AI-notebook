#!/usr/bin/env python3
"""chat-during-scan-v1 reference: chat turns while a folder check runs.

Normative text: docs/contracts/chat-during-scan-v1.md. Swift and C# must
reproduce every case exactly.

Operation `coverage`: input `{snapshot: {searchable, pending, error, skipped,
missing, unavailable, refreshPending, refreshError, isLowerBound},
pinnedFiles}` -> the normalized `PackCorpusCoverage`
(`PackCorpusCoverage.normalized` / `CompatibilityPackDataSource.NormalizedCoverage`).
Every output satisfies the frozen builder invariants of folder-rag-v1:
searchable + pending + error == filesInScope and
refreshPending + refreshError <= filesInScope.

Operation `scope-stale`: input `{before, after}` — the notebook's sources as
`{id, folderId, availability, eligible, published}` rows plus `folders` (folder
ids) — and the scope `.all`. Expected: whether the scope fingerprint differs
(`stale`). Only REVOKED sources (availability <> 'present' or eligible = 0)
and the folder set enter the fingerprint; usable sources, publication and
newly discovered files never make a prepared turn stale.

`staleRepreparations` is how many times a send prepares the same turn again
after `stalePreparedRequest` (nothing was written yet).
"""

import argparse
import json
from pathlib import Path

CONTRACT = "chat-during-scan"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/chat-during-scan-v1.json"
STALE_REPREPARATIONS = 3


def normalized(snapshot: dict, pinned: int) -> dict:
    searchable = max(0, snapshot["searchable"])
    pending = max(0, snapshot["pending"])
    error = max(0, snapshot["error"])
    shortfall = max(0, pinned - (searchable + pending + error))
    files = searchable + pending + error + shortfall
    refresh_pending = min(max(0, snapshot["refreshPending"]), files)
    out = dict(filesInScope=files, searchable=searchable + shortfall, pending=pending, error=error,
               skipped=max(0, snapshot["skipped"]), missing=max(0, snapshot["missing"]),
               unavailable=max(0, snapshot["unavailable"]), refreshPending=refresh_pending,
               refreshError=min(max(0, snapshot["refreshError"]), files - refresh_pending),
               partial=snapshot["isLowerBound"])
    assert out["searchable"] + out["pending"] + out["error"] == out["filesInScope"]
    assert out["refreshPending"] + out["refreshError"] <= out["filesInScope"]
    return out


def snap(searchable=0, pending=0, error=0, skipped=0, missing=0, unavailable=0,
         refresh_pending=0, refresh_error=0, lower=False) -> dict:
    return dict(searchable=searchable, pending=pending, error=error, skipped=skipped, missing=missing,
                unavailable=unavailable, refreshPending=refresh_pending, refreshError=refresh_error,
                isLowerBound=lower)


def coverage(name: str, snapshot: dict, pinned: int) -> dict:
    return dict(name=name, operation="coverage", input=dict(snapshot=snapshot, pinnedFiles=pinned),
                expected=normalized(snapshot, pinned))


def revoked(state: dict) -> tuple:
    rows = sorted((r["id"], r["folderId"], r["availability"], r["eligible"]) for r in state["sources"]
                  if r["availability"] != "present" or not r["eligible"])
    return (tuple(rows), tuple(sorted(state["folders"])))


def src(id: int, availability: str = "present", eligible: bool = True, published: bool = True, folder=1) -> dict:
    return dict(id=id, folderId=folder, availability=availability, eligible=eligible, published=published)


def scope(name: str, before: dict, after: dict) -> dict:
    return dict(name=name, operation="scope-stale", input=dict(before=before, after=after),
                expected=dict(stale=revoked(before) != revoked(after)))


def state(*sources, folders=(1,)) -> dict:
    return dict(sources=list(sources), folders=list(folders))


BASE = state(src(1), src(2), src(3, published=False))
CASES = [
    coverage("consistent", snap(searchable=5, pending=2, error=1, refresh_pending=3, refresh_error=1), 5),
    coverage("pinned-exceeds-counted", snap(searchable=2, pending=1, refresh_pending=1), 5),
    coverage("refresh-exceeds-files", snap(searchable=2, pending=1, refresh_pending=9, refresh_error=7, lower=True), 0),
    coverage("refresh-error-clamped-after-pending", snap(searchable=3, refresh_pending=2, refresh_error=4), 3),
    coverage("negative-counts", snap(searchable=-1, pending=-2, error=1, skipped=-3, refresh_pending=-1, refresh_error=4), 1),
    coverage("empty", snap(), 0),
    coverage("empty-with-pins", snap(missing=2), 2),
    scope("unchanged", BASE, BASE),
    scope("new-file-discovered", BASE, state(src(1), src(2), src(3, published=False), src(4, published=False))),
    scope("first-publication", BASE, state(src(1), src(2), src(3))),
    scope("present-becomes-missing", BASE, state(src(1), src(2, availability="missing"), src(3, published=False))),
    scope("unpublished-becomes-missing", BASE, state(src(1), src(2), src(3, availability="missing", published=False))),
    scope("rule-makes-ineligible", BASE, state(src(1, eligible=False), src(2), src(3, published=False))),
    scope("root-unavailable", BASE, state(src(1, availability="unavailable"), src(2, availability="unavailable"),
                                          src(3, availability="unavailable", published=False))),
    scope("missing-reappears", state(src(1), src(2, availability="missing")), state(src(1), src(2))),
    scope("new-missing-file", BASE, state(src(1), src(2), src(3, published=False), src(5, availability="missing"))),
    scope("folder-added", BASE, state(src(1), src(2), src(3, published=False), folders=(1, 2))),
    scope("folder-removed", state(src(1), src(2), folders=(1, 2)), state(src(1), src(2), folders=(1,))),
]


def build() -> dict:
    names = [c["name"] for c in CASES]
    if len(set(names)) != len(names):
        raise SystemExit("gen_chat_scan_fixtures: duplicate case name")
    return dict(contract=CONTRACT, version=VERSION, staleRepreparations=STALE_REPREPARATIONS, cases=CASES)


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check: bool = False) -> None:
    path = root / OUTPUT
    data = encoded()
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("chat-during-scan-v1.json is stale")
        print("chat-during-scan-v1.json is current")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
