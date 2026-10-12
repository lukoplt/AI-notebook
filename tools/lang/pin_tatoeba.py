"""Explicit Tatoeba acquisition; offline preparation never imports this module.

Mutable upstream exports are trusted only during an approved --pin-current run.
Locked replay preserves the captured compressed bytes, hashes and metadata.
"""

import argparse
import bz2
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.lang.prepare_corpus import (
    _insert_sentence, _tsv, _validate_config, contained, json_bytes, read_json, sentence_id, sha_file,
    snapshot_skew, snapshot_skew_limit, validate_snapshot_skew, verified_inputs,
)


EXPORT_ROOT = "https://downloads.tatoeba.org/exports/"
LANGUAGES = ("ces", "deu", "eng", "slk", "fra", "hrv", "hun", "nld", "pol", "slv")
SOURCE_FILES = (
    {"role": "base", "url": EXPORT_ROOT + "sentences_base.tar.bz2",
     "localPath": "sentences_base.tar.bz2", "formatVersion": "tatoeba-base-v1"},
    {"role": "links", "url": EXPORT_ROOT + "links.tar.bz2",
     "localPath": "links.tar.bz2", "formatVersion": "tatoeba-links-v1"},
    {"role": "cc0", "url": EXPORT_ROOT + "sentences_CC0.tar.bz2",
     "localPath": "sentences_CC0.tar.bz2", "formatVersion": "tatoeba-cc0-v1"},
) + tuple({"role": "sentences", "url": EXPORT_ROOT + f"per_language/{lang}/{lang}_sentences_detailed.tsv.bz2",
           "localPath": f"{lang}_sentences_detailed.tsv.bz2", "formatVersion": "tatoeba-detailed-v1"}
          for lang in LANGUAGES)
LOCK_FIELDS = {"contract", "version", "sourceId", "snapshotDate", "files"}
FILE_FIELDS = {"role", "url", "localPath", "sha256", "uncompressedSha256", "formatVersion",
               "memberPath", "byteCount", "lastModified", "etag"}
METADATA_FIELDS = {"byteCount", "lastModified", "etag"}
DEFAULT_CONFIG = Path(__file__).with_name("training-v1.json")


def _date(value):
    if not isinstance(value, str):
        raise ValueError("invalid snapshot date")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError as error:
        raise ValueError("invalid snapshot date") from error
    if parsed.isoformat() != value:
        raise ValueError("snapshot date must be YYYY-MM-DD")
    return parsed


def _metadata_time(value):
    if not isinstance(value, str):
        raise ValueError("missing Last-Modified metadata")
    try:
        timestamp = parsedate_to_datetime(value)
        if timestamp.tzinfo is None:
            raise ValueError("Last-Modified must specify a timezone")
        return timestamp.astimezone(timezone.utc)
    except (TypeError, ValueError, OverflowError) as error:
        raise ValueError("invalid Last-Modified metadata") from error


def _check_metadata(value):
    if not isinstance(value, dict) or set(value) != METADATA_FIELDS:
        raise ValueError("incomplete or unknown export metadata")
    if type(value["byteCount"]) is not int or value["byteCount"] <= 0 or not isinstance(value["etag"], str):
        raise ValueError("invalid export metadata numeric/string types")
    _metadata_time(value["lastModified"])
    return dict(value)


def _snapshot_date(metadata):
    dates = [_metadata_time(row["lastModified"]) for row in metadata]
    if not dates or max(dates) - min(dates) >= timedelta(days=7):
        raise ValueError("export metadata spans incompatible weekly snapshots")
    return max(dates).date().isoformat()


def _member_path(member):
    if not isinstance(member, str) or not member:
        raise ValueError("missing archive member path")
    # Member names are captured from archives, never guessed from URL suffixes.
    contained(Path(tempfile.gettempdir()), member)
    if PurePosixPath(member).suffix not in (".tsv", ".csv"):
        raise ValueError("archive member must contain TSV data (.tsv or .csv)")


def validate_lock(lock):
    if not isinstance(lock, dict) or set(lock) not in (LOCK_FIELDS, LOCK_FIELDS | {"snapshotSkew"}):
        raise ValueError("incomplete or unknown input lock properties")
    if lock["contract"] != "tatoeba-inputs" or type(lock["version"]) is not int or lock["version"] != 1:
        raise ValueError("unsupported input lock contract/version")
    if lock["sourceId"] != "tatoeba":
        raise ValueError("unsupported input lock source")
    if "snapshotSkew" in lock:
        validate_snapshot_skew(lock["snapshotSkew"])
    _date(lock["snapshotDate"])
    if not isinstance(lock["files"], list) or len(lock["files"]) != len(SOURCE_FILES):
        raise ValueError("lock must contain all thirteen input files")
    expected = {row["url"]: row for row in SOURCE_FILES}
    seen = set()
    for row in lock["files"]:
        if not isinstance(row, dict) or set(row) != FILE_FIELDS:
            raise ValueError("incomplete or unknown lock file properties")
        url = row["url"]
        if not isinstance(url, str) or url not in expected or url in seen:
            raise ValueError("duplicate or unapproved export URL")
        seen.add(url)
        if any(row[key] != value for key, value in expected[url].items()):
            raise ValueError("lock file role/path/schema does not match its approved URL")
        _check_metadata({key: row[key] for key in METADATA_FIELDS})
        for key in ("sha256", "uncompressedSha256"):
            if not isinstance(row[key], str) or re.fullmatch(r"[0-9a-f]{64}", row[key]) is None:
                raise ValueError("invalid SHA-256 in input lock")
        if row["role"] == "sentences":
            if row["memberPath"] is not None:
                raise ValueError("detailed sentences are plain bz2 TSV, not TAR")
        else:
            _member_path(row["memberPath"])
    if _snapshot_date(lock["files"]) != lock["snapshotDate"]:
        raise ValueError("snapshot date does not match export metadata")
    return lock


def _download(url, destination):
    if url not in {row["url"] for row in SOURCE_FILES}:
        raise ValueError("unapproved download URL")
    subprocess.run(["curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                    "--retry", "3", "--output", str(destination), url], check=True)


def _metadata(url):
    if url not in {row["url"] for row in SOURCE_FILES}:
        raise ValueError("unapproved metadata URL")
    result = subprocess.run(["curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                             "--retry", "3", "--head", "--silent", "--show-error", url],
                            check=True, capture_output=True, text=True)
    headers = {}
    for line in result.stdout.splitlines():
        if line.startswith("HTTP/"):
            headers = {}
        elif ":" in line:
            key, value = line.split(":", 1)
            headers[key.lower()] = value.strip()
    try:
        size = headers["content-length"]
        if re.fullmatch(r"[0-9]+", size) is None:
            raise ValueError("invalid Content-Length")
        return _check_metadata({"byteCount": int(size), "lastModified": headers["last-modified"],
                                "etag": headers.get("etag", "")})
    except KeyError as error:
        raise ValueError("HEAD must provide Content-Length and Last-Modified; no size/date is guessed") from error


def _inspect(path, specification, expected=None):
    path = Path(path)
    size, digest = path.stat().st_size, sha_file(path)
    if expected is not None and (size != expected["byteCount"] or digest != expected["sha256"]):
        raise ValueError(f"compressed SHA-256/byteCount mismatch: {specification['localPath']}")
    member = None
    with tempfile.TemporaryDirectory(prefix="ainotebook-tatoeba-inspect-") as temporary:
        output = Path(temporary) / "decompressed.tsv"
        try:
            if specification["role"] == "sentences":
                with bz2.open(path, "rb") as source, output.open("wb") as target:
                    shutil.copyfileobj(source, target)
            else:
                with bz2.open(path, "rb") as decoded:
                    with tarfile.open(fileobj=decoded, mode="r|") as archive:
                        for entry in archive:
                            if member is not None or not entry.isfile():
                                raise ValueError("TAR must contain exactly one regular TSV member")
                            _member_path(entry.name)
                            member = entry.name
                            if expected is not None and member != expected["memberPath"]:
                                raise ValueError("TAR member changed from input lock")
                            with archive.extractfile(entry) as source, output.open("wb") as target:
                                shutil.copyfileobj(source, target)
                        if member is None:
                            raise ValueError("TAR has no regular TSV member")
                    # TAR can finish before bzip2's trailer. Consume it to verify
                    # the compressed stream's CRC and reject a truncated export.
                    while decoded.read(1024 * 1024):
                        pass
            uncompressed = sha_file(output)
        except (OSError, EOFError, tarfile.TarError) as error:
            raise ValueError("invalid compressed export") from error
    if expected is not None and uncompressed != expected["uncompressedSha256"]:
        raise ValueError(f"uncompressed SHA-256 mismatch: {specification['localPath']}")
    return {"sha256": digest, "uncompressedSha256": uncompressed, "memberPath": member, "byteCount": size}


def _validate_snapshot(data_dir, lock, max_snapshot_skew_bp=100, languages=None):
    """Check all TSV schemas and cross-export identities with disk-backed storage."""
    with verified_inputs(data_dir, lock) as verified, tempfile.TemporaryDirectory(prefix="ainotebook-tatoeba-check-") as temporary:
        database = sqlite3.connect(Path(temporary) / "snapshot.sqlite")
        try:
            database.executescript("""
                CREATE TABLE base(id INTEGER PRIMARY KEY, base_id INTEGER);
                CREATE TABLE details(id INTEGER PRIMARY KEY, lang TEXT, text TEXT, owner TEXT, created TEXT, modified TEXT);
                CREATE TABLE cc0(id INTEGER PRIMARY KEY, lang TEXT, text TEXT, modified TEXT);
            """)
            for entry, path in verified:
                role = entry["role"]
                for fields in _tsv(path, {"base": 2, "links": 2, "cc0": 4, "sentences": 6}[role]):
                    number = sentence_id(fields[0])
                    if role == "links":
                        sentence_id(fields[1])  # Dangling endpoints are intentionally valid graph vertices.
                        continue
                    if role == "sentences" and fields[1] != entry["url"].split("/")[-2]:
                        raise ValueError("detailed export language does not match its source URL")
                    table = {"base": "base", "cc0": "cc0", "sentences": "details"}[role]
                    row = ((number, None if fields[1] == "\\N" else sentence_id(fields[1]))
                           if role == "base" else (number, *fields[1:]))
                    _insert_sentence(database, table, row)
            return snapshot_skew(database, max_snapshot_skew_bp, languages)
        finally:
            database.close()


def _cached_export(cache, specification):
    """A receipt is reusable only when its complete payload still verifies."""
    path = contained(cache, specification["localPath"])
    receipt = contained(cache, specification["localPath"] + ".json")
    if not path.is_file() or not receipt.is_file():
        return None
    try:
        row = read_json(receipt)
        if not isinstance(row, dict) or set(row) != FILE_FIELDS:
            return None
        if any(row[key] != value for key, value in specification.items()):
            return None
        _check_metadata({key: row[key] for key in METADATA_FIELDS})
        actual = _inspect(path, specification, expected=row)
        if any(row[key] != value for key, value in actual.items()):
            return None
        return row
    except (OSError, ValueError, TypeError):
        # Invalid cache entries can be repaired by acquiring them again; they
        # never become trusted just because --reuse-staging was requested.
        return None


def _cache_download(cache, specification, metadata, download):
    """Keep partial bytes on failure; publish a receipt only after full hashing."""
    relative = specification["localPath"]
    partial = contained(cache, relative + ".part")
    download(specification["url"], partial)
    actual = _inspect(partial, specification)
    if actual["byteCount"] != metadata["byteCount"]:
        raise ValueError("download byteCount changed from HEAD metadata")
    row = {**specification, **metadata, **actual}
    # An interrupted refresh must leave a previously complete cache file intact.
    partial.replace(contained(cache, relative))
    receipt = contained(cache, relative + ".json.part")
    receipt.write_bytes(json_bytes(row))
    receipt.replace(contained(cache, relative + ".json"))
    return row


def pin_current(data_dir, lock_path, *, downloader=None, metadata_reader=None, report=None,
                config_path=DEFAULT_CONFIG, reuse_staging=False):
    """Capture one explicitly approved mutable snapshot; refuse to replace a lock."""
    data_dir, lock_path = Path(data_dir), Path(lock_path)
    if lock_path.exists():
        raise ValueError("input lock already exists; pin-current never overwrites it")
    config = read_json(config_path)
    mappings, _, _, _ = _validate_config(config)
    if config["sourceId"] != "tatoeba":
        raise ValueError("pin-current requires the Tatoeba training config")
    download = _download if downloader is None else downloader
    metadata = _metadata if metadata_reader is None else metadata_reader
    data_dir.mkdir(parents=True, exist_ok=True)
    cache = contained(data_dir, ".cache")
    cache.mkdir(exist_ok=True)
    cached = {row["url"]: _cached_export(cache, row) for row in SOURCE_FILES}
    # Explicit reuse opts into the captured metadata for verified cache entries;
    # missing or corrupt entries still require fresh acquisition and HEAD checks.
    remote_urls = [row["url"] for row in SOURCE_FILES if not reuse_staging or cached[row["url"]] is None]
    before = {url: _check_metadata(metadata(url)) if url in remote_urls
              else {key: cached[url][key] for key in METADATA_FIELDS} for url in cached}
    snapshot_date = _snapshot_date(before.values())
    if report is not None:
        report(sum(row["byteCount"] for row in before.values()))
    files = []
    for specification in SOURCE_FILES:
        url = specification["url"]
        row = cached[url]
        if row is None or any(row[key] != before[url][key] for key in METADATA_FIELDS):
            row = _cache_download(cache, specification, before[url], download)
        files.append(row)
    after = {url: _check_metadata(metadata(url)) for url in remote_urls}
    if any(before[url] != after[url] for url in remote_urls):
        raise ValueError("upstream metadata changed during acquisition; no consistent snapshot")
    lock = {"contract": "tatoeba-inputs", "version": 1, "sourceId": "tatoeba",
            "snapshotDate": snapshot_date, "files": files}
    lock["snapshotSkew"] = _validate_snapshot(cache, lock, snapshot_skew_limit(config), mappings)
    validate_lock(lock)
    for row in files:
        destination = contained(data_dir, row["localPath"])
        if destination.exists() and sha_file(destination) != row["sha256"]:
            raise ValueError("refusing to replace retained cached bytes with a different snapshot")
    for row in files:
        destination = contained(data_dir, row["localPath"])
        if not destination.exists():
            source = contained(cache, row["localPath"])
            # Retain the cache after publication without duplicating export bytes.
            source.link_to(destination) if sys.version_info < (3, 10) else destination.hardlink_to(source)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=lock_path.parent, prefix=".tatoeba-lock-", delete=False) as output:
        temporary_lock = Path(output.name)
        output.write(json_bytes(lock))
    try:
        # Hard-link publication fails if another process has created this lock.
        temporary_lock.link_to(lock_path) if sys.version_info < (3, 10) else lock_path.hardlink_to(temporary_lock)
    finally:
        temporary_lock.unlink(missing_ok=True)
    return lock


def locked(data_dir, lock_path, *, downloader=None):
    """Replay a complete immutable lock, verifying cache before any acquisition."""
    data_dir, lock_path = Path(data_dir), Path(lock_path)
    if not lock_path.is_file():
        raise ValueError("locked mode requires an existing complete input lock")
    lock = validate_lock(read_json(lock_path))
    missing = []
    for row in lock["files"]:
        path = contained(data_dir, row["localPath"])
        if path.exists():
            _inspect(path, row, expected=row)
        else:
            missing.append(row)
    if missing:
        data_dir.mkdir(parents=True, exist_ok=True)
        download = _download if downloader is None else downloader
        with tempfile.TemporaryDirectory(prefix=".tatoeba-locked-", dir=data_dir) as temporary:
            staging = Path(temporary)
            for row in missing:
                destination = staging / row["localPath"]
                download(row["url"], destination)
                _inspect(destination, row, expected=row)
            for row in missing:
                (staging / row["localPath"]).replace(contained(data_dir, row["localPath"]))
    return lock


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--pin-current", action="store_true", help="Claude-only, explicitly approved initial acquisition")
    mode.add_argument("--locked", action="store_true", help="verify existing cache and retrieve only missing pinned bytes")
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                        help="training config supplying maxSnapshotSkewBp and selected languages")
    parser.add_argument("--reuse-staging", action="store_true",
                        help="reuse verified .cache exports with captured metadata instead of fresh HEAD requests")
    args = parser.parse_args()
    if args.locked and args.reuse_staging:
        parser.error("--reuse-staging is only valid with --pin-current")
    if args.pin_current:
        lock = pin_current(args.data_dir, args.lock, config_path=args.config, reuse_staging=args.reuse_staging,
                           report=lambda total: print(f"Export metadata reports {total} compressed bytes; allow additional space for decompression and preparation.", flush=True))
    else:
        lock = locked(args.data_dir, args.lock)
    print(f"Verified {len(lock['files'])} Tatoeba exports for snapshot {lock['snapshotDate']}")


if __name__ == "__main__":
    main()
