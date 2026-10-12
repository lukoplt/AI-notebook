"""Offline independent-reference conformance against the committed contracts."""

import copy
import hashlib
import json
import unittest
from collections import Counter
from fractions import Fraction
from pathlib import Path

from tools.lang.reference import (
    UnicodeData,
    aggregate,
    classify,
    decode_utf16,
    detect_document,
    detect_text,
    export_profiles,
    features,
    normalize,
    normalize_utf16,
    round_even,
    round_log_weight,
    score_slice,
    window_ranges,
)


ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "Tests/fixtures"
RESOURCES = ROOT / "Sources/AINotebookCore/Resources/Language"
NORMALIZATION_SHA256 = "871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e"


def fixture(name):
    return json.loads((FIXTURES / "contracts" / f"{name}.json").read_text(encoding="utf-8"))


class ReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tables = UnicodeData.load(RESOURCES / "unicode-15.1.0.json")
        cls.score_fixture = fixture("lang-score-v1")

    def test_proven_rounding(self):
        for numerator, denominator, expected in [
            (37, 72, -682), (1, 3, -1125), (1, 4, -1420),
            (1, 5, -1648), (1, 1, 0),
        ]:
            with self.subTest(numerator=numerator, denominator=denominator):
                self.assertEqual(round_log_weight(numerator, denominator), expected)
        self.assertEqual(round_log_weight(1, 2, scale=1), -1)
        self.assertEqual(round_log_weight(1, 2, scale=2), -1)

    def test_exact_ties_to_even(self):
        for numerator, expected in [(-7, -4), (-5, -2), (-3, -2), (-1, 0),
                                    (1, 0), (3, 2), (5, 2), (7, 4)]:
            with self.subTest(numerator=numerator):
                self.assertEqual(round_even(Fraction(numerator, 2)), expected)
        self.assertEqual(round_even(Fraction(-249, 100)), -2)
        self.assertEqual(round_even(Fraction(-251, 100)), -3)

    def test_rejects_invalid_probability(self):
        for numerator, denominator in [(0, 1), (-1, 2), (1, 0), (1, -2), (2, 1)]:
            with self.subTest(numerator=numerator, denominator=denominator):
                with self.assertRaises(ValueError):
                    round_log_weight(numerator, denominator)

    def test_reconstructs_every_synthetic_weight(self):
        actual = export_profiles(self.score_fixture["training"], [3, 3, 3], self.tables)
        for field in ["vocabulary", "profiles"]:
            self.assertEqual(actual[field], self.score_fixture["model"][field], field)

    def test_every_intermediate(self):
        cases = self.score_fixture["cases"]
        self.assertEqual(len(cases), 32)
        self.assertEqual(Counter(c["mode"] for c in cases), {"text": 23, "document": 9})
        for case in cases:
            with self.subTest(case=case["name"]):
                fn = detect_text if case["mode"] == "text" else detect_document
                self.assertEqual(fn(case["input"], self.score_fixture["model"], self.tables),
                                 case["expected"])

    def test_all_normalization_cases(self):
        cases = fixture("lang-normalize-v1")["cases"]
        self.assertEqual(len(cases), 44)
        for case in cases:
            with self.subTest(case=case["name"]):
                if "utf16Units" in case:
                    scalars = normalize_utf16(case["utf16Units"], self.tables, 5_000_000)
                else:
                    scalars = normalize(case["input"], self.tables, 5_000_000)
                self.assertEqual(classify(scalars, self.tables), case["expected"])

    def test_all_pinned_nfc_conformance_rows(self):
        path = FIXTURES / "unicode/NormalizationTest-15.1.0.txt"
        raw = path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), NORMALIZATION_SHA256)
        self.assertEqual(path.with_suffix(path.suffix + ".sha256").read_text().strip(),
                         NORMALIZATION_SHA256)
        sources = json.loads((RESOURCES / "unicode-sources-v1.json").read_text())
        rows = 0
        for line in raw.decode("utf-8").splitlines():
            body = line.split("#", 1)[0].strip()
            if not body or body.startswith("@"):
                continue
            columns = [[int(cp, 16) for cp in field.split()]
                       for field in body.split(";")[:5]]
            self.assertEqual(len(columns), 5)
            for index, column in enumerate(columns):
                with self.subTest(row=rows, column=index + 1):
                    self.assertEqual(self.tables.nfc(column), columns[1 if index < 3 else 3])
            rows += 1
        self.assertEqual(rows, 19074)
        self.assertEqual(rows, sources["normalizationRows"])

    def test_unicode_table_operations(self):
        for case in fixture("unicode-tables-v1")["cases"]:
            with self.subTest(case=case["name"]):
                operation, scalars = case["operation"], case["input"]
                if operation == "nfc":
                    actual = self.tables.nfc(scalars)
                elif operation == "fold":
                    actual = self.tables.fold(scalars)
                elif operation == "lower":
                    actual = [self.tables.simple_lower(cp) for cp in scalars]
                elif operation == "category":
                    actual = [self.tables.category(cp) for cp in scalars]
                else:
                    self.fail(f"Unhandled Unicode operation: {operation}")
                self.assertEqual(actual, case["expected"])

    def test_runtime_supplemental_contract(self):
        cases = fixture("lang-runtime-v1")["cases"]
        self.assertEqual({case["operation"] for case in cases},
                         {"normalize", "windows", "aggregate", "score"})
        for case in cases:
            with self.subTest(case=case["name"]):
                operation, value = case["operation"], case["input"]
                if operation == "normalize":
                    stream = normalize_utf16(value["utf16Units"], self.tables, value["inputCap"])
                    scalars = stream[:value["textCap"]] if value["mode"] == "text" else stream
                    actual = {"stream": stream, "scalars": scalars,
                              **classify(scalars, self.tables)}
                elif operation == "windows":
                    actual = window_ranges(value["length"], value["count"], value["size"])
                elif operation == "aggregate":
                    actual = aggregate(value["targets"], value["labels"], value["letters"])
                elif operation == "score":
                    model = copy.deepcopy(self.score_fixture["model"])
                    for field, override in case["modelOverrides"].items():
                        if isinstance(override, dict):
                            model[field].update(override)
                        else:
                            model[field] = override
                    actual = detect_text(value, model, self.tables)
                else:
                    self.fail(f"Unhandled runtime operation: {operation}")
                self.assertEqual(actual, case["expected"])

    def test_features_count_occurrences_and_do_not_cross_words(self):
        self.assertEqual(features([[97], [97]]), [
            Counter({(-1,): 2, (97,): 2, (-2,): 2}),
            Counter({(-1, 97): 2, (97, -2): 2}),
            Counter({(-1, 97, -2): 2}),
        ])
        self.assertEqual(features([]), [Counter(), Counter(), Counter()])

    def test_utf16_cap_counts_decoded_scalars(self):
        self.assertEqual(decode_utf16([0xD801, 0xDC00, 65], 1), [0x10400])
        self.assertEqual(decode_utf16([0xD800, 0xD800, 0xDC00, 65], 3),
                         [0xFFFD, 0x10000, 65])
        self.assertEqual(decode_utf16([0xDC00, 0xD800], 2), [0xFFFD, 0xFFFD])

    def test_score_slice_consumes_normalized_scalars(self):
        case = self.score_fixture["cases"][0]
        self.assertEqual(score_slice([ord(cp) for cp in case["input"]],
                                     self.score_fixture["model"], self.tables), case["expected"])


if __name__ == "__main__":
    unittest.main()
