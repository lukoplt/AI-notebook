#!/usr/bin/env python3
"""embedding-plan-v1 reference: which chunks a folder index build sends to the provider, in which order.

Three rules shorten a background build without changing what retrieval can find:

1. Priority: non-spreadsheet sources are embedded before spreadsheet sources
   (`xlsx`, which also covers `.xlsm`); within a class, manifest source id then
   chunk ord.
2. Spreadsheet cap: a spreadsheet source embeds only its chunks with
   `ord < 64`; the rest stay in full-text search only and are not counted in
   embedding progress.
3. Dedup: a chunk whose exact text already has a vector in the building
   generation copies that vector; identical texts inside one round are sent
   once.

Swift (`FolderIndexCoordinator` + `NotebookStore.captureEmbeddingRound`) and C#
(`FolderIndexCoordinator` + `NotebookStore.CaptureEmbeddingRound`) seed every
`build` case into a fresh store, run the real coordinator with a recording fake
provider and must reproduce the provider calls, copy count and progress
exactly. Normative text: docs/contracts/embedding-plan-v1.md.
"""

import argparse
import hashlib
import json
import unicodedata
from pathlib import Path

CONTRACT = "embedding-plan"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/embedding-plan-v1.json"

SPREADSHEET_TYPES = ["xlsx"]
SPREADSHEET_CHUNK_CAP = 64
ROUND_SCAN_FACTOR = 16
SOURCE_TYPES = ["pdf", "text", "markdown", "web", "docx", "pptx", "xlsx", "note", "email"]


def classify(source_type: str) -> dict:
    spreadsheet = source_type in SPREADSHEET_TYPES
    return dict(priorityClass=1 if spreadsheet else 0, embedCap=SPREADSHEET_CHUNK_CAP if spreadsheet else None)


def text_hash(text: str) -> str:
    """Lowercase hex SHA-256 of the exact UTF-8 bytes (no normalization)."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def candidates(sources: list) -> list:
    """Embeddable chunks in build order: (priority class, source id, ord)."""
    out = []
    for source in sources:
        rule = classify(source["type"])
        for ord_, text in enumerate(source["chunks"]):
            if rule["embedCap"] is None or ord_ < rule["embedCap"]:
                out.append((rule["priorityClass"], source["id"], ord_, text))
    return sorted(out, key=lambda c: c[:3])


def build(batch_size: int, sources: list) -> dict:
    """Round-by-round simulation of a build into an empty generation (static corpus)."""
    order = candidates(sources)
    vectorized = set()      # texts that already have a vector in the generation
    calls, copied, pos = [], 0, 0
    scan_limit = ROUND_SCAN_FACTOR * batch_size
    while pos < len(order):
        inputs, joined, scanned = [], 0, 0
        while pos < len(order) and scanned < scan_limit:
            text = order[pos][3]
            if text in vectorized:
                copied += 1                 # existing vector copied, no provider input
            elif text in inputs:
                joined += 1                 # same text already in this round's request
            elif len(inputs) < batch_size:
                inputs.append(text)
            else:
                break                       # needs a new input but the request is full
            pos += 1
            scanned += 1
        if inputs:
            calls.append(inputs)
            vectorized.update(inputs)
        copied += joined
    total = len(order)
    unembedded = [[s["id"], o] for s in sorted(sources, key=lambda s: s["id"]) for o in range(len(s["chunks"]))
                  if classify(s["type"])["embedCap"] is not None and o >= classify(s["type"])["embedCap"]]
    assert sum(len(c) for c in calls) + copied == total
    return dict(calls=calls, providerInputs=sum(len(c) for c in calls), copied=copied,
                chunkProgress=dict(done=total, total=total),
                sourceProgress=dict(done=len(sources), total=len(sources)), unembedded=unembedded)


def source(id_: int, type_: str, chunks: list) -> dict:
    assert type_ in SOURCE_TYPES and chunks
    return dict(id=id_, type=type_, chunks=chunks)


def build_case(name: str, batch_size: int, sources: list) -> dict:
    return dict(name=name, operation="build", input=dict(batchSize=batch_size, sources=sources),
                expected=build(batch_size, sources))


def cases() -> list:
    out = [dict(name="classify-" + t, operation="classify", input=dict(sourceType=t), expected=classify(t))
           for t in SOURCE_TYPES]
    nfc = unicodedata.normalize("NFC", "café")
    nfd = unicodedata.normalize("NFD", "café")
    for name, text in [("empty", ""), ("ascii", "a"), ("czech", "Příliš žluťoučký kůň úpěl ďábelské ódy"),
                       ("nfc", nfc), ("nfd", nfd), ("crlf", "line\r\n"), ("emoji", "📄 report")]:
        out.append(dict(name="hash-" + name, operation="textHash", input=dict(text=text),
                        expected=dict(hash=text_hash(text))))
    out.append(build_case("priority-non-spreadsheet-first", 2, [
        source(1, "xlsx", ["x1a", "x1b"]), source(2, "pdf", ["p2a", "p2b", "p2c"]), source(3, "docx", ["d3a"]),
        source(4, "xlsx", ["x4a"]), source(5, "email", ["e5a"])]))
    out.append(build_case("spreadsheet-cap-64", 64, [
        source(1, "xlsx", ["row %d" % n for n in range(70)]), source(2, "text", ["line %d" % n for n in range(70)])]))
    template = ["Header A", "Row 1", "Row 2"]
    out.append(build_case("dedup-template-copies", 3, [
        source(1, "xlsx", template), source(2, "xlsx", template), source(3, "xlsx", template),
        source(4, "xlsx", template), source(5, "pdf", ["Row 1", "unique pdf"]), source(6, "docx", ["same", "same", "other"])]))
    out.append(build_case("dedup-is-exact", 4, [source(1, "text", [nfc, nfd, "Café", nfc + " "])]))
    out.append(build_case("round-scan-limit", 2, [source(n, "text", ["a"]) for n in range(1, 41)] + [source(41, "text", ["b"])]))
    out.append(build_case("spreadsheet-cap-then-dedup", 4, [
        source(1, "xlsx", ["cell %d" % (n % 3) for n in range(66)]), source(2, "markdown", ["cell 1", "note"])]))
    return out


def contract() -> dict:
    return dict(contract=CONTRACT, version=VERSION,
                constants=dict(spreadsheetTypes=SPREADSHEET_TYPES, spreadsheetChunkCap=SPREADSHEET_CHUNK_CAP,
                               roundScanFactor=ROUND_SCAN_FACTOR, textHash="sha256-hex-utf8"),
                cases=cases())


def assert_reference_regressions() -> None:
    """Independent worked expectations, so --check cannot bless a shared bug."""
    by_name = {c["name"]: c["expected"] for c in cases()}
    assert by_name["priority-non-spreadsheet-first"]["calls"] == [["p2a", "p2b"], ["p2c", "d3a"], ["e5a", "x1a"], ["x1b", "x4a"]]
    cap = by_name["spreadsheet-cap-64"]
    assert cap["chunkProgress"] == dict(done=134, total=134) and cap["unembedded"] == [[1, n] for n in range(64, 70)]
    assert [len(c) for c in cap["calls"]] == [64, 64, 6]
    dedup = by_name["dedup-template-copies"]
    assert dedup["calls"] == [["Row 1", "unique pdf", "same"], ["other", "Header A", "Row 2"]] and dedup["copied"] == 11
    nfc, nfd = unicodedata.normalize("NFC", "café"), unicodedata.normalize("NFD", "café")
    assert by_name["dedup-is-exact"]["calls"] == [[nfc, nfd, "Café", nfc + " "]]
    assert by_name["dedup-is-exact"]["copied"] == 0
    # Without the per-round scan limit the two inputs would share one request.
    assert by_name["round-scan-limit"]["calls"] == [["a"], ["b"]] and by_name["round-scan-limit"]["copied"] == 39
    tail = by_name["spreadsheet-cap-then-dedup"]
    assert tail["calls"] == [["cell 1", "note", "cell 0", "cell 2"]] and tail["copied"] == 62
    assert by_name["hash-empty"]["hash"] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert by_name["hash-nfc"]["hash"] != by_name["hash-nfd"]["hash"]


def render(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if the committed fixture differs")
    args = parser.parse_args()
    assert_reference_regressions()
    root = Path(__file__).resolve().parents[2]
    path = root / OUTPUT
    text = render(contract())
    if args.check:
        if not path.exists() or path.read_text(encoding="utf-8") != text:
            raise SystemExit("out of date: " + OUTPUT)
        print("ok")
    else:
        path.write_text(text, encoding="utf-8")
        print("wrote " + OUTPUT)


if __name__ == "__main__":
    main()
