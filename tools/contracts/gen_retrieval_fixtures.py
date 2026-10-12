#!/usr/bin/env python3
"""Independent WP5 retrieval oracles; standard library only, no runtime imports.

Only the six named retrieval fixtures are written. --check compares bytes and
never writes. Scalar offsets use Python code points without Unicode rewriting.
Cache traces simulate counters/dictionaries, never a Float32 matrix.

Endpoint identity follows the already frozen WP6 ingestion fixtures and the
user's same-identity handoff: SHA256(type + LF + normalizedRoot), lowercase hex.
This intentionally supersedes WP5's proposed endpoint-v1/NUL encoding. Both
retrieval and ingestion must use this identity from their captured session.
"""

import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import struct


OUT = Path(__file__).resolve().parents[2] / 'Tests' / 'fixtures' / 'contracts'
GROUPS = ('scope', 'rank', 'cache', 'evidence', 'session', 'perf')
STAMP = '2026-01-01 00:00:00.000'


def rrf(lexical: list[int], vector: list[int], k: int = 60) -> list[dict]:
    scores = {}
    for branch in (lexical, vector):
        seen = set()
        rank = 0
        for chunk in branch:
            if chunk in seen:
                continue
            seen.add(chunk)
            rank += 1
            scores[chunk] = scores.get(chunk, 0) + 1_000_000 // (k + rank)
    return [dict(chunkId=i, rrfMicro=s) for i, s in
            sorted(scores.items(), key=lambda item: (-item[1], item[0]))]


def reference(chunk, source, revision, ord=0):
    return dict(chunkId=chunk, sourceId=source, revisionId=revision, ord=ord)


def scope_fixture():
    rows = [
        (1, 1, 10, 'present', 1, 102, 102, 101),
        (2, 1, 10, 'missing', 1, 201, 201, 201),
        (3, 1, 20, 'present', 0, 301, 301, 301),
        (4, 1, None, 'present', 1, 402, 401, 401),
        (5, 2, None, 'present', 1, 501, 501, None),
        (6, 1, 20, 'present', 1, 601, None, None),
        (7, 1, 20, 'unavailable', 1, 701, 701, 701),
    ]
    sources, revisions, chunks, manifest, embeddings = [], [], [], [], []
    for sid, nb, folder, availability, eligible, current, published, vector in rows:
        sources.append(dict(id=sid, notebookId=nb, folderId=folder,
                            relPath=f'{sid}.txt' if folder is not None else None,
                            type='text', title=f'{sid}.txt',
                            status='error' if sid == 4 else 'ready',
                            ingestedAt=STAMP, availability=availability,
                            eligible=eligible, currentRevision=current,
                            publishedRevisionId=published))
        for rid in sorted({r for r in (current, published, vector) if r is not None}):
            text = f'needle revision {rid}'
            revisions.append(dict(id=rid, sourceId=sid, revision=rid % 10,
                                  contentHash=f'fixture-{rid}', canonicalText=text,
                                  textFormatVersion=1, chunkerVersion=1, createdAt=STAMP))
            chunks.append(dict(id=rid * 10, sourceId=sid, revisionId=rid, ord=0,
                               text=text, tokenCount=4, charStart=None, charEnd=None))
        if vector is not None:
            manifest.append(dict(generationId=90, sourceId=sid, revisionId=vector,
                                 state='done', reason=None))
            embeddings.append(dict(generationId=90, chunkId=vector * 10, vector=[1, 0]))
    manifest.append(dict(generationId=91, sourceId=1, revisionId=102, state='done', reason=None))
    embeddings.append(dict(generationId=91, chunkId=1020, vector=[0, 1]))
    seed = dict(
        notebooks=[dict(id=n, name=f'n{n}', createdAt=STAMP, updatedAt=STAMP) for n in (1, 2)],
        folders=[dict(id=f, notebookId=1, rootPath=f'/fixture/f{f}',
                      pathIdentity=dict(volumeId='fixture', components=['fixture', f'f{f}']),
                      displayName=f'f{f}', includeExts=['txt'], ignoreGlobs=[], limits={},
                      createdAt=STAMP) for f in (10, 20)],
        sources=sources, revisions=revisions, chunks=chunks,
        generations=[dict(id=g, notebookId=1, providerId='legacy', endpointRevision='legacy',
                          model='m', modelDigest=None, dims=2, normalization='legacy',
                          queryFormatVersion='legacy', docFormatVersion='legacy',
                          chunkerVersion='legacy', state=state, createdAt=STAMP)
                     for g, state in ((90, 'active'), (91, 'retired'))],
        manifest=manifest, embeddings=embeddings)

    def selection(sources=(), folders=()):
        return dict(kind='selection', sourceIds=list(sources), folderIds=list(folders))

    def case(name, scope, lexical, vector, notebook=1, active=90, **extra):
        return dict(name=name, scope=scope, notebookId=notebook, active=active,
                    publishedChunkIds=lexical, vectorChunkIds=vector, **extra)

    cases = [
        case('all', dict(kind='all'), [1020, 4010], [1010, 4010]),
        case('folder10', selection(folders=[10]), [1020], [1010]),
        case('union-source4-folder10', selection([4], [10]), [1020, 4010], [1010, 4010]),
        case('empty', selection(), [], [], sqlCalls=0, embeddingCalls=0),
        case('other-notebook', dict(kind='all'), [5010], [], notebook=2, active=None),
        case('wrong-notebook-ids', selection([5]), [], []),
        case('unpublished', selection([6]), [], []),
        case('no-active', dict(kind='all'), [1020, 4010], [], active=None),
    ]
    scope_events = [
        dict(name='revoke-availability', scope={'kind': 'all'},
             events=[dict(kind='setAvailability', sourceId=1, value='missing')],
             afterPublishedChunkIds=[4010], afterVectorChunkIds=[4010]),
        dict(name='revoke-eligible', scope={'kind': 'all'},
             events=[dict(kind='setEligible', sourceId=1, value=0)],
             afterPublishedChunkIds=[4010], afterVectorChunkIds=[4010]),
        dict(name='revoke-membership', scope=selection(folders=[10]),
             events=[dict(kind='setFolder', sourceId=1, folderId=20, relPath='1.txt')],
             afterPublishedChunkIds=[], afterVectorChunkIds=[]),
        dict(name='join-membership', scope=selection(folders=[10]),
             events=[dict(kind='setFolder', sourceId=4, folderId=10, relPath='4.txt')],
             afterPublishedChunkIds=[1020], afterVectorChunkIds=[1010]),
        dict(name='publish-during-query', scope={'kind': 'all'},
             events=[dict(kind='publish', sourceId=1, revisionId=103)],
             afterPublishedChunkIds=[1020, 4010], afterVectorChunkIds=[1010, 4010]),
        dict(name='switch-during-query', scope={'kind': 'all'},
             events=[dict(kind='switchGeneration', oldId=90, newId=91)],
             afterPublishedChunkIds=[1020, 4010], afterVectorChunkIds=[1010, 4010]),
    ]
    for event in scope_events:
        folder_only = event['scope']['kind'] == 'selection'
        event.update(notebookId=1, active=90,
                     publishedChunkIds=[1020] if folder_only else [1020, 4010],
                     vectorChunkIds=[1010] if folder_only else [1010, 4010])
    return dict(seed=seed, cases=cases + scope_events)


def rank_fixture():
    cases = [dict(name=n, lexical=l, vector=v, expected=rrf(l, v))
             for n, l, v in [('union', [20, 30], [10, 20]), ('tie', [9], [3]),
                             ('dedupe', [20, 20, 30], [20]), ('empty', [], []),
                             ('full-pool', [1, 2], [3, 4])]]

    def row(cid, vector=None, eligible=1, **corrupt):
        # Each row has its own source, so the eligibility mask can distinguish it.
        value = dict(reference(cid, cid, cid * 100 + 1), eligible=eligible, **corrupt)
        if vector is not None:
            value['vector'] = vector
        return value

    def vector_case(name, rows, ids, scores, k=2, query=None, **extra):
        return dict(name=name, query=[1, 0] if query is None else query, dims=2,
                    rows=rows, k=k, expectedIds=ids, expectedScoreMicros=scores, **extra)

    three = [row(1, [1, 0]), row(2, [0, 1]), row(3, [-1, 0])]
    tied = [row(9, [1, 0]), row(3, [1, 0]), row(6, [1, 0])]
    cases += [
        vector_case('mask-before-heap', [row(1, [1, 0], 0), *three[1:]], [2, 3], [0, -1000000]),
        vector_case('tie-id', tied[:2], [3], [1000000], k=1),
        vector_case('zero-legacy', [row(1, [0, 0]), row(2, [-1, 0])], [1, 2], [0, -1000000]),
        vector_case('nonfinite', [row(1, float32Bits=[0x7fc00000, 0]),
                                 row(2, float32Bits=[0x7f800000, 0]),
                                 row(3, blobHex='0000803f'), row(4, [1, 0])],
                    [4], [1000000], invalidVectorCount=3),
        vector_case('k0', three, [], [], k=0),
        vector_case('k9', three, [1, 2, 3], [1000000, 0, -1000000], k=9),
        vector_case('tied-forward', tied, [3, 6], [1000000, 1000000]),
        vector_case('tied-reversed', list(reversed(tied)), [3, 6], [1000000, 1000000]),
        vector_case('normalized-dot', [row(1, [4, 3])], [1], [960000], k=1, query=[3, 4]),
    ]
    for name, query in [('query-empty', []), ('query-zero', [0, 0]),
                        ('query-wrong-dims', [1])]:
        cases.append(vector_case(name, three, [], [], query=query, expectedStatus='invalidQueryVector'))
    bad_query = vector_case('query-nonfinite', three, [], [], expectedStatus='invalidQueryVector')
    del bad_query['query']
    bad_query['queryFloat32Bits'] = [0x7fc00000, 0]
    cases.append(bad_query)
    cases.append(dict(name='oversized-generation', dims=2097153,
                      expectedStatus='oversizedVector', expectedBlobReads=0, expectedEmbeddingCalls=0))
    return dict(rrfK=60, cases=cases)


class CacheOracle:
    """Counter-only model; live retired entries remain charged outside lookup."""

    def __init__(self, budget, dims):
        self.budget, self.dims = budget, dims
        self.ready, self.fills, self.leases = {}, {}, {}
        self.retired = []
        self.tick = self.loads = 0

    def stats(self):
        return dict(residentBytes=sum(e['bytes'] for e in list(self.ready.values()) + self.retired),
                    reservedBytes=sum(f['bytes'] for f in self.fills.values()),
                    entryCount=len(self.ready), loadCount=self.loads,
                    residentKeys=sorted(self.ready))

    def touch(self, entry):
        self.tick += 1
        entry['tick'] = self.tick

    def grant(self, entry, lease):
        entry['leases'].add(lease)
        self.leases[lease] = entry
        self.touch(entry)

    def begin(self, key, lease, rows, barrier):
        if key in self.ready:
            self.grant(self.ready[key], lease)
            return 'cached'
        for name, fill in self.fills.items():
            if fill['key'] == key and fill['valid']:
                assert name == barrier
                fill['waiters'].add(lease)
                return 'pending'
        charge = rows * (self.dims * 4 + 32)
        if charge > self.budget:
            return 'stream'
        while True:
            stats = self.stats()
            if stats['residentBytes'] + stats['reservedBytes'] + charge <= self.budget:
                break
            victims = [(e['tick'], k) for k, e in self.ready.items() if not e['leases']]
            if not victims:
                return 'stream'
            del self.ready[min(victims)[1]]
        assert barrier not in self.fills
        self.loads += 1
        self.fills[barrier] = dict(key=key, bytes=charge, waiters={lease}, valid=True)
        return 'pending'

    def complete(self, barrier, failed=False):
        fill = self.fills.pop(barrier)
        if failed or not fill['valid'] or not fill['waiters']:
            return 'error' if failed else 'stream'
        entry = dict(bytes=fill['bytes'], leases=set(), tick=0)
        self.ready[fill['key']] = entry
        for lease in sorted(fill['waiters']):
            self.grant(entry, lease)
        return 'cached'

    def apply(self, action):
        op = action['op']
        if op in ('acquire', 'startAcquire'):
            barrier = action.get('barrier', action['lease'])
            result = self.begin(action['key'], action['lease'], action.get('rows', 2), barrier)
            if op == 'acquire':
                if result == 'pending':
                    result = self.complete(barrier)
                action['expectedMode'] = result
        elif op == 'release':
            entry = self.leases.pop(action['lease'])
            entry['leases'].remove(action['lease'])
            self.retired = [e for e in self.retired if e['leases']]
        elif op == 'invalidate':
            entry = self.ready.pop(action['key'], None)
            if entry is not None and entry['leases']:
                self.retired.append(entry)
            for fill in self.fills.values():
                if fill['key'] == action['key']:
                    fill['valid'] = False
        elif op in ('completeFill', 'failFill'):
            result = self.complete(action['barrier'], failed=op == 'failFill')
            if result == 'error':
                action['expectedError'] = 'loadFailed'
            else:
                action['expectedMode'] = result
        elif op == 'cancelWaiter':
            fill = next(f for f in self.fills.values() if action['lease'] in f['waiters'])
            fill['waiters'].remove(action['lease'])
            # Reservation belongs to the fill until its completion handler runs.
        else:
            raise ValueError(f'Unknown cache operation: {op}')
        action['expected'] = self.stats()


def cache_fixture():
    def acquire(key, lease, rows=2):
        return dict(op='acquire', key=key, lease=lease, rows=rows)

    def release(lease):
        return dict(op='release', lease=lease)

    def start(key, lease, barrier):
        return dict(op='startAcquire', key=key, lease=lease, rows=2, barrier=barrier)

    scripts = [
        ('lru', [acquire('A', 'a'), release('a'), acquire('B', 'b'), release('b'),
                 acquire('A', 'a2'), release('a2'), acquire('C', 'c'), release('c')]),
        ('leased-eviction', [acquire('A', 'a'), acquire('B', 'b'), dict(op='invalidate', key='A'),
                             acquire('C', 'c-stream'), release('a'), acquire('C', 'c'),
                             release('b'), release('c')]),
        ('oversize', [acquire('A', 'a', rows=5)]),
        ('epoch-race', [start('A', 'a', 'old-epoch'), dict(op='invalidate', key='A'),
                        dict(op='completeFill', barrier='old-epoch')]),
        ('single-flight', [start('A', 'a', 'shared'), start('A', 'a2', 'shared'),
                           dict(op='completeFill', barrier='shared'), release('a'), release('a2')]),
        ('load-failure', [start('A', 'a', 'failed'), dict(op='failFill', barrier='failed')]),
        ('databases-isolated', [acquire('A', 'a'), acquire('B', 'b'), release('a'), release('b')]),
    ]
    cases = []
    for name, actions in scripts:
        oracle = CacheOracle(160, 2)
        for action in actions:
            oracle.apply(action)
        # A paused acquisition exposes reservation stats now; mode/error describes
        # its eventual result when the named barrier is released by the adapter.
        completed = {a['barrier']: a for a in actions if a['op'] in ('completeFill', 'failFill')}
        for action in actions:
            if action['op'] == 'startAcquire':
                outcome = completed[action['barrier']]
                field = 'expectedMode' if 'expectedMode' in outcome else 'expectedError'
                action[field] = outcome[field]
        cases.append(dict(name=name, actions=actions))
    return dict(budgetBytes=160, dims=2, rowsPerMatrix=2, chargedBytesPerMatrix=80,
                metadataBytesPerRow=32,
                keys={k: dict(databaseId=f'db-{k}', notebookId=1, generationId=90, epoch=0)
                      for k in ('A', 'B', 'C')}, cases=cases)


def evidence_fixture():
    canonical = 'A😀B é C\nneedle tail'
    refs = [reference(1020 + i, 1, 102, i) for i in range(3)]
    chunks = [dict(ref, start=start, end=end, chunkText=canonical[start:end], chunkerVersion=2)
              for ref, (start, end) in zip(refs, [(0, 7), (4, 12), (12, 20)])]

    def passage_case(name, start, end, text=canonical, version=2, chunk_text=None, **extra):
        expected = text[start:end] if start is not None else chunk_text
        row = dict(chunkText=chunk_text if chunk_text is not None else expected,
                   start=start, end=end, chunkerVersion=version, pageHint=None)
        if text != canonical:
            row['canonicalText'] = text
        return dict(name=name, row=row, expectedText=expected,
                    expectedSnippet=expected[:240],
                    expectedSpans=[] if start is None else [dict(start=start, end=end)], **extra)

    old = reference(1010, 1, 101)
    cases = [
        passage_case('full-text', 0, 7, reference=refs[0]),
        passage_case('supplementary-prefix', 4, 12, reference=refs[1]),
        dict(name='published-neighbours', reference=refs[1], radius=1,
             expectedNeighbours=[refs[0], refs[2]]),
        dict(name='old-vector', reference=old, publishedRevisionId=102, radius=1,
             expectedNeighbours=refs[:2], mayMerge=False),
        passage_case('legacy', None, None, version=1, chunk_text='legacy whole text'),
        dict(name='invalid-span', row=dict(chunkText=canonical, start=0, end=99,
                                         chunkerVersion=2, pageHint=None), expectedError='invalidSpan'),
        dict(name='wrong-revision', reference=reference(1020, 1, 101),
             expectedError='revisionMismatch'),
        passage_case('snippet', 0, 241, text='😀' * 241),
        dict(name='revoked', reference=refs[0],
             events=[dict(kind='setAvailability', sourceId=1, value='missing')], expectedPassages=[]),
        dict(name='gc-pin', reference=old, expectedText='needle revision 101',
             retireGenerationId=90, currentRevisionId=102, publishedRevisionId=102,
             retainedRevisionIds=[101, 102], retainedChunkIds=[1010, 1020],
             deletedGenerationId=90, deletedRevisionId=101, deletedChunkId=1010,
             deletedVectorChunkId=1010, survivingRevisionIds=[102], survivingChunkIds=[1020]),
    ]
    return dict(canonicalText=canonical, sourceId=1, revisionId=102, chunks=chunks, cases=cases)


def endpoint_revision(provider_type, normalized_root):
    # Keep byte-identical with ingestion-generations-v1, including the LF separator.
    return hashlib.sha256((provider_type + '\n' + normalized_root).encode('utf-8')).hexdigest()


DELETED_PROVIDER = '6f1c2a4e-8b3d-4c7a-9e5f-0a1b2c3d4e5f'


def session_fixture():
    root = 'https://unit.example/proxy/v1'
    other = 'https://other.example/v1'

    def case(name, provider_type='openai_compatible', normalized_root=root,
             model='m', error=None, requests=1, **extra):
        return dict(name=name, type=provider_type, root=normalized_root,
                    normalizedRoot=normalized_root, model=model, queryFormatVersion='1',
                    expectedError=error, requests=requests, **extra)

    cases = [
        case('root', 'ollama', 'http://localhost:11434',
             expectedEndpointRevision=endpoint_revision('ollama', 'http://localhost:11434')),
        case('proxy', expectedEndpointRevision=endpoint_revision('openai_compatible', root)),
        case('key-rotation', model='m:tag', oldRoot=root, newRoot=root, oldKey='key-A', newKey='key-B',
             rawModel='m:tag', newModel='new:model', providerId='provider-a',
             expectedEndpointRevision=endpoint_revision('openai_compatible', root),
             expectedNewEndpointRevision=endpoint_revision('openai_compatible', root),
             expectedRequest=dict(url=root + '/embeddings', authorization='Bearer key-A',
                                  model='m:tag', inputs=['Q'])),
        case('root-change', oldRoot=root, newRoot=other, error='endpointRevisionMismatch', requests=0,
             generationEndpointRevision=endpoint_revision('openai_compatible', root),
             newEndpointRevision=endpoint_revision('openai_compatible', other)),
        case('chat-only-anthropic', 'anthropic', 'https://unit.example', error='unsupportedEndpoint', requests=0),
        case('chat-only-openwebui', 'openwebui', 'https://unit.example', error='unsupportedEndpoint', requests=0),
        case('legacy', model='qwen3:0.6b', modelKey='provider-a:qwen3:0.6b',
             storedKey='provider-a:qwen3:0.6b', providerId='provider-a', rawModel='qwen3:0.6b',
             expectedStatus='legacyEndpointUnverified'),
        case('legacy-bare', storedKey='m', selectedProviderId='provider-a',
             selectedModel='new-model', providerId='provider-a', rawModel='m',
             expectedStatus='legacyEndpointUnverified'),
        # A UUID-shaped prefix is a provider id even after the provider was removed.
        case('legacy-unresolved', model=DELETED_PROVIDER + ':qwen3:0.6b',
             storedKey=DELETED_PROVIDER + ':qwen3:0.6b', error='legacyProviderUnresolved', requests=0),
        case('unknown-format', error='unsupportedQueryFormat', requests=0),
    ]
    # Appended: a colon prefix that is neither a registered provider id, a UUID nor a
    # provider type is part of a bare model tag of the selected embedding provider.
    for name, stored in (('legacy-bare-tag', 'nomic-embed-text:latest'),
                         ('legacy-bare-size-tag', 'mxbai-embed-large:335m'),
                         ('legacy-unknown-prefix', 'deleted:qwen3:0.6b'),
                         ('legacy-empty-prefix', ':m')):
        cases.append(case(name, model=stored, storedKey=stored, selectedProviderId='provider-a',
                          selectedModel='new-model', providerId='provider-a', rawModel=stored,
                          expectedStatus='legacyEndpointUnverified'))
    # A provider-type prefix is provider-qualified; with no such provider id it is never guessed.
    cases.append(case('legacy-unresolved-type', model='ollama:nomic-embed-text',
                      storedKey='ollama:nomic-embed-text', error='legacyProviderUnresolved', requests=0))
    for c in cases:
        if c['name'].startswith('legacy'):
            c['queryFormatVersion'] = 'legacy'
        if c['name'] == 'unknown-format':
            c['queryFormatVersion'] = '99'
        c['inputs'] = ['Q']
        if c['expectedError'] is None:
            c['expectedInputs'] = ['Q']
    return dict(endpointRevisionEncoding='sha256-lowerhex(type-utf8 + LF + normalized-root-utf8)',
                cases=cases)


def perf_fixture():
    rows = []
    for i in range(8):
        vector = [int(j == (i + 17) % 4) for j in range(4)]
        rows.append(dict(chunkId=i + 1, sourceId=1 + i // 100, ord=i % 100,
                         text=f'synthetic {i} needle{i % 97}', vector=vector))
    raw = b''.join(struct.pack('<4f', *r['vector']) for r in rows)
    cases = [dict(name='small', count=8, dims=4, seed=17, rows=rows,
                  expectedVectorBytesSha256=hashlib.sha256(raw).hexdigest()),
             dict(name='large100k', count=100000, dims=256, seed=17),
             dict(name='large200k', count=200000, dims=256, seed=17),
             dict(name='timing', clockTicks=[100, 130, 180, 230], frequency=1000,
                  queryEmbeddingMs=30, warmRetrievalMs=50, hydrationMs=50)]
    return dict(scenarios=['concurrent-ingestion', 'streaming-budget', 'warm-cache'], cases=cases)


def make_contracts() -> dict[str, dict]:
    factories = (scope_fixture, rank_fixture, cache_fixture,
                 evidence_fixture, session_fixture, perf_fixture)
    # Return independent case objects, including where a local oracle reuses rows.
    return {f'retrieval-{group}-v1.json':
            deepcopy(dict(contract=f'retrieval-{group}', version=1, **factory()))
            for group, factory in zip(GROUPS, factories)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Compare generated bytes without writing.')
    args = parser.parse_args()
    bad = []
    for name, fixture in make_contracts().items():
        data = (json.dumps(fixture, ensure_ascii=False, sort_keys=True,
                           indent=2, allow_nan=False) + '\n').encode('utf-8')
        path = OUT / name
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                bad.append(name)
        else:
            OUT.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if bad:
        print('out of date: ' + ', '.join(bad))
        return 1
    print('ok' if args.check else 'wrote 6 retrieval fixtures')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
