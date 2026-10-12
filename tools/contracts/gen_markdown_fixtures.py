#!/usr/bin/env python3
"""MarkdownLite v1: reference parser and shared fixture generator.

    python3 tools/contracts/gen_markdown_fixtures.py          # (re)write the fixture
    python3 tools/contracts/gen_markdown_fixtures.py --check  # fail if it is stale

Writes Tests/fixtures/contracts/markdown-lite-v1.json. Swift
(`Sources/AINotebookCore/MarkdownLite.swift`) and C#
(`windows/src/AINotebook.Core/Text/MarkdownLite.cs`) port `parse` literally and
must reproduce every case.

Normative rules (also in docs/design/tokens-v1.md, "MarkdownLite v1")
=====================================================================

Text model. The input is a sequence of Unicode scalars (Swift: `unicodeScalars`,
C#: UTF-16 chars; every marker is ASCII, so slicing only ever happens at ASCII
positions and the two views agree). "Whitespace" means U+0020 and U+0009 only;
no host Unicode classification is used anywhere. "ASCII punctuation" is
!"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~. A "word char" is any scalar that is neither
whitespace nor ASCII punctuation (so every non-ASCII letter is a word char).

Blocks (line based). CRLF and CR become LF; the text is split on LF (empty
pieces kept). For each line, `content` = the line without leading and trailing
whitespace; `indent` = leading whitespace width (space 1, tab 4).
 1. Inside a fence: a line whose content is only backticks, at least as many as
    the opening run, closes it; any other line is appended verbatim. Code text =
    lines joined by LF. An unterminated fence runs to the end of the input.
 2. Blank content: closes paragraph and quote; inside a list it only marks
    "blank seen" (the list survives if the next non-blank line is a list item).
 3. Fence open: content starts with >= 3 backticks and the rest of the line (the
    ignored info string) contains no backtick. Closes everything open.
 4. Rule: content is >= 3 copies of one of - * _ and nothing else.
 5. Heading: 1-3 '#' followed by whitespace; text = rest, trimmed. "####" and
    "#x" are paragraph text.
 6. Quote: content starts with '>' (one optional space/tab after it is dropped).
    Consecutive quote lines form one quote block whose non-empty bodies are
    joined by a single space. No lazy continuation: a plain line ends the quote.
 7. Table line: content starts with '|'. Each such line is its own paragraph;
    separator rows (only | - : and whitespace, containing '-') are dropped.
 8. List item: `[-*+]` + whitespace, or 1-9 ASCII digits + '.' + whitespace.
    indent >= 2 while a list is open -> item of the sublist of the last top-level
    item (created on first use; its ordered/start come from that first nested
    item; deeper indentation is flattened to this second level). Otherwise a
    top-level item: it joins the open list when the ordered flag matches, else a
    new list starts. `start` = number of the first item (ordered lists only).
    A list item interrupts a paragraph.
 9. Other lines: right after a list item / continuation line (no blank seen) the
    line is appended to the last item (top-level or nested); otherwise it
    continues the open paragraph or starts one. Joined lines are separated by a
    single space.
Every block-start (3-8) closes the open paragraph; 3-7 also close an open list.

Inlines (left to right over the joined text):
 - `\\` + ASCII punctuation -> that character as text.
 - Backtick run of length N opens a code span closed by the next run of exactly
   N backticks; content verbatim, except one leading and trailing space are
   stripped when both exist and the content is not all spaces. No closing run ->
   the run is literal text.
 - `[` + 1-3 digits (first not 0) + `]`, not followed by `(` -> cite.
 - `[text](url)`: text runs to the first `]`, which must be followed by `(`; the
   url ends at the first `)` outside balanced parentheses and must contain no
   whitespace; it is a link only when it starts (ASCII case-insensitive) with
   http://, https:// or mailto: followed by at least one character. Otherwise
   `[` is literal text and scanning continues after it. Link text is parsed
   without links.
 - `*` runs. Length >= 2: strong opener (first two stars) if the next char is
   not whitespace; closer = the first later star run of length >= 2 whose
   preceding char is not whitespace, using its last two stars. Length 1: em
   opener under the same condition; closer = the first later star run of length
   1 or >= 3 with a non-whitespace preceding char, using its last star. Closer
   scans skip escapes and complete code spans.
 - `_` run of length 1 not preceded by a word char and followed by a
   non-whitespace char opens em; closer = the next `_` run of length 1 preceded
   by non-whitespace and not followed by a word char.
 - An opener without a closer leaves its whole run as literal text. Emphasis
   content is parsed recursively as an independent string.
 - No HTML: tags are text. Adjacent text is merged; empty text is never emitted.

Output: blocks `paragraph|heading|quote` {inlines}, heading {level}, `code`
{text}, `rule`, `list` {ordered, start (ordered only), items}; item {inlines,
sublist?}; sublist {ordered, start?, items}. Inlines: text{v}, strong{c}, em{c},
code{v}, link{href,c}, cite{n}.
"""

import argparse
import json
from pathlib import Path
from typing import Optional

CONTRACT = "markdown-lite"
VERSION = 1
ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "Tests/fixtures/contracts/markdown-lite-v1.json"

WS = (" ", "\t")
ASCII_PUNCT = frozenset("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
DIGITS = "0123456789"
LINK_SCHEMES = ("http://", "https://", "mailto:")


def _ws(ch: str) -> bool:
    return ch in WS


def _word(ch: str) -> bool:
    return not _ws(ch) and ch not in ASCII_PUNCT


def _ascii_lower(s: str) -> str:
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in s)


def _trim(s: str) -> str:
    return s.strip(" \t")


def _run(s: str, i: int, ch: str) -> int:
    j = i
    while j < len(s) and s[j] == ch:
        j += 1
    return j - i


# ------------------------------------------------------------------ inlines

def _code_close(s: str, start: int, run: int) -> int:
    p = start
    while p < len(s):
        if s[p] == "`":
            r = _run(s, p, "`")
            if r == run:
                return p
            p += r
        else:
            p += 1
    return -1


def _skip(s: str, p: int) -> int:
    """Returns the index after an escape or complete code span at p, else -1."""
    if s[p] == "\\" and p + 1 < len(s) and s[p + 1] in ASCII_PUNCT:
        return p + 2
    if s[p] == "`":
        r = _run(s, p, "`")
        j = _code_close(s, p + r, r)
        return j + r if j >= 0 else p + r
    return -1


def _cite(s: str, i: int):
    d = _run_digits(s, i + 1)
    end = i + 1 + d
    if 1 <= d <= 3 and s[i + 1] != "0" and end < len(s) and s[end] == "]" \
            and not (end + 1 < len(s) and s[end + 1] == "("):
        return int(s[i + 1:end]), end + 1
    return None


def _run_digits(s: str, i: int) -> int:
    j = i
    while j < len(s) and s[j] in DIGITS:
        j += 1
    return j - i


def _link(s: str, i: int):
    close = s.find("]", i + 1)
    if close < 0 or close + 1 >= len(s) or s[close + 1] != "(":
        return None
    u = close + 2
    p = u
    depth = 0
    while p < len(s):
        c = s[p]
        if _ws(c):
            return None
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                break
            depth -= 1
        p += 1
    if p >= len(s):
        return None
    href = s[u:p]
    low = _ascii_lower(href)
    if not any(low.startswith(x) and len(href) > len(x) for x in LINK_SCHEMES):
        return None
    return s[i + 1:close], href, p + 1


def _star(s: str, i: int, strong: bool):
    s0 = i + (2 if strong else 1)
    if s0 >= len(s) or _ws(s[s0]):
        return None
    p = s0 + 1
    while p < len(s):
        k = _skip(s, p)
        if k >= 0:
            p = k
            continue
        if s[p] == "*":
            r = _run(s, p, "*")
            q = p + r
            if not _ws(s[p - 1]) and ((r >= 2) if strong else (r == 1 or r >= 3)):
                return s[s0:q - (2 if strong else 1)], q
            p = q
            continue
        p += 1
    return None


def _underscore(s: str, i: int):
    s0 = i + 1
    if (i > 0 and _word(s[i - 1])) or s0 >= len(s) or _ws(s[s0]):
        return None
    p = s0 + 1
    while p < len(s):
        k = _skip(s, p)
        if k >= 0:
            p = k
            continue
        if s[p] == "_":
            r = _run(s, p, "_")
            q = p + r
            if r == 1 and not _ws(s[p - 1]) and (q == len(s) or not _word(s[q])):
                return s[s0:p], q
            p = q
            continue
        p += 1
    return None


def parse_inlines(s: str, links: bool = True) -> list:
    out = []
    buf = []

    def flush():
        if buf:
            out.append({"t": "text", "v": "".join(buf)})
            buf.clear()

    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "\\" and i + 1 < n and s[i + 1] in ASCII_PUNCT:
            buf.append(s[i + 1])
            i += 2
        elif ch == "`":
            r = _run(s, i, "`")
            j = _code_close(s, i + r, r)
            if j < 0:
                buf.append(s[i:i + r])
                i += r
                continue
            v = s[i + r:j]
            if len(v) >= 2 and v[0] == " " and v[-1] == " " and v.strip(" ") != "":
                v = v[1:-1]
            flush()
            out.append({"t": "code", "v": v})
            i = j + r
        elif ch == "[":
            cite = _cite(s, i)
            link = None if cite or not links else _link(s, i)
            if cite:
                flush()
                out.append({"t": "cite", "n": cite[0]})
                i = cite[1]
            elif link:
                flush()
                out.append({"t": "link", "href": link[1], "c": parse_inlines(link[0], False)})
                i = link[2]
            else:
                buf.append("[")
                i += 1
        elif ch == "*" or ch == "_":
            r = _run(s, i, ch)
            if ch == "*":
                m = _star(s, i, r >= 2)
                kind = "strong" if r >= 2 else "em"
            else:
                m = _underscore(s, i) if r == 1 else None
                kind = "em"
            if m is None:
                buf.append(ch * r)
                i += r
                continue
            flush()
            out.append({"t": kind, "c": parse_inlines(m[0], links)})
            i = m[1]
        else:
            buf.append(ch)
            i += 1
    flush()
    return out


# ------------------------------------------------------------------- blocks

def _indent(line: str) -> int:
    w = 0
    for c in line:
        if c == " ":
            w += 1
        elif c == "\t":
            w += 4
        else:
            break
    return w


def _list_marker(c: str):
    """(ordered, number, rest) or None. `c` is trimmed and non-empty."""
    if c[0] in "-*+" and len(c) > 1 and _ws(c[1]):
        return False, 0, _trim(c[2:])
    d = _run_digits(c, 0)
    if 1 <= d <= 9 and d + 1 < len(c) and c[d] == "." and _ws(c[d + 1]):
        return True, int(c[:d]), _trim(c[d + 2:])
    return None


def _is_rule(c: str) -> bool:
    return len(c) >= 3 and c[0] in "-*_" and all(x == c[0] for x in c)


def _heading(c: str) -> int:
    h = _run(c, 0, "#")
    return h if 1 <= h <= 3 and h < len(c) and _ws(c[h]) else 0


def _is_table_separator(c: str) -> bool:
    return "-" in c and all(x in "|-: \t" for x in c)


def _sublist(lst: dict) -> dict:
    out = {"ordered": lst["ordered"]}
    if lst["ordered"]:
        out["start"] = lst["start"]
    out["items"] = []
    for it in lst["items"]:
        item = {"inlines": parse_inlines(" ".join(it["lines"]))}
        if it.get("sub") is not None:
            item["sublist"] = _sublist(it["sub"])
        out["items"].append(item)
    return out


def parse(text: str) -> list:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    blocks = []
    st = {"para": None, "quote": None, "list": None, "last": None, "blank": False}

    def close_para():
        if st["para"] is not None:
            blocks.append({"type": "paragraph", "inlines": parse_inlines(" ".join(st["para"]))})
            st["para"] = None

    def close_quote():
        if st["quote"] is not None:
            blocks.append({"type": "quote", "inlines": parse_inlines(" ".join(st["quote"]))})
            st["quote"] = None

    def close_list():
        if st["list"] is not None:
            blocks.append(dict({"type": "list"}, **_sublist(st["list"])))
            st["list"] = None
            st["last"] = None
            st["blank"] = False

    def close_all():
        close_para()
        close_quote()
        close_list()

    fence_run = 0
    fence: Optional[list] = None
    for raw in text.split("\n"):
        if fence is not None:
            c = _trim(raw)
            if len(c) >= fence_run and _run(c, 0, "`") == len(c):
                blocks.append({"type": "code", "text": "\n".join(fence)})
                fence = None
            else:
                fence.append(raw)
            continue
        c = _trim(raw)
        if c == "":
            close_para()
            close_quote()
            if st["list"] is not None:
                st["blank"] = True
            continue
        if c.startswith("```") and "`" not in c[_run(c, 0, "`"):]:
            close_all()
            fence_run = _run(c, 0, "`")
            fence = []
            continue
        if _is_rule(c):
            close_all()
            blocks.append({"type": "rule"})
            continue
        h = _heading(c)
        if h:
            close_all()
            blocks.append({"type": "heading", "level": h, "inlines": parse_inlines(_trim(c[h:]))})
            continue
        if c[0] == ">":
            close_para()
            close_list()
            body = c[1:]
            if body and _ws(body[0]):
                body = body[1:]
            if st["quote"] is None:
                st["quote"] = []
            if body:
                st["quote"].append(body)
            continue
        if c[0] == "|":
            close_all()
            if not _is_table_separator(c):
                blocks.append({"type": "paragraph", "inlines": parse_inlines(c)})
            continue
        m = _list_marker(c)
        if m:
            ordered, number, rest = m
            close_para()
            close_quote()
            lst = st["list"]
            if _indent(raw) >= 2 and lst is not None:
                parent = lst["items"][-1]
                if parent["sub"] is None:
                    parent["sub"] = {"ordered": ordered, "start": number, "items": []}
                item = {"lines": [rest]}
                parent["sub"]["items"].append(item)
            else:
                if lst is not None and lst["ordered"] != ordered:
                    close_list()
                if st["list"] is None:
                    st["list"] = {"ordered": ordered, "start": number, "items": []}
                item = {"lines": [rest], "sub": None}
                st["list"]["items"].append(item)
            st["last"] = item
            st["blank"] = False
            continue
        if st["list"] is not None and not st["blank"]:
            st["last"]["lines"].append(c)
            continue
        close_quote()
        close_list()
        if st["para"] is None:
            st["para"] = []
        st["para"].append(c)
    if fence is not None:
        blocks.append({"type": "code", "text": "\n".join(fence)})
    close_all()
    return blocks


# -------------------------------------------------------------------- cases

STREAM_TEXT = (
    "## Shrnutí\n\n"
    "Podle smlouvy **platí výpovědní lhůta** 3 měsíce [2]. Viz také "
    "[zákoník](https://www.zakonyprolidi.cz/cs/2006-262).\n\n"
    "- první bod s `kódem`\n"
    "  - vnořený *detail* [12]\n"
    "- druhý bod\n\n"
    "```python\nprint(\"ahoj\")\n```\n\n"
    "> Poznámka: ověřte _aktuální_ znění."
)

# 10 cut points chosen to land inside every construct (heading, strong, cite,
# link text, url, code span, nested list, em, fence, quote) + the full text.
STREAM_CUTS = [
    3,                                         # "## " heading marker only
    STREAM_TEXT.index("výpovědní") + 3,        # inside **strong
    STREAM_TEXT.index("[2]") + 2,              # "[2" cite not closed
    STREAM_TEXT.index("[zákoník]") + 4,        # inside link text
    STREAM_TEXT.index("zakonyprolidi") + 5,    # inside url
    STREAM_TEXT.index("`kódem`") + 3,          # inside code span
    STREAM_TEXT.index("*detail*") + 4,         # inside nested *em
    STREAM_TEXT.index("[12]") + 3,             # "[12" cite not closed
    STREAM_TEXT.index("print") + 5,            # inside unterminated fence
    STREAM_TEXT.index("_aktuální_") + 5,       # inside quote _em
    len(STREAM_TEXT),                          # complete answer
]

CASES = [
    ("empty", ""),
    ("whitespace-only", "   \n\t\n  "),
    ("plain-czech", "Příliš žluťoučký kůň úpěl ďábelské ódy."),
    ("plain-slovak", "Ľúbostná báseň: ôsmy kôň, ťava a ďateľ."),
    ("soft-wrap-joins-with-space", "první řádek\ndruhý řádek\r\ntřetí\rčtvrtý"),
    ("blank-line-splits-paragraphs", "Odstavec jedna.\n\n\nOdstavec dvě."),
    ("trailing-spaces-trimmed", "  odsazený text   \n  pokračuje\t"),
    ("headings-1-to-3", "# Jedna\n## Dvě\n### Tři"),
    ("heading-4-is-text", "#### Čtyři"),
    ("heading-needs-space", "#hashtag a # uprostřed"),
    ("heading-interrupts-paragraph", "text odstavce\n## Nadpis\ndalší"),
    ("strong-em-basic", "**tučné**, *kurzíva* a _podtržítko_."),
    ("strong-with-diacritics", "Výsledek: **čtyřiadvacet žlutých**."),
    ("intraword-underscore", "proměnná snake_case_name a __init__"),
    ("intraword-star-em", "a*b*c"),
    ("strong-wraps-em", "**tučné s *kurzívou* uvnitř**"),
    ("triple-star", "***obojí*** a *x **y***"),
    ("unterminated-strong", "Toto je **neukončené tučné"),
    ("unterminated-em", "hvězdička * samotná a *otevřená"),
    ("strong-needs-nonspace", "** mezera ** a **ok**"),
    ("inline-code", "Spusť `swift test` a `dotnet test`."),
    ("code-span-protects-markers", "`**ne**` a `[1]` a `[x](https://a.b)`"),
    ("double-backtick-code", "`` `kód` `` a ``a`b``"),
    ("unterminated-code", "`otevřený kód **tučně**"),
    ("cite-single", "Tvrzení [3]."),
    ("cite-adjacent", "Zdroje [1][2][123]."),
    ("cite-invalid", "[0] [1234] [ab] [ 1]"),
    ("cite-vs-link", "[12] a [12](https://x.cz/a) a [12](ftp://x)"),
    ("link-http-https-mailto", "[web](http://a.cz), [bezpečně](HTTPS://b.cz) a [mail](mailto:a@b.cz)"),
    ("link-javascript-is-text", "[klikni](javascript:alert(1)) prosím"),
    ("link-data-is-text", "[obr](data:text/html,<b>x</b>)"),
    ("link-balanced-parens", "[wiki](https://cs.wikipedia.org/wiki/Praha_(město))"),
    ("link-with-space-is-text", "[a](https://x.cz \"titulek\")"),
    ("link-text-formatting", "[**tučný** odkaz](https://x.cz)"),
    ("link-bare-scheme-is-text", "[x](https://) [y](mailto:)"),
    ("link-scheme-ascii-case-only", "[a](HTTPſ://x) [b](maılto:x) [c](MAILTO:x)"),
    ("unterminated-link", "[text](https://x.cz/neukoncene"),
    ("html-stays-text", "<b>tučně</b> <script>alert(1)</script>"),
    ("escapes", "\\*není kurzíva\\* a \\[1] a \\\\ a \\ž"),
    ("quote-multiline", "> První řádek citace\n>druhý\n>\n> **třetí**"),
    ("quote-then-paragraph", "> citace\nobyčejný text"),
    ("rules", "nad\n---\n***\n___\npod"),
    ("rule-needs-same-char", "-*-"),
    ("bullet-list-markers", "- pomlčka\n* hvězdička\n+ plus"),
    ("ordered-list-start", "3. tři\n4. čtyři\n10. deset"),
    ("ordered-needs-dot-space", "1.5 kg a 2) ne"),
    ("nested-list", "- ovoce\n  - jablko\n  - hruška\n- zelenina\n    - mrkev"),
    ("nested-ordered-in-bullet", "- kroky\n  1. první\n  2. druhý"),
    ("nested-without-parent-is-top", "  - odsazená položka\n- další"),
    ("list-continuation-line", "1. **Název**\n   popis položky\n2. Další"),
    ("loose-list-survives-blank", "1. a\n\n2. b\n\n3. c"),
    ("list-then-paragraph", "- položka\n\nOdstavec za seznamem."),
    ("list-kind-switch", "- odrážka\n1. číslo"),
    ("list-interrupts-paragraph", "Úvod:\n- bod"),
    ("list-item-inline-markup", "- **tučně** a [1] a `kód`"),
    ("fence-basic", "```swift\nlet ž = \"ř\"\n\n    odsazeno\n```"),
    ("fence-unterminated", "Kód:\n```\nřádek 1\nřádek 2"),
    ("fence-longer-closer-run", "````\n```\nvnitřní\n```\n````"),
    ("fence-info-with-backtick-is-text", "```a`b```"),
    ("fence-closes-list", "- bod\n```\nkód\n```"),
    ("table-as-paragraphs", "| Jméno | Věk |\n|:---|---:|\n| Žofie | 30 |"),
    ("tabs-indent-nested", "- a\n\t- b"),
    ("emoji-and-astral", "**😀 smajlík** a 𝔘 [1]"),
]


def _cases() -> list:
    out = [{"name": n, "input": s, "expected": parse(s)} for n, s in CASES]
    for k, cut in enumerate(STREAM_CUTS):
        s = STREAM_TEXT[:cut]
        out.append({"name": f"stream-{k:02d}-cut-{cut}", "input": s, "expected": parse(s)})
    return out


def build() -> dict:
    return {"contract": CONTRACT, "version": VERSION, "cases": _cases()}


def encoded() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def generate(check: bool = False, output: Optional[Path] = None) -> None:
    path = output or OUTPUT
    data = encoded()
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit("markdown-lite-v1.json is stale; run gen_markdown_fixtures.py")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    generate(parser.parse_args().check)
