"""Acquisition tests use invented exports and injected readers, never the network."""

import bz2
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from tools.lang.pin_tatoeba import SOURCE_FILES, locked, pin_current


ROOT = Path(__file__).resolve().parents[3]


def tar_bytes(name, raw, kind="regular"):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:bz2") as archive:
        info = tarfile.TarInfo(name)
        info.size = len(raw)
        if kind == "symlink":
            info.type, info.linkname, info.size = tarfile.SYMTYPE, "outside.tsv", 0
        archive.addfile(info, io.BytesIO(raw) if kind != "symlink" else None)
        if kind == "extra":
            archive.addfile(tarfile.TarInfo("extra.tsv"), io.BytesIO())
    return buffer.getvalue()


def invented_exports():
    languages = ["ces", "deu", "eng", "slk", "fra", "hrv", "hun", "nld", "pol", "slv"]
    records = [(index + 1, lang, f"Wholly invented {lang} sentence.") for index, lang in enumerate(languages)]
    payloads = {}
    for entry in SOURCE_FILES:
        role, url = entry["role"], entry["url"]
        if role == "base":
            raw = "".join(f"{i}\t\\N\n" for i, _, _ in records).encode()
            payloads[url] = tar_bytes("sentences_base.csv", raw)
        elif role == "links":
            payloads[url] = tar_bytes("links.csv", b"1\t99\n99\t2\n")
        elif role == "cc0":
            payloads[url] = tar_bytes("sentences_CC0.csv", b"1\tces\tWholly invented ces sentence.\t2026-10-09 00:00:00\n")
        else:
            language = url.split("/")[-2]
            i, lang, text = next(row for row in records if row[1] == language)
            raw = f"{i}\t{lang}\t{text}\tOwner_{lang}\t2026-10-01 00:00:00\t2026-10-09 00:00:00\n".encode()
            payloads[url] = bz2.compress(raw)
    return payloads


def injected_readers(payloads):
    calls = []

    def download(url, destination):
        calls.append(url)
        Path(destination).write_bytes(payloads[url])

    def metadata(url):
        return {"byteCount": len(payloads[url]), "lastModified": "Fri, 09 Oct 2026 00:00:00 GMT",
                "etag": '"invented-fixed-export"'}

    return download, metadata, calls


def skewed_exports(detail_count=200):
    """Two skewed IDs, with enough detailed rows for the default 1% limit."""
    payloads = invented_exports()
    payloads[SOURCE_FILES[0]["url"]] = tar_bytes("sentences_base.csv",
        b"".join(f"{number}\t\\N\n".encode() for number in range(1, detail_count + 1) if number != 10))
    payloads[SOURCE_FILES[2]["url"]] = tar_bytes("sentences_CC0.csv",
        b"1\tces\tRecently changed CC0 text.\t2026-10-09 00:00:00\n")
    english = next(row["url"] for row in SOURCE_FILES if "/eng/" in row["url"])
    payloads[english] = bz2.compress(bz2.decompress(payloads[english]) + b"".join(
        f"{number}\teng\tInvented additional sentence {number}.\tOwner_eng\t2026-10-01 00:00:00\t2026-10-09 00:00:00\n".encode()
        for number in range(11, detail_count + 1)))
    return payloads


class FetchTests(unittest.TestCase):
    def setUp(self):
        for name in ("socket.socket", "socket.create_connection", "urllib.request.urlopen",
                     "tools.lang.pin_tatoeba._download", "tools.lang.pin_tatoeba._metadata"):
            patcher = patch(name, side_effect=AssertionError("network forbidden in acquisition tests"))
            patcher.start()
            self.addCleanup(patcher.stop)

    def capture(self, root, payloads=None):
        payloads = invented_exports() if payloads is None else payloads
        download, metadata, calls = injected_readers(payloads)
        lock = pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
        return lock, payloads, calls

    def test_locked_requires_existing_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "lock"):
                locked(root / "data", root / "missing.json")

    def test_capture_records_exact_hashes_members_and_offline_reverification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, payloads, calls = self.capture(root)
            self.assertEqual(len(lock["files"]), 13)
            self.assertEqual(len(calls), 13)
            self.assertEqual(lock["snapshotDate"], "2026-10-09")
            self.assertEqual(lock["contract"], "tatoeba-inputs")
            self.assertEqual({row["url"] for row in lock["files"]}, set(payloads))
            for entry in lock["files"]:
                self.assertEqual(entry["sha256"], hashlib.sha256(payloads[entry["url"]]).hexdigest())
                self.assertEqual(entry["byteCount"], len(payloads[entry["url"]]))
                self.assertEqual((root / "data" / entry["localPath"]).read_bytes(), payloads[entry["url"]])
                if entry["role"] == "sentences":
                    self.assertIsNone(entry["memberPath"])
                    raw = bz2.decompress(payloads[entry["url"]])
                else:
                    self.assertTrue(entry["memberPath"].endswith(".csv"))
                    with tarfile.open(fileobj=io.BytesIO(payloads[entry["url"]]), mode="r:bz2") as archive:
                        raw = archive.extractfile(entry["memberPath"]).read()
                self.assertEqual(entry["uncompressedSha256"], hashlib.sha256(raw).hexdigest())
            before = (root / "lock.json").read_bytes()
            self.assertEqual(locked(root / "data", root / "lock.json"), lock)
            self.assertEqual((root / "lock.json").read_bytes(), before)

    def test_capture_is_deterministic_in_two_directories(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            self.capture(Path(a))
            self.capture(Path(b))
            self.assertEqual((Path(a) / "lock.json").read_bytes(), (Path(b) / "lock.json").read_bytes())

    def test_real_two_field_base_sample_is_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            raw = b"2\t\\N\n3\t\\N\n"
            payloads[SOURCE_FILES[0]["url"]] = tar_bytes("sentences_base.csv", raw)
            for entry in SOURCE_FILES:
                if entry["role"] == "cc0":
                    payloads[entry["url"]] = tar_bytes("sentences_CC0.csv", b"")
                elif entry["role"] == "sentences" and entry["url"].split("/")[-2] not in ("deu", "eng"):
                    payloads[entry["url"]] = bz2.compress(b"")
            lock, _, _ = self.capture(root, payloads)
            base = next(row for row in lock["files"] if row["role"] == "base")
            self.assertEqual(base["memberPath"], "sentences_base.csv")
            self.assertEqual(base["uncompressedSha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual(locked(root / "data", root / "lock.json"), lock)

    def test_canonical_base_ids_and_numeric_references_are_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            # References need not have their own base row; they do not add graph evidence.
            raw = b"0\t\\N\n1\t0\n2\t9223372036854775807\n2\t9223372036854775807\n"
            raw += b"".join(f"{number}\t1\n".encode() for number in range(3, 11))
            payloads[SOURCE_FILES[0]["url"]] = tar_bytes("sentences_base.csv", raw)
            lock, _, _ = self.capture(root, payloads)
            self.assertEqual(locked(root / "data", root / "lock.json"), lock)

    def test_malformed_base_fields_or_ids_are_rejected(self):
        malformed = [b"1\n", b"1\tces\tText.\n", b"01\t\\N\n", b"-1\t\\N\n",
                     b"9223372036854775808\t\\N\n", b"1\t\n", b"1\t01\n", b"1\t-1\n",
                     b"1\t+1\n", b"1\t1.0\n", b"1\t 1\n", b"1\t\\n\n",
                     b"1\t9223372036854775808\n"]
        for raw in malformed:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                payloads = invented_exports()
                payloads[SOURCE_FILES[0]["url"]] = tar_bytes("sentences_base.csv", raw)
                with self.assertRaisesRegex(ValueError, "field count|sentence ID"):
                    self.capture(root, payloads)
                self.assertFalse((root / "lock.json").exists())

    def test_conflicting_duplicate_base_references_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            raw = b"".join(f"{number}\t\\N\n".encode() for number in range(1, 11)) + b"1\t2\n"
            payloads[SOURCE_FILES[0]["url"]] = tar_bytes("sentences_base.csv", raw)
            with self.assertRaisesRegex(ValueError, "conflicting duplicate sentence ID"):
                self.capture(root, payloads)
            self.assertFalse((root / "lock.json").exists())

    def test_missing_base_rows_above_skew_limit_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            raw = b"".join(f"{number}\t\\N\n".encode() for number in range(1, 10))
            payloads[SOURCE_FILES[0]["url"]] = tar_bytes("sentences_base.csv", raw)
            with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                self.capture(root, payloads)
            self.assertFalse((root / "lock.json").exists())

    def test_snapshot_skew_at_one_percent_is_recorded_and_locked_replays_hashes_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, _, _ = self.capture(root, skewed_exports())
            self.assertEqual(lock["snapshotSkew"], {
                "missingFromBase": 1, "cc0DetailMismatch": 1,
                "excludedIdsSha256": hashlib.sha256(b"1\n10").hexdigest(), "sampleIds": [1, 10]})
            with patch("tools.lang.pin_tatoeba._validate_snapshot", side_effect=AssertionError("locked only verifies hashes")):
                self.assertEqual(locked(root / "data", root / "lock.json"), lock)

    def test_snapshot_skew_just_above_one_percent_is_rejected_and_keeps_all_exports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = skewed_exports(199)
            with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                self.capture(root, payloads)
            self.assertFalse((root / "lock.json").exists())
            for row in SOURCE_FILES:
                self.assertEqual((root / "data/.cache" / row["localPath"]).read_bytes(), payloads[row["url"]])

    def test_configured_skew_limit_allows_retry_from_cached_exports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = skewed_exports(10)
            with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                self.capture(root, payloads)
            config = json.loads((ROOT / "tools/lang/training-v1.json").read_text())
            config["maxSnapshotSkewBp"] = 2000
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config))
            download, metadata, calls = injected_readers(payloads)
            lock = pin_current(root / "data", root / "lock.json", config_path=config_path,
                               downloader=download, metadata_reader=metadata)
            self.assertEqual(lock["snapshotSkew"]["sampleIds"], [1, 10])
            self.assertEqual(calls, [])

    def test_legacy_lock_without_skew_summary_remains_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, _, _ = self.capture(root)
            del lock["snapshotSkew"]
            (root / "lock.json").write_text(json.dumps(lock))
            self.assertEqual(locked(root / "data", root / "lock.json"), lock)

    def test_missing_cached_export_downloads_only_pinned_missing_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, payloads, _ = self.capture(root)
            missing = lock["files"][-1]
            (root / "data" / missing["localPath"]).unlink()
            download, _, calls = injected_readers(payloads)
            before = (root / "lock.json").read_bytes()
            self.assertEqual(locked(root / "data", root / "lock.json", downloader=download), lock)
            self.assertEqual(calls, [missing["url"]])
            self.assertEqual((root / "lock.json").read_bytes(), before)

    def test_changed_cached_bytes_fail_before_missing_file_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, payloads, _ = self.capture(root)
            entry = lock["files"][0]
            path = root / "data" / entry["localPath"]
            raw = path.read_bytes()
            path.write_bytes(bytes([raw[0] ^ 1]) + raw[1:])
            (root / "data" / lock["files"][-1]["localPath"]).unlink()
            download, _, calls = injected_readers(payloads)
            with self.assertRaisesRegex(ValueError, "SHA-256|hash"):
                locked(root / "data", root / "lock.json", downloader=download)
            self.assertEqual(calls, [])

    def test_changed_download_does_not_repin_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, payloads, _ = self.capture(root)
            entry = lock["files"][-1]
            (root / "data" / entry["localPath"]).unlink()
            payloads[entry["url"]] = bz2.compress(b"changed upstream bytes\n")
            download, _, _ = injected_readers(payloads)
            before = (root / "lock.json").read_bytes()
            with self.assertRaisesRegex(ValueError, "SHA-256|hash|byteCount"):
                locked(root / "data", root / "lock.json", downloader=download)
            self.assertEqual((root / "lock.json").read_bytes(), before)
            self.assertFalse((root / "data" / entry["localPath"]).exists())

    def test_changed_uncompressed_hash_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, _, _ = self.capture(root)
            lock["files"][0]["uncompressedSha256"] = "0" * 64
            (root / "lock.json").write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, "uncompressed.*(SHA-256|hash)"):
                locked(root / "data", root / "lock.json")

    def test_changed_metadata_fails_without_writing_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            download, metadata, _ = injected_readers(payloads)
            seen = {}

            def changed(url):
                seen[url] = seen.get(url, 0) + 1
                result = metadata(url)
                if seen[url] > 1:
                    result["etag"] = '"changed-upstream"'
                return result

            with self.assertRaisesRegex(ValueError, "changed|metadata|snapshot"):
                pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=changed)
            self.assertFalse((root / "lock.json").exists())

    def test_different_week_exports_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            download, metadata, _ = injected_readers(invented_exports())

            def stale(url):
                result = metadata(url)
                if url == SOURCE_FILES[-1]["url"]:
                    result["lastModified"] = "Fri, 25 Sep 2026 00:00:00 GMT"
                return result

            with self.assertRaisesRegex(ValueError, "week|snapshot"):
                pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=stale)
            self.assertFalse((root / "lock.json").exists())

    def test_incomplete_acquisition_never_writes_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            download, metadata, _ = injected_readers(invented_exports())

            def interrupted(url, destination):
                if url == SOURCE_FILES[-1]["url"]:
                    raise OSError("injected offline acquisition failure")
                download(url, destination)

            with self.assertRaises(OSError):
                pin_current(root / "data", root / "lock.json", downloader=interrupted, metadata_reader=metadata)
            self.assertFalse((root / "lock.json").exists())

    def cache_after_validation_failure(self, root, payloads=None):
        payloads = invented_exports() if payloads is None else payloads
        download, metadata, calls = injected_readers(payloads)
        with patch("tools.lang.pin_tatoeba._validate_snapshot", side_effect=ValueError("injected validation failure")):
            with self.assertRaisesRegex(ValueError, "injected validation failure"):
                pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
        self.assertEqual(len(calls), 13)
        self.assertFalse((root / "lock.json").exists())
        return payloads

    def test_validation_failure_keeps_downloads_and_retry_reuses_matching_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = self.cache_after_validation_failure(root)
            for entry in SOURCE_FILES:
                self.assertEqual((root / "data/.cache" / entry["localPath"]).read_bytes(), payloads[entry["url"]])
            download, metadata, calls = injected_readers(payloads)
            lock = pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
            self.assertEqual(calls, [])
            self.assertEqual(len(lock["files"]), 13)

    def test_reuse_staging_revalidates_complete_cache_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.cache_after_validation_failure(root)
            # setUp forbids the default download and metadata readers.
            lock = pin_current(root / "data", root / "lock.json", reuse_staging=True)
            self.assertEqual(len(lock["files"]), 13)

    def test_metadata_change_redownloads_only_changed_export(self):
        for field in ("etag", "lastModified", "byteCount"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                payloads = self.cache_after_validation_failure(root)
                changed_url = SOURCE_FILES[1]["url"]
                if field == "byteCount":
                    payloads[changed_url] = tar_bytes("links.csv", b"1\t99\n99\t2\n2\t3\n3\t4\n")
                download, metadata, calls = injected_readers(payloads)

                def changed(url):
                    result = metadata(url)
                    if url == changed_url and field != "byteCount":
                        result[field] = '"new-export"' if field == "etag" else "Fri, 09 Oct 2026 01:00:00 GMT"
                    return result

                lock = pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=changed)
                self.assertEqual(calls, [changed_url])
                entry = next(row for row in lock["files"] if row["url"] == changed_url)
                self.assertEqual(entry[field], changed(changed_url)[field])

    def test_tampered_cache_is_rehashed_before_reuse(self):
        for reuse_staging in (False, True):
            with self.subTest(reuse_staging=reuse_staging), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                payloads = self.cache_after_validation_failure(root)
                entry = SOURCE_FILES[0]
                path = root / "data/.cache" / entry["localPath"]
                raw = path.read_bytes()
                path.write_bytes(bytes([raw[0] ^ 1]) + raw[1:])
                download, metadata, calls = injected_readers(payloads)
                lock = pin_current(root / "data", root / "lock.json", downloader=download,
                                   metadata_reader=metadata, reuse_staging=reuse_staging)
                self.assertEqual(calls, [entry["url"]])
                self.assertEqual(len(lock["files"]), 13)

    def test_partial_download_is_retained_but_never_reused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            download, metadata, calls = injected_readers(payloads)
            missing = SOURCE_FILES[-1]

            def interrupted(url, destination):
                if url == missing["url"]:
                    Path(destination).write_bytes(payloads[url][:10])
                    raise OSError("injected interrupted download")
                download(url, destination)

            with self.assertRaisesRegex(OSError, "interrupted download"):
                pin_current(root / "data", root / "lock.json", downloader=interrupted, metadata_reader=metadata)
            self.assertEqual(len(calls), 12)
            cache = root / "data/.cache"
            self.assertEqual((cache / (missing["localPath"] + ".part")).read_bytes(), payloads[missing["url"]][:10])
            self.assertFalse((cache / missing["localPath"]).exists())
            self.assertFalse((cache / (missing["localPath"] + ".json")).exists())
            calls.clear()
            pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
            self.assertEqual(calls, [missing["url"]])

    def test_failed_refresh_preserves_previous_complete_cache_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = self.cache_after_validation_failure(root)
            _, metadata, _ = injected_readers(payloads)
            entry = SOURCE_FILES[0]

            def changed(url):
                return {**metadata(url), "etag": '"new-export"'}

            def interrupted(url, destination):
                Path(destination).write_bytes(b"partial replacement")
                raise OSError("injected interrupted refresh")

            with self.assertRaisesRegex(OSError, "interrupted refresh"):
                pin_current(root / "data", root / "lock.json", downloader=interrupted, metadata_reader=changed)
            self.assertEqual((root / "data/.cache" / entry["localPath"]).read_bytes(), payloads[entry["url"]])
            lock = pin_current(root / "data", root / "lock.json", reuse_staging=True)
            self.assertEqual(len(lock["files"]), 13)

    def test_incomplete_unknown_duplicate_or_foreign_lock_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, _, _ = self.capture(root)
            mutations = [
                lambda lock: lock["files"].pop(),
                lambda lock: lock.update(unknown=1),
                lambda lock: lock["files"][0].update(unknown=1),
                lambda lock: lock["files"][0].update(url="https://example.invalid/sentences_base.tar.bz2"),
                lambda lock: lock["files"][0].update(url="https://downloads.tatoeba.org/exports/unapproved.tar.bz2"),
                lambda lock: lock["files"][0].update(localPath="../outside.bz2"),
                lambda lock: lock["files"][0].update(role="unknown"),
                lambda lock: lock["files"].append(copy.deepcopy(lock["files"][0])),
                lambda lock: lock.update(version=True),
                lambda lock: lock["files"][0].update(byteCount=True),
                lambda lock: lock.update(snapshotSkew={}),
                lambda lock: lock["snapshotSkew"].update(missingFromBase=True),
                lambda lock: lock["snapshotSkew"].update(excludedIdsSha256="0"),
                lambda lock: lock["snapshotSkew"].update(sampleIds=[2, 1]),
            ]
            for index, mutation in enumerate(mutations):
                with self.subTest(mutation=index):
                    lock = copy.deepcopy(original)
                    mutation(lock)
                    (root / "lock.json").write_text(json.dumps(lock))
                    with self.assertRaises(ValueError):
                        locked(root / "data", root / "lock.json")
            (root / "lock.json").write_text('{"version":1,' + json.dumps(original)[1:])
            with self.assertRaisesRegex(ValueError, "duplicate"):
                locked(root / "data", root / "lock.json")

    def test_tar_traversal_symlink_and_extra_member_fail(self):
        for kind in ["traversal", "symlink", "extra"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                payloads = invented_exports()
                name = "../outside.csv" if kind == "traversal" else "sentences_base.csv"
                payloads[SOURCE_FILES[0]["url"]] = tar_bytes(name, b"1\t\\N\n", kind)
                download, metadata, _ = injected_readers(payloads)
                with self.assertRaises(ValueError):
                    pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
                self.assertFalse((root / "lock.json").exists())

    def test_cc0_or_detailed_text_mismatch_rejected(self):
        for role in ["cc0", "sentences"]:
            with self.subTest(role=role), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                payloads = invented_exports()
                entry = next(row for row in SOURCE_FILES if row["role"] == role)
                if role == "cc0":
                    payloads[entry["url"]] = tar_bytes("sentences_CC0.csv", b"1\tces\tWrong CC0 text.\t2026-10-09 00:00:00\n")
                else:
                    raw = bz2.decompress(payloads[entry["url"]]).replace(b"Wholly invented", b"Changed invented")
                    payloads[entry["url"]] = bz2.compress(raw)
                download, metadata, _ = injected_readers(payloads)
                with self.assertRaisesRegex(ValueError, "snapshot|mismatch"):
                    pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
                self.assertFalse((root / "lock.json").exists())

    def test_cc0_modification_skew_above_limit_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            entry = next(row for row in SOURCE_FILES if row["role"] == "cc0")
            # Text/IDs and all HEAD responses agree, but this CC0 export is stale.
            payloads[entry["url"]] = tar_bytes("sentences_CC0.csv",
                b"1\tces\tWholly invented ces sentence.\t2026-10-02 00:00:00\n")
            download, metadata, _ = injected_readers(payloads)
            with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
            self.assertFalse((root / "lock.json").exists())

    def test_cc0_language_skew_above_limit_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            entry = next(row for row in SOURCE_FILES if row["role"] == "cc0")
            payloads[entry["url"]] = tar_bytes("sentences_CC0.csv",
                b"1\teng\tWholly invented ces sentence.\t2026-10-09 00:00:00\n")
            with self.assertRaisesRegex(ValueError, "snapshot skew exceeds"):
                self.capture(root, payloads)
            self.assertFalse((root / "lock.json").exists())

    def test_truncated_compressed_tar_is_rejected_before_lock_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = invented_exports()
            # TAR's end marker can precede the missing bzip2 integrity trailer.
            url = SOURCE_FILES[0]["url"]
            payloads[url] = payloads[url][:-5]
            download, metadata, _ = injected_readers(payloads)
            with self.assertRaisesRegex(ValueError, "compressed export"):
                pin_current(root / "data", root / "lock.json", downloader=download, metadata_reader=metadata)
            self.assertFalse((root / "lock.json").exists())

    def test_cli_help_and_shell_syntax(self):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "tools/lang/pin_tatoeba.py"), "--help"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for flag in ["--pin-current", "--locked", "--data-dir", "--lock", "--reuse-staging", "--config"]:
            self.assertIn(flag, result.stdout)
        result = subprocess.run(["bash", "-n", str(ROOT / "tools/lang/fetch_tatoeba.sh")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
