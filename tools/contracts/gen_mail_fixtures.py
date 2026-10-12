#!/usr/bin/env python3
"""ingestion-mail-v1 / ingestion-formats-v1 reference and fixture generator.

Executable reference for the bounded e-mail readers (RFC 5322/MIME `.eml`,
Outlook `.msg` in an OLE Compound File) and for the macro-enabled OOXML
extensions and the folder default-extension upgrade. Swift
(`MailReader`, `CompoundFile`, `FolderDefaultsUpgrade`) and C# (`MailReader`,
`CompoundFile`, `FolderDefaultsUpgrade`) must reproduce every expected output
exactly. Normative text: docs/contracts/ingestion-mail-v1.md and
docs/contracts/ingestion-formats-v1.md.

Every fixture message is built programmatically (including a minimal CFB
writer); no real mailbox data is used. `--check` regenerates in memory and
compares every owned output without writing.
"""

import argparse
import base64
import io
import json
import struct
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "Tests" / "fixtures"
MAIL_CONTRACT = "contracts/ingestion-mail-v1.json"
FORMATS_CONTRACT = "contracts/ingestion-formats-v1.json"
ASSET_DIR = "ingestion/formats"

# ---------------------------------------------------------------------------
# Shared constants (normative)
# ---------------------------------------------------------------------------

OLD_DEFAULT_EXTS = ["pdf", "txt", "md", "markdown", "docx", "pptx", "xlsx"]
NEW_DEFAULT_EXTS = OLD_DEFAULT_EXTS + ["docm", "pptm", "xlsm", "eml", "msg"]
UPGRADE_MARKER = "data_folder_include_exts_v2"
DETECT = {"pdf": "pdf", "txt": "text", "md": "markdown", "markdown": "markdown",
          "docx": "docx", "docm": "docx", "pptx": "pptx", "pptm": "pptx",
          "xlsx": "xlsx", "xlsm": "xlsx", "eml": "email", "msg": "email"}

MAX_MIME_DEPTH = 32
MAX_MIME_PARTS = 10_000
MAX_CFB_ENTRIES = 100_000
MAX_ATTACHMENTS = 10_000
CFB_MAGIC = bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
WHITE = (set(range(9, 14)) | {32, 133, 160, 5760, 8232, 8233, 8239, 8287, 12288}
         | set(range(8192, 8203)))
DEFAULT_LIMITS = dict(maxFileBytes=52_428_800, maxOfficeDecompressedBytes=209_715_200,
                      maxExtractedChars=5_000_000)


class MailError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def is_white(ch):
    return ord(ch) in WHITE


def collapse(text):
    """Whitespace runs -> one U+0020, trimmed (ScalarChunker whitespace set)."""
    out, pending = [], False
    for ch in text:
        if is_white(ch):
            pending = bool(out)
            continue
        if pending:
            out.append(" ")
            pending = False
        out.append(ch)
    return "".join(out)


def trim(text):
    lo, hi = 0, len(text)
    while lo < hi and is_white(text[lo]):
        lo += 1
    while hi > lo and is_white(text[hi - 1]):
        hi -= 1
    return text[lo:hi]


def normalize_newlines(text):
    return text.replace("\r\n", "\n").replace("\r", "\n")


class Budget:
    """Decoded/read bytes, shared by one document (maxOfficeDecompressedBytes)."""

    def __init__(self, maximum):
        self.maximum, self.used = maximum, 0

    def accept(self, count):
        if count > self.maximum - self.used:
            raise MailError("officeLimit")
        self.used += count


# ---------------------------------------------------------------------------
# Charsets
# ---------------------------------------------------------------------------

def _table(codec):
    out = []
    for b in range(128, 256):
        try:
            out.append(bytes([b]).decode(codec))
        except UnicodeDecodeError:
            out.append("�")
    return out


TABLES = {"windows-1250": _table("cp1250"), "windows-1252": _table("cp1252"),
          "iso-8859-2": _table("iso8859_2")}
LABELS = {"utf-8": "utf-8", "utf8": "utf-8", "us-ascii": "utf-8", "ascii": "utf-8",
          "ansi_x3.4-1968": "utf-8",
          "iso-8859-1": "windows-1252", "iso8859-1": "windows-1252", "latin1": "windows-1252",
          "l1": "windows-1252", "windows-1252": "windows-1252", "cp1252": "windows-1252",
          "iso-8859-2": "iso-8859-2", "iso8859-2": "iso-8859-2", "latin2": "iso-8859-2", "l2": "iso-8859-2",
          "windows-1250": "windows-1250", "cp1250": "windows-1250", "x-cp1250": "windows-1250"}
CODEPAGES = {1250: "windows-1250", 1252: "windows-1252", 28591: "windows-1252", 28592: "iso-8859-2",
             65001: "utf-8", 20127: "utf-8"}


def charset_label(label):
    """ASCII-lowercased, whitespace/quote-trimmed label -> codec name or 'auto'."""
    value = "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in (label or ""))
    value = value.strip(" \t\r\n\"'")
    return LABELS.get(value, "auto")


def strict_utf8(data):
    """Same strict rules as TextDecoding (no overlongs, surrogates, > U+10FFFF)."""
    out, i, n = [], 0, len(data)
    while i < n:
        b = data[i]
        if b < 0x80:
            out.append(chr(b))
            i += 1
            continue
        if 0xC2 <= b <= 0xDF:
            length, value = 2, b & 0x1F
        elif 0xE0 <= b <= 0xEF:
            length, value = 3, b & 0x0F
        elif 0xF0 <= b <= 0xF4:
            length, value = 4, b & 0x07
        else:
            return None
        if i + length > n:
            return None
        for k in range(1, length):
            c = data[i + k]
            if not 0x80 <= c <= 0xBF:
                return None
            value = value << 6 | (c & 0x3F)
        if value < [0, 0, 0x80, 0x800, 0x10000][length] or value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
            return None
        out.append(chr(value))
        i += length
    return "".join(out)


def single_byte(data, codec):
    table = TABLES[codec]
    return "".join(chr(b) if b < 0x80 else table[b - 0x80] for b in data)


def decode_bytes(data, codec, fallback):
    """codec: utf-8 | windows-1250 | windows-1252 | iso-8859-2 | auto. Never fails:
    invalid UTF-8 (declared or auto) falls back to windows-1250 when the folder
    fallback is cp1250, else windows-1252."""
    if codec in TABLES:
        return single_byte(data, codec)
    text = strict_utf8(data)
    if text is not None:
        return text
    return single_byte(data, "windows-1250" if fallback == "cp1250" else "windows-1252")


def utf16le(data):
    """UTF-16LE; unpaired surrogates and an odd trailing byte -> U+FFFD."""
    out, i, n = [], 0, len(data) - len(data) % 2
    while i < n:
        unit = data[i] | data[i + 1] << 8
        i += 2
        if 0xD800 <= unit <= 0xDBFF and i < n:
            low = data[i] | data[i + 1] << 8
            if 0xDC00 <= low <= 0xDFFF:
                out.append(chr(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)))
                i += 2
                continue
        out.append("�" if 0xD800 <= unit <= 0xDFFF else chr(unit))
    if len(data) % 2:
        out.append("�")
    return "".join(out)


# ---------------------------------------------------------------------------
# Transfer encodings
# ---------------------------------------------------------------------------

B64 = {c: i for i, c in enumerate(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")}
HEX = {c: int(chr(c), 16) for c in b"0123456789abcdefABCDEF"}


def base64_lenient(data):
    """Bodies: every non-alphabet byte (whitespace, '=', junk) is ignored; a
    trailing single sextet is dropped."""
    values = [B64[b] for b in data if b in B64]
    out = bytearray()
    full = len(values) // 4 * 4
    for i in range(0, full, 4):
        v = values[i] << 18 | values[i + 1] << 12 | values[i + 2] << 6 | values[i + 3]
        out += bytes([v >> 16, v >> 8 & 0xFF, v & 0xFF])
    rest = values[full:]
    if len(rest) == 2:
        out.append((rest[0] << 18 | rest[1] << 12) >> 16)
    elif len(rest) == 3:
        v = rest[0] << 18 | rest[1] << 12 | rest[2] << 6
        out += bytes([v >> 16, v >> 8 & 0xFF])
    return bytes(out)


def quoted_printable(data):
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        b = data[i]
        if b != 0x3D:
            out.append(b)
            i += 1
            continue
        j = i + 1
        while j < n and data[j] in (0x20, 0x09):
            j += 1
        if j < n and data[j] == 0x0A:
            i = j + 1
            continue
        if j + 1 < n and data[j] == 0x0D and data[j + 1] == 0x0A:
            i = j + 2
            continue
        if j == n:
            i = n  # '=' (plus blanks) ending the data: soft break
            continue
        if i + 2 < n and data[i + 1] in HEX and data[i + 2] in HEX:
            out.append(HEX[data[i + 1]] << 4 | HEX[data[i + 2]])
            i += 3
            continue
        out.append(b)
        i += 1
    return bytes(out)


# ---------------------------------------------------------------------------
# RFC 2047 encoded words
# ---------------------------------------------------------------------------

def _encoded_word(text, i):
    """Parse =?charset?B|Q?payload?= at i -> (end, label, bytes) or None."""
    n = len(text)
    if not text.startswith("=?", i):
        return None
    j = i + 2
    k = j
    while k < n and text[k] != "?" and not is_white(text[k]):
        k += 1
    if k == j or k >= n or text[k] != "?":
        return None
    label = text[j:k].split("*", 1)[0]
    label = "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in label)
    if k + 2 >= n or text[k + 2] != "?" or text[k + 1] not in "bBqQ":
        return None
    mode = text[k + 1].upper()
    p = k + 3
    q = p
    while q < n and text[q] != "?" and not is_white(text[q]):
        q += 1
    if q + 1 >= n or text[q] != "?" or text[q + 1] != "=":
        return None
    payload = text[p:q]
    if any(ord(c) < 0x21 or ord(c) > 0x7E for c in payload):
        return None
    raw = payload.encode("ascii")
    if mode == "B":
        body = raw.rstrip(b"=")
        if any(b not in B64 for b in body) or len(body) % 4 == 1:
            return None
        data = base64_lenient(body)
    else:
        data, m = bytearray(), 0
        while m < len(raw):
            c = raw[m]
            if c == 0x5F:
                data.append(0x20)
                m += 1
            elif c == 0x3D:
                if m + 2 < len(raw) and raw[m + 1] in HEX and raw[m + 2] in HEX:
                    data.append(HEX[raw[m + 1]] << 4 | HEX[raw[m + 2]])
                    m += 3
                else:
                    return None
            else:
                data.append(c)
                m += 1
        data = bytes(data)
    return q + 2, label, data


def decode_words(text, fallback):
    """Encoded words decoded; whitespace between adjacent words dropped; adjacent
    words with the same codec concatenate bytes before decoding. Not collapsed."""
    out, i, n = [], 0, len(text)
    pending, gap_start = None, 0  # pending: (lowercased label, bytearray) of the open word run

    def flush():
        out.append(decode_bytes(bytes(pending[1]), charset_label(pending[0]), fallback))

    while i < n:
        word = _encoded_word(text, i) if text[i] == "=" else None
        if word is not None:
            end, label, data = word
            if pending is not None and pending[0] == label:
                pending[1].extend(data)
            else:
                if pending is not None:
                    flush()
                pending = (label, bytearray(data))
            i = gap_start = end
            continue
        if pending is not None and not is_white(text[i]):
            flush()
            out.append(text[gap_start:i])
            pending = None
        if pending is None:
            out.append(text[i])
        i += 1
    if pending is not None:
        flush()
        out.append(text[gap_start:n])
    return "".join(out)


def decode_header(text, fallback):
    return collapse(decode_words(text, fallback))


# ---------------------------------------------------------------------------
# Header blocks and parameters
# ---------------------------------------------------------------------------

def split_lines(data, start, end):
    """[(line_start, content_end, next_start)] over data[start:end]; LF ends a
    line, a CR before it is not content."""
    lines, i = [], start
    while i < end:
        j = data.find(b"\n", i, end)
        if j < 0:
            lines.append((i, end, end))
            break
        content = j - 1 if j > i and data[j - 1] == 0x0D else j
        lines.append((i, content, j + 1))
        i = j + 1
    return lines


def parse_entity_headers(data, start, end, fallback):
    """-> (headers: list[(lowercase name, raw value str)], body_start)."""
    headers, current = [], None
    lines = split_lines(data, start, end)
    body_start = end
    for line_start, content_end, next_start in lines:
        line = data[line_start:content_end]
        if not line:
            body_start = next_start
            break
        if line[0] in (0x20, 0x09):
            if current is not None:
                current[1].extend(line)
            continue
        colon = line.find(b":")
        if colon <= 0:
            current = None
            continue
        current = [line[:colon], bytearray(line[colon + 1:])]
        headers.append(current)
    result = []
    for name, value in headers:
        key = name.decode("latin-1").strip(" \t")
        key = "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in key)
        result.append((key, decode_bytes(bytes(value), "auto", fallback)))
    return result, body_start


def header(headers, name):
    for key, value in headers:
        if key == name:
            return value
    return None


def _ascii_lower(text):
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in text)


def parse_params(value):
    """'type/sub; a=b; c="q\\"x"' -> (lowercase type, {lowercase name: value})."""
    segments, current, quoted, escape = [], [], False, False
    for ch in value or "":
        if escape:
            current.append(ch)
            escape = False
        elif quoted and ch == "\\":
            current.append(ch)
            escape = True
        elif ch == '"':
            current.append(ch)
            quoted = not quoted
        elif ch == ";" and not quoted:
            segments.append("".join(current))
            current = []
        else:
            current.append(ch)
    segments.append("".join(current))
    kind = _ascii_lower(trim(segments[0]))
    params = {}
    for segment in segments[1:]:
        if "=" not in segment:
            continue
        name, raw = segment.split("=", 1)
        name = _ascii_lower(trim(name))
        raw = trim(raw)
        if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
            inner, out, k = raw[1:-1], [], 0
            while k < len(inner):
                if inner[k] == "\\" and k + 1 < len(inner):
                    out.append(inner[k + 1])
                    k += 2
                else:
                    out.append(inner[k])
                    k += 1
            raw = "".join(out)
        if name and name not in params:
            params[name] = raw
    return kind, params


def _percent(text):
    out, k, raw = bytearray(), 0, text.encode("utf-8")
    while k < len(raw):
        if raw[k] == 0x25 and k + 2 < len(raw) and raw[k + 1] in HEX and raw[k + 2] in HEX:
            out.append(HEX[raw[k + 1]] << 4 | HEX[raw[k + 2]])
            k += 3
        else:
            out.append(raw[k])
            k += 1
    return bytes(out)


def param_value(params, name, fallback):
    """RFC 2231 (single extended value and numbered continuations, max 100
    segments) before the plain value; a plain value may hold encoded words."""
    if name + "*" in params:
        return collapse(_extended([(params[name + "*"], True)], fallback))
    segments = []
    for index in range(100):
        if f"{name}*{index}*" in params:
            segments.append((params[f"{name}*{index}*"], True))
        elif f"{name}*{index}" in params:
            segments.append((params[f"{name}*{index}"], False))
        else:
            break
    if segments:
        return collapse(_extended(segments, fallback))
    if name in params:
        return decode_header(params[name], fallback)
    return ""


def _extended(segments, fallback):
    codec, data = "auto", bytearray()
    for index, (value, extended) in enumerate(segments):
        if extended:
            if index == 0 and value.count("'") >= 2:
                label, _, rest = value.split("'", 2)
                codec = charset_label(label)
                value = rest
            data.extend(_percent(value))
        else:
            data.extend(value.encode("utf-8"))
    return decode_bytes(bytes(data), codec, fallback)


# ---------------------------------------------------------------------------
# HTML -> text
# ---------------------------------------------------------------------------

BLOCK = {"address", "article", "aside", "blockquote", "center", "dd", "div", "dl", "dt", "fieldset",
         "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main",
         "nav", "ol", "p", "pre", "section", "table", "tr", "ul"}
SKIP = {"head", "script", "style", "title"}
ENTITIES = {"amp": "&", "lt": "<", "gt": ">", "quot": '"', "apos": "'", "nbsp": " "}


def _is_alnum(ch):
    return "a" <= ch <= "z" or "A" <= ch <= "Z" or "0" <= ch <= "9"


def html_to_text(html):
    out = []
    state = dict(pending=False, newlines=0, start=True)

    def text(ch):
        if is_white(ch):
            state["pending"] = True
            return
        if state["pending"] and not state["start"] and state["newlines"] == 0:
            out.append(" ")
        state.update(pending=False, newlines=0, start=False)
        out.append(ch)

    def line(hard):
        state["pending"] = False
        if state["start"]:
            return
        if hard:
            if state["newlines"] < 2:
                out.append("\n")
                state["newlines"] += 1
        elif state["newlines"] == 0:
            out.append("\n")
            state["newlines"] = 1

    i, n = 0, len(html)
    while i < n:
        ch = html[i]
        if ch == "<":
            if html.startswith("<!--", i):
                end = html.find("-->", i + 4)
                i = n if end < 0 else end + 3
                continue
            if i + 1 < n and html[i + 1] in "!?":
                end = html.find(">", i + 2)
                i = n if end < 0 else end + 1
                continue
            j = i + 1
            closing = j < n and html[j] == "/"
            if closing:
                j += 1
            k = j
            while k < n and _is_alnum(html[k]):
                k += 1
            if k == j or not ("a" <= html[j] <= "z" or "A" <= html[j] <= "Z"):
                text(ch)
                i += 1
                continue
            name = _ascii_lower(html[j:k])
            quote = None
            while k < n:
                c = html[k]
                if quote:
                    if c == quote:
                        quote = None
                elif c in "\"'":
                    quote = c
                elif c == ">":
                    break
                k += 1
            i = k + 1
            if not closing and name in SKIP:
                lower = _ascii_lower(html)
                end = lower.find("</" + name, i)
                if end < 0:
                    i = n
                else:
                    close = html.find(">", end)
                    i = n if close < 0 else close + 1
                continue
            if name == "br":
                line(True)
            elif name in BLOCK:
                line(False)
            elif name in ("td", "th"):
                state["pending"] = True
            continue
        if ch == "&":
            end = html.find(";", i + 1, i + 12)
            if end > i + 1:
                ref = html[i + 1:end]
                value = None
                if ref[0] == "#":
                    digits = ref[1:]
                    base = 10
                    if digits[:1] in ("x", "X"):
                        digits, base = digits[1:], 16
                    allowed = "0123456789abcdefABCDEF" if base == 16 else "0123456789"
                    if 1 <= len(digits) <= 8 and all(c in allowed for c in digits):
                        code = int(digits, base)
                        value = "�" if code == 0 or 0xD800 <= code <= 0xDFFF or code > 0x10FFFF else chr(code)
                else:
                    value = ENTITIES.get(ref)
                if value is not None:
                    text(value)
                    i = end + 1
                    continue
        text(ch)
        i += 1
    while out and out[-1] == "\n":
        out.pop()
    return "".join(out)


# ---------------------------------------------------------------------------
# EML
# ---------------------------------------------------------------------------

class Entity:
    def __init__(self):
        self.kind, self.params, self.disposition, self.name = "text/plain", {}, "", ""
        self.encoding, self.body, self.children = "", b"", []


def parse_entity(data, start, end, depth, counter, fallback):
    if depth > MAX_MIME_DEPTH:
        raise MailError("officeLimit")
    counter[0] += 1
    if counter[0] > MAX_MIME_PARTS:
        raise MailError("officeLimit")
    headers, body_start = parse_entity_headers(data, start, end, fallback)
    entity = Entity()
    kind, params = parse_params(header(headers, "content-type") or "")
    if "/" not in kind:
        kind, params = "text/plain", {}
    entity.kind, entity.params = kind, params
    disposition, dparams = parse_params(header(headers, "content-disposition") or "")
    entity.disposition = disposition
    entity.name = param_value(dparams, "filename", fallback) or param_value(params, "name", fallback)
    entity.encoding = _ascii_lower(trim(header(headers, "content-transfer-encoding") or ""))
    boundary = params.get("boundary", "")
    if kind.startswith("multipart/") and boundary:
        entity.children = [parse_entity(data, s, e, depth + 1, counter, fallback)[0]
                           for s, e in split_multipart(data, body_start, end, boundary.encode("utf-8"))]
    else:
        entity.body = data[body_start:end]
    return entity, headers


def split_multipart(data, start, end, boundary):
    delimiter = b"--" + boundary
    parts, open_start = [], None
    for line_start, content_end, next_start in split_lines(data, start, end):
        line = data[line_start:content_end].rstrip(b" \t")
        if line == delimiter or line == delimiter + b"--":
            if open_start is not None:
                stop = line_start
                if stop > open_start and data[stop - 1] == 0x0A:
                    stop -= 1
                    if stop > open_start and data[stop - 1] == 0x0D:
                        stop -= 1
                parts.append((open_start, max(open_start, stop)))
            if line == delimiter + b"--":
                return parts
            open_start = next_start
    if open_start is not None:
        parts.append((open_start, end))
    return parts


def is_attachment(entity):
    return entity.disposition == "attachment" or (entity.disposition != "inline" and entity.name != "")


def leaf_text(entity, budget, fallback):
    data = entity.body
    if entity.encoding == "base64":
        data = base64_lenient(data)
    elif entity.encoding == "quoted-printable":
        data = quoted_printable(data)
    budget.accept(len(data))
    text = normalize_newlines(decode_bytes(data, charset_label(entity.params.get("charset", "")), fallback))
    if entity.kind == "text/html":
        text = html_to_text(text)
    return trim(text)


def body_of(entity, budget, fallback):
    if entity.kind.startswith("multipart/") and entity.params.get("boundary", ""):
        children = [c for c in entity.children if not is_attachment(c)]
        if entity.kind == "multipart/alternative":
            for child in children:
                if child.kind == "text/plain":
                    return leaf_text(child, budget, fallback)
            for child in children:
                value = body_of(child, budget, fallback)
                if value is not None:
                    return value
            return None
        bodies = [b for b in (body_of(c, budget, fallback) for c in children) if b is not None]
        if not bodies:
            return None
        return "\n\n".join(b for b in bodies if b)
    if is_attachment(entity) or entity.kind not in ("text/plain", "text/html"):
        return None
    return leaf_text(entity, budget, fallback)


def attachments_of(entity, names):
    if entity.kind.startswith("multipart/") and entity.params.get("boundary", ""):
        for child in entity.children:
            attachments_of(child, names)
    elif is_attachment(entity) and entity.name:
        if len(names) >= MAX_ATTACHMENTS:
            raise MailError("officeLimit")
        names.append(entity.name)


def read_eml(data, fallback, budget):
    start = 0
    if data.startswith(b"From "):
        newline = data.find(b"\n")
        start = len(data) if newline < 0 else newline + 1
    root, headers = parse_entity(data, start, len(data), 0, [0], fallback)
    fields = {key: decode_header(header(headers, key) or "", fallback)
              for key in ("subject", "from", "to", "cc", "date")}
    body = body_of(root, budget, fallback) or ""
    names = []
    attachments_of(root, names)
    return fields, names, trim(body)


# ---------------------------------------------------------------------------
# Compound File Binary (MS-CFB) and Outlook MSG (MS-OXMSG)
# ---------------------------------------------------------------------------

END_OF_CHAIN, FREE_SECT, NO_STREAM = 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF


def _u16(data, at):
    return data[at] | data[at + 1] << 8


def _u32(data, at):
    return data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24


class CompoundFile:
    def __init__(self, data, budget):
        self.data, self.budget = data, budget
        if len(data) < 512 or data[:8] != CFB_MAGIC:
            raise MailError("corruptArchive")
        major, order, shift, mini_shift = _u16(data, 26), _u16(data, 28), _u16(data, 30), _u16(data, 32)
        if order != 0xFFFE or mini_shift != 6 or _u32(data, 56) != 4096 or \
                not ((major == 3 and shift == 9) or (major == 4 and shift == 12)):
            raise MailError("corruptArchive")
        self.major, self.size = major, 1 << shift
        if len(data) < self.size:
            raise MailError("corruptArchive")
        self.count = (len(data) - self.size + self.size - 1) // self.size
        fat_count, first_dir = _u32(data, 44), _u32(data, 48)
        self.first_minifat = _u32(data, 60)
        first_difat, difat_count = _u32(data, 68), _u32(data, 72)
        if fat_count > self.count or difat_count > self.count:
            raise MailError("corruptArchive")
        difat = [_u32(data, 76 + 4 * k) for k in range(109)]
        sector, seen = first_difat, set()
        for _ in range(difat_count):
            if sector >= self.count or sector in seen:
                raise MailError("corruptArchive")
            seen.add(sector)
            block = self.sector(sector)
            per = self.size // 4 - 1
            difat.extend(_u32(block, 4 * k) for k in range(per))
            sector = _u32(block, 4 * per)
        fat_sectors = [s for s in difat if s != FREE_SECT][:fat_count]
        if len(fat_sectors) < fat_count or any(s >= self.count for s in fat_sectors) or \
                len(set(fat_sectors)) != len(fat_sectors):
            raise MailError("corruptArchive")
        self.fat = []
        for s in fat_sectors:
            block = self.sector(s)
            self.fat.extend(_u32(block, 4 * k) for k in range(self.size // 4))
        directory = self.chain_bytes(first_dir, None)
        if len(directory) // 128 > MAX_CFB_ENTRIES:
            raise MailError("officeLimit")
        self.entries = []
        for k in range(len(directory) // 128):
            raw = directory[128 * k:128 * k + 128]
            name_length, kind = _u16(raw, 64), raw[66]
            if kind not in (0, 1, 2, 5) or (kind != 0 and (name_length < 2 or name_length > 64 or name_length % 2)):
                raise MailError("corruptArchive")
            name = utf16le(raw[:name_length - 2]) if kind != 0 else ""
            size = _u32(raw, 120) if major == 3 else _u32(raw, 120) | _u32(raw, 124) << 32
            self.entries.append(dict(name=name, kind=kind, left=_u32(raw, 68), right=_u32(raw, 72),
                                     child=_u32(raw, 76), start=_u32(raw, 116), size=size))
        if not self.entries or self.entries[0]["kind"] != 5:
            raise MailError("corruptArchive")
        self._mini = None
        self._minifat = None

    def sector(self, index):
        offset = (index + 1) * self.size
        block = self.data[offset:offset + self.size]
        self.budget.accept(self.size)
        return block + bytes(self.size - len(block))

    def chain(self, start, needed, table, limit):
        """Sector indices from `start`; stops after `needed` sectors (None: to
        ENDOFCHAIN). Revisits and out-of-range indices are corrupt."""
        out, seen, s = [], set(), start
        while s != END_OF_CHAIN and (needed is None or len(out) < needed):
            if s >= limit or s >= len(table) or s in seen:
                raise MailError("corruptArchive")
            seen.add(s)
            out.append(s)
            s = table[s]
        if needed is not None and len(out) < needed:
            raise MailError("corruptArchive")
        return out

    def chain_bytes(self, start, size):
        needed = None if size is None else (size + self.size - 1) // self.size
        data = b"".join(self.sector(s) for s in self.chain(start, needed, self.fat, self.count))
        return data if size is None else data[:size]

    def children(self, index):
        """{ASCII-uppercased name: entry index}, in-order; first name wins."""
        result, seen, stack = {}, set(), []
        node = self.entries[index]["child"]
        while stack or node != NO_STREAM:
            while node != NO_STREAM:
                if node >= len(self.entries) or node in seen:
                    raise MailError("corruptArchive")
                seen.add(node)
                stack.append(node)
                node = self.entries[node]["left"]
            node = stack.pop()
            entry = self.entries[node]
            if entry["kind"] in (1, 2):
                key = "".join(chr(ord(c) - 32) if "a" <= c <= "z" else c for c in entry["name"])
                result.setdefault(key, node)
            node = entry["right"]
        return result

    def read(self, index):
        entry = self.entries[index]
        if entry["kind"] != 2:
            raise MailError("corruptArchive")
        size = entry["size"]
        if size > len(self.data):
            raise MailError("corruptArchive")
        if size == 0:
            return b""
        if size >= 4096:
            return self.chain_bytes(entry["start"], size)
        if self._mini is None:
            root = self.entries[0]
            if root["size"] > len(self.data):
                raise MailError("corruptArchive")
            self._mini = self.chain_bytes(root["start"], root["size"]) if root["size"] else b""
            table = self.chain_bytes(self.first_minifat, None) if self.first_minifat != END_OF_CHAIN else b""
            self._minifat = [_u32(table, 4 * k) for k in range(len(table) // 4)]
        count = (len(self._mini) + 63) // 64
        sectors = self.chain(entry["start"], (size + 63) // 64, self._minifat, count)
        data = b"".join(self._mini[64 * s:64 * s + 64] for s in sectors)
        if len(data) < size:
            raise MailError("corruptArchive")
        return data[:size]


PR = dict(subject=0x0037, sentName=0x0042, sentEmail=0x0065, senderName=0x0C1A, senderEmail=0x0C1F,
          smtp=0x5D01, displayCc=0x0E03, displayTo=0x0E04, body=0x1000, html=0x1013,
          submitTime=0x0039, deliveryTime=0x0E06, codepage=0x3FFD, internetCpid=0x3FDE,
          attachLong=0x3707, attachShort=0x3704, displayName=0x3001)


def _stream_name(prop, kind):
    return "__SUBSTG1.0_%04X%04X" % (prop, kind)


def msg_string(cfb, children, prop, codec, fallback):
    unicode = children.get(_stream_name(prop, 0x001F))
    if unicode is not None:
        text = utf16le(cfb.read(unicode))
        return text.rstrip("\x00")
    ansi = children.get(_stream_name(prop, 0x001E))
    if ansi is not None:
        return decode_bytes(cfb.read(ansi).rstrip(b"\x00"), codec, fallback)
    return None


def msg_properties(cfb, children):
    index = children.get("__PROPERTIES_VERSION1.0")
    if index is None:
        return {}
    data = cfb.read(index)
    props = {}
    for at in range(32, len(data) - 15, 16):
        tag = _u32(data, at)
        props.setdefault(tag >> 16, (tag & 0xFFFF, data[at + 8:at + 16]))
    return props


def _civil(days):
    """Days since 1970-01-01 -> (y, m, d) (H. Hinnant's civil_from_days)."""
    z = days + 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return (y + 1 if m <= 2 else y), m, d


def filetime(value):
    if value == 0:
        return ""
    seconds = value // 10_000_000 - 11_644_473_600
    days, rest = divmod(seconds, 86400)
    y, m, d = _civil(days)
    if y > 9999:
        return ""
    return "%04d-%02d-%02dT%02d:%02d:%02dZ" % (y, m, d, rest // 3600, rest // 60 % 60, rest % 60)


def read_msg(data, fallback, budget):
    cfb = CompoundFile(data, budget)
    root = cfb.children(0)
    props = msg_properties(cfb, root)

    def long_prop(prop):
        value = props.get(prop)
        return _u32(value[1], 0) if value and value[0] == 0x0003 else None

    codepage = long_prop(PR["codepage"])
    codec = CODEPAGES.get(codepage, "auto") if codepage is not None else "auto"
    cpid = long_prop(PR["internetCpid"])
    html_codec = CODEPAGES.get(cpid, "auto") if cpid is not None else codec

    def s(prop, children=root):
        return collapse(msg_string(cfb, children, prop, codec, fallback) or "")

    name = s(PR["senderName"]) or s(PR["sentName"])
    email = ""
    for prop in (PR["smtp"], PR["senderEmail"], PR["sentEmail"]):
        candidate = s(prop)
        if "@" in candidate:
            email = candidate
            break
    if name and email and name != email:
        sender = f"{name} <{email}>"
    else:
        sender = name or email
    date = ""
    for prop in (PR["submitTime"], PR["deliveryTime"]):
        value = props.get(prop)
        if value and value[0] == 0x0040:
            date = filetime(struct.unpack("<Q", value[1])[0])
            if date:
                break
    fields = dict(subject=s(PR["subject"]), **{"from": sender}, to=s(PR["displayTo"]),
                  cc=s(PR["displayCc"]), date=date)
    body = msg_string(cfb, root, PR["body"], codec, fallback)
    if body is not None:
        body = trim(normalize_newlines(body))
    if not body:
        html = None
        binary = root.get(_stream_name(PR["html"], 0x0102))
        if binary is not None:
            html = decode_bytes(cfb.read(binary), html_codec, fallback)
        else:
            html = msg_string(cfb, root, PR["html"], codec, fallback)
        body = trim(html_to_text(normalize_newlines(html))) if html is not None else ""
    names = []
    storages = sorted(key for key, index in root.items()
                      if key.startswith("__ATTACH_VERSION1.0_#") and cfb.entries[index]["kind"] == 1)
    if len(storages) > MAX_ATTACHMENTS:
        raise MailError("officeLimit")
    for key in storages:
        children = cfb.children(root[key])
        value = s(PR["attachLong"], children) or s(PR["attachShort"], children) or s(PR["displayName"], children)
        if value:
            names.append(value)
    return fields, names, body


# ---------------------------------------------------------------------------
# Canonical document
# ---------------------------------------------------------------------------

def read_mail(data, extension, fallback="cp1250", limits=None):
    limits = dict(DEFAULT_LIMITS, **(limits or {}))
    if len(data) > limits["maxFileBytes"]:
        raise MailError("fileLimit")
    budget = Budget(limits["maxOfficeDecompressedBytes"])
    if data[:8] == CFB_MAGIC:
        fields, names, body = read_msg(data, fallback, budget)
    elif extension == "msg":
        raise MailError("corruptArchive")
    else:
        fields, names, body = read_eml(data, fallback, budget)
    lines = [f"{label}: {fields[key]}" for label, key in
             (("Subject", "subject"), ("From", "from"), ("To", "to"), ("Cc", "cc"), ("Date", "date"))
             if fields[key]]
    if names:
        lines.append("Attachments: " + ", ".join(names))
    head = "\n".join(lines)
    text = head + ("\n\n" if head and body else "") + body
    if len(text) > limits["maxExtractedChars"]:
        raise MailError("textLimit")
    return dict(text=text, title=fields["subject"] or None)


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

def crlf(text):
    return text.replace("\n", "\r\n").encode("utf-8")


def eml_plain_utf8():
    subject_b = base64.b64encode("Příliš žluťoučký".encode("utf-8")).decode()
    # A UTF-8 sequence split across two adjacent words (č = C4 8D).
    return crlf(
        "Return-Path: <jan@example.cz>\n"
        f"Subject: =?UTF-8?B?{subject_b}?=\n"
        " =?utf-8?Q?_k=C5=AF=C5=88_=C3=BAp=C4?= =?utf-8?Q?=9Bl?=\n"
        "From: =?utf-8?Q?Jan_Nov=C3=A1k?= <jan@example.cz>\n"
        "To: Petr Svoboda <petr@example.cz>,\n"
        "\tEva <eva@example.cz>\n"
        "Cc: =?iso-8859-2?Q?Ji=F8=ED?= <jiri@example.cz>\n"
        "Date: Tue, 07 Oct 2026 10:15:00 +0200\n"
        "MIME-Version: 1.0\n"
        "Content-Type: text/plain; charset=\"utf-8\"\n"
        "Content-Transfer-Encoding: 8bit\n"
        "\n"
        "Dobrý den,\n\nposílám podklady.  \n\n-- \nJan\n")


def _qp(data):
    return ["=%02X" % b if b == 61 or not 32 <= b <= 126 else chr(b) for b in data]


def eml_qp_latin2():
    tokens = _qp("Žádost o schůzku, příští týden.".encode("iso-8859-2"))
    return crlf(
        "Subject: =?ISO-8859-2?Q?=AE=E1dost?=\n"
        "From: info@example.cz\n"
        "Date: Mon, 6 Oct 2026 08:00:00 +0000\n"
        "Content-Type: text/plain; charset=ISO-8859-2\n"
        "Content-Transfer-Encoding: quoted-printable\n"
        "\n"
        + "".join(tokens[:12]) + "=\n" + "".join(tokens[12:]) + "\n"
        "Soft=20break=3D ok=  \n"
        "end = literal =4 and =zz\n")


def eml_base64_cp1250():
    payload = "Vážený pane,\r\nzasílám fakturu č. 2026/15.\r\nS pozdravem\r\n".encode("cp1250")
    encoded = base64.b64encode(payload).decode()
    lines = "\n".join(encoded[i:i + 20] for i in range(0, len(encoded), 20))
    return crlf(
        "Subject: =?windows-1250?B?" + base64.b64encode("Faktura č. 15".encode("cp1250")).decode() + "?=\n"
        "From: \"Účtárna\" <ucto@example.cz>\n"
        "To: klient@example.com\n"
        "Content-Type: text/plain; charset=windows-1250\n"
        "Content-Transfer-Encoding: base64\n"
        "\n" + lines + "\n")


def eml_alternative():
    return crlf(
        "Subject: Alternative\n"
        "From: a@example.com\n"
        "Content-Type: multipart/alternative; boundary=\"ALT\"\n"
        "\n"
        "This is a multi-part message in MIME format.\n"
        "--ALT\n"
        "Content-Type: text/html; charset=utf-8\n"
        "\n"
        "<p>HTML <b>version</b></p>\n"
        "--ALT\n"
        "Content-Type: text/plain; charset=utf-8\n"
        "\n"
        "Plain version\n"
        "--ALT--\n"
        "epilogue ignored\n")


def eml_html_only():
    return crlf(
        "Subject: HTML only\n"
        "From: news@example.com\n"
        "Content-Type: text/html; charset=utf-8\n"
        "Content-Transfer-Encoding: quoted-printable\n"
        "\n"
        "<!DOCTYPE html><html><head><title>T</title><style>p{color:red}</style></head>=\n"
        "<body><h1>Nadpis</h1><p>Prvn=C3=AD&nbsp;odstavec &amp; dal=C5=A1=C3=AD</p>\n"
        "<script>alert(1)</script><div>A<br>B<br/><br>C</div><!-- comment -->\n"
        "<table><tr><td>x</td><td>y</td></tr></table>&#269;&#x10D;&bogus; 1 &lt; 2 <unknown>\n"
        "<a href=\"x>y\">link</a></body></html>\n")


def eml_mixed():
    pdf = base64.b64encode(b"%PDF-1.4 fake attachment bytes").decode()
    return crlf(
        "Subject: =?utf-8?Q?P=C5=99=C3=ADlohy?=\n"
        "From: Tester <t@example.com>\n"
        "To: x@example.com\n"
        "Content-Type: multipart/mixed; boundary=\"MIX\"\n"
        "\n"
        "--MIX\n"
        "Content-Type: multipart/related; boundary=\"REL\"\n"
        "\n"
        "--REL\n"
        "Content-Type: multipart/alternative; boundary=\"ALT\"\n"
        "\n"
        "--ALT\n"
        "Content-Type: text/plain; charset=utf-8\n"
        "Content-Transfer-Encoding: quoted-printable\n"
        "\n"
        "Viz p=C5=99=C3=ADlohy.\n"
        "--ALT\n"
        "Content-Type: text/html; charset=utf-8\n"
        "\n"
        "<p>Viz <i>přílohy</i>.</p>\n"
        "--ALT--\n"
        "--REL\n"
        "Content-Type: image/png; name=\"image001.png\"\n"
        "Content-Disposition: inline; filename=\"image001.png\"\n"
        "Content-ID: <image001>\n"
        "Content-Transfer-Encoding: base64\n"
        "\n"
        "iVBORw0KGgo=\n"
        "--REL--\n"
        "--MIX\n"
        "Content-Type: application/pdf; name=\"ignored.pdf\"\n"
        "Content-Disposition: attachment;\n"
        " filename*=UTF-8''Smlouva%20%C4%8D.%201.pdf\n"
        "Content-Transfer-Encoding: base64\n"
        "\n" + pdf + "\n"
        "--MIX\n"
        "Content-Type: application/octet-stream;\n"
        " name=\"=?utf-8?B?" + base64.b64encode("Účet.xlsx".encode()).decode() + "?=\"\n"
        "Content-Transfer-Encoding: base64\n"
        "\n"
        "AAAA\n"
        "--MIX\n"
        "Content-Type: text/plain; charset=utf-8\n"
        "Content-Disposition: attachment;\n"
        " filename*0*=utf-8''pozn%C3%A1mky;\n"
        " filename*1=\".txt\"\n"
        "\n"
        "attachment text is never indexed\n"
        "--MIX\n"
        "Content-Type: text/plain; charset=utf-8\n"
        "\n"
        "Druhý inline text.\n"
        "--MIX--\n")


def eml_no_charset(fallback_bytes):
    return (b"Subject: Bez k\xf3dov\xe1n\xed\nFrom: x@example.com\n\n"
            + fallback_bytes + b"\n")


def eml_mbox_lf():
    return ("From jan@example.cz Tue Oct  7 10:15:00 2026\n"
            "Subject: LF only\n"
            "  folded continuation\n"
            "From: jan@example.cz\n"
            "X-Empty:\n"
            "\n"
            "Line one\r\nLine two\rLine three\n").encode("utf-8")


def eml_depth_bomb():
    head, tail = [], []
    for level in range(MAX_MIME_DEPTH + 1):
        head.append(f"Content-Type: multipart/mixed; boundary=\"B{level}\"\n\n--B{level}\n")
        tail.append(f"\n--B{level}--\n")
    text = "Subject: Deep\n" + "".join(head) + "Content-Type: text/plain\n\ndeep\n" + "".join(reversed(tail))
    return text.encode("utf-8")


def eml_long():
    return crlf("Subject: Long\nFrom: a@example.com\n\n" + "slovo " * 40 + "\n")


# --- CFB writer -------------------------------------------------------------

def _utf16(text):
    return text.encode("utf-16-le")


class CfbWriter:
    """Minimal MS-CFB writer: v3 (512) or v4 (4096) sectors, every stream below
    4096 bytes in the mini stream, larger ones in regular sectors. Siblings form a
    right-linked list (a valid binary tree; colours are not validated)."""

    def __init__(self, major=3):
        self.major = major
        self.size = 512 if major == 3 else 4096
        self.entries = [dict(name="Root Entry", kind=5, children=[], data=b"")]

    def storage(self, parent, name):
        self.entries.append(dict(name=name, kind=1, children=[], data=b""))
        index = len(self.entries) - 1
        self.entries[parent]["children"].append(index)
        return index

    def stream(self, parent, name, data):
        self.entries.append(dict(name=name, kind=2, children=[], data=data))
        self.entries[parent]["children"].append(len(self.entries) - 1)

    def build(self, mutate=None):
        size = self.size
        sectors = []  # list of bytes (each `size` long)
        fat = {}

        def alloc(data):
            if not data:
                return END_OF_CHAIN
            count = (len(data) + size - 1) // size
            first = len(sectors)
            for k in range(count):
                sectors.append(data[k * size:(k + 1) * size].ljust(size, b"\0"))
                fat[first + k] = first + k + 1 if k + 1 < count else END_OF_CHAIN
            return first

        mini, minifat = bytearray(), []
        for entry in self.entries[1:]:
            data = entry["data"]
            if entry["kind"] != 2:
                entry["start"], entry["size"] = 0, 0
            elif len(data) >= 4096:
                entry["start"], entry["size"] = alloc(data), len(data)
            elif data:
                count = (len(data) + 63) // 64
                first = len(mini) // 64
                mini += data.ljust(count * 64, b"\0")
                for k in range(count):
                    minifat.append(first + k + 1 if k + 1 < count else END_OF_CHAIN)
                entry["start"], entry["size"] = first, len(data)
            else:
                entry["start"], entry["size"] = END_OF_CHAIN, 0
        root = self.entries[0]
        root["start"] = alloc(bytes(mini)) if mini else END_OF_CHAIN
        root["size"] = len(mini)
        minifat_bytes = b"".join(struct.pack("<I", v) for v in minifat)
        first_minifat = alloc(minifat_bytes) if minifat else END_OF_CHAIN
        for entry in self.entries:
            entry["left"] = entry["right"] = NO_STREAM
            entry["child"] = entry["children"][0] if entry["children"] else NO_STREAM
        for entry in self.entries:
            for a, b in zip(entry["children"], entry["children"][1:]):
                self.entries[a]["right"] = b
        directory = bytearray()
        for entry in self.entries:
            raw = bytearray(128)
            name = _utf16(entry["name"]) + b"\0\0"
            raw[0:len(name)] = name
            struct.pack_into("<HBB", raw, 64, len(name), entry["kind"], 1)
            struct.pack_into("<III", raw, 68, entry["left"], entry["right"], entry["child"])
            struct.pack_into("<I", raw, 116, entry["start"])
            struct.pack_into("<Q", raw, 120, entry["size"])
            directory += raw
        while len(directory) % size:
            directory += bytes(128)
            struct.pack_into("<III", directory, len(directory) - 60, NO_STREAM, NO_STREAM, NO_STREAM)
        first_dir = alloc(bytes(directory))
        # FAT sectors: enough to cover themselves.
        per = size // 4
        fat_count = 1
        while (len(sectors) + fat_count + per - 1) // per > fat_count:
            fat_count += 1
        fat_first = len(sectors)
        for k in range(fat_count):
            sectors.append(bytes(size))
            fat[fat_first + k] = 0xFFFFFFFD
        table = [fat.get(k, FREE_SECT) for k in range(fat_count * per)]
        if mutate:
            mutate(table, dict(first_dir=first_dir, entries=self.entries))
        for k in range(fat_count):
            sectors[fat_first + k] = b"".join(struct.pack("<I", v) for v in table[k * per:(k + 1) * per])
        header = bytearray(512)
        header[0:8] = CFB_MAGIC
        struct.pack_into("<HHHHH", header, 24, 0x3E, self.major, 0xFFFE, 9 if self.major == 3 else 12, 6)
        struct.pack_into("<I", header, 40, 0 if self.major == 3 else len(directory) // size)
        struct.pack_into("<II", header, 44, fat_count, first_dir)
        struct.pack_into("<III", header, 56, 4096, first_minifat, (len(minifat_bytes) + size - 1) // size)
        struct.pack_into("<II", header, 68, END_OF_CHAIN, 0)
        for k in range(109):
            struct.pack_into("<I", header, 76 + 4 * k, fat_first + k if k < fat_count else FREE_SECT)
        return bytes(header).ljust(size, b"\0") + b"".join(sectors)


def _props(entries, top=True):
    out = bytearray(32 if top else 8)
    for prop, kind, value in entries:
        out += struct.pack("<II", prop << 16 | kind, 0x6) + value.ljust(8, b"\0")
    return bytes(out)


def _ft(year, month, day, hour, minute, second):
    import datetime
    epoch = datetime.datetime(1601, 1, 1)
    delta = datetime.datetime(year, month, day, hour, minute, second) - epoch
    return struct.pack("<Q", (delta.days * 86400 + delta.seconds) * 10_000_000)


def build_msg(strings, props=(), attachments=(), major=3, binaries=(), mutate=None):
    """str values become PT_UNICODE (001F, NUL-terminated UTF-16LE), bytes PT_STRING8 (001E, as given)."""
    writer = CfbWriter(major)
    for prop, value in strings:
        if isinstance(value, bytes):
            writer.stream(0, _stream_name(prop, 0x001E), value)
        else:
            writer.stream(0, _stream_name(prop, 0x001F), _utf16(value) + b"\0\0")
    for prop, value in binaries:
        writer.stream(0, _stream_name(prop, 0x0102), value)
    writer.stream(0, "__properties_version1.0", _props(props))
    for index, values in enumerate(attachments):
        storage = writer.storage(0, "__attach_version1.0_#%08X" % index)
        for prop, value in values:
            writer.stream(storage, _stream_name(prop, 0x001F), _utf16(value) + b"\0\0")
        writer.stream(storage, _stream_name(0x3701, 0x0102), b"attachment payload never read")
        writer.stream(storage, "__properties_version1.0", _props([], top=False))
    writer.stream(0, "__nameid_version1.0", b"")
    return writer.build(mutate)


def msg_unicode():
    return build_msg(
        [(PR["subject"], "Porada – zápis"), (PR["senderName"], "Jana Dvořáková"),
         (PR["senderEmail"], "/O=EXCHANGELABS/OU=EXCHANGE ADMINISTRATIVE GROUP/CN=RECIPIENTS/CN=JANA"),
         (PR["smtp"], "jana@example.cz"), (PR["displayTo"], "Tým  projektu;  Petr Novák"),
         (PR["displayCc"], ""), (PR["body"], "Zápis z porady:\r\n\r\n1. Rozpočet 😀\r\n2. Termíny\r\n\0")],
        props=[(PR["submitTime"], 0x0040, _ft(2026, 10, 7, 8, 15, 0)),
               (PR["deliveryTime"], 0x0040, _ft(2026, 10, 7, 8, 16, 0)),
               (PR["codepage"], 0x0003, struct.pack("<I", 1250))],
        attachments=[[(PR["attachLong"], "Rozpočet 2027.xlsx"), (PR["attachShort"], "ROZPOC~1.XLS")],
                     [(PR["displayName"], "Pozvánka")], [(PR["attachShort"], "")]])


def msg_ansi_cp1250():
    return build_msg(
        [(PR["subject"], "Příliš žluťoučký kůň".encode("cp1250")),
         (PR["sentName"], "Účetní oddělení".encode("cp1250")),
         (PR["sentEmail"], b"ucto@example.cz"),
         (PR["displayTo"], "Novák Jiří".encode("cp1250")),
         (PR["displayCc"], b"Eva"),
         (PR["body"], "Dobrý den,\r\nv příloze faktura.\r\n".encode("cp1250") + b"\0")],
        props=[(PR["deliveryTime"], 0x0040, _ft(2025, 12, 31, 23, 59, 59)),
               (PR["codepage"], 0x0003, struct.pack("<I", 1250))])


def msg_ansi_no_codepage():
    return build_msg([(PR["subject"], "Kódová stránka č. 1250 chybí".encode("cp1250")),
                      (PR["body"], "Žluťoučký kůň úpěl, ďábelské ódy.".encode("cp1250"))])


def msg_html_only():
    html = "<html><body><p>Dobrý <b>den</b>,</p><p>HTML&nbsp;tělo.</p></body></html>".encode("cp1250")
    return build_msg([(PR["subject"], "HTML only"), (PR["senderName"], "Web"), (PR["senderEmail"], "web@example.com")],
                     props=[(PR["internetCpid"], 0x0003, struct.pack("<I", 1250))],
                     binaries=[(PR["html"], html)], major=4)


def msg_large_body():
    body = "".join("Řádek %04d s textem.\r\n" % k for k in range(250))  # > 4096 bytes: regular sectors
    return build_msg([(PR["subject"], "Large body"), (PR["body"], body)])


def msg_fat_loop():
    def mutate(table, info):
        table[info["first_dir"]] = info["first_dir"]  # directory chain points at itself
    return build_msg([(PR["subject"], "Loop")], mutate=mutate)


def msg_tree_cycle():
    data = bytearray(build_msg([(PR["subject"], "Cycle"), (PR["body"], "x")]))
    # Find the directory sector and make entry 2's right sibling point at entry 1.
    size = 512
    first_dir = _u32(data, 48)
    base = (first_dir + 1) * size
    struct.pack_into("<I", data, base + 2 * 128 + 72, 1)
    return bytes(data)


def msg_bad_header():
    data = bytearray(msg_unicode())
    struct.pack_into("<H", data, 30, 10)  # sector shift 10 with major version 3
    return bytes(data)


# --- Macro-enabled OOXML -----------------------------------------------------

_XML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
_PKG = "http://schemas.openxmlformats.org/package/2006/relationships"
_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
_VBA_REL = "http://schemas.microsoft.com/office/2006/relationships/vbaProject"
_VBA = CFB_MAGIC + b"\0" * 8 + b"Attribute VB_Name = \"Module1\"\r\nSub AutoOpen()\r\n Shell \"calc\"\r\nEnd Sub\r\n"


def _zip(parts):
    output = io.BytesIO()
    with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in parts:
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_STORED
            entry.create_system = 0
            entry.create_version = 20
            entry.extract_version = 20
            entry.external_attr = 0x20
            archive.writestr(entry, data)
    return output.getvalue()


def _x(body):
    return (_XML + body + "\n").encode("utf-8")


def _types(main_part, main_type, extra=()):
    return _x('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
              '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
              '<Default Extension="xml" ContentType="application/xml"/>'
              '<Default Extension="bin" ContentType="application/vnd.ms-office.vbaProject"/>'
              f'<Override PartName="/{main_part}" ContentType="{main_type}"/>'
              + "".join(f'<Override PartName="/{p}" ContentType="{t}"/>' for p, t in extra) + '</Types>')


def _root_rels(target):
    return _x(f'<Relationships xmlns="{_PKG}"><Relationship Id="rId1" Type="{_REL}/officeDocument" '
              f'Target="{target}"/></Relationships>')


def docm():
    return _zip([
        ("[Content_Types].xml", _types("word/document.xml", "application/vnd.ms-word.document.macroEnabled.main+xml")),
        ("_rels/.rels", _root_rels("word/document.xml")),
        ("word/document.xml", _x('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                                 '<w:body><w:p><w:r><w:t>Makro dokument</w:t></w:r></w:p>'
                                 '<w:p><w:r><w:t>Druhý odstavec</w:t></w:r></w:p></w:body></w:document>')),
        ("word/_rels/document.xml.rels", _x(f'<Relationships xmlns="{_PKG}"><Relationship Id="rId9" '
                                            f'Type="{_VBA_REL}" Target="vbaProject.bin"/></Relationships>')),
        ("word/vbaProject.bin", _VBA),
    ])


def pptm():
    p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    return _zip([
        ("[Content_Types].xml", _types("ppt/presentation.xml",
                                       "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml")),
        ("_rels/.rels", _root_rels("ppt/presentation.xml")),
        ("ppt/presentation.xml", _x(f'<p:presentation xmlns:p="{p}" xmlns:r="{_REL}"><p:sldIdLst>'
                                    '<p:sldId id="256" r:id="rId2"/></p:sldIdLst></p:presentation>')),
        ("ppt/_rels/presentation.xml.rels", _x(
            f'<Relationships xmlns="{_PKG}"><Relationship Id="rId2" Type="{_REL}/slide" Target="slides/slide1.xml"/>'
            f'<Relationship Id="rId9" Type="{_VBA_REL}" Target="vbaProject.bin"/></Relationships>')),
        ("ppt/slides/slide1.xml", _x(f'<p:sld xmlns:p="{p}" xmlns:a="{a}"><p:cSld><p:spTree><p:sp><p:txBody>'
                                     '<a:p><a:r><a:t>Snímek s makrem</a:t></a:r></a:p></p:txBody></p:sp>'
                                     '</p:spTree></p:cSld></p:sld>')),
        ("ppt/vbaProject.bin", _VBA),
    ])


def xlsm():
    main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    return _zip([
        ("[Content_Types].xml", _types("xl/workbook.xml", "application/vnd.ms-excel.sheet.macroEnabled.main+xml")),
        ("_rels/.rels", _root_rels("xl/workbook.xml")),
        ("xl/workbook.xml", _x(f'<workbook xmlns="{main}" xmlns:r="{_REL}"><sheets>'
                               '<sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>')),
        ("xl/_rels/workbook.xml.rels", _x(
            f'<Relationships xmlns="{_PKG}"><Relationship Id="rId1" Type="{_REL}/worksheet" '
            'Target="worksheets/sheet1.xml"/>'
            f'<Relationship Id="rId9" Type="{_VBA_REL}" Target="vbaProject.bin"/></Relationships>')),
        ("xl/worksheets/sheet1.xml", _x(f'<worksheet xmlns="{main}"><sheetData><row r="1">'
                                        '<c r="A1" t="inlineStr"><is><t>Položka</t></is></c><c r="B1"><v>12</v></c>'
                                        '</row></sheetData></worksheet>')),
        ("xl/vbaProject.bin", _VBA),
    ])


# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------

def assets():
    cp1250_body = "Příliš žluťoučký kůň úpěl ďábelské ódy.".encode("cp1250")
    return {
        "plain-utf8.eml": eml_plain_utf8(),
        "qp-latin2.eml": eml_qp_latin2(),
        "base64-cp1250.eml": eml_base64_cp1250(),
        "alternative.eml": eml_alternative(),
        "html-only.eml": eml_html_only(),
        "mixed-attachments.eml": eml_mixed(),
        "no-charset.eml": eml_no_charset(cp1250_body),
        "mbox-lf.eml": eml_mbox_lf(),
        "depth-bomb.eml": eml_depth_bomb(),
        "long.eml": eml_long(),
        "unicode.msg": msg_unicode(),
        "ansi-cp1250.msg": msg_ansi_cp1250(),
        "ansi-no-codepage.msg": msg_ansi_no_codepage(),
        "html-only.msg": msg_html_only(),
        "large-body.msg": msg_large_body(),
        "fat-loop.msg": msg_fat_loop(),
        "tree-cycle.msg": msg_tree_cycle(),
        "bad-header.msg": msg_bad_header(),
        "not-cfb.msg": b"Subject: plain text renamed to .msg\r\n\r\nbody\r\n",
        "outlook-saved-as.eml": msg_unicode(),
        "macro.docm": docm(),
        "macro.pptm": pptm(),
        "macro.xlsm": xlsm(),
    }


def _expect(fn):
    try:
        return fn()
    except MailError as error:
        return dict(error=error.code)


def mail_cases(files):
    cases = []

    def extract(name, asset, fallback="cp1250", limits=None):
        ext = asset.rsplit(".", 1)[1]
        expected = _expect(lambda: read_mail(files[asset], ext, fallback, limits))
        cases.append(dict(name=name, operation="extract",
                          input=dict(asset=f"{ASSET_DIR}/{asset}", fallback=fallback, limits=limits or {}),
                          expected=expected))

    extract("eml-plain-utf8-encoded-words", "plain-utf8.eml")
    extract("eml-quoted-printable-iso-8859-2", "qp-latin2.eml")
    extract("eml-base64-windows-1250", "base64-cp1250.eml")
    extract("eml-alternative-prefers-plain", "alternative.eml")
    extract("eml-html-only", "html-only.eml")
    extract("eml-mixed-attachments", "mixed-attachments.eml")
    extract("eml-no-charset-fallback-cp1250", "no-charset.eml")
    extract("eml-no-charset-fallback-none", "no-charset.eml", fallback="none")
    extract("eml-mbox-lf-only", "mbox-lf.eml")
    extract("eml-depth-limit", "depth-bomb.eml")
    extract("eml-text-limit", "long.eml", limits=dict(maxExtractedChars=100))
    extract("eml-decoded-budget", "base64-cp1250.eml", limits=dict(maxOfficeDecompressedBytes=20))
    extract("eml-file-limit", "long.eml", limits=dict(maxFileBytes=64))
    extract("eml-containing-cfb-reads-as-msg", "outlook-saved-as.eml")
    extract("msg-unicode", "unicode.msg")
    extract("msg-ansi-cp1250", "ansi-cp1250.msg")
    extract("msg-ansi-codepage-beats-fallback", "ansi-cp1250.msg", fallback="none")
    extract("msg-ansi-no-codepage-fallback-cp1250", "ansi-no-codepage.msg")
    extract("msg-ansi-no-codepage-fallback-none", "ansi-no-codepage.msg", fallback="none")
    extract("msg-html-only-v4-sectors", "html-only.msg")
    extract("msg-large-body-regular-sectors", "large-body.msg")
    extract("msg-fat-loop", "fat-loop.msg")
    extract("msg-directory-cycle", "tree-cycle.msg")
    extract("msg-bad-header", "bad-header.msg")
    extract("msg-not-cfb", "not-cfb.msg")
    extract("msg-read-budget", "unicode.msg", limits=dict(maxOfficeDecompressedBytes=1024))
    extract("msg-text-limit", "large-body.msg", limits=dict(maxExtractedChars=200))

    for name, text in [
        ("adjacent-split-utf8", "=?utf-8?Q?=C4?= =?utf-8?Q?=8D?="),
        ("mixed-charsets", "=?iso-8859-2?Q?=AE?=  =?utf-8?B?xb4=?= text"),
        ("literal-between", "a =?utf-8?Q?b?= c =?utf-8?Q?d?="),
        ("invalid-word-kept", "=?utf-8?X?abc?= =?utf-8?B?***?= =?utf-8?Q?=Z1?="),
        ("lang-suffix-and-underscore", "=?UTF-8*cs?Q?P=C5=99=C3=ADklad_textu?="),
        ("unknown-charset-auto", "=?koi8-r?B?w8XO?= =?x-unknown?Q?=C3=A9?="),
        ("whitespace-collapse", "  a\t\r\n b  "),
    ]:
        cases.append(dict(name="header-" + name, operation="decode-header",
                          input=dict(text=text, fallback="cp1250"), expected=dict(text=decode_header(text, "cp1250"))))
    for name, html in [
        ("blocks-and-breaks", "<div>a</div><div>b<br><br><br>c</div><p>  d  e </p>"),
        ("entities", "&amp;&lt;&gt;&quot;&apos;&nbsp;x&#65;&#x42;&#0;&#xD800;&#99999999;&copy;&amp"),
        ("skipped-elements", "<HEAD><TITLE>t</TITLE></HEAD><Script>x<y</SCRIPT>z<style>s"),
        ("comments-and-doctype", "<!doctype html>a<!-- <p>x</p> -->b<?xml?>c<!-- open"),
        ("quoted-attribute", "<a title=\"1>2\" alt='3>4'>link</a> <img src=x>tail"),
        ("cells", "<table><tr><td>a</td><td>b</td></tr><tr><th>c</th></tr></table>"),
        ("literal-angle", "1 < 2 and 3 <> 4 <5"),
    ]:
        cases.append(dict(name="html-" + name, operation="html-to-text", input=dict(html=html),
                          expected=dict(text=html_to_text(html))))
    high = list(range(128, 256))
    for label in ("windows-1250", "windows-1252", "iso-8859-2"):
        cases.append(dict(name="charset-table-" + label, operation="decode-charset",
                          input=dict(bytes=high, charset=label, fallback="none"),
                          expected=dict(text=decode_bytes(bytes(high), charset_label(label), "none"))))
    for name, data, label, fallback in [
        ("utf8-valid", "Žluť".encode("utf-8"), "UTF-8", "none"),
        ("utf8-invalid-fallback-cp1250", b"\xe8\x9a", "utf-8", "cp1250"),
        ("utf8-invalid-fallback-none", b"\xe8\x9a", "utf-8", "none"),
        ("latin1-is-windows-1252", b"\x80\xe9", "ISO-8859-1", "cp1250"),
        ("quoted-label", b"\xa9", "\"latin2\"", "none"),
        ("unknown-label-auto", b"\xe8", "x-mac-ce", "cp1250"),
        ("overlong-rejected", b"\xc0\xaf", "", "none"),
    ]:
        cases.append(dict(name="charset-" + name, operation="decode-charset",
                          input=dict(bytes=list(data), charset=label, fallback=fallback),
                          expected=dict(text=decode_bytes(data, charset_label(label), fallback))))
    for name, value in [("epoch", 116444736000000000), ("leap-day", None), ("zero", 0), ("beyond-9999", 2650467744000000000)]:
        if value is None:
            value = struct.unpack("<Q", _ft(2024, 2, 29, 12, 0, 1))[0]
        cases.append(dict(name="filetime-" + name, operation="filetime", input=dict(value=value),
                          expected=dict(text=filetime(value))))
    return cases


def formats_cases():
    cases = []
    for name in ["a.pdf", "b.TXT", "c.md", "d.markdown", "e.docx", "f.DOCM", "g.pptx", "h.pptm", "i.xlsx",
                 "j.xlsm", "k.eml", "l.MSG", "m.xls", "n.doc", "o.xlsb", "p.dotm", "noext", ".eml"]:
        ext = name.rsplit(".", 1)[1].lower() if "." in name.lstrip(".") else ""
        cases.append(dict(name="detect-" + name, operation="detect", input=dict(filename=name),
                          expected=dict(kind=DETECT.get(ext))))
    for name, asset, kind, text in [
        ("docm", "macro.docm", "docx", "Makro dokument\nDruhý odstavec"),
        ("pptm", "macro.pptm", "pptx", "## Slide 1\nSnímek s makrem"),
        ("xlsm", "macro.xlsm", "xlsx", "## Data\nA1: Položka\tB1: 12"),
    ]:
        cases.append(dict(name="extract-" + name, operation="extract",
                          input=dict(asset=f"{ASSET_DIR}/{asset}"), expected=dict(kind=kind, text=text)))
    for name, stored, upgraded in [
        ("old-default", OLD_DEFAULT_EXTS, True),
        ("old-default-reordered", list(reversed(OLD_DEFAULT_EXTS)), True),
        ("customized-subset", ["pdf", "docx"], False),
        ("customized-superset", NEW_DEFAULT_EXTS, False),
        ("old-default-with-duplicate", OLD_DEFAULT_EXTS + ["pdf"], False),
        ("old-default-minus-one", OLD_DEFAULT_EXTS[:-1], False),
    ]:
        cases.append(dict(name="upgrade-" + name, operation="upgrade", input=dict(includeExts=stored),
                          expected=dict(includeExts=NEW_DEFAULT_EXTS if upgraded else stored)))
    return cases


def contracts(files):
    mail = dict(contract="ingestion-mail", version=1,
                limits=dict(maxMimeDepth=MAX_MIME_DEPTH, maxMimeParts=MAX_MIME_PARTS,
                            maxCompoundEntries=MAX_CFB_ENTRIES, maxAttachments=MAX_ATTACHMENTS),
                cases=mail_cases(files))
    formats = dict(contract="ingestion-formats", version=1, oldDefaultIncludeExts=OLD_DEFAULT_EXTS,
                   defaultIncludeExts=NEW_DEFAULT_EXTS, upgradeMarker=UPGRADE_MARKER,
                   cases=formats_cases())
    for contract in (mail, formats):
        names = [c["name"] for c in contract["cases"]]
        if len(names) != len(set(names)):
            raise SystemExit("gen_mail_fixtures: duplicate case name")
    return {MAIL_CONTRACT: mail, FORMATS_CONTRACT: formats}


def outputs():
    files = assets()
    result = {f"{ASSET_DIR}/{name}": data for name, data in files.items()}
    for path, value in contracts(files).items():
        result[path] = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare every owned output without writing")
    args = parser.parse_args()
    produced = outputs()
    if args.check:
        stale = [p for p, data in produced.items()
                 if not (FIXTURES / p).is_file() or (FIXTURES / p).read_bytes() != data]
        if stale:
            sys.exit("fixture drift: " + ", ".join(sorted(stale)))
        print(f"checked {len(produced)} mail/format fixtures")
        return
    for path, data in produced.items():
        target = FIXTURES / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(f"generated {len(produced)} mail/format fixtures")


if __name__ == "__main__":
    main()
