"""Independent format, oracle and determinism checks for WP6 shared fixtures."""

import copy
import io
import json
import re
import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

from tools.contracts.gen_ingestion_fixtures import (
    generate,
    make_contracts,
    validate_contracts,
    write_assets,
)


ASSETS = {
    "ingestion/paragraphs.docx", "ingestion/slides.pptx",
    "ingestion/workbook.xlsx", "ingestion/pages.pdf", "ingestion/corrupt.docx",
    "ingestion/external.xlsx", "ingestion/bad-index.xlsx", "ingestion/document2.docx",
}
CONTRACT_NAMES = {
    f"ingestion-{name}-v1.json" for name in (
        "encoding", "canonical", "office", "scan", "jobs", "pipeline",
        "generations", "coverage", "ui", "ooxml")
}
REQUIRED_CASES = {
    "encoding": {"utf8-bom", "utf16le", "utf16be", "plain-utf8", "cp1250",
        "cp1250-disabled", "bad-bom-utf8", "odd-utf16", "unpaired-utf16",
        "bad-utf8-cp1250", "undefined-cp1250", "empty"},
    "canonical": {"scalar-trim", "pdf-empty-middle", "docx", "pptx",
        "window-cross-page", "long-word", "chunk-limit"},
    "office": {"workbook-order", "paragraphs", "slides", "formula-no-cache"},
    "scan": {"fast-path", "same-hash", "verify-all", "changed", "partial-sibling",
        "cancelled", "late-old-generation", "root-offline", "unexpected-error"},
    "jobs": {"two-claims", "restart-expiry", "renew-60", "stale-fail", "stale-publish",
        "token-unique", "exhausted-user-retry", "concurrency-two", "memory-one",
        "chat-two-tokens", "chat-query-unblocked", "cancel-releases", "debounce",
        "max-coalesce", "signal-during-scan"},
    "pipeline": {"publish-short", "detector-unavailable", "inherit-short", "stat-changed",
        "hash-changed-same-stat", "new-observation-before-commit", "expired-owner",
        "replaced-owner", "metadata-and-embed-atomic"},
    "generations": {"new-generation", "copy-identical", "different-model-no-copy",
        "ingest-during-build", "stale-batch", "lease-lost-batch", "chat-pause-between-batches",
        "activate-atomic", "failed-build-keeps-active", "discard-keeps-active",
        "restart-resumes", "selected-provider-changed", "lexical-only", "scope-revocation",
        "periodic-1800", "watch-disabled-startup", "unknown-dimensions-bootstrap",
        "empty-bootstrap", "endpoint-changed-between-batches", "fifth-embed-failure",
        "bootstrap-stale-fence"},
    "coverage": {"first-pending", "first-error", "published-current",
        "published-refresh-pending", "published-refresh-error", "newly-published",
        "observed-not-extracted"},
}


class IngestionFixtureTests(unittest.TestCase):
    def case(self, contracts, group, name):
        return next(case for case in contracts[f"ingestion-{group}-v1.json"]["cases"]
                    if case["name"] == name)

    def test_successful_pipeline_job_targets_the_committed_revision(self):
        for case in make_contracts()["ingestion-pipeline-v1.json"]["cases"]:
            if case["operation"] != "pipeline":
                continue
            final = case["expected"]
            if final["result"].get("accepted"):
                with self.subTest(case=case["name"]):
                    job = next(j for j in final["state"]["jobs"] if j["id"] == 3001)
                    self.assertEqual(job["state"], "done")
                    self.assertEqual(job["targetRevision"], final["result"]["revisionId"])

    def test_deterministic_and_coverage_failure_keeps_old_evidence(self):
        contracts = make_contracts()
        old = self.case(contracts, "coverage", "published-refresh-error")
        self.assertEqual(old["expected"], dict(searchable=1, notSearchable=0,
            current=0, refreshPending=0, refreshError=1, skipped=0,
            missing=0, unavailable=0, isLowerBound=False))
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            generate(Path(a))
            generate(Path(b))
            first = {p.relative_to(a): p.read_bytes() for p in Path(a).rglob("*")
                     if p.is_file()}
            second = {p.relative_to(b): p.read_bytes() for p in Path(b).rglob("*")
                      if p.is_file()}
            self.assertEqual(first, second)
            self.assertEqual(set(map(str, first)),
                             {f"contracts/{name}" for name in CONTRACT_NAMES} | ASSETS)
        for value in contracts.values():
            names = [case["name"] for case in value["cases"]]
            self.assertEqual(len(names), len(set(names)))

    def test_rejects_invalid_scalar_spans(self):
        for update in ({"start": -1}, {"start": 7}, {"end": 10},
                       {"start": 2.0}, {"end": True}, {"text": "wrong"}):
            with self.subTest(update=update):
                contracts = make_contracts()
                chunk = self.case(contracts, "canonical", "scalar-trim")["expected"]["chunks"][0]
                chunk.update(update)
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_rejects_unknown_trace_operations(self):
        contracts = make_contracts()
        events = next(case["input"]["events"]
                      for contract in contracts.values() for case in contract["cases"]
                      if case["input"].get("events"))
        events[0]["operation"] = "unexpected-fixture-operation"
        with self.assertRaises(ValueError):
            validate_contracts(contracts, ASSETS)

    def test_rejects_unreferenced_assets(self):
        with self.assertRaises(ValueError):
            validate_contracts(make_contracts(), ASSETS | {"ingestion/unreferenced.docx"})

    def test_required_envelopes_and_named_boundary_cases(self):
        contracts = make_contracts()
        self.assertEqual(set(contracts), CONTRACT_NAMES)
        validate_contracts(contracts, ASSETS)
        for filename, contract in contracts.items():
            with self.subTest(contract=filename):
                self.assertEqual(contract["contract"], filename.removesuffix("-v1.json"))
                self.assertEqual(contract["version"], 1)
                self.assertTrue(contract["cases"])
                for case in contract["cases"]:
                    self.assertEqual(set(case), {"name", "operation", "input", "expected"})
                    self.assertIsInstance(case["input"], dict)
                    self.assertIsInstance(case["expected"], dict)
                    self.assertTrue(case["expected"], case["name"])
        for group, names in REQUIRED_CASES.items():
            actual = {case["name"] for case in contracts[f"ingestion-{group}-v1.json"]["cases"]}
            self.assertFalse(names - actual, f"Missing {group} cases: {sorted(names - actual)}")

    def test_encoding_oracles_preserve_scalars_and_reject_bom_fallback(self):
        contracts = make_contracts()
        successful = {
            "utf8-bom": ("A\n", "utf-8-bom", [239, 187, 191, 65, 10]),
            "utf16le": ("A😀", "utf-16le", [255, 254, 65, 0, 61, 216, 0, 222]),
            "utf16be": ("A😀", "utf-16be", [254, 255, 0, 65, 216, 61, 222, 0]),
            "plain-utf8": ("  Čau\r\n", "utf-8", list("  Čau\r\n".encode("utf-8"))),
            "cp1250": ("Příliš", "windows-1250", [80, 248, 237, 108, 105, 154]),
            "bad-utf8-cp1250": ("Ă(", "windows-1250", [195, 40]),
        }
        for name, (text, encoding, data) in successful.items():
            with self.subTest(case=name):
                case = self.case(contracts, "encoding", name)
                self.assertEqual(case["input"]["bytes"], data)
                self.assertEqual(case["expected"], {"text": text, "encoding": encoding})
        for name in ("cp1250-disabled", "bad-bom-utf8", "odd-utf16",
                     "unpaired-utf16", "undefined-cp1250"):
            with self.subTest(case=name):
                self.assertEqual(self.case(contracts, "encoding", name)["expected"],
                                 {"error": "unsupportedEncoding"})
        self.assertEqual(self.case(contracts, "encoding", "empty")["expected"]["text"], "")

    def test_canonical_scalar_and_page_oracles(self):
        contracts = make_contracts()
        scalar = self.case(contracts, "canonical", "scalar-trim")["expected"]
        self.assertEqual(scalar["text"], "  A😀éZ  ")
        self.assertEqual(scalar["chunks"], [{"text": "A😀éZ", "start": 2, "end": 7, "tokens": 2}])
        pdf = self.case(contracts, "canonical", "pdf-empty-middle")["expected"]
        self.assertEqual(pdf["text"], "A😀\n\n\n\néZ")
        self.assertEqual(pdf["pages"], [
            {"page": 1, "start": 0, "end": 2},
            {"page": 2, "start": 4, "end": 4},
            {"page": 3, "start": 6, "end": 9},
        ])
        self.assertEqual(pdf["chunks"], [{"text": pdf["text"], "start": 0, "end": 9,
                                         "tokens": 3, "pageFrom": 1, "pageTo": 3}])
        self.assertEqual(self.case(contracts, "canonical", "docx")["expected"]["text"], "A\nB😀\n")
        self.assertEqual(self.case(contracts, "canonical", "pptx")["expected"]["text"],
                         "## Slide 1\nA\n\n## Slide 2\nB")
        chunks = self.case(contracts, "canonical", "long-word")["expected"]["chunks"]
        self.assertEqual([(chunk["start"], chunk["end"], chunk["tokens"]) for chunk in chunks],
                         [(0, 2048, 512), (1792, 3840, 512), (3584, 4097, 129)])
        self.assertEqual(self.case(contracts, "canonical", "chunk-limit")["expected"],
                         {"error": "chunkLimit"})
        cross = self.case(contracts, "canonical", "window-cross-page")["expected"]
        self.assertEqual([(page["start"], page["end"]) for page in cross["pages"]],
                         [(0, 2050), (2052, 2082)])
        self.assertTrue(any(chunk["pageFrom"] == 1 and chunk["pageTo"] == 2
                            for chunk in cross["chunks"]))

    def test_literal_two_dimensional_coverage_decision_table(self):
        contracts = make_contracts()
        rows = {
            "first-pending": ("pending", None, None, None, (0, 1, 0, 1, 0)),
            "first-error": ("error", None, None, None, (0, 1, 0, 0, 1)),
            "published-current": ("ready", 1, 1, 1, (1, 0, 1, 0, 0)),
            "published-refresh-pending": ("chunking", 2, 1, 1, (1, 0, 0, 1, 0)),
            "published-refresh-error": ("error", 2, 1, 1, (1, 0, 0, 0, 1)),
            "newly-published": ("ready", 2, 2, 1, (1, 0, 1, 0, 0)),
            "observed-not-extracted": ("pending", 1, 1, 1, (1, 0, 0, 1, 0)),
        }
        columns = ("searchable", "notSearchable", "current", "refreshPending", "refreshError")
        for name, (status, current, published, vector, values) in rows.items():
            with self.subTest(case=name):
                case = self.case(contracts, "coverage", name)
                self.assertEqual({key: case["input"][key] for key in
                    ("status", "currentRevision", "publishedRevisionId", "activeVectorRevision")},
                    dict(status=status, currentRevision=current, publishedRevisionId=published,
                         activeVectorRevision=vector))
                expected = dict(zip(columns, values))
                expected.update(skipped=0, missing=0, unavailable=0, isLowerBound=False)
                self.assertEqual(case["expected"], expected)
        cases = contracts["ingestion-coverage-v1.json"]["cases"]
        self.assertTrue(any(case["input"].get("publishedRevisionId") == 2
                            and case["input"].get("activeVectorRevision", "absent") is None
                            and case["expected"]["current"] == 1 for case in cases))

    def test_eligible_scan_items_count_before_ingestion_and_only_once_after(self):
        contracts = make_contracts()
        for name, source_id, published, counts in (
            ("source-less-eligible", None, None, (0, 1, 0, 1)),
            ("eligible-source-inventory-dedup", 101, 1, (1, 0, 1, 0)),
        ):
            with self.subTest(case=name):
                case = self.case(contracts, "coverage", name)
                data = case["input"]
                self.assertEqual(data["sourceId"], source_id)
                self.assertEqual(data["publishedRevisionId"], published)
                self.assertEqual(data["availability"], "present")
                self.assertTrue(data["eligible"])
                self.assertTrue(data["hasScanItem"])
                self.assertEqual(data["scanKind"], "eligible")
                expected = dict(zip(
                    ("searchable", "notSearchable", "current", "refreshPending"), counts))
                expected.update(refreshError=0, skipped=0, missing=0,
                                unavailable=0, isLowerBound=False)
                self.assertEqual(case["expected"], expected)

    def test_partial_sibling_completion_does_not_hide_missing_root_files(self):
        case = self.case(make_contracts(), "scan", "partial-sibling")
        self.assertEqual(case["operation"], "walk")
        self.assertEqual(case["input"]["listErrors"], {"bad": "permissionDenied"})
        self.assertEqual(case["input"]["root"], dict(id=1, notebookId=1, rootPath="/docs",
            displayName="Docs", volumeId="test", components=["docs"], rootFileId="root-1"))
        self.assertEqual(case["expected"], {
            "completion": {"completed": ["good"], "incomplete": ["bad", ""], "rootUnavailable": False},
            "listCalls": ["", "bad", "good"], "missingSourceIds": [101]})
        for entries in case["input"]["directories"].values():
            for entry in entries:
                self.assertIn(entry["relPath"], case["input"]["stats"])

    def test_duplicate_scans_really_scan_twice_and_coalesce_one_extract_job(self):
        case = self.case(make_contracts(), "scan", "duplicate-scans-coalesce")
        beginnings = [event for event in case["input"]["events"]
                      if event["operation"] == "list" and event.get("beginScan")]
        self.assertEqual(len(beginnings), 2)
        generations = [event["expected"]["folder"]["scanGeneration"] for event in beginnings]
        self.assertEqual(len(set(generations)), 2)
        self.assertLess(generations[0], generations[1])
        extracts = [job for job in case["expected"]["jobs"] if job["kind"] == "extract"]
        self.assertEqual(len(extracts), 1)
        self.assertEqual(extracts[0]["state"], "queued")
        self.assertEqual(case["expected"]["folder"]["scanGeneration"], generations[-1])

    def test_root_offline_never_lists_or_reads_the_inaccessible_root(self):
        case = self.case(make_contracts(), "scan", "root-offline")
        self.assertFalse(any(event["operation"] == "list" for event in case["input"]["events"]))
        self.assertEqual(case["expected"]["listCalls"], [])
        self.assertEqual(case["expected"]["readCalls"], 0)
        self.assertEqual(case["expected"]["folder"]["scanState"], "unavailable")
        self.assertTrue(all(source["availability"] != "missing" for source in case["expected"]["sources"]))

    def test_every_trace_event_has_an_explicit_timed_projection(self):
        contracts = make_contracts()
        checked = 0
        for contract in contracts.values():
            for case in contract["cases"]:
                events = case["input"].get("events")
                if events is None:
                    continue
                with self.subTest(case=case["name"]):
                    self.assertTrue(events)
                    times = []
                    for event in events:
                        self.assertIsInstance(event["operation"], str)
                        self.assertEqual(type(event["at"]), int)
                        self.assertGreaterEqual(event["at"], 0)
                        self.assertIsInstance(event["expected"], dict)
                        self.assertTrue(event["expected"])
                        times.append(event["at"])
                    self.assertEqual(times, sorted(times))
                    checked += 1
        self.assertGreaterEqual(checked, 35)

    def test_pipeline_preserves_synthetic_model_integer_weights(self):
        source = json.loads((Path(__file__).resolve().parents[2] /
            "Tests/fixtures/contracts/lang-score-v1.json").read_text(encoding="utf-8"))["model"]
        expected = copy.deepcopy(source)
        expected["targets"] = ["cs", "sk"]
        for profile in expected["profiles"]:
            profile["id"] = {"xa": "cs", "xb": "sk"}.get(profile["id"], profile["id"])
        actual = self.case(make_contracts(), "pipeline", "inherit-short")["input"]["model"]
        self.assertEqual(actual, expected)

    def test_ui_scope_reducer_and_watcher_truth_table(self):
        cases = make_contracts()["ingestion-ui-v1.json"]["cases"]
        localizations = [case for case in cases if case["operation"] == "localization"]
        self.assertEqual(len(localizations), 51)
        self.assertEqual(len({case["input"]["key"] for case in localizations}), 51)
        for case in localizations:
            self.assertEqual(set(case["expected"]), {"en", "cs"})
            self.assertTrue(all(case["expected"].values()))
        known = {case["input"]["key"]: case["expected"] for case in localizations}
        self.assertEqual(known["addFolderButton"], {"en": "Add folder…", "cs": "Přidat složku…"})
        self.assertEqual(known["scopeEmpty"], {"en": "No sources selected", "cs": "Nejsou vybrány žádné zdroje"})
        self.assertEqual(known["folderRefreshError"], {"en": "Refresh failed", "cs": "Aktualizace selhala"})
        watch = {case["input"]["kind"]: case["expected"] for case in cases
                 if case["operation"] == "watch"}
        self.assertEqual(watch, {kind: {"forceHash": kind != "created"}
                               for kind in ("created", "changed", "renamed", "deleted", "overflow")})
        scopes = [case for case in cases if case["operation"] == "scope"]
        self.assertGreaterEqual(len(scopes), 7)
        for case in scopes:
            with self.subTest(case=case["name"]):
                data = case["input"]
                if data["wholeNotebook"]:
                    expected = {"kind": "all"}
                else:
                    sources, folders = set(data["sourceIds"]), set(data["folderIds"])
                    for member in data["members"]:
                        if member["setId"] in data["setIds"]:
                            sources.update(member["sourceIds"])
                            folders.update(member["folderIds"])
                    expected = {"kind": "selection", "sourceIds": sorted(sources), "folderIds": sorted(folders)}
                self.assertEqual(case["expected"], expected)
        store = [case for case in cases if case["operation"] == "scope-store"]
        self.assertGreaterEqual(len(store), 2)

    def test_assets_have_fixed_metadata_valid_xml_and_actual_pdf_offsets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_assets(root)
            self.assertEqual({str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()}, ASSETS)
            for relative in sorted(ASSETS):
                data = (root / relative).read_bytes()
                with self.subTest(asset=relative):
                    self.assertLess(len(data), 256_000)
                    if relative.endswith("corrupt.docx"):
                        with self.assertRaises(zipfile.BadZipFile):
                            zipfile.ZipFile(io.BytesIO(data))
                    elif not relative.endswith(".pdf"):
                        with zipfile.ZipFile(io.BytesIO(data)) as archive:
                            names = archive.namelist()
                            self.assertEqual(len(names), len(set(names)))
                            self.assertIn("[Content_Types].xml", names)
                            for info in archive.infolist():
                                self.assertEqual(info.compress_type, zipfile.ZIP_STORED)
                                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
                                self.assertFalse(info.comment)
                                self.assertFalse(info.extra)
                                ET.fromstring(archive.read(info).decode("utf-8"))
                    else:
                        self.assertTrue(data.startswith(b"%PDF-"))
                        startxref = re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", data)
                        self.assertIsNotNone(startxref)
                        offset = int(startxref.group(1))
                        self.assertTrue(data[offset:].startswith(b"xref\n"))
                        lines = data[offset:].splitlines()
                        start, count = map(int, lines[1].split())
                        self.assertEqual(start, 0)
                        for number, entry in enumerate(lines[2:2 + count]):
                            position, generation, state = entry.split()
                            if state == b"n":
                                self.assertTrue(data[int(position):].startswith(
                                    f"{number} {int(generation)} obj".encode("ascii")))
                        self.assertRegex(data, rb"/Count\s+3\b")
                        self.assertRegex(data, rb"/BaseFont\s+/Helvetica\b")
                        self.assertIn(b"(A)", data)
                        self.assertIn(b"(B)", data)

    def test_office_assets_lock_relationship_order_and_cell_values(self):
        ns = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
              "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
              "p": "http://schemas.openxmlformats.org/presentationml/2006/main"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_assets(root)
            with zipfile.ZipFile(root / "ingestion/workbook.xlsx") as archive:
                workbook = ET.fromstring(archive.read("xl/workbook.xml"))
                sheets = workbook.findall("s:sheets/s:sheet", ns)
                self.assertEqual([(sheet.attrib["name"], sheet.attrib[f"{{{ns['r']}}}id"])
                                  for sheet in sheets], [("Zeta", "rIdB"), ("Alpha", "rIdA")])
                relationships = {element.attrib["Id"]: element.attrib["Target"] for element
                                 in ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))}
                self.assertTrue(relationships["rIdB"].endswith("sheet2.xml"))
                self.assertTrue(relationships["rIdA"].endswith("sheet1.xml"))
            with zipfile.ZipFile(root / "ingestion/slides.pptx") as archive:
                presentation = ET.fromstring(archive.read("ppt/presentation.xml"))
                ids = [slide.attrib[f"{{{ns['r']}}}id"]
                       for slide in presentation.findall("p:sldIdLst/p:sldId", ns)]
                relationships = {element.attrib["Id"]: element.attrib["Target"] for element
                                 in ET.fromstring(archive.read("ppt/_rels/presentation.xml.rels"))}
                self.assertEqual([Path(relationships[ident]).name for ident in ids],
                                 ["slide10.xml", "slide2.xml"])
        cases = make_contracts()
        self.assertEqual(self.case(cases, "office", "workbook-order")["expected"]["text"],
            "## Zeta\nA1: Příliš\tC1: A😀B\nA2: 42\tB2: TRUE\tC2: #DIV/0!\n"
            "A3: 2 [cached formula]\tC3: 45292 [date serial]\n\n## Alpha\nA1: last")
        errors = {case["expected"].get("error") for case in cases["ingestion-office-v1.json"]["cases"]}
        self.assertTrue({"invalidCell", "invalidRelationship", "corruptArchive",
                         "officeLimit", "textLimit", "cellLimit", "pageLimit"} <= errors)

    def test_slide_relationship_order_is_distinct_from_lexical_filename_order(self):
        case = self.case(make_contracts(), "office", "slides-relationship-not-lexical")
        self.assertEqual(case["input"]["asset"], "ingestion/slides.pptx")
        mutation = next(mutation for mutation in case["input"]["mutations"]
                        if mutation["entry"] == "ppt/presentation.xml")
        self.assertEqual(mutation["operation"], "replace-entry")
        ns = {"p": "http://schemas.openxmlformats.org/presentationml/2006/main",
              "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
        presentation = ET.fromstring(mutation["text"])
        ids = [slide.attrib[f"{{{ns['r']}}}id"]
               for slide in presentation.findall("p:sldIdLst/p:sldId", ns)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_assets(root)
            with zipfile.ZipFile(root / case["input"]["asset"]) as archive:
                relationships = {element.attrib["Id"]: element.attrib["Target"] for element
                                 in ET.fromstring(archive.read("ppt/_rels/presentation.xml.rels"))}
        files = [Path(relationships[ident]).name for ident in ids]
        self.assertEqual(files, ["slide2.xml", "slide10.xml"])
        self.assertNotEqual(files, sorted(files))
        self.assertEqual(case["expected"]["text"], "## Slide 1\nB\n\n## Slide 2\nA")

    def test_json_bytes_are_canonical_and_generate_preserves_unowned_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sentinel = root / "unowned.txt"
            sentinel.write_bytes(b"do not touch\n")
            generate(root)
            self.assertEqual(sentinel.read_bytes(), b"do not touch\n")
            for path in (root / "contracts").glob("*.json"):
                actual = path.read_bytes()
                expected = (json.dumps(json.loads(actual), ensure_ascii=False, sort_keys=True,
                                       indent=2) + "\n").encode("utf-8")
                self.assertEqual(actual, expected)
                self.assertFalse(actual.startswith(b"\xef\xbb\xbf"))
                self.assertNotIn(b"\r", actual)
            generate(root, check=True)

    def test_check_detects_every_owned_file_drift_without_rewriting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            generate(root)
            generate(root, check=True)
            owned = sorted(ASSETS | {f"contracts/{name}" for name in CONTRACT_NAMES})
            for relative in owned:
                with self.subTest(path=relative):
                    path = root / relative
                    original = path.read_bytes()
                    changed = original + b"\n"
                    path.write_bytes(changed)
                    with self.assertRaises(ValueError):
                        generate(root, check=True)
                    self.assertEqual(path.read_bytes(), changed)
                    path.write_bytes(original)
            missing = root / "ingestion/pages.pdf"
            missing.unlink()
            with self.assertRaises(ValueError):
                generate(root, check=True)
            self.assertFalse(missing.exists())

    def test_rejects_missing_asset_references(self):
        with self.assertRaises(ValueError):
            validate_contracts(make_contracts(), ASSETS - {"ingestion/pages.pdf"})

    def test_rejects_unknown_case_operation_and_duplicate_names(self):
        for mutation in ("operation", "duplicate"):
            with self.subTest(mutation=mutation):
                contracts = make_contracts()
                cases = contracts["ingestion-canonical-v1.json"]["cases"]
                if mutation == "operation":
                    cases[0]["operation"] = "unsupported-fixture-operation"
                else:
                    cases.append(copy.deepcopy(cases[0]))
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_rejects_unknown_office_mutation_operation_and_missing_member(self):
        for update in ({"operation": "unrecognized-mutation"},
                       {"entry": "xl/missing-member.xml"}):
            with self.subTest(update=update):
                contracts = make_contracts()
                mutation = self.case(contracts, "office", "formula-no-cache")["input"]["mutations"][0]
                mutation.update(update)
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_rejects_invalid_pdf_page_scalar_spans(self):
        for update in ({"start": -1}, {"start": 3}, {"end": 10},
                       {"start": 0.0}, {"end": True}):
            with self.subTest(update=update):
                contracts = make_contracts()
                page = self.case(contracts, "canonical", "pdf-empty-middle")["expected"]["pages"][0]
                page.update(update)
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_rejects_chunk_page_ranges_that_disagree_with_the_page_map(self):
        for update in ({"pageFrom": 999}, {"pageTo": 0}, {"pageFrom": 2},
                       {"pageTo": 2}, {"pageFrom": 3, "pageTo": 1}):
            with self.subTest(update=update):
                contracts = make_contracts()
                chunk = self.case(contracts, "canonical", "pdf-empty-middle")["expected"]["chunks"][0]
                chunk.update(update)
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_rejects_values_that_cannot_represent_input_bytes(self):
        for byte in (-1, 256, True):
            with self.subTest(byte=byte):
                contracts = make_contracts()
                self.case(contracts, "encoding", "utf8-bom")["input"]["bytes"][0] = byte
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_rejects_invalid_stored_revision_chunk_and_page_references(self):
        updates = [("chunks", {"end": 99999}), ("chunks", {"text": "wrong"}),
                   ("chunks", {"revisionId": 99999}), ("chunks", {"sourceId": 999}),
                   ("revisionPages", {"end": 99999})]
        for collection, update in updates:
            with self.subTest(collection=collection, update=update):
                contracts = make_contracts()
                case = self.case(contracts, "pipeline", "revision-page-map-survives-refresh")
                projection = case["input"]["events"][-1]["expected"]
                projection["state"][collection][-1].update(update)
                case["expected"] = copy.deepcopy(projection)
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_released_generation_is_removed_by_gc_after_its_pin_is_released(self):
        case = self.case(make_contracts(), "generations", "pin-keeps-old-vectors")
        self.assertEqual(case["expected"]["pins"], [])
        self.assertEqual(case["expected"]["activeGenerationId"], 20)
        self.assertEqual([generation["id"] for generation in case["expected"]["generations"]], [20])

    def test_generation_rows_do_not_invent_a_persisted_error_column(self):
        checked = 0

        def check(value):
            nonlocal checked
            if isinstance(value, dict):
                for generation in value.get("generations", []):
                    self.assertNotIn("error", generation,
                                     "Generation errors belong to ingest_jobs; index_generations has no error column")
                    checked += 1
                for child in value.values():
                    check(child)
            elif isinstance(value, list):
                for child in value:
                    check(child)

        check(make_contracts()["ingestion-generations-v1.json"])
        self.assertGreater(checked, 0)

    def test_generation_revision_publication_has_a_completed_fenced_extract_job(self):
        checked = 0
        for case in make_contracts()["ingestion-generations-v1.json"]["cases"]:
            for event in case["input"].get("events", []):
                if event["operation"] != "publish-revision":
                    continue
                with self.subTest(case=case["name"]):
                    self.assertIn("extractJobId", event)
                    self.assertIn("leaseToken", event)
                    self.assertEqual(type(event["extractJobId"]), int)
                    self.assertIsInstance(event["leaseToken"], str)
                    self.assertTrue(event["leaseToken"])
                    jobs = [job for job in event["expected"]["jobs"] if job["id"] == event["extractJobId"]]
                    self.assertEqual(len(jobs), 1)
                    self.assertEqual(jobs[0]["kind"], "extract")
                    self.assertEqual(jobs[0]["state"], "done")
                    self.assertEqual(jobs[0]["target"], f"source:{event['sourceId']}")
                    self.assertIsNone(jobs[0]["leaseToken"])
                    self.assertIsNone(jobs[0]["leaseUntil"])
                    checked += 1
        self.assertGreater(checked, 0)

    def test_rejects_surrogate_codepoints_in_fixture_strings(self):
        for text in ("\ud800", "\udfff", "a\ud800b"):
            with self.subTest(text=repr(text)):
                contracts = make_contracts()
                self.case(contracts, "encoding", "empty")["expected"]["text"] = text
                with self.assertRaises(ValueError):
                    validate_contracts(contracts, ASSETS)

    def test_rejects_floating_point_trace_times(self):
        contracts = make_contracts()
        case = self.case(contracts, "scan", "fast-path")
        case["input"]["events"][0]["at"] = 0.0
        with self.assertRaises(ValueError):
            validate_contracts(contracts, ASSETS)


if __name__ == "__main__":
    unittest.main()
