#!/usr/bin/env python3
"""ingestion-reextract-v1 reference: requeue extraction after an extractor upgrade.

Folder sources whose extraction failed terminally under an older bounded
extractor are requeued exactly once per extractor revision, at runtime start
and on every periodic reconciliation. Swift
(`NotebookStore.requeueUpgradedExtractions`) and C#
(`NotebookStore.RequeueUpgradedExtractions`) seed each case into a fresh store
and must reproduce every expected output exactly. Normative text:
docs/contracts/ingestion-reextract-v1.md.

Version 2 (`ingestion-reextract-v2.json`, §7 of the same document) adds the
throttled spreadsheet upgrade: ready folder spreadsheets whose published
revision predates the compact spreadsheet text (`ingestion-xlsx-v2`) are
re-extracted in bounded batches (`requeueSpreadsheetUpgrades` /
`RequeueSpreadsheetUpgrades`). The v1 fixture is unchanged.
"""

import argparse
import copy
import json
from pathlib import Path
from typing import Optional

CONTRACT = "ingestion-reextract"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/ingestion-reextract-v1.json"

# Revision 2: the OOXML/ZIP fixes of b543919, cafa154, c9d6cfd and 857e2d1.
EXTRACTOR_REVISION = 2
OPTIONS_KEY = "extractorRevision"
# Failure codes a newer bounded extractor may resolve for unchanged bytes.
RETRYABLE_CODES = sorted(["corruptArchive", "invalidCell", "invalidRelationship", "missingMainPart",
                          "unexpectedError"])

NOTEBOOK_ID = 1
FOLDER_ID = 1
SOURCE_ID = 101
SEED = dict(notebookId=NOTEBOOK_ID, folder=dict(id=FOLDER_ID, notebookId=NOTEBOOK_ID, rootPath="/docs",
                                                 volumeId="v", components=["docs"], rootFileId="r"))
NOW = 5000


def job_revision(options: dict) -> int:
    """The extractor revision a job ran under; absent or non-integer means 1."""
    value = options.get(OPTIONS_KEY)
    return value if isinstance(value, int) and not isinstance(value, bool) else 1


def unfinished(job: dict) -> bool:
    return job["state"] in ("queued", "running", "paused") or (
        job["state"] == "failed" and job["attempts"] < 5 and job["nextRetryAt"] is not None)


def qualifies(source: dict, jobs: list) -> bool:
    if source["folderId"] is None or source["status"] != "error" or source["error"] not in RETRYABLE_CODES:
        return False
    if source["availability"] != "present" or not source["eligible"]:
        return False
    own = [j for j in jobs if j["kind"] == "extract" and j["target"] == "source:%d" % source["id"]]
    if any(unfinished(j) for j in own):
        return False
    return not any(job_revision(j["options"]) >= EXTRACTOR_REVISION for j in own)


def expect(inp: dict) -> dict:
    source = inp["source"]
    if not qualifies(source, inp["jobs"]):
        return dict(requeued=0, source=dict(status=source["status"], error=source["error"]), newJob=None, notified=[])
    new_job = dict(kind="extract", target="source:%d" % source["id"], targetRevision=source["currentRevision"],
                   state="queued", attempts=0, nextRetryAt=None, error=None, options={OPTIONS_KEY: EXTRACTOR_REVISION})
    return dict(requeued=1, source=dict(status="pending", error=None), newJob=new_job, notified=[source["notebookId"]])


def src(**over) -> dict:
    out = dict(id=SOURCE_ID, notebookId=NOTEBOOK_ID, folderId=FOLDER_ID, relPath="a.docx", status="error",
               error="corruptArchive", availability="present", eligible=True, currentRevision=None,
               publishedRevisionId=None, contentHash=None)
    for key, value in over.items():
        if key not in out:
            raise SystemExit("gen_reextract_fixtures: unknown source field " + key)
        out[key] = value
    return out


def job(job_id: int, state: str = "failed", attempts: int = 5, retry: Optional[int] = None,
        options: Optional[dict] = None, target: str = "source:%d" % SOURCE_ID, kind: str = "extract",
        error: Optional[str] = "corruptArchive", revision: Optional[int] = None) -> dict:
    return dict(id=job_id, kind=kind, target=target, targetRevision=revision, state=state, attempts=attempts,
                nextRetryAt=retry, error=error, options={} if options is None else options)


TERMINAL = job(301)
REVISION_11 = dict(id=11, sourceId=SOURCE_ID, revision=1, contentHash="h1", canonicalText="old text")

CASES = [
    ("legacy-corrupt-archive", dict(source=src(), jobs=[TERMINAL])),
    ("legacy-invalid-relationship", dict(source=src(error="invalidRelationship"),
                                         jobs=[job(301, error="invalidRelationship")])),
    ("legacy-missing-main-part", dict(source=src(error="missingMainPart"), jobs=[job(301, error="missingMainPart")])),
    ("legacy-invalid-cell", dict(source=src(error="invalidCell"), jobs=[job(301, error="invalidCell")])),
    ("legacy-unexpected-error", dict(source=src(error="unexpectedError"), jobs=[job(301, error="unexpectedError")])),
    ("legacy-no-job-row", dict(source=src(), jobs=[])),
    ("explicit-older-revision", dict(source=src(), jobs=[job(301, options={OPTIONS_KEY: 1})])),
    ("non-integer-revision-counts-as-one", dict(source=src(), jobs=[job(301, options={OPTIONS_KEY: "2"})])),
    ("other-options-kept-legacy", dict(source=src(), jobs=[job(301, options={"verifyAll": True})])),
    ("stamped-job-of-other-source", dict(source=src(), jobs=[TERMINAL, job(302, target="source:202",
                                                                            options={OPTIONS_KEY: 2})])),
    ("cancelled-terminal-legacy", dict(source=src(), jobs=[job(301, state="cancelled", attempts=1, error=None)])),
    ("refresh-failure-keeps-published", dict(source=src(currentRevision=11, publishedRevisionId=11, contentHash="h1"),
                                             revisions=[REVISION_11], jobs=[job(301, revision=11)])),
    # Not requeued.
    ("already-retried-current-revision", dict(source=src(), jobs=[TERMINAL, job(302, options={OPTIONS_KEY: 2})])),
    ("future-revision", dict(source=src(), jobs=[job(301, options={OPTIONS_KEY: 3})])),
    ("automatic-retry-pending", dict(source=src(), jobs=[job(301, attempts=2, retry=NOW + 60)])),
    ("queued-job-exists", dict(source=src(), jobs=[TERMINAL, job(302, state="queued", attempts=0, error=None)])),
    ("paused-job-exists", dict(source=src(), jobs=[TERMINAL, job(302, state="paused", attempts=0, error=None)])),
    ("limit-error-not-retryable", dict(source=src(error="textLimit"), jobs=[job(301, error="textLimit")])),
    ("not-downloaded-not-retryable", dict(source=src(error="notDownloaded"), jobs=[job(301, error="notDownloaded")])),
    ("cancelled-error-not-retryable", dict(source=src(error="cancelled"),
                                           jobs=[job(301, state="cancelled", attempts=0, error=None)])),
    ("lease-expired-not-retryable", dict(source=src(error="leaseExpired"), jobs=[job(301, error="leaseExpired")])),
    ("missing-source", dict(source=src(availability="missing"), jobs=[TERMINAL])),
    ("unavailable-root", dict(source=src(availability="unavailable"), jobs=[TERMINAL])),
    ("ineligible-source", dict(source=src(eligible=False), jobs=[TERMINAL])),
    ("ready-source", dict(source=src(status="ready", error=None), jobs=[TERMINAL])),
    ("pending-source", dict(source=src(status="pending", error=None), jobs=[TERMINAL])),
    ("loose-source", dict(source=src(folderId=None, relPath=None), jobs=[TERMINAL])),
]


# --- Version 2: throttled spreadsheet text upgrade (ingestion-reextract-v1.md §7) ---

OUTPUT_V2 = "Tests/fixtures/contracts/ingestion-reextract-v2.json"
SPREADSHEET_TEXT_VERSION = 2          # ingestion-xlsx-v2 textFormatVersion
SPREADSHEET_KEY = "spreadsheetTextVersion"
SPREADSHEET_BATCH = 8
SEED_V2 = dict(notebooks=[1, 2], folders=[
    dict(id=1, notebookId=1, rootPath="/docs", volumeId="v", components=["docs"], rootFileId="r"),
    dict(id=2, notebookId=2, rootPath="/other", volumeId="v", components=["other"], rootFileId="o")])


def spreadsheet_stamp(options: dict) -> int:
    """The spreadsheet text version an upgrade job was queued for; absent or non-integer means 0."""
    value = options.get(SPREADSHEET_KEY)
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def spreadsheet_candidates(inp: dict) -> list:
    revisions = {r["id"]: r for r in inp["revisions"]}
    jobs = [j for j in inp["jobs"] if j["kind"] == "extract"]
    outstanding = sum(1 for j in jobs if unfinished(j) and spreadsheet_stamp(j["options"]) >= SPREADSHEET_TEXT_VERSION)
    room = max(0, SPREADSHEET_BATCH - outstanding)
    out = []
    for source in sorted(inp["sources"], key=lambda s: s["id"]):
        published = revisions.get(source["publishedRevisionId"])
        own = [j for j in jobs if j["target"] == "source:%d" % source["id"]]
        if (source["folderId"] is None or source["type"] != "xlsx" or source["status"] != "ready"
                or source["availability"] != "present" or not source["eligible"] or published is None
                or source["currentRevision"] != source["publishedRevisionId"]
                or published["textFormatVersion"] >= SPREADSHEET_TEXT_VERSION):
            continue
        if any(unfinished(j) for j in own):
            continue
        if any(j["state"] == "failed" and spreadsheet_stamp(j["options"]) >= SPREADSHEET_TEXT_VERSION for j in own):
            continue
        out.append(source)
    return out[:room]


def expect_v2(inp: dict) -> dict:
    chosen = spreadsheet_candidates(inp)
    jobs = [dict(kind="extract", target="source:%d" % s["id"], targetRevision=s["currentRevision"], state="queued",
                 attempts=0, nextRetryAt=None, error=None, options={SPREADSHEET_KEY: SPREADSHEET_TEXT_VERSION})
            for s in chosen]
    notebooks = sorted({s["notebookId"] for s in chosen})
    return dict(requeued=len(chosen), newJobs=jobs, notified=notebooks,
                sources=[dict(id=s["id"], status=s["status"], error=s["error"]) for s in inp["sources"]])


def sheet(source_id: int, revision_id: Optional[int] = None, fmt: int = 1, folder: int = 1, **over) -> tuple:
    """A ready folder spreadsheet and its published revision."""
    revision_id = revision_id or source_id * 10
    source = dict(id=source_id, notebookId=folder, folderId=folder, type="xlsx", relPath="s%d.xlsx" % source_id,
                  status="ready", error=None, availability="present", eligible=True, currentRevision=revision_id,
                  publishedRevisionId=revision_id, contentHash="h%d" % source_id)
    for key, value in over.items():
        if key not in source:
            raise SystemExit("gen_reextract_fixtures: unknown source field " + key)
        source[key] = value
    revision = dict(id=revision_id, sourceId=source_id, revision=1, contentHash="h%d" % source_id,
                    canonicalText="## Sheet1\nA1: old", textFormatVersion=fmt)
    return source, revision


def scenario(*items, jobs=()) -> dict:
    sources, revisions = [], []
    for source, revision in items:
        if source is not None:
            sources.append(source)
        if revision is not None:
            revisions.append(revision)
    return dict(sources=sources, revisions=revisions, jobs=list(jobs))


def sjob(job_id: int, source_id: int, state: str, attempts: int = 1, retry: Optional[int] = None,
         stamp=SPREADSHEET_TEXT_VERSION, error: Optional[str] = None) -> dict:
    options = {} if stamp is None else {SPREADSHEET_KEY: stamp}
    row = job(job_id, state=state, attempts=attempts, retry=retry, options=options, target="source:%d" % source_id,
              error=error, revision=None)
    # A running job holds a lease (storage CHECK); every other state has none.
    row.update(leaseToken="lease-%d" % job_id if state == "running" else None,
               leaseUntil=NOW + 300 if state == "running" else None)
    return row


def _no_revision(source_id):
    source, _ = sheet(source_id, currentRevision=None, publishedRevisionId=None, contentHash=None)
    return source, None


CASES_V2 = [
    ("ready-v1-spreadsheet", scenario(sheet(101))),
    ("macro-enabled-workbook", scenario(sheet(101, relPath="m.xlsm"))),
    ("older-failed-unstamped-job", scenario(sheet(101), jobs=[sjob(301, 101, "failed", 5, stamp=None, error="corruptArchive")])),
    ("older-stamp-failed", scenario(sheet(101), jobs=[sjob(301, 101, "failed", 5, stamp=1, error="textLimit")])),
    ("non-integer-stamp-is-unstamped", scenario(sheet(101), jobs=[sjob(301, 101, "failed", 5, stamp="2", error="textLimit")])),
    ("cancelled-upgrade-requeued", scenario(sheet(101), jobs=[sjob(301, 101, "cancelled", 0)])),
    ("completed-older-jobs", scenario(sheet(101), jobs=[sjob(301, 101, "done", 1, stamp=None)])),
    ("batch-limit", scenario(*[sheet(101 + i) for i in range(10)])),
    ("batch-tops-up-outstanding", scenario(*[sheet(101 + i) for i in range(10)], jobs=[
        sjob(301, 201, "queued", 0), sjob(302, 202, "running", 1), sjob(303, 203, "failed", 2, retry=NOW + 60),
        sjob(304, 204, "failed", 5, error="textLimit"), sjob(305, 205, "done", 1), sjob(306, 206, "cancelled", 0),
        sjob(307, 207, "queued", 0, stamp=None)])),
    ("batch-full", scenario(sheet(101), jobs=[sjob(301 + i, 201 + i, "queued", 0) for i in range(8)])),
    ("two-notebooks", scenario(sheet(101, folder=2), sheet(102), sheet(103, folder=2))),
    # Not requeued.
    ("compact-revision", scenario(sheet(101, fmt=2))),
    ("non-spreadsheet", scenario(sheet(101, type="docx", relPath="a.docx"))),
    ("loose-spreadsheet", scenario(sheet(101, folderId=None, relPath=None))),
    ("pending-source", scenario(sheet(101, status="pending"))),
    ("chunking-source", scenario(sheet(101, status="chunking"))),
    ("error-source", scenario(sheet(101, status="error", error="textLimit"))),
    ("missing-source", scenario(sheet(101, availability="missing"))),
    ("unavailable-root", scenario(sheet(101, availability="unavailable"))),
    ("ineligible-source", scenario(sheet(101, eligible=False))),
    ("never-published", scenario(_no_revision(101))),
    ("newer-revision-pending", scenario(sheet(101, currentRevision=1011), (None, dict(
        id=1011, sourceId=101, revision=2, contentHash="h2", canonicalText="new", textFormatVersion=1)))),
    ("queued-job-exists", scenario(sheet(101), jobs=[sjob(301, 101, "queued", 0, stamp=None)])),
    ("running-job-exists", scenario(sheet(101), jobs=[sjob(301, 101, "running", 1, stamp=None)])),
    ("paused-job-exists", scenario(sheet(101), jobs=[sjob(301, 101, "paused", 0)])),
    ("retry-pending-job-exists", scenario(sheet(101), jobs=[sjob(301, 101, "failed", 2, retry=NOW + 60, error="textLimit")])),
    ("upgrade-failed-terminally", scenario(sheet(101), jobs=[sjob(301, 101, "failed", 5, error="textLimit")])),
    ("future-stamp-failed", scenario(sheet(101), jobs=[sjob(301, 101, "failed", 5, stamp=3, error="textLimit")])),
]


def build_v2() -> dict:
    cases = []
    for name, value in CASES_V2:
        inp = copy.deepcopy(value)
        inp["now"] = NOW
        cases.append(dict(name=name, input=inp, expected=expect_v2(inp)))
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_reextract_fixtures: duplicate v2 case name")
    counts = {c["name"]: c["expected"]["requeued"] for c in cases}
    if (counts["batch-limit"], counts["batch-tops-up-outstanding"], counts["batch-full"]) != (8, 5, 0):
        raise SystemExit("gen_reextract_fixtures: batch cases no longer exercise the throttle")
    return dict(contract=CONTRACT, version=2, spreadsheetTextVersion=SPREADSHEET_TEXT_VERSION,
                spreadsheetOptionsKey=SPREADSHEET_KEY, batchSize=SPREADSHEET_BATCH, seed=SEED_V2, cases=cases)


def build() -> dict:
    cases = []
    for name, value in CASES:
        inp = copy.deepcopy(value)
        inp.setdefault("revisions", [])
        inp["now"] = NOW
        cases.append(dict(name=name, input=inp, expected=expect(inp)))
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_reextract_fixtures: duplicate case name")
    outcomes = {c["expected"]["requeued"] for c in cases}
    if outcomes != {0, 1}:
        raise SystemExit("gen_reextract_fixtures: both outcomes must be covered")
    return dict(contract=CONTRACT, version=VERSION, extractorRevision=EXTRACTOR_REVISION, optionsKey=OPTIONS_KEY,
                retryableCodes=RETRYABLE_CODES, seed=SEED, cases=cases)


def encoded(value: Optional[dict] = None) -> bytes:
    return (json.dumps(build() if value is None else value, ensure_ascii=False, sort_keys=True, indent=2)
            + "\n").encode("utf-8")


def generate(root: Path, check: bool = False) -> None:
    for output, data in ((OUTPUT, encoded()), (OUTPUT_V2, encoded(build_v2()))):
        path = root / output
        name = Path(output).name
        if check:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit(name + " is stale")
            print(name + " is current")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
