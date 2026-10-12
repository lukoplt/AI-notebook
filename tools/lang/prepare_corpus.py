"""Offline, hash-pinned corpus preparation; this module has no acquisition path."""

from array import array
import argparse
import bz2
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import itertools
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
from tools.lang.reference import UnicodeData, classify, normalize

SPLITS = ("train", "validation", "test")
BUCKETS = (0, 12, 32, 80, 200)
TABLE_PATH = ROOT / "Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json"
FORMATS = {"base": "tatoeba-base-v1", "links": "tatoeba-links-v1",
           "cc0": "tatoeba-cc0-v1", "sentences": "tatoeba-detailed-v1"}
AUGMENTATIONS = ("none-v1", "scalar-prefix-v1", "strip-marks-v1", "concat-v1")
LENGTH_AUGMENTATIONS = ("scalar-prefix-v1", "concat-v1")
SELECTED_SENTENCES = "selected-sentences.tsv"


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def read_json(path):
    def pairs(rows):
        result = {}
        for key, value in rows:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def invalid(value):
        raise ValueError(f"noninteger JSON number: {value}")

    return json.loads(Path(path).read_bytes().decode("utf-8"), object_pairs_hook=pairs,
                      parse_float=invalid, parse_constant=invalid)


def sha_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def contained(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("invalid relative path")
    p = PurePosixPath(relative)
    if p.is_absolute() or ".." in p.parts or ":" in p.parts[0]:
        raise ValueError("path traversal or absolute path")
    result = (Path(root) / p).resolve()
    if not result.is_relative_to(Path(root).resolve()):
        raise ValueError("path escapes containment")
    return result


def sentence_id(value):
    if not isinstance(value, str) or re.fullmatch(r"0|[1-9][0-9]*", value) is None:
        raise ValueError(f"noncanonical sentence ID: {value!r}")
    number = int(value)
    if number > 9223372036854775807:
        raise ValueError("sentence ID exceeds signed 64-bit storage")
    return number


def group_id(record_keys: list[str]) -> str:
    keys = sorted(set(record_keys), key=lambda key: key.encode("utf-8"))
    return hashlib.sha256(("\n".join(keys) + "\n").encode("utf-8")).hexdigest()


class _UnionFind:
    """Integer-only graph; sentence texts and sorted membership live on disk."""
    def __init__(self):
        self.index = {}
        self.parents, self.sizes, self.ids = array("q"), array("q"), array("q")

    def add(self, number):
        if number not in self.index:
            i = len(self.parents)
            self.index[number] = i
            self.parents.append(i)
            self.sizes.append(1)
            self.ids.append(number)
        return self.index[number]

    def root(self, i):
        while self.parents[i] != i:
            self.parents[i] = self.parents[self.parents[i]]
            i = self.parents[i]
        return i

    def union(self, a, b):
        a, b = self.root(self.add(a)), self.root(self.add(b))
        if a == b:
            return
        if self.sizes[a] < self.sizes[b]:
            a, b = b, a
        self.parents[b] = a
        self.sizes[a] += self.sizes[b]


def build_components(source_id: str, sentence_ids: list[int], links: list[tuple[int, int]]) -> list[dict]:
    if re.fullmatch(r"[A-Za-z0-9_-]+", source_id) is None:
        raise ValueError("invalid source ID")
    graph = _UnionFind()
    for number in sentence_ids:
        graph.add(sentence_id(str(number)))
    for a, b in links:
        graph.union(sentence_id(str(a)), sentence_id(str(b)))
    groups = {}
    for number, i in graph.index.items():
        groups.setdefault(graph.root(i), []).append(f"{source_id}:{number}")
    output = [{"keys": sorted(keys, key=lambda key: key.encode("utf-8")), "groupId": group_id(keys)}
              for keys in groups.values()]
    return sorted(output, key=lambda row: row["groupId"])


def split_group(group: str, seed: int, split_bp: tuple[int, int, int]) -> str:
    if len(split_bp) != 3 or any(type(x) is not int or x <= 0 for x in split_bp) or sum(split_bp) != 10000:
        raise ValueError("splitBp must be positive and sum to 10000")
    if type(seed) is not int or seed < 0:
        raise ValueError("seed must be a nonnegative integer")
    digest = hashlib.sha256(f"{seed}\n{group}\n".encode()).digest()
    slot = int.from_bytes(digest[:8], "big") % 10000
    return "train" if slot < split_bp[0] else "validation" if slot < split_bp[0] + split_bp[1] else "test"


@contextmanager
def verified_inputs(data_dir: Path, lock: dict):
    """Verify every compressed/decompressed hash before a parser sees any text."""
    if lock.get("contract") != "tatoeba-inputs" or lock.get("version") != 1:
        raise ValueError("invalid input lock")
    datetime.strptime(lock["snapshotDate"], "%Y-%m-%d")
    paths = set()
    with tempfile.TemporaryDirectory(prefix="ainotebook-lang-inputs-") as temporary:
        verified = []
        for index, entry in enumerate(lock["files"]):
            if entry["localPath"] in paths:
                raise ValueError("duplicate lock file path")
            paths.add(entry["localPath"])
            if entry["role"] not in FORMATS or entry["formatVersion"] != FORMATS[entry["role"]]:
                raise ValueError("unsupported TSV schema")
            source = contained(data_dir, entry["localPath"])
            if source.stat().st_size != entry["byteCount"] or sha_file(source) != entry["sha256"]:
                raise ValueError(f"compressed SHA-256/byteCount mismatch: {entry['localPath']}")
            destination = Path(temporary) / str(index)
            member = entry["memberPath"]
            if member:
                contained(temporary, member)
                with tarfile.open(source, mode="r|bz2") as archive:
                    found = False
                    for item in archive:
                        if found or not item.isfile() or item.name != member:
                            raise ValueError("archive must contain exactly one expected regular TSV member")
                        contained(temporary, item.name)
                        with archive.extractfile(item) as stream, destination.open("wb") as output:
                            shutil.copyfileobj(stream, output)
                        found = True
                    if not found:
                        raise ValueError("missing archive member")
            else:
                with bz2.open(source, "rb") as stream, destination.open("wb") as output:
                    shutil.copyfileobj(stream, output)
            if sha_file(destination) != entry["uncompressedSha256"]:
                raise ValueError(f"uncompressed SHA-256 mismatch: {entry['localPath']}")
            verified.append((entry, destination))
        yield verified


def _tsv(path, fields):
    with Path(path).open(encoding="utf-8", errors="strict", newline="") as stream:
        for index, line in enumerate(stream, 1):
            # Remove the record terminator only; leading/trailing text spaces survive.
            row = line.removesuffix("\n").removesuffix("\r").split("\t")
            if len(row) != fields:
                raise ValueError(f"invalid TSV field count at {path.name}:{index}; expected {fields}")
            yield row


def _insert_sentence(db, table, row):
    number, *values = row
    existing = db.execute(f"SELECT * FROM {table} WHERE id=?", (number,)).fetchone()
    if existing is not None:
        if tuple(row) != existing:
            raise ValueError(f"conflicting duplicate sentence ID {number}")
        return
    db.execute(f"INSERT INTO {table} VALUES ({','.join('?' for _ in row)})", row)


def snapshot_skew_limit(config):
    limit = config.get("maxSnapshotSkewBp", 100)
    if type(limit) is not int or not 0 <= limit <= 10000:
        raise ValueError("maxSnapshotSkewBp must be an integer between 0 and 10000")
    return limit


def validate_snapshot_skew(summary):
    fields = {"missingFromBase", "cc0DetailMismatch", "excludedIdsSha256", "sampleIds"}
    if not isinstance(summary, dict) or set(summary) != fields:
        raise ValueError("invalid snapshotSkew properties")
    counts = [summary[key] for key in ("missingFromBase", "cc0DetailMismatch")]
    if any(type(count) is not int or count < 0 for count in counts):
        raise ValueError("invalid snapshotSkew counts")
    digest, sample = summary["excludedIdsSha256"], summary["sampleIds"]
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ValueError("invalid snapshotSkew SHA-256")
    if (not isinstance(sample, list) or len(sample) > 20
            or any(type(number) is not int or not 0 <= number <= 9223372036854775807 for number in sample)
            or sample != sorted(set(sample))):
        raise ValueError("invalid snapshotSkew sampleIds")
    if not min(20, max(counts)) <= len(sample) <= min(20, sum(counts)):
        raise ValueError("snapshotSkew sample/count mismatch")
    if sum(counts) <= 20 or len(sample) < 20:
        if digest != hashlib.sha256("\n".join(map(str, sample)).encode("ascii")).hexdigest():
            raise ValueError("snapshotSkew sample/hash mismatch")
    return summary


def snapshot_skew(db, max_bp=100, languages=None):
    """Record selected-language skew on disk; preserve every graph vertex.

    Reasons can overlap. The limit and ID hash use their union, ordered by
    numeric sentence ID and LF-joined without a trailing LF.
    """
    snapshot_skew_limit({"maxSnapshotSkewBp": max_bp})
    selected = tuple(sorted(set(languages))) if languages is not None else None
    predicate = "1" if selected is None else f"d.lang IN ({','.join('?' for _ in selected)})"
    args = () if selected is None else selected
    db.execute("""CREATE TEMP TABLE snapshot_skew(
        id INTEGER PRIMARY KEY, missing_from_base INTEGER, cc0_detail_mismatch INTEGER)""")
    db.execute(f"""INSERT INTO snapshot_skew
        SELECT d.id, b.id IS NULL,
            c.id IS NOT NULL AND (c.lang != d.lang OR c.text != d.text OR c.modified != d.modified)
        FROM details d LEFT JOIN base b ON b.id=d.id LEFT JOIN cc0 c ON c.id=d.id
        WHERE ({predicate}) AND (b.id IS NULL OR
            (c.id IS NOT NULL AND (c.lang != d.lang OR c.text != d.text OR c.modified != d.modified)))""", args)
    total = db.execute(f"SELECT COUNT(*) FROM details d WHERE {predicate}", args).fetchone()[0]
    excluded, missing, mismatch = db.execute("""SELECT COUNT(*), COALESCE(SUM(missing_from_base),0),
        COALESCE(SUM(cc0_detail_mismatch),0) FROM snapshot_skew""").fetchone()
    digest, sample = hashlib.sha256(), []
    for index, (number,) in enumerate(db.execute("SELECT id FROM snapshot_skew ORDER BY id")):
        if index:
            digest.update(b"\n")
        digest.update(str(number).encode("ascii"))
        if index < 20:
            sample.append(number)
    summary = {"missingFromBase": missing, "cc0DetailMismatch": mismatch,
               "excludedIdsSha256": digest.hexdigest(), "sampleIds": sample}
    if excluded * 10000 > total * max_bp:
        raise ValueError(f"snapshot skew exceeds maxSnapshotSkewBp={max_bp}: "
                         f"{excluded}/{total} selected-language detailed rows; {json_bytes(summary).decode().strip()}")
    return summary


def _validate_config(config):
    snapshot_skew_limit(config)
    source = config["sourceId"]
    if re.fullmatch(r"[A-Za-z0-9_-]+", source) is None:
        raise ValueError("invalid source ID")
    mappings = {}
    for row in config["languageMappings"]:
        if row["sourceLanguage"] in mappings:
            raise ValueError("duplicate source language mapping")
        mappings[row["sourceLanguage"]] = row["detectorLanguage"]
    languages = sorted(set(mappings.values()))
    if set(languages) != set(config["targets"]) | set(config["negativeLanguages"]):
        raise ValueError("language mappings do not cover targets and negatives")
    if set(config["targets"]) & set(config["negativeLanguages"]):
        raise ValueError("negative language is a target")
    splits = tuple(config["splitBp"][s] for s in SPLITS)
    split_group("0" * 64, config["seed"], splits)
    if type(config["maxComponentMembers"]) is not int or config["maxComponentMembers"] < 1:
        raise ValueError("invalid component cap")
    caps = {}
    for row in config["caps"]:
        key = row["language"], row["split"]
        if key in caps or type(row["maxOriginalRecords"]) is not int or row["maxOriginalRecords"] < 0:
            raise ValueError("duplicate/invalid cap")
        caps[key] = row["maxOriginalRecords"]
    if set(caps) != {(lang, s) for lang in languages for s in SPLITS}:
        raise ValueError("caps must cover every language/split")
    seen = set()
    for rule in config["augmentation"]:
        algorithm = rule.get("algorithm") if isinstance(rule, dict) else None
        if algorithm in seen or algorithm not in AUGMENTATIONS:
            raise ValueError("unknown/duplicate augmentation")
        seen.add(algorithm)
        if set(rule) != {"algorithm", "splits", "lengths"} | ({"maxOutputs"} if algorithm == "concat-v1" else set()):
            raise ValueError("unknown/missing augmentation properties")
        lengths = rule["lengths"]
        if (not isinstance(rule["splits"], list) or not rule["splits"] or len(set(rule["splits"])) != len(rule["splits"])
                or not set(rule["splits"]) <= set(SPLITS)):
            raise ValueError("invalid augmentation splits")
        if algorithm in LENGTH_AUGMENTATIONS:
            if (not isinstance(lengths, list) or not lengths or any(type(n) is not int or n <= 0 for n in lengths)
                    or lengths != sorted(set(lengths))):
                raise ValueError("invalid augmentation lengths")
        elif lengths:
            raise ValueError("only scalar-prefix-v1 and concat-v1 have lengths")
        if algorithm == "concat-v1":
            concat_caps(rule, languages)
    if not seen or ("none-v1" in seen and len(seen) != 1):
        raise ValueError("none-v1 must stand alone")
    return mappings, languages, splits, caps


def concat_caps(rule, languages):
    """Per split × language output cap, applied independently to each concat length."""
    caps = {}
    if not isinstance(rule.get("maxOutputs"), list):
        raise ValueError("concat-v1 requires maxOutputs")
    for row in rule["maxOutputs"]:
        if not isinstance(row, dict) or set(row) != {"split", "language", "maxOutputsPerLength"}:
            raise ValueError("invalid concat-v1 maxOutputs properties")
        key, cap = (row["split"], row["language"]), row["maxOutputsPerLength"]
        if key in caps or type(cap) is not int or cap < 0:
            raise ValueError("duplicate/invalid concat-v1 maxOutputs")
        caps[key] = cap
    if set(caps) != {(split, language) for split in rule["splits"] for language in languages}:
        raise ValueError("concat-v1 maxOutputs must cover exactly its splits × languages")
    return caps


def concatenate(pool, length, cap, seed):
    """concat-v1 for one split × language × length; deterministic, no runtime PRNG.

    `pool` holds that split/language's selected originals in cap order (seeded
    record-key SHA-256, then decimal ID text) as (recordKey, groupId, scalars).
    Each anchor, in pool order, yields at most one example: draw companion
    k = 1, 2, ... at index uint64be(SHA-256(seed LF "concat-v1" LF length LF
    anchorKey LF k LF)[:8]) mod len(pool); skip any whose original group is
    already present (so the anchor's own group and same-group translations are
    never repeated); append with one U+0020 until the joined stream reaches
    `length`, then keep exactly its first `length` scalars. An anchor that alone
    reaches `length`, or that has not reached it after 4*length draws, yields
    nothing. Emission stops after `cap` examples. Returns (member indexes, scalars).
    """
    output = []
    for anchor, (key, group, stream) in enumerate(pool):
        if len(output) >= cap:
            break
        if len(stream) >= length:
            continue
        members, groups, total = [anchor], {group}, len(stream)
        for draw in range(1, 4 * length + 1):
            if total >= length:
                break
            digest = hashlib.sha256(f"{seed}\nconcat-v1\n{length}\n{key}\n{draw}\n".encode("utf-8")).digest()
            index = int.from_bytes(digest[:8], "big") % len(pool)
            if pool[index][1] in groups:
                continue
            members.append(index)
            groups.add(pool[index][1])
            total += 1 + len(pool[index][2])
        if total < length:
            continue
        scalars = list(pool[members[0]][2])
        for index in members[1:]:
            scalars.append(32)
            scalars.extend(pool[index][2])
        output.append((members, scalars[:length]))
    return output


def prepare(data_dir: Path, lock: dict, config: dict, output_dir: Path) -> dict:
    mappings, languages, splits, caps = _validate_config(config)
    source = config["sourceId"]
    if lock["sourceId"] != source:
        raise ValueError("lock/config source mismatch")
    tables = UnicodeData.load(TABLE_PATH)
    output_dir = Path(output_dir)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    with verified_inputs(data_dir, lock) as inputs, tempfile.TemporaryDirectory(
            prefix="ainotebook-lang-prepare-", dir=output_dir.parent) as temporary:
        work = Path(temporary)
        db = sqlite3.connect(work / "corpus.sqlite")
        try:
            db.executescript("""
                CREATE TABLE base(id INTEGER PRIMARY KEY, base_id INTEGER);
                CREATE TABLE details(id INTEGER PRIMARY KEY, lang TEXT, text TEXT, owner TEXT, created TEXT, modified TEXT);
                CREATE TABLE cc0(id INTEGER PRIMARY KEY, lang TEXT, text TEXT, modified TEXT);
                CREATE TABLE vertices(root INTEGER, key TEXT, id INTEGER);
                CREATE TABLE groups(root INTEGER PRIMARY KEY, groupid TEXT, members INTEGER, split TEXT);
                CREATE TABLE assignments(id INTEGER PRIMARY KEY, groupid TEXT, blockid TEXT, split TEXT);
                CREATE TABLE eligible(id INTEGER PRIMARY KEY, language TEXT, license TEXT, split TEXT, rank TEXT);
                CREATE TABLE support(split TEXT, language TEXT, bucket INTEGER, groupid TEXT,
                    PRIMARY KEY(split,language,bucket,groupid));
            """)
            graph, file_rows = _UnionFind(), []
            for entry, path in sorted(inputs, key=lambda x: x[0]["localPath"]):
                role, rows = entry["role"], 0
                for fields in _tsv(path, {"base": 2, "links": 2, "cc0": 4, "sentences": 6}[role]):
                    rows += 1
                    number = sentence_id(fields[0])
                    graph.add(number)
                    if role == "links":
                        graph.union(number, sentence_id(fields[1]))
                    else:
                        # Base references are validated, but only links define translation edges.
                        row = ((number, None if fields[1] == "\\N" else sentence_id(fields[1]))
                               if role == "base" else (number, *fields[1:]))
                        _insert_sentence(db, {"base": "base", "sentences": "details", "cc0": "cc0"}[role],
                                         row)
                file_rows.append({**entry, "records": rows})
            skew = snapshot_skew(db, snapshot_skew_limit(config), mappings)
            db.executemany("INSERT INTO vertices VALUES (?,?,?)",
                           ((graph.root(i), f"{source}:{number}", number) for number, i in graph.index.items()))
            del graph
            db.execute("CREATE INDEX vertex_order ON vertices(root,key)")
            for root, vertices in itertools.groupby(db.execute("SELECT root,key FROM vertices ORDER BY root,key"), lambda r: r[0]):
                digest, count = hashlib.sha256(), 0
                for _, key in vertices:
                    digest.update((key + "\n").encode())
                    count += 1
                group = digest.hexdigest()
                db.execute("INSERT INTO groups VALUES (?,?,?,?)", (root, group, count, split_group(group, config["seed"], splits)))
            oversized, group_count = [], 0
            with (work / "groups.jsonl").open("wb") as out:
                for root, group, members, split in db.execute("SELECT * FROM groups ORDER BY groupid"):
                    group_count += 1
                    cursor = db.execute("SELECT key,id FROM vertices WHERE root=? ORDER BY key", (root,))
                    blocks = []
                    while True:
                        chunk = cursor.fetchmany(config["maxComponentMembers"])
                        if not chunk:
                            break
                        block = group_id([r[0] for r in chunk])
                        blocks.append({"groupId": block, "memberCount": len(chunk)})
                        db.executemany("INSERT INTO assignments VALUES (?,?,?,?)", ((r[1], group, block, split) for r in chunk))
                    record = {"groupId": group, "memberCount": members, "blocks": blocks}
                    if members > config["maxComponentMembers"]:
                        oversized.append(record)
                    out.write(json_bytes({**record, "split": split}))
            exclusions = Counter()
            for number, source_language, owner, split, skewed in db.execute(
                    "SELECT b.id,d.lang,d.owner,a.split,k.id FROM "
                    "(SELECT id FROM base UNION SELECT id FROM snapshot_skew) b "
                    "JOIN assignments a ON a.id=b.id LEFT JOIN details d ON d.id=b.id "
                    "LEFT JOIN snapshot_skew k ON k.id=b.id ORDER BY b.id"):
                # Base-only graph vertices have no source-language metadata.
                language = mappings.get(source_language, source_language or "und")
                license_id = ("CC0-1.0" if db.execute("SELECT 1 FROM cc0 WHERE id=?", (number,)).fetchone()
                              else "CC-BY-2.0-FR")
                reason = ("snapshotSkew" if skewed is not None else
                          "languageExcluded" if source_language not in mappings else
                          "licenseExcluded" if license_id not in config["licenseIds"] else
                          "missingContributor" if license_id == "CC-BY-2.0-FR" and (owner or "").strip() in ("", "\\N") else None)
                if reason:
                    exclusions[split, language, reason] += 1
                else:
                    rank = hashlib.sha256(f"{config['seed']}\n{source}:{number}\n".encode()).hexdigest()
                    db.execute("INSERT INTO eligible VALUES (?,?,?,?,?)", (number, language, license_id, split, rank))
            db.execute("CREATE INDEX cap_order ON eligible(language,split,rank,id)")
            db.execute("CREATE TABLE selected(id INTEGER PRIMARY KEY)")
            for language in languages:
                for split in SPLITS:
                    count = db.execute("SELECT COUNT(*) FROM eligible WHERE language=? AND split=?", (language, split)).fetchone()[0]
                    cap = caps[language, split]
                    if count > cap:
                        exclusions[split, language, "cap"] += count - cap
                    db.execute("INSERT INTO selected SELECT id FROM eligible WHERE language=? AND split=? ORDER BY rank,CAST(id AS TEXT) LIMIT ?",
                               (language, split, cap))
            # The hash-pinned attribution ledger: every selected original in all splits.
            selected_count = 0
            with (work / SELECTED_SENTENCES).open("wb") as ledger:
                for number, language, license_id, owner in db.execute(
                        "SELECT s.id,e.language,e.license,d.owner FROM selected s JOIN eligible e ON e.id=s.id "
                        "JOIN details d ON d.id=s.id ORDER BY s.id"):
                    ledger.write(f"{number}\t{language}\t{license_id}\t{owner}\n".encode("utf-8"))
                    selected_count += 1
            counts = Counter()
            augmentations = [{"algorithm": rule["algorithm"], "splits": rule["splits"], "lengths": rule["lengths"],
                              "inputCount": 0, "outputCount": 0} for rule in config["augmentation"]]
            concat = next((rule for rule in augmentations if rule["algorithm"] == "concat-v1"), None)
            concat_limits = concat_caps(next(r for r in config["augmentation"] if r["algorithm"] == "concat-v1"),
                                        languages) if concat else {}
            text_cap = config["parameters"]["textCapScalars"]
            with (work / "examples.jsonl").open("wb") as out:
                def write(split, language, record, rule, length, scalars, text, members=None):
                    number, source_language, owner, license_id, group, block = record
                    letters = classify(scalars[:text_cap], tables)["letterCount"]
                    bucket = max(b for b in BUCKETS if b <= letters)
                    counts[split, language, bucket, "originals" if rule == "original" else "augmented"] += 1
                    db.execute("INSERT OR IGNORE INTO support VALUES (?,?,?,?)", (split, language, bucket, group))
                    example = {"sourceId": source, "recordKey": f"{source}:{number}",
                        "originalGroupId": group, "blockId": block, "split": split,
                        "sourceLanguage": source_language, "language": language, "licenseId": license_id,
                        "contributor": owner, "text": text, "normalizedScalars": scalars, "rule": rule, "length": length}
                    if members is not None:
                        example["memberRecordKeys"] = members
                    out.write(json_bytes(example))

                def flush(split, language, pool):
                    # Concatenations follow their language's originals inside the same split.
                    if not pool:
                        return
                    pool.sort(key=lambda item: item[0])
                    keyed = [(f"{source}:{record[0]}", record[4], stream) for _, record, stream in pool]
                    for length in concat["lengths"]:
                        for members, scalars in concatenate(keyed, length, concat_limits[split, language], config["seed"]):
                            concat["outputCount"] += 1
                            write(split, language, pool[members[0]][1], "concat-v1", length, scalars,
                                  "".join(map(chr, scalars)), [keyed[i][0] for i in members])

                for split in SPLITS:
                    pooled = concat is not None and split in concat["splits"]
                    current, pool = None, []
                    for row in db.execute("""SELECT d.*,e.language,e.license,e.rank,a.groupid,a.blockid FROM selected s
                            JOIN details d ON s.id=d.id JOIN eligible e ON e.id=d.id JOIN assignments a ON a.id=d.id
                            WHERE a.split=? ORDER BY e.language,CAST(d.id AS TEXT)""", (split,)):
                        number, source_language, text, owner, _, _, language, license_id, rank, group, block = row
                        if language != current:
                            if pooled:
                                flush(split, current, pool)
                            current, pool = language, []
                        record = (number, source_language, owner, license_id, group, block)
                        stream = normalize(text, tables, config["parameters"]["inputCapScalars"])
                        examples = [("original", None, stream)]
                        for rule in augmentations:
                            if split not in rule["splits"]:
                                continue
                            rule["inputCount"] += 1
                            derived = []
                            if rule["algorithm"] == "scalar-prefix-v1":
                                derived = [(rule["algorithm"], n, stream[:n]) for n in rule["lengths"] if n < len(stream)]
                            elif rule["algorithm"] == "strip-marks-v1":
                                stripped = tables.nfc([cp for cp in tables.nfd(stream) if not tables.category(cp).startswith("M")])
                                if stripped != stream:
                                    derived = [(rule["algorithm"], None, stripped)]
                            elif rule["algorithm"] == "concat-v1":
                                pool.append(((rank, str(number)), record, stream))
                            rule["outputCount"] += len(derived)
                            examples.extend(derived)
                        for rule, length, scalars in sorted(examples, key=lambda e: ({"original": 0, "scalar-prefix-v1": 1, "strip-marks-v1": 2}[e[0]], e[1] or 0)):
                            write(split, language, record, rule, length, scalars,
                                  text if rule == "original" else "".join(map(chr, scalars)))
                    if pooled:
                        flush(split, current, pool)
            count_rows = []
            for split in SPLITS:
                for language in languages:
                    for bucket in BUCKETS:
                        count_rows.append({"split": split, "language": language, "bucketStart": bucket,
                            "originals": counts[split, language, bucket, "originals"],
                            "augmented": counts[split, language, bucket, "augmented"],
                            "originalGroups": db.execute("SELECT COUNT(*) FROM support WHERE split=? AND language=? AND bucket=?",
                                                         (split, language, bucket)).fetchone()[0]})
            provenance = {"contract": "prepared-language-corpus", "version": 1, "sourceId": source,
                "snapshotDate": lock["snapshotDate"], "snapshotSkew": skew,
                "files": file_rows, "caps": config["caps"],
                "languageMappings": config["languageMappings"], "negativeLanguages": config["negativeLanguages"],
                "deduplicationPolicy": "none; translation links only", "counts": count_rows,
                "oversizedComponents": oversized, "augmentation": augmentations,
                "augmentationRules": config["augmentation"],
                "selectedSentences": {"path": SELECTED_SENTENCES, "records": selected_count,
                                      "sha256": sha_file(work / SELECTED_SENTENCES)},
                "splitAssignments": {"path": "groups.jsonl", "sha256": sha_file(work / "groups.jsonl"), "groups": group_count},
                "split": {"algorithm": "translation-components-sha256-v1", "seed": config["seed"],
                          "splitBp": config["splitBp"], "maxComponentMembers": config["maxComponentMembers"]},
                "exclusions": [{"sourceId": source, "split": s, "language": lang, "reason": reason, "count": count}
                               for (s, lang, reason), count in sorted(exclusions.items())]}
            (work / "provenance.json").write_bytes(json_bytes(provenance))
            output_dir.mkdir(parents=True, exist_ok=True)
            for name in ("examples.jsonl", "groups.jsonl", "provenance.json", SELECTED_SENTENCES):
                (work / name).replace(output_dir / name)
            return provenance
        finally:
            db.close()


def _git(root, *arguments):
    return subprocess.run(["git", "-C", str(root), *arguments], check=True, capture_output=True, text=True).stdout.strip()


def snapshot_wp1(root: Path) -> dict:
    root = Path(root).resolve()
    inventories = []
    for path in sorted(root.glob("*.json")):
        data = read_json(path)
        if isinstance(data, dict) and "documents" in data:
            inventories.append(data)
    if len(inventories) != 1:
        raise ValueError("expected exactly one WP1 documents inventory")
    inventory = inventories[0]
    repo = Path(_git(root, "rev-parse", "--show-toplevel"))
    relative_root = root.relative_to(repo).as_posix()
    revision = _git(repo, "log", "-1", "--format=%H", "--", relative_root)
    if re.fullmatch(r"[0-9a-f]{40,64}", revision) is None:
        raise ValueError("WP1 source revision unavailable")
    date = _git(repo, "show", "-s", "--format=%cI", revision)
    snapshot_date = datetime.fromisoformat(date.replace("Z", "+00:00")).astimezone(timezone.utc).date().isoformat()
    origin = _git(repo, "remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?", origin)
    source_url = f"https://raw.githubusercontent.com/{match[1]}/{revision}/{relative_root}/" if match else None
    actual = inventory.get("contract") == "eval-corpus" and inventory.get("version") == 1
    if actual:
        if inventory.get("corpus_id") != "multilingual-v1" or inventory.get("license") != "MIT":
            raise ValueError("unknown WP1 eval-corpus schema/provenance")
        provenance = (root / "PROVENANCE.md").read_text(encoding="utf-8")
        if "each document ID is an independent authored" not in provenance:
            raise ValueError("missing WP1 translation-group policy")
    elif inventory.get("contract") != "wp1-detector-inventory" or inventory.get("version") != 1:
        raise ValueError("unknown WP1 inventory schema")
    documents, ids = [], set()
    for row in inventory["documents"]:
        try:
            if actual:
                document_id, sha, gold = row["document_id"], row["raw_sha256"], row["language"]
                source, license_id, group = inventory["corpus_id"], inventory["license"], row["document_id"]
            else:
                document_id, sha, gold = row["documentId"], row["sha256"], row["goldLabel"]
                source, license_id, group = row["sourceId"], row["licenseId"], row["translationGroupId"]
            if not document_id or document_id in ids or gold not in ("cs", "de", "en", "sk", "mixed", "und"):
                raise ValueError("duplicate document ID or invalid/missing gold label")
            if not source or not license_id or not group:
                raise ValueError("missing WP1 attribution/group")
            ids.add(document_id)
            path = contained(root, row["path"])
            raw = path.read_bytes()
            if hashlib.sha256(raw).hexdigest() != sha:
                raise ValueError(f"WP1 SHA-256 mismatch: {document_id}")
            committed = subprocess.run(["git", "-C", str(repo), "show",
                f"{revision}:{path.relative_to(repo).as_posix()}"], check=True, capture_output=True).stdout
            if hashlib.sha256(committed).hexdigest() != sha:
                raise ValueError(f"WP1 source revision SHA-256 mismatch: {document_id}")
            encoding = row["encoding"]
            if encoding not in ("utf-8", "windows-1250"):
                raise ValueError(f"unsupported WP1 encoding: {encoding}")
            text = raw.decode("cp1250" if encoding == "windows-1250" else "utf-8", errors="strict")
            if actual and hashlib.sha256(text.encode("utf-8")).hexdigest() != row["content_hash"]:
                raise ValueError(f"WP1 decoded SHA-256 mismatch: {document_id}")
            url = source_url + row["path"] if source_url else row.get("url", "")
            if not url.startswith("https://"):
                raise ValueError("unknown origin requires explicit HTTPS source URL")
            documents.append({"documentId": document_id, "sourceId": source, "goldLabel": gold, "sha256": sha,
                              "encoding": encoding, "text": text, "licenseId": license_id,
                              "translationGroupId": group, "url": url})
        except KeyError as error:
            raise ValueError(f"missing WP1 handoff field: {error}") from error
    return {"contract": "wp1-detector-documents", "version": 1, "sourceRevision": revision,
            "snapshotDate": snapshot_date, "documents": sorted(documents, key=lambda d: d["documentId"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-wp1", type=Path)
    parser.add_argument("--wp1-output", type=Path)
    for name in ("data-dir", "lock", "config", "output-dir"):
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    if args.snapshot_wp1:
        if not args.wp1_output or any((args.data_dir, args.lock, args.config, args.output_dir)):
            parser.error("snapshot mode requires only --snapshot-wp1 and --wp1-output")
        result = snapshot_wp1(args.snapshot_wp1)
        args.wp1_output.parent.mkdir(parents=True, exist_ok=True)
        args.wp1_output.write_bytes(json_bytes(result))
        print(f"WP1 snapshot: {len(result['documents'])} documents; {sha_file(args.wp1_output)}")
    else:
        if args.wp1_output or not all((args.data_dir, args.lock, args.config, args.output_dir)):
            parser.error("preparation requires --data-dir --lock --config --output-dir")
        result = prepare(args.data_dir, read_json(args.lock), read_json(args.config), args.output_dir)
        print(f"Prepared {sum(c['originals'] + c['augmented'] for c in result['counts'])} examples")


if __name__ == "__main__":
    main()
