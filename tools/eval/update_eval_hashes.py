#!/usr/bin/env python3
"""Explicit authoring hashes; default/check mode never changes corpus bytes."""

import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'eval/multilingual'


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, indent=2,
                       allow_nan=False) + '\n').encode('utf-8')


def updated_files(base=BASE):
    manifest = json.loads((base / 'manifest.json').read_bytes())
    questions = json.loads((base / 'queries.json').read_bytes())
    by_id = {}
    for doc in manifest['documents']:
        path = doc['path']
        if (not path or '\\' in path or ':' in path
                or any(p in ('', '.', '..') for p in path.split('/'))):
            raise ValueError('unsafe document path: ' + path)
        if doc['encoding'] not in ('utf-8', 'windows-1250'):
            raise ValueError('unsupported encoding: ' + doc['encoding'])
        raw = (base / path).read_bytes()
        text = raw.decode(doc['encoding'], errors='strict')
        doc['raw_sha256'] = hashlib.sha256(raw).hexdigest()
        doc['content_hash'] = hashlib.sha256(text.encode('utf-8')).hexdigest()
        if doc['document_id'] in by_id:
            raise ValueError('duplicate document: ' + doc['document_id'])
        by_id[doc['document_id']] = doc
    for query in questions['queries']:
        for gold in query['gold']:
            if gold['document_id'] not in by_id:
                raise ValueError('unknown gold document: ' + gold['document_id'])
            gold['content_hash'] = by_id[gold['document_id']]['content_hash']
    return {'manifest.json': canonical_json(manifest),
            'queries.json': canonical_json(questions)}, len(by_id), len(questions['queries'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--write', action='store_true')
    modes.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        files, documents, queries = updated_files()
        changed = [name for name, data in files.items()
                   if (BASE / name).read_bytes() != data]
        if args.write:
            for name in changed:
                (BASE / name).write_bytes(files[name])
        elif changed:
            print('Corpus hashes or canonical JSON differ: ' + ', '.join(changed), file=sys.stderr)
            return 1
        print(f'{documents} documents, {queries} queries; corpus hashes current')
        return 0
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
