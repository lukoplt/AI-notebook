#!/usr/bin/env python3
"""Deterministic WP6 fixture oracle; no production code or network access.

``root`` is a fixture root, containing contracts/ and ingestion/. Only the ten
JSON files and eight assets owned by WP6 Task 1 (+ the OOXML packaging fix) are written. --check is read-only.

Trace events carry an explicit operation, injected time and the complete expected
projection after that operation. Test adapters dispatch operations, never names.
Times are epoch seconds except schedule/runtime events (monotonic milliseconds).
OOXML mutations are applied to an in-memory copy of the named asset by the test
adapter: replace-entry replaces one entire UTF-8 member; remove-entry removes it.
The counted-stream operation tests a bounded reader with deliberately dishonest
declared lengths without committing enormous or parser-specific malformed ZIPs.
Fake-provider response vectors may contain the string "NaN", which the adapter
converts to a nonfinite float only at the provider boundary. Stored vectors never
contain this sentinel. Runtime jobs project scan jobs only; completed foreground
extraction jobs are covered by the publication fixtures.
Seed IDs are literal. IDs requested on creating events are fixture symbols:
adapters bind actual returned IDs to them and normalize subsequent projections
and arguments consistently (or seed SQLite sequences before creation). They must
never depend on an unrelated test's auto-increment history. A two-claim race
normalizes only the winning contender's token after checking membership.
"""

import argparse
import copy
from copy import deepcopy
import hashlib
import io
import json
import tempfile
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "Tests" / "fixtures"
GROUPS = ("encoding", "canonical", "office", "scan", "jobs", "pipeline",
          "generations", "coverage", "ui", "ooxml")
DEFAULT_IGNORES = [".*", "node_modules", ".git", "build", "dist", ".venv",
                   "__pycache__", "target", "bin", "obj", "~$*"]


def case(name, operation, input_value, expected):
    return dict(name=name, operation=operation, input=input_value, expected=expected)


def scalar_windows(text, window=2048, overlap=256):
    """Independent integer oracle from the WP3/WP6 scalar-window specification."""
    white = (set(range(9, 14)) | {32, 133, 160, 5760, 8232, 8233, 8239, 8287, 12288}
             | set(range(8192, 8203)))
    out, start = [], 0
    while start < len(text):
        end = min(start + window, len(text))
        if end < len(text):
            probe, floor = end, max(end - 200, start + 1)
            while probe > floor and ord(text[probe - 1]) not in white:
                probe -= 1
            if probe > floor:
                end = probe
        lo, hi = start, end
        while lo < hi and ord(text[lo]) in white:
            lo += 1
        while hi > lo and ord(text[hi - 1]) in white:
            hi -= 1
        if lo < hi:
            out.append(dict(text=text[lo:hi], start=lo, end=hi,
                            tokens=max(1, (hi - lo + 3) // 4)))
        if end == len(text):
            break
        start = max(end - overlap, start + 1)
    return out


def encoding_cases():
    rows = [
        ("utf8-bom", [239, 187, 191, 65, 10], "A\n", "utf-8-bom"),
        ("utf16le", [255, 254, 65, 0, 61, 216, 0, 222], "A😀", "utf-16le"),
        ("utf16be", [254, 255, 0, 65, 216, 61, 222, 0], "A😀", "utf-16be"),
        ("plain-utf8", list("  Čau\r\n".encode("utf-8")), "  Čau\r\n", "utf-8"),
        ("cp1250", [80, 248, 237, 108, 105, 154], "Příliš", "windows-1250"),
        ("bad-utf8-cp1250", [195, 40], "Ă(", "windows-1250"),
        ("empty", [], "", "utf-8"),
    ]
    result = [case(n, "decode", dict(bytes=b, fallback="cp1250"),
                   dict(text=t, encoding=e)) for n, b, t, e in rows]
    for name, data, fallback in [
        ("cp1250-disabled", [80, 248, 237, 108, 105, 154], "none"),
        ("bad-bom-utf8", [239, 187, 191, 255], "cp1250"),
        ("odd-utf16", [255, 254, 65], "cp1250"),
        ("unpaired-utf16", [254, 255, 216, 0], "cp1250"),
        ("undefined-cp1250", [129], "cp1250"),
    ]:
        result.append(case(name, "decode", dict(bytes=data, fallback=fallback),
                           dict(error="unsupportedEncoding")))
    return result


def canonical_cases():
    def assembled(name, kind, parts, text, pages=()):
        chunks = scalar_windows(text)
        for chunk in chunks:
            intersecting = [p["page"] for p in pages
                            if p["start"] < p["end"] and
                            chunk["start"] < p["end"] and p["start"] < chunk["end"]]
            if intersecting:
                chunk.update(pageFrom=intersecting[0], pageTo=intersecting[-1])
        return case(name, "canonical", dict(kind=kind, parts=parts, names=[],
                    window=2048, overlap=256, maxChunks=5000, maxScalars=5000000),
                    dict(text=text, pages=list(pages), chunks=chunks))
    result = [
        assembled("scalar-trim", "text", ["  A😀éZ  "], "  A😀éZ  "),
        assembled("pdf-empty-middle", "pdf", ["A😀", "", "éZ"], "A😀\n\n\n\néZ",
                  [dict(page=1, start=0, end=2), dict(page=2, start=4, end=4),
                   dict(page=3, start=6, end=9)]),
        assembled("docx", "docx", ["A", "B😀", ""], "A\nB😀\n"),
        assembled("pptx", "pptx", ["A", "B"], "## Slide 1\nA\n\n## Slide 2\nB"),
        assembled("window-cross-page", "pdf", ["A " * 1025, "B " * 15],
                  "A " * 1025 + "\n\n" + "B " * 15,
                  [dict(page=1, start=0, end=2050), dict(page=2, start=2052, end=2082)]),
        assembled("long-word", "text", ["x" * 4097], "x" * 4097),
        assembled("empty", "text", [""], ""),
        assembled("whitespace-only", "text", [" \t\r\n"], " \t\r\n"),
    ]
    result.append(case("chunk-limit", "canonical", dict(kind="text", parts=["x" * 4097],
        names=[], window=2048, overlap=256, maxChunks=2, maxScalars=5000000),
        dict(error="chunkLimit")))
    return result


WORKBOOK_TEXT = ("## Zeta\nA1: Příliš\tC1: A😀B\nA2: 42\tB2: TRUE\tC2: #DIV/0!\n"
                 "A3: 2 [cached formula]\tC3: 45292 [date serial]\n\n## Alpha\nA1: last")


def office_cases():
    sheet_ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    rel_ns = "http://schemas.openxmlformats.org/package/2006/relationships"
    sheet_entry = "xl/worksheets/sheet2.xml"

    def worksheet(rows):
        return f'<worksheet xmlns="{sheet_ns}"><sheetData>{rows}</sheetData></worksheet>'

    def extract(name, asset, kind, expected, mutations=(), limits=None):
        return case(name, "extract", dict(asset="ingestion/" + asset, kind=kind,
                    mutations=list(mutations), limits=limits or {}), expected)

    def modified(name, rows, expected):
        return extract(name, "workbook.xlsx", "xlsx", expected,
                       [dict(operation="replace-entry", entry=sheet_entry,
                             text=worksheet(rows))])

    result = [
        extract("workbook-order", "workbook.xlsx", "xlsx",
                dict(text=WORKBOOK_TEXT, sheetNames=["Zeta", "Alpha"])),
        extract("paragraphs", "paragraphs.docx", "docx", dict(text="A\nB😀\n")),
        extract("slides", "slides.pptx", "pptx", dict(text="## Slide 1\nA\n\n## Slide 2\nB")),
        extract("slides-relationship-not-lexical", "slides.pptx", "pptx",
                dict(text="## Slide 1\nB\n\n## Slide 2\nA"),
                [dict(operation="replace-entry", entry="ppt/presentation.xml", text=
                    '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
                    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
                    '<p:sldIdLst><p:sldId id="256" r:id="rId2"/>'
                    '<p:sldId id="257" r:id="rId10"/></p:sldIdLst></p:presentation>')]),
        extract("pages", "pages.pdf", "pdf", dict(text="A\n\n\n\nB", pages=[
            dict(page=1, start=0, end=1), dict(page=2, start=3, end=3), dict(page=3, start=5, end=6)])),
        extract("corrupt-zip", "corrupt.docx", "docx", dict(error="corruptArchive")),
        extract("external-relationship", "external.xlsx", "xlsx", dict(error="invalidRelationship")),
        extract("bad-shared-index", "bad-index.xlsx", "xlsx", dict(error="invalidCell")),
        modified("formula-no-cache", '<row r="1"><c r="A1"><f>1+1</f></c></row>',
                 dict(text="## Zeta\nA1: [formula; no cached value]\n\n## Alpha\nA1: last")),
        modified("cached-formula-date", '<row r="1"><c r="A1" s="1"><f>1+1</f><v>45292</v></c></row>',
                 dict(text="## Zeta\nA1: 45292 [cached formula] [date serial]\n\n## Alpha\nA1: last")),
        modified("empty-sheet", "", dict(text="## Zeta\n\n\n## Alpha\nA1: last")),
        modified("blank-cells-and-sparse-coordinates", '<row r="10"><c r="AA10"><v>7</v></c>'
                 '<c r="B10"/><c r="A10"><v>0</v></c></row><row r="2"><c r="Z2" t="b"><v>0</v></c></row>',
                 dict(text="## Zeta\nZ2: FALSE\nA10: 0\tAA10: 7\n\n## Alpha\nA1: last")),
        modified("invalid-cell-reference", '<row r="1"><c r="A0"><v>1</v></c></row>', dict(error="invalidCell")),
        modified("duplicate-coordinate", '<row r="1"><c r="A1"><v>1</v></c><c r="A1"><v>2</v></c></row>',
                 dict(error="invalidCell")),
        extract("missing-relationship", "workbook.xlsx", "xlsx", dict(error="invalidRelationship"),
                [dict(operation="replace-entry", entry="xl/_rels/workbook.xml.rels",
                      text=f'<Relationships xmlns="{rel_ns}"/>')]),
        extract("missing-part", "workbook.xlsx", "xlsx", dict(error="invalidRelationship"),
                [dict(operation="remove-entry", entry=sheet_entry)]),
        extract("escaping-relationship", "workbook.xlsx", "xlsx", dict(error="invalidRelationship"),
                [dict(operation="replace-entry", entry="xl/_rels/workbook.xml.rels", text=
                      f'<Relationships xmlns="{rel_ns}"><Relationship Id="rIdB" '
                      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
                      'Target="../../escape.xml"/></Relationships>')]),
        extract("malformed-xml", "paragraphs.docx", "docx", dict(error="corruptArchive"),
                [dict(operation="replace-entry", entry="word/document.xml", text="<document>")]),
        extract("doctype-external-entity", "paragraphs.docx", "docx", dict(error="corruptArchive", externalReads=0),
                [dict(operation="replace-entry", entry="word/document.xml", text=
                      '<!DOCTYPE document [<!ENTITY ext SYSTEM "file:///fixture-never-read">]>'
                      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                      '<w:body><w:p><w:r><w:t>&ext;</w:t></w:r></w:p></w:body></w:document>')]),
        extract("text-limit", "paragraphs.docx", "docx", dict(error="textLimit"),
                limits=dict(maxExtractedChars=4)),
        extract("cell-limit", "workbook.xlsx", "xlsx", dict(error="cellLimit", cellsMaterialized=2),
                limits=dict(maxCells=2)),
        extract("page-limit", "pages.pdf", "pdf", dict(error="pageLimit", pageTextReads=0),
                limits=dict(maxPdfPages=1)),
    ]
    # Numeric/date classification is independent of locale and date1904 mode.
    for name, fmt, date in [("custom-date", 'yyyy-mm-dd', True),
                            ("elapsed-time", '[h]:mm:ss', True),
                            ("quoted-date-literals", '0.00 &quot;days&quot;', False),
                            ("scientific-number", '0.00E+00', False)]:
        row = modified(name, '<row r="1"><c r="A1" s="1"><v>45292</v></c></row>',
                       dict(text="## Zeta\nA1: 45292" + (" [date serial]" if date else "") +
                            "\n\n## Alpha\nA1: last"))
        row["input"]["mutations"].append(dict(operation="replace-entry", entry="xl/styles.xml", text=
            f'<styleSheet xmlns="{sheet_ns}"><numFmts count="1"><numFmt numFmtId="164" formatCode="{fmt}"/>'
            '</numFmts><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="164"/></cellXfs></styleSheet>'))
        result.append(row)
    # Limits are exercised with small blocks; declaredBytes intentionally lies.
    for name, declared, blocks, limit, expected in [
        ("office-expanded-limit", [3, 3], [[65, 65, 65], [66, 66, 66]], 5,
         dict(error="officeLimit", readCalls=0, acceptedBytes=0)),
        ("dishonest-zip-length", [2], [[65, 66], [67]], 2,
         dict(error="officeLimit", readCalls=2, acceptedBytes=2)),
        ("expanded-exact-limit", [2, 1], [[65, 66], [67]], 3,
         dict(readCalls=2, acceptedBytes=3)),
    ]:
        result.append(case(name, "bounded-stream", dict(declaredBytes=declared,
            blocks=blocks, maxOfficeDecompressedBytes=limit), expected))
    return result


_OOXML_PACKAGE_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
_OOXML_REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
_OOXML_STRICT_REL_NS = "http://purl.oclc.org/ooxml/officeDocument/relationships"
_OOXML_WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
_OOXML_STRICT_WORD_NS = "http://purl.oclc.org/ooxml/wordprocessingml/main"
DOCUMENT2_TEXT = "Alpha\tBeta\nBefore \nBox\nAfter\nCell"


def _ooxml_relationships(*rows):
    """rows: (id, type, target[, external])."""
    body = "".join(
        f'<Relationship Id="{row[0]}" Type="{row[1]}" Target="{row[2]}"'
        + (' TargetMode="External"' if len(row) > 3 and row[3] else "") + "/>"
        for row in rows)
    return f'<Relationships xmlns="{_OOXML_PACKAGE_NS}">{body}</Relationships>'


OOXML_ERROR_TEXT = [
    ("missingMainPart", "sourceErrorMissingPart"),
    ("invalidRelationship", "sourceErrorMissingPart"),
    ("corruptArchive", "sourceErrorDamaged"),
    ("notDownloaded", "sourceErrorNotDownloaded"),
    ("fileLimit", "folderLimitError"),
    ("officeLimit", "folderLimitError"),
    ("textLimit", "folderLimitError"),
    ("pageLimit", "folderLimitError"),
    ("chunkLimit", "folderLimitError"),
    ("cellLimit", "folderLimitError"),
    ("unsupportedEncoding", "folderEncodingError"),
    ("invalidCell", "folderDocumentError"),
    ("unsupportedSyntax", "folderDocumentError"),
    ("outsideRoot", "folderReadError"),
    ("interiorLink", "folderReadError"),
    ("rootUnavailable", "folderReadError"),
    ("unexpectedError", None),
    ("changedDuringExtraction", None),
]
OOXML_LOCALIZATIONS = [
    ("sourceErrorMissingPart", "The document is incomplete: a required part is missing.",
     "Dokument je neúplný: chybí povinná část."),
    ("sourceErrorDamaged", "The file is damaged or is not a valid document.",
     "Soubor je poškozený nebo nejde o platný dokument."),
    ("sourceErrorNotDownloaded", "The file is only in cloud storage and could not be downloaded.",
     "Soubor je jen v cloudovém úložišti a nepodařilo se ho stáhnout."),
]


def ooxml_cases():
    """Real-world OPC/OOXML packaging accepted identically on both platforms.

    Relationship targets may be package-absolute ("/word/document2.xml"),
    relative with dot segments, percent-encoded or differ in ASCII case from the
    ZIP member name. External relationships (hyperlinks) are ignored; malformed
    or escaping relationships are dropped and only fail when a required part
    needs them. The main part falls back to the conventional path when the
    package relationships are missing, malformed or name no usable target, and
    `missingMainPart` reports a package without a main document part.
    Paragraphs nested in text boxes are separate lines; mc:Fallback copies of
    mc:Choice content are skipped; tab stops in paragraph properties are not text.
    """
    doc = "officeDocument"

    def extract(name, asset, kind, expected, mutations=()):
        return case(name, "extract", dict(asset="ingestion/" + asset, kind=kind,
                    mutations=list(mutations), limits={}), expected)

    def replace(entry, text):
        return dict(operation="replace-entry", entry=entry, text=text)

    def remove(entry):
        return dict(operation="remove-entry", entry=entry)

    def root(target, rel_type=f"{_OOXML_REL_NS}/{doc}", external=False):
        return replace("_rels/.rels", _ooxml_relationships(("rId1", rel_type, target, external)))

    def workbook_rels(*rows):
        return replace("xl/_rels/workbook.xml.rels", _ooxml_relationships(*rows))

    sheet = f"{_OOXML_REL_NS}/worksheet"
    shared = f"{_OOXML_REL_NS}/sharedStrings"
    styles = f"{_OOXML_REL_NS}/styles"
    slide = f"{_OOXML_REL_NS}/slide"
    paragraphs = dict(text="A\nB😀\n")
    document2 = dict(text=DOCUMENT2_TEXT)
    slides = dict(text="## Slide 1\nA\n\n## Slide 2\nB")
    workbook = dict(text=WORKBOOK_TEXT, sheetNames=["Zeta", "Alpha"])
    return [
        extract("document2-absolute-main-part", "document2.docx", "docx", document2),
        extract("main-part-relative-target", "document2.docx", "docx", document2,
                [root("word/document2.xml")]),
        extract("main-part-dot-segments", "document2.docx", "docx", document2,
                [root("./word/../word/document2.xml")]),
        extract("main-part-percent-encoded", "document2.docx", "docx", document2,
                [root("/word/document%32.xml")]),
        extract("main-part-ascii-case-insensitive", "document2.docx", "docx", document2,
                [root("/WORD/Document2.XML")]),
        extract("main-part-escaping-target", "document2.docx", "docx", dict(error="missingMainPart"),
                [root("/../document2.xml")]),
        extract("main-part-removed", "document2.docx", "docx", dict(error="missingMainPart"),
                [remove("word/document2.xml")]),
        extract("root-relationships-missing-no-conventional", "document2.docx", "docx",
                dict(error="missingMainPart"), [remove("_rels/.rels")]),
        extract("main-part-ambiguous", "document2.docx", "docx", dict(error="invalidRelationship"),
                [replace("_rels/.rels", _ooxml_relationships(
                    ("rId1", f"{_OOXML_REL_NS}/{doc}", "/word/document2.xml"),
                    ("rId2", f"{_OOXML_REL_NS}/{doc}", "/word/document2.xml")))]),
        extract("root-relationships-missing-conventional", "paragraphs.docx", "docx", paragraphs,
                [remove("_rels/.rels")]),
        extract("root-relationships-malformed-conventional", "paragraphs.docx", "docx", paragraphs,
                [replace("_rels/.rels", "<Relationships")]),
        extract("main-part-external-conventional", "paragraphs.docx", "docx", paragraphs,
                [root("https://example.invalid/document.xml", external=True)]),
        extract("strict-namespaces", "document2.docx", "docx", dict(text="Strict"),
                [root("/word/document2.xml", rel_type=f"{_OOXML_STRICT_REL_NS}/{doc}"),
                 replace("word/document2.xml", f'<w:document xmlns:w="{_OOXML_STRICT_WORD_NS}">'
                         '<w:body><w:p><w:r><w:t>Strict</w:t></w:r></w:p></w:body></w:document>')]),
        extract("slides-absolute-and-external-targets", "slides.pptx", "pptx", slides,
                [replace("ppt/_rels/presentation.xml.rels", _ooxml_relationships(
                    ("rId2", slide, "/ppt/slides/slide2.xml"),
                    ("rId10", slide, "/ppt/slides/slide10.xml"),
                    ("rIdLink", f"{_OOXML_REL_NS}/hyperlink", "https://example.invalid/?a=1#b", True),
                    ("rIdBad", f"{_OOXML_REL_NS}/theme", "../../escape.xml")))]),
        extract("slides-root-absolute-target", "slides.pptx", "pptx", slides,
                [root("/ppt/presentation.xml")]),
        extract("slide-fields-breaks-and-tab-stops", "slides.pptx", "pptx",
                dict(text="## Slide 1\nA\n1\nC\n\n## Slide 2\nB"),
                [replace("ppt/slides/slide10.xml",
                    '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
                    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree>'
                    '<p:sp><p:txBody><a:bodyPr/><a:p><a:pPr><a:tabLst><a:tab pos="0" algn="l"/></a:tabLst></a:pPr>'
                    '<a:r><a:t>A</a:t></a:r><a:br/><a:fld id="{00000000-0000-0000-0000-000000000001}" type="slidenum">'
                    '<a:t>1</a:t></a:fld></a:p><a:p><a:r><a:t>C</a:t></a:r></a:p></p:txBody></p:sp>'
                    '</p:spTree></p:cSld></p:sld>')]),
        extract("workbook-absolute-and-external-targets", "workbook.xlsx", "xlsx", workbook,
                [workbook_rels(("rIdA", sheet, "/xl/worksheets/sheet1.xml"),
                               ("rIdB", sheet, "/xl/worksheets/sheet2.xml"),
                               ("rIdS", shared, "/xl/sharedStrings.xml"),
                               ("rIdStyles", styles, "/xl/styles.xml"),
                               ("rIdLink", f"{_OOXML_REL_NS}/hyperlink", "file:///C:/x.xlsx#Sheet1!A1", True),
                               ("rIdBad", f"{_OOXML_REL_NS}/theme", "../../escape.xml"),
                               ("rIdDup", f"{_OOXML_REL_NS}/theme", "theme/theme1.xml"),
                               ("rIdDup", f"{_OOXML_REL_NS}/theme", "theme/theme2.xml"))]),
        extract("workbook-shared-strings-conventional", "workbook.xlsx", "xlsx", workbook,
                [workbook_rels(("rIdA", sheet, "worksheets/sheet1.xml"),
                               ("rIdB", sheet, "worksheets/sheet2.xml"),
                               ("rIdStyles", styles, "styles.xml"))]),
        extract("workbook-chartsheet-skipped", "workbook.xlsx", "xlsx", workbook,
                [replace("xl/workbook.xml",
                    f'<workbook xmlns="{_ASSET_MAIN_NS}" xmlns:r="{_OOXML_REL_NS}"><sheets>'
                    '<sheet name="Zeta" sheetId="2" r:id="rIdB"/><sheet name="Chart" sheetId="3" r:id="rIdC"/>'
                    '<sheet name="Alpha" sheetId="1" r:id="rIdA"/></sheets></workbook>'),
                 workbook_rels(("rIdA", sheet, "worksheets/sheet1.xml"),
                               ("rIdB", sheet, "worksheets/sheet2.xml"),
                               ("rIdC", f"{_OOXML_REL_NS}/chartsheet", "chartsheets/sheet1.xml"),
                               ("rIdS", shared, "sharedStrings.xml"),
                               ("rIdStyles", styles, "styles.xml"))]),
        extract("workbook-duplicate-used-relationship-id", "workbook.xlsx", "xlsx",
                dict(error="invalidRelationship"),
                [workbook_rels(("rIdA", sheet, "worksheets/sheet1.xml"),
                               ("rIdB", sheet, "worksheets/sheet2.xml"),
                               ("rIdB", sheet, "worksheets/sheet1.xml"),
                               ("rIdS", shared, "sharedStrings.xml"),
                               ("rIdStyles", styles, "styles.xml"))]),
    ] + [
        # Persisted sources.error code -> the localized explanation shown next to "Error".
        # null: no specific explanation (the row shows the plain status).
        case("error-text-" + code, "error-text", dict(code=code), dict(key=key))
        for code, key in OOXML_ERROR_TEXT
    ] + [
        case(key, "localization", dict(key=key), dict(en=en, cs=cs)) for key, en, cs in OOXML_LOCALIZATIONS
    ]


def coverage_counts(**changes):
    value = dict(searchable=0, notSearchable=0, current=0, refreshPending=0,
                 refreshError=0, skipped=0, missing=0, unavailable=0, isLowerBound=False)
    value.update(changes)
    return value


def coverage_cases():
    def seed(**changes):
        value = dict(availability="present", eligible=True, status="ready", currentRevision=1,
            publishedRevisionId=1, activeVectorRevision=1, scanState="idle", hasScanItem=False,
            scanKind=None, sourceId=101, folderId=1, notebookId=1, relPath="a.md")
        value.update(changes)
        return value
    rows = [
        ("first-pending", seed(status="pending", currentRevision=None, publishedRevisionId=None,
          activeVectorRevision=None), coverage_counts(notSearchable=1, refreshPending=1)),
        ("first-error", seed(status="error", currentRevision=None, publishedRevisionId=None,
          activeVectorRevision=None), coverage_counts(notSearchable=1, refreshError=1)),
        ("published-current", seed(), coverage_counts(searchable=1, current=1)),
        ("published-refresh-pending", seed(status="chunking", currentRevision=2),
         coverage_counts(searchable=1, refreshPending=1)),
        ("published-refresh-error", seed(status="error", currentRevision=2),
         coverage_counts(searchable=1, refreshError=1)),
        ("newly-published", seed(currentRevision=2, publishedRevisionId=2),
         coverage_counts(searchable=1, current=1)),
        ("newly-published-no-vectors", seed(currentRevision=2, publishedRevisionId=2,
          activeVectorRevision=None), coverage_counts(searchable=1, current=1)),
        ("observed-not-extracted", seed(status="pending"), coverage_counts(searchable=1, refreshPending=1)),
        ("missing-precedence", seed(availability="missing", eligible=False, hasScanItem=True,
          scanKind="skipped", status="error"), coverage_counts(missing=1)),
        ("unavailable-precedence", seed(availability="unavailable", eligible=False, hasScanItem=True,
          scanKind="skipped"), coverage_counts(unavailable=1)),
        ("skipped-source-inventory-dedup", seed(eligible=False, hasScanItem=True, scanKind="skipped"),
         coverage_counts(skipped=1)),
        ("source-less-skipped", seed(sourceId=None, currentRevision=None, publishedRevisionId=None,
          activeVectorRevision=None, eligible=False, hasScanItem=True, scanKind="skipped"), coverage_counts(skipped=1)),
        # Eligible present files are the inventory/source union (§2): an
        # observed file awaits extraction even before its source row exists.
        ("source-less-eligible", seed(sourceId=None, currentRevision=None, publishedRevisionId=None,
          activeVectorRevision=None, hasScanItem=True, scanKind="eligible"),
         coverage_counts(notSearchable=1, refreshPending=1)),
        ("eligible-source-inventory-dedup", seed(hasScanItem=True, scanKind="eligible"),
         coverage_counts(searchable=1, current=1)),
        ("empty-selection", seed(scope=dict(kind="selection", sourceIds=[], folderIds=[])), coverage_counts()),
        ("other-notebook", seed(notebookId=2, queryNotebookId=1), coverage_counts()),
        ("duplicate-folder-source-selection", seed(scope=dict(kind="selection", sourceIds=[101,101], folderIds=[1,1])),
         coverage_counts(searchable=1, current=1)),
        ("partial-empty-folder", seed(sourceId=None, currentRevision=None, publishedRevisionId=None,
          activeVectorRevision=None, scanState="partial", scope=dict(kind="selection", sourceIds=[], folderIds=[1])),
         coverage_counts(isLowerBound=True)),
        ("explicit-source-in-partial-folder", seed(scanState="partial",
          scope=dict(kind="selection", sourceIds=[101], folderIds=[])),
         coverage_counts(searchable=1, current=1, isLowerBound=True)),
    ]
    return [case(n, "coverage", i, e) for n, i, e in rows]


def file_stamp(identity="file1", mtime=10, size=5):
    return dict(identity=identity, mtimeNs=mtime, sizeBytes=size)


def scan_source(source_id=101, path="a.md", **changes):
    value = dict(id=source_id, notebookId=1, folderId=1, relPath=path,
                 status="ready", availability="present", eligible=True,
                 currentRevision=11, publishedRevisionId=11, contentHash="h",
                 mtimeNs=10, sizeBytes=5, error=None)
    value.update(changes)
    return value


def scan_cases():
    root = dict(id=1, notebookId=1, rootPath="/docs", displayName="Docs",
                volumeId="test", components=["docs"], rootFileId="root-1")
    partial = dict(root=copy.deepcopy(root), caseSensitive=True,
        directories={"": [dict(relPath="bad", isDirectory=True, isLink=False),
                           dict(relPath="good", isDirectory=True, isLink=False)], "good": []},
        stats={"": file_stamp("root-1", 0, 0), "bad": file_stamp("dir-bad", 0, 0),
               "good": file_stamp("dir-good", 0, 0)}, listErrors={"bad": "permissionDenied"},
        seedSources=[dict(id=101, relPath="good/gone.md", canonicalText="old"),
                     dict(id=102, relPath="bad/gone.md", canonicalText="old"),
                     dict(id=103, relPath="gone.md", canonicalText="old")])
    result = [case("partial-sibling", "walk", partial,
        dict(completion=dict(completed=["good"], incomplete=["bad", ""], rootUnavailable=False),
             listCalls=["", "bad", "good"], missingSourceIds=[101]))]
    nested = dict(root=copy.deepcopy(root), caseSensitive=True,
        directories={"": [dict(relPath="nested", isDirectory=True, isLink=False)],
                     "nested": [dict(relPath="nested/a.md", isDirectory=False, isLink=False)]},
        stats={"": file_stamp("root-1", 0, 0), "nested": file_stamp("dir-nested", 0, 0),
               "nested/a.md": file_stamp()}, listErrors={}, seedSources=[])
    result.append(case("nested-eligible-file", "walk", nested,
        dict(completion=dict(completed=[""], incomplete=[], rootUnavailable=False),
             listCalls=["", "nested"], visitedPaths=["nested", "nested/a.md"], missingSourceIds=[])))
    ignored = copy.deepcopy(nested)
    ignored.update(ignoreGlobs=["build"], directories={
        "": [dict(relPath="build", isDirectory=True, isLink=False)],
        "build": [dict(relPath="build/a.md", isDirectory=False, isLink=False)]}, stats={
        "": file_stamp("root-1", 0, 0), "build": file_stamp("dir-build", 0, 0),
        "build/a.md": file_stamp()})
    result.append(case("ignored-directory-descendants-listed", "walk", ignored,
        dict(completion=dict(completed=[""], incomplete=[], rootUnavailable=False),
             listCalls=["", "build"], visitedPaths=["build", "build/a.md"], missingSourceIds=[])))
    for name, is_directory, link_kind in [
        ("interior-file-link", False, "symlink"), ("interior-directory-link", True, "symlink"),
        ("junction-skipped", True, "junction"), ("reparse-skipped", True, "reparse")]:
        value = dict(root=copy.deepcopy(root), caseSensitive=True,
            directories={"": [dict(relPath="link", isDirectory=is_directory, isLink=True)]},
            stats={"": file_stamp("root-1", 0, 0), "link": file_stamp("link-1", 0, 0)},
            listErrors={}, seedSources=[], linkKinds={"link": link_kind})
        result.append(case(name, "walk", value, dict(completion=dict(completed=[""],
            incomplete=[], rootUnavailable=False), listCalls=[""], visitedPaths=["link"],
            missingSourceIds=[], targetReadCalls=0)))

    # Identity/open cases address native adapter seams rather than a canned walk.
    identity = dict(volumeId="test", components=["docs"], rootFileId="root-1")
    for name, extra, expected in [
        ("root-alias-allowed-once", dict(action="resolve-root", selectedPath="/alias", resolvedPath="/docs",
            resolvedIdentity=identity, openedIdentity=identity, selectedRootIsLink=True),
         dict(identity=identity, rootResolutions=1, accepted=True)),
        ("retargeted-root", dict(action="validate-root", selectedPath="/alias", resolvedPath="/elsewhere",
            persistedIdentity=identity, openedIdentity=dict(volumeId="test", components=["elsewhere"], rootFileId="root-2")),
         dict(error="rootIdentityChanged", readCalls=0)),
        ("same-path-root-replaced", dict(action="validate-root", selectedPath="/docs", resolvedPath="/docs",
            persistedIdentity=identity, openedIdentity=dict(volumeId="test", components=["docs"], rootFileId="root-2")),
         dict(error="rootIdentityChanged", readCalls=0)),
        ("outside-component", dict(action="containment", rootIdentity=identity, resolvedComponents=["docs2", "a.md"]),
         dict(error="outsideRoot", readCalls=0)),
        ("case-sensitive-distinct", dict(action="canonicalize-paths", caseSensitive=True, paths=["Docs/a.md", "docs/a.md"],
            canonicalPaths=["Docs/a.md", "docs/a.md"]), dict(sourcePaths=["Docs/a.md", "docs/a.md"])),
        ("case-insensitive-alias", dict(action="canonicalize-paths", caseSensitive=False, paths=["Docs/a.md", "docs/A.MD"],
            canonicalPaths=["Docs/a.md", "Docs/a.md"]), dict(sourcePaths=["Docs/a.md"])),
    ]:
        result.append(case(name, "identity", extra, expected))
    for name, extra, code in [
        ("no-follow-open-race", dict(enumerated=file_stamp(), opened=file_stamp("link-2"),
            openedIsLink=True, parentBefore="dir-1", parentAfter="dir-1"), "interiorLink"),
        ("directory-identity-swap", dict(enumerated=file_stamp(), opened=file_stamp(),
            openedIsLink=False, parentBefore="dir-1", parentAfter="dir-2"), "outsideRoot"),
    ]:
        result.append(case(name, "open", dict(root=root, relPath="a.md", **extra),
                           dict(error=code, readCalls=0)))

    def state(sources=None):
        return dict(folder=dict(id=1, notebookId=1, scanState="idle", scanGeneration=0,
                    lastFullScanAt=None, lastScanError=None),
                    sources=copy.deepcopy([scan_source()] if sources is None else sources),
                    revisions=[dict(id=11, sourceId=101, canonicalText="old",
                                    chunks=[dict(text="old", start=0, end=3)])] if sources is None else [],
                    inventory=[], jobs=[dict(id=201, kind="scan", target="folder:1", state="running",
                        attempts=1, leaseToken="scan-1", leaseUntil=300, targetRevision=None)],
                    readCalls=0, listCalls=[])

    def event(events, projection, operation, at, **data):
        events.append(dict(operation=operation, at=at, **data, expected=copy.deepcopy(projection)))

    def start(projection, events, entries):
        projection["folder"].update(scanState="scanning", scanGeneration=1)
        projection["listCalls"].append("")
        event(events, projection, "list", 0, directory="", entries=entries, beginScan=True,
              folderId=1, generation=1, jobId=201, leaseToken="scan-1")

    def finish(projection, events, at=3, completed=None, incomplete=None):
        incomplete = incomplete or []
        projection["folder"].update(scanState="partial" if incomplete else "idle")
        if not incomplete:
            projection["folder"]["lastFullScanAt"] = at
        projection["jobs"][0].update(state="done", leaseToken=None, leaseUntil=None)
        event(events, projection, "finish", at, folderId=1, generation=1,
              completed=[""] if completed is None else completed, incomplete=incomplete,
              rootUnavailable=False)

    for name, mtime, hashed, changed, verify in [
        ("fast-path", 10, False, False, False), ("same-hash", 11, True, False, False),
        ("verify-all", 10, True, False, True), ("changed", 11, True, True, False)]:
        projection = state()
        seed = copy.deepcopy(projection)
        events = []
        start(projection, events, [dict(relPath="a.md", isDirectory=False, isLink=False)])
        stamp = file_stamp(mtime=mtime)
        event(events, projection, "stat", 1, relPath="a.md", stamp=stamp)
        projection["sources"][0]["mtimeNs"] = mtime
        projection["inventory"] = [dict(folderId=1, relPath="a.md", kind="eligible",
            skipReason=None, mtimeNs=mtime, sizeBytes=5, seenGeneration=1)]
        if hashed:
            projection["readCalls"] += 1
        if changed:
            projection["sources"][0]["status"] = "pending"
            projection["jobs"].append(dict(id=202, kind="extract", target="source:101", targetRevision=11,
                state="queued", attempts=0, leaseToken=None, leaseUntil=None))
        if hashed:
            event(events, projection, "read", 2, relPath="a.md", hash="new" if changed else "h", stamp=stamp)
        finish(projection, events)
        result.append(case(name, "scan", dict(root=root, seed=seed, verifyAll=verify, events=events), projection))

    # Classification never opens ignored, unsupported or oversize file bodies.
    classified = [("ignore-" + str(i + 1), p, "ignored") for i, p in enumerate([
        ".hidden.md", "node_modules/a.md", ".git/config", "build/a.md", "dist/a.md", ".venv/a.md",
        "__pycache__/a.md", "target/a.md", "bin/a.md", "obj/a.md", "~$document.docx"])]
    classified += [("unsupported-extension", "image.png", "unsupported_ext"),
                   ("oversize-file", "huge.md", "over_limit")]
    for name, path, reason in classified:
        projection = state([])
        seed = copy.deepcopy(projection)
        events = []
        # The flat visit trace follows a separate walk; all directory ancestors
        # are explicitly listed so ignored trees cannot accidentally be pruned.
        parent = path.rpartition("/")[0]
        start(projection, events, [dict(relPath=parent or path, isDirectory=bool(parent), isLink=False)])
        if parent:
            projection["listCalls"].append(parent)
            event(events, projection, "list", 1, directory=parent,
                  entries=[dict(relPath=path, isDirectory=False, isLink=False)])
        size = 52428801 if reason == "over_limit" else 5
        projection["inventory"] = [dict(folderId=1, relPath=path, kind="skipped", skipReason=reason,
                                       mtimeNs=10, sizeBytes=size, seenGeneration=1)]
        event(events, projection, "stat", 2, relPath=path, stamp=file_stamp(size=size))
        finish(projection, events)
        result.append(case(name, "scan", dict(root=root, seed=seed, ignoreGlobs=DEFAULT_IGNORES,
            maxFileBytes=52428800, verifyAll=False, events=events), projection))

    for name, op, scan_state, error in [
        ("cancelled", "cancel", "partial", None),
        ("root-offline", "rootUnavailable", "unavailable", "rootUnavailable"),
        ("unexpected-error", "deny", "error", "unexpectedError")]:
        projection = state()
        seed = copy.deepcopy(projection)
        events = []
        if op == "rootUnavailable":
            projection["folder"].update(scanState="scanning", scanGeneration=1)
        else:
            start(projection, events, [])
        projection["folder"].update(scanState=scan_state, lastScanError=error)
        projection["jobs"][0].update(state="cancelled" if op == "cancel" else "done",
                                    leaseToken=None, leaseUntil=None)
        if op == "rootUnavailable":
            projection["sources"][0]["availability"] = "unavailable"
        event(events, projection, op, 1, directory="", error=error,
              beginScan=op == "rootUnavailable", folderId=1, generation=1,
              jobId=201, leaseToken="scan-1")
        result.append(case(name, "scan", dict(root=root, seed=seed, verifyAll=False, events=events), projection))

    projection = state()
    projection["folder"].update(scanState="scanning", scanGeneration=2)
    projection["jobs"][0].update(leaseToken="scan-2")
    seed = copy.deepcopy(projection)
    events = []
    event(events, projection, "finish", 1, folderId=1, generation=1, jobId=201,
          leaseToken="scan-1", completed=[""], incomplete=[], rootUnavailable=False, accepted=False)
    result.append(case("late-old-generation", "scan", dict(root=root, seed=seed,
                       verifyAll=False, events=events), projection))

    # Partial completion and a full follow-up explicitly retain root-level files.
    projection = state([scan_source(101, "good/gone.md"), scan_source(102, "bad/gone.md", currentRevision=12,
        publishedRevisionId=12), scan_source(103, "gone.md", currentRevision=13, publishedRevisionId=13)])
    projection["revisions"] = [dict(id=11+i, sourceId=101+i, canonicalText="old",
        chunks=[dict(text="old", start=0, end=3)]) for i in range(3)]
    seed = copy.deepcopy(projection)
    events = []
    start(projection, events, partial["directories"][""])
    projection["listCalls"].append("bad")
    event(events, projection, "deny", 1, directory="bad", error="permissionDenied")
    projection["listCalls"].append("good")
    event(events, projection, "list", 2, directory="good", entries=[])
    projection["sources"][0]["availability"] = "missing"
    finish(projection, events, completed=["good"], incomplete=["bad", ""])
    projection["folder"].update(scanState="scanning", scanGeneration=2)
    projection["jobs"].append(dict(id=202, kind="scan", target="folder:1", state="running",
        attempts=1, leaseToken="scan-2", leaseUntil=310, targetRevision=None))
    projection["listCalls"].append("")
    event(events, projection, "list", 10, directory="", entries=[], beginScan=True,
          folderId=1, generation=2, jobId=202, leaseToken="scan-2")
    for source in projection["sources"]:
        source["availability"] = "missing"
    projection["folder"].update(scanState="idle", lastFullScanAt=11)
    projection["jobs"][-1].update(state="done", leaseToken=None, leaseUntil=None)
    event(events, projection, "finish", 11, folderId=1, generation=2, jobId=202,
          completed=[""], incomplete=[], rootUnavailable=False)
    result.append(case("partial-then-full", "scan", dict(root=root, seed=seed,
                       verifyAll=False, events=events), projection))

    for name, before, path, hashed in [
        ("reappearance", scan_source(availability="missing"), "a.md", False),
        ("same-bytes-renamed", scan_source(), "renamed.md", True),
        ("duplicate-scans-coalesce", scan_source(status="pending"), "a.md", True)]:
        projection = state()
        projection["sources"] = [before]
        if name == "duplicate-scans-coalesce":
            projection["jobs"].append(dict(id=202, kind="extract", target="source:101", targetRevision=11,
                state="queued", attempts=0, leaseToken=None, leaseUntil=None))
        seed = copy.deepcopy(projection)
        events = []
        start(projection, events, [dict(relPath=path, isDirectory=False, isLink=False)])
        event(events, projection, "stat", 1, relPath=path, stamp=file_stamp())
        if name == "same-bytes-renamed":
            projection["sources"].append(scan_source(102, path, status="pending", currentRevision=None,
                publishedRevisionId=None, contentHash=None))
            projection["jobs"].append(dict(id=202, kind="extract", target="source:102", targetRevision=None,
                state="queued", attempts=0, leaseToken=None, leaseUntil=None))
        else:
            projection["sources"][0]["availability"] = "present"
        projection["inventory"] = [dict(folderId=1, relPath=path, kind="eligible", skipReason=None,
            mtimeNs=10, sizeBytes=5, seenGeneration=1)]
        if hashed:
            projection["readCalls"] += 1
            event(events, projection, "read", 2, relPath=path, hash="new" if name == "duplicate-scans-coalesce" else "h",
                  stamp=file_stamp())
        if name == "same-bytes-renamed":
            projection["sources"][0]["availability"] = "missing"
        finish(projection, events)
        if name == "duplicate-scans-coalesce":
            projection["folder"].update(scanState="scanning", scanGeneration=2)
            projection["jobs"].append(dict(id=203, kind="scan", target="folder:1", state="running",
                attempts=1, leaseToken="scan-2", leaseUntil=310, targetRevision=None))
            projection["listCalls"].append("")
            event(events, projection, "list", 10, directory="",
                  entries=[dict(relPath=path, isDirectory=False, isLink=False)], beginScan=True,
                  folderId=1, generation=2, jobId=203, leaseToken="scan-2")
            event(events, projection, "stat", 11, relPath=path, stamp=file_stamp())
            projection["readCalls"] += 1
            projection["inventory"][0]["seenGeneration"] = 2
            event(events, projection, "read", 12, relPath=path, hash="new", stamp=file_stamp())
            projection["folder"].update(scanState="idle", lastFullScanAt=13)
            projection["jobs"][-1].update(state="done", leaseToken=None, leaseUntil=None)
            event(events, projection, "finish", 13, folderId=1, generation=2, jobId=203,
                  completed=[""], incomplete=[], rootUnavailable=False)
        result.append(case(name, "scan", dict(root=root, seed=seed, verifyAll=False, events=events), projection))

    for name, status, current, published in [("rule-reenable-current", "ready", 11, 11),
                                             ("rule-reenable-unpublished", "pending", None, None)]:
        projection = state()
        projection["sources"] = [scan_source(status=status, currentRevision=current,
            publishedRevisionId=published, contentHash="h" if published else None)]
        projection["jobs"] = []
        if not published:
            projection["revisions"] = []
        seed = copy.deepcopy(projection)
        events = []
        projection["sources"][0]["eligible"] = False
        projection["inventory"] = [dict(folderId=1, relPath="a.md", kind="skipped", skipReason="ignored",
            mtimeNs=10, sizeBytes=5, seenGeneration=0)]
        projection["jobs"] = [dict(id=202, kind="scan", target="folder:1", targetRevision=None,
            state="queued", attempts=0, leaseToken=None, leaseUntil=None)]
        event(events, projection, "apply-rules", 1, folderId=1, ignoreGlobs=["*.md"],
              includeExts=["md"], eligibleSourceIds=[], retrievalSourceIds=[])
        projection["sources"][0]["eligible"] = True
        projection["inventory"][0].update(kind="eligible", skipReason=None)
        if not published:
            projection["jobs"].append(dict(id=203, kind="extract", target="source:101", targetRevision=None,
                state="queued", attempts=0, leaseToken=None, leaseUntil=None))
        event(events, projection, "apply-rules", 2, folderId=1, ignoreGlobs=[],
              includeExts=["md"], eligibleSourceIds=[101], retrievalSourceIds=[101] if published else [])
        result.append(case(name, "rules", dict(root=root, seed=seed, events=events), projection))
    return result


LOCALIZATIONS = [
    ("addFolderButton", "Add folder…", "Přidat složku…"),
    ("folderLastFullScan", "Last full scan", "Poslední úplný sken"),
    ("folderNeverScanned", "Never scanned", "Dosud neskenováno"),
    ("folderWatchEnabled", "Watch for changes", "Sledovat změny"),
    ("folderScanNow", "Scan now", "Skenovat teď"),
    ("folderVerifyAll", "Verify all", "Ověřit vše"),
    ("folderRulesTitle", "Folder rules", "Pravidla složky"),
    ("folderIncludeExtensions", "Include extensions", "Zahrnuté přípony"),
    ("folderIgnoreGlobs", "Ignore patterns (one per line)", "Ignorované vzory (jeden na řádek)"),
    ("folderMaxFileBytes", "Maximum file bytes", "Nejvýše bajtů souboru"),
    ("folderMaxOfficeBytes", "Maximum expanded Office bytes", "Nejvýše rozbalených bajtů Office"),
    ("folderMaxTextScalars", "Maximum text characters", "Nejvýše znaků textu"),
    ("folderMaxPdfPages", "Maximum PDF pages", "Nejvýše stran PDF"),
    ("folderMaxChunks", "Maximum passages per file", "Nejvýše pasáží na soubor"),
    ("folderMaxCells", "Maximum spreadsheet cells", "Nejvýše buněk tabulky"),
    ("folderEncodingFallback", "Text encoding fallback", "Náhradní kódování textu"),
    ("folderEncodingNone", "Strict UTF only", "Pouze striktní UTF"),
    ("folderEncodingCp1250", "Windows-1250", "Windows-1250"),
    ("folderEncodingUsed", "Encoding", "Kódování"),
    ("folderRulesInvalid", "Check patterns, extensions and positive limits.", "Zkontrolujte vzory, přípony a kladné limity."),
    ("folderRemoveButton", "Remove from notebook", "Odebrat z notebooku"),
    ("folderRemoveConfirm", "Remove this folder from the notebook?", "Odebrat tuto složku z notebooku?"),
    ("folderRemoveKeepsFiles", "Files on disk will be kept.", "Soubory na disku zůstanou zachovány."),
    ("folderSearchable", "Searchable", "Prohledatelné"),
    ("folderNotSearchable", "Not yet searchable", "Dosud neprohledatelné"),
    ("folderCurrent", "Current", "Aktuální"),
    ("folderRefreshPending", "Refresh pending", "Čeká na aktualizaci"),
    ("folderRefreshError", "Refresh failed", "Aktualizace selhala"),
    ("folderSkipped", "Skipped", "Přeskočené"),
    ("folderMissing", "Missing", "Chybějící"),
    ("folderUnavailable", "Unavailable", "Nedostupné"),
    ("folderAtLeast", "At least", "Alespoň"),
    ("folderOverlapError", "This folder overlaps a folder already in this notebook.", "Tato složka se překrývá se složkou již přidanou do notebooku."),
    ("folderReadError", "The folder or file could not be read.", "Složku nebo soubor se nepodařilo přečíst."),
    ("folderLimitError", "The extraction limit was exceeded.", "Byl překročen limit extrakce."),
    ("folderEncodingError", "The text encoding is not supported.", "Kódování textu není podporováno."),
    ("folderDocumentError", "The document is damaged or unsupported.", "Dokument je poškozený nebo nepodporovaný."),
    ("scopeWholeNotebook", "Whole notebook", "Celý notebook"),
    ("scopeSelection", "Selected items", "Vybrané položky"),
    ("scopeFolders", "Folders", "Složky"),
    ("scopeSourceSets", "Source sets", "Sady zdrojů"),
    ("scopeSources", "Individual sources", "Jednotlivé zdroje"),
    ("scopeEmpty", "No sources selected", "Nejsou vybrány žádné zdroje"),
    ("reindexButton", "Re-index", "Přeindexovat"),
    ("reindexProgress", "Re-index progress", "Průběh přeindexování"),
    ("reindexDiscovering", "Preparing the new index", "Připravuje se nový index"),
    ("reindexPausedForChat", "Background indexing paused for chat", "Indexování na pozadí je pozastaveno kvůli chatu"),
    ("reindexFailed", "Re-indexing failed; existing search remains available.", "Přeindexování selhalo; stávající vyhledávání zůstává dostupné."),
    ("reindexDualSpaceNote", "The existing index stays available while the new index is built. Temporary extra disk space is required.",
     "Stávající index zůstává dostupný během vytváření nového indexu. Dočasně je potřeba více místa na disku."),
    ("reindexDiscard", "Discard new index", "Zahodit nový index"),
    ("reindexRetry", "Retry re-indexing", "Zkusit přeindexování znovu"),
]


def ui_cases():
    result = [case(key, "localization", dict(key=key), dict(en=en, cs=cs))
              for key, en, cs in LOCALIZATIONS]

    def selection(whole=False, sources=(), folders=(), sets=(), members=()):
        return dict(wholeNotebook=whole, sourceIds=list(sources), folderIds=list(folders),
                    setIds=list(sets), members=list(members))

    def scope(sources=(), folders=()):
        return dict(kind="selection", sourceIds=list(sources), folderIds=list(folders))

    for name, value, expected in [
        ("all", selection(True, [1], [8], [9]), dict(kind="all")),
        ("empty", selection(), scope()),
        ("duplicate-union", selection(False, [1, 1], [8], [9],
            [dict(setId=9, sourceIds=[1, 2], folderIds=[7, 8])]), scope([1, 2], [7, 8])),
        ("all-sources-explicit", selection(False, [1, 2, 3]), scope([1, 2, 3])),
        ("set-membership-old", selection(False, [1], [8], [9],
            [dict(setId=9, sourceIds=[2], folderIds=[7])]), scope([1, 2], [7, 8])),
        ("set-membership-new", selection(False, [1], [8], [9],
            [dict(setId=9, sourceIds=[3], folderIds=[10])]), scope([1, 3], [8, 10])),
        ("removed-set", selection(False, [], [], [9]), scope()),
    ]:
        result.append(case(name, "scope", value, expected))
    store_seed = dict(notebooks=[dict(id=1), dict(id=2)],
        sources=[dict(id=101, notebookId=1, folderId=1), dict(id=102, notebookId=2, folderId=2)],
        folders=[dict(id=1, notebookId=1), dict(id=2, notebookId=2)],
        sets=[dict(id=9, notebookId=1, sourceIds=[101], folderIds=[1]),
              dict(id=10, notebookId=2, sourceIds=[102], folderIds=[2])])
    for name, value, expected in [
        ("removed-explicit-folder", selection(False, [], [99]), dict(scope=scope())),
        ("cross-notebook-source", selection(False, [102]), dict(error="notebookMismatch")),
        ("cross-notebook-folder", selection(False, [], [2]), dict(error="notebookMismatch")),
        ("cross-notebook-set", selection(False, [], [], [10]), dict(error="notebookMismatch")),
        ("owned-set-scope", selection(False, [], [], [9]), dict(scope=scope([101], [1]))),
    ]:
        value.pop("members")
        result.append(case(name, "scope-store", dict(seed=copy.deepcopy(store_seed), notebookId=1,
                                                     selection=value), expected))
    for kind in ["created", "changed", "renamed", "deleted", "overflow"]:
        result.append(case("watch-" + kind, "watch", dict(kind=kind), dict(forceHash=kind != "created")))
    result.extend(runtime_cases())
    return result


def runtime_cases():
    """Millisecond clock with empty fake roots; drain completes one queued scan.

    start-scan/finish-scan are barriers inside drain, used to inject signals while
    enumeration is suspended. source/URL commands inject an extractor and omit
    embedding selection, so provider calls stay zero. Callbacks carry watchToken.
    """
    folders = [dict(id=1, notebookId=1, rootPath="/docs/one", watchEnabled=True),
               dict(id=2, notebookId=2, rootPath="/docs/two", watchEnabled=True),
               dict(id=3, notebookId=1, rootPath="/docs/disabled", watchEnabled=False)]

    def initial():
        return dict(watchedFolderIds=[], queuedJobIds=[], providerCallCount=0, jobs=[],
                    folderIds=[1, 2, 3], sources=[], scanStarts=[], diskDeleteCalls=0)

    def event(events, state, op, at, **data):
        events.append(dict(operation=op, at=at, **data, expected=copy.deepcopy(state)))

    def start(events, state):
        state.update(watchedFolderIds=[1, 2], queuedJobIds=[201, 202], jobs=[
            dict(id=201, kind="scan", folderId=1, state="queued", verifyAll=False),
            dict(id=202, kind="scan", folderId=2, state="queued", verifyAll=False)])
        event(events, state, "start", 0, watchTokens={"1": "watch-1", "2": "watch-2"})

    def row(name, state, events):
        return case(name, "runtime", dict(seed=dict(notebooks=[1, 2], folders=copy.deepcopy(folders),
            jobs=[], sources=[]), embeddingSelection=None, projectJobKinds=["scan"], events=events), state)

    result = []
    state, events = initial(), []
    start(events, state)
    event(events, state, "start", 1)  # Idempotent; disabled folder remains absent.
    state["watchedFolderIds"] = []
    event(events, state, "stop", 2)
    result.append(row("runtime-two-notebooks-disabled-and-stop", state, events))

    state, events = initial(), []
    start(events, state)
    state["watchedFolderIds"] = [2]
    event(events, state, "watch", 1, folderId=1, enabled=False)
    state["folderIds"] = [1, 3]
    state["watchedFolderIds"] = []
    state["queuedJobIds"] = [201]
    state["jobs"][1]["state"] = "cancelled"
    event(events, state, "remove", 2, folderId=2)
    event(events, state, "signal", 3, folderId=2, watchToken="watch-2", forceHash=True)
    event(events, state, "tick", 503)
    result.append(row("runtime-callback-after-remove", state, events))

    state, events = initial(), []
    start(events, state)
    state["jobs"][0]["state"] = "running"
    state["queuedJobIds"] = [202]
    state["scanStarts"] = [201]
    event(events, state, "start-scan", 1, jobId=201, folderId=1)
    event(events, state, "signal", 100, folderId=1, watchToken="watch-1", forceHash=False)
    event(events, state, "signal", 200, folderId=1, watchToken="watch-1", forceHash=True)
    state["jobs"][0]["state"] = "done"
    event(events, state, "finish-scan", 300, jobId=201, folderId=1)
    event(events, state, "tick", 699)
    state["queuedJobIds"] = [202, 203]
    state["jobs"].append(dict(id=203, kind="scan", folderId=1, state="queued", verifyAll=True))
    event(events, state, "tick", 700)
    state["jobs"][1]["state"] = "done"
    state["queuedJobIds"] = [203]
    state["scanStarts"].append(202)
    event(events, state, "drain", 701, jobId=202)
    state["jobs"][2]["state"] = "done"
    state["queuedJobIds"] = []
    state["scanStarts"].append(203)
    event(events, state, "drain", 702, jobId=203)
    event(events, state, "drain", 703, jobId=None)
    result.append(row("runtime-one-trailing-scan", state, events))

    for name, kind, uri in [("runtime-loose-source", "text", None),
                            ("runtime-url-refresh", "url", "https://fixture.invalid/doc")]:
        state, events = initial(), []
        state["sources"] = [dict(id=101, notebookId=1, type=kind, uri=uri,
            publishedRevisionId=11, canonicalText="first", retainedRevisionIds=[11])]
        event(events, state, "ingest-source", 0, sourceId=101, notebookId=1, kind=kind,
              uri=uri, text="first", leaseToken="source-1")
        state["sources"][0].update(publishedRevisionId=12, canonicalText="second", retainedRevisionIds=[11, 12])
        event(events, state, "refresh-url" if uri else "refresh-source", 1,
              sourceId=101, text="second", leaseToken="source-2")
        result.append(row(name, state, events))
    return result


_ASSET_XML_DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
_ASSET_PACKAGE_NS = 'http://schemas.openxmlformats.org/package/2006/relationships'
_ASSET_REL_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
_ASSET_MAIN_NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'


def _asset_xml(body: str) -> bytes:
    return (_ASSET_XML_DECL + body + '\n').encode('utf-8')


def _asset_zip(parts: list[tuple[str, bytes]]) -> bytes:
    """Freeze entry order and every writable ZIP metadata field."""
    output = io.BytesIO()
    with zipfile.ZipFile(output, mode='w', compression=zipfile.ZIP_STORED) as archive:
        for name, data in parts:
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_STORED
            entry.create_system = 0
            entry.create_version = 20
            entry.extract_version = 20
            entry.external_attr = 0x20  # DOS archive attribute; avoids host defaults.
            entry.internal_attr = 0
            entry.flag_bits = 0
            entry.extra = b''
            entry.comment = b''
            archive.writestr(entry, data)
    return output.getvalue()


def _asset_content_types(overrides: list[tuple[str, str]]) -> bytes:
    return _asset_xml(
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        + ''.join(f'<Override PartName="/{name}" ContentType="{kind}"/>' for name, kind in overrides)
        + '</Types>')


def _asset_root_relationship(target: str) -> bytes:
    return _asset_xml(f'<Relationships xmlns="{_ASSET_PACKAGE_NS}">'
                      f'<Relationship Id="rId1" Type="{_ASSET_REL_NS}/officeDocument" Target="{target}"/>'
                      '</Relationships>')


def _asset_docx() -> bytes:
    return _asset_zip([
        ('[Content_Types].xml', _asset_content_types([
            ('word/document.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml')])),
        ('_rels/.rels', _asset_root_relationship('word/document.xml')),
        ('word/document.xml', _asset_xml(
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            '<w:body><w:p><w:r><w:t>A</w:t></w:r></w:p>'
            '<w:p><w:r><w:t>B</w:t></w:r><w:r><w:t>😀</w:t></w:r></w:p>'
            '<w:p/></w:body></w:document>')),
    ])


def _asset_document2_docx() -> bytes:
    """Main part reached only through a package-absolute relationship target."""
    w, r = _OOXML_WORD_NS, _ASSET_REL_NS
    return _asset_zip([
        ('[Content_Types].xml', _asset_content_types([
            ('word/document2.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'),
            ('docProps/core.xml', 'application/vnd.openxmlformats-package.core-properties+xml')])),
        ('_rels/.rels', _asset_xml(_ooxml_relationships(
            ('rId1', f'{r}/officeDocument', '/word/document2.xml'),
            ('rId2', f'{_ASSET_PACKAGE_NS}/metadata/core-properties', '/docProps/core.xml'),
            ('rId3', f'{r}/extended-properties', 'docProps/app.xml')))),
        ('docProps/core.xml', _asset_xml(
            '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Document Two</dc:title></cp:coreProperties>')),
        ('word/document2.xml', _asset_xml(
            f'<w:document xmlns:w="{w}" xmlns:r="{r}" '
            'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
            'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" '
            'xmlns:v="urn:schemas-microsoft-com:vml" mc:Ignorable="wps"><w:body>'
            '<w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr>'
            '<w:hyperlink r:id="rIdLink"><w:r><w:t>Alpha</w:t></w:r></w:hyperlink>'
            '<w:r><w:tab/><w:t>Beta</w:t></w:r></w:p>'
            '<w:p><w:r><w:t xml:space="preserve">Before </w:t></w:r><w:r><mc:AlternateContent>'
            '<mc:Choice Requires="wps"><w:drawing><wps:wsp><wps:txbx><w:txbxContent>'
            '<w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp></w:drawing></mc:Choice>'
            '<mc:Fallback><w:pict><v:shape><v:textbox><w:txbxContent>'
            '<w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></v:textbox></v:shape></w:pict></mc:Fallback>'
            '</mc:AlternateContent></w:r><w:r><w:t>After</w:t></w:r></w:p>'
            '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
            '<w:sectPr/></w:body></w:document>')),
        ('word/_rels/document2.xml.rels', _asset_xml(_ooxml_relationships(
            ('rIdLink', f'{r}/hyperlink', 'https://example.invalid/a?b=c#frag', True),
            ('rIdNull', f'{r}/hyperlink', 'NULL', True),
            ('rIdBad', f'{r}/image', '../../outside.png')))),
    ])


def _asset_slide(text: str) -> bytes:
    return _asset_xml(
        '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/>'
        '<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
        '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/>'
        '<p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/>'
        '<p:txBody><a:bodyPr/><a:lstStyle/>'
        f'<a:p><a:r><a:t>{text}</a:t></a:r></a:p>'
        '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>')


def _asset_pptx() -> bytes:
    return _asset_zip([
        ('[Content_Types].xml', _asset_content_types([
            ('ppt/presentation.xml', 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml'),
            ('ppt/slides/slide2.xml', 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml'),
            ('ppt/slides/slide10.xml', 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml')])),
        ('_rels/.rels', _asset_root_relationship('ppt/presentation.xml')),
        ('ppt/presentation.xml', _asset_xml(
            '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
            f'xmlns:r="{_ASSET_REL_NS}">'
            '<p:sldIdLst><p:sldId id="256" r:id="rId10"/>'
            '<p:sldId id="257" r:id="rId2"/></p:sldIdLst>'
            '<p:sldSz cx="9144000" cy="6858000"/>'
            '<p:notesSz cx="6858000" cy="9144000"/></p:presentation>')),
        ('ppt/_rels/presentation.xml.rels', _asset_xml(
            f'<Relationships xmlns="{_ASSET_PACKAGE_NS}">'
            f'<Relationship Id="rId2" Type="{_ASSET_REL_NS}/slide" Target="slides/slide2.xml"/>'
            f'<Relationship Id="rId10" Type="{_ASSET_REL_NS}/slide" Target="slides/slide10.xml"/>'
            '</Relationships>')),
        # Physical order and numeric filename order both disagree with presentation order.
        ('ppt/slides/slide2.xml', _asset_slide('B')),
        ('ppt/slides/slide10.xml', _asset_slide('A')),
    ])


def _asset_xlsx_parts() -> list[tuple[str, bytes]]:
    return [
        ('[Content_Types].xml', _asset_content_types([
            ('xl/workbook.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'),
            ('xl/worksheets/sheet1.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'),
            ('xl/worksheets/sheet2.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'),
            ('xl/sharedStrings.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml'),
            ('xl/styles.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml')])),
        ('_rels/.rels', _asset_root_relationship('xl/workbook.xml')),
        ('xl/workbook.xml', _asset_xml(
            f'<workbook xmlns="{_ASSET_MAIN_NS}" xmlns:r="{_ASSET_REL_NS}">'
            '<workbookPr date1904="0"/><sheets>'
            '<sheet name="Zeta" sheetId="2" r:id="rIdB"/>'
            '<sheet name="Alpha" sheetId="1" r:id="rIdA"/>'
            '</sheets></workbook>')),
        ('xl/_rels/workbook.xml.rels', _asset_xml(
            f'<Relationships xmlns="{_ASSET_PACKAGE_NS}">'
            f'<Relationship Id="rIdA" Type="{_ASSET_REL_NS}/worksheet" Target="worksheets/sheet1.xml"/>'
            f'<Relationship Id="rIdB" Type="{_ASSET_REL_NS}/worksheet" Target="worksheets/sheet2.xml"/>'
            f'<Relationship Id="rIdS" Type="{_ASSET_REL_NS}/sharedStrings" Target="sharedStrings.xml"/>'
            f'<Relationship Id="rIdStyles" Type="{_ASSET_REL_NS}/styles" Target="styles.xml"/>'
            '</Relationships>')),
        ('xl/sharedStrings.xml', _asset_xml(
            f'<sst xmlns="{_ASSET_MAIN_NS}" count="1" uniqueCount="1">'
            '<si><r><t>Pří</t></r><r><t>liš</t></r></si></sst>')),
        ('xl/styles.xml', _asset_xml(
            f'<styleSheet xmlns="{_ASSET_MAIN_NS}">'
            '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
            '<fills count="2"><fill><patternFill patternType="none"/></fill>'
            '<fill><patternFill patternType="gray125"/></fill></fills>'
            '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
            '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
            '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
            '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'
            '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
            '</styleSheet>')),
        ('xl/worksheets/sheet1.xml', _asset_xml(
            f'<worksheet xmlns="{_ASSET_MAIN_NS}"><sheetData>'
            '<row r="1"><c r="A1" t="inlineStr"><is><t>last</t></is></c></row>'
            '</sheetData></worksheet>')),
        ('xl/worksheets/sheet2.xml', _asset_xml(
            f'<worksheet xmlns="{_ASSET_MAIN_NS}"><sheetData>'
            '<row r="3"><c r="C3" s="1"><v>45292</v></c>'
            '<c r="A3"><f>1+1</f><v>2</v></c></row>'
            '<row r="1"><c r="C1" t="inlineStr"><is><r><t>A😀</t></r><r><t>B</t></r></is></c>'
            '<c r="B1"/><c r="A1" t="s"><v>0</v></c></row>'
            '<row r="2"><c r="C2" t="e"><v>#DIV/0!</v></c>'
            '<c r="B2" t="b"><v>1</v></c><c r="A2"><v>42</v></c></row>'
            '</sheetData></worksheet>')),
    ]


def _asset_replace(parts: list[tuple[str, bytes]], part_name: str, before: bytes, after: bytes) -> list[tuple[str, bytes]]:
    output = []
    matches = 0
    for name, data in parts:
        if name == part_name:
            if data.count(before) != 1:
                raise ValueError(f'Expected one replacement in {part_name}')
            data = data.replace(before, after, 1)
            matches += 1
        output.append((name, data))
    if matches != 1:
        raise ValueError(f'Expected one part named {part_name}')
    return output


def _asset_pdf() -> bytes:
    """Three pages A / blank / B; compute byte offsets rather than hard-code them."""
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 8 0 R >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 9 0 R >>',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    ]
    for stream in [b'BT /F1 12 Tf 72 720 Td (A) Tj ET\n', b'', b'BT /F1 12 Tf 72 720 Td (B) Tj ET\n']:
        objects.append(f'<< /Length {len(stream)} >>\nstream\n'.encode('ascii') + stream + b'endstream')
    objects.append(b'<< /Title (Ingestion fixture) /Producer (AI Notebook deterministic fixtures) >>')
    # A binary comment keeps Git from treating fixed-width xref records (whose
    # final space is required with LF) as trailing whitespace in a text file.
    data = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\x00\n')
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f'{index} 0 obj\n'.encode('ascii') + body + b'\nendobj\n')
    xref = len(data)
    data.extend(f'xref\n0 {len(objects) + 1}\n'.encode('ascii'))
    data.extend(b'0000000000 65535 f \n')
    for offset in offsets[1:]:
        data.extend(f'{offset:010d} 00000 n \n'.encode('ascii'))
    data.extend(f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R /Info 10 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode('ascii'))
    return bytes(data)


def asset_bytes() -> dict[str, bytes]:
    """Keys are relative to Tests/fixtures, matching each case's input.asset."""
    workbook = _asset_xlsx_parts()
    external = _asset_replace(workbook, 'xl/_rels/workbook.xml.rels',
        b'Target="worksheets/sheet2.xml"',
        b'Target="https://fixture.invalid/sheet.xml" TargetMode="External"')
    bad_index = _asset_replace(workbook, 'xl/worksheets/sheet2.xml',
        b'<c r="A1" t="s"><v>0</v></c>', b'<c r="A1" t="s"><v>9</v></c>')
    return {
        'ingestion/paragraphs.docx': _asset_docx(),
        'ingestion/slides.pptx': _asset_pptx(),
        'ingestion/workbook.xlsx': _asset_zip(workbook),
        'ingestion/pages.pdf': _asset_pdf(),
        'ingestion/corrupt.docx': b'PK\x03\x04truncated-ingestion-archive\n',
        'ingestion/external.xlsx': _asset_zip(external),
        'ingestion/bad-index.xlsx': _asset_zip(bad_index),
        'ingestion/document2.docx': _asset_document2_docx(),
    }


def write_assets(root: Path) -> None:
    """Write only the eight explicitly owned assets below a fixture directory."""
    for relative, data in asset_bytes().items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


# Independent literal queue and generation traces.

TRACE_OPERATIONS = {
    "jobs": {"claim", "claim-race", "claim-many", "recover-expired", "renew", "fail", "publish", "user-retry", "requeue-retryable"},
    "admission": {"acquire", "release", "cancel-waiter", "memory-pressure", "begin-chat", "end-chat", "background-batch", "query-embedding"},
    "schedule": {"signal", "started", "finished", "tick"},
    "generation": {"request-build", "claim", "begin-batch", "commit-batch", "activate", "publish-revision", "recover-expired", "provider-failure", "discard", "pin", "unpin", "gc", "begin-chat", "end-chat", "query-embedding", "change-selection", "invalidate-selection", "set-eligibility", "retrieve", "finish-empty", "renew"},
    "reconcile": {"start", "tick", "complete-scan", "manual-scan", "stop"},
    "embedding-session": {"capture", "mutate-config", "embed", "serialize", "rotate-key"},
}


def _case(name, operation, seed, events):
    return dict(name=name, operation=operation, input={**deepcopy(seed), "events": events}, expected=deepcopy(events[-1]["expected"]))


def _event(operation, at, expected, **args):
    return dict(operation=operation, at=at, **deepcopy(args), expected=deepcopy(expected))


def _job(id=301, state="queued", attempts=0, token=None, until=None, retry=None,
         kind="extract", target="source:101", target_revision=11, error=None, options=None):
    return dict(id=id, kind=kind, target=target, targetRevision=target_revision,
                state=state, attempts=attempts, leaseToken=token, leaseUntil=until,
                nextRetryAt=retry, error=error, options={} if options is None else deepcopy(options))


def _source(id=101, revision=11, folder=1, notebook=1):
    return dict(id=id, notebookId=notebook, folderId=folder, availability="present", eligible=True,
                status="ready", currentRevision=revision, publishedRevisionId=revision)


def _job_projection(jobs, accepted=True, published=None, source_status="chunking"):
    source=_source();source["status"]=source_status
    return dict(jobs=deepcopy(jobs), sources=[source], accepted=accepted,
                publishedRevisionIds=[] if published is None else published)


def jobs_cases():
    out=[]
    queued=_job()
    running=_job(state="running", attempts=1, token="lease-a", until=300)
    seed=dict(notebookIds=[1], folderIds=[1], sources=[_source()],
              revisions=[dict(id=11, sourceId=101, canonicalText="old", chunks=[dict(id=111,text="old",start=0,end=3)])], jobs=[queued])
    # The real two-connection barrier race may elect either contender. The adapter
    # first verifies the stored token is exactly one contender token, then applies
    # tokenNormalization solely to the compared projection (never store state).
    race_winner=_job(state="running",attempts=1,token="winner",until=300)
    out.append(_case("two-claims", "jobs", {**seed,"tokenNormalization":{"lease-a":"winner","lease-b":"winner"}}, [
        _event("claim-race",0,{**_job_projection([race_winner]),"winnerTokenCount":1,"acceptedCount":1,"rejectedCount":1}, jobId=301,
               contenders=[dict(store="connection-a",leaseToken="lease-a"),dict(store="connection-b",leaseToken="lease-b")],
               barrier="before-atomic-claim")]))
    s={**seed,"jobs":[running],"sources":[{**_source(),"status":"chunking"}]}
    # Retryable expiry (storage-job-handoff-v1): the job keeps the leaseExpired
    # diagnostic and the fenced source returns to pending until the next claim.
    expired=_job(attempts=1,retry=360,error="leaseExpired")
    claimed=_job(state="running",attempts=2,token="lease-b",until=660)
    out.append(_case("restart-expiry","jobs",s,[
        _event("recover-expired",300,_job_projection([expired],source_status="pending"),process="replacement"),
        _event("claim",359,_job_projection([expired],False,source_status="pending"),jobId=301,leaseToken="too-early"),
        _event("claim",360,_job_projection([claimed]),jobId=301,leaseToken="lease-b")]))
    renewed=_job(state="running",attempts=1,token="lease-a",until=360)
    out.append(_case("renew-60","jobs",s,[
        _event("renew",60,_job_projection([renewed]),jobId=301,leaseToken="lease-a")]))
    replacement=_job(state="running",attempts=2,token="lease-b",until=660)
    for name,op in [("stale-fail","fail"),("stale-publish","publish")]:
        args=dict(jobId=301,leaseToken="lease-a")
        if op=="fail": args["error"]="old-worker-error"
        else: args.update(requestedRevision=11,revisionDraft=dict(id=12,canonicalText="new",chunks=[dict(id=112,text="new",start=0,end=3)]))
        out.append(_case(name,"jobs",{**seed,"jobs":[replacement],"sources":[{**_source(),"status":"chunking"}]},[
            _event(op,361,_job_projection([replacement],False),**args)]))
    many=[_job(id=400+i) for i in range(100)]
    many_claimed=[_job(id=400+i,state="running",attempts=1,token=f"unique-{i:03}",until=300) for i in range(100)]
    out.append(_case("token-unique","jobs",{**seed,"jobs":many},[
        _event("claim-many",0,{**_job_projection(many_claimed),"issuedLeaseTokens":[f"unique-{i:03}" for i in range(100)]},
               jobIds=list(range(400,500)),tokenSequence=[f"unique-{i:03}" for i in range(100)])]))
    exhausted=_job(state="failed",attempts=5,error="extract-failed")
    fresh=_job(id=302)
    out.append(_case("exhausted-user-retry","jobs",{**seed,"jobs":[exhausted],"sources":[{**_source(),"status":"error"}]},[
        _event("claim",1000,_job_projection([exhausted],False,source_status="error"),jobId=301,leaseToken="sixth"),
        _event("user-retry",1001,_job_projection([exhausted,fresh],source_status="pending"),jobId=301,newJobId=302)]))

    def admission(name,steps,budget=536870912):
        state=dict(reservations=[],waiters=[],chatTokens=[],backgroundWaiters=[],startedBackgroundBatches=[],queryInputs=[],cancelledWaiters=[],providerCallCount=0,memoryPressure=False)
        events=[]
        for op,at,changes,args in steps:
            state.update(deepcopy(changes));events.append(_event(op,at,state,**args))
        out.append(_case(name,"admission",dict(maxExtractions=2,memoryBytes=budget,seed= dict(reservations=[],waiters=[],chatTokens=[],memoryPressure=False)),events))
    r1=dict(token="extract-a",bytes=10);r2=dict(token="extract-b",bytes=10);r3=dict(token="extract-c",bytes=10)
    admission("concurrency-two",[
        ("acquire",0,{"reservations":[r1]},dict(requestId="a",bytes=10,token="extract-a")),
        ("acquire",1,{"reservations":[r1,r2]},dict(requestId="b",bytes=10,token="extract-b")),
        ("acquire",2,{"waiters":[dict(requestId="c",bytes=10,token="extract-c")]},dict(requestId="c",bytes=10,token="extract-c")),
        ("release",3,{"reservations":[r2,r3],"waiters":[]},dict(token="extract-a"))])
    big1=dict(token="extract-a",bytes=400000000);big2=dict(token="extract-b",bytes=400000000)
    admission("memory-one",[
        ("acquire",0,{"reservations":[big1]},dict(requestId="a",bytes=400000000,token="extract-a")),
        ("acquire",1,{"waiters":[dict(requestId="b",bytes=400000000,token="extract-b")]},dict(requestId="b",bytes=400000000,token="extract-b")),
        ("release",2,{"reservations":[big2],"waiters":[]},dict(token="extract-a"))])
    admission("chat-two-tokens",[
        ("begin-chat",0,{"chatTokens":["chat-a"]},dict(token="chat-a")),
        ("begin-chat",1,{"chatTokens":["chat-a","chat-b"]},dict(token="chat-b")),
        ("background-batch",2,{"backgroundWaiters":["batch-a"]},dict(batchId="batch-a")),
        ("end-chat",3,{"chatTokens":["chat-b"]},dict(token="chat-a")),
        ("end-chat",4,{"chatTokens":[],"backgroundWaiters":[],"startedBackgroundBatches":["batch-a"],"providerCallCount":1},dict(token="chat-b"))])
    admission("chat-query-unblocked",[
        ("begin-chat",0,{"chatTokens":["chat-a"]},dict(token="chat-a")),
        ("background-batch",1,{"backgroundWaiters":["batch-a"]},dict(batchId="batch-a")),
        ("query-embedding",2,{"queryInputs":["question"],"providerCallCount":1},dict(text="question",vector=[1,0]))])
    admission("cancel-releases",[
        ("acquire",0,{"reservations":[r1]},dict(requestId="a",bytes=10,token="extract-a")),
        ("acquire",1,{"reservations":[r1,r2]},dict(requestId="b",bytes=10,token="extract-b")),
        ("acquire",2,{"waiters":[dict(requestId="c",bytes=10,token="extract-c")]},dict(requestId="c",bytes=10,token="extract-c")),
        ("release",3,{"reservations":[r2,r3],"waiters":[]},dict(token="extract-a",reason="cancelled")),
        ("release",4,{},dict(token="extract-a",reason="duplicate-release"))])
    admission("cancel-waiter",[
        ("memory-pressure",0,{"memoryPressure":True},dict(blocked=True)),
        ("acquire",1,{"waiters":[dict(requestId="a",bytes=10,token="extract-a")]},dict(requestId="a",bytes=10,token="extract-a")),
        ("cancel-waiter",2,{"waiters":[],"cancelledWaiters":["a"]},dict(requestId="a")),
        ("memory-pressure",3,{"memoryPressure":False},dict(blocked=False))])
    admission("oversize-runs-alone",[
        ("acquire",0,{"reservations":[dict(token="extract-a",bytes=536870912)]},dict(requestId="a",bytes=600000000,token="extract-a")),
        ("acquire",1,{"waiters":[dict(requestId="b",bytes=10,token="extract-b")]},dict(requestId="b",bytes=10,token="extract-b")),
        ("release",2,{"reservations":[r2],"waiters":[]},dict(token="extract-a"))])
    admission("memory-pressure-clears",[
        ("memory-pressure",0,{"memoryPressure":True},dict(blocked=True)),
        ("acquire",1,{"waiters":[dict(requestId="a",bytes=10,token="extract-a")]},dict(requestId="a",bytes=10,token="extract-a")),
        ("memory-pressure",2,{"memoryPressure":False,"reservations":[r1],"waiters":[]},dict(blocked=False))])

    def sched(due=None,running=False,first=None,last=None,trailing_first=None,trailing_last=None,started=0):
        return dict(dueAt=due,running=running,firstSignal=first,lastSignal=last,trailingFirstSignal=trailing_first,trailingLastSignal=trailing_last,startedScanCount=started)
    out.append(_case("debounce","schedule",dict(clockUnit="monotonic-milliseconds",seed=sched()),[
        _event("signal",0,sched(500,first=0,last=0)),
        _event("signal",400,sched(900,first=0,last=400)),
        _event("signal",800,sched(1300,first=0,last=800))]))
    out.append(_case("max-coalesce","schedule",dict(clockUnit="monotonic-milliseconds",seed=sched()),[
        _event("signal",at,sched(min(at+500,5000),first=0,last=at)) for at in range(0,5000,100)]))
    out.append(_case("signal-during-scan","schedule",dict(clockUnit="monotonic-milliseconds",seed=sched()),[
        _event("signal",0,sched(500,first=0,last=0)),
        _event("started",500,sched(running=True,started=1)),
        _event("signal",600,sched(running=True,trailing_first=600,trailing_last=600,started=1)),
        _event("signal",700,sched(running=True,trailing_first=600,trailing_last=700,started=1)),
        _event("finished",800,sched(1200,first=600,last=700,started=1)),
        _event("started",1200,sched(running=True,started=2)),
        _event("finished",1300,sched(started=2)),
        _event("tick",2000,sched(started=2))]))
    return out


def _identity(**changes):
    value=dict(providerId="local",endpointRevision=hashlib.sha256(b"ollama\nhttp://localhost:11434").hexdigest(),model="embed-a",modelDigest=None,dims=2,normalization="l2",queryFormatVersion="1",docFormatVersion="1",chunkerVersion="2")
    value.update(changes)
    return value


def _revision(id,source,text,chunk):
    return dict(id=id,sourceId=source,canonicalText=text,textFormatVersion=1,chunkerVersion=2,chunks=[dict(id=chunk,text=text,start=0,end=len(text),tokenCount=max(1,(len(text)+3)//4))])


def _manifest(source=101,revision=11,state="pending",reason=None):
    return dict(sourceId=source,revisionId=revision,state=state,reason=reason)


def _generation(id=10,state="active",identity=None,manifest=None,vectors=None):
    return dict(id=id,notebookId=1,state=state,identity=_identity() if identity is None else deepcopy(identity),
                manifest=[_manifest(101,11,"done"),_manifest(102,21,"done")] if manifest is None else deepcopy(manifest),
                vectors=[dict(chunkId=111,revisionId=11,values=[1,0]),dict(chunkId=211,revisionId=21,values=[0,1])] if vectors is None else deepcopy(vectors))


def _gen_state():
    return dict(activeGenerationId=10,selectedSelection=_identity(),sources=[_source(),_source(102,21)],
                revisions=[_revision(11,101,"old",111),_revision(21,102,"beta",211)],generations=[_generation()],jobs=[],pins=[],chatTokens=[],inFlightBatches=[],providerRequests=[],providerCallCount=0,queryProviderCallCount=0,retrieval=None)


def _build_job(state="queued",attempts=0,token=None,until=None,target="generation:20",selection=None,copy=False,error=None,retry=None):
    return _job(state=state,attempts=attempts,token=token,until=until,retry=retry,kind="embed",target=target,target_revision=None,error=error,
                options=dict(selection=_identity() if selection is None else deepcopy(selection),copyExisting=copy))


# Production background batch size (FolderIndexCoordinator on both platforms): chunks per provider request.
GENERATION_BATCH_SIZE = 64


def _gen_seed(state):
    return dict(notebookIds=[1],folderIds=[1],clockUnit="epoch-seconds",batchSize=GENERATION_BATCH_SIZE,seed=deepcopy(state))


def _build_state(identity=None,copy=False,unknown=False):
    s=_gen_state();ident=_identity() if identity is None else deepcopy(identity);s["selectedSelection"]=ident
    if unknown:
        s["jobs"]=[_build_job(target="notebook:1",selection=ident,copy=copy)]
    else:
        s["generations"].append(_generation(20,"building",identity=ident,manifest=[_manifest(),_manifest(102,21)],vectors=[]))
        s["jobs"]=[_build_job(selection=ident,copy=copy)]
    return s


def _claimed_state(state,at=1,attempt=1,token="build-a"):
    s=deepcopy(state);j=s["jobs"][0];j.update(state="running",attempts=attempt,leaseToken=token,leaseUntil=at+300,nextRetryAt=None)
    return s


def _request(batch_id,chunk_ids,revision_ids,texts,selection=None,kind="background"):
    ident=_identity() if selection is None else selection
    return dict(batchId=batch_id,kind=kind,providerId=ident["providerId"],endpointRevision=ident["endpointRevision"],model=ident["model"],
                url="http://localhost:11434/api/embed",chunkIds=chunk_ids,revisionIds=revision_ids,inputs=texts)


def _sent_state(state,request):
    s=deepcopy(state);s["inFlightBatches"].append(deepcopy(request));s["providerRequests"].append(deepcopy(request));s["providerCallCount"]+=1
    return s


def _batch_state(state,batch_id,vectors,manifest=None):
    s=deepcopy(state);s["inFlightBatches"]=[b for b in s["inFlightBatches"] if b["batchId"]!=batch_id]
    s["generations"][-1]["vectors"].extend(deepcopy(vectors))
    if manifest is not None:s["generations"][-1]["manifest"]=deepcopy(manifest)
    return s


def generation_cases():
    out=[]
    base=_gen_state();build=_build_state();claimed=_claimed_state(build)
    req=_request("batch-a",[111,211],[11,21],["old","beta"])
    sent=_sent_state(claimed,req)
    vec=[dict(chunkId=111,revisionId=11,values=[1,0]),dict(chunkId=211,revisionId=21,values=[0,1])]
    done=_batch_state(sent,"batch-a",vec,[_manifest(101,11,"done"),_manifest(102,21,"done")])
    activated=deepcopy(done);activated["activeGenerationId"]=20;activated["generations"][0]["state"]="retired";activated["generations"][1]["state"]="active";activated["jobs"][0].update(state="done",leaseToken=None,leaseUntil=None)
    request_event=_event("request-build",0,build,notebookId=1,generationId=20,jobId=301,selection=_identity(),copyExisting=False)
    claim_event=_event("claim",1,claimed,jobId=301,leaseToken="build-a")
    begin_event=_event("begin-batch",2,sent,jobId=301,batchId="batch-a",chunkIds=[111,211],revisionIds=[11,21])
    commit_event=_event("commit-batch",3,done,jobId=301,leaseToken="build-a",batchId="batch-a",vectors=[[1,0],[0,1]])
    activation_event=_event("activate",4,activated,jobId=301,leaseToken="build-a",generationId=20)
    out.append(_case("new-generation","generation",_gen_seed(base),[request_event]))
    out.append(_case("activate-atomic","generation",_gen_seed(base),[request_event,claim_event,begin_event,commit_event,activation_event]))

    changed=deepcopy(base);changed["sources"][1].update(currentRevision=22,publishedRevisionId=22);changed["revisions"].append(_revision(22,102,"new beta",221))
    copied=deepcopy(changed);copied["generations"].append(_generation(20,"building",manifest=[_manifest(101,11,"done"),_manifest(102,22)],vectors=vec[:1]));copied["jobs"]=[_build_job(copy=True)]
    out.append(_case("copy-identical","generation",_gen_seed(changed),[
        _event("request-build",0,copied,notebookId=1,generationId=20,jobId=301,selection=_identity(),copyExisting=True)]))
    different=_identity(model="embed-b");model_seed=deepcopy(base);model_seed["selectedSelection"]=different
    model_build=_build_state(different);model_build["jobs"]=[_build_job(selection=different,copy=True)]
    out.append(_case("different-model-no-copy","generation",_gen_seed(model_seed),[
        _event("request-build",0,model_build,notebookId=1,generationId=20,jobId=301,selection=different,copyExisting=True)]))

    # Publication while the first complete manifest is waiting to activate must add pending work.
    during=deepcopy(done);during["sources"][1].update(currentRevision=22,publishedRevisionId=22);during["revisions"].append(_revision(22,102,"new beta",221));during["generations"][1]["manifest"]=[_manifest(101,11,"done"),_manifest(102,22)];during["generations"][1]["vectors"]=vec[:1]
    during["jobs"].append(_job(id=302,state="done",attempts=1,target="source:102",target_revision=22))
    req_new=_request("batch-b",[221],[22],["new beta"])
    sent_new=_sent_state(during,req_new)
    done_new=_batch_state(sent_new,"batch-b",[dict(chunkId=221,revisionId=22,values=[0,1])],[_manifest(101,11,"done"),_manifest(102,22,"done")])
    active_new=deepcopy(done_new);active_new["activeGenerationId"]=20;active_new["generations"][0]["state"]="retired";active_new["generations"][1]["state"]="active";active_new["jobs"][0].update(state="done",leaseToken=None,leaseUntil=None)
    out.append(_case("ingest-during-build","generation",_gen_seed(done),[
        _event("publish-revision",4,during,sourceId=102,revision=_revision(22,102,"new beta",221),extractJobId=302,leaseToken="extract-b",expectedCurrentRevision=21),
        _event("activate",5,during,jobId=301,leaseToken="build-a",generationId=20),
        _event("begin-batch",6,sent_new,jobId=301,batchId="batch-b",chunkIds=[221],revisionIds=[22]),
        _event("commit-batch",7,done_new,jobId=301,leaseToken="build-a",batchId="batch-b",vectors=[[0,1]]),
        _event("activate",8,active_new,jobId=301,leaseToken="build-a",generationId=20)]))
    stale=deepcopy(sent);stale["sources"][1].update(currentRevision=22,publishedRevisionId=22);stale["revisions"].append(_revision(22,102,"new beta",221));stale["generations"][1]["manifest"][1]=_manifest(102,22)
    stale["jobs"].append(_job(id=302,state="done",attempts=1,target="source:102",target_revision=22))
    stale_committed=_batch_state(stale,"batch-a",vec[:1],[_manifest(101,11,"done"),_manifest(102,22)])
    out.append(_case("stale-batch","generation",_gen_seed(sent),[
        _event("publish-revision",3,stale,sourceId=102,revision=_revision(22,102,"new beta",221),extractJobId=302,leaseToken="extract-b",expectedCurrentRevision=21),
        _event("commit-batch",4,stale_committed,jobId=301,leaseToken="build-a",batchId="batch-a",vectors=[[1,0],[0,1]])]))
    # Retryable expiry keeps the leaseExpired diagnostic (storage-job-handoff-v1).
    lost=deepcopy(sent);lost["jobs"][0].update(state="queued",leaseToken=None,leaseUntil=None,nextRetryAt=361,error="leaseExpired")
    rejected=deepcopy(lost);rejected["inFlightBatches"]=[]
    out.append(_case("lease-lost-batch","generation",_gen_seed(sent),[
        _event("recover-expired",301,lost),
        _event("commit-batch",302,rejected,jobId=301,leaseToken="build-a",batchId="batch-a",vectors=[[1,0],[0,1]])]))

    one_sent=_sent_state(claimed,_request("batch-a",[111],[11],["old"]))
    chatting=deepcopy(one_sent);chatting["chatTokens"]=["chat-a"]
    first_done=_batch_state(chatting,"batch-a",vec[:1],[_manifest(101,11,"done"),_manifest(102,21)])
    query=deepcopy(first_done);query["providerRequests"].append(_request("query-a",[],[],["question"],kind="query"));query["providerCallCount"]+=1;query["queryProviderCallCount"]=1
    renewed=deepcopy(query);renewed["jobs"][0]["leaseUntil"]=361
    unchat=deepcopy(renewed);unchat["chatTokens"]=[]
    second=_sent_state(unchat,_request("batch-b",[211],[21],["beta"]))
    out.append(_case("chat-pause-between-batches","generation",{**_gen_seed(one_sent),"batchSize":1},[
        _event("begin-chat",3,chatting,token="chat-a"),
        _event("commit-batch",4,first_done,jobId=301,leaseToken="build-a",batchId="batch-a",vectors=[[1,0]]),
        _event("begin-batch",5,first_done,jobId=301,batchId="batch-b",chunkIds=[211],revisionIds=[21]),
        _event("query-embedding",6,query,batchId="query-a",text="question",vector=[1,0]),
        _event("renew",61,renewed,jobId=301,leaseToken="build-a"),
        _event("end-chat",62,unchat,token="chat-a"),
        _event("begin-batch",63,second,jobId=301,batchId="batch-b",chunkIds=[211],revisionIds=[21])]))

    fail=deepcopy(sent);fail["inFlightBatches"]=[];fail["jobs"][0].update(state="failed",leaseToken=None,leaseUntil=None,nextRetryAt=63,error="provider-error")
    out.append(_case("failed-build-keeps-active","generation",_gen_seed(sent),[
        _event("provider-failure",3,fail,jobId=301,leaseToken="build-a",batchId="batch-a",error="provider-error")]))
    discarded=deepcopy(build);discarded["generations"][1]["state"]="retired";discarded["jobs"][0]["state"]="cancelled"
    out.append(_case("discard-keeps-active","generation",_gen_seed(build),[
        _event("discard",2,discarded,notebookId=1,generationId=20)]))
    restart=deepcopy(claimed);restart["jobs"][0].update(state="queued",leaseToken=None,leaseUntil=None,nextRetryAt=361,error="leaseExpired")
    reclaimed=_claimed_state(restart,361,2,"build-b");reclaimed["jobs"][0]["error"]=None
    out.append(_case("restart-resumes","generation",_gen_seed(claimed),[
        _event("recover-expired",301,restart,process="replacement"),
        _event("claim",361,reclaimed,jobId=301,leaseToken="build-b")]))

    for name,sel in [("selected-provider-changed",_identity(providerId="other")),("endpoint-changed-between-batches",_identity(endpointRevision=hashlib.sha256(b"ollama\nhttp://localhost:11435").hexdigest())),("model-changed-between-batches",_identity(model="embed-b"))]:
        change=deepcopy(done);change["selectedSelection"]=sel
        invalidated=deepcopy(change);invalidated["jobs"][0].update(state="cancelled",leaseToken=None,leaseUntil=None,nextRetryAt=None,error="embeddingSelectionChanged");invalidated["generations"][1].update(state="failed")
        out.append(_case(name,"generation",_gen_seed(done),[
            _event("change-selection",4,change,selection=sel),
            _event("invalidate-selection",5,invalidated,jobId=301,leaseToken="build-a")]))
    lexical=deepcopy(base);lexical["activeGenerationId"]=None;lexical["generations"]=[];lexical["selectedSelection"]=None
    retrieved=deepcopy(lexical);retrieved["retrieval"]=dict(lexicalChunkIds=[111,211],vectorChunkIds=[],sourceRevisionPairs=[dict(sourceId=101,revisionId=11),dict(sourceId=102,revisionId=21)])
    out.append(_case("lexical-only","generation",_gen_seed(lexical),[
        _event("retrieve",0,retrieved,notebookId=1,scope=dict(kind="all"))]))
    initial_results=deepcopy(base);initial_results["retrieval"]=dict(lexicalChunkIds=[111,211],vectorChunkIds=[111,211],sourceRevisionPairs=[dict(sourceId=101,revisionId=11),dict(sourceId=102,revisionId=21)])
    revoked=deepcopy(initial_results);revoked["sources"][0]["eligible"]=False
    revoked_results=deepcopy(revoked);revoked_results["retrieval"]=dict(lexicalChunkIds=[211],vectorChunkIds=[211],sourceRevisionPairs=[dict(sourceId=102,revisionId=21)])
    out.append(_case("scope-revocation","generation",_gen_seed(base),[
        _event("retrieve",0,initial_results,notebookId=1,scope=dict(kind="all")),
        _event("set-eligibility",1,revoked,sourceId=101,eligible=False),
        _event("retrieve",2,revoked_results,notebookId=1,scope=dict(kind="all"))]))
    pinned=deepcopy(done);pinned["pins"]=[dict(token="query-pin",generationId=10,sourceRevisions=[dict(sourceId=101,revisionId=11),dict(sourceId=102,revisionId=21)])]
    pin_active=deepcopy(activated);pin_active["pins"]=deepcopy(pinned["pins"])
    unpinned=deepcopy(pin_active);unpinned["pins"]=[]
    gc=deepcopy(unpinned);gc["generations"]=[g for g in gc["generations"] if g["id"]!=10]
    out.append(_case("pin-keeps-old-vectors","generation",_gen_seed(done),[
        _event("pin",4,pinned,token="query-pin",generationId=10),
        _event("activate",5,pin_active,jobId=301,leaseToken="build-a",generationId=20),
        _event("gc",6,pin_active,generationId=10),
        _event("unpin",7,unpinned,token="query-pin"),
        _event("gc",8,gc,generationId=10)]))

    unknown_sel=_identity(dims=None);unknown_seed=deepcopy(base);unknown_seed["selectedSelection"]=unknown_sel
    unknown=_build_state(unknown_sel,unknown=True);unknown_claimed=_claimed_state(unknown)
    unknown_req=_request("bootstrap-a",[111,211],[11,21],["old","beta"],unknown_sel)
    unknown_sent=_sent_state(unknown_claimed,unknown_req)
    boot_commit=deepcopy(unknown_sent);boot_commit["inFlightBatches"]=[];boot_commit["generations"].append(_generation(20,"building"));boot_commit["jobs"][0]["target"]="generation:20"
    boot_active=deepcopy(boot_commit);boot_active["activeGenerationId"]=20;boot_active["generations"][0]["state"]="retired";boot_active["generations"][1]["state"]="active";boot_active["jobs"][0].update(state="done",leaseToken=None,leaseUntil=None)
    out.append(_case("unknown-dimensions-bootstrap","generation",_gen_seed(unknown_seed),[
        _event("request-build",0,unknown,notebookId=1,jobId=301,selection=unknown_sel,copyExisting=False),
        _event("claim",1,unknown_claimed,jobId=301,leaseToken="build-a"),
        _event("begin-batch",2,unknown_sent,jobId=301,batchId="bootstrap-a",chunkIds=[111,211],revisionIds=[11,21]),
        _event("commit-batch",3,boot_commit,jobId=301,leaseToken="build-a",batchId="bootstrap-a",generationId=20,vectors=[[1,0],[0,1]]),
        _event("activate",4,boot_active,jobId=301,leaseToken="build-a",generationId=20)]))
    empty=deepcopy(unknown_claimed);empty["sources"]=[];empty["revisions"]=[];empty["generations"]=[];empty["activeGenerationId"]=None
    empty_done=deepcopy(empty);empty_done["jobs"][0].update(state="done",leaseToken=None,leaseUntil=None)
    out.append(_case("empty-bootstrap","generation",_gen_seed(empty),[
        _event("finish-empty",2,empty_done,jobId=301,leaseToken="build-a")]))
    boot_lost=deepcopy(unknown_sent);boot_lost["jobs"][0].update(leaseToken="build-b",leaseUntil=660,attempts=2)
    boot_reject=deepcopy(boot_lost);boot_reject["inFlightBatches"]=[]
    out.append(_case("bootstrap-stale-fence","generation",_gen_seed(boot_lost),[
        _event("commit-batch",361,boot_reject,jobId=301,leaseToken="build-a",batchId="bootstrap-a",generationId=20,vectors=[[1,0],[0,1]])]))
    boot_change=deepcopy(unknown_sent);boot_change["selectedSelection"]=_identity(model="embed-b",dims=None)
    boot_cancel=deepcopy(boot_change);boot_cancel["inFlightBatches"]=[];boot_cancel["jobs"][0].update(state="cancelled",leaseToken=None,leaseUntil=None,nextRetryAt=None,error="embeddingSelectionChanged")
    out.append(_case("bootstrap-selection-changed-in-flight","generation",_gen_seed(unknown_sent),[
        _event("change-selection",3,boot_change,selection=_identity(model="embed-b",dims=None)),
        _event("commit-batch",4,boot_cancel,jobId=301,leaseToken="build-a",batchId="bootstrap-a",generationId=20,vectors=[[1,0],[0,1]])]))
    boot_stale=deepcopy(unknown_sent);boot_stale["sources"][0].update(currentRevision=12,publishedRevisionId=12);boot_stale["sources"][1].update(currentRevision=22,publishedRevisionId=22);boot_stale["revisions"].extend([_revision(12,101,"new",121),_revision(22,102,"new beta",221)])
    boot_stale_reject=deepcopy(boot_stale);boot_stale_reject["inFlightBatches"]=[]
    out.append(_case("bootstrap-all-revisions-stale","generation",_gen_seed(boot_stale),[
        _event("commit-batch",3,boot_stale_reject,jobId=301,leaseToken="build-a",batchId="bootstrap-a",generationId=20,vectors=[[1,0],[0,1]])]))
    for name,response in [("bootstrap-count-mismatch",[[1,0]]),("bootstrap-mixed-dimensions",[[1,0],[0,1,0]]),("bootstrap-empty-vector",[[],[]]),("bootstrap-zero-vector",[[1,0],[0,0]]),("bootstrap-nonfinite-vector",[[1,0],["NaN",1]])]:
        invalid=deepcopy(unknown_sent);invalid["inFlightBatches"]=[];invalid["jobs"][0].update(state="failed",leaseToken=None,leaseUntil=None,nextRetryAt=63,error="invalidVector")
        out.append(_case(name,"generation",_gen_seed(unknown_sent),[
            _event("commit-batch",3,invalid,jobId=301,leaseToken="build-a",batchId="bootstrap-a",generationId=20,vectors=response)]))
    first=deepcopy(claimed);first["generations"][1]["manifest"][0]["state"]="done";first["generations"][1]["vectors"]=vec[:1];first["providerRequests"]=[_request("batch-a",[111],[11],["old"])];first["providerCallCount"]=1
    second_sent=_sent_state(first,_request("batch-b",[211],[21],["beta"]))
    second_invalid=deepcopy(second_sent);second_invalid["inFlightBatches"]=[];second_invalid["jobs"][0].update(state="failed",leaseToken=None,leaseUntil=None,nextRetryAt=65,error="invalidVector")
    out.append(_case("dimensions-change-second-batch","generation",{**_gen_seed(first),"batchSize":1},[
        _event("begin-batch",4,second_sent,jobId=301,batchId="batch-b",chunkIds=[211],revisionIds=[21]),
        _event("commit-batch",5,second_invalid,jobId=301,leaseToken="build-a",batchId="batch-b",vectors=[[0,1,0]])]))
    fifth=deepcopy(sent);fifth["jobs"][0]["attempts"]=5
    terminal=deepcopy(fifth);terminal["inFlightBatches"]=[];terminal["jobs"][0].update(state="failed",leaseToken=None,leaseUntil=None,nextRetryAt=None,error="provider-error");terminal["generations"][1].update(state="failed")
    out.append(_case("fifth-embed-failure","generation",_gen_seed(fifth),[
        _event("provider-failure",3,terminal,jobId=301,leaseToken="build-a",batchId="batch-a",error="provider-error")]))
    out.extend(_reconcile_cases())
    out.extend(_session_cases())
    return out


def _reconcile_cases():
    folders=[dict(id=1,notebookId=1,watchEnabled=True,scanState="idle",scanGeneration=0,lastFullScanAt=None),dict(id=2,notebookId=2,watchEnabled=True,scanState="idle",scanGeneration=0,lastFullScanAt=None),dict(id=3,notebookId=1,watchEnabled=False,scanState="idle",scanGeneration=0,lastFullScanAt=None)]
    seed=dict(notebookIds=[1,2],folders=folders,jobs=[],sources=[],running=False,nextReconcileAt=None,providerCallCount=0)
    scan1=_job(id=301,kind="scan",target="folder:1",target_revision=None,options=dict(verifyAll=False))
    scan2=_job(id=302,kind="scan",target="folder:2",target_revision=None,options=dict(verifyAll=False))
    started={**deepcopy(seed),"running":True,"nextReconcileAt":1800,"jobs":[scan1,scan2]}
    finished_one=deepcopy(started);finished_one["folders"][0].update(scanGeneration=1,lastFullScanAt=1);finished_one["jobs"][0].update(state="done",attempts=1)
    finished_two=deepcopy(finished_one);finished_two["folders"][1].update(scanGeneration=1,lastFullScanAt=2);finished_two["jobs"][1].update(state="done",attempts=1)
    after=deepcopy(finished_two);after["nextReconcileAt"]=3600
    after["jobs"].extend([_job(id=303,kind="scan",target="folder:1",target_revision=None,options=dict(verifyAll=False)),_job(id=304,kind="scan",target="folder:2",target_revision=None,options=dict(verifyAll=False))])
    # Full empty scans finish before the periodic deadline, which queues fresh work once.
    periodic=_case("periodic-1800","reconcile",dict(seed=seed,clockUnit="epoch-seconds",nextJobId=301),[
        _event("start",0,started),
        _event("complete-scan",1,finished_one,folderId=1,jobId=301,leaseToken="scan-a",entries=[]),
        _event("complete-scan",2,finished_two,folderId=2,jobId=302,leaseToken="scan-b",entries=[]),
        _event("tick",1799,finished_two),_event("tick",1800,after),_event("tick",1800,after)])
    manual=deepcopy(started);manual["jobs"].append(_job(id=303,kind="scan",target="folder:3",target_revision=None,options=dict(verifyAll=True)))
    disabled=_case("watch-disabled-startup","reconcile",dict(seed=seed,clockUnit="epoch-seconds",nextJobId=301),[
        _event("start",0,started),_event("manual-scan",1,manual,folderId=3,verifyAll=True,jobId=303)])
    return [periodic,disabled]


def _session_cases():
    config=dict(id="remote",type="openai_compatible",enabled=True,baseURL="https://embedding.example/v1/",privacyAcknowledged=True)
    root="https://embedding.example/v1"
    selection=_identity(providerId="remote",endpointRevision=hashlib.sha256(("openai_compatible\n"+root).encode()).hexdigest(),model="embed-a",dims=None)
    captured=dict(selection=selection,identity=None,requests=[],durableOptions=None,error=None)
    serialized={**deepcopy(captured),"durableOptions":dict(selection=selection,copyExisting=False)}
    # Only the input contains this synthetic sentinel; no persisted or public projection may contain it.
    secret=_case("no-api-key-serialization","embedding-session",dict(config=config,apiKey="fixture-secret-never-persist",model="embed-a",modelDigest=None,queryFormatVersion="1",docFormatVersion="1",httpClientBaseAddress="https://wrong.example/",seed=dict(selection=None,identity=None,requests=[],durableOptions=None,error=None)),[
        _event("capture",0,captured),_event("serialize",1,serialized,copyExisting=False)])
    after_mutation=deepcopy(captured)
    request=dict(url="https://embedding.example/v1/embeddings",model="embed-a",inputs=["old"],authorization="Bearer fixture-secret-never-persist")
    sent=deepcopy(captured);sent["identity"]={**selection,"dims":2};sent["requests"]=[request]
    fixed=_case("captured-endpoint-and-model","embedding-session",dict(config=config,apiKey="fixture-secret-never-persist",model="embed-a",modelDigest=None,queryFormatVersion="1",docFormatVersion="1",httpClientBaseAddress="https://wrong.example/",seed=dict(selection=None,identity=None,requests=[],durableOptions=None,error=None)),[
        _event("capture",0,captured),_event("mutate-config",1,after_mutation,baseURL="https://changed.example/v2",model="embed-b"),
        _event("embed",2,sent,inputs=["old"],responseVectors=[[1,0]])])
    rotated=_case("key-rotation-same-identity","embedding-session",dict(config=config,apiKey="key-a",model="embed-a",modelDigest=None,queryFormatVersion="1",docFormatVersion="1",seed=dict(selection=None,identity=None,requests=[],durableOptions=None,error=None)),[
        _event("capture",0,captured),_event("rotate-key",1,captured,apiKey="key-b")])
    chat=[]
    for kind in ["anthropic","openwebui"]:
        chat.append(_case("chat-only-selection-"+kind,"embedding-session",dict(config={**config,"type":kind},apiKey=None,model="chat-model",modelDigest=None,queryFormatVersion="1",docFormatVersion="1",seed=dict(selection=None,identity=None,requests=[],durableOptions=None,error=None)),[
            _event("capture",0,dict(selection=None,identity=None,requests=[],durableOptions=None,error="unsupportedEndpoint"))]))
    return [secret,fixed,rotated,*chat]


def _pipeline_model():
    """Exact frozen test model, with only its two target IDs relabeled."""
    frozen = json.loads((FIXTURES / 'contracts/lang-score-v1.json').read_text(encoding='utf-8'))
    model = copy.deepcopy(frozen['model'])
    labels = {'xa': 'cs', 'xb': 'sk'}
    model['targets'] = [labels[x] for x in model['targets']]
    for profile in model['profiles']:
        profile['id'] = labels.get(profile['id'], profile['id'])
    return model


def _pipeline_descriptor(title, kind, page_count, sheet_count, size_bytes, language):
    return dict(version=1, title=title, type=kind, pageCount=page_count,
                sheetCount=sheet_count, sizeBytes=size_bytes, lang=language)


def _pipeline_doc_result(label, coverage, cs, sk, unknown, sampled, reason):
    return dict(label=label, langCoverageBp=coverage, sharesBp=dict(cs=cs, sk=sk),
                unknownShareBp=unknown, sampledLetters=sampled, reason=reason)


def _pipeline_job(job_id=3001, **changes):
    job = dict(id=job_id, kind='extract', target='source:101', targetRevision=1001,
               state='running', attempts=1, leaseToken='owner-a', leaseUntil=310,
               nextRetryAt=None, error=None, options={})
    job.update(changes)
    return job


def _pipeline_selection():
    return dict(providerId='fixture', endpointRevision='fixture-endpoint-1',
                model='fixture-model', modelDigest=None, dims=2, normalization='l2',
                queryFormatVersion='1', docFormatVersion='1', chunkerVersion='2')


def _pipeline_fixture(name, text, document_result, chunk_results, *, available=True,
                      pages=(), embedding=False, scenario='publish', kind='text'):
    """Literal state projections for injected-extractor/real-store harnesses.

    Each event expected.state is the complete observed publication projection.
    The test adapter owns fake filesystem/extractor barriers, while mutations and
    publication use the real store. snapshot/extract change no persistent rows.
    The observe event installs an independently committed scanner observation
    with its explicit source stamp and replacement job; it is an external test
    transaction at the worker barrier, not a simulated worker publication. The
    scan contract separately drives the scanner through real scan-ticket APIs.
    Rollback is injected into the publication transaction and observed before an
    outer queue loop could record a separate failed attempt.
    """
    raw = list(text.encode('utf-8'))
    sha = hashlib.sha256(bytes(raw)).hexdigest()
    old_sha = hashlib.sha256(b'old').hexdigest()
    doc = dict(text=text, title='New title', kind=kind, pages=list(pages),
               sheetNames=[], encoding='utf-8' if kind == 'text' else None)
    old_pages = [dict(revisionId=1001, page=1, start=0, end=3)] if kind == 'pdf' else []
    old_descriptor = _pipeline_descriptor('Old title', kind, len(old_pages), 0, 3, 'cs')
    state = dict(
        source=dict(id=101, notebookId=1, folderId=1, relPath='a.' + ('pdf' if kind == 'pdf' else 'txt'),
                    availability='present', eligible=True, status='chunking',
                    currentRevision=1001, publishedRevisionId=1001, contentHash=old_sha,
                    mtimeNs=10, sizeBytes=len(raw), encoding='windows-1250', lang='cs',
                    langCoverageBp=10000, langCoverage=dict(version=1, langCoverageBp=10000,
                        sharesBp=dict(cs=10000, sk=0), unknownShareBp=0),
                    descriptor=old_descriptor, error=None),
        revisions=[dict(id=1001, sourceId=101, revision=1, contentHash=old_sha,
                        canonicalText='old', textFormatVersion=1, chunkerVersion=2)],
        chunks=[dict(id=2001, sourceId=101, revisionId=1001, ordinal=0, text='old',
                     start=0, end=3, tokens=1, lang='cs', langInherited=False,
                     pageFrom=1 if old_pages else None, pageTo=1 if old_pages else None)],
        revisionPages=old_pages, jobs=[_pipeline_job()], generations=[], manifests=[],
        notificationCount=0)
    seed = copy.deepcopy(state)
    stamp = dict(identity='file-1', mtimeNs=10, sizeBytes=len(raw))
    input_value = dict(
        model=_pipeline_model(), detector='available' if available else 'unavailable',
        notebookId=1, folderId=1, sourceId=101,
        folder=dict(id=1, notebookId=1, rootPath='/docs', volumeId='test',
                    components=['docs'], rootFileId='root-1', scanGeneration=1,
                    scanState='idle', enabled=True, rulesVersion=1),
        seed=seed, snapshot=dict(bytes=raw, stamp=stamp, sha256=sha),
        extractor=dict(kind='injected', document=doc),
        chunker=dict(window=2048, overlap=256),
        request=dict(sourceId=101, expectedCurrentRevision=1001, observation=stamp,
                     rulesVersion=1, fence=dict(jobId=3001, leaseToken='owner-a')),
        embeddingSelection=_pipeline_selection() if embedding else None,
        events=[])
    events = input_value['events']

    def event(operation, at, result, **data):
        events.append(dict(operation=operation, at=at, **data,
                           expected=dict(state=copy.deepcopy(state), result=copy.deepcopy(result))))

    chunk_specs = scalar_windows(text)
    if len(chunk_specs) != len(chunk_results):
        raise ValueError(f'{name}: chunk language expectation count mismatch')
    draft_chunks = []
    for index, (chunk, detection) in enumerate(zip(chunk_specs, chunk_results)):
        # Tuple: raw detector label, reason, final persisted language, inheritance.
        label, reason, language, inherited = detection
        hit_pages = [p['page'] for p in pages if p['start'] < p['end'] and
                     chunk['start'] < p['end'] and p['start'] < chunk['end']]
        draft_chunks.append(dict(**chunk, lang=language, langInherited=inherited,
            detection=None if not available else dict(label=label, reason=reason),
            pageFrom=hit_pages[0] if hit_pages else None, pageTo=hit_pages[-1] if hit_pages else None))
    metadata = dict(encoding=doc['encoding'], lang=None if document_result is None else document_result['label'],
                    langCoverageBp=None if document_result is None else document_result['langCoverageBp'])
    metadata['langCoverage'] = None if document_result is None else dict(
        version=1, langCoverageBp=document_result['langCoverageBp'],
        sharesBp=copy.deepcopy(document_result['sharesBp']),
        unknownShareBp=document_result['unknownShareBp'])
    metadata['descriptor'] = _pipeline_descriptor('New title', kind, len(pages), 0,
                                                   len(raw), metadata['lang'])
    draft = dict(canonicalText=text, contentHash=sha, textFormatVersion=1,
                 chunkerVersion=2, chunks=draft_chunks, pages=list(pages),
                 documentDetection=document_result, metadata=metadata)
    event('snapshot', 10, dict(stamp=stamp, sha256=sha))
    event('extract', 11, draft)

    if scenario in ('stat-changed', 'hash-changed-same-stat'):
        changed_raw = raw.copy()
        changed_raw[0] = 66 if changed_raw[0] != 66 else 67
        changed_stamp = dict(stamp)
        if scenario == 'stat-changed':
            changed_stamp['mtimeNs'] = 11
        changed_hash = hashlib.sha256(bytes(changed_raw)).hexdigest()
        event('change-original', 12, None,
              file=dict(bytes=changed_raw, stamp=changed_stamp, sha256=changed_hash))
        state['source']['status'] = 'pending'
        state['jobs'][0].update(state='cancelled', leaseToken=None, leaseUntil=None)
        state['jobs'].append(_pipeline_job(3002, state='queued', attempts=0,
                                           leaseToken=None, leaseUntil=None))
        state['notificationCount'] = 1
        event('publish', 13, dict(accepted=False, revisionId=None, error='changedDuringExtraction'),
              fence=dict(jobId=3001, leaseToken='owner-a'))
    elif scenario == 'new-observation-before-commit':
        # A newer scan records its observation, cancels the superseded token,
        # and queues the next extraction in one observation transaction.
        newer_stamp = dict(stamp, mtimeNs=11)
        state['source'].update(mtimeNs=11, status='pending')
        state['jobs'][0].update(state='cancelled', leaseToken=None, leaseUntil=None)
        state['jobs'].append(_pipeline_job(3002, state='queued', attempts=0,
                                           leaseToken=None, leaseUntil=None))
        state['notificationCount'] = 1
        event('observe', 12, dict(extractJobId=3002), observation=newer_stamp,
              sourceId=101, scanGeneration=2, transaction='committed-scan-observation',
              cancelJobId=3001, replacementJob=copy.deepcopy(state['jobs'][-1]))
        # Superseded publication is rejected, with no publication notification.
        event('publish', 13, dict(accepted=False, revisionId=None, error=None),
              fence=dict(jobId=3001, leaseToken='owner-a'))
    elif scenario == 'expired-owner':
        event('publish', 310, dict(accepted=False, revisionId=None, error=None),
              fence=dict(jobId=3001, leaseToken='owner-a'))
    elif scenario == 'replaced-owner':
        # Retryable expiry keeps the job diagnostic and fences the source back
        # to pending (storage-job-handoff-v1); the next claim clears both.
        state['jobs'][0].update(state='queued', leaseToken=None, leaseUntil=None, nextRetryAt=370,
                                error='leaseExpired')
        state['source']['status'] = 'pending'
        event('expire', 310, dict(recovered=1), jobId=3001)
        state['jobs'][0].update(state='running', attempts=2, leaseToken='owner-b',
                                leaseUntil=670, nextRetryAt=None, error=None)
        state['source']['status'] = 'chunking'
        event('claim', 370, dict(claimedJobId=3001), jobId=3001, leaseToken='owner-b')
        event('publish', 371, dict(accepted=False, revisionId=None, error=None),
              fence=dict(jobId=3001, leaseToken='owner-a'))
    elif scenario == 'metadata-and-embed-atomic':
        event('publish', 12, dict(accepted=False, revisionId=None, error='injectedFailure'),
              fence=dict(jobId=3001, leaseToken='owner-a'), fault='after-embed-enqueue')
    elif scenario == 'publish':
        state['source'].update(status='ready', currentRevision=1002, publishedRevisionId=1002,
                                contentHash=sha, **metadata)
        state['revisions'].append(dict(id=1002, sourceId=101, revision=2, contentHash=sha,
                                       canonicalText=text, textFormatVersion=1, chunkerVersion=2))
        for index, chunk in enumerate(draft_chunks):
            stored = {k: v for k, v in chunk.items() if k != 'detection'}
            state['chunks'].append(dict(id=2002 + index, sourceId=101,
                                        revisionId=1002, ordinal=index, **stored))
        state['revisionPages'].extend(dict(revisionId=1002, **p) for p in pages)
        state['jobs'][0].update(state='done', targetRevision=1002, leaseToken=None, leaseUntil=None)
        if embedding:
            state['generations'].append(dict(id=5001, notebookId=1, state='building',
                                             identity=_pipeline_selection()))
            state['manifests'].append(dict(generationId=5001, sourceId=101,
                                           revisionId=1002, state='pending', reason=None))
            state['jobs'].append(_pipeline_job(3002, kind='embed', target='generation:5001',
                targetRevision=None, state='queued', attempts=0, leaseToken=None, leaseUntil=None,
                options=dict(selection=_pipeline_selection(), copyExisting=True)))
        state['notificationCount'] = 1
        event('publish', 12, dict(accepted=True, revisionId=1002, error=None),
              fence=dict(jobId=3001, leaseToken='owner-a'))
    else:
        raise ValueError(f'Unknown pipeline scenario: {scenario}')
    return case(name, 'pipeline', input_value, copy.deepcopy(events[-1]['expected']))


def pipeline_cases():
    unknown = _pipeline_doc_result('und', 0, 0, 0, 10000, 3, 'insufficientEvidence')
    short = [('und', 'minLetters', 'und', False)]
    result = [
        _pipeline_fixture('publish-short', 'A😀éZ', unknown, short, embedding=True),
        _pipeline_fixture('detector-unavailable', 'A😀éZ', None,
                          [(None, None, None, False)], available=False),
    ]
    # The frozen model caps at 256 scalars. Its document windows are [0,14),
    # [121,135),[242,256); whitespace-only windows contribute zero letters.
    # Canonical whitespace remains stored, while default 2048/256 chunking
    # trims it out of chunk text and gives a genuinely short second chunk.
    prefix = 'aaaa aaaa aaaa' + ' ' * 2034
    confident = _pipeline_doc_result('cs', 10000, 10000, 0, 0, 12, 'dominant')
    result.append(_pipeline_fixture('inherit-short', prefix + 'z', confident,
                  [('cs', 'accepted', 'cs', False), ('und', 'minLetters', 'cs', True)]))
    result.append(_pipeline_fixture('low-confidence-und', prefix + 'aaaa aaaa bbbb', confident,
                  [('cs', 'accepted', 'cs', False), ('und', 'minMargin', 'und', False)]))
    result.append(_pipeline_fixture('background-never-inherits', prefix + 'dddd dddd dddd', confident,
                  [('cs', 'accepted', 'cs', False), ('und', 'background', 'und', False)]))
    mixed_prefix = ('aaaa aaaa aaaa' + ' ' * 107 + 'bbbb bbbb bbbb' +
                    ' ' * 107 + 'aaaa aaaa aaaa' + ' ' * 1792)
    mixed = _pipeline_doc_result('mixed', 10000, 6666, 3333, 0, 36, 'mixed')
    result.append(_pipeline_fixture('mixed-document', mixed_prefix + 'z', mixed,
                  [('und', 'minWinningScore', 'und', False), ('und', 'minLetters', 'und', False)]))
    diluted_prefix = ('aaaa aaaa aaaa' + ' ' * 107 + 'dddd dddd dddd' +
                      ' ' * 107 + 'dddd dddd dddd' + ' ' * 1792)
    diluted = _pipeline_doc_result('und', 3333, 3333, 0, 6666, 36, 'insufficientEvidence')
    result.append(_pipeline_fixture('und-document', diluted_prefix + 'z', diluted,
                  [('und', 'background', 'und', False), ('und', 'minLetters', 'und', False)]))
    for name in ('stat-changed', 'hash-changed-same-stat', 'new-observation-before-commit',
                 'expired-owner', 'replaced-owner'):
        result.append(_pipeline_fixture(name, 'A😀éZ', unknown, short, scenario=name))
    pdf_text = 'A😀\n\n\n\néZ'
    pages = [dict(page=1, start=0, end=2), dict(page=2, start=4, end=4),
             dict(page=3, start=6, end=9)]
    result.append(_pipeline_fixture('metadata-and-embed-atomic', pdf_text, unknown, short,
                  pages=pages, embedding=True, scenario='metadata-and-embed-atomic', kind='pdf'))
    result.append(_pipeline_fixture('revision-page-map-survives-refresh', pdf_text, unknown, short,
                  pages=pages, kind='pdf'))
    result.append(_pipeline_fixture('empty-revision', '',
                  _pipeline_doc_result('und', 0, 0, 0, 0, 0, 'insufficientEvidence'), []))
    result.append(case('descriptor-metadata-not-prose', 'descriptor',
        dict(document=dict(text='# Body\nSecret prose', title='Metadata', kind='markdown',
                           pages=[], sheetNames=[], encoding='utf-8'),
             filename='fallback.md', sizeBytes=32, lang='cs'),
        _pipeline_descriptor('Metadata', 'markdown', 0, 0, 32, 'cs')))
    # Pure inheritance guard cases make every accepted and rejected reason explicit.
    for name, label, reason, document, language, inherited in [
        ('min-words-inherits', 'und', 'minWords', 'cs', 'cs', True),
        ('disabled-bucket-no-inheritance', 'und', 'bucketDisabled', 'cs', 'und', False),
        ('winning-score-no-inheritance', 'und', 'minWinningScore', 'cs', 'und', False),
        ('coverage-no-inheritance', 'und', 'minKnownCoverageBp', 'cs', 'und', False),
        ('unavailable-never-inherits', None, None, 'cs', None, False),
    ]:
        result.append(case(name, 'chunk-language',
                           dict(label=label, reason=reason, documentLabel=document),
                           dict(lang=language, langInherited=inherited)))
    return result


CASE_OPERATIONS = {
    "encoding": {"decode"}, "canonical": {"canonical"},
    "office": {"extract", "bounded-stream"},
    "scan": {"walk", "identity", "open", "scan", "rules"},
    "jobs": {"jobs", "admission", "schedule"},
    "pipeline": {"pipeline", "chunk-language", "descriptor"},
    "generations": {"generation", "reconcile", "embedding-session"},
    "coverage": {"coverage"}, "ui": {"localization", "scope", "scope-store", "watch", "runtime"},
    "ooxml": {"extract", "error-text", "localization"},
}


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _integer(value, minimum=0):
    return type(value) is int and minimum <= value <= 9007199254740991


def _validate_json(value):
    if isinstance(value, str):
        _require(not any(0xD800 <= ord(c) <= 0xDFFF for c in value), "unpaired scalar")
    elif isinstance(value, dict):
        for key, child in value.items():
            _require(isinstance(key, str), "non-string JSON key")
            if key == "bytes" and isinstance(child, list):
                _require(all(type(b) is int and 0 <= b <= 255 for b in child),
                         "invalid byte array")
            _validate_json(key)
            _validate_json(child)
    elif isinstance(value, list):
        for child in value:
            _validate_json(child)
    else:
        _require(value is None or type(value) in (bool, int), "fixture arithmetic must use integers")


def _validate_spans(value):
    """Check any canonical document/revision projection, including nested traces."""
    if isinstance(value, dict):
        text = value.get("canonicalText", value.get("text"))
        if isinstance(text, str):
            for chunk in value.get("chunks", []):
                start, end = chunk.get("start"), chunk.get("end")
                _require(_integer(start) and _integer(end) and start < end <= len(text),
                         "invalid scalar chunk span")
                _require(chunk.get("text") == text[start:end], "chunk does not slice canonical scalars")
                if "pages" in value:
                    hits = [p["page"] for p in value["pages"] if p["start"] < p["end"] and
                            start < p["end"] and p["start"] < end]
                    _require(chunk.get("pageFrom") == (hits[0] if hits else None) and
                             chunk.get("pageTo") == (hits[-1] if hits else None), "invalid chunk page range")
            previous_end = 0
            previous_page = 0
            for page in value.get("pages", []):
                start, end, number = page.get("start"), page.get("end"), page.get("page")
                _require(_integer(start) and _integer(end) and start <= end <= len(text)
                         and start >= previous_end, "invalid scalar page span")
                _require(_integer(number, 1) and number > previous_page, "invalid page order")
                previous_end, previous_page = end, number
        if "revisions" in value and "chunks" in value:
            revisions = {revision["id"]: revision for revision in value["revisions"]}
            _require(len(revisions) == len(value["revisions"]), "duplicate revision identity")
            pages_by_revision = {}
            for page in value.get("revisionPages", []):
                _require(page.get("revisionId") in revisions, "page references missing revision")
                pages_by_revision.setdefault(page["revisionId"], []).append(page)
            for chunk in value["chunks"]:
                revision = revisions.get(chunk.get("revisionId"))
                _require(revision is not None, "chunk references missing revision")
                _require(chunk.get("sourceId") == revision.get("sourceId"), "chunk/revision owner mismatch")
            for revision_id, revision in revisions.items():
                _validate_spans(dict(canonicalText=revision["canonicalText"],
                    chunks=[c for c in value["chunks"] if c["revisionId"] == revision_id],
                    pages=pages_by_revision.get(revision_id, [])))
        for child in value.values():
            _validate_spans(child)
    elif isinstance(value, list):
        for child in value:
            _validate_spans(child)


def validate_contracts(contracts: dict[str, dict], asset_names: set[str]) -> None:
    """Reject corrupt fixture inputs before writing any output (also public for tests)."""
    _require(set(contracts) == {f"ingestion-{g}-v1.json" for g in GROUPS}, "unexpected contract set")
    _validate_json(contracts)
    referenced = set()
    byte_assets = asset_bytes()

    def references(value):
        if isinstance(value, dict):
            if "asset" in value:
                name = value["asset"]
                _require(name in asset_names and name in byte_assets, f"missing asset: {name}")
                referenced.add(name)
            for child in value.values():
                references(child)
        elif isinstance(value, list):
            for child in value:
                references(child)

    for group in GROUPS:
        contract = contracts[f"ingestion-{group}-v1.json"]
        _require(contract.get("contract") == "ingestion-" + group and
                 type(contract.get("version")) is int and contract["version"] == 1,
                 "invalid contract envelope")
        rows = contract.get("cases")
        _require(isinstance(rows, list) and bool(rows), "empty cases")
        names = set()
        for row in rows:
            _require(set(row) == {"name", "operation", "input", "expected"}, "invalid case shape")
            name, operation, data, expected = (row[k] for k in ("name", "operation", "input", "expected"))
            _require(isinstance(name, str) and name and name not in names, "duplicate/empty case name")
            names.add(name)
            _require(operation in CASE_OPERATIONS[group], f"unknown operation: {operation}")
            _require(isinstance(data, dict) and isinstance(expected, dict) and expected, "invalid case IO")
            references(data)
            _validate_spans(row)
            if operation == "decode":
                _require(isinstance(data.get("bytes"), list), "decode requires byte array")
            if "events" in data:
                _require(operation in TRACE_OPERATIONS, f"no trace grammar for {operation}")
                _require(isinstance(data["events"], list) and data["events"], "empty event trace")
                previous_at = -1
                for event in data["events"]:
                    _require(event.get("operation") in TRACE_OPERATIONS[operation], "unknown trace operation")
                    at = event.get("at")
                    _require(_integer(at) and at >= previous_at, "invalid trace time")
                    _require(isinstance(event.get("expected"), dict) and event["expected"], "missing event projection")
                    previous_at = at
                _require(expected == data["events"][-1]["expected"], "final trace projection differs")
            if operation == "walk":
                for entries in data["directories"].values():
                    for entry in entries:
                        _require(entry["relPath"] in data["stats"], "walk entry missing stat")
            if operation == "extract" and data.get("mutations"):
                with zipfile.ZipFile(io.BytesIO(byte_assets[data["asset"]])) as archive:
                    members = set(archive.namelist())
                for mutation in data["mutations"]:
                    _require(mutation.get("operation") in {"replace-entry", "remove-entry"}, "unknown archive mutation")
                    _require(mutation.get("entry") in members, "mutation refers to missing archive member")
                    if mutation["operation"] == "replace-entry":
                        _require(isinstance(mutation.get("text"), str), "replacement requires XML text")
                    else:
                        members.remove(mutation["entry"])
    _require(referenced == asset_names, "unreferenced assets: " + ", ".join(sorted(asset_names - referenced)))


def make_contracts() -> dict[str, dict]:
    makers = (encoding_cases, canonical_cases, office_cases, scan_cases, jobs_cases,
              pipeline_cases, generation_cases, coverage_cases, ui_cases, ooxml_cases)
    return {f"ingestion-{group}-v1.json": dict(contract="ingestion-" + group,
            version=1, cases=maker()) for group, maker in zip(GROUPS, makers)}


def generate(root: Path, check: bool = False) -> None:
    """Write owned outputs, or regenerate in a temporary directory and compare."""
    contracts = make_contracts()
    assets = asset_bytes()
    validate_contracts(contracts, set(assets))
    if check:
        with tempfile.TemporaryDirectory(prefix="ingestion-check-") as directory:
            candidate = Path(directory)
            generate(candidate)
            paths = [f"contracts/{name}" for name in contracts] + list(assets)
            changed = [p for p in paths if not (root / p).is_file() or
                       (root / p).read_bytes() != (candidate / p).read_bytes()]
            _require(not changed, "fixture drift: " + ", ".join(changed))
        return
    for filename, value in contracts.items():
        path = root / "contracts" / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8"))
    write_assets(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare every owned output without writing")
    args = parser.parse_args()
    try:
        generate(FIXTURES, check=args.check)
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
    verb = "checked" if args.check else "generated"
    print(f"{verb} 10 ingestion contracts and 8 assets")


TRACE_OPERATIONS.update({
    "scan": {"list", "stat", "read", "deny", "cancel", "rootUnavailable", "finish"},
    "rules": {"apply-rules"},
    "pipeline": {"snapshot", "extract", "change-original", "publish", "observe", "expire", "claim"},
    "runtime": {"start", "stop", "watch", "remove", "signal", "tick", "drain", "start-scan", "finish-scan", "ingest-source", "refresh-source", "refresh-url"},
})

if __name__ == "__main__":
    main()
