import hashlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import zipfile

from tools.unicode import gen_tables as gen
from tools.unicode.gen_tables import parse_unicode_data, verify_bytes


class GeneratorTests(unittest.TestCase):
    def test_rejects_changed_pinned_bytes(self):
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            verify_bytes("UnicodeData.txt", b"wrong\n")

    def test_simple_lower_is_not_full_fold(self):
        fields = [""] * 15
        fields[0:5] = ["0130", "LATIN CAPITAL LETTER I WITH DOT ABOVE", "Lu", "0", "L"]
        fields[5] = "0049 0307"
        fields[13] = "0069"
        table = parse_unicode_data(";".join(fields) + "\n")
        self.assertEqual(table["simpleLower"], [[304, 105]])
        self.assertEqual(table["decomposition"], [[304, [73, 775]]])

    def test_first_last_expands_inclusive_range(self):
        rows = []
        for cp, name in [(0x3400, "<CJK Ideograph Extension A, First>"),
                         (0x4DBF, "<CJK Ideograph Extension A, Last>")]:
            fields = [""] * 15
            fields[0:5] = [f"{cp:04X}", name, "Lo", "0", "L"]
            rows.append(";".join(fields))
        self.assertEqual(parse_unicode_data("\n".join(rows))["categories"],
                         [[0x3400, 0x4DBF, "Lo"]])

    @staticmethod
    def row(cp, name="TEST", category="Lo", ccc="0", decomposition="", lower=""):
        fields = [""] * 15
        fields[0:6] = [cp, name, category, ccc, "L", decomposition]
        fields[13] = lower
        return ";".join(fields)

    def test_coalesces_only_adjacent_equal_categories(self):
        rows = [self.row("0041", category="Lu"), self.row("0042", category="Lu"),
                self.row("0044", category="Lu"), self.row("0045", category="Ll")]
        self.assertEqual(parse_unicode_data("\n".join(rows))["categories"],
                         [[65, 66, "Lu"], [68, 68, "Lu"], [69, 69, "Ll"]])

    def test_sparse_mappings_omit_zero_identity_and_compatibility(self):
        rows = [self.row("0061", lower="0061"),
                self.row("00A0", category="Zs", decomposition="<noBreak> 0020"),
                self.row("0301", category="Mn", ccc="230")]
        table = parse_unicode_data("\n".join(rows))
        self.assertEqual(table["ccc"], [[769, 230]])
        self.assertEqual(table["simpleLower"], [])
        self.assertEqual(table["decomposition"], [])

    def test_preserves_surrogate_category_ranges(self):
        rows = [self.row("D800", "<Surrogate, First>", "Cs"),
                self.row("DFFF", "<Surrogate, Last>", "Cs")]
        self.assertEqual(parse_unicode_data("\n".join(rows))["categories"],
                         [[55296, 57343, "Cs"]])

    def test_rejects_malformed_ranges_and_records(self):
        first = self.row("3400", "<CJK, First>")
        invalid = [
            first,
            self.row("3401", "<CJK, Last>"),
            first + "\n" + self.row("3401", "<Other, Last>"),
            first + "\n" + self.row("3401", "<CJK, Last>", "Lu"),
            first + "\n" + self.row("3401", "<CJK, Last>", ccc="1"),
            first + "\n" + self.row("3401"),
            self.row("0041") + "\n" + self.row("0041"),
            self.row("0042") + "\n" + self.row("0041"),
            self.row("110000"), self.row("0041", category="XX"),
            self.row("0041", ccc="256"), "0041;too;few",
            self.row("0041", decomposition="D800"),
            self.row("0041", lower="D800"),
        ]
        for source in invalid:
            with self.subTest(source=source), self.assertRaises(ValueError):
                parse_unicode_data(source)

    def test_rejects_canonical_decomposition_cycles(self):
        for source in [self.row("0041", decomposition="0041"),
                       self.row("0041", decomposition="0042") + "\n" +
                       self.row("0042", decomposition="0041")]:
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "cycle"):
                parse_unicode_data(source)

    def test_cli_help_from_repository_root(self):
        root = Path(__file__).resolve().parents[3]
        result = subprocess.run([sys.executable, "-B", "tools/unicode/gen_tables.py", "--help"],
                                cwd=root, capture_output=True, text=True, check=True)
        self.assertIn("--ucd-dir", result.stdout)
        self.assertIn("--license-file", result.stdout)
        self.assertIn("--download", result.stdout)
        self.assertIn("--check", result.stdout)


class SupplementalFixtureTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[3]

    def fixture(self, name):
        return json.loads((self.ROOT / "Tests/fixtures" / name).read_bytes())

    def test_schemas_preserve_appendix_and_optional_snapshot_skew_extension(self):
        text = (self.ROOT / "docs/contracts/lang-detector-v1.md").read_text()
        for section, name in [("## 9. JSON Schema: artifact", "artifact"),
                              ("## 10. JSON Schema: training manifest", "manifest")]:
            source = text.split(section, 1)[1].split("```json\n", 1)[1].split("```", 1)[0]
            committed = (self.ROOT / f"tools/lang/schemas/{name}-v1.schema.json").read_bytes()
            self.assertEqual(gen.extract_schemas()[f"{name}-v1.schema.json"], committed)
            schema = json.loads(committed)
            if name == "manifest":
                extension = schema["properties"].pop("snapshotSkew")
                self.assertEqual(extension, {
                    "type": "object", "additionalProperties": False,
                    "required": ["missingFromBase", "cc0DetailMismatch", "excludedIdsSha256", "sampleIds"],
                    "properties": {
                        "missingFromBase": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
                        "cc0DetailMismatch": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
                        "excludedIdsSha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                        "sampleIds": {"type": "array", "items": {
                            "type": "integer", "minimum": 0, "maximum": 9223372036854775807}, "maxItems": 20},
                    },
                })
            self.assertEqual(json.loads(source), schema)

    def test_frozen_fixtures_unchanged(self):
        for name, digest in [("lang-normalize-v1.json", "704197892d77805c4ae3b9fc9ad04752d0187d3ef768e5ae8842baa8860afb4c"),
                             ("lang-score-v1.json", "2ab9a8d0c0b92664f24e7402c80bf051fb09102c8818982db68ed5b658f0fb13")]:
            self.assertEqual(hashlib.sha256((self.ROOT / "Tests/fixtures/contracts" / name).read_bytes()).hexdigest(), digest)

    def test_unicode_fixture_covers_operations_and_source_rows(self):
        fixture = self.fixture("contracts/unicode-tables-v1.json")
        cases = {case["name"]: case for case in fixture["cases"]}
        self.assertEqual({case["operation"] for case in cases.values()}, {"nfc", "fold", "lower", "category"})
        self.assertEqual(cases["simple-lower-not-full-fold"]["expected"], [105, 223, 66600])
        self.assertEqual(cases["full-fold-expands"]["expected"], [105, 775, 115, 115])
        self.assertEqual(cases["categories"]["expected"], ["Cn", "Lo", "Mn", "Nd", "Co"])
        rows = gen.normalization_rows((self.ROOT / "Tests/fixtures/unicode/NormalizationTest-15.1.0.txt").read_bytes())
        pairs = {(tuple(row[i]), tuple(row[1 if i < 3 else 3])) for row in rows for i in range(5)}
        for name in ("hangul", "composition-exclusion", "equal-ccc-blocking", "leading-marks"):
            case = cases[name]
            self.assertIn((tuple(case["input"]), tuple(case["expected"])), pairs)

    def test_artifact_mutations_are_independent_and_raw_representations_exclusive(self):
        cases = self.fixture("contracts/lang-artifact-validation-v1.json")["cases"]
        self.assertGreaterEqual(len(cases), 33)
        for case in cases:
            self.assertEqual(sum(key in case for key in (
                "rawArtifact", "rawBytesBase64", "rawManifestProperties")), 1, case["name"])
            self.assertIs(type(case["valid"]), bool)
        cases = [case for case in cases if "rawManifestProperties" not in case]
        by_name = {case["name"]: case for case in cases}
        model = self.fixture("contracts/lang-score-v1.json")["model"]
        self.assertEqual(json.loads(by_name["unchanged-synthetic"]["rawArtifact"]), model)
        self.assertTrue(by_name["unchanged-synthetic"]["valid"])
        self.assertTrue(all(not case["valid"] for case in cases[1:]))
        for name, value in [("weight-positive", 1), ("weight-too-negative", -1000001)]:
            mutated = json.loads(by_name[name]["rawArtifact"])
            self.assertEqual(mutated["profiles"][0]["orders"][0]["weights"][0], value)
            mutated["profiles"][0]["orders"][0]["weights"][0] = model["profiles"][0]["orders"][0]["weights"][0]
            self.assertEqual(mutated, model)
        self.assertIn('"version":1.0', by_name["fraction-version"]["rawArtifact"])
        self.assertIn('"version":1e0', by_name["exponent-version"]["rawArtifact"])
        self.assertIn('"\\u0076ersion"', by_name["escaped-duplicate-version"]["rawArtifact"])

    def test_artifact_cases_fail_raw_parsing_or_semantic_validation(self):
        import base64
        import bisect
        schema = json.loads((self.ROOT / "tools/lang/schemas/artifact-v1.schema.json").read_bytes())
        table = json.loads((self.ROOT / "Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json").read_bytes())
        ranges = table["categories"]
        starts = [row[0] for row in ranges]

        def category(cp):
            index = bisect.bisect_right(starts, cp) - 1
            return ranges[index][2] if index >= 0 and cp <= ranges[index][1] else "Cn"

        def reject_number(_):
            raise ValueError("Not a decimal integer token")

        def unique_object(pairs):
            obj = {}
            for key, value in pairs:
                if key in obj:
                    raise ValueError("Duplicate decoded key")
                obj[key] = value
            return obj

        def validate(raw):
            if not raw.endswith(b"\n") or raw.startswith(b"\xef\xbb\xbf"):
                raise ValueError("LF/BOM")
            model = json.loads(raw.decode("utf-8"), parse_float=reject_number,
                               parse_constant=reject_number, object_pairs_hook=unique_object)
            validate_schema(model, schema)
            p = model["parameters"]
            if not 0 < p["windowScalars"] <= p["textCapScalars"] <= p["inputCapScalars"] <= 5000000:
                raise ValueError("Cap relationship")
            if model["targets"] != sorted(set(model["targets"])):
                raise ValueError("Target order/uniqueness")
            if [row["order"] for row in model["vocabulary"]] != [1, 2, 3]:
                raise ValueError("Vocabulary order")
            for n, order in enumerate(model["vocabulary"], 1):
                tuples = [tuple(feature) for feature in order["features"]]
                if tuples != sorted(set(tuples)):
                    raise ValueError("Feature order/uniqueness")
                if len(tuples) > len(model["profiles"]) * p["maxFeaturesPerProfile"][n - 1]:
                    raise ValueError("Vocabulary cap")
                for symbols in tuples:
                    if len(symbols) != n:
                        raise ValueError("Feature length")
                    if symbols in ((-1,), (-2,)):
                        continue
                    for i, cp in enumerate(symbols):
                        if cp == -1 and i != 0 or cp == -2 and i != n - 1:
                            raise ValueError("Boundary position")
                        if cp >= 0 and category(cp)[0] not in ("L", "M"):
                            raise ValueError("Feature category")
                    if not any(cp >= 0 for cp in symbols):
                        raise ValueError("Boundary-only tuple")
                    if symbols[0] == -1 and category(symbols[1])[0] != "L":
                        raise ValueError("Detached leading mark")
            if [row["id"] for row in model["profiles"]] != ["background"] + model["targets"]:
                raise ValueError("Profile order")
            prior = {3: -1125, 4: -1420, 5: -1648}[len(model["profiles"])]
            for profile in model["profiles"]:
                if profile["priorWeight"] != prior:
                    raise ValueError("Prior")
                if [row["order"] for row in profile["orders"]] != [1, 2, 3]:
                    raise ValueError("Profile order records")
                if any(len(weights["weights"]) != len(vocab["features"])
                       for weights, vocab in zip(profile["orders"], model["vocabulary"])):
                    raise ValueError("Weight count")
            if [row["start"] for row in model["thresholds"]] != [12, 32, 80, 200]:
                raise ValueError("Threshold order")
            if any(row["enabled"] and row["minMargin"] < 1 for row in model["thresholds"]):
                raise ValueError("Enabled margin")

        for case in self.fixture("contracts/lang-artifact-validation-v1.json")["cases"]:
            if "rawManifestProperties" in case:
                continue
            raw = (case["rawArtifact"].encode("utf-8") if "rawArtifact" in case
                   else base64.b64decode(case["rawBytesBase64"], validate=True))
            with self.subTest(name=case["name"]):
                if case["valid"]:
                    validate(raw)
                else:
                    with self.assertRaises(ValueError):
                        validate(raw)

    def test_snapshot_skew_cases_match_manifest_schema_and_strict_json(self):
        import base64
        schema = json.loads((self.ROOT / "tools/lang/schemas/manifest-v1.schema.json").read_bytes())
        bundle = self.fixture("lang/loading-bundle-v1.json")
        manifest = base64.b64decode(bundle["resources"]["lang-detector-v1.manifest.json"],
                                    validate=True).decode("utf-8")
        cases = [case for case in self.fixture("contracts/lang-artifact-validation-v1.json")["cases"]
                 if "rawManifestProperties" in case]
        self.assertEqual(len(cases), 64)
        self.assertEqual(sum(case["valid"] for case in cases), 5)
        self.assertEqual(len({case["name"] for case in cases}), len(cases))

        def reject_number(_):
            raise ValueError("Not a decimal integer token")

        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("Duplicate decoded key")
                result[key] = value
            return result

        for case in cases:
            properties = case["rawManifestProperties"]
            self.assertTrue(not properties or properties.endswith(","), case["name"])
            raw = "{" + properties + manifest[1:]

            def validate():
                value = json.loads(raw, parse_float=reject_number,
                                   parse_constant=reject_number, object_pairs_hook=unique_object)
                validate_schema(value, schema)

            with self.subTest(name=case["name"]):
                if case["valid"]:
                    validate()
                else:
                    with self.assertRaises(ValueError):
                        validate()

    def test_inheritance_preserves_null_and_only_inherits_short_inputs(self):
        cases = self.fixture("contracts/lang-inheritance-v1.json")["cases"]
        self.assertEqual(len(cases), 16)
        for case in cases:
            i = case["input"]
            inherits = (i["label"] == "und" and i["reason"] in ("minLetters", "minWords")
                        and i["documentLabel"] in ("cs", "de", "en", "sk"))
            self.assertEqual(case["expected"], {
                "lang": i["documentLabel"] if inherits else i["label"], "langInherited": inherits})

    def test_runtime_full_score_trees_threshold_equalities_and_text_cap(self):
        frozen = {case["name"]: case for case in self.fixture("contracts/lang-score-v1.json")["cases"]}
        cases = {case["name"]: case for case in self.fixture("contracts/lang-runtime-v1.json")["cases"]}
        for name in ("equal-winning-score", "equal-margin", "equal-coverage"):
            self.assertEqual(cases[name]["expected"], frozen["accept-xa"]["expected"])
        coverage = dict(frozen["coverage-only"]["expected"], label="xa", reason="accepted")
        self.assertEqual(cases["equal-floored-coverage"]["expected"], coverage)
        a, b = (cases[name]["expected"] for name in ("text-cap-exact", "text-cap-discards-suffix"))
        self.assertEqual(a, b)
        self.assertEqual(a["words"], ["a" * 8190, "a"])
        self.assertEqual(a["letterCount"], 8191)
        self.assertEqual(a["wordCount"], 2)
        self.assertEqual(a["reason"], "minWords")
        self.assertEqual(a["featureCounts"], [8195, 8193, 8191])
        self.assertEqual(a["knownCounts"], [8195, 8193, 8190])
        self.assertEqual(a["coverageBp"], 9999)
        self.assertEqual(a["margin"], 10027)
        self.assertEqual(a["profiles"]["xa"], {
            "weightedSums": [-5593602, -7066586, -8768699],
            "orderScores": [-683, -863, -1071], "combinedScore": -6747})
        self.assertEqual(cases["windows-513"]["expected"], [[0, 256], [257, 513]])
        self.assertEqual(cases["windows-4097"]["expected"][-1], [3585, 4097])
        self.assertEqual(cases["utf16-pair-cap"]["expected"]["stream"], [66600])
        self.assertEqual(cases["utf16-unpaired-adjacent"]["expected"]["stream"], [65533, 65536, 97])
        self.assertEqual(cases["fold-pre-post-cap"]["expected"]["stream"], [115, 115, 115])
        self.assertEqual(cases["dotted-i-text-cap"]["expected"]["scalars"], [105])
        self.assertEqual(cases["dotted-i-document"]["expected"]["scalars"], [105, 775])


class GenerationTests(unittest.TestCase):
    def test_atomic_write_failure_keeps_original_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "resource.json"
            target.write_bytes(b"original\n")
            with patch.object(gen.os, "replace", side_effect=OSError("simulated failure")):
                with self.assertRaisesRegex(OSError, "simulated failure"):
                    gen.atomic_write(target, b"replacement\n")
            self.assertEqual(target.read_bytes(), b"original\n")
            self.assertEqual(list(root.iterdir()), [target])

    def test_offline_import_never_imports_acquisition(self):
        root = Path(__file__).resolve().parents[3]
        script = """
import builtins
import pathlib
original = builtins.__import__
def offline(name, *args, **kwargs):
    if name.split('.')[0] in ('urllib', 'socket', 'http'):
        raise AssertionError('offline path imported acquisition: ' + name)
    return original(name, *args, **kwargs)
builtins.__import__ = offline
from tools.unicode import gen_tables as gen
root = pathlib.Path.cwd()
gen.supplemental_fixtures()
gen.extract_schemas()
"""
        subprocess.run([sys.executable, "-B", "-c", script], cwd=root,
                       capture_output=True, text=True, check=True)

    def test_casefold_uses_only_common_and_full_rows(self):
        self.assertEqual(gen.parse_case_folding(
            "0041; C; 0061; # A\n0130; F; 0069 0307;\n"
            "0130; T; 0069;\n1E9E; S; 00DF;\n1E9E; F; 0073 0073;\n"),
            [[65, [97]], [304, [105, 775]], [7838, [115, 115]]])

    def test_casefold_rejects_duplicate_and_invalid_mappings(self):
        for source in ["0041; C; 0061;\n0041; F; 0061;",
                       "0041; C; 0061;\n0041; C; 0062;",
                       "D800; C; 0061;", "0041; F; D800;",
                       "0041; F; ;", "0041; X; 0061;"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                gen.parse_case_folding(source)

    def test_full_exclusions_expand_ranges_and_ignore_other_properties(self):
        self.assertEqual(gen.parse_composition_exclusions(
            "0340..0341; Full_Composition_Exclusion # two\n"
            "0344; Full_Composition_Exclusion\n0041; NFC_QC; Y\n"),
            [832, 833, 836])
        for source in ["0344..0340; Full_Composition_Exclusion",
                       "0344; Full_Composition_Exclusion\n0344; Full_Composition_Exclusion",
                       "D800; Full_Composition_Exclusion"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                gen.parse_composition_exclusions(source)

    def test_generation_rejects_lost_changed_or_extra_casefold_mappings(self):
        for mappings in ([], [[65, [98]]], [[65, [97]], [66, [98]]]):
            with self.subTest(mappings=mappings), patch.object(
                    gen, "parse_case_folding", return_value=mappings):
                with self.assertRaisesRegex(ValueError, "CaseFolding.*reconstruction"):
                    gen.build_unicode_outputs(self.inputs(), b"test license\n")

    def test_generation_rejects_lost_or_extra_composition_exclusions(self):
        for exclusions in ([], [832, 836]):
            with self.subTest(exclusions=exclusions), patch.object(
                    gen, "parse_composition_exclusions", return_value=exclusions):
                with self.assertRaisesRegex(ValueError, "Full_Composition_Exclusion.*reconstruction"):
                    gen.build_unicode_outputs(self.inputs(), b"test license\n")

    @staticmethod
    def inputs():
        row = GeneratorTests.row
        return {
            "UnicodeData.txt": ("\n".join([
                row("0041", category="Lu", lower="0061"), row("0061", category="Ll"),
                row("00E0", category="Ll", decomposition="0061 0300"),
                row("0300", category="Mn", ccc="230"),
                row("0301", category="Mn", ccc="230"),
                row("0308", category="Mn", ccc="230"),
                row("0344", category="Mn", ccc="230", decomposition="0308 0301"),
            ]) + "\n").encode(),
            "CaseFolding.txt": b"0041; C; 0061;\n",
            "DerivedNormalizationProps.txt": b"0344; Full_Composition_Exclusion\n",
            "NormalizationTest.txt": b"# exact bytes\n@Part0 # test\n00E0;00E0;0061 0300;00E0;0061 0300;\n",
        }

    def test_generation_reproduces_committed_language_fixtures_byte_for_byte(self):
        # Small pinned UCD inputs keep this regression offline and independent
        # of an external acquisition cache; detector cases use the frozen model.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ucd = root / "ucd"
            ucd.mkdir()
            inputs = self.inputs()
            for name, data in inputs.items():
                (ucd / name).write_bytes(data)
            license_data = b"Invented license for unit test.\n"
            (ucd / "license.txt").write_bytes(license_data)
            pins = {name: hashlib.sha256(data).hexdigest() for name, data in inputs.items()}
            with patch.dict(gen.PINNED_SHA256, pins), patch.object(
                    gen, "LICENSE_SHA256", hashlib.sha256(license_data).hexdigest()):
                gen.generate(ucd, root / "resources", root / "fixtures",
                             schema_dir=root / "schemas")
            contracts = gen.ROOT / "Tests/fixtures/contracts"
            # These two WP0 inputs are frozen sources, not generator outputs.
            frozen = {"lang-normalize-v1.json", "lang-score-v1.json"}
            for committed in sorted(contracts.glob("lang-*.json")):
                if committed.name in frozen:
                    continue
                with self.subTest(fixture=committed.name):
                    generated = root / "fixtures/contracts" / committed.name
                    self.assertTrue(generated.is_file(), f"Missing generated {committed.name}")
                    self.assertTrue(generated.read_bytes() == committed.read_bytes(),
                                    f"Generated bytes differ: {committed.name}")

    def test_regression_merge_rejects_duplicate_case_names(self):
        fixture = "contracts/lang-artifact-validation-v1.json"
        duplicate = gen.envelope("lang-artifact-validation", [
            {"name": "schema-key-kelvin-sign", "rawArtifact": "{}\n", "valid": True}])
        with self.assertRaisesRegex(ValueError, "Duplicate.*schema-key-kelvin-sign"):
            gen.merge_regression_fixtures({fixture: duplicate})

    def test_generation_is_deterministic_pins_license_and_check_never_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ucd = root / "ucd"
            ucd.mkdir()
            inputs = self.inputs()
            for name, data in inputs.items():
                (ucd / name).write_bytes(data)
            license_file = root / "approved-license.txt"
            license_file.write_bytes(b"Invented license for unit test.\n")
            pins = {name: hashlib.sha256(data).hexdigest() for name, data in inputs.items()}
            with patch.dict(gen.PINNED_SHA256, pins), patch.object(
                    gen, "LICENSE_SHA256", hashlib.sha256(license_file.read_bytes()).hexdigest()):
                for run in ("a", "b"):
                    gen.generate(ucd, root / run / "resources", root / run / "fixtures",
                                 license_file=license_file, schema_dir=root / run / "schemas")
                def snapshot(run):
                    return {p.relative_to(root / run): p.read_bytes()
                            for p in (root / run).rglob("*") if p.is_file()}
                a = snapshot("a")
                self.assertEqual(a, snapshot("b"))
                table_bytes = a[Path("resources/unicode-15.1.0.json")]
                table = json.loads(table_bytes)
                self.assertEqual(table["composition"], [[97, 768, 224]])
                self.assertEqual(table["compositionExclusions"], [836])
                self.assertEqual(table["caseFold"], [[65, [97]]])
                self.assertEqual(list(table), ["format", "unicodeVersion", "normalizationTablesVersion",
                    "categories", "ccc", "decomposition", "compositionExclusions", "composition",
                    "caseFold", "simpleLower"])
                self.assertTrue(table_bytes.endswith(b"\n"))
                self.assertNotIn(b" ", table_bytes)
                digest = hashlib.sha256(table_bytes).hexdigest()
                self.assertEqual(a[Path("resources/unicode-15.1.0.json.sha256")], (digest + "\n").encode())
                manifest = json.loads(a[Path("resources/unicode-sources-v1.json")])
                self.assertEqual(manifest["tableSha256"], digest)
                self.assertEqual(manifest["normalizationRows"], 1)
                self.assertEqual(manifest["license"], {
                    "url": "https://www.unicode.org/license.txt",
                    "sha256": hashlib.sha256(license_file.read_bytes()).hexdigest(),
                    "retrievedAt": "2026-10-09", "licenseId": "Unicode-3.0"})
                self.assertEqual(a[Path("fixtures/unicode/NormalizationTest-15.1.0.txt")],
                                 inputs["NormalizationTest.txt"])
                before = {p: p.stat().st_mtime_ns for p in (root / "a").rglob("*")}
                gen.generate(ucd, root / "a/resources", root / "a/fixtures",
                             license_file=license_file, schema_dir=root / "a/schemas", check=True)
                self.assertEqual(before, {p: p.stat().st_mtime_ns for p in (root / "a").rglob("*")})
                target = root / "a/resources/unicode-15.1.0.json"
                target.write_bytes(b"changed\n")
                with self.assertRaisesRegex(ValueError, "mismatch.*unicode-15.1.0.json"):
                    gen.generate(ucd, root / "a/resources", root / "a/fixtures",
                                 license_file=license_file, schema_dir=root / "a/schemas", check=True)
                self.assertEqual(target.read_bytes(), b"changed\n")

    def test_bad_input_or_license_fails_before_any_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, data in self.inputs().items():
                (root / name).write_bytes(data)
            (root / "license.txt").write_bytes(b"wrong\n")
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                gen.generate(root, root / "out", root / "fixtures")
            self.assertFalse((root / "out").exists())
            pins = {name: hashlib.sha256(data).hexdigest() for name, data in self.inputs().items()}
            with patch.dict(gen.PINNED_SHA256, pins), self.assertRaisesRegex(ValueError, "SHA-256.*license"):
                gen.generate(root, root / "out", root / "fixtures")
            self.assertFalse((root / "out").exists())

    def test_archive_rejects_unsafe_members_before_extraction(self):
        for name, mode in [("../outside", 0o100644), ("/absolute", 0o100644),
                           ("a/../../outside", 0o100644), ("a\\outside", 0o100644),
                           ("link", 0o120777), ("pipe", 0o010644)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                raw = io.BytesIO()
                with zipfile.ZipFile(raw, "w") as archive:
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = mode << 16
                    archive.writestr(info, b"bad")
                data = raw.getvalue()
                with patch.dict(gen.PINNED_SHA256, {"UCD.zip": hashlib.sha256(data).hexdigest()}):
                    with self.assertRaisesRegex(ValueError, "Unsafe archive"):
                        gen.extract_archive(data, Path(directory) / "ucd")
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_archive_checks_hash_and_only_writes_named_verified_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                gen.extract_archive(b"wrong", root / "wrong")
            raw = io.BytesIO()
            inputs = self.inputs()
            with zipfile.ZipFile(raw, "w") as archive:
                for name, data in inputs.items():
                    archive.writestr(name, data)
                archive.writestr("unused.txt", b"not extracted")
            data = raw.getvalue()
            pins = {name: hashlib.sha256(value).hexdigest() for name, value in inputs.items()}
            pins["UCD.zip"] = hashlib.sha256(data).hexdigest()
            with patch.dict(gen.PINNED_SHA256, pins):
                gen.extract_archive(data, root / "ucd")
                self.assertEqual({p.name for p in (root / "ucd").iterdir()}, set(inputs) | {"UCD.zip"})
                for name, expected in inputs.items():
                    self.assertEqual((root / "ucd" / name).read_bytes(), expected)


def validate_schema(value, schema, root=None):
    """Small independent validator for the exact appendix schema vocabulary."""
    import re
    root = schema if root is None else root
    if "$ref" in schema:
        target = root
        for component in schema["$ref"].split("/")[1:]:
            target = target[component]
        return validate_schema(value, target, root)
    if "anyOf" in schema:
        for candidate in schema["anyOf"]:
            try:
                validate_schema(value, candidate, root)
                break
            except ValueError:
                continue
        else:
            raise ValueError("No anyOf branch matched")
    # bool is a subclass of int in Python; equality alone is not sufficient.
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        raise ValueError("Wrong constant")
    if "enum" in schema and not any(type(value) is type(item) and value == item for item in schema["enum"]):
        raise ValueError("Wrong enum")
    kinds = {"object": dict, "array": list, "string": str, "integer": int, "null": type(None)}
    if "type" in schema and type(value) is not kinds[schema["type"]]:
        raise ValueError("Wrong type")
    if isinstance(value, dict):
        if not set(schema.get("required", ())) <= value.keys():
            raise ValueError("Missing property")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False and not value.keys() <= properties.keys():
            raise ValueError("Unknown property")
        for key, item in value.items():
            if key in properties:
                validate_schema(item, properties[key], root)
    elif isinstance(value, list):
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", sys.maxsize):
            raise ValueError("Array size")
        for item in value:
            if "items" in schema:
                validate_schema(item, schema["items"], root)
    elif isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            raise ValueError("String length")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            raise ValueError("String pattern")
    elif type(value) is int:
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            raise ValueError("Integer range")


class LoadingFixtureTests(unittest.TestCase):
    @staticmethod
    def bundle():
        import base64
        outputs = gen.build_loading_fixtures()
        envelope = json.loads(outputs["lang/loading-bundle-v1.json"])
        resources = {name: base64.b64decode(data, validate=True)
                     for name, data in envelope["resources"].items()}
        return outputs, envelope, resources

    def test_bundle_is_deterministic_and_has_only_test_resource_bytes(self):
        outputs, envelope, resources = self.bundle()
        self.assertEqual(outputs, gen.build_loading_fixtures())
        self.assertEqual(set(outputs), {"lang/loading-bundle-v1.json", "contracts/lang-loading-v1.json"})
        self.assertEqual(envelope["contract"], "lang-loading-bundle")
        self.assertEqual(envelope["version"], 1)
        self.assertEqual(envelope["testOnly"], 1)
        self.assertEqual(set(resources), {"lang-detector-v1.json", "lang-detector-v1.manifest.json",
                                         "NOTICE", "ATTRIBUTION.md"})
        self.assertEqual(envelope["sharedUnicodeResources"], ["unicode-15.1.0.json",
                         "unicode-15.1.0.json.sha256", "unicode-sources-v1.json", "UNICODE-LICENSE.txt"])
        for data in [*outputs.values(), *resources.values()]:
            self.assertTrue(data.endswith(b"\n"))
            self.assertFalse(data.startswith(b"\xef\xbb\xbf"))
        notice = b"Wholly invented WP4 loader fixture; not for distribution as a model.\n"
        self.assertEqual(resources["NOTICE"], notice)
        self.assertEqual(resources["ATTRIBUTION.md"], notice)

    def test_bundle_artifact_and_manifest_match_appendix_schemas(self):
        import re
        _, _, resources = self.bundle()
        appendix = (gen.ROOT / "docs/contracts/lang-detector-v1.md").read_text()
        schemas = [json.loads(block) for block in re.findall(r"```json\n(.*?)\n```", appendix, re.S)]
        self.assertEqual(len(schemas), 2)
        for name, schema in zip(("lang-detector-v1.json", "lang-detector-v1.manifest.json"), schemas):
            validate_schema(json.loads(resources[name]), schema)

    def test_bundle_production_shape_integrity_and_unicode_pins(self):
        from datetime import date, datetime
        _, _, resources = self.bundle()
        artifact = json.loads(resources["lang-detector-v1.json"])
        manifest = json.loads(resources["lang-detector-v1.manifest.json"])
        self.assertEqual(artifact["modelId"], "wp4-loader-test-only")
        self.assertEqual(manifest["modelId"], artifact["modelId"])
        self.assertEqual(artifact["kind"], "production")
        self.assertEqual(artifact["targets"], ["cs", "de", "en", "sk"])
        self.assertEqual(artifact["parameters"], {"maxFeaturesPerProfile": [256, 1024, 4096],
            "orderWeights": [1, 2, 3], "scoreScale": 1024, "lengthBucketStarts": [12, 32, 80, 200],
            "minLetters": 12, "minWords": 3, "mixedDominanceBp": 7000,
            "inputCapScalars": 5000000, "textCapScalars": 8192, "windowCount": 8, "windowScalars": 512})
        self.assertEqual(artifact["vocabulary"], [{"order": order, "features": []} for order in (1, 2, 3)])
        self.assertEqual([p["id"] for p in artifact["profiles"]], ["background", "cs", "de", "en", "sk"])
        for profile in artifact["profiles"]:
            self.assertEqual(profile["priorWeight"], -1648)
            self.assertEqual(profile["orders"], [{"order": n, "weights": [], "unknownWeight": 0} for n in (1, 2, 3)])
        self.assertEqual(manifest["artifactPath"], "Sources/AINotebookCore/Resources/Language/lang-detector-v1.json")
        self.assertEqual(manifest["artifactSha256"], hashlib.sha256(resources["lang-detector-v1.json"]).hexdigest())
        attribution = artifact["attribution"]
        self.assertEqual(attribution, manifest["attribution"])
        self.assertEqual(attribution["sourceIds"], ["wp4-loader-test-only"])
        # The trainer always attributes the redistributed Unicode tables too.
        self.assertEqual(attribution["licenseIds"], ["LicenseRef-WP4-Test-Only", "Unicode-3.0"])
        self.assertEqual(attribution["attributionPath"], "tools/lang/ATTRIBUTION.md")
        self.assertEqual(attribution["noticePath"], "NOTICE")
        for prefix, name in [("notice", "NOTICE"), ("attribution", "ATTRIBUTION.md")]:
            self.assertEqual(attribution[prefix + "Sha256"], hashlib.sha256(resources[name]).hexdigest())
        env = manifest["environment"]
        self.assertEqual(env["exporterGitCommit"], "0" * 40)
        self.assertEqual(env["normalizationTablesVersion"], gen.NORMALIZATION_VERSION)
        self.assertEqual({f["url"]: f["sha256"] for f in env["unicodeFiles"]},
                         {gen.UCD_URL + name: gen.PINNED_SHA256[name] for name in gen.UCD_FILES})
        self.assertEqual(len(env["unicodeFiles"]), 4)
        datetime.strptime(manifest["createdAt"], "%Y-%m-%dT%H:%M:%SZ")
        for corpus in manifest["corpus"]:
            self.assertEqual(corpus["id"], "wp4-loader-test-only")
            self.assertEqual(corpus["originalRecords"], 0)
            self.assertEqual(set(corpus["licenseIds"]) | {"Unicode-3.0"}, set(attribution["licenseIds"]))
            self.assertNotIn("Unicode-3.0", corpus["licenseIds"])
            for row in corpus["files"]:
                self.assertEqual(row["records"], 0)
                self.assertEqual(row["url"], "https://example.invalid/wp4-loader-test-only")
                self.assertEqual(row["sha256"], hashlib.sha256(b"").hexdigest())
                date.fromisoformat(row["snapshotDate"])
        for row in env["unicodeFiles"]:
            date.fromisoformat(row["snapshotDate"])

    def test_manifest_completes_all_zero_record_products_and_disabled_buckets(self):
        import itertools
        _, _, resources = self.bundle()
        artifact = json.loads(resources["lang-detector-v1.json"])
        m = json.loads(resources["lang-detector-v1.manifest.json"])
        languages = ["cs", "de", "en", "fr", "hr", "hu", "nl", "pl", "sk", "sl"]
        buckets = [0, 12, 32, 80, 200]
        self.assertEqual(m["negativeLanguages"], ["fr", "hr", "hu", "nl", "pl", "sl"])
        self.assertEqual(sorted(row["detectorLanguage"] for row in m["corpus"][0]["languageMappings"]), languages)
        self.assertEqual(len({row["sourceLanguage"] for row in m["corpus"][0]["languageMappings"]}), 10)
        self.assertEqual(sum(m["split"]["splitBp"].values()), 10000)
        self.assertEqual(m["split"]["oversizedComponents"], [])
        for field, keys, products, zero_fields in [
            ("caps", ["language", "split"], [languages, ["train", "validation", "test"]], ["maxOriginalRecords"]),
            ("counts", ["language", "split", "bucketStart"], [languages, ["train", "validation", "test"], buckets], ["originals", "augmented", "originalGroups"]),
            ("support", ["language", "split", "bucketStart"], [languages, ["validation", "test"], buckets[1:]], ["originalGroups", "evaluated", "accepted"]),
            ("metrics", ["language", "split", "bucketStart", "name"], [languages + ["all"], ["validation", "test"], buckets,
             ["acceptedError", "csSkConfusion", "foreignAcceptance", "acceptanceCoverage"]], ["numerator", "denominator"]),
        ]:
            expected = set(itertools.product(*products))
            actual = [tuple(row[key] for key in keys) for row in m[field]]
            self.assertEqual(set(actual), expected, field)
            self.assertEqual(len(actual), len(expected), field)
            for row in m[field]:
                for key in zero_fields:
                    self.assertEqual(row[key], 0)
                if field == "metrics":
                    self.assertIsNone(row["rateBp"])
        self.assertEqual(m["augmentation"], [{"algorithm": "none-v1", "splits": ["train", "validation", "test"],
                                            "lengths": [], "inputCount": 0, "outputCount": 0}])
        self.assertEqual(m["exclusions"], [])
        self.assertEqual(m["documentMetrics"], [])
        self.assertEqual(m["calibration"]["disabledBuckets"],
                         [{"bucketStart": b, "reason": "insufficientSupport"} for b in buckets[1:]])
        self.assertEqual(artifact["thresholds"], [{"start": b, "enabled": 0, "minWinningScore": -120000,
                         "minMargin": 1, "minKnownCoverageBp": 0} for b in buckets[1:]])
        for b, row in zip(buckets[1:], m["calibration"]["candidates"]):
            self.assertEqual(row, {"bucketStart": b, "minWinningScores": [-120000],
                                  "minMargins": [1], "minKnownCoverageBp": [0]})

    def test_loading_mutations_cover_all_required_failure_boundaries(self):
        outputs, _, resources = self.bundle()
        fixture = json.loads(outputs["contracts/lang-loading-v1.json"])
        self.assertEqual(fixture["contract"], "lang-loading")
        self.assertEqual(fixture["version"], 1)
        cases = fixture["cases"]
        self.assertEqual(len({c["name"] for c in cases}), len(cases))
        self.assertEqual([c["operation"] for c in cases if c["expected"]["isAvailable"]], ["unchanged"])
        for case in cases:
            self.assertEqual(set(case), {"name", "operation", "input", "expected"})
            self.assertIs(type(case["expected"]["isAvailable"]), bool)
        removed = {c["input"]["resource"] for c in cases if c["operation"] == "removeResource"}
        self.assertTrue(set(resources) | {"unicode-15.1.0.json", "unicode-15.1.0.json.sha256"} <= removed)
        flipped = {c["input"]["resource"] for c in cases if c["operation"] == "flipByte"}
        self.assertTrue({"lang-detector-v1.json", "unicode-15.1.0.json", "NOTICE", "ATTRIBUTION.md"} <= flipped)
        mutations = {c["input"]["pointer"]: c["input"]["value"] for c in cases if c["operation"] == "setManifestValue"}
        self.assertTrue({"/modelId", "/environment/normalizationTablesVersion", "/attribution/attributionSha256",
                         "/attribution/attributionPath", "/createdAt", "/counts/1", "/support/1"} <= mutations.keys())
        self.assertTrue({f"/environment/unicodeFiles/{i}/sha256" for i in range(4)} <= mutations.keys())
        self.assertTrue({"replaceArtifactWithSynthetic", "addUnknownManifestKey", "duplicateManifestKey"}
                        <= {c["operation"] for c in cases})
        manifest = json.loads(resources["lang-detector-v1.manifest.json"])
        without_unicode = {c["name"]: c for c in cases}["attribution-without-unicode-license"]
        self.assertEqual(without_unicode["operation"], "setResourceValues")
        self.assertIs(without_unicode["input"]["refreshArtifactDigest"], True)
        self.assertEqual(without_unicode["expected"], {"isAvailable": False})
        self.assertEqual([(c["resource"], c["pointer"], c["value"]) for c in without_unicode["input"]["changes"]],
                         [(name, "/attribution/licenseIds", ["LicenseRef-WP4-Test-Only"])
                          for name in ("lang-detector-v1.json", "lang-detector-v1.manifest.json")])
        self.assertEqual(mutations["/counts/1"], manifest["counts"][0])
        self.assertEqual(mutations["/support/1"], manifest["support"][0])
