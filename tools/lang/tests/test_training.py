"""Offline training and exact validation calibration tests."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from unittest.mock import patch

from tools.lang.tests.test_prepare_corpus import (CONCAT_LINKS, ROOT, OfflineTests, concat_records,
    concat_rule, tiny_config, tiny_corpus)


TARGETS = ["cs", "de", "en", "sk"]
NEGATIVES = ["fr", "hr", "hu", "nl", "pl", "sl"]


def training_config():
    config = tiny_config()
    config["augmentation"].append(concat_rule(splits=("validation", "test"), cap=50))
    config["minimumSupport"] = {"groupsPerTarget": 200, "groupsPerNegativeLanguage": 200,
                                "acceptedTotal": 1000, "acceptedTrueCs": 100, "acceptedTrueSk": 100}
    config["calibration"] = {
        "algorithm": "grid-max-accepted-v1",
        "candidates": [{"bucketStart": start, "minWinningScores": [-120000, 0],
                        "minMargins": [1, 128], "minKnownCoverageBp": [0, 10000]}
                       for start in [12, 32, 80, 200]],
        "tieBreak": ["minWinningScoreDescending", "minMarginDescending", "minKnownCoverageBpDescending"],
    }
    return config


def candidate_grid(**overrides):
    return {"bucketStart": 12, "minWinningScores": [-20000], "minMargins": [1],
            "minKnownCoverageBp": [0], **overrides}


def row(language, index, **overrides):
    return {"truth": language, "originalGroupId": f"{language}-{index}",
            "winner": language if language in TARGETS else "background", "winningScore": -10000,
            "margin": 256, "coverageBp": 10000, "letterCount": 24, "wordCount": 4,
            "bucketStart": 12, "split": "validation", **overrides}


def supported_rows():
    return [row(language, index) for language in TARGETS + NEGATIVES
            for index in range(250 if language in TARGETS else 200)]


class CalibrationTests(unittest.TestCase):
    def test_below_minimum_bucket_reports_support_without_acceptance(self):
        from tools.lang.calibrate import evaluate_rows
        rows = [row("cs", 0, letterCount=11, bucketStart=None),
                row("cs", 1, letterCount=5, bucketStart=0),
                row("fr", 0, letterCount=0, wordCount=0, bucketStart=None),
                row("en", 0)]
        threshold = {"start": 0, "enabled": 0, "minWinningScore": -20000,
                     "minMargin": 1, "minKnownCoverageBp": 0}
        result = evaluate_rows(rows, threshold, TARGETS, NEGATIVES)
        self.assertEqual(result["acceptedTotal"], 0)
        self.assertEqual(result["support"]["cs"], {"originalGroups": 2, "evaluated": 2, "accepted": 0})
        self.assertEqual(result["metrics"]["acceptanceCoverage"],
                         {"numerator": 0, "denominator": 3, "rateBp": 0})
        self.assertEqual(result["metrics"]["foreignAcceptance"],
                         {"numerator": 0, "denominator": 1, "rateBp": 0})
        self.assertIsNone(result["metrics"]["acceptedError"]["rateBp"])
        with self.assertRaises(ValueError):
            evaluate_rows(rows, {**threshold, "enabled": 1}, TARGETS, NEGATIVES)

    def test_gate_uses_cross_products_not_rounded_rate(self):
        from tools.lang.calibrate import exact_gate
        self.assertTrue(exact_gate(2, 100, 200))
        self.assertFalse(exact_gate(20001, 1000000, 200))
        self.assertFalse(exact_gate(0, 0, 200))

    def test_no_support_disables_bucket(self):
        from tools.lang.calibrate import calibrate_bucket
        result = calibrate_bucket([], candidate_grid(), TARGETS, ["fr"])
        self.assertEqual(result["threshold"], {"start": 12, "enabled": 0,
            "minWinningScore": -20000, "minMargin": 1, "minKnownCoverageBp": 0})
        self.assertEqual(result["reason"], "insufficientSupport")

    def test_all_group_minima_count_original_groups_not_augmented_rows(self):
        from tools.lang.calibrate import calibrate_bucket
        self.assertEqual(calibrate_bucket(supported_rows(), candidate_grid(), TARGETS, NEGATIVES)["reason"], "accepted")
        for language in TARGETS + NEGATIVES:
            rows = supported_rows()
            originals = [r for r in rows if r["truth"] == language]
            for item in originals[199:]:
                item["originalGroupId"] = originals[0]["originalGroupId"]
            with self.subTest(language=language):
                result = calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)
                self.assertEqual(result["reason"], "insufficientSupport")
                self.assertEqual(result["support"][language]["originalGroups"], 199)
            originals[199]["originalGroupId"] = f"{language}-199"
            self.assertEqual(calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)["reason"], "accepted")

    def test_total_accepted_boundary_999_versus_1000(self):
        from tools.lang.calibrate import calibrate_bucket
        rows = supported_rows()
        rows[0]["winner"] = "background"
        self.assertEqual(calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)["reason"], "insufficientSupport")
        rows[0]["winner"] = "cs"
        result = calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)
        self.assertEqual(result["reason"], "accepted")
        self.assertEqual(result["acceptedTotal"], 1000)

    def test_accepted_true_cs_sk_boundary_99_versus_100(self):
        from tools.lang.calibrate import calibrate_bucket
        for language in ["cs", "sk"]:
            rows = supported_rows()
            own = [r for r in rows if r["truth"] == language]
            for item in own[:151]:
                item["winner"] = "background"
            rows.extend(copy.deepcopy([r for r in rows if r["truth"] == "en"][:151]))
            with self.subTest(language=language):
                self.assertEqual(calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)["reason"], "insufficientSupport")
                own[150]["winner"] = language
                result = calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)
                self.assertEqual(result["reason"], "accepted")
                self.assertEqual(result["support"][language]["accepted"], 100)

    def test_exact_metric_denominators_and_disabled_metrics(self):
        from tools.lang.calibrate import evaluate_rows
        rows = [row("cs", 0, winner="sk"), row("sk", 0, winner="en"),
                row("cs", 1, winner="background"), row("fr", 0, winner="de"),
                row("fr", 1), row("en", 0), row("en", 1, wordCount=2)]
        threshold = {"start": 12, "enabled": 1, "minWinningScore": -20000,
                     "minMargin": 1, "minKnownCoverageBp": 0}
        result = evaluate_rows(rows, threshold, TARGETS, NEGATIVES)
        self.assertEqual(result["metrics"], {
            "acceptedError": {"numerator": 3, "denominator": 4, "rateBp": 7500},
            "csSkConfusion": {"numerator": 1, "denominator": 2, "rateBp": 5000},
            "foreignAcceptance": {"numerator": 1, "denominator": 2, "rateBp": 5000},
            "acceptanceCoverage": {"numerator": 4, "denominator": 7, "rateBp": 5714},
        })
        self.assertEqual(result["support"]["cs"], {"originalGroups": 2, "evaluated": 2, "accepted": 1})
        threshold["enabled"] = 0
        disabled = evaluate_rows(rows, threshold, TARGETS, NEGATIVES)
        self.assertEqual(disabled["acceptedTotal"], 0)
        self.assertIsNone(disabled["metrics"]["acceptedError"]["rateBp"])
        self.assertEqual(disabled["metrics"]["foreignAcceptance"]["denominator"], 2)

    def test_short_background_and_other_buckets_always_abstain(self):
        from tools.lang.calibrate import evaluate_rows
        rows = [row("en", 0), row("en", 1, letterCount=11, bucketStart=None),
                row("en", 2, wordCount=2), row("en", 3, winner="background"),
                row("en", 4, letterCount=32, bucketStart=32)]
        threshold = {"start": 12, "enabled": 1, "minWinningScore": -10000,
                     "minMargin": 256, "minKnownCoverageBp": 10000}
        result = evaluate_rows(rows, threshold, TARGETS, NEGATIVES)
        self.assertEqual(result["acceptedTotal"], 1)
        self.assertEqual(result["support"]["en"]["evaluated"], 3)

    def test_all_three_exact_validation_gates(self):
        from tools.lang.calibrate import calibrate_bucket
        for metric, passing, failing in [("acceptedError", 20, 21),
                                          ("csSkConfusion", 5, 6),
                                          ("foreignAcceptance", 12, 13)]:
            for count in [passing, failing]:
                rows = supported_rows()
                truth, winner = {"acceptedError": ("de", "en"),
                                 "csSkConfusion": ("cs", "sk"),
                                 "foreignAcceptance": ("fr", "en")}[metric]
                for item in [r for r in rows if r["truth"] == truth][:count]:
                    item["winner"] = winner
                with self.subTest(metric=metric, count=count):
                    result = calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)
                    self.assertEqual(result["reason"], "accepted" if count == passing else "noEligibleThreshold")

    def test_rounded_rate_cannot_rescue_candidate(self):
        from tools.lang.calibrate import calibrate_bucket
        rows = supported_rows()
        rows.extend(copy.deepcopy([r for r in rows if r["truth"] == "en"][:49]))
        for item in [r for r in rows if r["truth"] == "de"][:21]:
            item["winner"] = "en"
        self.assertEqual(10000 * 21 // 1049, 200)
        result = calibrate_bucket(rows, candidate_grid(), TARGETS, NEGATIVES)
        self.assertEqual(result["reason"], "noEligibleThreshold")
        self.assertEqual(result["threshold"]["enabled"], 0)
        self.assertEqual(result["acceptedTotal"], 0)

    def test_cartesian_grid_maximizes_acceptance_then_descending_triple(self):
        from tools.lang.calibrate import calibrate_bucket
        rows = supported_rows()
        candidates = candidate_grid(minWinningScores=[-20000, -10000, 0],
                                    minMargins=[1, 128, 256, 512],
                                    minKnownCoverageBp=[0, 5000, 10000])
        result = calibrate_bucket(rows, candidates, TARGETS, NEGATIVES)
        self.assertEqual(result["threshold"], {"start": 12, "enabled": 1,
            "minWinningScore": -10000, "minMargin": 256, "minKnownCoverageBp": 10000})
        rows.extend([row("en", 0, winningScore=-20000, margin=1, coverageBp=0)])
        result = calibrate_bucket(rows, candidates, TARGETS, NEGATIVES)
        self.assertEqual(result["threshold"], {"start": 12, "enabled": 1,
            "minWinningScore": -20000, "minMargin": 1, "minKnownCoverageBp": 0})
        self.assertEqual(result["acceptedTotal"], 1001)

    def test_calibration_rejects_test_or_train_rows(self):
        from tools.lang.calibrate import calibrate_bucket
        for split in ["test", "train"]:
            with self.subTest(split=split), self.assertRaisesRegex(ValueError, "validation"):
                calibrate_bucket([row("cs", 0, split=split)], candidate_grid(), TARGETS, NEGATIVES)

    def test_candidate_values_are_raw_sorted_unique_bounded_integers(self):
        from tools.lang.calibrate import calibrate_bucket
        invalid = [{"minWinningScores": []}, {"minWinningScores": [-10000, -20000]},
                   {"minWinningScores": [-20000, -20000]}, {"minWinningScores": [-1.0]},
                   {"minWinningScores": [1]}, {"minWinningScores": [-7000001]},
                   {"minMargins": [0]}, {"minMargins": [True]}, {"minMargins": [7000001]},
                   {"minKnownCoverageBp": [10001]}, {"minKnownCoverageBp": [-1]},
                   {"bucketStart": True}, {"bucketStart": 13}]
        for change in invalid:
            with self.subTest(change=change), self.assertRaises(ValueError):
                calibrate_bucket([], candidate_grid(**change), TARGETS, NEGATIVES)

    def test_evaluation_rejects_raw_noninteger_thresholds(self):
        from tools.lang.calibrate import evaluate_rows
        threshold = {"start": 12, "enabled": 1, "minWinningScore": -20000,
                     "minMargin": 1, "minKnownCoverageBp": 0}
        for field, value in [("enabled", True), ("enabled", 2), ("minWinningScore", -2.5),
                             ("minMargin", 0), ("minKnownCoverageBp", 10001)]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                evaluate_rows([], {**threshold, field: value}, TARGETS, NEGATIVES)


class TrainingTests(OfflineTests):
    def export_inputs(self, root, records=None, links=None):
        from tools.lang.prepare_corpus import snapshot_wp1
        lock = tiny_corpus(root / "data", records=records, links=links)
        lock_path, config_path, wp1_path = root / "lock.json", root / "config.json", root / "documents.json"
        lock_path.write_text(json.dumps(lock), encoding="utf-8")
        config_path.write_text(json.dumps(training_config()), encoding="utf-8")
        wp1_path.write_text(json.dumps(snapshot_wp1(ROOT / "eval/multilingual")), encoding="utf-8")
        return (root / "data", lock_path, config_path, root / "out", wp1_path,
                "2026-10-09T00:00:00Z", "0" * 40)

    def test_training_reproducible_export(self):
        from tools.lang.train_detector import train
        from tools.lang.prepare_corpus import snapshot_wp1
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            lock_path = root / "lock.json"
            lock_path.write_text(json.dumps(lock), encoding="utf-8")
            config_path = root / "config.json"
            config_path.write_text(json.dumps(training_config()), encoding="utf-8")
            wp1_path = root / "documents.json"
            wp1_path.write_text(json.dumps(snapshot_wp1(ROOT / "eval/multilingual")), encoding="utf-8")
            for name in ["first", "second"]:
                train(root / "data", lock_path, config_path, root / name, wp1_path,
                      "2026-10-09T00:00:00Z", "0" * 40)
            expected = {"lang-detector-v1.json", "lang-detector-v1.manifest.json",
                        "ATTRIBUTION.md", "NOTICE", "support-report.json"}
            first = {p.name: p.read_bytes() for p in (root / "first").iterdir() if p.is_file()}
            second = {p.name: p.read_bytes() for p in (root / "second").iterdir() if p.is_file()}
            self.assertTrue(expected <= first.keys())
            self.assertEqual(first, second)
            artifact = json.loads(first["lang-detector-v1.json"])
            self.assertEqual([profile["id"] for profile in artifact["profiles"]],
                             ["background", "cs", "de", "en", "sk"])
            manifest = json.loads(first["lang-detector-v1.manifest.json"])
            self.assertEqual(manifest["artifactSha256"], hashlib.sha256(first["lang-detector-v1.json"]).hexdigest())
            self.assertEqual(manifest["snapshotSkew"], {
                "missingFromBase": 0, "cc0DetailMismatch": 0,
                "excludedIdsSha256": hashlib.sha256(b"").hexdigest(), "sampleIds": []})

    def test_export_records_skew_and_verify_rejects_fabricated_summary(self):
        from tools.lang.train_detector import train, verify_only
        from tools.lang.tests.test_prepare_corpus import DEFAULT_RECORDS, replace_export
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            lock = json.loads(args[1].read_text())
            base = next(entry for entry in lock["files"] if entry["role"] == "base")
            replace_export(args[0], base, "".join(
                f"{number}\t\\N\n" for number, _, _, _ in DEFAULT_RECORDS if number != 7).encode())
            cc0 = next(entry for entry in lock["files"] if entry["role"] == "cc0")
            replace_export(args[0], cc0, b"8\tdeu\tChanged after details export.\t2026-10-09 00:00:00\n")
            args[1].write_text(json.dumps(lock), encoding="utf-8")
            config = json.loads(args[2].read_text())
            config["maxSnapshotSkewBp"] = 3000
            args[2].write_text(json.dumps(config), encoding="utf-8")
            report = train(*args)
            manifest_path = args[3] / "lang-detector-v1.manifest.json"
            manifest = json.loads(manifest_path.read_text())
            expected = {"missingFromBase": 1, "cc0DetailMismatch": 1,
                        "excludedIdsSha256": hashlib.sha256(b"7\n8").hexdigest(), "sampleIds": [7, 8]}
            self.assertEqual(manifest["snapshotSkew"], expected)
            self.assertEqual(report["preparation"]["snapshotSkew"], expected)
            verify_only(*args)
            for summary in (None, {"missingFromBase": 0, "cc0DetailMismatch": 0,
                                  "excludedIdsSha256": hashlib.sha256(b"").hexdigest(), "sampleIds": []}):
                changed = copy.deepcopy(manifest)
                if summary is None:
                    del changed["snapshotSkew"]
                else:
                    changed["snapshotSkew"] = summary
                manifest_path.write_text(json.dumps(changed) + "\n", encoding="utf-8")
                with self.subTest(summary=summary), self.assertRaisesRegex(ValueError, "snapshotSkew"):
                    verify_only(*args)

    def test_training_config_accepts_bounded_snapshot_skew_limit(self):
        from tools.lang.train_detector import validate_config
        for limit in (0, 100, 10000):
            with self.subTest(limit=limit):
                validate_config({**training_config(), "maxSnapshotSkewBp": limit})
        for limit in (True, -1, 10001, 100.0, "100"):
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                validate_config({**training_config(), "maxSnapshotSkewBp": limit})

    def test_snapshot_skew_schema_matches_supported_sentence_id_range(self):
        from tools.lang.prepare_corpus import validate_snapshot_skew
        from tools.lang.train_detector import validate_schema
        summary = {"missingFromBase": 2, "cc0DetailMismatch": 0,
                   "excludedIdsSha256": hashlib.sha256(b"0\n9223372036854775807").hexdigest(),
                   "sampleIds": [0, 9223372036854775807]}
        schema = json.loads((ROOT / "tools/lang/schemas/manifest-v1.schema.json").read_text())
        validate_snapshot_skew(summary)
        validate_schema(summary, schema["properties"]["snapshotSkew"])

    def test_export_preserves_and_verifies_group_assignments(self):
        from tools.lang.train_detector import train, verify_only
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            report = train(*args)
            assignments = report["preparation"]["splitAssignments"]
            path = args[3] / assignments["path"]
            self.assertTrue(path.is_file(), "exported group provenance must not reference a deleted temporary file")
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), assignments["sha256"])
            self.assertEqual(len(path.read_bytes().splitlines()), assignments["groups"])
            verify_only(*args)
            path.write_bytes(path.read_bytes() + b"{}\n")
            with self.assertRaisesRegex(ValueError, "group|assignment"):
                verify_only(*args)

    def test_verify_packaged_artifact_without_developer_diagnostics(self):
        from tools.lang.train_detector import train, verify_only
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            report = train(*args)
            (args[3] / "groups.jsonl").unlink()
            (args[3] / "support-report.json").unlink()
            self.assertEqual({p.name for p in args[3].iterdir()},
                             {"lang-detector-v1.json", "lang-detector-v1.manifest.json", "NOTICE", "ATTRIBUTION.md"})
            result = verify_only(*args)
            self.assertEqual(result["artifactSha256"], report["artifactSha256"])
            manifest_path = args[3] / "lang-detector-v1.manifest.json"
            manifest = json.loads(manifest_path.read_text())
            del manifest["snapshotSkew"]
            manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
            self.assertEqual(verify_only(*args)["artifactSha256"], report["artifactSha256"])

    def test_verify_rejects_fabricated_calibration_environment_and_report(self):
        from tools.lang.train_detector import train, verify_only
        from tools.lang.prepare_corpus import json_bytes
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            train(*args)
            manifest_path = args[3] / "lang-detector-v1.manifest.json"
            report_path = args[3] / "support-report.json"
            manifest, report = json.loads(manifest_path.read_text()), json.loads(report_path.read_text())
            mutations = [
                ("disabled reason", lambda m, r: m["calibration"]["disabledBuckets"][0].update(reason="noEligibleThreshold")),
                ("environment dependency", lambda m, r: m["environment"]["dependencies"].append({"name": "invented", "version": "1"})),
                ("semantic command", lambda m, r: m["environment"]["commandArguments"].extend(["--unrecognized", "invented"])),
                ("command timestamp", lambda m, r: m["environment"]["commandArguments"].__setitem__(
                    m["environment"]["commandArguments"].index("--created-at") + 1, "2026-10-08T00:00:00Z")),
                ("readiness report", lambda m, r: r.update(readiness="passed")),
                ("enabled bucket report", lambda m, r: r.update(enabledBuckets=[12])),
                ("document report", lambda m, r: r["documentPredictions"][0].update(goldLabel="cs" if r["documentPredictions"][0]["goldLabel"] != "cs" else "en")),
            ]
            for name, mutation in mutations:
                m, r = copy.deepcopy(manifest), copy.deepcopy(report)
                mutation(m, r)
                manifest_path.write_bytes(json_bytes(m))
                report_path.write_bytes(json_bytes(r))
                with self.subTest(name=name), self.assertRaises(ValueError):
                    verify_only(*args)
            manifest_path.write_bytes(json_bytes(manifest))
            report_path.unlink()
            with self.assertRaisesRegex(ValueError, "report"):
                verify_only(*args)

    def test_verify_legacy_zero_skew_export_with_developer_report(self):
        from tools.lang.train_detector import train, verify_only
        from tools.lang.prepare_corpus import json_bytes
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            report = train(*args)
            manifest_path = args[3] / "lang-detector-v1.manifest.json"
            report_path = args[3] / "support-report.json"
            manifest = json.loads(manifest_path.read_text())
            legacy_manifest, legacy_report = copy.deepcopy(manifest), copy.deepcopy(report)
            del legacy_manifest["snapshotSkew"]
            del legacy_report["preparation"]["snapshotSkew"]
            manifest_path.write_bytes(json_bytes(legacy_manifest))
            report_path.write_bytes(json_bytes(legacy_report))
            self.assertEqual(verify_only(*args)["artifactSha256"], report["artifactSha256"])
            manifest_path.write_bytes(json_bytes(manifest))
            with self.assertRaisesRegex(ValueError, "report"):
                verify_only(*args)
            manifest_path.write_bytes(json_bytes(legacy_manifest))
            report["preparation"]["snapshotSkew"]["excludedIdsSha256"] = "0" * 64
            report_path.write_bytes(json_bytes(report))
            with self.assertRaisesRegex(ValueError, "report"):
                verify_only(*args)

    def test_test_labels_do_not_change_weights_or_thresholds(self):
        from tools.lang.prepare_corpus import group_id, split_group
        from tools.lang.train_detector import train
        from tools.lang.tests.test_prepare_corpus import DEFAULT_RECORDS
        test_id = next(i for i in range(1000, 2000) if split_group(group_id([f"tatoeba:{i}"]), 1729, (8000, 1000, 1000)) == "test")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            models, manifests = [], []
            for name, source_language in [("cs", "ces"), ("sk", "slk")]:
                run = root / name
                run.mkdir()
                records = list(DEFAULT_RECORDS) + [(test_id, source_language, "Toto je dlouhá věta pro testování jazyka.", "HeldOutOwner")]
                args = self.export_inputs(run, records)
                train(*args)
                models.append(json.loads((run / "out/lang-detector-v1.json").read_text()))
                manifests.append(json.loads((run / "out/lang-detector-v1.manifest.json").read_text()))
            for field in ("vocabulary", "profiles", "thresholds"):
                self.assertEqual(models[0][field], models[1][field], field)
            self.assertEqual([r for r in manifests[0]["support"] if r["split"] == "validation"],
                             [r for r in manifests[1]["support"] if r["split"] == "validation"])
            self.assertNotEqual([r for r in manifests[0]["support"] if r["split"] == "test"],
                                [r for r in manifests[1]["support"] if r["split"] == "test"])

    def test_verify_only_is_read_only_and_uses_recorded_revision(self):
        from tools.lang.train_detector import train, verify_only
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            train(*args)
            before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in args[3].iterdir()}
            with patch("tools.lang.train_detector._attribution", side_effect=AssertionError("verify must not generate NOTICE")):
                result = verify_only(*args[:-1], "1" * 40)
            self.assertEqual(result["exporterGitCommit"], "0" * 40)
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in args[3].iterdir()})

    def test_verify_only_rejects_retuned_threshold_with_updated_hash(self):
        from tools.lang.train_detector import train, verify_only
        from tools.lang.prepare_corpus import json_bytes
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            train(*args)
            artifact_path, manifest_path = args[3] / "lang-detector-v1.json", args[3] / "lang-detector-v1.manifest.json"
            model, manifest = json.loads(artifact_path.read_text()), json.loads(manifest_path.read_text())
            model["thresholds"][0]["minWinningScore"] += 1
            artifact_path.write_bytes(json_bytes(model))
            manifest["artifactSha256"] = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
            manifest_path.write_bytes(json_bytes(manifest))
            with self.assertRaisesRegex(ValueError, "threshold|calibrat"):
                verify_only(*args)

    def test_notice_reexport_is_idempotent_and_preserves_other_notices(self):
        from tools.lang.train_detector import train, BEGIN, END
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.export_inputs(root)
            train(*args)
            first = {p.name: p.read_bytes() for p in args[3].iterdir()}
            source_notice = root / "source-NOTICE"
            source_notice.write_bytes(first["NOTICE"])
            with patch("tools.lang.train_detector.NOTICE_PATH", source_notice):
                train(*args)
            self.assertEqual(first, {p.name: p.read_bytes() for p in args[3].iterdir()})
            source_notice.write_bytes(first["NOTICE"] + b"Unrelated trailing notice.\n")
            with patch("tools.lang.train_detector.NOTICE_PATH", source_notice):
                train(*args)
            notice = (args[3] / "NOTICE").read_text()
            self.assertEqual(notice.count(BEGIN), 1)
            self.assertEqual(notice.count(END), 1)
            self.assertTrue(notice.endswith("Unrelated trailing notice.\n"))

    def test_schema_and_semantic_reconciliation_reject_mutations(self):
        from tools.lang.train_detector import train, validate_outputs
        from tools.lang.reference import UnicodeData
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            train(*args)
            artifact = json.loads((args[3] / "lang-detector-v1.json").read_text())
            manifest = json.loads((args[3] / "lang-detector-v1.manifest.json").read_text())
            attribution, notice = (args[3] / "ATTRIBUTION.md").read_bytes(), (args[3] / "NOTICE").read_bytes()
            tables = UnicodeData.load(ROOT / "Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json")
            legacy_manifest = copy.deepcopy(manifest)
            legacy_manifest.pop("snapshotSkew")
            validate_outputs(artifact, legacy_manifest, attribution, notice, tables)
            mutations = [
                ("unknown artifact", lambda a, m: a.update(unknown=1)),
                ("boolean integer", lambda a, m: a.update(alpha=True)),
                ("duplicate metric", lambda a, m: m["metrics"].append(copy.deepcopy(m["metrics"][0]))),
                ("duplicate support", lambda a, m: m["support"].append(copy.deepcopy(m["support"][0]))),
                ("wrong support", lambda a, m: m["support"][0].update(evaluated=999)),
                ("invalid date", lambda a, m: m.update(createdAt="2026-02-30T00:00:00Z")),
                ("Unicode host", lambda a, m: m["environment"]["unicodeFiles"][0].update(url="https://foreign.invalid/UnicodeData.txt")),
                ("duplicate disabled", lambda a, m: m["calibration"]["disabledBuckets"].append(copy.deepcopy(m["calibration"]["disabledBuckets"][0]))),
                ("augmentation lengths", lambda a, m: m["augmentation"][1].update(lengths=[24])),
                ("unsorted concat lengths", lambda a, m: m["augmentation"][2].update(lengths=[160, 64])),
                ("unknown augmentation", lambda a, m: m["augmentation"][2].update(algorithm="concat-v2")),
                ("augmentation private cap", lambda a, m: m["augmentation"][2].update(maxOutputs=[])),
                ("unreconciled coverage", lambda a, m: next(r for r in m["metrics"] if r["name"] == "acceptanceCoverage").update(denominator=1, rateBp=0)),
                ("unreconciled accepted denominator", lambda a, m: next(r for r in m["metrics"] if r["name"] == "acceptedError").update(denominator=1, rateBp=0)),
                ("impossible original groups", lambda a, m: m["counts"][0].update(originalGroups=9007199254740991)),
                ("corpus original total", lambda a, m: m["corpus"][0].update(originalRecords=m["corpus"][0]["originalRecords"] + 1)),
                ("augmentation output total", lambda a, m: m["augmentation"][0].update(outputCount=m["augmentation"][0]["outputCount"] + 1)),
                ("negative skew count", lambda a, m: m["snapshotSkew"].update(missingFromBase=-1)),
                ("boolean skew count", lambda a, m: m["snapshotSkew"].update(cc0DetailMismatch=True)),
                ("invalid skew hash", lambda a, m: m["snapshotSkew"].update(excludedIdsSha256="invalid")),
                ("unexpected skew property", lambda a, m: m["snapshotSkew"].update(unknown=0)),
                ("inconsistent skew sample", lambda a, m: m["snapshotSkew"].update(sampleIds=[7])),
                ("duplicate skew samples", lambda a, m: m["snapshotSkew"].update(
                    missingFromBase=2, sampleIds=[7, 7], excludedIdsSha256=hashlib.sha256(b"7\n7").hexdigest())),
            ]
            for name, mutation in mutations:
                a, m = copy.deepcopy(artifact), copy.deepcopy(manifest)
                mutation(a, m)
                with self.subTest(name=name), self.assertRaises(ValueError):
                    validate_outputs(a, m, attribution, notice, tables)

    def test_config_is_expanded_and_cli_help_is_offline(self):
        from tools.lang.train_detector import validate_config
        config = json.loads((ROOT / "tools/lang/training-v1.json").read_text())
        validate_config(config)
        self.assertEqual(config["modelId"], "tatoeba-cs-de-en-sk-v1")
        self.assertEqual(len(config["caps"]), 30)
        concat = next(rule for rule in config["augmentation"] if rule["algorithm"] == "concat-v1")
        self.assertEqual(concat["splits"], ["validation", "test"])
        self.assertEqual(concat["lengths"], [64, 160, 512, 1024])
        self.assertEqual(sorted((r["split"], r["language"]) for r in concat["maxOutputs"]),
                         sorted((s, l) for s in ["validation", "test"] for l in sorted(TARGETS + NEGATIVES)))
        self.assertEqual({r["maxOutputsPerLength"] for r in concat["maxOutputs"]}, {1000})
        for row in config["calibration"]["candidates"]:
            self.assertEqual(row["minWinningScores"], list(range(-120000, 1, 2000)))
            self.assertEqual(row["minMargins"], [1,128,256,512,1024,2048,4096,8192])
            self.assertEqual(row["minKnownCoverageBp"], [0,2500,5000,7500,9000,9500,10000])
        subprocess.run([sys.executable, "-B", str(ROOT / "tools/lang/train_detector.py"), "--help"],
                       cwd=ROOT, check=True, capture_output=True)

    def test_wp1_snapshot_cannot_be_empty_or_claim_another_url_revision(self):
        from tools.lang.train_detector import load_wp1
        from tools.lang.prepare_corpus import snapshot_wp1
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "snapshot.json"
            valid = snapshot_wp1(ROOT / "eval/multilingual")
            for change in ("empty", "revision"):
                snapshot = copy.deepcopy(valid)
                if change == "empty":
                    snapshot["documents"] = []
                else:
                    snapshot["documents"][0]["url"] = snapshot["documents"][0]["url"].replace(snapshot["sourceRevision"], "0" * 40)
                path.write_text(json.dumps(snapshot), encoding="utf-8")
                with self.subTest(change=change), self.assertRaises(ValueError):
                    load_wp1(path)

    def test_verify_only_rejects_missing_attribution_even_with_rehashed_artifact(self):
        from tools.lang.train_detector import train, verify_only
        from tools.lang.prepare_corpus import json_bytes
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary))
            train(*args)
            artifact_path, manifest_path = args[3] / "lang-detector-v1.json", args[3] / "lang-detector-v1.manifest.json"
            attribution_path = args[3] / "ATTRIBUTION.md"
            attribution_path.write_bytes(b"Incomplete attribution.\n")
            model, manifest = json.loads(artifact_path.read_text()), json.loads(manifest_path.read_text())
            model["attribution"]["attributionSha256"] = hashlib.sha256(attribution_path.read_bytes()).hexdigest()
            artifact_path.write_bytes(json_bytes(model))
            manifest["artifactSha256"] = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
            manifest["attribution"] = model["attribution"]
            manifest_path.write_bytes(json_bytes(manifest))
            with self.assertRaisesRegex(ValueError, "attribution"):
                verify_only(*args)

    def test_concat_examples_round_trip_through_export_and_verification(self):
        from tools.lang.train_detector import train, validate_schema, verify_only
        with tempfile.TemporaryDirectory() as temporary:
            args = self.export_inputs(Path(temporary), records=concat_records(), links=CONCAT_LINKS)
            report = train(*args)
            manifest = json.loads((args[3] / "lang-detector-v1.manifest.json").read_text())
            concat = next(rule for rule in manifest["augmentation"] if rule["algorithm"] == "concat-v1")
            self.assertEqual(set(concat), {"algorithm", "splits", "lengths", "inputCount", "outputCount"})
            self.assertEqual(concat["lengths"], [64, 160])
            self.assertGreater(concat["outputCount"], 0)
            self.assertEqual(concat["inputCount"], sum(r["originals"] for r in manifest["counts"]
                                                       if r["split"] in ("validation", "test")))
            self.assertEqual(report["preparation"]["augmentationRules"], training_config()["augmentation"])
            validate_schema(manifest, json.loads((ROOT / "tools/lang/schemas/manifest-v1.schema.json").read_text()))
            long_support = [r for r in manifest["support"] if r["bucketStart"] >= 80 and r["evaluated"]]
            self.assertTrue(long_support, "concatenations must populate long-text buckets")
            verify_only(*args)


class AttributionTests(unittest.TestCase):
    def attribution(self, rows, selected=None):
        from tools.lang.train_detector import _attribution_data
        with tempfile.TemporaryDirectory() as temporary:
            examples = Path(temporary) / "examples.jsonl"
            examples.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
            originals = [row for row in rows if row["rule"] == "original"]
            provenance = {"snapshotDate": "2026-10-03", "files": [
                {"url": "https://downloads.tatoeba.org/exports/links.tar.bz2", "sha256": "a" * 64,
                 "uncompressedSha256": "b" * 64, "role": "links"},
                {"url": "https://downloads.tatoeba.org/exports/sentences_CC0.tar.bz2", "sha256": "c" * 64,
                 "uncompressedSha256": "d" * 64, "role": "cc0"}],
                "selectedSentences": selected or {"path": "selected-sentences.tsv", "records": len(originals),
                                                  "sha256": "e" * 64}}
            snapshot = {"documents": [{"sourceId": "multilingual-v1", "documentId": "doc-1", "licenseId": "MIT",
                                       "translationGroupId": "doc-1", "url": "https://example.invalid/doc-1",
                                       "sha256": "f" * 64}]}
            return _attribution_data(examples, snapshot, provenance)

    @staticmethod
    def rows(count, contributor="Prolific", license_id="CC-BY-2.0-FR", start=1):
        return [{"sourceId": "tatoeba", "recordKey": f"tatoeba:{i}", "contributor": contributor,
                 "licenseId": license_id, "rule": rule} for i in range(start, start + count)
                for rule in ("original", "scalar-prefix-v1")]

    def test_attribution_is_compact_and_aggregates_contributors(self):
        rows = (self.rows(3, "zeta") + self.rows(5, "alpha", start=100) + self.rows(5, "beta", start=200)
                + self.rows(2, "\\N", "CC0-1.0", start=300) + self.rows(1, "gamma", "CC0-1.0", start=400))
        raw, sources, licenses = self.attribution(rows)
        text = raw.decode("utf-8")
        self.assertEqual(sources, ["multilingual-v1", "tatoeba"])
        self.assertEqual(licenses, ["CC-BY-2.0-FR", "CC0-1.0", "MIT", "Unicode-3.0"])
        for needle in ["https://tatoeba.org", "CC BY 2.0 FR", "https://creativecommons.org/licenses/by/2.0/fr/",
                       "https://creativecommons.org/publicdomain/zero/1.0/", "2026-10-03",
                       "https://downloads.tatoeba.org/exports/links.tar.bz2", "a" * 64, "b" * 64, "c" * 64,
                       "Selected original sentences: 16", "SHA-256 `" + "e" * 64 + "`", "selected-sentences.tsv",
                       "tools/lang/prepare_corpus.py", "doc-1"]:
            self.assertIn(needle, text)
        self.assertRegex(text, r"(?s)- alpha: 5\n- beta: 5\n- zeta: 3\n")
        self.assertRegex(text, r"(?s)- \(no contributor supplied\): 2\n- gamma: 1\n")
        self.assertNotRegex(text, r"sentences/show/[0-9]")
        self.assertEqual(text.count("- alpha:"), 1)

    def test_attribution_size_does_not_grow_with_sentences_per_contributor(self):
        small = self.attribution(self.rows(10))[0]
        large = self.attribution(self.rows(5000))[0]
        self.assertLessEqual(len(large) - len(small), 16)
        self.assertLess(len(large), 1_000_000)

    def test_attribution_rejects_ledger_count_mismatch(self):
        with self.assertRaisesRegex(ValueError, "selected"):
            self.attribution(self.rows(3), {"path": "selected-sentences.tsv", "records": 4, "sha256": "e" * 64})


if __name__ == "__main__":
    unittest.main()
