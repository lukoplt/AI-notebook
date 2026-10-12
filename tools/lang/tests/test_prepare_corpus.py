"""Offline corpus preparation and pinned WP1 snapshot contract tests."""

import bz2
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from tools.lang.prepare_corpus import build_components, group_id, prepare, snapshot_wp1, split_group
from tools.lang.reference import UnicodeData, classify, normalize


ROOT = Path(__file__).resolve().parents[3]
SPLITS = ("train", "validation", "test")
MAPPINGS = [("ces", "cs"), ("deu", "de"), ("eng", "en"), ("slk", "sk"),
            ("fra", "fr"), ("hrv", "hr"), ("hun", "hu"), ("nld", "nl"),
            ("pol", "pl"), ("slv", "sl")]
DEFAULT_RECORDS = [
    (1, "ces", "Příliš žluťoučký kůň úpěl ďábelské ódy. " * 15, "CzechAuthor"),
    (2, "slk", "Ľúbezná vôňa čaká ďalších návštevníkov. " * 15, "SlovakAuthor"),
    (3, "jpn", "除外された翻訳", "ExcludedAuthor"),
    (4, "eng", "The missing author requires exclusion.", ""),
    (5, "fra", "La phrase française conserve ses accents.", "FrenchAuthor"),
    (6, "ces", "Identical words without translation links.", "FirstAuthor"),
    (7, "ces", "Identical words without translation links.", "SecondAuthor"),
    (8, "deu", "Ein gemeinfreier deutscher Beispielsatz.", ""),
]


def tiny_config():
    languages = sorted(target for _, target in MAPPINGS)
    return {
        "sourceId": "tatoeba", "modelId": "wp4-invented-test-only",
        "targets": ["cs", "de", "en", "sk"],
        "languageMappings": [{"sourceLanguage": source, "detectorLanguage": target}
                             for source, target in MAPPINGS],
        "negativeLanguages": ["fr", "hr", "hu", "nl", "pl", "sl"],
        "seed": 1729, "splitBp": {"train": 8000, "validation": 1000, "test": 1000},
        "maxComponentMembers": 10000,
        "caps": [{"split": split, "language": language, "maxOriginalRecords": 100}
                 for split in SPLITS for language in languages],
        "augmentation": [
            {"algorithm": "scalar-prefix-v1", "splits": list(SPLITS), "lengths": [24, 64, 160, 400]},
            {"algorithm": "strip-marks-v1", "splits": list(SPLITS), "lengths": []},
        ],
        "parameters": {"maxFeaturesPerProfile": [256, 1024, 4096], "orderWeights": [1, 2, 3],
                       "scoreScale": 1024, "lengthBucketStarts": [12, 32, 80, 200],
                       "minLetters": 12, "minWords": 3, "mixedDominanceBp": 7000,
                       "inputCapScalars": 5000000, "textCapScalars": 8192,
                       "windowCount": 8, "windowScalars": 512},
        "licenseIds": ["CC0-1.0", "CC-BY-2.0-FR"],
    }


def tiny_corpus(root, records=None, links=None, cc0_ids=None, reverse=False):
    """Create wholly invented local exports; no real corpus/network is involved."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    records = list(DEFAULT_RECORDS if records is None else records)
    links = list([(1, 3), (3, 2), (2, 999)] if links is None else links)
    cc0_ids = {8} if cc0_ids is None else set(cc0_ids)
    if reverse:
        records.reverse()
        links.reverse()
    lock = {"contract": "tatoeba-inputs", "version": 1, "sourceId": "tatoeba",
            "snapshotDate": "2026-10-09", "files": []}

    def emit(name, role, rows, format_version, url):
        raw = "".join("\t".join(map(str, row)) + "\n" for row in rows).encode("utf-8")
        compressed = bz2.compress(raw)
        (root / name).write_bytes(compressed)
        lock["files"].append({"role": role, "url": url, "localPath": name,
            "sha256": hashlib.sha256(compressed).hexdigest(),
            "uncompressedSha256": hashlib.sha256(raw).hexdigest(),
            "formatVersion": format_version, "memberPath": None, "byteCount": len(compressed),
            "lastModified": "Fri, 09 Oct 2026 00:00:00 GMT", "etag": '"invented-v1"'})

    url = "https://downloads.tatoeba.org/exports/"
    emit("sentences_base.tsv.bz2", "base", [(i, "\\N") for i, _, _, _ in records],
         "tatoeba-base-v1", url + "sentences_base.tar.bz2")
    emit("links.tsv.bz2", "links", links, "tatoeba-links-v1", url + "links.tar.bz2")
    emit("sentences_CC0.tsv.bz2", "cc0", [(i, lang, text, "2026-10-09 00:00:00")
         for i, lang, text, _ in records if i in cc0_ids],
         "tatoeba-cc0-v1", url + "sentences_CC0.tar.bz2")
    for lang, _ in MAPPINGS:
        name = f"{lang}_sentences_detailed.tsv.bz2"
        emit(name, "sentences", [(i, code, text, owner, "2026-10-01 00:00:00", "2026-10-09 00:00:00")
             for i, code, text, owner in records if code == lang],
             "tatoeba-detailed-v1", url + f"per_language/{lang}/{name}")
    return lock


def read_examples(output):
    return [json.loads(line) for line in (Path(output) / "examples.jsonl").read_text().splitlines()]


def replace_export(root, entry, raw):
    compressed = bz2.compress(raw)
    (Path(root) / entry["localPath"]).write_bytes(compressed)
    entry.update(sha256=hashlib.sha256(compressed).hexdigest(),
                 uncompressedSha256=hashlib.sha256(raw).hexdigest(), byteCount=len(compressed))


class OfflineTests(unittest.TestCase):
    def setUp(self):
        for name in ("socket.socket", "socket.create_connection", "urllib.request.urlopen"):
            patcher = patch(name, side_effect=AssertionError("network forbidden in corpus tests"))
            patcher.start()
            self.addCleanup(patcher.stop)


class CorpusTests(OfflineTests):
    def test_links_through_excluded_or_missing_text(self):
        groups = build_components("tatoeba", [1, 2], [(1, 99), (99, 2)])
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["keys"], ["tatoeba:1", "tatoeba:2", "tatoeba:99"])
        expected = "a67d6874c78af1cb330d9c5c338cd56b034c75fa3fc06bbe2368884c7dde8a0e"
        self.assertEqual(groups[0]["groupId"], expected)
        self.assertEqual(group_id(groups[0]["keys"]), expected)
        self.assertEqual(split_group(expected, 1729, (8000, 1000, 1000)), "test")
        self.assertEqual(groups, build_components("tatoeba", [2, 1], [(99, 2), (1, 99)]))

    def test_duplicate_reverse_links_and_identical_unlinked_text(self):
        groups = build_components("tatoeba", [1, 2, 3], [(1, 2), (2, 1), (1, 2)])
        self.assertEqual(sorted(g["keys"] for g in groups),
                         [["tatoeba:1", "tatoeba:2"], ["tatoeba:3"]])

    def test_split_rejects_invalid_basis_points(self):
        for split in [(0, 5000, 5000), (8000, 1000, 999), (-1, 5000, 5001)]:
            with self.subTest(split=split), self.assertRaises(ValueError):
                split_group("0" * 64, 1729, split)

    def test_graph_rejects_invalid_source_and_noncanonical_ids(self):
        for source, ids in [("tatöeba", [1]), ("tatoeba:foreign", [1]), ("tatoeba", [True]),
                            ("tatoeba", [-1]), ("tatoeba", ["01"])]:
            with self.subTest(source=source, ids=ids), self.assertRaises(ValueError):
                build_components(source, ids, [])

    def test_graph_precedes_language_filtering_and_preserves_attribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            result = prepare(root / "data", lock, tiny_config(), root / "out")
            originals = {r["recordKey"]: r for r in read_examples(root / "out") if r["rule"] == "original"}
            self.assertEqual(set(originals), {f"tatoeba:{i}" for i in [1, 2, 5, 6, 7, 8]})
            linked = group_id(["tatoeba:1", "tatoeba:2", "tatoeba:3", "tatoeba:999"])
            self.assertEqual(originals["tatoeba:1"]["originalGroupId"], linked)
            self.assertEqual(originals["tatoeba:2"]["originalGroupId"], linked)
            self.assertEqual(originals["tatoeba:1"]["split"], originals["tatoeba:2"]["split"])
            self.assertNotEqual(originals["tatoeba:6"]["originalGroupId"], originals["tatoeba:7"]["originalGroupId"])
            self.assertEqual(originals["tatoeba:1"]["licenseId"], "CC-BY-2.0-FR")
            self.assertEqual(originals["tatoeba:1"]["contributor"], "CzechAuthor")
            self.assertEqual(originals["tatoeba:8"]["licenseId"], "CC0-1.0")
            self.assertEqual(originals["tatoeba:5"]["language"], "fr")
            self.assertEqual(result["deduplicationPolicy"], "none; translation links only")
            self.assertEqual(sum(r["count"] for r in result["exclusions"] if r["reason"] == "missingContributor"), 1)
            self.assertEqual(sum(r["count"] for r in result["exclusions"] if r["reason"] == "languageExcluded"), 1)
            self.assertEqual([r["language"] for r in result["exclusions"] if r["reason"] == "languageExcluded"], ["und"])
            self.assertEqual(len(result["files"]), len(lock["files"]))
            for source in lock["files"]:
                self.assertTrue(any(f["sha256"] == source["sha256"] and
                                    f["uncompressedSha256"] == source["uncompressedSha256"]
                                    for f in result["files"]))

    def test_oversized_blocks_inherit_one_original_split(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            config = tiny_config()
            config["maxComponentMembers"] = 2
            result = prepare(root / "data", lock, config, root / "out")
            expected = group_id(["tatoeba:1", "tatoeba:2", "tatoeba:3", "tatoeba:999"])
            oversized = next(row for row in result["oversizedComponents"] if row["groupId"] == expected)
            self.assertEqual(oversized, {"groupId": expected, "memberCount": 4, "blocks": [
                {"groupId": group_id(["tatoeba:1", "tatoeba:2"]), "memberCount": 2},
                {"groupId": group_id(["tatoeba:3", "tatoeba:999"]), "memberCount": 2}]})
            rows = [row for row in read_examples(root / "out") if row["originalGroupId"] == expected]
            self.assertEqual({row["split"] for row in rows}, {split_group(expected, 1729, (8000, 1000, 1000))})
            assignment = result["splitAssignments"]
            raw = (root / "out" / assignment["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), assignment["sha256"])

    def test_conflicting_duplicate_sentence_id_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = [(1, "ces", "First original.", "Owner"), (1, "ces", "Conflicting original.", "Owner")]
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[])
            with self.assertRaisesRegex(ValueError, "[Dd]uplicate|[Cc]onflict"):
                prepare(root / "data", lock, tiny_config(), root / "out")

    def test_real_base_sample_lines_are_presence_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = [(2, "ces", "Original Czech sample sentence.", "Owner"),
                       (3, "slk", "Original Slovak sample sentence.", "Owner")]
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[])
            raw = bz2.decompress((root / "data" / lock["files"][0]["localPath"]).read_bytes())
            self.assertEqual(raw, b"2\t\\N\n3\t\\N\n")
            result = prepare(root / "data", lock, tiny_config(), root / "out")
            originals = [r for r in read_examples(root / "out") if r["rule"] == "original"]
            self.assertEqual({r["recordKey"] for r in originals}, {"tatoeba:2", "tatoeba:3"})
            self.assertEqual({r["language"] for r in originals}, {"cs", "sk"})
            self.assertEqual(result["splitAssignments"]["groups"], 2)

    def test_base_references_are_validated_but_not_translation_edges_or_vertices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = [(2, "ces", "First original sample sentence.", "Owner"),
                       (3, "slk", "Second original sample sentence.", "Owner")]
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[])
            replace_export(root / "data", lock["files"][0], b"2\t3\n3\t999\n0\t0\n4\t9223372036854775807\n")
            result = prepare(root / "data", lock, tiny_config(), root / "out")
            originals = [r for r in read_examples(root / "out") if r["rule"] == "original"]
            self.assertEqual({r["originalGroupId"] for r in originals},
                             {group_id(["tatoeba:2"]), group_id(["tatoeba:3"])})
            self.assertEqual(result["splitAssignments"]["groups"], 4)
            self.assertEqual(sum(r["count"] for r in result["exclusions"] if r["reason"] == "languageExcluded"), 2)

    def test_invalid_base_references_and_field_counts_are_rejected(self):
        for raw in [b"1\t\n", b"1\t01\n", b"1\t-1\n", b"1\t 2\n", b"1\tNULL\n",
                    b"1\t9223372036854775808\n", b"1\n", b"1\tces\tOld format.\n"]:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                lock = tiny_corpus(root / "data")
                replace_export(root / "data", lock["files"][0], raw)
                with self.assertRaisesRegex(ValueError, "sentence ID|field count"):
                    prepare(root / "data", lock, tiny_config(), root / "out")

    def test_conflicting_duplicate_base_reference_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            replace_export(root / "data", lock["files"][0], b"1\t\\N\n1\t2\n")
            with self.assertRaisesRegex(ValueError, "conflicting duplicate sentence ID"):
                prepare(root / "data", lock, tiny_config(), root / "out")

    def test_missing_base_above_default_skew_limit_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            raw = bz2.decompress((root / "data" / lock["files"][0]["localPath"]).read_bytes())
            replace_export(root / "data", lock["files"][0], raw.replace(b"1\t\\N\n", b""))
            with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                prepare(root / "data", lock, tiny_config(), root / "out")

    def test_cc0_detail_language_text_and_modified_must_match(self):
        for index, value in [(1, "ces"), (2, "Mismatched text."), (3, "2026-10-02 00:00:00")]:
            with self.subTest(field=index), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                lock = tiny_corpus(root / "data")
                entry = next(r for r in lock["files"] if r["role"] == "cc0")
                fields = ["8", "deu", DEFAULT_RECORDS[-1][2], "2026-10-09 00:00:00"]
                fields[index] = value
                replace_export(root / "data", entry, ("\t".join(fields) + "\n").encode())
                with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                    prepare(root / "data", lock, tiny_config(), root / "out")

    def test_skew_at_one_percent_is_excluded_before_caps_and_augmentation(self):
        for field, value in [(1, "deu"), (2, "Recently edited text."), (3, "2026-10-08 00:00:00")]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                records = [(i, "ces", f"Příliš žluťoučký kůň úpěl ďábelské ódy {i}.", "Owner")
                           for i in range(1, 201)]
                lock = tiny_corpus(root / "data", records=records, links=[(1, 9), (9, 2)], cc0_ids=[10])
                base = next(r for r in lock["files"] if r["role"] == "base")
                raw = bz2.decompress((root / "data" / base["localPath"]).read_bytes())
                replace_export(root / "data", base,
                               b"".join(line for line in raw.splitlines(keepends=True) if line != b"9\t\\N\n"))
                cc0 = next(r for r in lock["files"] if r["role"] == "cc0")
                fields = ["10", "ces", records[9][2], "2026-10-09 00:00:00"]
                fields[field] = value
                replace_export(root / "data", cc0, ("\t".join(fields) + "\n").encode())
                config = tiny_config()
                for cap in config["caps"]:
                    cap["maxOriginalRecords"] = 300
                result = prepare(root / "data", lock, config, root / "out")
                self.assertEqual(result["snapshotSkew"], {
                    "missingFromBase": 1, "cc0DetailMismatch": 1,
                    "excludedIdsSha256": hashlib.sha256(b"9\n10").hexdigest(), "sampleIds": [9, 10]})
                rows = read_examples(root / "out")
                self.assertTrue(all(r["recordKey"] not in ("tatoeba:9", "tatoeba:10") for r in rows))
                originals = {r["recordKey"]: r for r in rows if r["rule"] == "original"}
                self.assertEqual(len(originals), 198)
                self.assertEqual(originals["tatoeba:1"]["originalGroupId"],
                                 group_id(["tatoeba:1", "tatoeba:2", "tatoeba:9"]))
                self.assertEqual(originals["tatoeba:1"]["split"], originals["tatoeba:2"]["split"])
                self.assertEqual(sum(r["count"] for r in result["exclusions"]
                                     if r["reason"] == "snapshotSkew"), 2)
                self.assertEqual(json.loads((root / "out" / "provenance.json").read_text())["snapshotSkew"],
                                 result["snapshotSkew"])
                # 2/199 exceeds 1%, even though integer-rounded basis points equal 100.
                detail = next(r for r in lock["files"] if r["localPath"].startswith("ces_"))
                raw = bz2.decompress((root / "data" / detail["localPath"]).read_bytes())
                replace_export(root / "data", detail, b"\n".join(raw.splitlines()[:-1]) + b"\n")
                with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                    prepare(root / "data", lock, config, root / "rejected")
                self.assertFalse((root / "rejected").exists())

    def test_skew_overlap_counts_reasons_but_excludes_each_id_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = [(i, "ces", "Original sample sentence.", "Owner") for i in range(100)]
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[0])
            base = next(r for r in lock["files"] if r["role"] == "base")
            raw = bz2.decompress((root / "data" / base["localPath"]).read_bytes())
            replace_export(root / "data", base, raw.removeprefix(b"0\t\\N\n"))
            cc0 = next(r for r in lock["files"] if r["role"] == "cc0")
            replace_export(root / "data", cc0, b"0\tces\tEdited sentence.\t2026-10-09 00:00:00\n")
            result = prepare(root / "data", lock, tiny_config(), root / "out")
            self.assertEqual(result["snapshotSkew"], {"missingFromBase": 1, "cc0DetailMismatch": 1,
                "excludedIdsSha256": hashlib.sha256(b"0").hexdigest(), "sampleIds": [0]})
            self.assertEqual(sum(r["count"] for r in result["exclusions"] if r["reason"] == "snapshotSkew"), 1)
            self.assertNotIn("tatoeba:0", {r["recordKey"] for r in read_examples(root / "out")})

    def test_configurable_skew_and_sample_are_deterministic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = [(i, "ces", "Original sample sentence.", "Owner") for i in range(25)]
            config = tiny_config()
            config["maxSnapshotSkewBp"] = 10000
            results = []
            for reverse in (False, True):
                data, out = root / f"data-{reverse}", root / f"out-{reverse}"
                lock = tiny_corpus(data, records=records, links=[], cc0_ids=[], reverse=reverse)
                base = next(r for r in lock["files"] if r["role"] == "base")
                replace_export(data, base, b"")
                result = prepare(data, lock, config, out)
                self.assertEqual(read_examples(out), [])
                self.assertEqual(result["snapshotSkew"], {"missingFromBase": 25, "cc0DetailMismatch": 0,
                    "excludedIdsSha256": hashlib.sha256("\n".join(map(str, range(25))).encode()).hexdigest(),
                    "sampleIds": list(range(20))})
                results.append(result["snapshotSkew"])
            self.assertEqual(results[0], results[1])

    def test_skew_uses_selected_detailed_rows_before_license_or_cap_filtering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # 99 unselected French details must not dilute the one selected Czech row's skew.
            records = [(1, "ces", "Original Czech sentence.", "")]
            records += [(i, "fra", "Original French sentence.", "Owner") for i in range(2, 101)]
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[])
            base = next(r for r in lock["files"] if r["role"] == "base")
            replace_export(root / "data", base,
                           b"".join(f"{i}\t\\N\n".encode() for i in range(2, 101)))
            config = tiny_config()
            config["negativeLanguages"].remove("fr")
            config["languageMappings"] = [r for r in config["languageMappings"] if r["sourceLanguage"] != "fra"]
            config["caps"] = [r for r in config["caps"] if r["language"] != "fr"]
            with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                prepare(root / "data", lock, config, root / "out")
            replace_export(root / "data", base, b"")
            config["maxSnapshotSkewBp"] = 10000
            result = prepare(root / "data", lock, config, root / "out")
            self.assertEqual(result["snapshotSkew"]["missingFromBase"], 1)
            self.assertEqual(result["snapshotSkew"]["sampleIds"], [1])

    def test_zero_skew_and_invalid_skew_limits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            config = tiny_config()
            config["maxSnapshotSkewBp"] = 0
            result = prepare(root / "data", lock, config, root / "out")
            self.assertEqual(result["snapshotSkew"], {"missingFromBase": 0, "cc0DetailMismatch": 0,
                "excludedIdsSha256": hashlib.sha256(b"").hexdigest(), "sampleIds": []})
            for invalid in (-1, 10001, True, "100", 100.0, None):
                config["maxSnapshotSkewBp"] = invalid
                with self.subTest(limit=invalid), self.assertRaisesRegex(ValueError, "maxSnapshotSkewBp"):
                    prepare(root / "data", lock, config, root / "out")

    def test_conflicting_duplicate_contributor_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = [(1, "ces", "Same text.", "FirstOwner"), (1, "ces", "Same text.", "SecondOwner")]
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[])
            with self.assertRaisesRegex(ValueError, "[Dd]uplicate|[Cc]onflict"):
                prepare(root / "data", lock, tiny_config(), root / "out")

    def test_tatoeba_missing_owner_sentinel_and_whitespace_excluded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = [(1, "ces", "No owner supplied.", "\\N"), (2, "ces", "Blank owner supplied.", "   ")]
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[])
            result = prepare(root / "data", lock, tiny_config(), root / "out")
            self.assertEqual(read_examples(root / "out"), [])
            self.assertEqual(sum(row["count"] for row in result["exclusions"] if row["reason"] == "missingContributor"), 2)

    def test_wrong_compressed_hash_fails_before_parsing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            (root / "data" / lock["files"][0]["localPath"]).write_bytes(b"invalid compressed and TSV bytes")
            with self.assertRaisesRegex(ValueError, "SHA-256|hash"):
                prepare(root / "data", lock, tiny_config(), root / "out")

    def test_wrong_uncompressed_hash_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            lock["files"][0]["uncompressedSha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "SHA-256|hash"):
                prepare(root / "data", lock, tiny_config(), root / "out")

    def test_invalid_utf8_and_noncanonical_ids_are_rejected(self):
        for raw in [b"1\t\xff\n", b"01\t\\N\n", b"-1\t\\N\n"]:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                lock = tiny_corpus(root / "data")
                source = lock["files"][0]
                replace_export(root / "data", source, raw)
                with self.assertRaises((ValueError, UnicodeDecodeError)):
                    prepare(root / "data", lock, tiny_config(), root / "out")

    def test_tar_member_verification_and_unsafe_members(self):
        for kind in ["regular", "traversal", "symlink", "extra"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                lock = tiny_corpus(root / "data")
                entry = lock["files"][0]
                raw = bz2.decompress((root / "data" / entry["localPath"]).read_bytes())
                member = "../outside.csv" if kind == "traversal" else "sentences_base.csv"
                data = io.BytesIO()
                with tarfile.open(fileobj=data, mode="w:bz2") as archive:
                    info = tarfile.TarInfo(member)
                    info.size = len(raw)
                    if kind == "symlink":
                        info.type, info.linkname, info.size = tarfile.SYMTYPE, "outside.tsv", 0
                    archive.addfile(info, io.BytesIO(raw) if kind != "symlink" else None)
                    if kind == "extra":
                        extra = tarfile.TarInfo("unexpected.tsv")
                        archive.addfile(extra, io.BytesIO())
                compressed = data.getvalue()
                (root / "data" / entry["localPath"]).write_bytes(compressed)
                entry.update(memberPath=member, sha256=hashlib.sha256(compressed).hexdigest(), byteCount=len(compressed))
                if kind == "regular":
                    prepare(root / "data", lock, tiny_config(), root / "out")
                    self.assertTrue(read_examples(root / "out"))
                else:
                    with self.assertRaises(ValueError):
                        prepare(root / "data", lock, tiny_config(), root / "out")

    def test_unknown_tsv_schema_and_duplicate_language_mapping_rejected(self):
        for mutation in ["schema", "mapping"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                lock = tiny_corpus(root / "data")
                config = tiny_config()
                if mutation == "schema":
                    lock["files"][0]["formatVersion"] = "unknown-v1"
                else:
                    config["languageMappings"].append(copy.deepcopy(config["languageMappings"][0]))
                with self.assertRaises(ValueError):
                    prepare(root / "data", lock, config, root / "out")

    def test_cli_help_and_required_preparation_arguments(self):
        script = ROOT / "tools/lang/prepare_corpus.py"
        help_result = subprocess.run([sys.executable, "-B", str(script), "--help"], capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        for flag in ["--data-dir", "--lock", "--config", "--output-dir", "--snapshot-wp1", "--wp1-output"]:
            self.assertIn(flag, help_result.stdout)
        missing = subprocess.run([sys.executable, "-B", str(script)], capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("requires", missing.stderr)

    def test_cap_order_is_seeded_record_hash_after_split(self):
        records = [(i, "ces", f"Příliš mnoho vět číslo {i}.", "Owner") for i in range(1, 31)]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = tiny_config()
            config["augmentation"] = [{"algorithm": "none-v1", "splits": list(SPLITS), "lengths": []}]
            for cap in config["caps"]:
                cap["maxOriginalRecords"] = 1
            lock = tiny_corpus(root / "data", records=records, links=[], cc0_ids=[])
            result = prepare(root / "data", lock, config, root / "out")
            actual = {row["split"]: row["recordKey"] for row in read_examples(root / "out")}
            expected = {}
            for split in SPLITS:
                keys = [f"tatoeba:{i}" for i, _, _, _ in records
                        if split_group(group_id([f"tatoeba:{i}"]), 1729, (8000, 1000, 1000)) == split]
                if keys:
                    expected[split] = min(keys, key=lambda key:
                        (hashlib.sha256(f"1729\n{key}\n".encode()).digest(), key.encode()))
            self.assertEqual(actual, expected)
            self.assertEqual(sum(r["count"] for r in result["exclusions"] if r["reason"] == "cap"),
                             len(records) - len(expected))

    def test_augmentation_is_independent_and_counts_original_groups(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            text = "Łß áéíóú " * 70
            records = [(1, "ces", text, "Owner"), (2, "ces", text, "Owner")]
            lock = tiny_corpus(root / "data", records=records, links=[(1, 2)], cc0_ids=[])
            config = tiny_config()
            result = prepare(root / "data", lock, config, root / "out")
            examples = read_examples(root / "out")
            tables = UnicodeData.load(ROOT / "Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json")
            stream = normalize(text, tables, 5000000)
            self.assertEqual(len(examples), 12)
            self.assertEqual(len({row["originalGroupId"] for row in examples}), 1)
            self.assertEqual(len({row["split"] for row in examples}), 1)
            for row in examples:
                if row["rule"] == "original":
                    self.assertIsNone(row["length"])
                    self.assertEqual(row["text"], text)
                    self.assertEqual(row["normalizedScalars"], stream)
                elif row["rule"] == "scalar-prefix-v1":
                    self.assertEqual(row["normalizedScalars"], stream[:row["length"]])
                elif row["rule"] == "strip-marks-v1":
                    self.assertEqual("".join(map(chr, row["normalizedScalars"])), "łss aeiou " * 70)
                else:
                    self.fail(f"Unexpected rule: {row['rule']}")
            count_rows = result["counts"]
            self.assertEqual(len(count_rows), 10 * 3 * 5)
            self.assertEqual(sum(row["originals"] for row in count_rows), 2)
            self.assertEqual(sum(row["augmented"] for row in count_rows), 10)
            for row in count_rows:
                matching = [example for example in examples if example["split"] == row["split"]
                            and example["language"] == row["language"]
                            and max([0] + [b for b in [12, 32, 80, 200] if
                                classify(example["normalizedScalars"][:8192], tables)["letterCount"] >= b]) == row["bucketStart"]]
                self.assertEqual(row["originalGroups"], len({e["originalGroupId"] for e in matching}))

    def test_reproducible_outputs_and_shuffled_input_examples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, reverse in [("a", False), ("b", False), ("shuffled", True)]:
                lock = tiny_corpus(root / name / "data", reverse=reverse)
                prepare(root / name / "data", lock, tiny_config(), root / name / "out")
            for filename in ["examples.jsonl", "groups.jsonl", "provenance.json"]:
                self.assertEqual((root / "a/out" / filename).read_bytes(), (root / "b/out" / filename).read_bytes())
            for filename in ["examples.jsonl", "groups.jsonl"]:
                self.assertEqual((root / "a/out" / filename).read_bytes(), (root / "shuffled/out" / filename).read_bytes())

    def test_equal_text_from_distinct_rules_keeps_both_examples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data", records=[(1, "ces", "A \u0301", "Owner")], links=[], cc0_ids=[])
            config = tiny_config()
            config["augmentation"][0]["lengths"] = [2]
            prepare(root / "data", lock, config, root / "out")
            examples = read_examples(root / "out")
            self.assertEqual(len(examples), 3)
            derived = [row for row in examples if row["rule"] != "original"]
            self.assertEqual({row["rule"] for row in derived}, {"scalar-prefix-v1", "strip-marks-v1"})
            self.assertEqual([row["normalizedScalars"] for row in derived], [[97, 32], [97, 32]])


LANGUAGES = sorted(target for _, target in MAPPINGS)


def concat_rule(lengths=(64, 160), splits=SPLITS, cap=1000):
    return {"algorithm": "concat-v1", "splits": list(splits), "lengths": list(lengths),
            "maxOutputs": [{"split": split, "language": language, "maxOutputsPerLength": cap}
                           for split in splits for language in LANGUAGES]}


def concat_records():
    """Short invented sentences; several languages, cross- and same-language links."""
    records = [(i, "ces", f"Tohle je krátká česká věta číslo {i}.", f"CzechOwner{i % 3}") for i in range(1, 61)]
    records += [(i, "slk", f"Toto je krátka slovenská veta číslo {i}.", "SlovakOwner") for i in range(61, 121)]
    records += [(i, "fra", f"Voici une phrase française numéro {i}.", "FrenchOwner") for i in range(121, 151)]
    return records


CONCAT_LINKS = [(1, 2), (3, 4), (5, 61), (7, 62), (121, 9)]


def expected_concatenations(pool, length, cap, seed=1729):
    """Independent reading of concat-v1; pool is [(recordKey, groupId, scalars)] in cap order."""
    output = []
    for key, group, stream in pool:
        if len(output) >= cap:
            break
        if len(stream) >= length:
            continue
        members, groups, total, draw = [(key, stream)], {group}, len(stream), 0
        while total < length and draw < 4 * length:
            draw += 1
            digest = hashlib.sha256(f"{seed}\nconcat-v1\n{length}\n{key}\n{draw}\n".encode()).digest()
            other_key, other_group, other_stream = pool[int.from_bytes(digest[:8], "big") % len(pool)]
            if other_group in groups:
                continue
            members.append((other_key, other_stream))
            groups.add(other_group)
            total += 1 + len(other_stream)
        if total < length:
            continue
        scalars = []
        for index, (_, stream_part) in enumerate(members):
            scalars.extend(([32] if index else []) + stream_part)
        output.append(([k for k, _ in members], scalars[:length]))
    return output


def cap_order(rows):
    return sorted(rows, key=lambda row: (hashlib.sha256(f"1729\n{row['recordKey']}\n".encode()).hexdigest(),
                                         row["recordKey"].split(":", 1)[1]))


class ConcatenationTests(OfflineTests):
    def prepared(self, root, records=None, links=None, rules=None, reverse=False):
        config = tiny_config()
        config["augmentation"] = rules or [concat_rule()]
        lock = tiny_corpus(root / "data", records=concat_records() if records is None else records,
                           links=CONCAT_LINKS if links is None else links, cc0_ids=[], reverse=reverse)
        result = prepare(root / "data", lock, config, root / "out")
        return result, read_examples(root / "out")

    def test_concat_joins_distinct_groups_of_one_language_and_split(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, examples = self.prepared(Path(temporary))
            originals = {row["recordKey"]: row for row in examples if row["rule"] == "original"}
            derived = [row for row in examples if row["rule"] == "concat-v1"]
            self.assertTrue(derived)
            self.assertEqual({row["length"] for row in derived}, {64, 160})
            self.assertGreater(len({row["language"] for row in derived}), 1)
            for row in derived:
                members = [originals[key] for key in row["memberRecordKeys"]]
                self.assertGreaterEqual(len(members), 2)
                self.assertEqual(row["memberRecordKeys"][0], row["recordKey"])
                self.assertEqual(row["originalGroupId"], originals[row["recordKey"]]["originalGroupId"])
                self.assertEqual({m["split"] for m in members}, {row["split"]})
                self.assertEqual({m["language"] for m in members}, {row["language"]})
                self.assertEqual(len({m["originalGroupId"] for m in members}), len(members))
                self.assertFalse({"tatoeba:1", "tatoeba:2"} <= set(row["memberRecordKeys"]))
                joined = []
                for index, member in enumerate(members):
                    joined.extend(([32] if index else []) + member["normalizedScalars"])
                self.assertEqual(len(row["normalizedScalars"]), row["length"])
                self.assertEqual(row["normalizedScalars"], joined[:row["length"]])
                self.assertEqual(row["text"], "".join(map(chr, row["normalizedScalars"])))
            for split in SPLITS:
                for language in LANGUAGES:
                    pool = [(r["recordKey"], r["originalGroupId"], r["normalizedScalars"]) for r in
                            cap_order([r for r in originals.values() if r["split"] == split and r["language"] == language])]
                    for length in (64, 160):
                        actual = [(r["memberRecordKeys"], r["normalizedScalars"]) for r in derived
                                  if r["split"] == split and r["language"] == language and r["length"] == length]
                        with self.subTest(split=split, language=language, length=length):
                            self.assertEqual(actual, expected_concatenations(pool, length, 1000))
                            self.assertLessEqual(len(actual), len(pool))
            rule = result["augmentation"][0]
            self.assertEqual(rule, {"algorithm": "concat-v1", "splits": list(SPLITS), "lengths": [64, 160],
                                    "inputCount": len(originals), "outputCount": len(derived)})
            self.assertEqual(sum(row["augmented"] for row in result["counts"]), len(derived))
            self.assertEqual(result["augmentationRules"], [concat_rule()])

    def test_concat_caps_take_anchors_in_seeded_cap_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, examples = self.prepared(Path(temporary), rules=[concat_rule(lengths=(64,), cap=2)])
            originals = [row for row in examples if row["rule"] == "original"]
            derived = [row for row in examples if row["rule"] == "concat-v1"]
            busiest = max(((s, l) for s in SPLITS for l in LANGUAGES),
                          key=lambda key: sum(1 for r in originals if (r["split"], r["language"]) == key))
            for split in SPLITS:
                for language in LANGUAGES:
                    rows = [r for r in derived if (r["split"], r["language"]) == (split, language)]
                    self.assertLessEqual(len(rows), 2)
            pool = cap_order([r for r in originals if (r["split"], r["language"]) == busiest])
            self.assertEqual([r["recordKey"] for r in derived if (r["split"], r["language"]) == busiest],
                             [r["recordKey"] for r in pool[:2]])

    def test_concat_is_reproducible_for_shuffled_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, _ = self.prepared(root / "a")
            second, _ = self.prepared(root / "b", reverse=True)
            for name in ("examples.jsonl", "selected-sentences.tsv"):
                self.assertEqual((root / "a/out" / name).read_bytes(), (root / "b/out" / name).read_bytes(), name)
            for name in ("augmentation", "counts", "selectedSentences"):
                self.assertEqual(first[name], second[name], name)

    def test_concat_never_emits_from_insufficient_or_single_group_material(self):
        records = [(1, "ces", "Krátká věta jedna.", "Owner"), (2, "ces", "Krátká věta dvě.", "Owner"),
                   (3, "ces", "Tato jediná věta je sama o sobě delší než šedesát čtyři znaků textu.", "Owner")]
        with tempfile.TemporaryDirectory() as temporary:
            result, examples = self.prepared(Path(temporary), records=records, links=[(1, 2), (1, 3)],
                                             rules=[concat_rule(lengths=(64,))])
            self.assertEqual([row for row in examples if row["rule"] == "concat-v1"], [])
            self.assertEqual(result["augmentation"][0]["inputCount"], 3)
            self.assertEqual(result["augmentation"][0]["outputCount"], 0)

    def test_concat_config_requires_complete_nonnegative_caps(self):
        from tools.lang.prepare_corpus import _validate_config
        valid = tiny_config()
        valid["augmentation"] = [concat_rule(splits=("validation", "test")),
                                 {"algorithm": "strip-marks-v1", "splits": list(SPLITS), "lengths": []}]
        _validate_config(valid)

        def without_caps(rule):
            del rule["maxOutputs"]

        mutations = {
            "missing caps": without_caps,
            "incomplete caps": lambda rule: rule["maxOutputs"].pop(),
            "duplicate cap": lambda rule: rule["maxOutputs"].append(copy.deepcopy(rule["maxOutputs"][0])),
            "foreign split cap": lambda rule: rule["maxOutputs"][0].update(split="train"),
            "negative cap": lambda rule: rule["maxOutputs"][0].update(maxOutputsPerLength=-1),
            "boolean cap": lambda rule: rule["maxOutputs"][0].update(maxOutputsPerLength=True),
            "unknown cap key": lambda rule: rule["maxOutputs"][0].update(unexpected=1),
            "empty lengths": lambda rule: rule.update(lengths=[]),
            "unsorted lengths": lambda rule: rule.update(lengths=[160, 64]),
            "unknown rule key": lambda rule: rule.update(unexpected=1),
        }
        for name, mutation in mutations.items():
            config = copy.deepcopy(valid)
            mutation(config["augmentation"][0])
            with self.subTest(name=name), self.assertRaises(ValueError):
                _validate_config(config)
        config = copy.deepcopy(valid)
        config["augmentation"][1]["maxOutputs"] = []
        with self.assertRaises(ValueError):
            _validate_config(config)


class SelectedSentenceLedgerTests(OfflineTests):
    def test_prepare_writes_hash_pinned_selected_sentence_ledger(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = tiny_corpus(root / "data")
            result = prepare(root / "data", lock, tiny_config(), root / "out")
            originals = [row for row in read_examples(root / "out") if row["rule"] == "original"]
            raw = (root / "out/selected-sentences.tsv").read_bytes()
            expected = "".join(f"{key.split(':', 1)[1]}\t{row['language']}\t{row['licenseId']}\t{row['contributor']}\n"
                               for key, row in sorted(((r["recordKey"], r) for r in originals),
                                                      key=lambda item: int(item[0].split(":", 1)[1])))
            self.assertEqual(raw.decode("utf-8"), expected)
            self.assertEqual(result["selectedSentences"], {"path": "selected-sentences.tsv",
                                                           "records": len(originals),
                                                           "sha256": hashlib.sha256(raw).hexdigest()})


def wp1_copy_repository(root):
    """Create a local Git fixture so snapshot revision and URL assertions are real."""
    root = Path(root)
    destination = root / "eval/multilingual"
    shutil.copytree(ROOT / "eval/multilingual", destination)
    env = dict(os.environ, GIT_AUTHOR_DATE="2026-10-09T10:00:00Z", GIT_COMMITTER_DATE="2026-10-09T10:00:00Z")
    commands = [["init", "-q"], ["config", "user.email", "fixture@example.invalid"],
                ["config", "user.name", "Fixture"],
                ["remote", "add", "origin", "git@github.com:example/notebook.git"],
                ["add", "eval/multilingual"], ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "invented snapshot"]]
    for command in commands:
        subprocess.run(["git", *command], cwd=root, env=env, check=True, capture_output=True)
    return destination


class WP1SnapshotTests(OfflineTests):
    def test_real_cp1250_and_mixed_documents_preserve_original_text(self):
        root = ROOT / "eval/multilingual"
        actual = snapshot_wp1(root)
        repeated = snapshot_wp1(root)
        self.assertEqual(json.dumps(actual, sort_keys=True).encode(), json.dumps(repeated, sort_keys=True).encode())
        self.assertEqual((actual["contract"], actual["version"]), ("wp1-detector-documents", 1))
        self.assertEqual(len(actual["documents"]), 44)
        manifest = json.loads((root / "manifest.json").read_text())
        expected = next(row for row in manifest["documents"] if row["encoding"] == "windows-1250")
        document = next(row for row in actual["documents"] if row["documentId"] == expected["document_id"])
        self.assertEqual(document["text"], (root / expected["path"]).read_bytes().decode("windows-1250"))
        self.assertEqual(document["sha256"], expected["raw_sha256"])
        self.assertEqual(document["encoding"], "windows-1250")
        self.assertEqual(document["sourceId"], "multilingual-v1")
        self.assertEqual(document["licenseId"], "MIT")
        self.assertEqual(sum(row["goldLabel"] == "mixed" for row in actual["documents"]), 4)
        revision = subprocess.check_output(["git", "log", "-1", "--format=%H", "--", "eval/multilingual"], cwd=ROOT, text=True).strip()
        self.assertEqual(actual["sourceRevision"], revision)
        self.assertIn(f"/{revision}/eval/multilingual/", document["url"])
        self.assertTrue(document["url"].startswith("https://raw.githubusercontent.com/"))

    def test_modified_original_hash_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            manifest = json.loads((root / "manifest.json").read_text())
            (root / manifest["documents"][0]["path"]).write_bytes(b"modified original")
            with self.assertRaisesRegex(ValueError, "SHA-256|hash"):
                snapshot_wp1(root)

    def test_modified_file_and_manifest_cannot_claim_commit_pinned_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            manifest = json.loads((root / "manifest.json").read_text())
            row = manifest["documents"][0]
            raw = b"Modified file with matching uncommitted manifest hashes.\n"
            (root / row["path"]).write_bytes(raw)
            row["raw_sha256"] = row["content_hash"] = hashlib.sha256(raw).hexdigest()
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "revision|commit|SHA-256|hash"):
                snapshot_wp1(root)

    def test_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            manifest = json.loads((root / "manifest.json").read_text())
            manifest["documents"][0]["path"] = "../outside.txt"
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                snapshot_wp1(root)

    def test_missing_gold_label_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            manifest = json.loads((root / "manifest.json").read_text())
            del manifest["documents"][0]["language"]
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                snapshot_wp1(root)

    def test_und_label_and_ssh_origin_use_commit_pinned_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            manifest = json.loads((root / "manifest.json").read_text())
            manifest["documents"][0]["language"] = "und"
            (root / "manifest.json").write_text(json.dumps(manifest))
            snapshot = snapshot_wp1(root)
            document = next(row for row in snapshot["documents"] if row["documentId"] == manifest["documents"][0]["document_id"])
            self.assertEqual(document["goldLabel"], "und")
            self.assertTrue(document["url"].startswith(f"https://raw.githubusercontent.com/example/notebook/{snapshot['sourceRevision']}/"))
            self.assertEqual(snapshot["snapshotDate"], "2026-10-09")

    def test_ambiguous_inventory_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            shutil.copyfile(root / "manifest.json", root / "second-inventory.json")
            with self.assertRaises(ValueError):
                snapshot_wp1(root)

    def test_unknown_inventory_schema_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            manifest = json.loads((root / "manifest.json").read_text())
            manifest["contract"] = "unknown-inventory"
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                snapshot_wp1(root)

    def test_duplicate_inventory_key_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            path = root / "manifest.json"
            path.write_text('{"contract":"eval-corpus",' + path.read_text().lstrip()[1:])
            with self.assertRaisesRegex(ValueError, "duplicate"):
                snapshot_wp1(root)

    def test_unknown_origin_host_requires_explicit_source_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = wp1_copy_repository(temporary)
            subprocess.run(["git", "remote", "set-url", "origin", "https://example.invalid/notebook.git"],
                           cwd=temporary, check=True, capture_output=True)
            with self.assertRaises(ValueError):
                snapshot_wp1(root)


if __name__ == "__main__":
    unittest.main()
