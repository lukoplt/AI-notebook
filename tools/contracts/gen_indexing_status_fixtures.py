#!/usr/bin/env python3
"""indexing-status-v1 reference: per-notebook indexing status derivation.

Pure functions over an input snapshot (`IndexingInputs`) that the platform
stores read in one batch. Swift (`IndexingStatus.derive`) and C#
(`IndexingStatusDerivation.Derive`) must reproduce every expected output
exactly. Normative text: docs/contracts/indexing-status-v1.md.

Two operations:
- `derive`: IndexingInputs -> IndexingStatus (canonical JSON projection);
- `availability`: provider facts -> EmbeddingAvailability (session factory
  reason instead of nil).

Addendum (§6, 0.15.1): the admission's memory-pressure level is a runtime
fact; `extracting` reports it so a slowed or paused extraction is visible.

Addendum (§7, 0.15.2): a running scan no longer hides extraction/embedding
progress. While a scan is active the work phase (`extracting`/`embedding`)
wins and carries `scanInProgress = true` plus the scan's `filesSeen`; a scan
with no such work stays `scanning` (`scanInProgress = true`).

Addendum (§8, 0.15.3): which embed job feeds `embedJob` (operation
`embedJob`). An unfinished job beats a finished one and a running job beats
every other, so a bootstrap queued behind a running generation build no longer
hides its progress; a copy-existing bootstrap whose selection matches a
building generation reports that generation's progress (not "preparing").
"""

import argparse
import json
from pathlib import Path
from typing import Optional

CONTRACT = "indexing-status"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/indexing-status-v1.json"

PHASES = ["scanning", "extracting", "embedding", "retrying", "blocked", "ready", "lexicalOnly", "empty"]
ACTIVE = {"scanning", "extracting", "embedding", "retrying"}
MEMORY_PRESSURE = ("normal", "warning", "critical")
WARNING_STATES = ("partial", "error", "unavailable")
AVAILABILITY_REASON = {
    "noProvider": "noEmbeddingModel",
    "noModel": "noEmbeddingModel",
    "providerHasNoEmbeddings": "noEmbeddingModel",
    "providerDisabled": "providerDisabled",
    "consentRequired": "consentRequired",
    "credentialUnavailable": "credentialUnavailable",
}


def _status(i: dict, phase: str, **fields) -> dict:
    out = dict(phase=phase, filesSeen=None, done=None, total=None, preparing=False, retry=None,
               blockedReason=None, errorCode=None, memoryPressure=None, scanInProgress=False, sourceErrors=i["sourcesError"],
               scanWarnings=[dict(folderId=f["folderId"], state=f["scanState"], error=f["lastScanError"])
                             for f in i["folders"] if f["scanState"] in WARNING_STATES],
               isActive=phase in ACTIVE)
    for key, value in fields.items():
        if key not in out:
            raise SystemExit("gen_indexing_status_fixtures: unknown field " + key)
        out[key] = value
    return out


def _waiting(job: dict, now: int) -> bool:
    """An embed job waiting for its automatic retry deadline."""
    retry = job["nextRetryAt"]
    if job["state"] == "failed":
        return job["attempts"] < 5 and retry is not None
    return job["state"] == "queued" and retry is not None and retry > now


def derive(i: dict) -> dict:
    if i["runtimeError"] is not None:
        return _status(i, "blocked", blockedReason="runtimeFailed", errorCode=i["runtimeError"])
    scanning = [f for f in i["folders"] if f["scanState"] == "scanning"]
    if scanning or i["scanJobsPending"] > 0:
        # §7: progress of extraction/embedding is never hidden behind a running scan.
        seen = [f["filesSeen"] for f in scanning if f["filesSeen"] is not None]
        files_seen = sum(seen) if seen else None
        work = _work(i)
        if work is not None:
            work["scanInProgress"] = True
            work["filesSeen"] = files_seen
            return work
        return _status(i, "scanning", filesSeen=files_seen, scanInProgress=True)
    return _work(i) or _settled(i)


def _work(i: dict) -> Optional[dict]:
    """Steps 3-4 without retrying: extraction or a non-waiting embed job; None otherwise."""
    if i["extractQueued"] + i["extractRunning"] > 0:
        total = i["sourcesTotal"]
        pressure = i["memoryPressure"]
        if pressure not in MEMORY_PRESSURE:
            raise SystemExit("gen_indexing_status_fixtures: unknown memory pressure " + pressure)
        return _status(i, "extracting", done=min(total, i["sourcesReady"] + i["sourcesError"]), total=total,
                       memoryPressure=None if pressure == "normal" else pressure)
    job = i["embedJob"]
    if job is not None and not _waiting(job, i["now"]) and (job["state"] == "running" or job["state"] == "queued"):
        if job["bootstrap"]:
            return _status(i, "embedding", preparing=True)
        total = i["embedChunksTotal"]
        if total <= 0:
            return _status(i, "embedding")
        return _status(i, "embedding", done=min(total, i["embedChunksDone"]), total=total)
    return None


def _settled(i: dict) -> dict:
    """Steps 4 (retrying) to 9."""
    now = i["now"]
    job = i["embedJob"]
    if job is not None:
        if _waiting(job, now):
            retry_at = job["nextRetryAt"]
            return _status(i, "retrying", retry=dict(code=job["errorCode"] or "unknown", retryAt=retry_at,
                                                     attempt=job["attempts"], retryInSeconds=max(0, retry_at - now)))
    if i["sourcesTotal"] == 0:
        return _status(i, "empty")
    availability = i["embeddingAvailability"]
    if availability != "ready":
        return _status(i, "blocked", blockedReason=AVAILABILITY_REASON[availability])
    terminal = job is not None and job["state"] == "failed" and not _waiting(job, now)
    if terminal and i["needsEmbedding"]:
        return _status(i, "blocked", blockedReason="indexFailed", errorCode=job["errorCode"] or "unknown")
    if not i["needsEmbedding"]:
        return _status(i, "ready")
    return _status(i, "lexicalOnly")


# §8 (0.15.3): the embed job behind `embedJob` and the generation behind the chunk counts.
SELECTION_FIELDS = ("providerId", "endpointRevision", "model", "modelDigest", "normalization",
                    "queryFormatVersion", "docFormatVersion", "chunkerVersion")


def compatible(selection: dict, identity: dict) -> bool:
    """Same vector space: every field equal; an unknown selection dimension matches any."""
    if any(selection[key] != identity[key] for key in SELECTION_FIELDS):
        return False
    return selection["dims"] is None or selection["dims"] == identity["dims"]


def unfinished(job: dict) -> bool:
    """queued|running|paused, or failed with an automatic retry pending."""
    state = job["state"]
    if state in ("queued", "running", "paused"):
        return True
    return state == "failed" and job["attempts"] < 5 and job["nextRetryAt"] is not None


def _rank(job: dict) -> int:
    if job["state"] == "running":
        return 0
    return 1 if unfinished(job) else 2


def embed_job(e: dict) -> dict:
    """Running first, then any other unfinished job, then finished ones; the highest id within a class."""
    jobs = e["jobs"]
    if not jobs:
        return dict(embedJob=None, progressGenerationId=None)
    pick = min(jobs, key=lambda j: (_rank(j), -j["id"]))
    target = pick["target"]
    bootstrap, progress = False, None
    if target.startswith("generation:"):
        progress = int(target[len("generation:"):])
    elif target.startswith("notebook:"):
        bootstrap = True
        options = pick["options"]
        if options is not None and options["copyExisting"]:
            building = [g["id"] for g in e["generations"]
                        if g["state"] == "building" and compatible(options["selection"], g["identity"])]
            if building:
                bootstrap, progress = False, max(building)
    else:
        raise SystemExit("gen_indexing_status_fixtures: bad target " + target)
    return dict(embedJob=dict(state=pick["state"], attempts=pick["attempts"], nextRetryAt=pick["nextRetryAt"],
                              errorCode=pick["error"], bootstrap=bootstrap), progressGenerationId=progress)


def availability(a: dict) -> str:
    """Checks run in this order; the key is loaded only after every cheaper check passed."""
    if not a["configured"]:
        return "noProvider"
    if not a["supportsEmbeddings"]:
        return "providerHasNoEmbeddings"
    if not a["enabled"]:
        return "providerDisabled"
    if a["model"].strip() == "":
        return "noModel"
    if a["cloud"] and not a["privacyAcknowledged"]:
        return "consentRequired"
    if a["keyLoadFails"]:
        return "credentialUnavailable"
    return "ready"


def inputs(**over) -> dict:
    base = dict(now=1000, runtimeError=None, embeddingAvailability="ready", folders=[], scanJobsPending=0,
                extractQueued=0, extractRunning=0, sourcesTotal=3, sourcesReady=3, sourcesError=0,
                needsEmbedding=False, embedJob=None, embedChunksDone=0, embedChunksTotal=0, memoryPressure="normal")
    for key in over:
        if key not in base:
            raise SystemExit("gen_indexing_status_fixtures: unknown input " + key)
    base.update(over)
    return base


def folder(folder_id: int, state: str, error: Optional[str] = None, seen: Optional[int] = None) -> dict:
    return dict(folderId=folder_id, scanState=state, lastScanError=error, filesSeen=seen)


def job(state: str, attempts: int = 1, retry: Optional[int] = None, error: Optional[str] = None,
        bootstrap: bool = False) -> dict:
    return dict(state=state, attempts=attempts, nextRetryAt=retry, errorCode=error, bootstrap=bootstrap)


DERIVE = [
    ("empty-notebook", inputs(sourcesTotal=0, sourcesReady=0)),
    ("empty-ignores-missing-provider", inputs(sourcesTotal=0, sourcesReady=0, embeddingAvailability="noProvider")),
    ("ready", inputs()),
    ("ready-nothing-to-embed", inputs(needsEmbedding=False, embedJob=job("done"))),
    ("lexical-only", inputs(needsEmbedding=True)),
    ("lexical-only-after-selection-change", inputs(needsEmbedding=True,
        embedJob=job("cancelled", error="embeddingSelectionChanged"))),
    ("lexical-only-paused-job", inputs(needsEmbedding=True, embedJob=job("paused", attempts=0))),
    ("scanning-folder-state", inputs(folders=[folder(1, "scanning", seen=12)])),
    ("scanning-queued-job", inputs(folders=[folder(1, "idle")], scanJobsPending=1)),
    ("scanning-sums-files", inputs(folders=[folder(1, "scanning", seen=5), folder(2, "scanning", seen=7),
                                            folder(3, "scanning"), folder(4, "idle", seen=99)])),
    ("scanning-unknown-count", inputs(folders=[folder(1, "scanning")])),
    ("scanning-beats-extracting", inputs(folders=[folder(1, "scanning", seen=3)], extractQueued=2)),
    ("extracting", inputs(extractQueued=2, extractRunning=1, sourcesTotal=10, sourcesReady=6, sourcesError=1)),
    ("extracting-clamps-done", inputs(extractRunning=1, sourcesTotal=2, sourcesReady=2, sourcesError=1)),
    ("extracting-memory-warning", inputs(extractQueued=500, sourcesTotal=6000, sourcesReady=5500,
        memoryPressure="warning")),
    ("extracting-memory-critical", inputs(extractQueued=700, sourcesTotal=6000, sourcesReady=5300,
        memoryPressure="critical")),
    ("extracting-memory-critical-running", inputs(extractRunning=1, sourcesTotal=4, sourcesReady=2,
        memoryPressure="critical")),
    ("scanning-ignores-memory-pressure", inputs(folders=[folder(1, "scanning", seen=3)], extractQueued=2,
        memoryPressure="critical")),
    ("embedding-ignores-memory-pressure", inputs(needsEmbedding=True, embedJob=job("running"), embedChunksDone=1,
        embedChunksTotal=2, memoryPressure="critical")),
    ("ready-ignores-memory-pressure", inputs(memoryPressure="warning")),
    ("runtime-failed-ignores-memory-pressure", inputs(runtimeError="unexpectedError", extractQueued=3,
        memoryPressure="critical")),
    ("extracting-beats-embedding", inputs(extractQueued=1, sourcesTotal=4, sourcesReady=1,
        embedJob=job("running"), embedChunksDone=1, embedChunksTotal=9)),
    ("embedding-generation", inputs(needsEmbedding=True, embedJob=job("running"), embedChunksDone=40,
        embedChunksTotal=100)),
    ("embedding-bootstrap", inputs(needsEmbedding=True, embedJob=job("running", bootstrap=True),
        embedChunksDone=5, embedChunksTotal=10)),
    ("embedding-queued-due", inputs(needsEmbedding=True, embedJob=job("queued", attempts=0), embedChunksTotal=8)),
    ("embedding-queued-deadline-passed", inputs(needsEmbedding=True, embedJob=job("queued", retry=900),
        embedChunksDone=2, embedChunksTotal=8)),
    ("embedding-queued-deadline-now", inputs(needsEmbedding=True, embedJob=job("queued", retry=1000),
        embedChunksTotal=8)),
    ("embedding-unknown-total", inputs(needsEmbedding=True, embedJob=job("running"))),
    ("embedding-clamps-done", inputs(needsEmbedding=True, embedJob=job("running"), embedChunksDone=12,
        embedChunksTotal=10)),
    ("embedding-beats-blocked", inputs(needsEmbedding=True, embeddingAvailability="providerDisabled",
        embedJob=job("running"), embedChunksDone=1, embedChunksTotal=2)),
    ("retrying-failed", inputs(needsEmbedding=True, embedJob=job("failed", attempts=2, retry=1120,
        error="providerUnreachable"))),
    ("retrying-lease-expired", inputs(needsEmbedding=True, embedJob=job("queued", attempts=1, retry=1060,
        error="leaseExpired"))),
    ("retrying-overdue", inputs(needsEmbedding=True, embedJob=job("failed", attempts=4, retry=990,
        error="providerTimeout"))),
    ("retrying-deadline-now", inputs(needsEmbedding=True, embedJob=job("failed", attempts=3, retry=1000,
        error="providerHttp503"))),
    ("retrying-without-code", inputs(needsEmbedding=True, embedJob=job("failed", attempts=1, retry=1060))),
    ("retrying-beats-blocked", inputs(needsEmbedding=True, embeddingAvailability="providerDisabled",
        embedJob=job("failed", attempts=1, retry=1060, error="providerUnreachable"))),
    ("blocked-no-provider", inputs(embeddingAvailability="noProvider", needsEmbedding=True)),
    ("blocked-no-model", inputs(embeddingAvailability="noModel", needsEmbedding=True)),
    ("blocked-provider-has-no-embeddings", inputs(embeddingAvailability="providerHasNoEmbeddings",
        needsEmbedding=True)),
    ("blocked-provider-disabled", inputs(embeddingAvailability="providerDisabled", needsEmbedding=True)),
    ("blocked-consent", inputs(embeddingAvailability="consentRequired", needsEmbedding=True)),
    ("blocked-credential", inputs(embeddingAvailability="credentialUnavailable", needsEmbedding=True)),
    ("blocked-even-when-index-current", inputs(embeddingAvailability="noModel", needsEmbedding=False)),
    ("index-failed", inputs(needsEmbedding=True, embedJob=job("failed", attempts=5, error="providerHttp500"))),
    ("index-failed-exhausted-with-deadline", inputs(needsEmbedding=True,
        embedJob=job("failed", attempts=5, retry=1200, error="invalidVector"))),
    ("index-failed-without-code", inputs(needsEmbedding=True, embedJob=job("failed", attempts=2))),
    ("index-failed-but-current", inputs(needsEmbedding=False, embedJob=job("failed", attempts=5,
        error="providerHttp500"))),
    ("availability-beats-index-failed", inputs(needsEmbedding=True, embeddingAvailability="consentRequired",
        embedJob=job("failed", attempts=5, error="providerAuth"))),
    ("runtime-failed", inputs(runtimeError="unexpectedError", folders=[folder(1, "scanning", seen=2)],
        scanJobsPending=1, extractQueued=3)),
    ("runtime-failed-empty", inputs(runtimeError="notFound", sourcesTotal=0, sourcesReady=0)),
    ("scan-warnings", inputs(folders=[folder(1, "partial"), folder(2, "error", error="permissionDenied"),
                                      folder(3, "unavailable", error="rootUnavailable"), folder(4, "idle")],
                             sourcesTotal=5, sourcesReady=3, sourcesError=2)),
    ("scan-warnings-while-scanning", inputs(folders=[folder(1, "scanning", seen=4),
                                                     folder(2, "error", error="unexpectedError")])),
    # §7 (0.15.2): a running scan shows the work phase with scanInProgress.
    ("scan-with-embedding", inputs(folders=[folder(1, "scanning", seen=2100)], needsEmbedding=True,
        embedJob=job("running"), embedChunksDone=210000, embedChunksTotal=530000)),
    ("scan-queued-with-embedding", inputs(folders=[folder(1, "idle")], scanJobsPending=1, needsEmbedding=True,
        embedJob=job("running"), embedChunksDone=5, embedChunksTotal=9)),
    ("scan-with-embedding-bootstrap", inputs(folders=[folder(1, "scanning", seen=3)], needsEmbedding=True,
        embedJob=job("running", bootstrap=True))),
    ("scan-with-extracting", inputs(folders=[folder(1, "scanning", seen=40)], extractQueued=3, extractRunning=1,
        sourcesTotal=50, sourcesReady=20, embedJob=job("running"), embedChunksDone=1, embedChunksTotal=9)),
    ("scan-hides-retry", inputs(folders=[folder(1, "scanning", seen=8)], needsEmbedding=True,
        embedJob=job("failed", attempts=2, retry=1120, error="providerUnreachable"))),
    ("scan-without-work", inputs(folders=[folder(1, "scanning", seen=8), folder(2, "partial")], needsEmbedding=True)),
    ("scan-with-embedding-unknown-count", inputs(folders=[folder(1, "scanning")], needsEmbedding=True,
        embedJob=job("queued", attempts=0))),
]


def identity(**over) -> dict:
    base = dict(providerId="ollama", endpointRevision="e1", model="nomic-embed-text", modelDigest=None, dims=768,
                normalization="l2", queryFormatVersion="2", docFormatVersion="2", chunkerVersion="2")
    for key in over:
        if key not in base:
            raise SystemExit("gen_indexing_status_fixtures: unknown identity field " + key)
    base.update(over)
    return base


def selection(**over) -> dict:
    """A raw-provider selection: dimensions unknown until the first response."""
    return identity(**dict(dict(dims=None), **over))


def generation(gid: int, state: str, **over) -> dict:
    return dict(id=gid, state=state, identity=identity(**over))


def embed(jid: int, target: str, state: str, attempts: int = 0, retry: Optional[int] = None,
          error: Optional[str] = None, copy: Optional[bool] = True, sel: Optional[dict] = None) -> dict:
    """An embed job row; `copy=None` = options that do not decode."""
    options = None if copy is None else dict(copyExisting=copy, selection=sel or selection())
    return dict(id=jid, target=target, state=state, attempts=attempts, nextRetryAt=retry, error=error, options=options)


EMBED_JOB = [
    ("no-jobs", dict(jobs=[], generations=[])),
    ("generation-running", dict(jobs=[embed(165, "generation:1", "running", 1, sel=identity())],
                                generations=[generation(1, "building")])),
    ("bootstrap-queued-without-generation", dict(jobs=[embed(778, "notebook:1", "queued")], generations=[])),
    # The reported DB: generation 1 building (768 dims) with running job 165; a publication queued bootstrap 778.
    ("running-generation-job-and-queued-bootstrap", dict(
        jobs=[embed(165, "generation:1", "running", 1, sel=identity()), embed(778, "notebook:1", "queued")],
        generations=[generation(1, "building")])),
    ("queued-bootstrap-joins-building-generation", dict(
        jobs=[embed(165, "generation:1", "queued", 1, sel=identity()), embed(778, "notebook:1", "queued")],
        generations=[generation(1, "building")])),
    ("queued-bootstrap-joins-newest-building-generation", dict(
        jobs=[embed(778, "notebook:1", "queued")],
        generations=[generation(1, "building"), generation(3, "building"), generation(2, "active")])),
    ("queued-bootstrap-other-model-prepares", dict(
        jobs=[embed(165, "generation:1", "done", 1, sel=identity()), embed(778, "notebook:1", "queued")],
        generations=[generation(1, "building", model="mxbai-embed-large")])),
    ("queued-bootstrap-other-format-prepares", dict(
        jobs=[embed(778, "notebook:1", "queued")],
        generations=[generation(1, "building", queryFormatVersion="1", docFormatVersion="1")])),
    ("queued-bootstrap-other-dims-prepares", dict(
        jobs=[embed(778, "notebook:1", "queued", sel=selection(dims=1024))],
        generations=[generation(1, "building")])),
    ("queued-bootstrap-active-only-prepares", dict(
        jobs=[embed(778, "notebook:1", "queued")], generations=[generation(1, "active")])),
    ("queued-reindex-bootstrap-prepares", dict(
        jobs=[embed(778, "notebook:1", "queued", copy=False)], generations=[generation(1, "building")])),
    ("undecodable-bootstrap-prepares", dict(
        jobs=[embed(778, "notebook:1", "queued", copy=None)], generations=[generation(1, "building")])),
    ("running-bootstrap-beats-queued-generation-job", dict(
        jobs=[embed(3, "notebook:1", "running", 1), embed(5, "generation:2", "queued", sel=identity(model="other"))],
        generations=[generation(2, "building", model="other")])),
    ("waiting-generation-job-beats-newer-finished-bootstrap", dict(
        jobs=[embed(10, "generation:1", "failed", 2, retry=1120, error="providerUnreachable", sel=identity()),
              embed(12, "notebook:1", "done", 1)],
        generations=[generation(1, "building")])),
    ("paused-job-is-unfinished", dict(
        jobs=[embed(10, "generation:1", "paused", 0, sel=identity()), embed(12, "notebook:1", "cancelled")],
        generations=[generation(1, "building")])),
    ("newest-unfinished-wins", dict(
        jobs=[embed(10, "generation:1", "queued", 0, sel=identity()),
              embed(14, "generation:2", "queued", 0, sel=identity(model="other"))],
        generations=[generation(1, "building"), generation(2, "building", model="other")])),
    ("terminal-failure-is-finished", dict(
        jobs=[embed(10, "generation:1", "failed", 5, error="providerHttp500", sel=identity()),
              embed(12, "generation:1", "failed", 5, retry=1200, error="invalidVector", sel=identity()),
              embed(9, "notebook:1", "done", 1)],
        generations=[generation(1, "failed")])),
    ("newest-finished-without-unfinished", dict(
        jobs=[embed(5, "generation:1", "done", 1, sel=identity()), embed(9, "notebook:1", "done")],
        generations=[generation(1, "active")])),
]


def provider(**over) -> dict:
    base = dict(configured=True, supportsEmbeddings=True, enabled=True, model="nomic-embed-text", cloud=False,
                privacyAcknowledged=False, keyLoadFails=False)
    base.update(over)
    return base


AVAILABILITY = [
    ("local-ready", provider()),
    ("cloud-ready", provider(cloud=True, privacyAcknowledged=True, model="text-embedding-3-small")),
    ("not-configured", provider(configured=False)),
    ("no-embeddings", provider(supportsEmbeddings=False, cloud=True, privacyAcknowledged=True)),
    ("no-embeddings-before-disabled", provider(supportsEmbeddings=False, cloud=True, enabled=False)),
    ("disabled", provider(enabled=False)),
    ("disabled-before-model", provider(enabled=False, model="")),
    ("blank-model", provider(model="  ")),
    ("empty-model", provider(model="")),
    ("consent", provider(cloud=True, privacyAcknowledged=False)),
    ("consent-before-key", provider(cloud=True, privacyAcknowledged=False, keyLoadFails=True)),
    ("credential", provider(cloud=True, privacyAcknowledged=True, keyLoadFails=True)),
]


def build() -> dict:
    cases = [dict(name=name, operation="derive", input=value, expected=derive(value)) for name, value in DERIVE]
    cases += [dict(name="availability-" + name, operation="availability", input=value, expected=availability(value))
              for name, value in AVAILABILITY]
    cases += [dict(name="embed-job-" + name, operation="embedJob", input=value, expected=embed_job(value))
              for name, value in EMBED_JOB]
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_indexing_status_fixtures: duplicate case name")
    covered = {c["expected"]["phase"] for c in cases if c["operation"] == "derive"}
    if covered != set(PHASES):
        raise SystemExit("gen_indexing_status_fixtures: phases not covered: " + str(set(PHASES) - covered))
    return dict(contract=CONTRACT, version=VERSION, phases=PHASES, cases=cases)


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check: bool = False) -> None:
    path = root / OUTPUT
    data = encoded()
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("indexing-status-v1.json is stale")
        print("indexing-status-v1.json is current")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
