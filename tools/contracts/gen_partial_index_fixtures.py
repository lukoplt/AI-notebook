#!/usr/bin/env python3
"""retrieval-partial-v1 reference: semantic retrieval during the first index build.

While a notebook has no active generation, retrieval reads the already
completed sources of the newest building generation of the current embedding
selection, so semantic search is available long before activation. Swift
(`NotebookStore.withQueryPin`, `Retriever.search`) and C#
(`NotebookStore.WithQueryPin`, `Retriever.SearchAsync`) seed every case into a
fresh store, run one hybrid query through a scripted embedding session and must
reproduce every expected output exactly. Normative text:
docs/contracts/retrieval-partial-index-v1.md.

Standard library only; this oracle never imports runtime code. Lexical ties are
by construction: every chunk text has exactly three FTS tokens, so all chunks
matching the one-token query have equal bm25 and order by chunk id.
"""

import argparse
import copy
import json
import math
from pathlib import Path

CONTRACT = 'retrieval-partial'
VERSION = 1
OUTPUT = 'Tests/fixtures/contracts/retrieval-partial-v1.json'
STAMP = '2026-01-01 00:00:00.000'
NOTEBOOK_ID = 1
RRF_K = 60
FETCH_K = 8
QUERY = 'kiwi'
SELECTION = dict(providerId='p', model='m', endpointRevision='e1')

# (sourceId, availability, publishedRevision, [(revisionId, [(chunkId, word)])])
SOURCES = [
    (1, 'present', 11, [(11, [(111, 'kiwi'), (112, 'plum')])]),
    (2, 'present', 21, [(21, [(211, 'plum'), (212, 'plum')])]),
    # Revision 30 is a superseded extraction; 31 is current and published.
    (3, 'present', 31, [(30, [(301, 'kiwi')]), (31, [(311, 'kiwi')])]),
    (4, 'present', 41, [(41, [(411, 'kiwi')])]),
    (5, 'present', 51, [(51, [(511, 'plum'), (512, 'kiwi')])]),
    (6, 'missing', 61, [(61, [(611, 'kiwi')])]),
]

# Integer components; both platforms L2-normalize rows and the query before scoring.
BUILD_VECTORS = {111: [1, 0, 0], 112: [3, 4, 0], 211: [4, 3, 0], 212: [0, 1, 0],
                 301: [12, 5, 0], 511: [5, 12, 0], 611: [24, 7, 0]}
ACTIVE_VECTORS = {111: [0, 1, 0], 112: [1, 0, 0]}
QUERY_VECTOR = [1, 0, 0]


def model_key(generation: dict) -> str:
    if generation['providerId'] == 'legacy':
        return generation['model']
    return generation['providerId'] + ':' + generation['model']


def generation(gid, state, model='m', endpoint='e1'):
    return dict(id=gid, notebookId=NOTEBOOK_ID, providerId='p', endpointRevision=endpoint, model=model,
                modelDigest=None, dims=3, normalization='l2', queryFormatVersion='1', docFormatVersion='1',
                chunkerVersion='1', state=state, createdAt=STAMP)


def manifest(gid, rows):
    return [dict(generationId=gid, sourceId=s, revisionId=r, state=st, reason=None) for s, r, st in rows]


def embeddings(gid, vectors, chunk_ids):
    return [dict(generationId=gid, chunkId=c, vector=vectors[c]) for c in chunk_ids]


def seed() -> dict:
    sources, revisions, chunks = [], [], []
    for sid, availability, published, revs in SOURCES:
        sources.append(dict(id=sid, notebookId=NOTEBOOK_ID, type='text', title=f'{sid}.txt', status='ready',
                            ingestedAt=STAMP, availability=availability, eligible=1,
                            currentRevision=published, publishedRevisionId=published))
        for number, (rid, rev_chunks) in enumerate(revs, start=1):
            texts = [f'{word} chunk c{cid}' for cid, word in rev_chunks]
            revisions.append(dict(id=rid, sourceId=sid, revision=number, contentHash=f'fixture-{rid}',
                                  canonicalText='\n'.join(texts), textFormatVersion=1, chunkerVersion=1,
                                  createdAt=STAMP))
            for ord_, ((cid, _), text) in enumerate(zip(rev_chunks, texts)):
                chunks.append(dict(id=cid, sourceId=sid, revisionId=rid, ord=ord_, text=text, tokenCount=3))
    return dict(notebooks=[dict(id=NOTEBOOK_ID, name='n1', createdAt=STAMP, updatedAt=STAMP)],
                sources=sources, revisions=revisions, chunks=chunks)


BUILDING_MANIFEST = [(1, 11, 'done'), (2, 21, 'done'), (3, 30, 'done'), (4, 41, 'pending'),
                     (5, 51, 'pending'), (6, 61, 'done')]
BUILDING_CHUNKS = [111, 112, 211, 212, 301, 511, 611]


def building(gid=70, model='m', endpoint='e1', rows=None, chunk_ids=None, state='building'):
    return dict(generations=[generation(gid, state, model, endpoint)],
                manifest=manifest(gid, BUILDING_MANIFEST if rows is None else rows),
                embeddings=embeddings(gid, BUILD_VECTORS, BUILDING_CHUNKS if chunk_ids is None else chunk_ids))


def merge(*worlds):
    out = dict(generations=[], manifest=[], embeddings=[])
    for world in worlds:
        for key in out:
            out[key] += world[key]
    return out


def raw_cases():
    def case(name, world, provider=None, session_endpoint='e1'):
        return dict(name=name, sessionEndpointRevision=session_endpoint,
                    provider=provider or dict(kind='vector', vector=QUERY_VECTOR), **world)

    empty = dict(generations=[], manifest=[], embeddings=[])
    active = dict(generations=[generation(60, 'active')], manifest=manifest(60, [(1, 11, 'done')]),
                  embeddings=embeddings(60, ACTIVE_VECTORS, [111, 112]))
    active_other = dict(generations=[generation(60, 'active', model='other')],
                        manifest=manifest(60, [(1, 11, 'done')]),
                        embeddings=embeddings(60, ACTIVE_VECTORS, [111, 112]))
    return [
        case('no-generation', empty),
        case('building-partial', building()),
        case('active-and-building', merge(active, building())),
        case('active-other-model-and-building', merge(active_other, building())),
        case('stale-revision-only', building(rows=[(1, 11, 'pending'), (3, 30, 'done')], chunk_ids=[111, 301])),
        case('mismatched-selection', building(model='other')),
        case('mismatched-endpoint', building(endpoint='e0')),
        case('mismatched-dims', building(), provider=dict(kind='vector', vector=[1, 0])),
        case('provider-unavailable', building(), provider=dict(kind='failure')),
        case('newest-building', merge(
            building(70, rows=[(1, 11, 'done')], chunk_ids=[111, 112]),
            building(71, rows=[(2, 21, 'done')], chunk_ids=[211, 212]),
            building(72, rows=[(1, 11, 'done')], chunk_ids=[111, 112], state='failed'))),
    ]


# ---------------------------------------------------------------- reference


def rrf(lexical, vector, k=RRF_K):
    scores = {}
    for branch in (lexical, vector):
        for rank, chunk in enumerate(dict.fromkeys(branch), start=1):
            scores[chunk] = scores.get(chunk, 0) + 1_000_000 // (k + rank)
    return [dict(chunkId=c, rrfMicro=s) for c, s in sorted(scores.items(), key=lambda i: (-i[1], i[0]))]


def cosine(a, b):
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return sum(x * y for x, y in zip(a, b)) / (na * nb)


def pin(world: dict, sources: dict):
    """§3: the generation a query reads and its vector revisions (sourceId -> revisionId)."""
    selection = SELECTION['providerId'] + ':' + SELECTION['model']
    usable = {sid for sid, s in sources.items() if s['availability'] == 'present' and s['eligible'] == 1}
    gens = [g for g in world['generations'] if g['notebookId'] == NOTEBOOK_ID]
    active = [g for g in gens if g['state'] == 'active']
    done = lambda gid: [m for m in world['manifest'] if m['generationId'] == gid and m['state'] == 'done'
                        and m['sourceId'] in usable]
    if active:
        g = active[0]
        if model_key(g) != selection:
            return None, {}
        return g, {m['sourceId']: m['revisionId'] for m in done(g['id'])}
    candidates = sorted((g for g in gens if g['state'] == 'building' and model_key(g) == selection),
                        key=lambda g: -g['id'])
    if not candidates:
        return None, {}
    g = candidates[0]
    revisions = {m['sourceId']: m['revisionId'] for m in done(g['id'])
                 if sources[m['sourceId']]['publishedRevisionId'] == m['revisionId']}
    return (g, revisions) if revisions else (None, {})


def expect(case: dict, data: dict) -> dict:
    sources = {s['id']: s for s in data['sources']}
    chunks = {c['id']: c for c in data['chunks']}
    g, revisions = pin(case, sources)
    lexical = sorted(c['id'] for c in data['chunks']
                     if QUERY in c['text'].split()
                     and sources[c['sourceId']]['availability'] == 'present'
                     and sources[c['sourceId']]['eligible'] == 1
                     and sources[c['sourceId']]['publishedRevisionId'] == c['revisionId'])[:FETCH_K]
    provider = case['provider']
    if g is None:
        status, calls, query = 'noActiveGeneration', 0, None
    elif case['sessionEndpointRevision'] != g['endpointRevision']:
        status, calls, query = 'endpointRevisionMismatch', 0, None
    elif provider['kind'] == 'failure':
        status, calls, query = 'embeddingFailed', 1, None
    elif len(provider['vector']) != g['dims'] or not any(provider['vector']):
        status, calls, query = 'invalidQueryVector', 1, None
    else:
        status, calls, query = 'used', 1, provider['vector']
    vector = []
    if query is not None:
        scored = []
        for e in case['embeddings']:
            c = chunks[e['chunkId']]
            if e['generationId'] == g['id'] and revisions.get(c['sourceId']) == c['revisionId']:
                scored.append((-cosine(query, e['vector']), c['id']))
        vector = [cid for _, cid in sorted(scored)[:FETCH_K]]
    return dict(generationId=g['id'] if g else None, generationState=g['state'] if g else None,
                vectorRevisions=[dict(sourceId=s, revisionId=revisions[s]) for s in sorted(revisions)],
                vectorStatus=status, embedCalls=calls, embeddingError=status == 'embeddingFailed',
                lexicalChunkIds=lexical, vectorChunkIds=vector, fused=rrf(lexical, vector))


def build() -> dict:
    data = seed()
    for c in data['chunks']:
        assert len(c['text'].split()) == 3, c  # equal bm25 for every one-token match
    cases = []
    for raw in raw_cases():
        c = copy.deepcopy(raw)
        c['expected'] = expect(c, data)
        cases.append(c)
    return dict(contract=CONTRACT, version=VERSION, notebookId=NOTEBOOK_ID, query=QUERY, fetchK=FETCH_K,
                rrfK=RRF_K, selection=SELECTION, seed=data, cases=cases)


def render(fixture: dict) -> bytes:
    return (json.dumps(fixture, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Compare generated bytes without writing.')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[2] / OUTPUT
    data = render(build())
    if args.check:
        if not path.is_file() or path.read_bytes() != data:
            print('out of date: ' + OUTPUT)
            return 1
        print('ok')
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    print('wrote ' + OUTPUT)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
