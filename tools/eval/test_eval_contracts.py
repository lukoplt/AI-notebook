"""Independent checks for the shared WP1 forward contracts."""

import json
import copy
from contextlib import redirect_stderr, redirect_stdout
from fractions import Fraction
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / 'Tests/fixtures/contracts'
COUNTS = {'eval-assets': 27, 'eval-retrieval': 12, 'eval-report': 2, 'eval-cli': 6}
METRICS = ['lexical_recall_at_top_k', 'lexical_recall_at_fetch_k',
           'hybrid_recall_at_top_k', 'candidate_recall_at_fetch_k', 'packed_evidence_recall']


def walk(cases):
    for case in cases:
        yield case
        yield from walk(case.get('subcases', []))


def occurrence_span(text, phrase, occurrence):
    if not phrase or occurrence < 1:
        raise ValueError('invalid_gold')
    starts = [i for i in range(len(text)) if text.startswith(phrase, i)]
    if occurrence > len(starts):
        raise ValueError('occurrence_not_found')
    start = starts[occurrence - 1]
    return {'start': start, 'end': start + len(phrase)}


def recall(gold, evidence):
    found = sum(any(e['document_id'] == g['document_id']
                    and e['content_hash'] == g['content_hash']
                    and e['start'] <= g['start'] and e['end'] >= g['end']
                    for e in evidence) for g in gold)
    total = len(gold)
    return dict(status='measured' if total else 'not_applicable', found=found,
                total=total, recall_bp=10000 * found // total if total else None)


def unavailable():
    return dict(status='not_available', found=None, total=None, recall_bp=None)


def metric_reference(i):
    return dict(zip(METRICS, [
        recall(i['gold'], i['lexical'][:i['top_k']]),
        recall(i['gold'], i['lexical']),
        recall(i['gold'], i['fused'][:i['top_k']]) if i['include_vectors'] else unavailable(),
        recall(i['gold'], i['fused']),
        unavailable() if i['packed'] is None else recall(i['gold'], i['packed']),
    ]))


def aggregate(metrics):
    measured = [m for m in metrics if m['status'] == 'measured']
    found, total = sum(m['found'] for m in measured), sum(m['total'] for m in measured)
    if total:
        return dict(status='measured', found=found, total=total, recall_bp=10000 * found // total)
    return unavailable() if any(m['status'] == 'not_available' for m in metrics) else recall([], [])


def retrieval_reference(i):
    """Independent arithmetic for these single-token, integer-vector cases.

    This is not an FTS tokenizer: assert the narrow fixture inputs so a new
    language/tokenization case cannot silently pass a simplified oracle.
    """
    query = i['query']
    assert query == '' or query.isascii() and query.isalpha() and query == query.lower()
    all_chunks, eligible = [], []
    for d in i['documents']:
        for ordinal, chunk in enumerate(d['chunks']):
            tokens = chunk['text'].split()
            assert all(t.isascii() and t.isalpha() and t == t.lower() for t in tokens)
            item = dict(document_id=d['document_id'], ordinal=ordinal,
                        order=len(all_chunks), tokens=tokens, vector=chunk['vector'])
            all_chunks.append(item)
            scope = i['scope']
            if d['notebook_id'] == i['notebook_id'] and (scope['kind'] == 'all'
                    or d['source_id'] in scope['sourceIds'] or d['folder_id'] in scope['folderIds']):
                eligible.append(item)
    average = Fraction(sum(len(c['tokens']) for c in all_chunks), len(all_chunks))
    # For one term, the positive IDF factor is common to all rows. The
    # remaining BM25 length/frequency ordering uses exact rational arithmetic.
    def lexical_key(c):
        frequency = c['tokens'].count(query)
        value = Fraction(frequency) / (frequency + Fraction(3, 10)
                                      + Fraction(9, 10) * len(c['tokens']) / average)
        return -value, c['order']
    lexical = sorted([c for c in eligible if query in c['tokens']], key=lexical_key)[:i['fetch_k']]
    def vector_key(c):
        dot = sum(a * b for a, b in zip(c['vector'], i['query_vector']))
        norm = sum(a * a for a in c['vector'])
        # Query norm is constant. Squared cosine plus its sign preserves order.
        sign = (dot > 0) - (dot < 0)
        value = Fraction(dot * dot, norm) * sign
        return -sign, -value, c['order']
    vector = sorted(eligible, key=vector_key)[:i['fetch_k']] if i['include_vectors'] else []
    scores = {}
    for branch in (lexical, vector):
        for rank, item in enumerate(branch, 1):
            scores[item['order']] = scores.get(item['order'], 0) + 1000000 // (i['rrf_k'] + rank)
    fused = [all_chunks[index] for index in sorted(scores, key=lambda n: (-scores[n], n))]
    def identities(items):
        return [{key: c[key] for key in ('document_id', 'ordinal')} for c in items]
    return dict(lexical=identities(lexical), vector=identities(vector), fused=identities(fused),
                embedding_calls=int(i['include_vectors'] and bool(eligible)))


def markdown_reference(r):
    def cell(value):
        return '—' if value is None else str(value)
    def escape(value):
        return value.replace('\\', '\\\\').replace('|', '\\|').replace('\r', ' ').replace('\n', ' ')
    lines = [
        '# Multilingual retrieval eval v1', '',
        f"Corpus: {r['corpus_id']} ({r['documents']} documents, {r['queries_total']} queries)",
        f"Backend: {r['retrieval_version']}; chunker: {r['chunker_version']}; mode: {r['mode']}",
        f"topK: {r['top_k']}; fetchK per branch: {r['fetch_k']}",
        'Recall aggregation: micro (pooled gold evidence items).', '',
        '| metric | found | total | recall bp | status |',
        '|---|---:|---:|---:|---|',
    ]
    for name in METRICS:
        m = r['metrics'][name]
        lines.append('| ' + ' | '.join([name, cell(m['found']), cell(m['total']),
                                       cell(m['recall_bp']), m['status']]) + ' |')
    lines += ['', '| query | text | status | lexical bp | hybrid bp | candidate bp | packed bp |',
              '|---|---|---|---:|---:|---:|---:|']
    for q in r['queries']:
        values = [escape(q['query_id']), escape(q['text']), escape(q['status'])]
        values += [cell(q['metrics'][name]['recall_bp']) for name in
                   (METRICS[0], METRICS[2], METRICS[3], METRICS[4])]
        lines.append('| ' + ' | '.join(values) + ' |')
    lines += ['', 'Candidate recall uses the full union of the per-branch fetchK lists.',
              'Unavailable packing/overview measurements are not scores; WP8 supplies those adapters.']
    return '\n'.join(lines) + '\n'


def fixture(name):
    return json.loads((CONTRACTS / (name + '-v1.json')).read_bytes())


class EvalContractsTests(unittest.TestCase):
    def test_contract_envelopes_and_counts(self):
        for name, count in COUNTS.items():
            with self.subTest(contract=name):
                value = fixture(name)
                self.assertEqual(name, value['contract'])
                self.assertEqual(1, value['version'])
                self.assertEqual(count, len(value['cases']))
                self.assertEqual(count, len({c['name'] for c in value['cases']}))
                names = [c['name'] for c in walk(value['cases'])]
                self.assertEqual(len(names), len(set(names)))
                raw = (CONTRACTS / (name + '-v1.json')).read_bytes()
                canonical = (json.dumps(value, ensure_ascii=False, sort_keys=True,
                                        indent=2, allow_nan=False) + '\n').encode('utf-8')
                self.assertEqual(canonical, raw)
                self.assertNotIn(b'\r', raw)
                self.assertFalse(raw.startswith(b'\xef\xbb\xbf'))

    def test_valid_assets_resolve_exact_bytes_and_scalar_spans(self):
        checked = 0
        for case in walk(fixture('eval-assets')['cases']):
            self.assertTrue({'name', 'manifest', 'queries', 'files', 'expected'} <= set(case))
            if case['expected']['error'] is not None:
                continue  # Core validators, not a third Python validator, own errors.
            with self.subTest(case=case['name']):
                manifest = json.loads(case['manifest_json']) if 'manifest_json' in case else case['manifest']
                queries = json.loads(case['queries_json']) if 'queries_json' in case else case['queries']
                by_id, resolved = {}, []
                for d in manifest['documents']:
                    raw = bytes(case['files'][d['path']])
                    text = raw.decode(d['encoding'], errors='strict')
                    self.assertEqual(hashlib.sha256(raw).hexdigest(), d['raw_sha256'])
                    self.assertEqual(hashlib.sha256(text.encode('utf-8')).hexdigest(), d['content_hash'])
                    by_id[d['document_id']] = (d, text)
                for q in queries['queries']:
                    for g in q['gold']:
                        d, text = by_id[g['document_id']]
                        self.assertEqual(d['content_hash'], g['content_hash'])
                        self.assertEqual(d['notebook_id'], q['notebook_id'])
                        scope = q['scope']
                        self.assertTrue(scope['kind'] == 'all' or d['source_id'] in scope['sourceIds']
                                        or d['folder_id'] in scope['folderIds'])
                        resolved.append(dict(query_id=q['query_id'], document_id=d['document_id'],
                                             content_hash=g['content_hash'],
                                             **occurrence_span(text, g['phrase'], g['occurrence'])))
                self.assertEqual(case['expected']['spans'], resolved)
                checked += 1
        self.assertGreaterEqual(checked, 8)  # seven primary successes and BOM preservation

    def test_authored_primary_errors_are_frozen(self):
        wanted = {
            'utf8': None, 'second-occurrence': None, 'overlapping-occurrence': None,
            'astral-prefix': None, 'exact-whitespace': 'occurrence_not_found',
            'no-normalization': 'occurrence_not_found', 'cp1250': None,
            'bad-utf8': 'invalid_encoding', 'bad-cp1250': 'invalid_encoding',
            'unsupported-encoding': 'invalid_encoding', 'missing-document': 'unknown_document',
            'duplicate-document': 'duplicate_document', 'duplicate-source': 'duplicate_source',
            'duplicate-query': 'duplicate_query', 'raw-hash': 'raw_hash_mismatch',
            'content-hash': 'content_hash_mismatch', 'gold-hash': 'gold_hash_mismatch',
            'hash-syntax': 'invalid_hash', 'empty-phrase': 'invalid_gold',
            'zero-occurrence': 'invalid_gold', 'large-occurrence': 'occurrence_not_found',
            'out-of-scope': 'gold_out_of_scope', 'other-notebook': 'gold_out_of_scope',
            'empty-selection': None, 'duplicate-relative-path': None,
            'bad-path': 'invalid_path', 'absent-with-gold': 'invalid_query',
        }
        self.assertEqual(wanted, {c['name']: c['expected']['error'] for c in fixture('eval-assets')['cases']})
        for c in walk(fixture('eval-assets')['cases']):
            if c['expected']['error'] is not None:
                self.assertEqual([], c['expected']['spans'], c['name'])

    def test_shared_scalar_windows(self):
        cases = fixture('eval-assets')['window_cases']
        self.assertEqual(3, len(cases))
        self.assertEqual(3, len({c['name'] for c in cases}))
        for c in cases:
            i, e = c['input'], c['expected']
            if e['error'] is not None:
                self.assertEqual('invalid_window', e['error'])
                self.assertEqual((4, 4), (i['size'], i['overlap']))
                continue
            result, start = [], 0
            while start < len(i['text']):
                end = min(start + i['size'], len(i['text']))
                result.append(dict(start=start, end=end, text=i['text'][start:end]))
                if end == len(i['text']):
                    break
                start = end - i['overlap']
            self.assertEqual(e['windows'], result, c['name'])

    def test_every_retrieval_and_metric_case_has_independent_arithmetic(self):
        seen, errors = set(), set()
        for c in walk(fixture('eval-retrieval')['cases']):
            self.assertNotIn(c['name'], seen)
            seen.add(c['name'])
            with self.subTest(case=c['name']):
                if c['expected'].get('error'):
                    errors.add(c['expected']['error'])
                    continue
                if c['kind'] == 'metrics':
                    self.assertEqual(set(METRICS), set(c['expected']))
                    self.assertEqual(c['expected'], metric_reference(c['input']))
                else:
                    self.assertEqual('retrieval', c['kind'])
                    self.assertEqual(c['expected'], retrieval_reference(c['input']))
        self.assertTrue({'invalid_fetch_k', 'invalid_embedding'} <= errors)
        self.assertGreater(len(seen), 12)

    def test_report_totals_groups_nulls_and_markdown(self):
        for c in fixture('eval-report')['cases']:
            r = c['expected_json']
            self.assertEqual(r, c['input'])
            self.assertEqual(1, r['schema_version'])
            self.assertEqual(len(r['queries']), r['queries_total'])
            self.assertEqual('legacy-fts-eval-rrf-v1', r['retrieval_version'])
            self.assertEqual('eval-scalars-v1', r['chunker_version'])
            self.assertEqual({'warm_retrieval_ms': None, 'end_to_end_ms': None, 'cold_cache_ms': None}, r['timing'])
            self.assertTrue(any(all(char in q['text'] for char in ('|', '\n', 'é')) for q in r['queries']))
            for metric in METRICS:
                self.assertEqual(r['metrics'][metric], aggregate([q['metrics'][metric] for q in r['queries']]))
            for group, field in [('by_language', 'language'), ('by_case_type', 'case_type')]:
                self.assertEqual({q[field] for q in r['queries']}, set(r[group]))
                for label, metrics in r[group].items():
                    for metric in METRICS:
                        self.assertEqual(metrics[metric], aggregate([q['metrics'][metric] for q in r['queries'] if q[field] == label]))
                for metric in METRICS:
                    if r['metrics'][metric]['status'] == 'measured':
                        for number in ('found', 'total'):
                            self.assertEqual(r['metrics'][metric][number],
                                             sum(ms[metric][number] or 0 for ms in r[group].values()))
            for case_type, count in [('overview', 'overview_queries'), ('absent', 'absent_queries'),
                                     ('empty_selection', 'empty_selection_queries')]:
                self.assertEqual(sum(q['case_type'] == case_type for q in r['queries']), r[count])
            for q in r['queries']:
                if q['case_type'] == 'overview':
                    self.assertEqual('deferred_overview_wp8', q['status'])
                    self.assertTrue(all(m == recall([], []) for m in q['metrics'].values()))
                if q['case_type'] in ('absent', 'empty_selection', 'overview'):
                    self.assertTrue(all(m['total'] in (0, None) for m in q['metrics'].values()))
            self.assertEqual(c['expected_markdown'], markdown_reference(r))

    def test_generator_check_is_read_only_and_deterministic(self):
        paths = [CONTRACTS / (name + '-v1.json') for name in COUNTS]
        paths += [ROOT / 'eval/multilingual' / name for name in ('manifest.json', 'queries.json')]
        before = [path.read_bytes() for path in paths]
        for _ in range(2):
            result = subprocess.run([sys.executable, str(ROOT / 'tools/eval/gen_eval_fixtures.py'), '--check'],
                                    capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn('44 documents, 144 queries; eval fixtures current', result.stdout)
            self.assertEqual(before, [path.read_bytes() for path in paths])

    def test_default_generator_check_rejects_drift_without_writing(self):
        import gen_eval_fixtures
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name in COUNTS:
                filename = name + '-v1.json'
                (directory / filename).write_bytes((CONTRACTS / filename).read_bytes())
            stale = directory / 'eval-report-v1.json'
            stale.write_bytes(stale.read_bytes() + b' ')
            before = {p.name: p.read_bytes() for p in directory.iterdir()}
            with patch.object(gen_eval_fixtures, 'CONTRACTS', directory), \
                    patch.object(sys, 'argv', ['gen_eval_fixtures.py']), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(1, gen_eval_fixtures.main())
            self.assertIn('eval-report-v1.json', errors.getvalue())
            self.assertEqual(before, {p.name: p.read_bytes() for p in directory.iterdir()})

    def test_required_adversarial_subcases_remain_present(self):
        cases = {c['name']: c for c in fixture('eval-assets')['cases']}
        self.assertTrue({'bom-preserved'} <= {c['name'] for c in cases['utf8']['subcases']})
        self.assertTrue({'negative-occurrence'} <= {c['name'] for c in cases['zero-occurrence']['subcases']})
        paths = cases['bad-path']['subcases']
        for field in ('path', 'rel_path'):
            actual = {c['manifest']['documents'][0][field] for c in paths}
            self.assertTrue({'/absolute', 'C:/absolute', 'documents\\a.txt', 'documents//a.txt',
                             'documents/./a.txt', 'documents/../a.txt', ''} <= actual)
        required = {
            'answer-without-gold', 'search-with-overview-ids', 'unknown-scope-kind',
            'invalid-document-language', 'invalid-query-language', 'unknown-source-selection',
            'unknown-folder-selection', 'unknown-query-notebook', 'empty-manifest', 'empty-query-array',
            'mismatched-corpus-ids', 'folder-spans-notebooks', 'answer-with-absent-reason',
            'absent-missing-reason', 'absent-invalid-reason', 'absent-wrong-reason',
            'empty-selection-wrong-reason', 'empty-selection-selects-document',
            'overview-outside-selection', 'overview-missing-gold-coverage', 'overview-extra-gold-coverage',
            'query-unpaired-high-surrogate', 'query-unpaired-low-surrogate', 'manifest-unpaired-surrogate',
            'duplicate-gold-tuple',
        }
        subs = {c['name']: c for c in cases['absent-with-gold']['subcases']}
        self.assertTrue(required <= set(subs))
        for name in required:
            self.assertEqual('invalid_gold' if name == 'duplicate-gold-tuple' else 'invalid_query',
                             subs[name]['expected']['error'])
        for prefix in ('corpus', 'document', 'query'):
            self.assertTrue({prefix + '-id-non-ascii', prefix + '-id-empty'} <= set(subs))
        for prefix in ('manifest', 'queries'):
            self.assertTrue({prefix + '-wrong-contract', prefix + '-wrong-version',
                             prefix + '-malformed-json'} <= set(subs))

    def test_raw_invalid_json_tokens_are_preserved(self):
        kinds = set()
        def strings(value):
            if isinstance(value, str):
                yield value
            elif isinstance(value, list):
                for item in value:
                    yield from strings(item)
            elif isinstance(value, dict):
                for key, item in value.items():
                    yield key
                    yield from strings(item)
        for c in walk(fixture('eval-assets')['cases']):
            for key in ('manifest_json', 'queries_json'):
                if key not in c:
                    continue
                raw = c[key]
                self.assertIsInstance(raw, str)
                self.assertEqual('invalid_query', c['expected']['error'])
                tokens = []
                def number(token):
                    tokens.append(token)
                    return token
                try:
                    decoded = json.loads(raw, parse_int=number, parse_float=number)
                except json.JSONDecodeError:
                    kinds.add('malformed')
                    continue
                if any('e' in n.lower() for n in tokens):
                    kinds.add('exponent')
                if any('.' in n for n in tokens):
                    kinds.add('fraction')
                if any(n == '9007199254740992' for n in tokens):
                    kinds.add('large')
                if any(n in ('0', '-1') for n in tokens):
                    kinds.add('nonpositive')
                if any(any(0xD800 <= ord(char) <= 0xDFFF for char in text) for text in strings(decoded)):
                    kinds.add('surrogate')
                    self.assertTrue('\\ud' in raw.lower())
        self.assertEqual({'malformed', 'exponent', 'fraction', 'large', 'nonpositive', 'surrogate'}, kinds)

    def test_cli_cases_freeze_all_options_and_prefixed_host(self):
        keys = {'root', 'mode', 'model', 'host', 'top_k', 'fetch_k', 'json_path',
                'markdown_path', 'validate_only'}
        seen_flags, has_prefix, negative = set(), False, 0
        cases = list(walk(fixture('eval-cli')['cases']))
        for c in cases:
            expected, args = c['expected'], c['args']
            self.assertTrue(all(isinstance(arg, str) for arg in args))
            if expected.get('error'):
                self.assertEqual({'error': 'usage'}, expected)
                negative += 1
                continue
            self.assertEqual(keys, set(expected))
            self.assertTrue(expected['fetch_k'] >= expected['top_k'] > 0)
            self.assertIn(expected['mode'], ('lexical', 'ollama'))
            self.assertIsNone(expected['model']) if expected['mode'] == 'lexical' else self.assertTrue(expected['model'])
            # Check the authored successful arguments, without constructing a
            # third URL validator or deciding expected failures from a parser.
            values, index = {}, 0
            while index < len(args):
                flag = args[index]
                self.assertNotIn(flag, values)
                if flag == '--validate-only':
                    values[flag] = True
                    index += 1
                else:
                    values[flag] = args[index + 1]
                    index += 2
            seen_flags.update(values)
            self.assertEqual('multilingual', values['--dataset'])
            self.assertEqual(values.get('--root', 'eval/multilingual'), expected['root'])
            self.assertEqual(values.get('--mode', 'lexical'), expected['mode'])
            self.assertEqual(values.get('--model'), expected['model'])
            self.assertEqual(values.get('--json'), expected['json_path'])
            self.assertEqual(values.get('--out'), expected['markdown_path'])
            self.assertEqual(values.get('--validate-only', False), expected['validate_only'])
            self.assertEqual(int(values.get('--top-k', '16')), expected['top_k'])
            self.assertEqual(int(values.get('--fetch-k', '32')), expected['fetch_k'])
            self.assertEqual(values.get('--host', 'http://127.0.0.1:11434').strip().rstrip('/'), expected['host'])
            has_prefix |= expected['host'] == 'https://localhost/ollama'
        self.assertTrue(has_prefix)
        self.assertGreater(negative, 10)
        self.assertTrue({'--dataset', '--root', '--mode', '--model', '--host', '--top-k',
                         '--fetch-k', '--json', '--out', '--validate-only'} <= seen_flags)

    def test_overlapping_occurrence_is_second_start(self):
        case = next(c for c in fixture('eval-assets')['cases'] if c['name'] == 'overlapping-occurrence')
        self.assertIsNone(case['expected']['error'])
        self.assertEqual([(2, 5)], [(s['start'], s['end']) for s in case['expected']['spans']])

    def test_report_gold_has_micro_denominator(self):
        case = next(c for c in fixture('eval-report')['cases'] if c['name'] == 'measured')
        metric = case['expected_json']['metrics']['candidate_recall_at_fetch_k']
        self.assertEqual(('measured', 1, 2, 5000),
                         tuple(metric[k] for k in ('status', 'found', 'total', 'recall_bp')))

    def test_comparator_preserves_denominators_and_structure(self):
        from compare_reports import first_difference
        left = {'platform': 'macos', 'metrics': {'recall': {'found': 1, 'total': 2}},
                'queries': [{'fused': ['a', 'b'], 'metric': None}]}
        right = copy.deepcopy(left)
        right['platform'] = 'windows'
        self.assertEqual('$["platform"]', first_difference(left, right))
        self.assertIsNone(first_difference(left, right, ignore_platform=True))
        right['metrics']['recall']['total'] = 3
        self.assertEqual('$["metrics"]["recall"]["total"]',
                         first_difference(left, right, ignore_platform=True))
        right['metrics']['recall']['total'] = 2
        right['queries'][0]['fused'].reverse()
        self.assertEqual('$["queries"][0]["fused"][0]',
                         first_difference(left, right, ignore_platform=True))
        right = copy.deepcopy(left)
        del right['queries'][0]['metric']
        self.assertEqual('$["queries"][0]["metric"]', first_difference(left, right))
        self.assertEqual('$["queries"]', first_difference({'queries': []}, {'queries': [{}]}))
        self.assertEqual('$["nested"]["platform"]', first_difference(
            {'nested': {'platform': 'macos'}}, {'nested': {'platform': 'windows'}}, ignore_platform=True))
        self.assertEqual('$', first_difference(True, 1))

    def test_comparator_cli_rejects_denominator_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            left, right = Path(tmp) / 'mac.json', Path(tmp) / 'win.json'
            left.write_text('{"platform":"macos","metrics":{"recall":{"found":1,"total":2}}}')
            right.write_text('{"platform":"windows","metrics":{"recall":{"found":1,"total":3}}}')
            result = subprocess.run([sys.executable, str(ROOT / 'tools/eval/compare_reports.py'),
                                     str(left), str(right), '--ignore-platform'], capture_output=True, text=True)
            self.assertEqual(1, result.returncode)
            self.assertIn('$["metrics"]["recall"]["total"]', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
