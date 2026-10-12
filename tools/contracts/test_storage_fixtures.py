import importlib.util
import json
import pathlib
import sqlite3
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "storage", ROOT / "tools/contracts/gen_storage_fixtures.py")


class StorageFixtureTests(unittest.TestCase):
    def module(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        return module

    def test_real_v18_and_repeatable_logical_state(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as d:
            a, b = pathlib.Path(d) / "a.sqlite", pathlib.Path(d) / "b.sqlite"
            module.build_v18(a)
            module.build_v18(b)
            self.assertEqual(module.logical_dump(a), module.logical_dump(b))
            self.assertEqual(a.read_bytes()[:16], b"SQLite format 3\x00")
        contracts = module.make_contracts()
        self.assertEqual(contracts["storage-v19.json"]["version"], 1)
        self.assertNotIn("sqliteVersion", repr(contracts))
        for contract in contracts.values():
            names = [c["name"] for c in contract["cases"]]
            self.assertEqual(len(names), len(set(names)))

    def test_old_database_seed_and_legacy_group_oracle(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "v18.sqlite"
            module.build_v18(path)
            db = sqlite3.connect(path)
            try:
                self.assertEqual(db.execute("SELECT count(*) FROM sources").fetchone(), (13,))
                self.assertEqual(db.execute("SELECT count(*) FROM source_chunks").fetchone(), (11,))
                self.assertEqual(db.execute("SELECT count(*) FROM chunk_embeddings WHERE length(embedding)=dim*4").fetchone(), (9,))
                self.assertEqual(db.execute("SELECT id FROM sources WHERE NOT EXISTS(SELECT 1 FROM source_chunks WHERE source_id=sources.id) ORDER BY id").fetchall(), [(106,), (107,), (109,)])
                self.assertEqual(db.execute("SELECT citations_json FROM messages WHERE id=41").fetchone(), (module.CITATIONS,))
                self.assertEqual(db.execute("SELECT note_uuid,auto_source_id FROM notes WHERE id=21").fetchone(), (module.NOTE_UUID, 109))
                self.assertEqual(db.execute("SELECT rowid FROM notes_fts WHERE notes_fts MATCH 'saved'").fetchall(), [(21,)])
                self.assertEqual(db.execute("SELECT count(*) FROM grdb_migrations").fetchone(), (16,))
                self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))
            finally:
                db.close()
        legacy = json.loads((ROOT / "Tests/fixtures/contracts/legacy-generation-v1.json").read_text())
        for item in legacy["cases"]:
            groups, active = module.legacy_groups(item["input"], item["configuredModelKey"])
            for notebook in item["expected"]:
                nb = notebook["notebookId"]
                self.assertEqual({(m, d): count for (n, m, d), count in groups.items() if n == nb},
                                 {(g["modelKey"], g["dims"]): g["vectorCount"] for g in notebook["generations"]})
                expected = notebook["activeGeneration"]
                self.assertEqual(active.get(nb), None if expected is None else (nb, expected["modelKey"], expected["dims"]))

    def reference_database(self, module):
        db = sqlite3.connect(":memory:")
        db.execute("PRAGMA foreign_keys=ON")
        for _, _, sql in module.old_migrations():
            for statement in sql.split("@@"):
                if statement.strip():
                    db.execute(statement)
        db.execute("INSERT INTO providers VALUES(?,'ollama','Ollama','http://127.0.0.1:11434',1,1,?)", (module.OLLAMA, module.STAMP))
        db.executescript(module.V19_SCHEMA)
        db.execute("DROP TABLE chunk_embeddings_v18")
        return db

    def test_every_operational_setup_executes_with_foreign_keys(self):
        module = self.module()
        contracts = module.make_contracts()
        operations = {
            "storage-catalog-v1.json": {"overlap", "relative-paths", "inventory-upsert", "membership", "remove-folder", "coverage", "evidence-cap", "limits"},
            "storage-jobs-revisions-v1.json": {"publish", "revision-update", "jobs", "extraction"},
            "storage-generations-v1.json": {"generation"},
            "storage-integration-v1.json": {"integration", "scalar"},
            "storage-job-handoff-v1.json": {"trace"},
        }
        for name, contract in contracts.items():
            if name in ("storage-v19.json", "storage-v20.json"):  # schema-only contracts
                continue
            for item in contract["cases"]:
                with self.subTest(file=name, case=item["name"]):
                    self.assertIn(item["operation"], operations[name])
                    self.assertIsInstance(item["expected"], dict)
                    self.assertTrue(item["expected"])
                    db = self.reference_database(module)
                    try:
                        case_setup = (item.get("setupSql", []) if name == "storage-job-handoff-v1.json"
                                      else item["setupSql"])
                        for sql in contract.get("setupSql", []) + case_setup:
                            db.execute(sql)
                        self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])
                        if item["operation"] == "jobs" and "snapshots" in item["expected"]:
                            self.assertEqual(len(item["events"]), len(item["expected"]["snapshots"]))
                    finally:
                        db.close()

    def test_v20_schema_queries_run_on_the_reference_schema(self):
        module = self.module()
        contract = module.make_contracts()["storage-v20.json"]
        db = self.reference_database(module)
        try:
            db.executescript(module.V20_SCHEMA)
            fresh = next(c for c in contract["cases"] if c["name"] == "fresh-schema")
            for projection in fresh["queries"]:
                with self.subTest(query=projection["name"]):
                    self.assertEqual([list(r) for r in db.execute(projection["sql"])], projection["rows"])
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO generation_text_hashes VALUES (1,1,'short',0)")
        finally:
            db.close()

    def test_schema_projection_sql_and_wp2_constraints(self):
        module = self.module()
        db = self.reference_database(module)
        try:
            for projection in module.schema_queries():
                with self.subTest(query=projection["name"]):
                    self.assertEqual([list(r) for r in db.execute(projection["sql"])], projection["rows"])
            for model in ["", "   "]:
                with self.assertRaises(sqlite3.IntegrityError):
                    db.execute("INSERT INTO provider_model_limits VALUES(?,?,NULL,8192,1024,'auto')", (module.OLLAMA, model))
            db.execute("INSERT INTO provider_model_limits VALUES(?,'m',NULL,8192,1024,'auto')", (module.OLLAMA,))
            for sql in ["UPDATE provider_model_limits SET context_window=0",
                        "UPDATE provider_model_limits SET context_window=4096",
                        "UPDATE provider_model_limits SET runtime_context=0",
                        "UPDATE provider_model_limits SET max_output_tokens=0",
                        "UPDATE provider_model_limits SET max_output_tokens=8192",
                        "UPDATE provider_model_limits SET source='other'"]:
                with self.assertRaises(sqlite3.IntegrityError):
                    db.execute(sql)
        finally:
            db.close()

    def test_job_snapshots_match_normative_wp0_transitions(self):
        module = self.module()
        reference_spec = importlib.util.spec_from_file_location(
            "wp0_job_reference", ROOT / "tools/contracts/gen_fixtures.py")
        reference = importlib.util.module_from_spec(reference_spec)
        reference_spec.loader.exec_module(reference)
        cases = [item for item in module.jobs_revision_contract()["cases"]
                 if item["operation"] == "jobs"]
        ordinary = {"lease-timeline", "token-fence", "expiry-fence", "exhaustion",
                    "expired-fifth", "pause-resume-cancel", "restart-reclaim"}
        self.assertEqual({item["name"] for item in cases}, ordinary | {
            "claim-order", "two-connections-single-claim"})

        def initial_job(retry, revision):
            return dict(state="queued", attempts=0, nextRetryAt=retry, leaseUntil=None,
                        leaseToken=None, targetRevision=revision, error=None)

        def transition(job, event):
            op, now = event["op"], event["at"]
            error_code = None
            if op in {"claim", "renew", "fail", "retry", "recover", "publish"}:
                kind = {"claim": "start", "recover": "expire"}.get(op, op)
                result = reference.job_transition(job, dict(kind=kind, now=now,
                    leaseToken=event["token"], requestedRevision=job["targetRevision"]))
                job, accepted = result["job"], result["accepted"]
                if accepted and op == "claim":
                    job["error"] = None
                elif accepted and op == "fail":
                    job["error"] = event["error"]
                elif accepted and op == "recover":
                    job["error"] = "leaseExpired"
            elif op == "pause":
                accepted = job["state"] == "queued"
                if accepted:
                    job["state"] = "paused"
                else:
                    error_code = "invalidValue"
            elif op == "resume":
                accepted = job["state"] == "paused"
                if accepted:
                    job["state"] = "queued"
                else:
                    error_code = "invalidValue"
            elif op == "cancel":
                accepted = job["state"] in {"queued", "running", "paused"}
                if accepted:
                    job.update(state="cancelled", leaseUntil=None, leaseToken=None,
                               nextRetryAt=None)
                else:
                    error_code = "invalidValue"
            elif op == "complete":
                # These extraction cases intentionally fail the lease fence before
                # the separate prohibition on completing extraction without publish.
                live_owner = (job["state"] == "running" and job["leaseUntil"] > now
                              and job["leaseToken"] == event["token"])
                self.assertFalse(live_owner, "A live extraction owner must publish")
                accepted = False
            elif op == "reopen":
                accepted = True
            else:
                self.fail(f"Unknown job event: {op}")
            actual = {key: job[key] for key in (
                "state", "attempts", "nextRetryAt", "leaseUntil", "leaseToken", "error")}
            actual["result"] = accepted
            if error_code is not None:
                actual["expectedError"] = error_code
            self.assertEqual(event.get("expectedError"), error_code)
            return job, actual

        checked_steps = 0
        for item in cases:
            with self.subTest(case=item["name"]):
                if item["name"] in ordinary:
                    job = initial_job(item["enqueueAt"], item["targetRevision"])
                    snapshots = item["expected"]["snapshots"]
                    self.assertEqual(len(item["events"]), len(snapshots))
                    for event, expected in zip(item["events"], snapshots):
                        with self.subTest(event=event):
                            job, actual = transition(job, event)
                            self.assertEqual(actual, expected)
                            checked_steps += 1
                elif item["name"] == "claim-order":
                    jobs = {draft["id"]: initial_job(draft["nextRetryAt"], draft["targetRevision"])
                            for draft in item["jobs"]}
                    claimed, snapshots = [], []
                    for event in item["events"]:
                        due = [(job["nextRetryAt"], ident) for ident, job in jobs.items()
                               if job["state"] == "queued" and job["nextRetryAt"] <= event["at"]]
                        self.assertTrue(due)
                        _, ident = min(due)
                        jobs[ident], actual = transition(jobs[ident], event)
                        self.assertTrue(actual["result"])
                        claimed.append(ident)
                        snapshots.append(dict(jobId=ident, **actual))
                    self.assertEqual(claimed, item["expected"]["claimedJobIds"])
                    self.assertEqual(snapshots, item["expected"]["snapshots"])
                elif item["name"] == "two-connections-single-claim":
                    self.assertEqual(len(item["events"]), 2)
                    winners = set()
                    # SQLite serializes claim transactions; either contender may
                    # acquire the write transaction first. Check both orders.
                    for events in (item["events"], list(reversed(item["events"]))):
                        job = initial_job(item["enqueueAt"], item["targetRevision"])
                        successes = 0
                        for event in events:
                            job, actual = transition(job, event)
                            successes += int(actual["result"])
                        self.assertEqual(successes, item["expected"]["successfulClaims"])
                        for key in ("attempts", "state", "nextRetryAt", "leaseUntil"):
                            self.assertEqual(job[key], item["expected"][key])
                        winners.add(job["leaseToken"])
                    self.assertEqual(winners, set(item["expected"]["winningTokens"]))
                else:
                    self.fail(f"Unknown job fixture: {item['name']}")
        self.assertEqual(checked_steps, 65)

    def test_handoff_terminal_source_snapshots(self):
        contract = self.module().make_contracts()["storage-job-handoff-v1.json"]
        cases = {case["name"]: case for case in contract["cases"]}
        self.assertEqual(len(cases), 38)
        for mode, error in (("failure", "terminal extraction failure"), ("expiry", "leaseExpired")):
            for source in ("initial", "refresh"):
                for successor in ("current", "newer-revision", "newer-failed-job", "newer-running-job"):
                    name = f"terminal-{mode}-{source}-{successor}"
                    with self.subTest(case=name):
                        snapshots = cases[name]["expected"]["snapshots"]
                        terminal = snapshots[-3]
                        self.assertEqual(terminal["job"]["state"], "failed")
                        self.assertEqual(terminal["job"]["attempts"], 5)
                        self.assertIsNone(terminal["job"]["nextRetryAt"])
                        self.assertEqual(terminal["job"]["error"], error)
                        status = "chunking" if successor == "newer-running-job" else "error"
                        source_error = error if successor == "current" else (
                            None if successor == "newer-running-job" else "newer failure")
                        self.assertEqual(terminal["source"]["status"], status)
                        self.assertEqual(terminal["source"]["error"], source_error)
                        self.assertFalse(snapshots[-2]["accepted"])
                        self.assertFalse(snapshots[-1]["accepted"])

    def test_handoff_nonterminal_expiry_source_snapshots(self):
        contract = self.module().make_contracts()["storage-job-handoff-v1.json"]
        cases = {case["name"]: case for case in contract["cases"]}
        for source in ("initial", "refresh"):
            for successor in ("current", "newer-revision", "newer-failed-job", "newer-running-job"):
                name = f"nonterminal-expiry-{source}-{successor}"
                with self.subTest(case=name):
                    snapshots = cases[name]["expected"]["snapshots"]
                    self.assertEqual([s["accepted"] for s in snapshots],
                                     [True, False, True, True, False, False, False, successor == "current", False])
                    before, recovered = snapshots[2], snapshots[3]
                    self.assertEqual(recovered["job"]["state"], "queued")
                    self.assertEqual(recovered["job"]["attempts"], 1)
                    self.assertEqual(recovered["job"]["nextRetryAt"], 360)
                    self.assertEqual(recovered["job"]["error"], "leaseExpired")
                    self.assertIsNone(recovered["job"]["leaseUntil"])
                    self.assertIsNone(recovered["job"]["leaseToken"])
                    expected_source = dict(before["source"])
                    if successor == "current":
                        self.assertEqual(expected_source["error"], "prior failure")
                        expected_source.update(status="pending", error=None)
                    self.assertEqual(recovered["source"], expected_source)
                    for snapshot in snapshots[4:7]:
                        self.assertEqual(snapshot["job"], recovered["job"])
                        self.assertEqual(snapshot["source"], recovered["source"])
                    self.assertEqual(snapshots[1]["recoveredCount"], 0)
                    self.assertEqual(recovered["recoveredCount"], 1)
                    self.assertEqual(snapshots[4]["recoveredCount"], 0)
                    self.assertEqual(snapshots[7]["job"]["state"],
                                     "running" if successor == "current" else "cancelled")
                    self.assertEqual(snapshots[8]["job"], snapshots[7]["job"])
                    self.assertEqual(snapshots[8]["source"], snapshots[7]["source"])

    def test_check_detects_json_and_logical_database_drift(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            module.write_fixtures(output)
            self.assertEqual(module.check_fixtures(output), [])
            database = output / "storage/v18.sqlite"
            data = bytearray(database.read_bytes())
            data[96:100] = (3008000).to_bytes(4, "big")  # writer version is intentionally ignored
            database.write_bytes(data)
            self.assertEqual(module.check_fixtures(output), [])
            contract = output / "contracts/storage-v19.json"
            contract.write_bytes(contract.read_bytes() + b"\n")
            self.assertEqual(module.check_fixtures(output), ["contracts/storage-v19.json"])
            db = sqlite3.connect(database)
            try:
                db.execute("UPDATE notes SET body_md='changed' WHERE id=21")
                db.commit()
            finally:
                db.close()
            self.assertEqual(module.check_fixtures(output), ["contracts/storage-v19.json", "storage/v18.sqlite (logical state)"])


if __name__ == "__main__":
    unittest.main()
