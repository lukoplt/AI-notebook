#!/usr/bin/env python3
"""Freeze WP1 forward contracts; default/check mode never changes any asset.

Expected failures, spans, branch orders, metric counts and report bytes below
are authored gold. SHA-256 values alone are calculated from literal bytes.
Retrieval mocks normally return [query_vector]; query_vectors, when present,
is the complete returned batch for missing/extra-vector validation subcases.
The string sentinel "nan" is decoded only by a mock, never as JSON NaN.
"""

import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / 'Tests/fixtures/contracts'
METRIC_NAMES = (
    'lexical_recall_at_top_k', 'lexical_recall_at_fetch_k',
    'hybrid_recall_at_top_k', 'candidate_recall_at_fetch_k',
    'packed_evidence_recall',
)


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, indent=2,
                       allow_nan=False) + '\n').encode('utf-8')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def document(raw=b'abc\n', text='abc\n', document_id='d1', source_id=1,
             notebook_id=1, folder_id=10, path='documents/a.txt',
             rel_path='a.txt', encoding='utf-8'):
    return dict(document_id=document_id, source_id=source_id,
                notebook_id=notebook_id, folder_id=folder_id, path=path,
                rel_path=rel_path, language='en', encoding=encoding,
                raw_sha256=sha(raw), content_hash=sha(text.encode('utf-8')))


def asset_case(name, raw=b'abc\n', text='abc\n', phrase='abc', occurrence=1,
               start=0, end=3, encoding='utf-8', error=None):
    d = document(raw, text, encoding=encoding)
    q = dict(query_id='q1', text='Where is the recorded value?', language='en',
             case_type='answer', tags=[], notebook_id=1, scope={'kind': 'all'},
             gold=[dict(document_id='d1', content_hash=d['content_hash'],
                        phrase=phrase, occurrence=occurrence)],
             absent_reason=None, overview_document_ids=[])
    spans = [] if error else [dict(query_id='q1', document_id='d1',
                                   content_hash=d['content_hash'], start=start, end=end)]
    return dict(name=name,
                manifest=dict(contract='eval-corpus', version=1,
                              corpus_id='fixture-corpus-v1', license='MIT', documents=[d]),
                queries=dict(contract='eval-queries', version=1,
                             corpus_id='fixture-corpus-v1', queries=[q]),
                files={d['path']: list(raw)}, expected=dict(error=error, spans=spans))


def first_doc(case):
    return case['manifest']['documents'][0]


def first_query(case):
    return case['queries']['queries'][0]


def first_gold(case):
    return first_query(case)['gold'][0]


def invalid_asset(name, error, change):
    case = asset_case(name, error=error)
    change(case)
    return case


def second_doc(case, notebook_id=1, folder_id=20, document_id='d2', source_id=2):
    d = document(document_id=document_id, source_id=source_id,
                 notebook_id=notebook_id, folder_id=folder_id,
                 path='documents/b.txt', rel_path='a.txt')
    case['manifest']['documents'].append(d)
    case['files'][d['path']] = list(b'abc\n')
    return d


def absent_query(case):
    q = first_query(case)
    q.update(case_type='absent', gold=[], absent_reason='not_in_corpus')
    return q


def build_assets():
    cases = []
    utf8 = asset_case('utf8')
    utf8['subcases'] = [asset_case('bom-preserved', raw=b'\xef\xbb\xbfa', text='\ufeffa',
                                  phrase='a', start=1, end=2)]
    cases.append(utf8)
    cases.append(asset_case('second-occurrence', b'abc abc\n', 'abc abc\n', occurrence=2, start=4, end=7))
    cases.append(asset_case('overlapping-occurrence', b'ababa', 'ababa', 'aba', 2, 2, 5))
    cases.append(asset_case('astral-prefix', '😀 abc'.encode('utf-8'), '😀 abc', start=2, end=5))
    cases.append(asset_case('exact-whitespace', b'a  b', 'a  b', 'a b', error='occurrence_not_found'))
    cases.append(asset_case('no-normalization', 'e\u0301'.encode('utf-8'), 'e\u0301', 'é', error='occurrence_not_found'))
    cases.append(asset_case('cp1250', 'Příliš'.encode('cp1250'), 'Příliš', 'Příliš', end=6, encoding='windows-1250'))
    cases.append(asset_case('bad-utf8', bytes([195, 40]), '', error='invalid_encoding'))
    cases.append(asset_case('bad-cp1250', bytes([129]), '', encoding='windows-1250', error='invalid_encoding'))
    cases.append(asset_case('unsupported-encoding', encoding='latin1', error='invalid_encoding'))
    cases.append(invalid_asset('missing-document', 'unknown_document',
                               lambda c: first_gold(c).update(document_id='missing')))
    cases.append(invalid_asset('duplicate-document', 'duplicate_document',
                               lambda c: second_doc(c, document_id='d1')))
    cases.append(invalid_asset('duplicate-source', 'duplicate_source',
                               lambda c: second_doc(c, source_id=1)))
    cases.append(invalid_asset('duplicate-query', 'duplicate_query',
                               lambda c: c['queries']['queries'].append(deepcopy(first_query(c)))))
    cases.append(invalid_asset('raw-hash', 'raw_hash_mismatch',
                               lambda c: first_doc(c).update(raw_sha256='0' * 64)))
    cases.append(invalid_asset('content-hash', 'content_hash_mismatch',
                               lambda c: first_doc(c).update(content_hash='0' * 64)))
    cases.append(invalid_asset('gold-hash', 'gold_hash_mismatch',
                               lambda c: first_gold(c).update(content_hash='0' * 64)))
    syntax = invalid_asset('hash-syntax', 'invalid_hash',
                            lambda c: first_doc(c).update(raw_sha256='A' * 64))
    syntax['subcases'] = []
    for target, field in [('raw', 'raw_sha256'), ('content', 'content_hash'), ('gold', 'content_hash')]:
        for label, value in [('uppercase', 'A' * 64), ('nonhex', 'g' * 64), ('short', 'a' * 63)]:
            def change(c, target=target, field=field, value=value):
                (first_gold(c) if target == 'gold' else first_doc(c))[field] = value
            syntax['subcases'].append(invalid_asset('hash-' + target + '-' + label, 'invalid_hash', change))
    cases.append(syntax)
    cases.append(invalid_asset('empty-phrase', 'invalid_gold', lambda c: first_gold(c).update(phrase='')))
    zero = invalid_asset('zero-occurrence', 'invalid_gold', lambda c: first_gold(c).update(occurrence=0))
    zero['subcases'] = [invalid_asset('negative-occurrence', 'invalid_gold',
                                      lambda c: first_gold(c).update(occurrence=-1))]
    cases.append(zero)
    cases.append(invalid_asset('large-occurrence', 'occurrence_not_found', lambda c: first_gold(c).update(occurrence=99)))

    def out_of_scope(c):
        second_doc(c)
        first_query(c)['scope'] = dict(kind='selection', sourceIds=[], folderIds=[20])
    cases.append(invalid_asset('out-of-scope', 'gold_out_of_scope', out_of_scope))

    def other_notebook(c):
        d = second_doc(c, notebook_id=2)
        first_gold(c).update(document_id=d['document_id'], content_hash=d['content_hash'])
    cases.append(invalid_asset('other-notebook', 'gold_out_of_scope', other_notebook))

    empty = asset_case('empty-selection')
    first_query(empty).update(case_type='empty_selection', gold=[], absent_reason='empty_scope',
                              scope=dict(kind='selection', sourceIds=[], folderIds=[]))
    empty['expected']['spans'] = []
    cases.append(empty)

    duplicate_path = asset_case('duplicate-relative-path')
    d = second_doc(duplicate_path)
    first_query(duplicate_path)['scope'] = dict(kind='selection', sourceIds=[], folderIds=[20])
    first_gold(duplicate_path).update(document_id='d2', content_hash=d['content_hash'])
    duplicate_path['expected']['spans'] = [dict(query_id='q1', document_id='d2',
                                              content_hash=d['content_hash'], start=0, end=3)]
    cases.append(duplicate_path)

    bad_path = invalid_asset('bad-path', 'invalid_path', lambda c: first_doc(c).update(path='../outside.txt'))
    bad_path['subcases'] = []
    path_values = [('absolute', '/absolute'), ('drive', 'C:/absolute'),
                   ('backslash', 'documents\\a.txt'), ('empty-component', 'documents//a.txt'),
                   ('dot-component', 'documents/./a.txt'), ('dotdot-component', 'documents/../a.txt')]
    for label, value in path_values:
        bad_path['subcases'].append(invalid_asset('path-' + label, 'invalid_path',
                                                  lambda c, value=value: first_doc(c).update(path=value)))
        bad_path['subcases'].append(invalid_asset('relative-path-' + label, 'invalid_path',
                                                  lambda c, value=value: first_doc(c).update(rel_path=value)))
    bad_path['subcases'].append(invalid_asset('path-empty', 'invalid_path', lambda c: first_doc(c).update(path='')))
    bad_path['subcases'].append(invalid_asset('relative-path-empty', 'invalid_path', lambda c: first_doc(c).update(rel_path='')))
    bad_path['subcases'].append(invalid_asset('same-folder-relative-path', 'invalid_path', lambda c: second_doc(c, folder_id=10)))
    bad_path['subcases'].append(invalid_asset('missing-file', 'missing_file', lambda c: c['files'].clear()))
    cases.append(bad_path)

    invalid = invalid_asset('absent-with-gold', 'invalid_query',
                             lambda c: first_query(c).update(case_type='absent', absent_reason='not_in_corpus'))
    subs = invalid['subcases'] = []

    def add(name, change, error='invalid_query'):
        subs.append(invalid_asset(name, error, change))

    add('answer-without-gold', lambda c: first_query(c).update(gold=[]))
    add('search-with-overview-ids', lambda c: first_query(c).update(overview_document_ids=['d1']))
    add('unknown-scope-kind', lambda c: first_query(c).update(scope={'kind': 'unknown'}))
    add('invalid-document-language', lambda c: first_doc(c).update(language='fr'))
    add('invalid-query-language', lambda c: first_query(c).update(language='mixed'))
    add('unknown-source-selection', lambda c: first_query(c).update(scope=dict(kind='selection', sourceIds=[999], folderIds=[])))
    add('unknown-folder-selection', lambda c: first_query(c).update(scope=dict(kind='selection', sourceIds=[], folderIds=[999])))
    add('unknown-query-notebook', lambda c: absent_query(c).update(notebook_id=999))
    add('invalid-case-type', lambda c: first_query(c).update(case_type='mixed'))
    add('empty-question-text', lambda c: first_query(c).update(text=''))
    add('duplicate-gold-tuple', lambda c: first_query(c)['gold'].append(deepcopy(first_gold(c))), error='invalid_gold')

    for target, contract in [('manifest', 'eval-corpus'), ('queries', 'eval-queries')]:
        add(target + '-wrong-contract', lambda c, target=target: c[target].update(contract='wrong-contract'))
        add(target + '-missing-contract', lambda c, target=target: c[target].pop('contract'))
        add(target + '-wrong-version', lambda c, target=target: c[target].update(version=2))
        add(target + '-missing-version', lambda c, target=target: c[target].pop('version'))
        add(target + '-malformed-json', lambda c, target=target: c.update({target + '_json': '{"contract":'}))
        add(target + '-wrong-envelope-type', lambda c, target=target: c.update({target + '_json': '[]'}))
    add('empty-manifest', lambda c: c['manifest'].update(documents=[]))
    add('empty-query-array', lambda c: c['queries'].update(queries=[]))
    add('mismatched-corpus-ids', lambda c: c['queries'].update(corpus_id='another-corpus'))
    add('folder-spans-notebooks', lambda c: second_doc(c, notebook_id=2, folder_id=10))
    add('missing-document-field', lambda c: first_doc(c).pop('source_id'))
    add('missing-question-field', lambda c: first_query(c).pop('scope'))
    add('missing-gold-field', lambda c: first_gold(c).pop('occurrence'))

    for target in ('corpus', 'document', 'query'):
        for label, value in [('non-ascii', 'é'), ('empty', ''), ('uppercase', 'Upper')]:
            def change(c, target=target, value=value):
                if target == 'corpus':
                    c['manifest']['corpus_id'] = value
                    c['queries']['corpus_id'] = value
                elif target == 'document':
                    first_doc(c)['document_id'] = value
                    first_gold(c)['document_id'] = value
                else:
                    first_query(c)['query_id'] = value
            add(target + '-id-' + label, change)

    add('answer-with-absent-reason', lambda c: first_query(c).update(absent_reason='not_in_corpus'))
    add('absent-missing-reason', lambda c: absent_query(c).update(absent_reason=None))
    add('absent-invalid-reason', lambda c: absent_query(c).update(absent_reason='missing'))
    add('absent-wrong-reason', lambda c: absent_query(c).update(absent_reason='empty_scope'))
    add('empty-selection-wrong-reason', lambda c: first_query(c).update(
        case_type='empty_selection', gold=[], absent_reason='not_in_corpus',
        scope=dict(kind='selection', sourceIds=[], folderIds=[])))
    add('empty-selection-selects-document', lambda c: first_query(c).update(
        case_type='empty_selection', gold=[], absent_reason='empty_scope'))
    add('absent-with-overview-ids', lambda c: absent_query(c).update(overview_document_ids=['d1']))

    def overview_outside(c):
        second_doc(c)
        first_query(c).update(case_type='overview', overview_document_ids=['d2'],
                              scope=dict(kind='selection', sourceIds=[], folderIds=[10]))
        first_gold(c)['document_id'] = 'd2'
    add('overview-outside-selection', overview_outside)

    def overview_missing_coverage(c):
        second_doc(c)
        first_query(c).update(case_type='overview', overview_document_ids=['d1', 'd2'])
    add('overview-missing-gold-coverage', overview_missing_coverage)

    def overview_extra_coverage(c):
        second_doc(c)
        first_query(c).update(case_type='overview', overview_document_ids=['d2'])
    add('overview-extra-gold-coverage', overview_extra_coverage)
    add('overview-empty-ids', lambda c: first_query(c).update(case_type='overview'))
    add('overview-duplicate-ids', lambda c: first_query(c).update(case_type='overview', overview_document_ids=['d1', 'd1']))
    add('overview-unknown-id', lambda c: first_query(c).update(case_type='overview', overview_document_ids=['missing']))
    add('overview-with-absent-reason', lambda c: first_query(c).update(
        case_type='overview', overview_document_ids=['d1'], absent_reason='not_in_corpus'))

    # Use literal raw JSON tokens. Parsed objects remain valid fallback inputs,
    # making loss of the raw override visible to the platform harness.
    def raw_field(c, target, address, token):
        obj = deepcopy(c[target])
        node = obj
        for key in address[:-1]:
            node = node[key]
        node[address[-1]] = '__RAW_TOKEN__'
        raw = json.dumps(obj, ensure_ascii=False, sort_keys=True)
        c[target + '_json'] = raw.replace('"__RAW_TOKEN__"', token)

    numeric_fields = [
        ('document-source', 'manifest', ['documents', 0, 'source_id']),
        ('document-notebook', 'manifest', ['documents', 0, 'notebook_id']),
        ('document-folder', 'manifest', ['documents', 0, 'folder_id']),
        ('query-notebook', 'queries', ['queries', 0, 'notebook_id']),
        ('scope-source', 'queries', ['queries', 0, 'scope', 'sourceIds', 0]),
        ('scope-folder', 'queries', ['queries', 0, 'scope', 'folderIds', 0]),
    ]
    for label, target, address in numeric_fields:
        for suffix, token in [('zero', '0'), ('negative', '-1'), ('unsafe-integer', '9007199254740992'),
                              ('fractional', '1.0'), ('exponent', '1e0'), ('boolean', 'true')]:
            def change(c, label=label, target=target, address=address, token=token):
                if label.startswith('scope-'):
                    first_query(c)['scope'] = dict(kind='selection', sourceIds=[1], folderIds=[10])
                raw_field(c, target, address, token)
            add(label + '-' + suffix, change)
    for label, target, address in [
        ('manifest-version', 'manifest', ['version']),
        ('queries-version', 'queries', ['version']),
        ('gold-occurrence', 'queries', ['queries', 0, 'gold', 0, 'occurrence']),
    ]:
        for suffix, token in [('fractional', '1.0'), ('exponent', '1e0'), ('boolean', 'true')]:
            add(label + '-' + suffix,
                lambda c, target=target, address=address, token=token: raw_field(c, target, address, token))
    add('numeric-id-overflow', lambda c: raw_field(c, 'manifest', ['documents', 0, 'source_id'], '1e999'))
    add('query-unpaired-high-surrogate', lambda c: raw_field(c, 'queries', ['queries', 0, 'text'], '"\\ud800"'))
    add('query-unpaired-low-surrogate', lambda c: raw_field(c, 'queries', ['queries', 0, 'text'], '"\\udfff"'))
    add('manifest-unpaired-surrogate', lambda c: raw_field(c, 'manifest', ['documents', 0, 'document_id'], '"\\ud800"'))
    cases.append(invalid)

    windows = [
        dict(name='empty-text', input=dict(text='', size=4, overlap=1), expected=dict(error=None, windows=[])),
        dict(name='scalar-overlap', input=dict(text='😀abcde\u0301f', size=4, overlap=1), expected=dict(error=None, windows=[
            dict(start=0, end=4, text='😀abc'), dict(start=3, end=7, text='cde\u0301'), dict(start=6, end=8, text='\u0301f')])),
        dict(name='invalid-overlap', input=dict(text='😀abcde\u0301f', size=4, overlap=4),
             expected=dict(error='invalid_window', windows=[])),
    ]
    return dict(contract='eval-assets', version=1, cases=cases, window_cases=windows)


def branch_item(document_id, ordinal=0):
    return dict(document_id=document_id, ordinal=ordinal)


def retrieval_document(document_id, source_id, text, vector,
                       notebook_id=1, folder_id=10):
    return dict(document_id=document_id, source_id=source_id,
                notebook_id=notebook_id, folder_id=folder_id,
                chunks=[dict(text=text, vector=vector)])


def retrieval_case(name, documents, lexical, vector, fused,
                   scope=None, notebook_id=1, fetch_k=1, include_vectors=True,
                   embedding_calls=1):
    return dict(name=name, kind='retrieval',
                input=dict(documents=documents, notebook_id=notebook_id,
                           query='fox', query_vector=[1, 0],
                           scope={'kind': 'all'} if scope is None else scope,
                           fetch_k=fetch_k, top_k=1, include_vectors=include_vectors, rrf_k=60),
                expected=dict(lexical=lexical, vector=vector, fused=fused,
                              embedding_calls=embedding_calls))


def metric(status, found, total, recall_bp):
    return dict(status=status, found=found, total=total, recall_bp=recall_bp)


def measured(found, total, recall_bp):
    # The basis-point argument is deliberately authored, not derived here.
    return metric('measured', found, total, recall_bp)


def metric_map(lexical_top, lexical_fetch, hybrid_top, candidates, packed):
    return dict(zip(METRIC_NAMES, deepcopy([lexical_top, lexical_fetch, hybrid_top, candidates, packed])))


def span(document_id, start, end, content_hash='a' * 64):
    return dict(document_id=document_id, content_hash=content_hash, start=start, end=end)


def metrics_case(name, gold, lexical, fused, packed, expected, include_vectors=True, top_k=1):
    return dict(name=name, kind='metrics', input=dict(gold=gold, lexical=lexical,
                fused=fused, top_k=top_k, include_vectors=include_vectors, packed=packed),
                expected=expected)


def build_retrieval():
    first, second = branch_item('d1'), branch_item('d2')
    disjoint = retrieval_case('disjoint-branches', [
        retrieval_document('d1', 1, 'fox on shelf', [0, 1]),
        retrieval_document('d2', 2, 'vector target', [1, 0], folder_id=20),
    ], [first], [second], [first, second])
    disjoint['subcases'] = []

    def invalid(name, error, change, calls):
        c = deepcopy(disjoint)
        c.pop('subcases')
        c['name'] = name
        change(c['input'])
        c['expected'] = dict(error=error, embedding_calls=calls)
        disjoint['subcases'].append(c)

    invalid('zero-fetch-k', 'invalid_fetch_k', lambda i: i.update(fetch_k=0), 0)
    invalid('zero-rrf-k', 'invalid_fetch_k', lambda i: i.update(rrf_k=0), 0)
    invalid('missing-query-vector', 'invalid_embedding', lambda i: i.update(query_vectors=[]), 1)
    invalid('extra-query-vector', 'invalid_embedding', lambda i: i.update(query_vectors=[[1, 0], [1, 0]]), 1)
    invalid('nonfinite-query-vector', 'invalid_embedding', lambda i: i.update(query_vector=['nan', 0]), 1)
    invalid('mismatched-query-dimension', 'invalid_embedding', lambda i: i.update(query_vector=[1, 0, 0]), 1)
    invalid('empty-query-vector', 'invalid_embedding', lambda i: i.update(query_vector=[]), 1)
    invalid('zero-query-vector', 'invalid_embedding', lambda i: i.update(query_vector=[0, 0]), 1)
    invalid('mismatched-stored-dimension', 'invalid_embedding',
            lambda i: i['documents'][0]['chunks'][0].update(vector=[0, 1, 0]), 1)
    invalid('nonfinite-stored-vector', 'invalid_embedding',
            lambda i: i['documents'][0]['chunks'][0].update(vector=[0, 'nan']), 1)
    invalid('zero-stored-vector', 'invalid_embedding',
            lambda i: i['documents'][0]['chunks'][0].update(vector=[0, 0]), 1)

    zero, one = measured(0, 1, 0), measured(1, 1, 10000)
    unavailable = metric('not_available', None, None, None)
    not_applicable = metric('not_applicable', 0, 0, None)
    first_evidence, second_evidence = span('d1', 0, 12), span('d2', 0, 13)
    disjoint['subcases'].append(metrics_case('full-union-recall', [span('d2', 0, 6)],
        [first_evidence], [first_evidence, second_evidence], None,
        metric_map(zero, zero, zero, one, unavailable)))

    cases = [disjoint]
    cases.append(retrieval_case('same-hit-dedup', [
        retrieval_document('d1', 1, 'fox on shelf', [1, 0]),
        retrieval_document('d2', 2, 'vector target', [0, 1], folder_id=20),
    ], [first], [first], [first]))
    cases.append(retrieval_case('equal-score-stable-id', [
        retrieval_document('d1', 1, 'fox on shelf', [1, 0]),
        retrieval_document('d2', 2, 'fox on shelf', [1, 0], folder_id=20),
    ], [first, second], [first, second], [first, second], fetch_k=2))
    cases.append(retrieval_case('folder-before-limit', [
        retrieval_document('d1', 1, 'fox', [1, 0]),
        retrieval_document('d2', 2, 'fox on shelf', [1, 1], folder_id=20),
    ], [second], [second], [second], scope=dict(kind='selection', sourceIds=[], folderIds=[20])))
    cases.append(retrieval_case('other-notebook-exclusion', [
        retrieval_document('d1', 1, 'fox', [1, 0], notebook_id=2),
        retrieval_document('d2', 2, 'fox on shelf', [1, 1], folder_id=20),
    ], [second], [second], [second]))
    cases.append(retrieval_case('empty-selection', [
        retrieval_document('d1', 1, 'fox on shelf', [1, 0]),
    ], [], [], [], scope=dict(kind='selection', sourceIds=[], folderIds=[]), embedding_calls=0))
    lexical_only = retrieval_case('lexical-only', [
        retrieval_document('d1', 1, 'fox on shelf', [0, 1]),
        retrieval_document('d2', 2, 'vector target', [1, 0], folder_id=20),
    ], [first], [], [first], include_vectors=False, embedding_calls=0)
    lexical_only['subcases'] = [metrics_case('lexical-only-metrics', [span('d1', 0, 3)],
        [first_evidence], [first_evidence], None,
        metric_map(one, one, unavailable, one, unavailable), include_vectors=False)]
    cases.append(lexical_only)

    first_occurrence, second_occurrence = span('d1', 0, 3), span('d1', 4, 7)
    full = span('d1', 0, 8)
    cases.append(metrics_case('second-occurrence-only', [second_occurrence], [first_occurrence],
        [first_occurrence], [first_occurrence], metric_map(zero, zero, zero, zero, zero)))
    cases.append(metrics_case('overlap-earns-once', [span('d1', 4, 6)],
        [span('d1', 0, 7), span('d1', 3, 9)], [span('d1', 0, 7), span('d1', 3, 9)],
        [span('d1', 0, 7), span('d1', 3, 9)], metric_map(one, one, one, one, one)))
    wrong = span('d1', 0, 8, 'b' * 64)
    cases.append(metrics_case('wrong-hash', [second_occurrence], [wrong], [wrong], [wrong],
                              metric_map(zero, zero, zero, zero, zero)))
    truncated = metrics_case('packed-suffix-omitted', [second_occurrence], [full], [full],
                             [first_occurrence], metric_map(one, one, one, one, zero))
    truncated['subcases'] = [metrics_case('disjoint-packed-gap', [span('d1', 2, 6)],
        [full], [full], [span('d1', 0, 3), span('d1', 5, 8)],
        metric_map(one, one, one, one, zero))]
    cases.append(truncated)
    empty_pack = metrics_case('measured-empty-pack', [second_occurrence], [full], [full], [],
                               metric_map(one, one, one, one, zero))
    empty_pack['subcases'] = [
        metrics_case('absent-packing-hook', [second_occurrence], [full], [full], None,
                     metric_map(one, one, one, one, unavailable)),
        metrics_case('empty-gold-not-applicable', [], [full], [full], [],
                     metric_map(not_applicable, not_applicable, not_applicable, not_applicable, not_applicable)),
    ]
    cases.append(empty_pack)
    return dict(contract='eval-retrieval', version=1, cases=cases)


def build_reports():
    """Literal report DTO/Markdown gold; no production scorer/writer is invoked."""
    names = (
        'lexical_recall_at_top_k',
        'lexical_recall_at_fetch_k',
        'hybrid_recall_at_top_k',
        'candidate_recall_at_fetch_k',
        'packed_evidence_recall',
    )

    def metric(status, found, total, bp):
        return {'status': status, 'found': found, 'total': total, 'recall_bp': bp}

    def repeated(value):
        return {name: deepcopy(value) for name in names}

    recovered = repeated(metric('measured', 1, 1, 10000))
    missed = repeated(metric('measured', 0, 1, 0))
    pooled = repeated(metric('measured', 1, 2, 5000))
    inapplicable = repeated(metric('not_applicable', 0, 0, None))
    unavailable = metric('not_available', None, None, None)
    span = {
        'document_id': 'document-a',
        'content_hash': 'a' * 64,
        'start': 0,
        'end': 10,
    }

    measured = {
        'schema_version': 1,
        'corpus_id': 'fixture-report-v1',
        'corpus_hash': 'a' * 64,
        'platform': 'macos',
        'retrieval_version': 'legacy-fts-eval-rrf-v1',
        'chunker_version': 'eval-scalars-v1',
        'mode': 'ollama',
        'model': 'fixture-vectors-v1',
        'dimensions': 2,
        'top_k': 1,
        'fetch_k': 2,
        'documents': 2,
        'queries_total': 5,
        'overview_queries': 1,
        'absent_queries': 1,
        'empty_selection_queries': 1,
        'metrics': deepcopy(pooled),
        'by_language': {
            'cs': deepcopy(recovered),
            'de': deepcopy(inapplicable),
            'en': deepcopy(missed),
            'sk': deepcopy(inapplicable),
        },
        'by_case_type': {
            'absent': deepcopy(inapplicable),
            'answer': deepcopy(recovered),
            'empty_selection': deepcopy(inapplicable),
            'exact_identifier': deepcopy(missed),
            'overview': deepcopy(inapplicable),
        },
        'queries': [
            {
                'query_id': 'found',
                'text': 'Evidence | café\nfolder\\note',
                'language': 'cs',
                'case_type': 'answer',
                'status': 'measured',
                'files_in_scope': 2,
                'candidates_with_chunks': 2,
                'lexical': [deepcopy(span)],
                'vector': [deepcopy(span)],
                'fused': [deepcopy(span)],
                'metrics': deepcopy(recovered),
            },
            {
                'query_id': 'missing',
                'text': 'Find the second document.',
                'language': 'en',
                'case_type': 'exact_identifier',
                'status': 'measured',
                'files_in_scope': 2,
                'candidates_with_chunks': 2,
                'lexical': [deepcopy(span)],
                'vector': [deepcopy(span)],
                'fused': [deepcopy(span)],
                'metrics': deepcopy(missed),
            },
            {
                'query_id': 'absent',
                'text': 'Which insurance policy applies?',
                'language': 'en',
                'case_type': 'absent',
                'status': 'measured',
                'files_in_scope': 2,
                'candidates_with_chunks': 2,
                'lexical': [deepcopy(span)],
                'vector': [deepcopy(span)],
                'fused': [deepcopy(span)],
                'metrics': deepcopy(inapplicable),
            },
            {
                'query_id': 'empty',
                'text': 'Kto zodpovedá za kontrolu?',
                'language': 'sk',
                'case_type': 'empty_selection',
                'status': 'measured',
                'files_in_scope': 0,
                'candidates_with_chunks': 0,
                'lexical': [],
                'vector': [],
                'fused': [],
                'metrics': deepcopy(inapplicable),
            },
            {
                'query_id': 'overview',
                'text': 'Gib einen Überblick.',
                'language': 'de',
                'case_type': 'overview',
                'status': 'deferred_overview_wp8',
                'files_in_scope': 2,
                'candidates_with_chunks': 2,
                'lexical': [],
                'vector': [],
                'fused': [],
                'metrics': deepcopy(inapplicable),
            },
        ],
        'capabilities': {'packed_evidence': 'measured', 'overview': 'not_available'},
        'timing': {
            'warm_retrieval_ms': None,
            'end_to_end_ms': None,
            'cold_cache_ms': None,
        },
    }

    # Lexical report differences are authored explicitly; these are fixture
    # construction operations, not derived scorer or Markdown-writer output.
    lexical = deepcopy(measured)
    lexical['mode'] = 'lexical'
    lexical['model'] = None
    lexical['dimensions'] = None
    lexical['capabilities']['packed_evidence'] = 'not_available'
    lexical['metrics']['hybrid_recall_at_top_k'] = deepcopy(unavailable)
    lexical['metrics']['packed_evidence_recall'] = deepcopy(unavailable)
    for language in ('cs', 'en', 'sk'):
        lexical['by_language'][language]['hybrid_recall_at_top_k'] = deepcopy(unavailable)
        lexical['by_language'][language]['packed_evidence_recall'] = deepcopy(unavailable)
    for case_type in ('absent', 'answer', 'empty_selection', 'exact_identifier'):
        lexical['by_case_type'][case_type]['hybrid_recall_at_top_k'] = deepcopy(unavailable)
        lexical['by_case_type'][case_type]['packed_evidence_recall'] = deepcopy(unavailable)
    for row in lexical['queries']:
        row['vector'] = []
        if row['case_type'] != 'overview':
            row['metrics']['hybrid_recall_at_top_k'] = deepcopy(unavailable)
            row['metrics']['packed_evidence_recall'] = deepcopy(unavailable)

    measured_markdown = r'''# Multilingual retrieval eval v1

Corpus: fixture-report-v1 (2 documents, 5 queries)
Backend: legacy-fts-eval-rrf-v1; chunker: eval-scalars-v1; mode: ollama
topK: 1; fetchK per branch: 2
Recall aggregation: micro (pooled gold evidence items).

| metric | found | total | recall bp | status |
|---|---:|---:|---:|---|
| lexical_recall_at_top_k | 1 | 2 | 5000 | measured |
| lexical_recall_at_fetch_k | 1 | 2 | 5000 | measured |
| hybrid_recall_at_top_k | 1 | 2 | 5000 | measured |
| candidate_recall_at_fetch_k | 1 | 2 | 5000 | measured |
| packed_evidence_recall | 1 | 2 | 5000 | measured |

| query | text | status | lexical bp | hybrid bp | candidate bp | packed bp |
|---|---|---|---:|---:|---:|---:|
| found | Evidence \| café folder\\note | measured | 10000 | 10000 | 10000 | 10000 |
| missing | Find the second document. | measured | 0 | 0 | 0 | 0 |
| absent | Which insurance policy applies? | measured | — | — | — | — |
| empty | Kto zodpovedá za kontrolu? | measured | — | — | — | — |
| overview | Gib einen Überblick. | deferred_overview_wp8 | — | — | — | — |

Candidate recall uses the full union of the per-branch fetchK lists.
Unavailable packing/overview measurements are not scores; WP8 supplies those adapters.
'''
    unavailable_markdown = r'''# Multilingual retrieval eval v1

Corpus: fixture-report-v1 (2 documents, 5 queries)
Backend: legacy-fts-eval-rrf-v1; chunker: eval-scalars-v1; mode: lexical
topK: 1; fetchK per branch: 2
Recall aggregation: micro (pooled gold evidence items).

| metric | found | total | recall bp | status |
|---|---:|---:|---:|---|
| lexical_recall_at_top_k | 1 | 2 | 5000 | measured |
| lexical_recall_at_fetch_k | 1 | 2 | 5000 | measured |
| hybrid_recall_at_top_k | — | — | — | not_available |
| candidate_recall_at_fetch_k | 1 | 2 | 5000 | measured |
| packed_evidence_recall | — | — | — | not_available |

| query | text | status | lexical bp | hybrid bp | candidate bp | packed bp |
|---|---|---|---:|---:|---:|---:|
| found | Evidence \| café folder\\note | measured | 10000 | — | 10000 | — |
| missing | Find the second document. | measured | 0 | — | 0 | — |
| absent | Which insurance policy applies? | measured | — | — | — | — |
| empty | Kto zodpovedá za kontrolu? | measured | — | — | — | — |
| overview | Gib einen Überblick. | deferred_overview_wp8 | — | — | — | — |

Candidate recall uses the full union of the per-branch fetchK lists.
Unavailable packing/overview measurements are not scores; WP8 supplies those adapters.
'''
    return {
        'contract': 'eval-report',
        'version': 1,
        'cases': [
            {
                'name': 'measured',
                'input': deepcopy(measured),
                'expected_json': deepcopy(measured),
                'expected_markdown': measured_markdown,
            },
            {
                'name': 'unavailable',
                'input': deepcopy(lexical),
                'expected_json': deepcopy(lexical),
                'expected_markdown': unavailable_markdown,
            },
        ],
    }


def build_cli():
    """Authored CLI expectations; no parser or network dependency."""
    base_args = ['--dataset', 'multilingual']

    def success(name, args, **overrides):
        options = {
            'root': 'eval/multilingual',
            'mode': 'lexical',
            'model': None,
            'host': 'http://127.0.0.1:11434',
            'top_k': 16,
            'fetch_k': 32,
            'json_path': None,
            'markdown_path': None,
            'validate_only': False,
        }
        options.update(overrides)
        return {'name': name, 'args': args, 'expected': options}

    def failure(name, args):
        return {'name': name, 'args': args, 'expected': {'error': 'usage'}}

    cases = [
        success('default-multilingual-lexical', base_args),
        success('explicit-top-fetch', base_args + ['--top-k', '2', '--fetch-k', '4'],
                top_k=2, fetch_k=4),
        failure('zero-top-k', base_args + ['--top-k', '0']),
        failure('fetch-below-top-k', base_args + ['--top-k', '4', '--fetch-k', '2']),
        failure('unknown-flag', base_args + ['--unknown']),
        failure('lexical-model', base_args + ['--mode', 'lexical', '--model', 'nomic-embed-text-v2-moe']),
    ]

    subcases = [
        failure('invalid-dataset', ['--dataset', 'english']),
        failure('invalid-mode', base_args + ['--mode', 'hybrid']),
        failure('missing-ollama-model', base_args + ['--mode', 'ollama']),
        failure('empty-ollama-model', base_args + ['--mode', 'ollama', '--model', '']),
        failure('empty-root', base_args + ['--root', '']),
        failure('empty-json-path', base_args + ['--json', '']),
        failure('empty-markdown-path', base_args + ['--out', '']),
        failure('empty-host', base_args + ['--host', '']),
        failure('empty-dataset', ['--dataset', '']),
        failure('empty-mode', base_args + ['--mode', '']),
        failure('unexpected-positional', base_args + ['extra']),
        failure('validate-only-unexpected-value', base_args + ['--validate-only', 'true']),
        failure('unknown-equals-flag', base_args + ['--top-k=2']),
        failure('missing-value-before-next-flag', base_args + ['--root', '--validate-only']),
        failure('negative-top-k', base_args + ['--top-k', '-1']),
        failure('fractional-top-k', base_args + ['--top-k', '1.5']),
        failure('exponent-top-k', base_args + ['--top-k', '1e1']),
        failure('signed-top-k', base_args + ['--top-k', '+2']),
        failure('nonfinite-top-k', base_args + ['--top-k', 'NaN']),
        failure('whitespace-top-k', base_args + ['--top-k', ' 2 ']),
        failure('non-ascii-top-k', base_args + ['--top-k', '２']),
        failure('overflow-top-k', base_args + ['--top-k', '9223372036854775808']),
        failure('zero-fetch-k', base_args + ['--fetch-k', '0']),
        failure('negative-fetch-k', base_args + ['--fetch-k', '-1']),
        failure('fractional-fetch-k', base_args + ['--fetch-k', '32.5']),
        failure('exponent-fetch-k', base_args + ['--fetch-k', '1e2']),
        failure('non-ascii-fetch-k', base_args + ['--fetch-k', '３２']),
        failure('overflow-fetch-k', base_args + ['--fetch-k', '9223372036854775808']),
    ]

    # Missing/repeated forms are complete individual cases for both dispatchers.
    value_flags = [
        ('dataset', 'multilingual'), ('root', 'eval/multilingual'),
        ('mode', 'lexical'), ('model', 'nomic-embed-text-v2-moe'),
        ('host', 'http://127.0.0.1:11434'), ('top-k', '16'),
        ('fetch-k', '32'), ('json', 'eval-result.json'), ('out', 'eval-result.md'),
    ]
    for name, value in value_flags:
        prefix = [] if name == 'dataset' else list(base_args)
        if name == 'model':
            prefix += ['--mode', 'ollama']
        flag = '--' + name
        subcases.append(failure('missing-' + name + '-value', prefix + [flag]))
        subcases.append(failure('repeated-' + name, prefix + [flag, value, flag, value]))
    subcases.append(failure('repeated-validate-only', base_args + ['--validate-only', '--validate-only']))

    # Explicit invalid inputs come from the binding authority rules, independently
    # of the implementation's URL parser and without normalizing the input bytes.
    invalid_hosts = [
        ('missing-scheme', 'localhost:11434'),
        ('unsupported-scheme', 'ftp://localhost'),
        ('missing-authority', 'http:///ollama'),
        ('empty-hostname', 'http://:11434'),
        ('empty-port', 'http://localhost:'),
        ('zero-port', 'http://localhost:0'),
        ('overflow-port', 'http://localhost:65536'),
        ('negative-port', 'http://localhost:-1'),
        ('positive-signed-port', 'http://localhost:+1'),
        ('nondigit-port', 'http://localhost:abc'),
        ('non-ascii-port', 'http://localhost:１２'),
        ('userinfo', 'http://user:pass@localhost/ollama'),
        ('empty-userinfo', 'http://@localhost/ollama'),
        ('query', 'http://localhost/ollama?key=x'),
        ('empty-query', 'http://localhost/ollama?'),
        ('fragment', 'http://localhost/ollama#part'),
        ('empty-fragment', 'http://localhost/ollama#'),
        ('leading-control', '\thttp://localhost/ollama'),
        ('inner-control', 'http://local\nhost/ollama'),
        ('trailing-control', 'http://localhost/ollama\x00'),
        ('del-control', 'http://localhost/ollama\x7f'),
        ('c1-control', 'http://localhost/ollama\x85'),
        ('hostname-whitespace', 'http://local host/ollama'),
        ('path-whitespace', 'http://localhost/ollama root'),
        ('inner-unicode-whitespace', 'http://localhost/ollama\u00a0root'),
        ('hostname-underscore', 'http://bad_host/ollama'),
        ('hostname-leading-hyphen', 'http://-bad.example/ollama'),
        ('hostname-trailing-hyphen', 'http://bad-.example/ollama'),
        ('hostname-empty-label', 'http://a..example/ollama'),
        ('hostname-double-root-dot', 'http://localhost../ollama'),
        ('hostname-non-ascii', 'http://höst.example/ollama'),
        ('hostname-percent-escape', 'http://host%20name/ollama'),
        ('hostname-label-too-long', 'http://' + 'a' * 64 + '.example/ollama'),
        ('hostname-too-long', 'http://' + '.'.join(['a' * 63] * 4) + '/ollama'),
        ('ipv4-out-of-range', 'http://256.2.3.4/ollama'),
        ('ipv4-leading-zero', 'http://01.2.3.4/ollama'),
        ('ipv4-short', 'http://127.1/ollama'),
        ('ipv6-unclosed', 'http://[::1/ollama'),
        ('ipv6-unbracketed', 'http://2001:db8::1/ollama'),
        ('ipv6-invalid-literal', 'http://[oops]/ollama'),
        ('ipv6-authority-suffix', 'http://[::1]junk/ollama'),
        ('ipv6-scoped', 'http://[fe80::1%25en0]/ollama'),
        ('ipvfuture', 'http://[v1.a]/ollama'),
    ]
    subcases.extend(failure('invalid-host-' + name, base_args + ['--host', host])
                    for name, host in invalid_hosts)

    subcases += [
        success('explicit-root-outputs-validate-only',
                base_args + ['--root', 'fixtures/eval source', '--mode', 'lexical',
                             '--json', 'results/report.json', '--out', 'results/report.md',
                             '--validate-only'],
                root='fixtures/eval source', json_path='results/report.json',
                markdown_path='results/report.md', validate_only=True),
        success('explicit-ollama',
                base_args + ['--mode', 'ollama', '--model', 'nomic-embed-text-v2-moe',
                             '--host', 'http://localhost:11434', '--top-k', '2', '--fetch-k', '4'],
                mode='ollama', model='nomic-embed-text-v2-moe',
                host='http://localhost:11434', top_k=2, fetch_k=4),
        success('prefixed-host',
                base_args + ['--mode', 'ollama', '--model', 'nomic-embed-text-v2-moe',
                             '--host', 'https://localhost/ollama'],
                mode='ollama', model='nomic-embed-text-v2-moe', host='https://localhost/ollama'),
        success('host-trailing-slashes-normalized',
                base_args + ['--host', 'https://localhost/ollama///'],
                host='https://localhost/ollama'),
        success('host-surrounding-whitespace-normalized',
                base_args + ['--host', '\u00a0https://localhost/ollama \u00a0'],
                host='https://localhost/ollama'),
        success('host-bracketed-ipv6',
                base_args + ['--host', 'http://[::1]:11434/ollama'],
                host='http://[::1]:11434/ollama'),
        success('host-minimum-port', base_args + ['--host', 'http://localhost:1'],
                host='http://localhost:1'),
        success('host-maximum-port', base_args + ['--host', 'http://localhost:65535'],
                host='http://localhost:65535'),
        success('host-idna-root-dot', base_args + ['--host', 'https://xn--hst-sna.example./ollama'],
                host='https://xn--hst-sna.example./ollama'),
        success('host-single-numeric-label', base_args + ['--host', 'http://1234/ollama'],
                host='http://1234/ollama'),
        success('host-ipv4-root-dot', base_args + ['--host', 'http://127.0.0.1./ollama'],
                host='http://127.0.0.1./ollama'),
    ]
    cases[4]['subcases'] = subcases
    return {'contract': 'eval-cli', 'version': 1, 'cases': cases}


def generated_files():
    """Return only the four owned contract paths and their reproducible bytes."""
    return {
        'eval-assets-v1.json': canonical_json(build_assets()),
        'eval-retrieval-v1.json': canonical_json(build_retrieval()),
        'eval-report-v1.json': canonical_json(build_reports()),
        'eval-cli-v1.json': canonical_json(build_cli()),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--write', action='store_true')
    modes.add_argument('--check', action='store_true')
    args = parser.parse_args()
    # Corpus ownership ended with Task 1A. Even --write only checks those bytes.
    checked = subprocess.run([sys.executable, str(ROOT / 'tools/eval/update_eval_hashes.py'), '--check'],
                             cwd=ROOT, check=False)
    if checked.returncode:
        return checked.returncode
    try:
        files = generated_files()
        different = [name for name, data in files.items()
                     if not (CONTRACTS / name).is_file() or (CONTRACTS / name).read_bytes() != data]
        if args.write:
            for name in different:
                (CONTRACTS / name).write_bytes(files[name])
        elif different:
            print('Eval fixture bytes differ: ' + ', '.join(different), file=sys.stderr)
            return 1
        print('eval contracts v1: 27 asset, 12 retrieval/metric, 2 report, 6 CLI root cases; 3 window cases')
        print('44 documents, 144 queries; eval fixtures current')
        return 0
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
