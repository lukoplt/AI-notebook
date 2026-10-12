"""Held-out release evaluation and gate tests (WP4 Task 14)."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest

from tools.lang.evaluate_detector import (CI_PER_GROUP, assert_release_gate, compact_document, compact_text,
    digest_features, digest_word_scalars, digest_words, evaluate, evaluate_documents, selection_key, select_ci)


ROOT = Path(__file__).resolve().parents[3]
LANGUAGES = ["cs", "de", "en", "fr", "hr", "hu", "nl", "pl", "sk", "sl"]


def gate_row(split, bucket, **overrides):
    row = {"split": split, "bucketStart": bucket, "enabled": 1, "supportPass": True,
           "acceptedError": {"numerator": 0, "denominator": 1000},
           "csSkConfusion": {"numerator": 0, "denominator": 200},
           "foreignAcceptance": {"numerator": 0, "denominator": 1200},
           "acceptanceCoverage": {"numerator": 1000, "denominator": 2000}}
    row.update(overrides)
    return row


def passing_report(buckets=(12,)):
    return {"enabledBuckets": list(buckets),
            "gateRows": [gate_row(split, bucket) for split in ("validation", "test") for bucket in buckets]}


def manifest(disabled=()):
    return {"negativeLanguages": ["fr", "hr", "hu", "nl", "pl", "sl"],
            "calibration": {"disabledBuckets": [{"bucketStart": b, "reason": "insufficientSupport"} for b in disabled]}}


class EvaluationTests(unittest.TestCase):
    def test_test_support_cannot_be_retuned_away(self):
        report = {"enabledBuckets": [12], "gateRows": [
            {"split": "test", "bucketStart": 12, "supportPass": False,
             "acceptedError": {"numerator": 0, "denominator": 999},
             "csSkConfusion": {"numerator": 0, "denominator": 200},
             "foreignAcceptance": {"numerator": 0, "denominator": 1200}}]}
        with self.assertRaisesRegex(ValueError, "support"):
            assert_release_gate(report)

    def test_passing_report_and_exact_cross_products(self):
        assert_release_gate(passing_report((12, 32)))
        report = passing_report()
        report["gateRows"][1]["acceptedError"] = {"numerator": 20, "denominator": 1000}  # exactly 200 bp
        assert_release_gate(report)
        report["gateRows"][1]["acceptedError"] = {"numerator": 2001, "denominator": 100000}  # 200.1 bp
        with self.assertRaisesRegex(ValueError, r"test bucket 12: acceptedError 2001/100000"):
            assert_release_gate(report)

    def test_zero_denominator_never_passes(self):
        report = passing_report()
        report["gateRows"][0]["csSkConfusion"] = {"numerator": 0, "denominator": 0}
        with self.assertRaisesRegex(ValueError, "validation bucket 12: csSkConfusion 0/0"):
            assert_release_gate(report)

    def test_both_splits_are_required_for_each_enabled_bucket(self):
        report = passing_report()
        report["gateRows"] = report["gateRows"][:1]
        with self.assertRaisesRegex(ValueError, "test bucket 12: missing gate row"):
            assert_release_gate(report)

    def test_all_disabled_artifact_requires_usefulness_review(self):
        with self.assertRaisesRegex(ValueError, "NO_ENABLED_BUCKETS: usefulness review required"):
            assert_release_gate({"enabledBuckets": [], "gateRows": []})

    def test_manifest_and_native_parity_failures_fail_the_gate(self):
        report = passing_report()
        report["manifestReconciled"] = {"support": True, "metrics": False, "documentMetrics": True}
        with self.assertRaisesRegex(ValueError, "metrics do not reproduce the manifest"):
            assert_release_gate(report)
        report = passing_report()
        report["nativeParity"] = {"expectedCases": 10, "platforms": {
            "swift": {"exitCode": 0, "cases": 10, "mismatches": 0},
            "csharp": {"exitCode": 1, "cases": 10, "mismatches": 2}}}
        with self.assertRaisesRegex(ValueError, "native parity csharp: 2 mismatches"):
            assert_release_gate(report)
        report["nativeParity"]["platforms"]["csharp"] = {"exitCode": 0, "cases": 9, "mismatches": 0}
        with self.assertRaisesRegex(ValueError, "native parity csharp: evaluated 9 of 10"):
            assert_release_gate(report)

    def test_evaluate_counts_abstentions_groups_and_cs_sk_confusion(self):
        rows, predictions = [], []

        def add(split, truth, group, label, letters):
            rows.append({"split": split, "truth": truth, "originalGroupId": group})
            bucket = max(b for b in (0, 12, 32, 80, 200) if b <= letters)
            predictions.append({"label": label, "letterCount": letters, "bucketStart": bucket or None})

        add("test", "cs", "g1", "cs", 20)
        add("test", "cs", "g1", "sk", 20)   # same group, cs→sk confusion
        add("test", "sk", "g2", "und", 20)  # abstention still counts as evaluated support
        add("test", "fr", "g3", "en", 20)   # foreign acceptance
        add("test", "fr", "g4", "und", 5)   # below-minimum reporting bucket
        add("validation", "en", "g5", "en", 40)
        report = evaluate(rows, predictions, manifest())
        test12 = next(r for r in report["gateRows"] if r["split"] == "test" and r["bucketStart"] == 12)
        self.assertEqual(test12["acceptedError"], {"numerator": 2, "denominator": 3, "rateBp": 6666})
        self.assertEqual(test12["csSkConfusion"], {"numerator": 1, "denominator": 2, "rateBp": 5000})
        self.assertEqual(test12["foreignAcceptance"], {"numerator": 1, "denominator": 1, "rateBp": 10000})
        self.assertEqual(test12["acceptanceCoverage"], {"numerator": 3, "denominator": 4, "rateBp": 7500})
        self.assertFalse(test12["supportPass"])
        support = {(r["split"], r["bucketStart"], r["language"]): r for r in report["support"]}
        self.assertEqual(support["test", 12, "cs"], {"split": "test", "bucketStart": 12, "language": "cs",
                                                     "originalGroups": 1, "evaluated": 2, "accepted": 2})
        self.assertEqual(support["test", 12, "sk"]["accepted"], 0)
        self.assertNotIn(("test", 0, "fr"), support)  # support rows only cover gate buckets
        metrics = {(r["split"], r["bucketStart"], r["language"], r["name"]): r for r in report["metrics"]}
        self.assertEqual(metrics["test", 0, "fr", "acceptanceCoverage"]["denominator"], 1)
        self.assertEqual(metrics["test", 12, "cs", "csSkConfusion"]["numerator"], 1)
        self.assertEqual(metrics["test", 12, "cs", "foreignAcceptance"]["denominator"], 0)
        self.assertEqual(report["evaluated"], {"validation": 1, "test": 5})
        self.assertEqual(report["enabledBuckets"], [12, 32, 80, 200])
        self.assertEqual(report["manifestReconciled"]["support"], False)  # minimal manifest records none

    def test_evaluate_reconciles_with_manifest_rows_and_disabled_buckets(self):
        rows = [{"split": "test", "truth": "de", "originalGroupId": "g"}]
        predictions = [{"label": "de", "letterCount": 12, "bucketStart": 12}]
        first = evaluate(rows, predictions, manifest(disabled=(200,)))
        self.assertEqual(first["enabledBuckets"], [12, 32, 80])
        self.assertEqual(first["disabledBuckets"], [{"bucketStart": 200, "reason": "insufficientSupport"}])
        recorded = {**manifest(disabled=(200,)), "support": first["support"], "metrics": first["metrics"]}
        self.assertEqual(evaluate(rows, predictions, recorded)["manifestReconciled"],
                         {"support": True, "metrics": True})
        with self.assertRaisesRegex(ValueError, "bucketStart"):
            evaluate(rows, [{"label": "de", "letterCount": 40, "bucketStart": 12}], manifest())
        with self.assertRaisesRegex(ValueError, "aligned"):
            evaluate(rows, [], manifest())

    def test_documents_are_counted_separately_with_window_decisions(self):
        snapshot = {"documents": [
            {"documentId": "cs-1", "sourceId": "s", "goldLabel": "cs"},
            {"documentId": "mx-1", "sourceId": "s", "goldLabel": "mixed"}]}

        def document(label, windows):
            return {"label": label, "reason": "dominant" if label == "cs" else "insufficientEvidence",
                    "sharesBp": {"cs": 6000}, "unknownShareBp": 4000, "langCoverageBp": 6000, "sampledLetters": 10,
                    "windows": [{"start": 0, "end": 5, "expected": {"label": w, "reason": r, "letterCount": 5}}
                                for w, r in windows]}

        result = evaluate_documents(snapshot, [document("cs", [("cs", "accepted")]),
                                               document("und", [("cs", "accepted"), ("und", "minMargin")])],
                                    {"documentMetrics": []})
        self.assertEqual(result["documentMetrics"], [
            {"sourceId": "s", "goldLabel": "cs", "predictedLabel": "cs", "count": 1},
            {"sourceId": "s", "goldLabel": "mixed", "predictedLabel": "und", "count": 1}])
        self.assertEqual(result["confusion"]["mixed"]["und"], 1)
        self.assertEqual([m["documentId"] for m in result["mistakes"]], ["mx-1"])
        self.assertEqual(result["mistakes"][0]["windows"], [
            {"label": "cs", "reason": "accepted", "letterCount": 5},
            {"label": "und", "reason": "minMargin", "letterCount": 5}])
        self.assertEqual(result["correct"], 1)
        self.assertFalse(result["reconciled"])

    def test_compact_digests_are_canonical_and_complete(self):
        features = [[{"symbols": [-2], "count": 3}, {"symbols": [97], "count": 12}],
                    [{"symbols": [-1, 97], "count": 3}], []]
        canonical = "-2:3;97:12|-1,97:3|"
        self.assertEqual(digest_features(features), "sha256:" + hashlib.sha256(canonical.encode()).hexdigest())
        self.assertEqual(digest_word_scalars([[97, 98], [269]]),
                         "sha256:" + hashlib.sha256(b"97,98;269").hexdigest())
        self.assertEqual(digest_word_scalars([]), "sha256:" + hashlib.sha256(b"").hexdigest())
        self.assertEqual(digest_words(["ab", "č"]), "sha256:" + hashlib.sha256("ab\0č".encode()).hexdigest())
        text = {"words": ["ab"], "wordScalars": [[97, 98]], "features": features, "label": "und"}
        compact = compact_text(text)
        self.assertEqual(set(compact), set(text))
        self.assertEqual(compact["label"], "und")
        self.assertTrue(compact["features"].startswith("sha256:"))
        self.assertIsInstance(text["features"], list)  # input is not mutated
        document = compact_document({"label": "und", "windows": [{"start": 0, "end": 2, "expected": text}]})
        self.assertEqual(document["windows"][0]["expected"], compact)

    def test_ci_selection_is_first_by_hash_per_language_and_bucket(self):
        key = selection_key("tatoeba:7", "concat-v1", 64)
        self.assertEqual(key, (hashlib.sha256(b"tatoeba:7\nconcat-v1\n64\n").hexdigest(), "tatoeba:7"))
        self.assertEqual(selection_key("tatoeba:7", "original", None)[0],
                         hashlib.sha256(b"tatoeba:7\noriginal\n\n").hexdigest())
        candidates = [{"language": "cs", "bucketStart": 12, "recordKey": f"tatoeba:{i}", "rule": "original",
                       "length": None} for i in range(40)]
        candidates.append({"language": "sk", "bucketStart": 0, "recordKey": "tatoeba:99", "rule": "original",
                           "length": None})
        selected = select_ci(candidates)
        cs = [c for c in selected if c["language"] == "cs"]
        self.assertEqual(len(cs), CI_PER_GROUP)
        expected = sorted(candidates[:40], key=lambda c: selection_key(c["recordKey"], c["rule"], c["length"]))
        self.assertEqual(cs, expected[:CI_PER_GROUP])
        self.assertEqual([c["recordKey"] for c in selected if c["language"] == "sk"], ["tatoeba:99"])

    def test_cli_help_is_offline(self):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "tools/lang/evaluate_detector.py"), "--help"],
                                cwd=ROOT, capture_output=True, text=True, check=True)
        for flag in ("--data-dir", "--artifact", "--manifest", "--wp1-documents", "--work-dir",
                     "--fixture-output", "--metrics-output", "--report", "--native-parity", "--gate"):
            self.assertIn(flag, result.stdout)


class CommittedReleaseFixtureTests(unittest.TestCase):
    """The committed CI replay must stay compact, attributed and tied to the bundled artifact."""

    def test_committed_fixture_is_compact_attributed_and_pinned(self):
        path = ROOT / "Tests/fixtures/contracts/lang-release-v1.json"
        raw = path.read_bytes()
        self.assertLess(len(raw), 2 * 1024 * 1024)
        fixture = json.loads(raw)
        manifest_path = ROOT / "Sources/AINotebookCore/Resources/Language/lang-detector-v1.manifest.json"
        self.assertEqual(fixture["artifactSha256"], json.loads(manifest_path.read_bytes())["artifactSha256"])
        self.assertEqual(set(fixture), {"contract", "version", "artifactSha256", "compaction", "attribution", "cases"})
        names = [c["name"] for c in fixture["cases"]]
        self.assertEqual(len(names), len(set(names)))
        text = [c for c in fixture["cases"] if c["mode"] == "text"]
        documents = [c for c in fixture["cases"] if c["mode"] == "document"]
        self.assertEqual(len(documents), 44)
        for case in text:
            self.assertEqual(case["sourceId"], "tatoeba")
            self.assertTrue(case["members"])
            for member in case["members"]:
                self.assertRegex(member["recordKey"], r"^tatoeba:[0-9]+$")
                self.assertIn(member["licenseId"], ("CC-BY-2.0-FR", "CC0-1.0"))
                if member["licenseId"] == "CC-BY-2.0-FR":
                    self.assertTrue(member["contributor"])
            for field in ("features", "wordScalars", "words"):
                self.assertTrue(case["expected"][field].startswith("sha256:"))
        for case in documents:
            self.assertEqual(case["sourceId"], "multilingual-v1")
            self.assertEqual(case["licenseId"], "MIT")


if __name__ == "__main__":
    unittest.main()
