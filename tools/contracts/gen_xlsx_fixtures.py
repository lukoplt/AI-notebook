#!/usr/bin/env python3
"""ingestion-xlsx-v2 reference: compact spreadsheet canonical text (text_format_version 2).

Normative text: docs/contracts/ingestion-xlsx-v2.md. This module is the
executable reference. It contains

* the pure value renderers (numbers, date serials, whitespace) that Swift
  (`SpreadsheetText`) and C# (`SpreadsheetText`) must reproduce byte for byte;
* an independent reference reader that renders a whole workbook package from
  its XML parts (it never imports production code);
* the fixture builder for `Tests/fixtures/contracts/ingestion-xlsx-v2.json`
  plus its two synthetic workbook assets, including the explicit supersession
  map for the frozen v1 fixture cases whose expected XLSX text changed;
* `--measure`: v1 vs v2 characters and chunker-v2 chunk counts on synthetic
  workbooks shaped like real-world templates (no fixture output).

`--check` regenerates in memory and compares every owned output (read-only).
"""

import argparse
import io
import json
import posixpath
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_ingestion_fixtures as ingestion  # noqa: E402  (shared deterministic ZIP writer + chunk oracle)

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "Tests" / "fixtures"
CONTRACT = "ingestion-xlsx"
VERSION = 2
OUTPUT = "contracts/ingestion-xlsx-v2.json"
TEXT_FORMAT_VERSION = 2

SIGNIFICANT_DIGITS = 15
EXPONENT_DIGITS_LIMIT = 5
DECIMAL_EXPONENT_LIMIT = 400
ROW_SEPARATOR = "\n"
CELL_SEPARATOR = " | "
ASCII_WHITESPACE = "\t\n\r "

MAIN_NS = ("http://schemas.openxmlformats.org/spreadsheetml/2006/main",
           "http://purl.oclc.org/ooxml/spreadsheetml/main")
REL_NS = ("http://schemas.openxmlformats.org/officeDocument/2006/relationships",
          "http://purl.oclc.org/ooxml/officeDocument/relationships")
PACKAGE_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
NON_WORKSHEET = ("chartsheet", "dialogsheet", "macrosheet")
HIDDEN_STATES = ("hidden", "veryHidden")


class Fail(Exception):
    """A reader error code (same vocabulary as production)."""


# ---------------------------------------------------------------------------
# Pure renderers (contract §3–§5)

_NUMERIC = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z")


def normalize_value(text: str) -> str:
    """§3: every maximal run of TAB/LF/CR/SPACE becomes one SPACE; trim SPACE at both ends."""
    out, pending = [], False
    for ch in text:
        if ch in ASCII_WHITESPACE:
            pending = True
            continue
        if pending and out:
            out.append(" ")
        pending = False
        out.append(ch)
    return "".join(out)


def parse_decimal(raw: str):
    """§4 steps 1–4. Returns None (not numeric / out of range), "zero", or (negative, digits, n)
    with value = 0.digits × 10^n, digits without leading or trailing zeros, at most 15 digits."""
    s = raw.strip(ASCII_WHITESPACE)
    if not _NUMERIC.match(s):
        return None
    negative = s.startswith("-")
    if s[0] in "+-":
        s = s[1:]
    exponent = 0
    for marker in "eE":
        if marker in s:
            s, exp_text = s.split(marker)
            sign = -1 if exp_text.startswith("-") else 1
            exp_digits = exp_text.lstrip("+-").lstrip("0")
            if len(exp_digits) > EXPONENT_DIGITS_LIMIT:
                return None
            exponent = sign * int(exp_digits or "0")
    integer, _, fraction = s.partition(".")
    digits = integer + fraction
    n = len(integer)
    stripped = digits.lstrip("0")
    n -= len(digits) - len(stripped)
    digits = stripped.rstrip("0")
    if not digits:
        return "zero"
    n += exponent
    if len(digits) > SIGNIFICANT_DIGITS:
        round_up = digits[SIGNIFICANT_DIGITS] >= "5"
        digits = digits[:SIGNIFICANT_DIGITS]
        if round_up:
            chars = list(digits)
            index = len(chars) - 1
            while index >= 0 and chars[index] == "9":
                chars[index] = "0"
                index -= 1
            if index < 0:
                chars = ["1"] + chars
                n += 1
            else:
                chars[index] = chr(ord(chars[index]) + 1)
            digits = "".join(chars)[:SIGNIFICANT_DIGITS]
        digits = digits.rstrip("0")
    if not -DECIMAL_EXPONENT_LIMIT <= n <= DECIMAL_EXPONENT_LIMIT:
        return None
    return negative, digits, n


def render_number(raw: str):
    """§4: the compact decimal text, or None when the lexeme is not a renderable number."""
    parsed = parse_decimal(raw)
    if parsed is None:
        return None
    if parsed == "zero":
        return "0"
    negative, d, n = parsed
    k = len(d)
    if k <= n <= 21:
        body = d + "0" * (n - k)
    elif 0 < n <= 21:
        body = d[:n] + "." + d[n:]
    elif -6 < n <= 0:
        body = "0." + "0" * (-n) + d
    else:
        e = n - 1
        body = d[0] + ("." + d[1:] if k > 1 else "") + "E" + ("+" if e >= 0 else "-") + str(abs(e))
    return ("-" if negative else "") + body


def days_from_civil(y: int, m: int, d: int) -> int:
    """Days since 1970-01-01 (proleptic Gregorian), H. Hinnant's integer algorithm."""
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_from_days(z: int):
    z += 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + (3 if mp < 10 else -9)
    return y + (m <= 2), m, d


def render_date(raw: str, date1904: bool):
    """§5: ISO date/time text of a positive serial, or None (the caller renders a number)."""
    parsed = parse_decimal(raw)
    if parsed is None or parsed == "zero" or parsed[0]:
        return None
    _, d, n = parsed
    if n <= 0:
        integer, fraction = 0, ("0" * (-n)) + d
    else:
        padded = d + "0" * max(0, n - len(d))
        integer, fraction = int(padded[:n]), padded[n:]
    if integer > 3_000_000:
        return None
    seconds = 0
    if fraction and n > -6:
        f, m = int(fraction), len(fraction)
        if m == 1:
            numerator, denominator = f * 86400, 10
        else:
            numerator, denominator = f * 864, 10 ** (m - 2)
        q, r = divmod(numerator, denominator)
        seconds = q + (1 if 2 * r >= denominator else 0)
    total = integer * 86400 + seconds
    day, second_of_day = divmod(total, 86400)
    hh, rest = divmod(second_of_day, 3600)
    mm, ss = divmod(rest, 60)
    clock = "%02d:%02d" % (hh, mm) + (":%02d" % ss if ss else "")
    if day == 0:
        return clock
    if date1904:
        y, mo, dd = civil_from_days(days_from_civil(1904, 1, 1) + day)
    elif day < 60:
        y, mo, dd = civil_from_days(days_from_civil(1899, 12, 31) + day)
    elif day == 60:
        y, mo, dd = 1900, 2, 29
    else:
        y, mo, dd = civil_from_days(days_from_civil(1899, 12, 30) + day)
    if y > 9999:
        return None
    text = "%04d-%02d-%02d" % (y, mo, dd)
    return text + (" " + clock if second_of_day else "")


def column_name(column: int) -> str:
    out = ""
    while column:
        column, rem = divmod(column - 1, 26)
        out = chr(65 + rem) + out
    return out


def is_builtin_date(fmt_id: int) -> bool:
    return 14 <= fmt_id <= 22 or 27 <= fmt_id <= 36 or 45 <= fmt_id <= 47 or 50 <= fmt_id <= 58


def is_custom_date(code: str) -> bool:
    """§6 custom number-format classification (same rule on both platforms)."""
    i = 0
    while i < len(code):
        c = code[i]
        if c == '"':
            i += 1
            while i < len(code) and code[i] != '"':
                i += 1
        elif c in "\\_*":
            i += 1
        elif c == "[":
            end = code.find("]", i + 1)
            if end < 0:
                return False
            content = code[i + 1:end].lower()
            if content and len(set(content)) == 1 and content[0] in "hms":
                return True
            i = end
        elif c.lower() in "ymdhs":
            return True
        i += 1
    return False


def render_cell(kind: str, value: str, shared: str, is_date: bool, date1904: bool) -> str:
    """§3 value of one cell before normalization; '' means omitted."""
    if kind in ("s", "inlineStr"):
        text = shared
    elif kind == "e":
        return ""
    elif kind == "b":
        text = {"": "", "0": "FALSE", "1": "TRUE"}[value]
    elif kind == "n" and value:
        rendered = render_date(value, date1904) if is_date else None
        if rendered is None:
            rendered = render_number(value)
        text = rendered if rendered is not None else value
    else:  # str, d, empty n
        text = value
    return normalize_value(text)


def render_rows(cells) -> list:
    """cells: [(row, column, text)] already rendered; returns the row lines (§2)."""
    rows = {}
    for row, column, text in cells:
        if text:
            rows.setdefault(row, []).append((column, text))
    lines = []
    for row in sorted(rows):
        parts, previous = [], 0
        for column, text in sorted(rows[row]):
            parts.append(text if column == previous + 1 else column_name(column) + "=" + text)
            previous = column
        lines.append("R%d: " % row + CELL_SEPARATOR.join(parts))
    return lines


def render_sheets(sheets) -> str:
    """sheets: [(name, [row line])]."""
    return "\n\n".join("## " + name + "\n" + ROW_SEPARATOR.join(lines) for name, lines in sheets)


# ---------------------------------------------------------------------------
# Independent reference reader (valid packages only; error codes for the cases it covers)

def _local(tag: str):
    if tag.startswith("{"):
        ns, name = tag[1:].split("}")
        return name if ns in MAIN_NS else None
    return None


def _rel_kind(rel_type: str, kind: str) -> bool:
    return any(rel_type == ns + "/" + kind for ns in REL_NS)


def _resolve(source_part: str, target: str) -> str:
    if target.startswith("/"):
        return target.lstrip("/")
    base = posixpath.dirname(source_part)
    return posixpath.normpath(posixpath.join(base, target))


def _relationships(parts: dict, source_part: str) -> dict:
    rels_path = posixpath.join(posixpath.dirname(source_part), "_rels", posixpath.basename(source_part) + ".rels")
    if rels_path not in parts:
        return {}
    root = ET.fromstring(parts[rels_path])
    out = {}
    for rel in root:
        if rel.tag != "{%s}Relationship" % PACKAGE_NS:
            continue
        if rel.get("TargetMode") == "External":
            out[rel.get("Id")] = (rel.get("Type"), None)
        else:
            out[rel.get("Id")] = (rel.get("Type"), _resolve(source_part, rel.get("Target")))
    return out


def _cell_text(si) -> str:
    out = []
    for child in si:
        name = _local(child.tag)
        if name == "t":
            out.append(child.text or "")
        elif name == "r":
            out.extend(t.text or "" for t in child if _local(t.tag) == "t")
    return "".join(out)


def _coordinate(reference: str):
    m = re.fullmatch(r"([A-Z]{1,3})([1-9][0-9]{0,6})", reference)
    if not m:
        raise Fail("invalidCell")
    column = 0
    for ch in m.group(1):
        column = column * 26 + ord(ch) - 64
    row = int(m.group(2))
    if column > 16384 or row > 1048576:
        raise Fail("invalidCell")
    return row, column


def read_workbook(parts: dict):
    """Returns (text, sheetNames) or raises Fail(code)."""
    root_rels = _relationships(parts, "")
    main = next((target for kind, target in root_rels.values()
                 if target and kind.endswith("/officeDocument")), "xl/workbook.xml")
    workbook = ET.fromstring(parts[main])
    rels = _relationships(parts, main)
    date1904 = False
    sheets = []
    for child in workbook:
        name = _local(child.tag)
        if name == "workbookPr":
            date1904 = child.get("date1904") in ("1", "true")
        elif name == "sheets":
            for sheet in child:
                if _local(sheet.tag) != "sheet":
                    continue
                rid = next((sheet.get("{%s}id" % ns) for ns in REL_NS if sheet.get("{%s}id" % ns)), None)
                rel = rels.get(rid)
                if rel and any(_rel_kind(rel[0], kind) for kind in NON_WORKSHEET):
                    continue
                if sheet.get("state") in HIDDEN_STATES:
                    continue
                if not rel or not _rel_kind(rel[0], "worksheet") or rel[1] not in parts:
                    raise Fail("invalidRelationship")
                sheets.append((sheet.get("name"), rel[1]))
    shared_part = next((t for k, t in rels.values() if _rel_kind(k, "sharedStrings")),
                       posixpath.join(posixpath.dirname(main), "sharedStrings.xml"))
    styles_rels = [t for k, t in rels.values() if _rel_kind(k, "styles")]
    shared = []
    if shared_part in parts:
        shared = [_cell_text(si) for si in ET.fromstring(parts[shared_part]) if _local(si.tag) == "si"]
    cell_formats, custom = [], {}
    worksheets = [ET.fromstring(parts[part]) for _, part in sheets]
    numeric = any(c.get("t", "n") == "n" and any(_local(v.tag) == "v" and v.text for v in c)
                  for w in worksheets for c in w.iter() if _local(c.tag) == "c")
    explicit = any(c.get("s") is not None for w in worksheets for c in w.iter() if _local(c.tag) == "c")
    if numeric and (styles_rels or explicit):
        if len(styles_rels) != 1 or styles_rels[0] not in parts:
            raise Fail("invalidRelationship")
        styles = ET.fromstring(parts[styles_rels[0]])
        for child in styles:
            if _local(child.tag) == "cellXfs":
                cell_formats = [int(xf.get("numFmtId", "0")) for xf in child if _local(xf.tag) == "xf"]
            elif _local(child.tag) == "numFmts":
                for fmt in child:
                    if _local(fmt.tag) == "numFmt":
                        custom[int(fmt.get("numFmtId"))] = fmt.get("formatCode")

    def is_date(style: int) -> bool:
        if not (styles_rels or explicit):
            return False
        if style >= len(cell_formats):
            raise Fail("invalidCell")
        fmt = cell_formats[style]
        if fmt < 164:
            return is_builtin_date(fmt)
        if fmt not in custom:
            raise Fail("invalidCell")
        return is_custom_date(custom[fmt])

    rendered = []
    for (name, _), worksheet in zip(sheets, worksheets):
        cells, seen = [], set()
        for data in worksheet:
            if _local(data.tag) != "sheetData":
                continue
            for row in data:
                if _local(row.tag) != "row":
                    continue
                for c in row:
                    if _local(c.tag) != "c":
                        continue
                    r, col = _coordinate(c.get("r"))
                    if (r, col) in seen:
                        raise Fail("invalidCell")
                    seen.add((r, col))
                    kind = c.get("t", "n")
                    value, inline = "", ""
                    for child in c:
                        tag = _local(child.tag)
                        if tag == "v":
                            value = child.text or ""
                        elif tag == "is":
                            inline = _cell_text(child)
                    text = ""
                    if kind == "s" and value:
                        index = int(value)
                        if index >= len(shared):
                            raise Fail("invalidCell")
                        text = render_cell("s", "", shared[index], False, date1904)
                    elif kind == "inlineStr":
                        text = render_cell("inlineStr", "", inline, False, date1904)
                    else:
                        dated = kind == "n" and value != "" and is_date(int(c.get("s", "0")))
                        text = render_cell(kind, value, "", dated, date1904)
                    cells.append((r, col, text))
        rendered.append((name, render_rows(cells)))
    return render_sheets(rendered), [name for name, _ in rendered]


def mutated_parts(asset: str, mutations) -> dict:
    with zipfile.ZipFile(FIXTURES / asset) as archive:
        parts = {name: archive.read(name) for name in archive.namelist()}
    return apply_mutations(parts, mutations)


def apply_mutations(parts: dict, mutations) -> dict:
    parts = dict(parts)
    for mutation in mutations:
        if mutation["operation"] == "remove-entry":
            del parts[mutation["entry"]]
        else:
            parts[mutation["entry"]] = mutation["text"].encode("utf-8")
    return parts


def expected_extraction(parts: dict) -> dict:
    try:
        text, names = read_workbook(parts)
    except Fail as error:
        return dict(error=str(error))
    return dict(text=text, sheetNames=names)


# ---------------------------------------------------------------------------
# v1 renderer (measurement only; frozen folder-rag-v1 §3 XLSX assembly)

def render_v1(parts: dict) -> str:
    """The v1 text of a valid package: every visible or hidden worksheet, A1-reference cells."""
    root_rels = _relationships(parts, "")
    main = next((t for k, t in root_rels.values() if t and k.endswith("/officeDocument")), "xl/workbook.xml")
    workbook = ET.fromstring(parts[main])
    rels = _relationships(parts, main)
    shared_part = next((t for k, t in rels.values() if _rel_kind(k, "sharedStrings")), None)
    shared = [_cell_text(si) for si in ET.fromstring(parts[shared_part])] if shared_part else []
    styles = ET.fromstring(parts[next(t for k, t in rels.values() if _rel_kind(k, "styles"))])
    formats = [int(xf.get("numFmtId", "0")) for child in styles if _local(child.tag) == "cellXfs" for xf in child]
    custom = {int(f.get("numFmtId")): f.get("formatCode") for child in styles
              if _local(child.tag) == "numFmts" for f in child}
    blocks = []
    for child in workbook:
        if _local(child.tag) != "sheets":
            continue
        for sheet in child:
            rid = next(sheet.get("{%s}id" % ns) for ns in REL_NS if sheet.get("{%s}id" % ns))
            worksheet = ET.fromstring(parts[rels[rid][1]])
            cells = []
            for c in worksheet.iter():
                if _local(c.tag) != "c":
                    continue
                r, col = _coordinate(c.get("r"))
                kind = c.get("t", "n")
                formula = any(_local(x.tag) == "f" for x in c)
                value = next((x.text or "" for x in c if _local(x.tag) == "v"), "")
                if kind == "s" and value:
                    value = shared[int(value)]
                elif kind == "inlineStr":
                    value = next(_cell_text(x) for x in c if _local(x.tag) == "is")
                elif kind == "b" and value:
                    value = "TRUE" if value == "1" else "FALSE"
                if formula and not value:
                    text = "[formula; no cached value]"
                elif not value:
                    continue
                else:
                    text = value + (" [cached formula]" if formula else "")
                    fmt = formats[int(c.get("s", "0"))] if c.get("s") else None
                    if kind == "n" and fmt is not None and (is_builtin_date(fmt) or is_custom_date(custom.get(fmt, ""))):
                        text += " [date serial]"
                cells.append((r, col, c.get("r") + ": " + text))
            out, last = "", None
            for r, col, text in sorted(cells):
                if last is not None:
                    out += "\t" if last == r else "\n"
                out += text
                last = r
            blocks.append("## " + sheet.get("name") + "\n" + out)
    return "\n\n".join(blocks)


# ---------------------------------------------------------------------------
# Synthetic workbooks (assets + measurement)

def _xml(body: str) -> bytes:
    return ingestion._asset_xml(body)


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def build_package(sheets, shared, date1904=False, custom_formats=(("164", "d.m.yyyy"),)) -> bytes:
    """sheets: [(name, state, rows)], rows: {row: [(column, xml_attrs, inner_xml)]}.
    Styles: s=0 General, s=1 built-in date 14, s=2 custom date 164, s=3 0.00."""
    main = ingestion._ASSET_MAIN_NS
    rel = ingestion._ASSET_REL_NS
    sheet_xml = "".join(
        '<sheet name="%s" sheetId="%d"%s r:id="rId%d"/>' % (_escape(name), i + 1,
                                                           ' state="%s"' % state if state else "", i + 1)
        for i, (name, state, _) in enumerate(sheets))
    parts = [
        ("[Content_Types].xml", ingestion._asset_content_types(
            [("xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml")]
            + [("xl/worksheets/sheet%d.xml" % (i + 1),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml") for i in range(len(sheets))]
            + [("xl/sharedStrings.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"),
               ("xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml")])),
        ("_rels/.rels", ingestion._asset_root_relationship("xl/workbook.xml")),
        ("xl/workbook.xml", _xml('<workbook xmlns="%s" xmlns:r="%s"><workbookPr date1904="%d"/><sheets>%s</sheets></workbook>'
                                 % (main, rel, 1 if date1904 else 0, sheet_xml))),
        ("xl/_rels/workbook.xml.rels", _xml(
            '<Relationships xmlns="%s">' % ingestion._ASSET_PACKAGE_NS
            + "".join('<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>' % (i + 1, rel, i + 1)
                      for i in range(len(sheets)))
            + '<Relationship Id="rIdS" Type="%s/sharedStrings" Target="sharedStrings.xml"/>' % rel
            + '<Relationship Id="rIdT" Type="%s/styles" Target="styles.xml"/>' % rel
            + "</Relationships>")),
        ("xl/sharedStrings.xml", _xml('<sst xmlns="%s" count="%d" uniqueCount="%d">%s</sst>' % (
            main, len(shared), len(shared), "".join('<si><t xml:space="preserve">%s</t></si>' % _escape(s) for s in shared)))),
        ("xl/styles.xml", _xml(
            '<styleSheet xmlns="%s"><numFmts count="%d">%s</numFmts>' % (
                main, len(custom_formats),
                "".join('<numFmt numFmtId="%s" formatCode="%s"/>' % (i, _escape(c)) for i, c in custom_formats))
            + '<cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="2"/></cellXfs>'
            + "</styleSheet>")),
    ]
    for i, (_, _, rows) in enumerate(sheets):
        body = "".join('<row r="%d">%s</row>' % (r, "".join(
            '<c r="%s%d"%s>%s</c>' % (column_name(col), r, attrs, inner) for col, attrs, inner in rows[r]))
            for r in sorted(rows))
        parts.append(("xl/worksheets/sheet%d.xml" % (i + 1),
                      _xml('<worksheet xmlns="%s"><sheetData>%s</sheetData></worksheet>' % (main, body))))
    return ingestion._asset_zip(parts)


class Strings:
    def __init__(self):
        self.values, self.index = [], {}

    def __call__(self, text):
        if text not in self.index:
            self.index[text] = len(self.values)
            self.values.append(text)
        return ' t="s"', "<v>%d</v>" % self.index[text]


def _formula_number(value, style=0):
    return (' s="%d"' % style if style else ""), "<f>SUM(X1:X2)</f><v>%s</v>" % value


def _formula_empty_string():
    return ' t="str"', '<f>IF(A1="","",A1)</f><v></v>'


def _formula_uncached():
    return "", "<f>VLOOKUP(A1,Lists!A:B,2,0)</f>"


def _formula_error():
    return ' t="e"', "<f>VLOOKUP(A1,Lists!A:B,2,0)</f><v>#N/A</v>"


def template_workbook(rows=120, lookup=150, grid_columns=14) -> bytes:
    """A Czech form template: a form sheet (labels B, inputs D, sparse), a calculation grid with dates,
    formula-heavy columns that are mostly empty-string/zero results, and a hidden lookup sheet."""
    s = Strings()
    form = {}
    labels = ["Název akce", "Investor", "Zhotovitel", "IČO", "Místo stavby", "Termín zahájení",
              "Termín dokončení", "Rozpočet celkem", "Odpovědná osoba", "Telefon", "E-mail", "Poznámka"]
    for i, label in enumerate(labels):
        r = 3 + 2 * i
        form[r] = [(2, *s(label + ":"))]
        if i in (0, 1, 4):
            form[r].append((4, *s(["Oprava střechy ZŠ Komenského", "Město Kolín", "Kolín, Komenského 395"][[0, 1, 4].index(i)])))
        elif i == 5:
            form[r].append((4, ' s="2"', "<v>45383</v>"))
        elif i == 7:
            form[r].append((4, *_formula_number("1250000.0000000002", 3)))
        else:
            form[r].append((4, *_formula_empty_string()))
    grid = {1: [(c + 1, *s(h)) for c, h in enumerate(
        ["Datum", "Položka", "MJ", "Množství", "Cena/MJ", "Celkem", "DPH", "S DPH", "Kontrola", "Středisko",
         "Pozn.", "Index", "Kurz", "Odkaz"][:grid_columns])]}
    items = ["Krytina plechová", "Latě 40/60", "Klempířské prvky", "Lešení", "Doprava", "Okapový systém"]
    for r in range(2, rows + 2):
        row = [(1, ' s="1"', "<v>%d</v>" % (45292 + r))]
        if r % 3 == 0:
            row += [(2, *s(items[r % len(items)])), (3, *s("m2")), (4, "", "<v>%d</v>" % (r * 3)),
                    (5, "", "<v>%s</v>" % ("0.1" if r % 2 else "249.9")),
                    (6, *_formula_number("%r" % (r * 3 * (0.1 if r % 2 else 249.9))))]
        else:
            row += [(2, *_formula_empty_string()), (3, *_formula_empty_string()), (6, *_formula_number("0"))]
        row += [(7, *_formula_number("0")), (8, *_formula_number("0")), (9, *_formula_uncached()),
                (10, *_formula_empty_string()), (11, *_formula_error())]
        row += [(c, *_formula_empty_string()) for c in range(12, grid_columns + 1)]
        grid[r] = row
    lists = {r: [(1, *s("Středisko %03d" % r)), (2, "", "<v>%d</v>" % (1000 + r)), (3, *s("aktivní"))]
             for r in range(1, lookup + 1)}
    return build_package([("Formulář", None, form), ("Rozpočet", None, grid), ("Lists", "hidden", lists)], s.values)


def data_table_workbook(rows=400) -> bytes:
    s = Strings()
    header = ["Datum", "Číslo dokladu", "Dodavatel", "Popis", "Částka", "Měna", "Kurz", "Částka CZK"]
    data = {1: [(c + 1, *s(h)) for c, h in enumerate(header)]}
    vendors = ["ACME s.r.o.", "Stavby Novák a.s.", "Kancelář plus", "Černý Plyn"]
    for r in range(2, rows + 2):
        amount = (r * 137) % 9000 / 7
        data[r] = [(1, ' s="2"', "<v>%d</v>" % (45000 + r)), (2, "", "<v>%d</v>" % (2026000 + r)),
                   (3, *s(vendors[r % 4])), (4, *s("Faktura za služby %d" % (r % 12 + 1))),
                   (5, ' s="3"', "<v>%r</v>" % amount), (6, *s("EUR" if r % 5 == 0 else "CZK")),
                   (7, "", "<v>%s</v>" % ("25.12" if r % 5 == 0 else "1")),
                   (8, *_formula_number("%r" % (amount * (25.12 if r % 5 == 0 else 1)), 3))]
    return build_package([("Doklady", None, data)], s.values)


def sparse_report_workbook(rows=200) -> bytes:
    s = Strings()
    report = {}
    for r in range(1, rows + 1):
        cols = [1 + (r * 7) % 30, 31 + (r * 11) % 20]
        report[r * 3] = [(cols[0], *s("Sekce %d" % (r % 9))), (cols[1], "", "<v>%s</v>" % (r * 0.1))]
    return build_package([("Report", None, report)], s.values)


def header_prefixed(lines):
    """Measurement-only variant: values prefixed with the first row's header names."""
    header, out = None, []
    for line in lines:
        prefix, _, body = line.partition(": ")
        cells = body.split(CELL_SEPARATOR)
        if header is None:
            header = cells
            out.append(line)
            continue
        out.append(prefix + ": " + CELL_SEPARATOR.join(
            (header[i] + "=" + v) if i < len(header) and "=" not in v[:3] else v for i, v in enumerate(cells)))
    return out


def measure() -> None:
    def chunks(text):
        return len(ingestion.scalar_windows(text))

    print("%-26s %10s %10s %7s %7s %7s %8s" % ("workbook", "v1 chars", "v2 chars", "v1 ch", "v2 ch", "saved", "v2+hdr"))
    for name, package in [("form template (18 copies)", template_workbook()),
                          ("template, big grid", template_workbook(rows=1200, lookup=600)),
                          ("dense data table", data_table_workbook()),
                          ("sparse report", sparse_report_workbook())]:
        with zipfile.ZipFile(io.BytesIO(package)) as archive:
            parts = {n: archive.read(n) for n in archive.namelist()}
        v1 = render_v1(parts)
        v2, _ = read_workbook(parts)
        blocks = v2.split("\n\n")
        hdr = "\n\n".join(b.split("\n", 1)[0] + "\n" + "\n".join(header_prefixed(b.split("\n")[1:])) for b in blocks)
        print("%-26s %10d %10d %7d %7d %6d%% %8d" % (name, len(v1), len(v2), chunks(v1), chunks(v2),
                                                   round(100 * (1 - chunks(v2) / chunks(v1))), len(hdr)))


# ---------------------------------------------------------------------------
# Fixture

ASSETS = {
    "ingestion/xlsx/template.xlsx": lambda: template_workbook(rows=24, lookup=6, grid_columns=12),
    "ingestion/xlsx/data-1904.xlsx": lambda: build_package(
        [("Data", None, {1: [(1, ' t="inlineStr"', "<is><t>Datum</t></is>"), (2, ' t="inlineStr"', "<is><t>Čas</t></is>")],
                         2: [(1, ' s="1"', "<v>0</v>"), (2, ' s="2"', "<v>0.5</v>")],
                         3: [(1, ' s="1"', "<v>43830</v>"), (2, ' s="2"', "<v>43830.75</v>")]})],
        [], date1904=True, custom_formats=(("164", "h:mm"),)),
}

SHEET2 = "xl/worksheets/sheet2.xml"
SHEET_NS = ingestion._ASSET_MAIN_NS


def _worksheet(rows: str) -> str:
    return '<worksheet xmlns="%s"><sheetData>%s</sheetData></worksheet>' % (SHEET_NS, rows)


def _styles(code: str) -> str:
    return ('<styleSheet xmlns="%s"><numFmts count="1"><numFmt numFmtId="164" formatCode="%s"/></numFmts>'
            '<cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="164"/></cellXfs></styleSheet>' % (SHEET_NS, code))


def _workbook_xml(sheets: str, pr: str = "") -> str:
    return ('<workbook xmlns="%s" xmlns:r="%s">%s<sheets>%s</sheets></workbook>'
            % (SHEET_NS, ingestion._ASSET_REL_NS, pr, sheets))


ZETA_ALPHA = '<sheet name="Zeta" sheetId="2" r:id="rIdB"/><sheet name="Alpha" sheetId="1" r:id="rIdA"/>'


def _replace(entry: str, text: str) -> dict:
    return dict(operation="replace-entry", entry=entry, text=text)


def number_cases():
    raw = [("integer", "45292"), ("negative-zero", "-0"), ("zero-fraction", "0.000"), ("trailing-dot-zero", "42.0"),
           ("plus-sign", "+5"), ("leading-zeros", "007.50"), ("bare-fraction", ".5"), ("bare-point", "5."),
           ("float-noise-up", "0.30000000000000004"), ("float-noise-down", "1234.5600000000002"),
           ("nines-carry", "2.9999999999999996"), ("carry-new-digit", "999999999999999.7"),
           ("half-up-sixteenth", "1.0000000000000005"), ("below-half", "1.0000000000000004"),
           ("sixteen-digit-integer", "1234567890123456"), ("eighteen-digit-integer", "123456789012345678"),
           ("negative", "-12.5"), ("exponent-plain", "1e5"), ("exponent-fraction", "1.5E-3"),
           ("plain-limit-21", "1E+20"), ("scientific-21", "1E+21"), ("scientific-mantissa", "-1.25E+22"),
           ("small-plain", "0.000001"), ("small-scientific", "1.5E-7"), ("ascii-whitespace", " \t42\r\n"),
           ("exponent-leading-zeros", "1E+00005"), ("too-many-exponent-digits", "1E+123456"),
           ("decimal-exponent-limit", "1E+399"), ("beyond-exponent-limit", "1E+400"),
           ("tiny-at-limit", "1E-401"), ("tiny-beyond-limit", "1E-402"), ("not-numeric-comma", "1,5"), ("not-numeric-text", "NaN"),
           ("not-numeric-hex", "0x10"), ("empty", ""), ("unicode-space-not-trimmed", " 42")]
    return [dict(name="number-" + name, operation="number", input=dict(raw=value),
                 expected=dict(text=render_number(value))) for name, value in raw]


def date_cases():
    raw = [("epoch-1900", "1", False), ("before-leap-bug", "59", False), ("fictional-leap-day", "60", False),
           ("after-leap-bug", "61", False), ("new-year-2024", "45292", False), ("noon", "45292.5", False),
           ("seconds", "45292.000011574", False), ("round-to-next-day", "45292.999999999", False),
           ("time-only", "0.75", False), ("tiny-time", "0.000001", False), ("float-noise-time", "0.29166666666666669", False),
           ("last-day", "2958465", False), ("beyond-9999", "2958466", False), ("zero", "0", False),
           ("negative", "-1", False), ("not-numeric", "abc", False), ("epoch-1904", "0.5", True),
           ("first-day-1904", "1", True), ("same-serial-1904", "45292", True), ("last-day-1904", "2957003", True),
           ("beyond-1904", "2957004", True), ("scientific-serial", "4.5292E+4", False),
           ("huge-serial", "1E+20", False)]
    return [dict(name="date-" + name, operation="date", input=dict(raw=value, date1904=d1904),
                 expected=dict(text=render_date(value, d1904))) for name, value, d1904 in raw]


def value_cases():
    raw = [("plain", "Příliš"), ("inner-runs", "A \t\r\n  B"), ("trim", "  A  "), ("only-space", " \n\t "),
           ("nbsp-kept", " A "), ("emoji", "A😀B"), ("pipe-kept", "a | b"), ("empty", "")]
    return [dict(name="value-" + name, operation="value", input=dict(raw=value),
                 expected=dict(text=normalize_value(value))) for name, value in raw]


def extract_cases():
    def extract(name, mutations=(), asset="ingestion/workbook.xlsx", limits=None, override=None):
        mutations = list(mutations)
        expected = override or expected_extraction(mutated_parts(asset, mutations))
        return dict(name=name, operation="extract",
                    input=dict(asset=asset, kind="xlsx", mutations=mutations, limits=limits or {}),
                    expected=expected)

    def sheet(name, rows, extra=()):
        return extract(name, [_replace(SHEET2, _worksheet(rows))] + list(extra))

    s1 = _styles
    return [
        extract("workbook-order"),
        sheet("formula-no-cache-omitted", '<row r="1"><c r="A1"><f>1+1</f></c><c r="B1"><v>3</v></c></row>'),
        sheet("cached-empty-string-omitted", '<row r="1"><c r="A1" t="str"><f>""</f><v></v></c></row>'
              '<row r="2"><c r="B2" t="str"><f>"x"</f><v>  x  </v></c></row>'),
        sheet("cached-formula-date", '<row r="1"><c r="A1" s="1"><f>1+1</f><v>45292</v></c></row>'),
        sheet("error-values-omitted", '<row r="1"><c r="A1" t="e"><v>#N/A</v></c><c r="B1" t="e"><f>1/0</f>'
              '<v>#DIV/0!</v></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>ok</t></is></c></row>'),
        sheet("empty-sheet-keeps-heading", ""),
        sheet("blank-cells-and-column-gaps", '<row r="10"><c r="AA10"><v>7</v></c><c r="B10"/><c r="A10"><v>0</v></c>'
              '</row><row r="2"><c r="Z2" t="b"><v>0</v></c></row><row r="3"><c r="B3"><v>1</v></c><c r="C3"><v>2</v></c>'
              '<c r="F3"><v>3</v></c></row>'),
        sheet("whitespace-normalized", '<row r="1"><c r="A1" t="inlineStr"><is><t xml:space="preserve">  Řádek 1\n'
              'Řádek\t2  </t></is></c><c r="B1" t="inlineStr"><is><t xml:space="preserve"> \n </t></is></c>'
              '<c r="C1" t="inlineStr"><is><t>x</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t> </t></is></c></row>'),
        sheet("number-formatting", '<row r="1"><c r="A1"><v>0.30000000000000004</v></c><c r="B1"><v>42.0</v></c>'
              '<c r="C1"><v>-1.5E-7</v></c><c r="D1"><v>1E+21</v></c><c r="E1"><v>1,5</v></c><c r="F1"><v>-0</v></c></row>'),
        sheet("boolean-and-iso-date-type", '<row r="1"><c r="A1" t="b"><v>1</v></c><c r="B1" t="d"><v>2024-01-01T00:00:00</v>'
              '</c><c r="C1" t="b"/></row>'),
        sheet("custom-date", '<row r="1"><c r="A1" s="1"><v>45292</v></c></row>', [_replace("xl/styles.xml", s1("yyyy-mm-dd"))]),
        sheet("elapsed-time-format", '<row r="1"><c r="A1" s="1"><v>1.5</v></c></row>', [_replace("xl/styles.xml", s1("[h]:mm:ss"))]),
        sheet("bracket-run-elapsed", '<row r="1"><c r="A1" s="1"><v>0.25</v></c></row>', [_replace("xl/styles.xml", s1("[HHH]:mm"))]),
        sheet("color-bracket-not-date", '<row r="1"><c r="A1" s="1"><v>45292</v></c></row>',
              [_replace("xl/styles.xml", s1("[Red]0.00"))]),
        sheet("quoted-date-literals", '<row r="1"><c r="A1" s="1"><v>45292</v></c></row>',
              [_replace("xl/styles.xml", s1("0.00 &quot;days&quot;"))]),
        sheet("scientific-number", '<row r="1"><c r="A1" s="1"><v>45292</v></c></row>', [_replace("xl/styles.xml", s1("0.00E+00"))]),
        sheet("date-style-on-text-cell-ignored", '<row r="1"><c r="A1" s="1" t="inlineStr"><is><t>45292</t></is></c></row>'),
        sheet("date-serial-out-of-range-is-number", '<row r="1"><c r="A1" s="1"><v>-3</v></c><c r="B1" s="1"><v>0</v></c>'
              '<c r="C1" s="1"><v>3000000</v></c></row>'),
        sheet("missing-style-index", '<row r="1"><c r="A1" s="7"><v>1</v></c></row>'),
        sheet("missing-custom-format", '<row r="1"><c r="A1" s="1"><v>1</v></c></row>',
              [_replace("xl/styles.xml", '<styleSheet xmlns="%s"><cellXfs count="2"><xf numFmtId="0"/>'
                        '<xf numFmtId="170"/></cellXfs></styleSheet>' % SHEET_NS)]),
        sheet("default-style-zero-is-date", '<row r="1"><c r="A1"><v>45292</v></c></row>',
              [_replace("xl/styles.xml", '<styleSheet xmlns="%s"><cellXfs count="1"><xf numFmtId="14"/></cellXfs>'
                        '</styleSheet>' % SHEET_NS)]),
        extract("date1904-workbook", [_replace("xl/workbook.xml", _workbook_xml(ZETA_ALPHA, '<workbookPr date1904="true"/>'))]),
        extract("hidden-and-very-hidden-sheets-skipped", [_replace("xl/workbook.xml", _workbook_xml(
            '<sheet name="Zeta" sheetId="2" state="hidden" r:id="rIdB"/>'
            '<sheet name="Alpha" sheetId="1" state="visible" r:id="rIdA"/>'))]),
        extract("very-hidden-skipped", [_replace("xl/workbook.xml", _workbook_xml(
            '<sheet name="Zeta" sheetId="2" r:id="rIdB"/><sheet name="Alpha" sheetId="1" state="veryHidden" r:id="rIdA"/>'))]),
        extract("all-sheets-hidden", [_replace("xl/workbook.xml", _workbook_xml(
            '<sheet name="Zeta" sheetId="2" state="hidden" r:id="rIdB"/>'
            '<sheet name="Alpha" sheetId="1" state="veryHidden" r:id="rIdA"/>'))]),
        extract("cell-limit", limits=dict(maxCells=2), override=dict(error="cellLimit", cellsMaterialized=2)),
        extract("text-limit", limits=dict(maxExtractedChars=20), override=dict(error="textLimit")),
        extract("template-asset", asset="ingestion/xlsx/template.xlsx"),
        extract("date1904-asset", asset="ingestion/xlsx/data-1904.xlsx"),
    ]


# Frozen v1 fixtures whose expected XLSX canonical text is superseded by v2.
SUPERSEDED = {
    "ingestion-office-v1.json": ["workbook-order", "formula-no-cache", "cached-formula-date", "empty-sheet",
                                 "blank-cells-and-sparse-coordinates", "custom-date", "elapsed-time",
                                 "quoted-date-literals", "scientific-number"],
    "ingestion-ooxml-v1.json": ["workbook-absolute-and-external-targets", "workbook-shared-strings-conventional",
                                "workbook-chartsheet-skipped"],
    "ingestion-formats-v1.json": ["extract-xlsm"],
}


def _is_xlsx_text_case(case) -> bool:
    i = case.get("input")
    if not isinstance(i, dict) or case.get("operation") != "extract" or "text" not in case.get("expected", {}):
        return False
    return i.get("kind") == "xlsx" or str(i.get("asset", "")).endswith((".xlsx", ".xlsm"))


def supersedes() -> dict:
    out = {}
    for filename, names in SUPERSEDED.items():
        frozen = json.loads((FIXTURES / "contracts" / filename).read_text(encoding="utf-8"))
        texts = sorted(c["name"] for c in frozen["cases"] if _is_xlsx_text_case(c))
        if texts != sorted(names):
            raise SystemExit("gen_xlsx_fixtures: %s XLSX text cases changed: %s" % (filename, texts))
        replaced = {}
        for case in frozen["cases"]:
            if case["name"] in names:
                parts = mutated_parts(case["input"]["asset"], case["input"].get("mutations", []))
                expected = expected_extraction(parts)
                if "error" in expected:
                    raise SystemExit("gen_xlsx_fixtures: superseded case %s now fails" % case["name"])
                if "sheetNames" not in case["expected"]:
                    expected.pop("sheetNames")
                if "kind" in case["expected"]:
                    expected["kind"] = case["expected"]["kind"]
                replaced[case["name"]] = expected
        out[filename] = replaced
    release = json.loads((FIXTURES / "contracts/release-integration-v1.json").read_text(encoding="utf-8"))
    workbook = [a for a in release["assets"] if a["kind"] == "xlsx"]
    if [a["repoPath"] for a in workbook] != ["Tests/fixtures/ingestion/workbook.xlsx"]:
        raise SystemExit("gen_xlsx_fixtures: release-integration-v1 workbook asset changed")
    out["release-integration-v1.json"] = {workbook[0]["relPath"]: dict(
        canonicalText=out["ingestion-office-v1.json"]["workbook-order"]["text"])}
    return out


def build() -> dict:
    cases = number_cases() + date_cases() + value_cases() + extract_cases()
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("gen_xlsx_fixtures: duplicate case name")
    return dict(contract=CONTRACT, version=VERSION, textFormatVersion=TEXT_FORMAT_VERSION,
                significantDigits=SIGNIFICANT_DIGITS, cellSeparator=CELL_SEPARATOR,
                cases=cases, supersedes=supersedes())


def encoded(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def outputs() -> dict:
    out = {path: builder() for path, builder in ASSETS.items()}
    # Assets are written first: extract cases read them back from disk.
    return out


def generate(root: Path, check: bool) -> None:
    assets = outputs()
    stale = [p for p, data in assets.items() if not (root / p).is_file() or (root / p).read_bytes() != data]
    if check:
        if stale:
            raise SystemExit("gen_xlsx_fixtures: stale assets: " + ", ".join(stale))
        if not (root / OUTPUT).is_file() or (root / OUTPUT).read_bytes() != encoded(build()):
            raise SystemExit("gen_xlsx_fixtures: %s is stale" % OUTPUT)
        print("ingestion-xlsx-v2.json and %d assets are current" % len(assets))
        return
    for path, data in assets.items():
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_bytes(data)
    (root / OUTPUT).write_bytes(encoded(build()))
    print("generated ingestion-xlsx-v2.json and %d assets" % len(assets))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--measure", action="store_true")
    args = parser.parse_args()
    if args.measure:
        measure()
    else:
        generate(FIXTURES, args.check)
