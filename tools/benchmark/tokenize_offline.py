#!/usr/bin/env python3
"""Offline documented-tokenizer counter (WP7 fallback when a provider omits counts).

    python3 tools/benchmark/tokenize_offline.py --root DIR < requests.jsonl > counts.jsonl

DIR/manifest.json maps exact tokenizer IDs to local asset directories:

    {"version": 1, "tokenizers": {"<tokenizerId>": {"path": "<relative dir>",
        "revision": "<immutable upstream revision>", "assetsSha256": "<64 hex>",
        "files": {"<relative file>": "<64 hex>", ...}}}}

`assetsSha256` is SHA-256 over the UTF-8 inventory lines "<sha256>  <file>\\n"
sorted by file path in scalar order. Every file hash and the inventory hash are
verified before the first answer; any missing or mismatched asset terminates
with `tokenizerUnavailable`. Requests are newline JSON {requestId, tokenizerId,
text}; responses are newline JSON {requestId, tokens, tokenizerId, revision,
assetsSha256}. Counting is len(encode(text, add_special_tokens=True,
truncation=False)). This program never downloads, never truncates and never
logs request text. Third-party packages (tokenizer-requirements.txt) are only
imported by the live factory; the pure functions below need none.
"""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path


class TokenizerError(Exception):
    """Stable error code; the message is the code, never request text."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _hex64(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def inventory_sha256(files):
    lines = ''.join(f'{files[name]}  {name}\n' for name in sorted(files, key=lambda n: list(map(ord, n))))
    return hashlib.sha256(lines.encode('utf-8')).hexdigest()


def _inside(root, relative):
    if not isinstance(relative, str) or relative == '' or relative.startswith(('/', '\\')) or '\\' in relative:
        return None
    parts = relative.split('/')
    if any(p in ('', '.', '..') for p in parts):
        return None
    path = root.joinpath(*parts)
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return None
    return path


def load_manifest(root):
    """Read and verify DIR/manifest.json; returns {id: {path, revision, assetsSha256}}."""
    root = Path(root)
    try:
        data = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise TokenizerError('tokenizerUnavailable')
    if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('tokenizers'), dict):
        raise TokenizerError('tokenizerUnavailable')
    verified = {}
    for tokenizer_id, entry in data['tokenizers'].items():
        if not isinstance(entry, dict) or not isinstance(entry.get('revision'), str) or not entry['revision'] \
                or not _hex64(entry.get('assetsSha256')) or not isinstance(entry.get('files'), dict) \
                or not entry['files']:
            raise TokenizerError('tokenizerUnavailable')
        directory = _inside(root, entry.get('path'))
        if directory is None or not directory.is_dir():
            raise TokenizerError('tokenizerUnavailable')
        for name, expected in entry['files'].items():
            path = _inside(directory, name)
            if path is None or not _hex64(expected) or not path.is_file():
                raise TokenizerError('tokenizerUnavailable')
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise TokenizerError('tokenizerUnavailable')
        if inventory_sha256(entry['files']) != entry['assetsSha256']:
            raise TokenizerError('tokenizerUnavailable')
        verified[tokenizer_id] = dict(path=str(directory), revision=entry['revision'],
                                      assetsSha256=entry['assetsSha256'])
    return verified


def count(request, manifest, factory, cache=None):
    """Count one request against an already verified manifest. `factory(path)` loads a tokenizer."""
    if not isinstance(request, dict) or not isinstance(request.get('requestId'), str) or not request['requestId'] \
            or not isinstance(request.get('tokenizerId'), str) or not isinstance(request.get('text'), str):
        raise TokenizerError('invalidRequest')
    entry = manifest.get(request['tokenizerId'])
    if entry is None:
        raise TokenizerError('unknownTokenizer')
    cache = {} if cache is None else cache
    tokenizer = cache.get(request['tokenizerId'])
    if tokenizer is None:
        tokenizer = factory(entry['path'])
        cache[request['tokenizerId']] = tokenizer
    ids = tokenizer.encode(request['text'], add_special_tokens=True, truncation=False)
    return dict(requestId=request['requestId'], tokens=len(ids), tokenizerId=request['tokenizerId'],
                revision=entry['revision'], assetsSha256=entry['assetsSha256'])


def serve(lines, manifest, factory):
    """Yield one response line per request line; errors carry only requestId and code."""
    cache = {}
    for line in lines:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
        except ValueError:
            yield json.dumps(dict(requestId=None, error='invalidRequest'), ensure_ascii=False)
            continue
        try:
            yield json.dumps(count(request, manifest, factory, cache), ensure_ascii=False, sort_keys=True)
        except TokenizerError as error:
            request_id = request.get('requestId') if isinstance(request, dict) else None
            yield json.dumps(dict(requestId=request_id if isinstance(request_id, str) else None,
                                  error=error.code), ensure_ascii=False, sort_keys=True)


def transformers_factory(path):
    # Offline flags are set in main() before this import can run.
    from transformers import AutoTokenizer
    return AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=False)


def main(argv=None):
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    parser = argparse.ArgumentParser(description='Offline documented-tokenizer counter.')
    parser.add_argument('--root', required=True, help='Directory containing manifest.json and tokenizer assets.')
    args = parser.parse_args(argv)
    try:
        manifest = load_manifest(args.root)
    except TokenizerError as error:
        print(json.dumps(dict(error=error.code)), file=sys.stderr)
        return 3
    for response in serve(sys.stdin, manifest, transformers_factory):
        sys.stdout.write(response + '\n')
        sys.stdout.flush()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
