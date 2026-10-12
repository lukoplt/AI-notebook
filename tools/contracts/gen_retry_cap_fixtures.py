#!/usr/bin/env python3
"""ingestion-retry-cap-v1 reference: a file that fails extraction three times is given up.

A source — folder member or loose file — gets a failure budget of three
extraction attempts for the same content, counted across every extract job
(scan-created, foreground, automatic retry, upgrade requeue). After the third failed attempt the source stays
`status='error'` with its last error code, scans neither re-read it (stat fast
path) nor queue extraction for it while the content is unchanged, and the
extractor-upgrade requeue skips it. The budget resets only when the content
changes or the user explicitly retries; a successful publication clears it.
Every extract job stops after three attempts (scan/embed/gc jobs keep five);
the frozen job fixtures that pinned five are superseded case by case
(`supersedes`, §1a), and the generator fails when a frozen case changes.

Each case is a step sequence on one folder (notebook 1, folder 1, file
`a.docx`). Swift (`NotebookStore`) and C# (`NotebookStore`) run every step
against a fresh store and must reproduce every step's `result`, the source
row (`status, error, extractFailures, gaveUp`), the extract jobs in id order
(`state, attempts, nextRetryAt, error, options`) and the indexing status
(`active, sourceErrors`) exactly. Normative text:
docs/contracts/ingestion-retry-cap-v1.md.
"""

import argparse
import copy
import json
from pathlib import Path
from typing import Optional

CONTRACT = "ingestion-retry-cap"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/ingestion-retry-cap-v1.json"

FAILURE_BUDGET = 3          # failed attempts per source and content
EXTRACT_MAX_ATTEMPTS = 3    # attempts of one extract job (other kinds: 5)
LEGACY_MAX_ATTEMPTS = 5     # the `unfinished` predicate keeps its frozen bound
LEASE_SECONDS = 300
EXTRACTOR_REVISION = 2
EXTRACTOR_KEY = "extractorRevision"
RETRY_UNAVAILABLE = "retryUnavailable"
USER_RETRY_KEY = "userRetry"
BACKGROUND_WEB_RETRY = False   # user decision 2026-10-11: only an explicit user action fetches a URL
RETRYABLE_CODES = ["corruptArchive", "invalidCell", "invalidRelationship", "missingMainPart", "unexpectedError"]
MIGRATION = "v21_extract_retry_budget"
SCHEMA_DDL = """
CREATE TABLE source_extract_budget (
 source_id INTEGER PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
 failures INTEGER NOT NULL DEFAULT 0 CHECK(failures>=0),
 content_hash TEXT CHECK(content_hash IS NULL OR length(content_hash)>0)
);
"""

SEED = dict(notebookId=1, folder=dict(id=1, notebookId=1, rootPath="/docs", watchEnabled=False), relPath="a.docx")


class Model:
    """The store semantics the contract fixes, for one folder source."""

    def __init__(self) -> None:
        self.source: Optional[dict] = None
        self.jobs: list = []
        self.revisions = 0
        self.fence: Optional[int] = None

    # --- helpers -------------------------------------------------------------------------------

    @staticmethod
    def unfinished(job: dict) -> bool:
        return job["state"] in ("queued", "running", "paused") or (
            job["state"] == "failed" and job["attempts"] < LEGACY_MAX_ATTEMPTS and job["nextRetryAt"] is not None)

    def gave_up(self) -> bool:
        s = self.source
        return s is not None and s["status"] == "error" and s["failures"] >= FAILURE_BUDGET

    def owns(self, index: int) -> bool:
        """The job still owns the source status: current pointer, no newer claimed extraction."""
        job = self.jobs[index]
        return (self.source["current"] == job["targetRevision"]
                and not any(j["attempts"] > 0 for j in self.jobs[index + 1:]))

    def cancel_unfinished(self, keep: Optional[int] = None) -> None:
        for i, job in enumerate(self.jobs):
            if i != keep and self.unfinished(job):
                job.update(state="cancelled", nextRetryAt=None, lease=None)

    def enqueue(self, options: Optional[dict] = None) -> None:
        self.jobs.append(dict(state="queued", attempts=0, nextRetryAt=None, error=None, lease=None,
                              targetRevision=self.source["current"], options=options or {}))

    def fast_path(self, mtime: int, size: int) -> bool:
        s = self.source
        if s is None or s["mtime"] != mtime or s["size"] != size:
            return False
        published = s["committed"] is not None and s["published"] is not None and s["current"] == s["published"]
        return (published and s["status"] == "ready") or self.gave_up()

    def require_extraction(self, keep_running: bool) -> bool:
        s = self.source
        if s["failures"] >= FAILURE_BUDGET:
            return False  # given up: nothing is queued until the content changes or the user retries
        reusable = None
        for i, job in enumerate(self.jobs):
            if self.unfinished(job) and job["targetRevision"] == s["current"] and (
                    job["state"] in ("queued", "paused") or (keep_running and job["state"] == "running")):
                reusable = i
        if reusable is not None:
            self.cancel_unfinished(keep=reusable)
            if self.jobs[reusable]["state"] != "running":
                s.update(status="pending", error=None)
            return False
        self.cancel_unfinished()
        self.enqueue()
        s.update(status="pending", error=None)
        return True

    def settle_failure(self, index: int, code: str, now: int, lease_expired: bool) -> None:
        job = self.jobs[index]
        owned = self.owns(index)
        if owned:
            self.source["failures"] += 1
        # Without background web retries a loose URL's failed attempt is final: only the user fetches again.
        loose_web = self.source["web"] and not BACKGROUND_WEB_RETRY
        exhausted = (job["attempts"] >= EXTRACT_MAX_ATTEMPTS or (owned and self.source["failures"] >= FAILURE_BUDGET)
                     or loose_web)
        retry = None if exhausted else now + 30 * (1 << job["attempts"])
        state = "failed" if exhausted or not lease_expired else "queued"
        job.update(state=state, nextRetryAt=retry, error=code, lease=None)
        if owned:
            if lease_expired and not exhausted:
                self.source.update(status="pending", error=None)
            else:
                self.source.update(status="error", error=code)

    # --- steps ---------------------------------------------------------------------------------

    def observe(self, at: int, mtime: int, size: int, hash_: str, verify_all: bool = False) -> dict:
        read = verify_all or not self.fast_path(mtime, size)
        observed = hash_ if read else None
        before = len(self.jobs)
        s = self.source
        if s is None:
            self.source = dict(status="pending", error=None, failures=0, hash=observed, mtime=mtime, size=size,
                               committed=None, published=None, current=None, folder=True, readable=True, web=False)
            self.enqueue()
            return dict(read=read, queued=True)
        same_stamp = s["mtime"] == mtime and s["size"] == size
        was_fast = self.fast_path(mtime, size)
        s.update(mtime=mtime, size=size)
        published = s["committed"] is not None and s["published"] is not None and s["current"] == s["published"]
        if observed is not None and published and observed == s["committed"]:
            # The committed bytes are on disk: any pending refresh is superseded.
            if s["status"] != "ready":
                self.cancel_unfinished()
                s.update(status="ready", error=None, failures=0, hash=None)
            return dict(read=read, queued=False)
        if observed is None and was_fast:
            return dict(read=read, queued=False)
        if observed is not None:
            if s["hash"] == observed:
                pass
            elif s["hash"] is None and same_stamp:
                s["hash"] = observed
            else:
                s.update(failures=0, hash=observed)
        elif not same_stamp:
            s.update(failures=0, hash=None)
        self.require_extraction(keep_running=same_stamp)
        return dict(read=read, queued=len(self.jobs) > before)

    def claim(self, at: int) -> dict:
        due = [i for i, j in enumerate(self.jobs) if j["state"] == "queued" and j["attempts"] < LEGACY_MAX_ATTEMPTS
               and (j["nextRetryAt"] is None or j["nextRetryAt"] <= at)]
        due.sort(key=lambda i: (-1 if self.jobs[i]["nextRetryAt"] is None else self.jobs[i]["nextRetryAt"], i))
        for i in due:
            if not self.owns(i):
                self.jobs[i].update(state="cancelled", nextRetryAt=None, lease=None)
                continue
            self.jobs[i].update(state="running", attempts=self.jobs[i]["attempts"] + 1, nextRetryAt=None,
                                lease=at + LEASE_SECONDS, error=None)
            self.source.update(status="chunking", error=None)
            self.fence = i
            return dict(claimed=True)
        self.fence = None
        return dict(claimed=False)

    def fail(self, at: int, code: str) -> dict:
        i = self.fence
        if i is None or self.jobs[i]["state"] != "running" or self.jobs[i]["lease"] <= at:
            return dict(failed=False)
        self.settle_failure(i, code, at, lease_expired=False)
        self.fence = None
        return dict(failed=True)

    def expire(self, at: int) -> dict:
        expired = [i for i, j in enumerate(self.jobs) if j["state"] == "running" and j["lease"] <= at]
        for i in expired:
            self.settle_failure(i, "leaseExpired", at, lease_expired=True)
        return dict(recovered=len(expired))

    def requeue(self, at: int) -> dict:
        count = 0
        for i, job in enumerate(self.jobs):
            if job["state"] == "failed" and job["attempts"] < LEGACY_MAX_ATTEMPTS and job["nextRetryAt"] is not None \
                    and job["nextRetryAt"] <= at:
                if not self.owns(i):
                    job.update(state="cancelled", nextRetryAt=None, lease=None)
                    continue
                job["state"] = "queued"
                self.source.update(status="pending", error=None)
                count += 1
        return dict(requeued=count)

    def publish(self, at: int, hash_: str) -> dict:
        i = self.fence
        if i is None or self.jobs[i]["state"] != "running":
            return dict(published=False)
        self.revisions += 1
        self.jobs[i].update(state="done", nextRetryAt=None, lease=None, targetRevision=self.revisions)
        self.source.update(current=self.revisions, published=self.revisions, committed=hash_, status="ready", error=None,
                           failures=0, hash=None)
        self.fence = None
        return dict(published=True)

    def loose(self, at: int, raw_path: bool, url: bool = False) -> dict:
        """A loose (non-folder) source: a local file, a URL (web source), or pasted text without either."""
        self.source = dict(status="pending", error=None, failures=0, hash=None, mtime=None, size=None, committed=None,
                           published=None, current=None, folder=False, readable=raw_path or url, web=url)
        return {}

    def reset_if_gave_up(self) -> None:
        """An explicit user action: a spent budget starts over, otherwise the attempt simply counts."""
        if self.source["failures"] >= FAILURE_BUDGET:
            self.source["failures"] = 0

    def begin(self, at: int) -> dict:
        """Foreground (re)ingestion (`beginExtraction`): a user action, so the failure count starts over."""
        for job in self.jobs:
            if job["state"] in ("queued", "running", "paused") or (job["state"] == "failed" and job["nextRetryAt"] is not None):
                job.update(state="cancelled", nextRetryAt=None, lease=None)
        self.reset_if_gave_up()
        self.enqueue()
        self.jobs[-1].update(state="running", attempts=1, lease=at + LEASE_SECONDS)
        self.source.update(status="chunking", error=None)
        self.fence = len(self.jobs) - 1
        return {}

    def abandon(self, at: int) -> dict:
        """The worker has nothing to re-read for a loose source: no attempt is counted."""
        i = self.fence
        if i is None or self.jobs[i]["state"] != "running" or self.jobs[i]["lease"] <= at:
            return dict(abandoned=False)
        self.jobs[i].update(state="failed", nextRetryAt=None, error=RETRY_UNAVAILABLE, lease=None)
        if self.owns(i):
            self.source.update(status="error", error=RETRY_UNAVAILABLE)
        self.fence = None
        return dict(abandoned=True)

    def retry_one(self) -> bool:
        if self.source is None or self.source["status"] != "error" or not self.source["readable"]:
            return False
        self.reset_if_gave_up()
        self.require_extraction(keep_running=True)
        for job in self.jobs:
            if job["state"] == "queued" and job["attempts"] == 0:
                job["options"] = dict(job["options"], **{USER_RETRY_KEY: True})
        return True

    def retry(self, at: int) -> dict:
        return dict(retried=self.retry_one())

    def retry_all(self, at: int) -> dict:
        return dict(retried=1 if self.retry_one() else 0)

    def upgrade(self, at: int) -> dict:
        s = self.source
        def revision(job: dict) -> int:
            value = job["options"].get(EXTRACTOR_KEY)
            return value if isinstance(value, int) and not isinstance(value, bool) else 1
        if (s is None or not s["folder"] or s["status"] != "error" or s["error"] not in RETRYABLE_CODES
                or s["failures"] >= FAILURE_BUDGET
                or any(self.unfinished(j) for j in self.jobs)
                or any(revision(j) >= EXTRACTOR_REVISION for j in self.jobs)):
            return dict(requeued=0)
        self.enqueue({EXTRACTOR_KEY: EXTRACTOR_REVISION})
        s.update(status="pending", error=None)
        return dict(requeued=1)

    def forget(self, at: int) -> dict:
        """A row written before schema v21: no recorded failures, no content hash."""
        self.source.update(failures=0, hash=None)
        return {}

    # --- projection ----------------------------------------------------------------------------

    def snapshot(self) -> dict:
        s = self.source
        source = None if s is None else dict(status=s["status"], error=s["error"], extractFailures=s["failures"],
                                             gaveUp=self.gave_up())
        jobs = [dict(state=j["state"], attempts=j["attempts"], nextRetryAt=j["nextRetryAt"], error=j["error"],
                     options=j["options"]) for j in self.jobs]
        active = any(j["state"] in ("queued", "running") for j in self.jobs)
        errors = 1 if s is not None and s["status"] == "error" else 0
        return dict(source=source, extractJobs=jobs, indexing=dict(active=active, sourceErrors=errors))


STEPS = {"observe", "loose", "begin", "abandon", "claim", "fail", "expire", "requeue", "publish", "retry", "retryAll",
         "upgrade", "forget"}
A = dict(mtime=1000, size=10, hash="a" * 64)
B = dict(mtime=2000, size=12, hash="b" * 64)


def obs(at: int, content: dict = A, **over) -> dict:
    step = dict(op="observe", at=at, mtime=content["mtime"], size=content["size"], hash=content["hash"], verifyAll=False)
    step.update(over)
    return step


def op(name: str, at: int, **args) -> dict:
    return dict(op=name, at=at, **args)


def fail_cycle(start: int, code: str = "corruptArchive", requeue_first: bool = False) -> list:
    """Claim at `start` and fail one second later; optionally make the pending retry due first."""
    steps = [op("requeue", start)] if requeue_first else []
    return steps + [op("claim", start), op("fail", start + 1, code=code)]


def give_up(start: int = 100, code: str = "corruptArchive") -> list:
    """First observation, then three failed attempts of the first job (retries at +60, +120)."""
    return ([obs(start)] + fail_cycle(start + 1, code)
            + fail_cycle(start + 100, code, requeue_first=True) + fail_cycle(start + 300, code, requeue_first=True))


def loose_give_up(start: int = 100, code: str = "corruptArchive") -> list:
    """A loose file: its foreground ingestion and two automatic retries fail."""
    return ([op("loose", start, rawPath=True), op("begin", start + 1), op("fail", start + 2, code=code)]
            + fail_cycle(start + 100, code, requeue_first=True) + fail_cycle(start + 300, code, requeue_first=True))


CASES = [
    ("three-failures-then-gives-up", give_up() + [op("requeue", 2000), op("claim", 2001)]),
    ("no-fourth-attempt-across-rescans", give_up() + [
        obs(1000), obs(1100, verifyAll=True), obs(1200, mtime=1500), obs(1300, mtime=1500),
        op("claim", 1400)]),
    ("scan-requeue-counts-across-jobs", [obs(100)] + fail_cycle(101) + [obs(200, verifyAll=True)] + fail_cycle(201)
     + [obs(300, verifyAll=True)] + fail_cycle(301) + [obs(400, verifyAll=True), op("claim", 401)]),
    ("content-change-resets", give_up() + [obs(1000, B)] + fail_cycle(1001)),
    ("touch-without-change-keeps-gave-up", give_up() + [obs(1000, mtime=1700), op("claim", 1001)]),
    ("legacy-row-uses-stat-identity", give_up() + [op("forget", 900), op("upgrade", 1000)] + fail_cycle(1001)
     + fail_cycle(1100, requeue_first=True) + fail_cycle(1300, requeue_first=True)
     + [obs(1500), obs(1600, mtime=1800)]),
    ("explicit-retry-resets", give_up() + [op("retry", 1000)] + fail_cycle(1001)),
    ("retry-all-resets", give_up() + [op("retryAll", 1000), op("claim", 1001)]),
    ("retry-ignores-pending-source", [obs(100), op("retry", 101), op("retryAll", 102)]),
    ("transient-failure-then-success-clears", [obs(100)] + fail_cycle(101) + [
        op("requeue", 200), op("claim", 200), op("publish", 201, hash=A["hash"]), obs(300, B)] + fail_cycle(301)),
    ("upgrade-requeue-skips-gave-up", give_up() + [op("upgrade", 1000), obs(1100)]),
    ("upgrade-requeue-legacy-row", give_up() + [op("forget", 900), op("upgrade", 1000)] + fail_cycle(1001)
     + [op("upgrade", 1100)] + fail_cycle(1100, requeue_first=True) + fail_cycle(1300, requeue_first=True)
     + [op("upgrade", 1500), obs(1600, verifyAll=True)]),
    ("lease-expiry-counts", [obs(100), op("claim", 101), op("expire", 401), op("claim", 461), op("expire", 761),
                             op("claim", 881), op("expire", 1181), op("claim", 1300), obs(1400)]),
    ("refresh-failure-keeps-published", [obs(100), op("claim", 101), op("publish", 102, hash=A["hash"]), obs(200, B)]
     + fail_cycle(201) + fail_cycle(300, requeue_first=True) + fail_cycle(500, requeue_first=True)
     + [obs(700, B), obs(800, A)]),
    # Loose (non-folder) sources follow the same rule (§3a): the folder worker re-reads their file or URL.
    ("loose-three-failures-then-gives-up", loose_give_up() + [op("requeue", 2000), op("claim", 2001)]),
    ("loose-explicit-retry-resets", loose_give_up() + [op("retry", 1000)] + fail_cycle(1001)),
    ("loose-retry-all-resets", loose_give_up() + [op("retryAll", 1000), op("claim", 1001)]),
    ("loose-reingest-resets", loose_give_up() + [op("begin", 1000), op("fail", 1001, code="corruptArchive")]),
    ("loose-transient-failure-then-success-clears", [op("loose", 100, rawPath=True), op("begin", 101),
     op("fail", 102, code="unexpectedError"), op("requeue", 200), op("claim", 200), op("publish", 201, hash=A["hash"])]),
    ("loose-lease-expiry-counts", [op("loose", 100, rawPath=True), op("begin", 101), op("expire", 401), op("claim", 461),
                                   op("expire", 761), op("claim", 881), op("expire", 1181), op("claim", 1300)]),
    ("loose-upgrade-requeue-skips-loose", loose_give_up() + [op("forget", 900), op("upgrade", 1000)]),
    ("retry-before-giving-up-keeps-count", [obs(100)] + fail_cycle(101) + [op("retry", 200)] + fail_cycle(201)
     + [op("retry", 300)] + fail_cycle(301) + [op("retry", 400), op("claim", 401)]),
    # A URL is fetched only by an explicit user action (§3a): no automatic retry, every user attempt counts.
    ("loose-url-user-retry-only", [op("loose", 100, rawPath=False, url=True), op("begin", 101),
     op("fail", 102, code="unexpectedError"), op("requeue", 2000), op("claim", 2001), op("retry", 2100)]
     + fail_cycle(2101, "unexpectedError") + [op("requeue", 3000), op("retry", 3100)] + fail_cycle(3101, "unexpectedError")
     + [op("retry", 3200), op("claim", 3201), op("publish", 3202, hash=A["hash"])]),
    ("loose-text-not-retryable", [op("loose", 100, rawPath=False), op("begin", 101), op("fail", 102, code="unexpectedError"),
                                  op("requeue", 200), op("claim", 200), op("abandon", 201), op("requeue", 2000),
                                  op("retry", 2001), op("retryAll", 2002)]),
]


# --- §1a supersession of frozen job fixtures that pinned five attempts for extract jobs ---------------

FIXTURES = Path(__file__).resolve().parents[2] / "Tests/fixtures/contracts"
# Exactly the frozen cases whose expectation changes when an extract job stops after three attempts.
SUPERSEDED = {
    "job-transitions-v1.json": ["fourth-failure-backoff-480-seconds"],
    "storage-jobs-revisions-v1.json": ["exhaustion", "expired-fifth"],
    "storage-job-handoff-v1.json": ["terminal-%s-%s-%s" % (mode, start, successor)
                                    for mode in ("failure", "expiry") for start in ("initial", "refresh")
                                    for successor in ("current", "newer-revision", "newer-failed-job", "newer-running-job")],
}


def backoff(now: int, attempts: int, cap: int):
    return None if attempts >= cap else now + 30 * 2 ** attempts


def job_transition(job: dict, event: dict, cap: int) -> dict:
    """job-transitions-v1 reference (gen_fixtures.job_transition) with the extract cap as a parameter."""
    result = dict(job)
    accepted = published = False
    kind, now = event["kind"], event["now"]
    live = (job["state"] == "running" and job["leaseUntil"] > now and job["leaseToken"] is not None
            and job["leaseToken"] == event.get("leaseToken"))
    if kind == "start" and job["state"] == "queued" and job["attempts"] < LEGACY_MAX_ATTEMPTS \
            and (job["nextRetryAt"] is None or now >= job["nextRetryAt"]) and event.get("leaseToken"):
        result.update(state="running", attempts=job["attempts"] + 1, nextRetryAt=None, leaseUntil=now + LEASE_SECONDS,
                      leaseToken=event["leaseToken"])
        accepted = True
    elif kind == "fail" and live:
        result.update(state="failed", leaseUntil=None, leaseToken=None, nextRetryAt=backoff(now, job["attempts"], cap))
        accepted = True
    elif kind == "retry" and job["state"] == "failed" and job["attempts"] < LEGACY_MAX_ATTEMPTS \
            and job["nextRetryAt"] is not None and now >= job["nextRetryAt"]:
        result["state"] = "queued"
        accepted = True
    elif kind == "expire" and job["state"] == "running" and job["leaseUntil"] <= now:
        retry = backoff(now, job["attempts"], cap)
        result.update(state="queued" if retry is not None else "failed", leaseUntil=None, leaseToken=None, nextRetryAt=retry)
        accepted = True
    elif kind == "renew" and live:
        result["leaseUntil"] = now + LEASE_SECONDS
        accepted = True
    elif kind == "publish" and live:
        published = job["targetRevision"] == event["requestedRevision"]
        result.update(state="done" if published else "cancelled", leaseUntil=None, leaseToken=None, nextRetryAt=None)
        accepted = True
    return dict(job=result, accepted=accepted, published=published)


def transitions_case(case: dict, cap: int) -> dict:
    out = copy.deepcopy(case)
    out["expected"] = job_transition(case["input"]["job"], case["input"]["event"], cap)
    return out


def timeline_case(case: dict, cap: int) -> dict:
    """storage-jobs-revisions-v1 `jobs` timeline of one extract job (claim/renew/fail/retry/recover only)."""
    job = dict(state="queued", attempts=0, nextRetryAt=case["enqueueAt"], leaseUntil=None, leaseToken=None, error=None)
    snapshots, starts, retries = [], [], []
    for event in case["events"]:
        op, at, token = event["op"], event["at"], event.get("token")
        live = job["state"] == "running" and job["leaseUntil"] > at and job["leaseToken"] == token
        result = False
        if op == "claim":
            if job["state"] == "queued" and job["attempts"] < LEGACY_MAX_ATTEMPTS \
                    and (job["nextRetryAt"] is None or job["nextRetryAt"] <= at):
                job.update(state="running", attempts=job["attempts"] + 1, nextRetryAt=None, leaseUntil=at + LEASE_SECONDS,
                           leaseToken=token, error=None)
                starts.append(at)
                result = True
        elif op == "fail":
            if live:
                retry = backoff(at, job["attempts"], cap)
                job.update(state="failed", nextRetryAt=retry, leaseUntil=None, leaseToken=None, error=event["error"])
                retries.append(retry)
                result = True
        elif op == "retry":
            if job["state"] == "failed" and job["attempts"] < LEGACY_MAX_ATTEMPTS and job["nextRetryAt"] is not None \
                    and job["nextRetryAt"] <= at:
                job["state"] = "queued"
                result = True
        elif op == "recover":
            if job["state"] == "running" and job["leaseUntil"] <= at:
                retry = backoff(at, job["attempts"], cap)
                job.update(state="queued" if retry is not None else "failed", nextRetryAt=retry, leaseUntil=None,
                           leaseToken=None, error="leaseExpired")
                result = True
        elif op == "renew":
            if live:
                job["leaseUntil"] = at + LEASE_SECONDS
                result = True
        else:
            raise SystemExit("gen_retry_cap_fixtures: timeline op %s is not modelled" % op)
        snapshots.append(dict(job, result=result))
    out = copy.deepcopy(case)
    out["expected"] = dict(snapshots=snapshots)
    if "expectedClaims" in case:
        out["expectedClaims"] = len(starts)
    if "startTimes" in case:
        out["startTimes"], out["retryTimes"] = starts, retries
    return out


def handoff_case(case: dict, cap: int) -> dict:
    """storage-job-handoff-v1 trace oracle (gen_storage_fixtures.handoff_contract) with the extract cap as a parameter."""
    inputs = case["input"]
    draft = inputs["draft"]
    initial = "setupSql" in case
    cap = cap if draft["kind"] == "extract" else LEGACY_MAX_ATTEMPTS
    job = dict(id=1, **draft, state="queued", attempts=0, nextRetryAt=inputs["enqueueAt"], leaseUntil=None, leaseToken=None,
               error=None)
    source = dict(id=1, status="pending" if initial else "ready", error=None, currentRevision=None if initial else 11,
                  publishedRevisionId=None if initial else 11)
    notebook_deleted = newer_job_started = False
    snapshots = []
    for event in inputs["events"]:
        op, now = event["op"], event["at"]
        accepted, requeued, recovered = False, None, None
        live = job["state"] == "running" and job["leaseUntil"] > now and job["leaseToken"] == event.get("token")
        current = source["currentRevision"] == draft["targetRevision"]
        if op == "claim":
            if job["state"] == "queued" and job["attempts"] < LEGACY_MAX_ATTEMPTS and job["nextRetryAt"] <= now:
                if notebook_deleted or (draft["kind"] == "extract" and (not current or newer_job_started)):
                    job.update(state="cancelled", nextRetryAt=None)
                else:
                    accepted = True
                    job.update(state="running", attempts=job["attempts"] + 1, nextRetryAt=None, leaseUntil=now + LEASE_SECONDS,
                               leaseToken=event["token"], error=None)
                    if draft["kind"] == "extract":
                        source.update(status="chunking", error=None)
        elif op in ("fail", "recover"):
            accepted = live if op == "fail" else (job["state"] == "running" and job["leaseUntil"] <= now)
            if op == "recover":
                recovered = int(accepted)
            if accepted:
                retry = backoff(now, job["attempts"], cap)
                exhausted = retry is None
                error = event["error"] if op == "fail" else "leaseExpired"
                job.update(state="failed" if op == "fail" or exhausted else "queued", nextRetryAt=retry, leaseUntil=None,
                           leaseToken=None, error=error)
                if draft["kind"] == "extract" and current and not newer_job_started:
                    if op == "recover" and not exhausted:
                        source.update(status="pending", error=None)
                    else:
                        source.update(status="error", error=error)
        elif op in ("requeue", "retry"):
            requeued = 0 if op == "requeue" else None
            if job["state"] == "failed" and job["attempts"] < LEGACY_MAX_ATTEMPTS and job["nextRetryAt"] is not None \
                    and job["nextRetryAt"] <= now:
                if draft["kind"] == "extract" and (not current or newer_job_started):
                    job.update(state="cancelled", nextRetryAt=None)
                else:
                    accepted = True
                    if op == "requeue":
                        requeued = 1
                    job["state"] = "queued"
                    if draft["kind"] == "extract":
                        source.update(status="pending", error=None)
        elif op == "updateOptions":
            accepted = job["state"] == "queued" and job["attempts"] == 0
            if accepted:
                job["optionsJSON"] = event["optionsJSON"]
        elif op in ("retarget", "complete"):
            accepted = live
            if accepted:
                if "generationId" in event:
                    job["target"] = "generation:%d" % event["generationId"]
                if op == "complete":
                    job.update(state="done", nextRetryAt=None, leaseUntil=None, leaseToken=None)
        elif op == "setSourceError":
            accepted = True
            source.update(status="error", error=event["error"])
        elif op == "supersedeSource":
            accepted = True
            source.update(currentRevision=12, status="error", error=event["error"])
        elif op == "supersedeJob":
            accepted = newer_job_started = True
            source.update(status="error" if event.get("error") else "chunking", error=event.get("error"))
        elif op == "deleteNotebook":
            accepted = notebook_deleted = True
        else:
            raise SystemExit("gen_retry_cap_fixtures: handoff op %s is not modelled" % op)
        snapshots.append(dict(accepted=accepted, requeuedCount=requeued, recoveredCount=recovered, job=copy.deepcopy(job),
                              source=copy.deepcopy(source)))
    out = copy.deepcopy(case)
    out["expected"] = dict(snapshots=snapshots)
    return out


ORACLES = {
    "job-transitions-v1.json": (lambda case: True, transitions_case),
    "storage-jobs-revisions-v1.json": (lambda case: case.get("operation") == "jobs" and case.get("kind") == "extract"
                                       and "synchronization" not in case and all(e["op"] in ("claim", "renew", "fail", "retry", "recover")
                                               for e in case["events"]), timeline_case),
    "storage-job-handoff-v1.json": (lambda case: case.get("operation") == "trace", handoff_case),
}


def supersedes() -> dict:
    """Re-run every modelled frozen case: with five attempts it must reproduce the frozen expectation byte for byte
    (so an edited frozen case fails here); the cases whose expectation differs with three attempts must be exactly
    the declared SUPERSEDED list. The replacement is the whole case (expected and derived fields)."""
    out = {}
    for filename, (modelled, oracle) in ORACLES.items():
        frozen = json.loads((FIXTURES / filename).read_text(encoding="utf-8"))
        replaced = {}
        for case in frozen["cases"]:
            if not modelled(case):
                continue
            if oracle(case, LEGACY_MAX_ATTEMPTS) != case:
                raise SystemExit("gen_retry_cap_fixtures: %s case %s no longer matches its frozen oracle"
                                 % (filename, case["name"]))
            capped = oracle(case, EXTRACT_MAX_ATTEMPTS)
            if capped != case:
                replaced[case["name"]] = capped
        if sorted(replaced) != sorted(SUPERSEDED[filename]):
            raise SystemExit("gen_retry_cap_fixtures: %s superseded cases changed: %s" % (filename, sorted(replaced)))
        out[filename] = replaced
    return out


def build() -> dict:
    cases = []
    for name, steps in CASES:
        model = Model()
        rows = []
        for step in copy.deepcopy(steps):
            name_ = step["op"]
            if name_ not in STEPS:
                raise SystemExit("gen_retry_cap_fixtures: unknown step " + name_)
            args = {k: v for k, v in step.items() if k not in ("op", "at")}
            if name_ == "observe":
                result = model.observe(step["at"], args["mtime"], args["size"], args["hash"], args["verifyAll"])
            elif name_ == "fail":
                result = model.fail(step["at"], args["code"])
            elif name_ == "publish":
                result = model.publish(step["at"], args["hash"])
            elif name_ == "loose":
                result = model.loose(step["at"], args["rawPath"], args.get("url", False))
            elif name_ == "retryAll":
                result = model.retry_all(step["at"])
            else:
                result = getattr(model, name_)(step["at"])
            rows.append(dict(step=step, result=result, expected=model.snapshot()))
        cases.append(dict(name=name, steps=rows))
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_retry_cap_fixtures: duplicate case name")
    check(cases)
    return dict(contract=CONTRACT, version=VERSION, failureBudget=FAILURE_BUDGET,
                extractMaxAttempts=EXTRACT_MAX_ATTEMPTS, leaseSeconds=LEASE_SECONDS, migration=MIGRATION,
                schemaDDL=SCHEMA_DDL, seed=SEED, cases=cases, supersedes=supersedes())


def check(cases: list) -> None:
    """The cases must keep exercising the rules they are named after."""
    by = {c["name"]: c["steps"] for c in cases}

    def at(name: str, op_: str, when: int) -> dict:
        return next(s for s in by[name] if s["step"]["op"] == op_ and s["step"]["at"] == when)

    def require(ok: bool, message: str) -> None:
        if not ok:
            raise SystemExit("gen_retry_cap_fixtures: " + message)

    final = by["three-failures-then-gives-up"][-1]
    require(final["result"] == dict(claimed=False) and final["expected"]["source"]["gaveUp"],
            "three failures must give up")
    require([at("no-fourth-attempt-across-rescans", "observe", t)["result"] for t in (1000, 1100, 1200, 1300)]
            == [dict(read=False, queued=False), dict(read=True, queued=False), dict(read=True, queued=False),
                dict(read=False, queued=False)], "a gave-up source must stay settled across rescans")
    across = by["scan-requeue-counts-across-jobs"]
    require(across[-1]["result"] == dict(claimed=False)
            and at("scan-requeue-counts-across-jobs", "fail", 302)["expected"]["extractJobs"][-1]["attempts"] == 1,
            "failures must count across jobs")
    require(by["content-change-resets"][-1]["expected"]["source"]["extractFailures"] == 1,
            "a content change must reset the budget")
    require(at("legacy-row-uses-stat-identity", "observe", 1600)["result"] == dict(read=True, queued=True),
            "an unknown content hash falls back to the stat identity")
    require(by["explicit-retry-resets"][-1]["expected"]["source"]["extractFailures"] == 1,
            "an explicit retry must reset the budget")
    require(by["transient-failure-then-success-clears"][-1]["expected"]["source"]["extractFailures"] == 1,
            "a publication must clear the budget")
    require(at("upgrade-requeue-skips-gave-up", "upgrade", 1000)["result"] == dict(requeued=0),
            "the upgrade requeue must skip gave-up sources")
    require(at("upgrade-requeue-legacy-row", "upgrade", 1000)["result"] == dict(requeued=1)
            and at("upgrade-requeue-legacy-row", "upgrade", 1500)["result"] == dict(requeued=0),
            "a legacy error row is requeued once and then gives up")
    require(by["lease-expiry-counts"][-1]["expected"]["source"]["gaveUp"], "lease expiries count as failed attempts")
    require(by["refresh-failure-keeps-published"][-1]["expected"]["source"]["status"] == "ready",
            "the committed bytes on disk settle a gave-up refresh")
    require(by["loose-three-failures-then-gives-up"][-1]["expected"]["source"]["gaveUp"]
            and by["loose-three-failures-then-gives-up"][-1]["result"] == dict(claimed=False),
            "a loose file gives up after three failed attempts")
    require(by["loose-reingest-resets"][-1]["expected"]["source"]["extractFailures"] == 1,
            "a foreground re-ingestion resets the budget")
    url = by["loose-url-user-retry-only"]
    require(at("loose-url-user-retry-only", "requeue", 2000)["result"] == dict(requeued=0)
            and at("loose-url-user-retry-only", "fail", 3102)["expected"]["source"]["gaveUp"]
            and at("loose-url-user-retry-only", "retry", 3200)["expected"]["source"]["extractFailures"] == 0
            and url[-1]["expected"]["source"]["status"] == "ready",
            "a URL is never retried automatically; three user attempts give up and a further Retry starts over")
    require(at("retry-before-giving-up-keeps-count", "fail", 302)["expected"]["source"]["gaveUp"],
            "an explicit retry before giving up keeps counting")
    require(at("loose-text-not-retryable", "retry", 2001)["result"] == dict(retried=False)
            and at("loose-text-not-retryable", "abandon", 201)["expected"]["source"]["extractFailures"] == 1,
            "a loose source without a file is not retryable and an abandoned retry is no attempt")
    for case in cases:
        for row in case["steps"]:
            source = row["expected"]["source"]
            require(not (source and source["gaveUp"] and row["expected"]["indexing"]["active"]),
                    "a gave-up source must not keep indexing active")
            require(all(job["attempts"] <= EXTRACT_MAX_ATTEMPTS for job in row["expected"]["extractJobs"]),
                    "an extract job ran more than three attempts")


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check_only: bool = False) -> None:
    path = root / OUTPUT
    data = encoded()
    name = Path(OUTPUT).name
    if check_only:
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
