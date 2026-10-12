#!/usr/bin/env python3
"""ingestion-build-merge-v1 reference: embed work for a selection whose
dimensions are unknown joins an existing generation of the same vector space.

Raw providers (e.g. Ollama `nomic-embed-text`) are selected without verified
dimensions. Before this contract every publication of such a selection queued a
notebook-target bootstrap job, even while a generation of the same space was
building; after the build activated, the bootstrap probed the provider again
and built a redundant second generation. Normative text:
docs/contracts/ingestion-build-merge-v1.md. Swift (`EmbedJobPlanning`) and C#
(`EmbedJobPlanning`) must reproduce every case exactly.

Three pure decisions over durable rows:
- `resolve`: the generation whose verified identity a build request adopts;
- `supersede`: unclaimed bootstrap jobs made redundant by a generation job;
- `startup`: what runtime start does with one existing bootstrap job.
"""

import argparse
import json
from pathlib import Path
from typing import Optional

CONTRACT = "ingestion-build-merge"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/ingestion-build-merge-v1.json"

SELECTION_FIELDS = ("providerId", "endpointRevision", "model", "modelDigest", "normalization",
                    "queryFormatVersion", "docFormatVersion", "chunkerVersion")
STARTUP_ACTIONS = ("keep", "merge", "noop")


def compatible(selection: dict, identity: dict) -> bool:
    """Same vector space: every field equal; an unknown selection dimension matches any."""
    if any(selection[key] != identity[key] for key in SELECTION_FIELDS):
        return False
    return selection["dims"] is None or selection["dims"] == identity["dims"]


def _known(selection: dict) -> bool:
    return selection["dims"] is not None and selection["dims"] > 0


def resolve(i: dict) -> dict:
    """Unknown dimensions + copyExisting: the newest compatible building generation, else the compatible active one."""
    selection = i["selection"]
    if _known(selection) or not i["copyExisting"]:
        return dict(generationId=None)
    for state in ("building", "active"):
        matches = [g["id"] for g in i["generations"] if g["state"] == state and compatible(selection, g["identity"])]
        if matches:
            return dict(generationId=max(matches))
    return dict(generationId=None)


def _unclaimed_bootstrap(job: dict) -> bool:
    """A notebook-target job nobody owns that would still run: queued, paused, or failed with a retry pending."""
    if not job["target"].startswith("notebook:"):
        return False
    state = job["state"]
    if state in ("queued", "paused"):
        return True
    return state == "failed" and job["attempts"] < 5 and job["nextRetryAt"] is not None


def _incremental(job: dict) -> Optional[dict]:
    """The decoded selection of a copy-existing (incremental) bootstrap, else None."""
    options = job["options"]
    if options is None or not options["copyExisting"]:
        return None
    return options["selection"]


def supersede(i: dict) -> list:
    """Bootstraps the generation job of `identity` covers; they complete as no-ops, in id order."""
    out = []
    for job in i["jobs"]:
        selection = _incremental(job)
        if _unclaimed_bootstrap(job) and selection is not None and compatible(selection, i["identity"]):
            out.append(job["id"])
    return sorted(out)


def startup(i: dict) -> str:
    """merge: queue/join the generation job (and complete the bootstrap); noop: complete it; keep: leave it."""
    job = i["job"]
    selection = _incremental(job)
    if not _unclaimed_bootstrap(job) or selection is None:
        return "keep"
    resolved = resolve(dict(selection=selection, copyExisting=True, generations=i["generations"]))["generationId"]
    if resolved is None:
        return "keep"
    state = next(g["state"] for g in i["generations"] if g["id"] == resolved)
    if state == "building" or i["needsEmbedding"]:
        return "merge"
    return "noop"


def identity(**over) -> dict:
    base = dict(providerId="ollama", endpointRevision="e1", model="nomic-embed-text", modelDigest=None, dims=768,
                normalization="l2", queryFormatVersion="2", docFormatVersion="2", chunkerVersion="2")
    for key in over:
        if key not in base:
            raise SystemExit("gen_build_merge_fixtures: unknown identity field " + key)
    base.update(over)
    return base


def selection(**over) -> dict:
    return identity(**dict(dict(dims=None), **over))


def generation(gid: int, state: str, **over) -> dict:
    return dict(id=gid, state=state, identity=identity(**over))


def job(jid: int, state: str, target: str = "notebook:1", attempts: int = 0, retry: Optional[int] = None,
        copy: Optional[bool] = True, sel: Optional[dict] = None) -> dict:
    """`copy=None` = options that do not decode."""
    options = None if copy is None else dict(copyExisting=copy, selection=sel or selection())
    return dict(id=jid, target=target, state=state, attempts=attempts, nextRetryAt=retry, options=options)


def resolve_input(sel: dict, generations: list, copy: bool = True) -> dict:
    return dict(selection=sel, copyExisting=copy, generations=generations)


RESOLVE = [
    ("no-generation", resolve_input(selection(), [])),
    ("building-same-space", resolve_input(selection(), [generation(1, "building")])),
    ("building-beats-active", resolve_input(selection(), [generation(1, "active"), generation(2, "building")])),
    ("building-beats-newer-active", resolve_input(selection(), [generation(2, "building"), generation(3, "active")])),
    ("newest-building", resolve_input(selection(), [generation(1, "building"), generation(4, "building"),
                                                    generation(2, "building", model="other")])),
    ("active-same-space", resolve_input(selection(), [generation(1, "active")])),
    ("failed-and-retired-ignored", resolve_input(selection(), [generation(1, "failed"), generation(2, "retired")])),
    ("known-dims-unchanged", resolve_input(selection(dims=768), [generation(1, "building")])),
    ("reindex-unchanged", resolve_input(selection(), [generation(1, "building")], copy=False)),
    ("other-provider", resolve_input(selection(), [generation(1, "building", providerId="lmstudio")])),
    ("other-endpoint", resolve_input(selection(), [generation(1, "building", endpointRevision="e2")])),
    ("other-model", resolve_input(selection(), [generation(1, "building", model="mxbai-embed-large")])),
    ("other-digest", resolve_input(selection(modelDigest="sha256:a"), [generation(1, "building", modelDigest="sha256:b")])),
    ("same-digest", resolve_input(selection(modelDigest="sha256:a"), [generation(1, "building", modelDigest="sha256:a")])),
    ("other-normalization", resolve_input(selection(), [generation(1, "building", normalization="none")])),
    ("other-raw-format", resolve_input(selection(), [generation(1, "active", queryFormatVersion="1",
                                                                docFormatVersion="1")])),
    ("other-chunker", resolve_input(selection(), [generation(1, "building", chunkerVersion="1")])),
    ("other-space-building-same-space-active", resolve_input(selection(), [generation(1, "active"),
                                                                           generation(2, "building", model="other")])),
]

SUPERSEDE = [
    ("queued-bootstrap", dict(identity=identity(), jobs=[job(778, "queued")])),
    ("running-bootstrap-kept", dict(identity=identity(), jobs=[job(778, "running", attempts=1)])),
    ("paused-bootstrap", dict(identity=identity(), jobs=[job(778, "paused")])),
    ("waiting-bootstrap", dict(identity=identity(), jobs=[job(778, "failed", attempts=2, retry=1120)])),
    ("terminal-bootstrap-kept", dict(identity=identity(), jobs=[job(778, "failed", attempts=5),
                                                                job(779, "failed", attempts=5, retry=1200)])),
    ("finished-bootstraps-kept", dict(identity=identity(), jobs=[job(770, "done"), job(771, "cancelled")])),
    ("reindex-bootstrap-kept", dict(identity=identity(), jobs=[job(778, "queued", copy=False)])),
    ("undecodable-bootstrap-kept", dict(identity=identity(), jobs=[job(778, "queued", copy=None)])),
    ("other-space-kept", dict(identity=identity(), jobs=[job(778, "queued", sel=selection(model="other")),
                                                         job(779, "queued", sel=selection(dims=1024))])),
    ("generation-jobs-kept", dict(identity=identity(), jobs=[job(165, "queued", target="generation:1",
                                                                 sel=identity())])),
    ("several-in-id-order", dict(identity=identity(), jobs=[job(901, "queued"), job(778, "paused"),
                                                            job(800, "running", attempts=1),
                                                            job(850, "queued", sel=selection(dims=768))])),
]

STARTUP = [
    # The reported DB: generation 1 building, its job running; bootstrap 778 queued by a publication.
    ("bootstrap-behind-building-generation", dict(job=job(778, "queued"), generations=[generation(1, "building")],
                                                  needsEmbedding=True)),
    ("bootstrap-behind-building-generation-current", dict(job=job(778, "queued"),
                                                          generations=[generation(1, "building")],
                                                          needsEmbedding=False)),
    ("bootstrap-active-needs-build", dict(job=job(778, "queued"), generations=[generation(1, "active")],
                                          needsEmbedding=True)),
    ("bootstrap-active-current", dict(job=job(778, "queued"), generations=[generation(1, "active")],
                                      needsEmbedding=False)),
    ("bootstrap-without-generation", dict(job=job(778, "queued"), generations=[], needsEmbedding=True)),
    ("bootstrap-other-space", dict(job=job(778, "queued"), generations=[generation(1, "building", model="other"),
                                                                       generation(2, "active", docFormatVersion="1",
                                                                                  queryFormatVersion="1")],
                                   needsEmbedding=True)),
    ("reindex-bootstrap-kept", dict(job=job(778, "queued", copy=False), generations=[generation(1, "building")],
                                    needsEmbedding=True)),
    ("running-bootstrap-kept", dict(job=job(778, "running", attempts=1), generations=[generation(1, "building")],
                                    needsEmbedding=True)),
    ("waiting-bootstrap-merges", dict(job=job(778, "failed", attempts=1, retry=1060),
                                      generations=[generation(1, "building")], needsEmbedding=True)),
    ("undecodable-bootstrap-kept", dict(job=job(778, "queued", copy=None), generations=[generation(1, "building")],
                                        needsEmbedding=True)),
]


def build() -> dict:
    cases = [dict(name="resolve-" + n, operation="resolve", input=v, expected=resolve(v)) for n, v in RESOLVE]
    cases += [dict(name="supersede-" + n, operation="supersede", input=v, expected=supersede(v)) for n, v in SUPERSEDE]
    cases += [dict(name="startup-" + n, operation="startup", input=v, expected=startup(v)) for n, v in STARTUP]
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_build_merge_fixtures: duplicate case name")
    covered = {c["expected"] for c in cases if c["operation"] == "startup"}
    if covered != set(STARTUP_ACTIONS):
        raise SystemExit("gen_build_merge_fixtures: startup actions not covered: " + str(set(STARTUP_ACTIONS) - covered))
    return dict(contract=CONTRACT, version=VERSION, cases=cases)


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check: bool = False) -> None:
    path = root / OUTPUT
    data = encoded()
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("ingestion-build-merge-v1.json is stale")
        print("ingestion-build-merge-v1.json is current")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
