"""python3 -B -m unittest tools.benchmark.test_tokenize_offline (no third-party packages)."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.benchmark.tokenize_offline import (TokenizerError, count, inventory_sha256, load_manifest, main,
                                              serve)


class Tokenizer:
    def __init__(self, calls):
        self.calls = calls

    def encode(self, text, *, add_special_tokens, truncation):
        self.calls.append((text, add_special_tokens, truncation))
        return list(range(len(text) + 2))  # scalar count plus two special tokens


def write_assets(root, files, tokenizer_id='fixture-tokenizer', tamper=None):
    directory = Path(root) / 'assets' / 'fixture'
    directory.mkdir(parents=True)
    hashes = {}
    for name, data in files.items():
        (directory / name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    entry = dict(path='assets/fixture', revision='fixture-revision', assetsSha256=inventory_sha256(hashes),
                 files=dict(hashes))
    if tamper:
        tamper(entry, directory)
    (Path(root) / 'manifest.json').write_text(json.dumps(dict(version=1, tokenizers={tokenizer_id: entry})),
                                              encoding='utf-8')
    return entry


class OfflineCounterTests(unittest.TestCase):
    def test_count_preserves_text_and_disables_truncation(self):
        calls = []

        class Plain:
            def encode(self, text, *, add_special_tokens, truncation):
                calls.append((text, add_special_tokens, truncation))
                return [1, 2, 3]
        manifest = {"fixture-tokenizer": {"path": "unused", "revision": "fixture-revision",
                                          "assetsSha256": "a" * 64}}
        result = count({"requestId": "r1", "tokenizerId": "fixture-tokenizer", "text": "a😀b"},
                       manifest, lambda path: Plain())
        self.assertEqual([("a😀b", True, False)], calls)
        self.assertEqual(3, result["tokens"])
        self.assertEqual("r1", result["requestId"])
        self.assertEqual(("fixture-revision", "a" * 64), (result["revision"], result["assetsSha256"]))

    def test_unknown_tokenizer_is_rejected_without_loading(self):
        loads = []
        with self.assertRaises(TokenizerError) as ctx:
            count({"requestId": "r", "tokenizerId": "missing", "text": "x"}, {}, lambda p: loads.append(p))
        self.assertEqual('unknownTokenizer', ctx.exception.code)
        self.assertEqual([], loads)

    def test_supplementary_scalars_and_request_id_echo(self):
        calls = []
        manifest = {"t": {"path": "p", "revision": "r", "assetsSha256": "b" * 64}}
        lines = [json.dumps({"requestId": "a", "tokenizerId": "t", "text": "𐐀😀"}),
                 json.dumps({"requestId": "b", "tokenizerId": "t", "text": ""}),
                 json.dumps({"requestId": "c", "tokenizerId": "nope", "text": "secret text"})]
        factory_calls = []

        def factory(path):
            factory_calls.append(path)
            return Tokenizer(calls)
        out = [json.loads(x) for x in serve(lines, manifest, factory)]
        self.assertEqual(["a", "b", "c"], [x["requestId"] for x in out])
        self.assertEqual([4, 2], [out[0]["tokens"], out[1]["tokens"]])
        self.assertEqual("unknownTokenizer", out[2]["error"])
        self.assertNotIn("secret text", json.dumps(out))
        self.assertEqual(["𐐀😀", ""], [c[0] for c in calls])
        self.assertEqual(["p"], factory_calls, "one load per tokenizer")

    def test_manifest_hashes_are_verified(self):
        with tempfile.TemporaryDirectory() as root:
            entry = write_assets(root, {"tokenizer.json": b"{}", "config.json": b"{\"a\":1}"})
            verified = load_manifest(root)
            self.assertEqual(entry["assetsSha256"], verified["fixture-tokenizer"]["assetsSha256"])
            self.assertTrue(Path(verified["fixture-tokenizer"]["path"]).is_dir())

    def test_mismatched_asset_terminates(self):
        def tamper(entry, directory):
            (directory / "tokenizer.json").write_bytes(b"{\"changed\":true}")
        with tempfile.TemporaryDirectory() as root:
            write_assets(root, {"tokenizer.json": b"{}"}, tamper=tamper)
            with self.assertRaises(TokenizerError) as ctx:
                load_manifest(root)
            self.assertEqual("tokenizerUnavailable", ctx.exception.code)

    def test_inventory_hash_and_escape_paths_are_rejected(self):
        def bad_inventory(entry, directory):
            entry["assetsSha256"] = "0" * 64

        def escape(entry, directory):
            entry["files"]["../outside"] = "0" * 64
        for tamper in (bad_inventory, escape):
            with tempfile.TemporaryDirectory() as root:
                write_assets(root, {"tokenizer.json": b"{}"}, tamper=tamper)
                with self.assertRaises(TokenizerError):
                    load_manifest(root)
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(TokenizerError):
                load_manifest(root)  # no manifest at all

    def test_main_fails_closed_before_reading_requests(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(3, main(["--root", root]))


if __name__ == "__main__":
    unittest.main()
