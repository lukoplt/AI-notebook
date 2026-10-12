#!/usr/bin/env python3
"""WP9 release-integration oracle: frozen inputs and observable scenarios.

Reads only immutable repository inputs (WP1 multilingual corpus manifest and
documents, the WP6 workbook and its independently authored office contract,
the WP8 context-pack contract and the v18 SQLite fixture). It never calls a
production extractor or detector; the platform integration tests assert that
the real Swift/C# pipelines reproduce these values.

No timestamp, absolute path, SQLite version, random ID or host Unicode
classification enters the output bytes.
"""

import argparse
import hashlib
import json
import sqlite3
from pathlib import Path
from typing import Optional

CONTRACT = "release-integration"
VERSION = 1
OUTPUT = "Tests/fixtures/contracts/release-integration-v1.json"
DB_FIXTURE = "storage/v18.sqlite"
CHUNK_SCALARS = 2048

# (document id or None, kind, repoPath, destination relPath)
ASSETS = [
    ("cs-03", "invoice", "eval/multilingual/documents/cs/customer/finance/2026/10/invoice.md", "cs/invoice.md"),
    ("sk-03", "invoice", "eval/multilingual/documents/sk/customer/finance/2026/10/invoice.md", "sk/invoice.md"),
    ("en-03", "invoice", "eval/multilingual/documents/en/customer/finance/2026/10/invoice.md", "en/invoice.md"),
    ("de-03", "invoice", "eval/multilingual/documents/de/customer/finance/2026/10/invoice.md", "de/invoice.md"),
    ("cs-10", "cp1250", "eval/multilingual/documents/cs/customer/technical/legacy/terminal.txt", "cs/terminal.txt"),
    (None, "xlsx", "Tests/fixtures/ingestion/workbook.xlsx", "sheets/workbook.xlsx"),
]

QUESTION = "Porovnej FA-CS-2026-031, FA-SK-2026-041, INV-EN-2026-051 a RE-DE-2026-061."
ANSWER = "Odpověď [2][1][2][99]."
INSTRUCTIONS = "Odpověz stručně česky."
ENDPOINT_CASES = [
    ("openai_compatible", "https://wp9.invalid/v1"),
    ("openai_compatible", "https://wp9.invalid/proxy/v1"),
    ("ollama", "http://127.0.0.1:11434"),
]


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _fail(message: str):
    raise SystemExit("gen_release_fixtures: " + message)


def _manifest_rows(root: Path) -> dict:
    manifest = json.loads((root / "eval/multilingual/manifest.json").read_bytes())
    return {row["document_id"]: row for row in manifest["documents"]}


def _workbook_text(root: Path) -> str:
    office = json.loads((root / "Tests/fixtures/contracts/ingestion-office-v1.json").read_bytes())
    matches = [c for c in office["cases"] if c["name"] == "workbook-order"]
    if len(matches) != 1:
        _fail("expected exactly one workbook-order office case")
    if matches[0]["input"]["asset"] != "ingestion/workbook.xlsx":
        _fail("workbook-order case does not describe ingestion/workbook.xlsx")
    return matches[0]["expected"]["text"]


def _rules_text(root: Path) -> str:
    pack = json.loads((root / "Tests/fixtures/contracts/context-pack-v1.json").read_bytes())
    texts = set()
    for case in pack["cases"]:
        expected = case.get("expected")
        if not isinstance(expected, dict) or "messages" not in expected:
            continue
        for message in expected["messages"]:
            if message.get("role") != "system":
                continue
            for section in message["sections"]:
                if section["kind"] == "rules":
                    texts.add(section["text"])
    if len(texts) != 1:
        _fail("context-pack fixture instances disagree on the rules paragraph")
    return texts.pop()


def _check_db(root: Path) -> str:
    path = root / "Tests/fixtures" / DB_FIXTURE
    digest = _sha(path.read_bytes())
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        ids = {r[0] for r in db.execute("SELECT identifier FROM grdb_migrations")}
        if "v18_personas" not in ids or "v19_folder_rag" in ids:
            _fail("storage/v18.sqlite is not a v18 database")
        row = db.execute("SELECT session_id, content, citations_json FROM messages WHERE id=41").fetchone()
    finally:
        db.close()
    if row is None or row[0] != 31 or row[1] != "saved answer":
        _fail("legacy message 41/session 31 is missing")
    citations = json.loads(row[2])
    if len(citations) != 1 or citations[0]["chunkId"] != 1101 or citations[0]["sourceId"] != 101:
        _fail("legacy citation must reference chunk 1101/source 101")
    return digest


def _assets(root: Path) -> list:
    rows = _manifest_rows(root)
    out = []
    for document_id, kind, repo_path, rel_path in ASSETS:
        raw = (root / repo_path).read_bytes()
        if document_id is None:
            text, encoding, language = _workbook_text(root), None, None
        else:
            row = rows[document_id]
            if "eval/multilingual/" + row["path"] != repo_path:
                _fail("manifest path mismatch for " + document_id)
            if _sha(raw) != row["raw_sha256"]:
                _fail("raw hash mismatch for " + document_id)
            codec = "cp1250" if row["encoding"] == "windows-1250" else "utf-8"
            text = raw.decode(codec, errors="strict")
            if _sha(text.encode("utf-8")) != row["content_hash"]:
                _fail("canonical hash mismatch for " + document_id)
            encoding, language = row["encoding"], row["language"]
        if len(text) > CHUNK_SCALARS:
            _fail(rel_path + " no longer fits one chunk; coverage expectations would be invalid")
        out.append(dict(kind=kind, repoPath=repo_path, relPath=rel_path, rawSha256=_sha(raw),
                        canonicalText=text, encoding=encoding, language=language))
    return out


def build(root: Path) -> dict:
    # benchmark-v1 contract: sha256_lowerhex(type + "\n" + normalizedRoot); roots are already normalized.
    endpoint_cases = [dict(type=t, root=r, expected=_sha((t + "\n" + r).encode("utf-8")))
                      for t, r in ENDPOINT_CASES]
    cases = [
        dict(name="upgrade-chat", expected=dict(files=6, searchable=6, refreshPending=0, refreshError=0,
                                                savedMarkers=[2, 1], citationVersion=2)),
        dict(name="restart-reconcile", relPath="en/invoice.md",
             append="\nWP9-RESTART: added while the application was stopped.\n",
             expected=dict(files=6, searchable=6, sameSource=True, newRevision=True)),
        dict(name="cancel-resume", relPath="cs/invoice.md",
             append="\nWP9-RESUME: dokončená nová revize.\n",
             expected=dict(cancelledState="cancelled", oldRevisionRetained=True, newJob=True,
                           newRevision=True, searchable=6)),
        dict(name="delete-completed-scan", relPath="de/invoice.md",
             expected=dict(before="present", after="missing", searchable=5, missing=1,
                           oldCitationReadable=True)),
        dict(name="rules-restrict", pattern="de/**", relPath="de/invoice.md",
             expected=dict(eligible=False, availability="present", searchable=5, vectorIncludes=False,
                           lexicalIncludes=False, mapIncludes=False, overviewIncludes=False)),
        dict(name="empty-selection", expected=dict(citations=0, queryEmbeddingCalls=0)),
        dict(name="zero-evidence", cap=0, expected=dict(citations=0, evidenceSections=0)),
    ]
    return dict(contract=CONTRACT, version=VERSION, assets=_assets(root), endpointCases=endpoint_cases,
                rulesText=_rules_text(root), question=QUESTION, answer=ANSWER, instructions=INSTRUCTIONS,
                dbFixture=DB_FIXTURE, dbSha256=_check_db(root), runtimeContext=32768, maxOutputTokens=1024,
                fetchK=32, topK=8, cases=cases)


def encoded(root: Path) -> bytes:
    return (json.dumps(build(root), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def generate(root: Path, check: bool = False, output: Optional[Path] = None) -> None:
    path = output or root / OUTPUT
    data = encoded(root)
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("release-integration-v1.json is stale")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
