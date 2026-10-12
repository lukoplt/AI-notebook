import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.contracts.gen_markdown_fixtures import (  # noqa: E402
    CASES, STREAM_TEXT, build, encoded, generate, parse)


def t(v):
    return {"t": "text", "v": v}


def para(*inlines):
    return {"type": "paragraph", "inlines": list(inlines)}


def item(*inlines, sublist=None):
    out = {"inlines": list(inlines)}
    if sublist is not None:
        out["sublist"] = sublist
    return out


# Independent, hand-worked expectations: --check cannot bless a shared bug.
WORKED = [
    ("", []),
    ("   \n\t\n", []),
    ("Ahoj světe", [para(t("Ahoj světe"))]),
    ("a\nb\r\nc", [para(t("a b c"))]),
    ("a\n\nb", [para(t("a")), para(t("b"))]),
    ("# Nadpis", [{"type": "heading", "level": 1, "inlines": [t("Nadpis")]}]),
    ("### Tři", [{"type": "heading", "level": 3, "inlines": [t("Tři")]}]),
    ("#### Čtyři", [para(t("#### Čtyři"))]),
    ("#bez", [para(t("#bez"))]),
    ("**tučně**", [para({"t": "strong", "c": [t("tučně")]})]),
    ("*kurzíva* a _taky_", [para({"t": "em", "c": [t("kurzíva")]}, t(" a "),
                                  {"t": "em", "c": [t("taky")]})]),
    ("snake_case_name", [para(t("snake_case_name"))]),
    ("**neukončené", [para(t("**neukončené"))]),
    ("***obojí***", [para({"t": "strong", "c": [{"t": "em", "c": [t("obojí")]}]})]),
    ("`a*b*c`", [para({"t": "code", "v": "a*b*c"})]),
    ("``a`b``", [para({"t": "code", "v": "a`b"})]),
    ("`neukončený", [para(t("`neukončený"))]),
    ("viz [12]", [para(t("viz "), {"t": "cite", "n": 12})]),
    ("[1][2]", [para({"t": "cite", "n": 1}, {"t": "cite", "n": 2})]),
    ("[0] [1234]", [para(t("[0] [1234]"))]),
    ("[12](https://x.cz)", [para({"t": "link", "href": "https://x.cz", "c": [t("12")]})]),
    ("[klik](javascript:alert(1))", [para(t("[klik](javascript:alert(1))"))]),
    ("[w](https://en.wikipedia.org/wiki/A_(b))",
     [para({"t": "link", "href": "https://en.wikipedia.org/wiki/A_(b)", "c": [t("w")]})]),
    ("<b>ne</b>", [para(t("<b>ne</b>"))]),
    ("\\*ne\\*", [para(t("*ne*"))]),
    ("> citace\n> dál", [{"type": "quote", "inlines": [t("citace dál")]}]),
    ("---", [{"type": "rule"}]),
    ("```swift\nlet a = 1\n\n  b\n```", [{"type": "code", "text": "let a = 1\n\n  b"}]),
    ("```\nneukončený\nkód", [{"type": "code", "text": "neukončený\nkód"}]),
    ("- a\n- b", [{"type": "list", "ordered": False, "items": [item(t("a")), item(t("b"))]}]),
    ("3. tři\n4. čtyři", [{"type": "list", "ordered": True, "start": 3,
                           "items": [item(t("tři")), item(t("čtyři"))]}]),
    ("- a\n  - b\n  - c\n- d",
     [{"type": "list", "ordered": False, "items": [
         item(t("a"), sublist={"ordered": False, "items": [item(t("b")), item(t("c"))]}),
         item(t("d"))]}]),
    ("1. a\n   pokračování\n\n2. b",
     [{"type": "list", "ordered": True, "start": 1,
       "items": [item(t("a pokračování")), item(t("b"))]}]),
    ("- a\n\ntext", [{"type": "list", "ordered": False, "items": [item(t("a"))]}, para(t("text"))]),
    ("- a\n1. b", [{"type": "list", "ordered": False, "items": [item(t("a"))]},
                   {"type": "list", "ordered": True, "start": 1, "items": [item(t("b"))]}]),
    ("| a | b |\n|---|---|\n| 1 | 2 |", [para(t("| a | b |")), para(t("| 1 | 2 |"))]),
    ("odstavec\n# nadpis", [para(t("odstavec")),
                            {"type": "heading", "level": 1, "inlines": [t("nadpis")]}]),
]


class MarkdownFixtureTests(unittest.TestCase):
    def test_worked_examples(self):
        for text, expected in WORKED:
            with self.subTest(text=text):
                self.assertEqual(expected, parse(text))

    def test_envelope_and_unique_names(self):
        f = build()
        self.assertEqual("markdown-lite", f["contract"])
        self.assertEqual(1, f["version"])
        names = [c["name"] for c in f["cases"]]
        self.assertEqual(len(names), len(set(names)))
        self.assertGreaterEqual(len(names), 45)
        for c in f["cases"]:
            self.assertEqual({"name", "input", "expected"}, set(c))
            self.assertIsInstance(c["input"], str)

    def test_required_coverage(self):
        inputs = [c["input"] for c in build()["cases"]]
        joined = "\n".join(inputs)
        for needle in ("ř", "ž", "ľ", "ô", "[12](https://", "javascript:", "\n  - ", "**", "```"):
            self.assertIn(needle, joined)
        streams = [c for c in build()["cases"] if c["name"].startswith("stream-")]
        self.assertGreaterEqual(len(streams), 10)
        for c in streams:
            self.assertTrue(STREAM_TEXT.startswith(c["input"]))

    def test_every_prefix_parses(self):
        for name, text in CASES:
            for cut in range(len(text) + 1):
                parse(text[:cut])

    def test_deterministic_and_rejects_stale_file(self):
        self.assertEqual(encoded(), encoded())
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "fixture.json"
            out.write_bytes(encoded())
            self.assertEqual(json.loads(out.read_bytes()), build())
            generate(True, output=out)
            out.write_bytes(b"{}\n")
            with self.assertRaises(SystemExit):
                generate(True, output=out)

    def test_committed_fixture_is_current(self):
        generate(True)


if __name__ == "__main__":
    unittest.main()
