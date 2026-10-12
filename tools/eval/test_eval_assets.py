import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'eval/multilingual'

SUFFIXES = [
    'customer/contracts/master.md', 'supplier/contracts/master.md',
    'customer/finance/2026/10/invoice.md', 'supplier/finance/2026/10/invoice.md',
    'customer/meetings/2026/kickoff.md', 'customer/meetings/2026/risk.md',
    'supplier/meetings/2026/handover.md', 'customer/technical/runbooks/recovery.md',
    'supplier/technical/interfaces/telemetry.md', 'customer/technical/legacy/terminal.txt',
]


def assets():
    return (json.loads((BASE / 'manifest.json').read_bytes()),
            json.loads((BASE / 'queries.json').read_bytes()))


def selected(document, question):
    scope = question['scope']
    return document['notebook_id'] == question['notebook_id'] and (
        scope['kind'] == 'all' or document['source_id'] in scope['sourceIds']
        or document['folder_id'] in scope['folderIds'])

class EvalAssetsTests(unittest.TestCase):
    def test_real_corpus(self):
        m = json.loads((BASE / 'manifest.json').read_text(encoding='utf-8'))
        qs = json.loads((BASE / 'queries.json').read_text(encoding='utf-8'))['queries']
        self.assertEqual(44, len(m['documents']))
        self.assertEqual(144, len(qs))
        self.assertEqual(44, len({d['document_id'] for d in m['documents']}))
        self.assertEqual(144, len({q['query_id'] for q in qs}))
        counts = {lang: sum(d['language'] == lang for d in m['documents'])
                  for lang in ('cs', 'sk', 'en', 'de', 'mixed')}
        self.assertEqual({'cs': 10, 'sk': 10, 'en': 10, 'de': 10, 'mixed': 4}, counts)
        by_id = {}
        for d in m['documents']:
            raw = (BASE / d['path']).read_bytes()
            text = raw.decode(d['encoding'], errors='strict')
            self.assertEqual(hashlib.sha256(raw).hexdigest(), d['raw_sha256'])
            self.assertEqual(hashlib.sha256(text.encode('utf-8')).hexdigest(), d['content_hash'])
            self.assertTrue(text.endswith('\n'))
            self.assertNotIn('\r', text)
            by_id[d['document_id']] = (d, text)
        for q in qs:
            for g in q['gold']:
                d, text = by_id[g['document_id']]
                self.assertEqual(d['content_hash'], g['content_hash'], q['query_id'])
                starts = [i for i in range(len(text)) if text.startswith(g['phrase'], i)]
                self.assertTrue(g['phrase'])
                self.assertGreaterEqual(g['occurrence'], 1)
                self.assertLessEqual(g['occurrence'], len(starts), q['query_id'])
                s = q['scope']
                selected = (s['kind'] == 'all' or d['source_id'] in s['sourceIds']
                            or d['folder_id'] in s['folderIds'])
                self.assertTrue(d['notebook_id'] == q['notebook_id'] and selected)
        self.assertEqual(4, sum(q['case_type'] == 'absent' for q in qs))
        self.assertEqual(4, sum(q['case_type'] == 'empty_selection' for q in qs))
        self.assertEqual(4, sum(q['case_type'] == 'overview' for q in qs))

    def test_cp1250_is_real_bytes(self):
        p = BASE / 'documents/cs/customer/technical/legacy/terminal.txt'
        raw = p.read_bytes()
        with self.assertRaises(UnicodeDecodeError):
            raw.decode('utf-8', errors='strict')
        self.assertIn('Příliš žluťoučký kůň', raw.decode('cp1250', errors='strict'))

    def test_inventory_and_canonical_bytes(self):
        m, q = assets()
        self.assertEqual(('eval-corpus', 1, 'multilingual-v1', 'MIT'),
                         (m['contract'], m['version'], m['corpus_id'], m['license']))
        self.assertEqual(('eval-queries', 1, m['corpus_id']),
                         (q['contract'], q['version'], q['corpus_id']))
        expected = {}
        for n, lang in enumerate(('cs', 'sk', 'en', 'de'), 1):
            for row, suffix in enumerate(SUFFIXES, 1):
                expected[f'{lang}-{row:02}'] = (
                    f'documents/{lang}/{suffix}', suffix.split('/', 1)[1],
                    n * 100 + row, 1, (n - 1) * 20 + (10 if suffix.startswith('customer/') else 20))
        for row, path, rel_path, notebook, folder in [
            (1, 'mixed/customer/meetings/rollout.md', 'meetings/rollout.md', 1, 90),
            (2, 'mixed/supplier/contracts/addendum.md', 'contracts/addendum.md', 1, 100),
            (3, 'loose/handover.md', 'handover.md', 1, None),
            (4, 'other-notebook/technical/recovery.md', 'technical/recovery.md', 2, 110),
        ]:
            expected[f'mix-{row:02}'] = ('documents/' + path, rel_path, 500 + row, notebook, folder)
        self.assertEqual(set(expected), {d['document_id'] for d in m['documents']})
        self.assertEqual(44, len({d['source_id'] for d in m['documents']}))
        actual_paths = set()
        for d in m['documents']:
            self.assertEqual(expected[d['document_id']], tuple(d[k] for k in
                             ('path', 'rel_path', 'source_id', 'notebook_id', 'folder_id')))
            self.assertEqual('windows-1250' if d['document_id'] == 'cs-10' else 'utf-8', d['encoding'])
            raw = (BASE / d['path']).read_bytes()
            self.assertFalse(raw.startswith(b'\xef\xbb\xbf'))
            self.assertNotIn(b'\r', raw)
            self.assertTrue(raw.endswith(b'\n'))
            actual_paths.add(d['path'])
        self.assertEqual(actual_paths, {str(p.relative_to(BASE)) for p in (BASE / 'documents').rglob('*') if p.is_file()})

    def test_authored_length_and_unicode(self):
        m, _ = assets()
        long_docs = []
        for d in m['documents']:
            text = (BASE / d['path']).read_bytes().decode(d['encoding'])
            count = len(text.split())
            low, high = (120, 220) if d['path'].endswith('/invoice.md') else (250, 500)
            self.assertTrue(low <= count <= high, (d['document_id'], count))
            if d['language'] == 'mixed':
                sections = text.split('\n## ')[1:]
                self.assertEqual(2, len(sections))
                for section in sections:
                    self.assertGreaterEqual(len(section.split('\n', 1)[1].split()), 150)
            if len(text) > 4096 and any('/' + kind + '/' in d['path'] for kind in ('technical', 'contracts')):
                long_docs.append(d['document_id'])
            if d['document_id'] == 'en-08':
                self.assertIn('🔧', text)
                self.assertIn('e\u0301', text)
                self.assertLess(text.index('e\u0301'), text.index('snapshot M53'))
            if d['document_id'] == 'sk-10':
                self.assertTrue(set('ľĺŕôä').issubset(set(text)))
        self.assertGreaterEqual(len(long_docs), 8, long_docs)

    def test_questions_scopes_and_language_coverage(self):
        m, qs = assets()
        documents = {d['document_id']: d for d in m['documents']}
        queries = {q['query_id']: q for q in qs['queries']}
        expected_ids = {d + '-' + kind for d in documents for kind in ('paraphrase', 'identifier', 'scope')}
        expected_ids |= {kind + '-' + lang for kind in ('absent', 'empty', 'overview') for lang in ('cs', 'sk', 'en', 'de')}
        self.assertEqual(expected_ids, set(queries))
        self.assertEqual({'answer', 'exact_identifier', 'scope', 'absent', 'empty_selection', 'overview'},
                         {q['case_type'] for q in queries.values()})
        self.assertEqual({'mixed', 'cross_language', 'cp1250', 'repeated_phrase', 'overlap'},
                         {t for q in queries.values() for t in q['tags']})
        scope_kinds, cross, matched = set(), [], 0
        for q in queries.values():
            self.assertRegex(q['query_id'], r'^[a-z0-9][a-z0-9-]*$')
            self.assertIn(q['language'], ('cs', 'sk', 'en', 'de'))
            self.assertTrue(q['text'].strip())
            self.assertEqual(len(q['tags']), len(set(q['tags'])))
            s = q['scope']
            self.assertIn(s['kind'], ('all', 'selection'))
            if s['kind'] == 'selection':
                self.assertTrue(set(s['sourceIds']) <= {d['source_id'] for d in documents.values()})
                self.assertTrue(set(s['folderIds']) <= {d['folder_id'] for d in documents.values()})
                scope_kinds.add((bool(s['sourceIds']), bool(s['folderIds'])))
            if q['case_type'] in ('absent', 'empty_selection'):
                self.assertEqual([], q['gold'])
                self.assertEqual('not_in_corpus' if q['case_type'] == 'absent' else 'empty_scope', q['absent_reason'])
                self.assertEqual([], q['overview_document_ids'])
                if q['case_type'] == 'empty_selection':
                    self.assertFalse(any(selected(d, q) for d in documents.values()))
            else:
                self.assertTrue(q['gold'])
                self.assertIsNone(q['absent_reason'])
            if q['case_type'] != 'overview':
                self.assertEqual([], q['overview_document_ids'])
            for gold in q['gold']:
                self.assertLess(len(gold['phrase']), 160)
            if q['query_id'].endswith('-paraphrase'):
                d = documents[q['query_id'].removesuffix('-paraphrase')]
                if d['language'] != 'mixed' and d['language'] != q['language']:
                    cross.append(q)
                    self.assertIn('cross_language', q['tags'])
                self.assertEqual(d['document_id'], q['gold'][0]['document_id'])
                if queries[d['document_id'] + '-scope']['text'] == q['text']:
                    matched += 1
        self.assertEqual({(True, False), (False, True), (True, True), (False, False)}, scope_kinds)
        self.assertEqual(16, len(cross))
        self.assertEqual({lang: 4 for lang in ('cs', 'sk', 'en', 'de')},
                         {lang: sum(q['language'] == lang for q in cross) for lang in ('cs', 'sk', 'en', 'de')})
        self.assertGreaterEqual(matched, 4)
        self.assertEqual('Za jak dlouho se má ozvat servis chlazení observatoře?', queries['cs-01-paraphrase']['text'])
        self.assertEqual({'kind': 'all'}, queries['cs-01-paraphrase']['scope'])
        self.assertEqual({'kind': 'selection', 'sourceIds': [], 'folderIds': [10]}, queries['cs-01-scope']['scope'])
        self.assertEqual([503], queries['mix-03-scope']['scope']['sourceIds'])

    def test_overlap_repeated_occurrence_and_overview_order(self):
        m, qs = assets()
        by_id = {d['document_id']: d for d in m['documents']}
        overlap = set()
        for q in qs['queries']:
            for gold in q['gold']:
                d = by_id[gold['document_id']]
                text = (BASE / d['path']).read_bytes().decode(d['encoding'])
                starts = [i for i in range(len(text)) if text.startswith(gold['phrase'], i)]
                start = starts[gold['occurrence'] - 1]
                end = start + len(gold['phrase'])
                if 'overlap' in q['tags']:
                    self.assertTrue(any(a <= start < end <= a + 256 for a in range(1792, len(text), 1792)))
                    overlap.add((gold['document_id'], start, end))
                if q['query_id'] == 'cs-03-paraphrase':
                    self.assertEqual(2, gold['occurrence'])
                    self.assertEqual(2, len(starts))
                    self.assertTrue(gold['phrase'].endswith('.'))
                    self.assertIn('repeated_phrase', q['tags'])
                if q['case_type'] == 'overview':
                    self.assertLessEqual(end, 2048)
            if q['case_type'] == 'overview':
                docs = [d for d in m['documents'] if selected(d, q)]
                buckets = {}
                for d in docs:
                    key = (d['folder_id'] if d['folder_id'] is not None else -1,
                           d['rel_path'].rsplit('/', 1)[0] if '/' in d['rel_path'] else '')
                    buckets.setdefault(key, []).append(d)
                rows = [sorted(buckets[k], key=lambda d: (d['rel_path'], d['source_id'])) for k in sorted(buckets)]
                wanted = [row[i]['document_id'] for i in range(max(map(len, rows))) for row in rows if i < len(row)]
                self.assertEqual(10, len(wanted))
                self.assertEqual(wanted, q['overview_document_ids'])
                self.assertEqual(wanted, [g['document_id'] for g in q['gold']])
        self.assertGreaterEqual(len(overlap), 8)

    def test_hash_check_is_read_only_and_repeatable(self):
        before = [(BASE / p).read_bytes() for p in ('manifest.json', 'queries.json')]
        for _ in range(2):
            result = subprocess.run([sys.executable, str(ROOT / 'tools/eval/update_eval_hashes.py'), '--check'],
                                    capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual('44 documents, 144 queries; corpus hashes current\n', result.stdout)
            self.assertEqual(before, [(BASE / p).read_bytes() for p in ('manifest.json', 'queries.json')])

    def test_hash_writer_rejects_unknown_gold(self):
        from update_eval_hashes import updated_files
        m, q = assets()
        # Keep the test small; failure must never discard the offending gold.
        m['documents'] = m['documents'][:1]
        q['queries'] = q['queries'][:1]
        q['queries'][0]['gold'][0]['document_id'] = 'missing-document'
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            d = m['documents'][0]
            (base / d['path']).parent.mkdir(parents=True)
            (base / d['path']).write_bytes((BASE / d['path']).read_bytes())
            (base / 'manifest.json').write_text(json.dumps(m))
            (base / 'queries.json').write_text(json.dumps(q))
            with self.assertRaisesRegex(ValueError, 'unknown gold document'):
                updated_files(base)

if __name__ == '__main__':
    unittest.main()
