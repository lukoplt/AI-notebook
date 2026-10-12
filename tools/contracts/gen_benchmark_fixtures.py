#!/usr/bin/env python3
"""WP7 benchmark reference: shared fixtures plus the three production resources.

Standard library only. Integer arithmetic for every frozen number; vector
expectations are integer millionths computed in IEEE double. Writes

    Tests/fixtures/contracts/{embedding-profiles,embedding-strict,benchmark-report,
        benchmark-run,embedding-default,token-calibration-session}-v1.json,
        token-estimate-v2.json
    Sources/AINotebookCore/Resources/Benchmark/{embedding-profiles-v1,
        token-estimate-v2,embedding-decision-v1}.json

    python3 -B tools/contracts/gen_benchmark_fixtures.py          # rewrite
    python3 -B tools/contracts/gen_benchmark_fixtures.py --check  # byte compare, never writes

Normative prose: docs/contracts/benchmark-v1.md. Every response, digest,
token count and timing below is synthetic test data for fake transports and
fixed clocks. Nothing here is a measurement of a real model or machine.
`make_contracts()` returns fixture envelopes only; `make_resources()` returns
the production projection, which never contains cases or the `fixture-only`
family. The WP8 pack reference (`gen_fixtures.py`) is imported read-only to
compute builder outputs under an injected estimator/tuning.
"""

import argparse
import copy
import hashlib
import importlib.util
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Tests' / 'fixtures' / 'contracts'
RES = ROOT / 'Sources' / 'AINotebookCore' / 'Resources' / 'Benchmark'

INT32_MAX = 2_147_483_647
INT64_MAX = 9_223_372_036_854_775_807
LANGUAGES = ('cs', 'de', 'en', 'sk', 'und', 'mixed')
BODY_LANGUAGES = ('cs', 'de', 'en', 'sk')
MIXED_ORDER = ('cs', 'sk', 'en', 'de')
CASE_TYPES = ('answer', 'exact_identifier', 'scope', 'absent', 'empty_selection', 'overview')
METRICS = ('lexical_recall_at_top_k', 'lexical_recall_at_fetch_k', 'hybrid_recall_at_top_k',
           'candidate_recall_at_fetch_k', 'packed_evidence_recall')
FIXTURE_FAMILY = 'fixture-only'
HEADROOM_BP = 1500
MAX_RATE_BP = 1_000_000
MAX_SCALARS = 5_000_000
STRICT_TOO_LONG = 'the input length exceeds the context length'
BACKEND = 'fts-or-pinned-rrf-v1'
CACHE_BUDGET_BYTES = 536_870_912
WARM_GATE_US = 300_000
OLLAMA_ROOT = 'http://127.0.0.1:11434'
OLLAMA_PROVIDER_ID = '00000000-0000-0000-0000-000000000000'
CHAT_MODEL = 'llama3.2:3b'


def hex64(ch):
    return ch * 64


def digest(ch):
    return 'sha256:' + hex64(ch)


def sha256_text(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def canonical_json(value):
    """Sorted keys, compact separators, literal UTF-8, JSON-required escapes only."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def render(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')


# ------------------------------------------------------------------ arithmetic

def ceildiv(a, b):
    if a < 0 or b <= 0:
        raise ValueError('invalidCalibration')
    return a // b + (a % b != 0)


def calibrate(samples):
    """Max per-sample ceil(tokens*10000/scalars) over (scalars, tokens) pairs."""
    if not samples or any(s <= 0 or t < 0 for s, t in samples):
        raise ValueError('invalidCalibration')
    return max(ceildiv(t * 10000, s) for s, t in samples)


def estimate(scalars, rate_bp, headroom_bp=HEADROOM_BP):
    return ceildiv(ceildiv(scalars * rate_bp, 10000) * (10000 + headroom_bp), 10000)


def percentile(samples, bp):
    """Nearest rank: sorted[ceil(n*bp/10000)-1]."""
    if not samples or not 0 < bp <= 10000 or min(samples) < 0:
        raise ValueError('invalidSamples')
    return sorted(samples)[ceildiv(len(samples) * bp, 10000) - 1]


def tokens_per_second_milli(tokens, elapsed_us):
    if tokens < 0 or elapsed_us < 0 or tokens > INT64_MAX // 1_000_000_000:
        raise ValueError('invalidSamples')
    return None if elapsed_us == 0 else tokens * 1_000_000_000 // elapsed_us


def warm_gate(chunks, concurrent, queries, p95_us):
    if chunks != 100_000 or concurrent or queries != 200:
        return None
    return p95_us < WARM_GATE_US


def fnv1a32(text):
    h = 2166136261
    for byte in text.encode('utf-8'):
        h = ((h ^ byte) * 16777619) % (1 << 32)
    return h


def ms_to_us(ms):
    """Nearest integer microsecond, ties away from zero (shared CLI conversion)."""
    v = ms * 1000
    return int(math.floor(abs(v) + 0.5)) * (1 if v >= 0 else -1)


def millionths(values):
    return [int(math.floor(abs(x) * 1_000_000 + 0.5)) * (1 if x >= 0 else -1) for x in values]


# --------------------------------------------------------------- token rates

def valid_family(family):
    return isinstance(family, str) and family != '' and not any(ch.isspace() for ch in family)


def validate_rates(rates):
    seen = set()
    for r in rates:
        if (not valid_family(r['family']) or r['language'] not in LANGUAGES
                or not isinstance(r['tokensPerScalarBp'], int)
                or not 0 <= r['tokensPerScalarBp'] <= MAX_RATE_BP):
            raise ValueError('invalidCalibration')
        key = (r['family'], r['language'])
        if key in seen:
            raise ValueError('invalidCalibration')
        seen.add(key)


def fit(training):
    if not training:
        raise ValueError('invalidCalibration')
    ids = set()
    groups = {}
    for s in training:
        if (s['split'] != 'train' or s['id'] in ids or s['language'] not in LANGUAGES
                or not valid_family(s['family']) or not 0 < s['scalars'] <= MAX_SCALARS
                or s['tokens'] is None or s['tokens'] < 0):
            raise ValueError('invalidCalibration')
        ids.add(s['id'])
        groups.setdefault((s['family'], s['language']), []).append((s['scalars'], s['tokens']))
    rates = []
    for (family, language) in sorted(groups, key=lambda k: (list(map(ord, k[0])), list(map(ord, k[1])))):
        rate = calibrate(groups[(family, language)])
        if rate > MAX_RATE_BP:
            raise ValueError('invalidCalibration')
        rates.append(dict(family=family, language=language, tokensPerScalarBp=rate))
    return rates


def family_rate(family, language, rates):
    rows = [r for r in rates if r['family'] == family]
    exact = [r['tokensPerScalarBp'] for r in rows if r['language'] == language]
    if exact:
        return exact[0]
    return max((r['tokensPerScalarBp'] for r in rows), default=None)


def estimate_text(text, language, family, rates):
    """TokenEstimatorV2.estimate reference; unknown family is the UTF-8 fallback."""
    rate = family_rate(family, language, rates)
    if rate is not None:
        n = len(text)
        if n > MAX_SCALARS:
            return INT32_MAX
        base = ceildiv(n * rate, 10000)
    else:
        base = len(text.encode('utf-8'))
    if base > INT32_MAX // 2:
        return INT32_MAX
    return min(INT32_MAX, ceildiv(base * (10000 + HEADROOM_BP), 10000))


def undercount_rows(samples, rates):
    out = []
    for s in samples:
        rate = family_rate(s['family'], s['language'], rates)
        if rate is None:
            raise ValueError('uncalibratedFamily')
        est = estimate(s['scalars'], rate)
        out.append(dict(id=s['id'], estimated=est, actual=s['tokens'], undercount=max(0, s['tokens'] - est)))
    return out


def resolve_family(model, model_digest, bindings):
    if model_digest is None:
        return None
    for b in bindings:
        if b['model'] == model and b['modelDigest'] == model_digest:
            return b['family']
    return None


def payload_hash(bindings, rates, provenance):
    return hashlib.sha256(canonical_json(dict(bindings=bindings, provenance=provenance, rates=rates))
                          .encode('utf-8')).hexdigest()


def estimate_resource(status='pending', bindings=(), rates=(), provenance=()):
    bindings, rates, provenance = list(bindings), list(rates), list(provenance)
    return dict(contract='token-estimate', version=2, status=status,
                payloadHash=payload_hash(bindings, rates, provenance),
                bindings=bindings, rates=rates, provenance=provenance)


def validate_estimate_resource(resource, production):
    if resource.get('contract') != 'token-estimate' or resource.get('version') != 2:
        raise ValueError('invalidCalibration')
    if resource['payloadHash'] != payload_hash(resource['bindings'], resource['rates'], resource['provenance']):
        raise ValueError('invalidCalibration')
    validate_rates(resource['rates'])
    if resource['status'] == 'pending':
        if resource['bindings'] or resource['rates'] or resource['provenance']:
            raise ValueError('invalidCalibration')
    elif resource['status'] != 'calibrated':
        raise ValueError('invalidCalibration')
    families = {r['family'] for r in resource['rates']}
    pairs = set()
    for b in resource['bindings']:
        if not is_digest(b['modelDigest']) or b['family'] not in families or (b['model'], b['modelDigest']) in pairs:
            raise ValueError('invalidCalibration')
        pairs.add((b['model'], b['modelDigest']))
    if production and FIXTURE_FAMILY in families | {b['family'] for b in resource['bindings']}:
        raise ValueError('invalidCalibration')


def is_hex64(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def is_digest(value):
    return isinstance(value, str) and value.startswith('sha256:') and is_hex64(value[7:])


def normalize_digest(value):
    if is_hex64(value):
        return 'sha256:' + value
    return value if is_digest(value) else None


# ------------------------------------------------------------------ profiles

PROFILE_ROWS = [
    # id, model, tokenizerId, native, dims, ceiling, query prefix, doc prefix, matryoshka, ceiling source
    ('nomic-v2-256', 'nomic-embed-text-v2-moe', 'nomic-ai/nomic-embed-text-v2-moe', 768, 256, 512,
     'search_query: ', 'search_document: ', True, 'model-card'),
    ('nomic-v2-768', 'nomic-embed-text-v2-moe', 'nomic-ai/nomic-embed-text-v2-moe', 768, 768, 512,
     'search_query: ', 'search_document: ', True, 'model-card'),
    ('qwen3-06b-256', 'qwen3-embedding:0.6b', 'Qwen/Qwen3-Embedding-0.6B', 1024, 256, 32768,
     'Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:', '',
     True, 'model-card'),
    ('qwen3-06b-512', 'qwen3-embedding:0.6b', 'Qwen/Qwen3-Embedding-0.6B', 1024, 512, 32768,
     'Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:', '',
     True, 'model-card'),
    ('qwen3-06b-1024', 'qwen3-embedding:0.6b', 'Qwen/Qwen3-Embedding-0.6B', 1024, 1024, 32768,
     'Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:', '',
     True, 'model-card'),
    ('bge-m3-1024', 'bge-m3', 'BAAI/bge-m3', 1024, 1024, 8192, '', '', False, 'model-card'),
    ('paraphrase-768', 'paraphrase-multilingual',
     'sentence-transformers/paraphrase-multilingual-mpnet-base-v2', 768, 768, 512, '', '', False, 'ollama-512'),
]

PROFILES = [dict(id=i, model=m, tokenizerId=t, nativeDims=n, dims=d, maxInputTokens=c, queryPrefix=q,
                 documentPrefix=p, matryoshka=mat, ceilingSource=src)
            for i, m, t, n, d, c, q, p, mat, src in PROFILE_ROWS]
PROFILE_BY_ID = {p['id']: p for p in PROFILES}
PROFILE_ORDER = [p['id'] for p in PROFILES]


def format_input(profile, text, purpose):
    return (profile['queryPrefix'] if purpose == 'query' else profile['documentPrefix']) + text


def format_version(profile_id, purpose, limit):
    return f'wp7:{profile_id}:{purpose}:split1:scalarpool1:prefixl2:ctx{limit}'


def identity_for(profile_id, endpoint_revision, model_digest, limit, provider_id=OLLAMA_PROVIDER_ID):
    p = PROFILE_BY_ID[profile_id]
    return dict(providerId=provider_id, endpointRevision=endpoint_revision, model=p['model'],
                modelDigest=model_digest, dims=p['dims'], normalization='l2',
                queryFormatVersion=format_version(profile_id, 'query', limit),
                docFormatVersion=format_version(profile_id, 'document', limit), chunkerVersion='2')


def endpoint_revision(ptype, root):
    return hashlib.sha256((ptype + '\n' + root).encode('utf-8')).hexdigest()


def vec(values):
    """Encode nonfinite test inputs as string sentinels, never as JSON number tokens."""
    out = []
    for v in values:
        if isinstance(v, float) and math.isnan(v):
            out.append('NaN')
        elif isinstance(v, float) and math.isinf(v):
            out.append('Infinity' if v > 0 else '-Infinity')
        else:
            out.append(v)
    return out


def unvec(values):
    return [float(v) if isinstance(v, str) else float(v) for v in values]


def project(vector, native, dims):
    v = unvec(vector)
    if len(v) != native or dims <= 0 or dims > native or not all(math.isfinite(x) for x in v):
        raise ValueError('invalidEmbedding')
    head = v[:dims]
    norm = math.sqrt(sum(x * x for x in head))
    if not math.isfinite(norm) or norm == 0:
        raise ValueError('invalidEmbedding')
    return [x / norm for x in head]


def pool(vectors, weights):
    if (not vectors or len(vectors) != len(weights) or not vectors[0]
            or any(w <= 0 for w in weights)):
        raise ValueError('invalidEmbedding')
    vs = [unvec(v) for v in vectors]
    if any(len(v) != len(vs[0]) or not all(math.isfinite(x) for x in v) for v in vs):
        raise ValueError('invalidEmbedding')
    total = [0.0] * len(vs[0])
    for v, w in zip(vs, weights):
        for d in range(len(total)):
            total[d] += v[d] * w
    norm = math.sqrt(sum(x * x for x in total))
    if not math.isfinite(norm) or norm == 0:
        raise ValueError('invalidEmbedding')
    return [x / norm for x in total]


def bisect(text):
    if len(text) < 2:
        raise ValueError('inputCannotFit')
    n = len(text) // 2
    return text[:n], text[n:]


def expect(fn, *args):
    try:
        return dict(expected=fn(*args))
    except ValueError as error:
        return dict(error=str(error))


def profiles_fixture():
    cases = []
    for p in PROFILES:
        for name, purpose, text in (('query-cs', 'query', 'Kdo ručí?'), ('document-sk', 'document', 'Záruka platí.')):
            cases.append(dict(name=f"{p['id']}-{name}", kind='format', profileId=p['id'], purpose=purpose,
                              text=text, expected=format_input(p, text, purpose),
                              formatVersion=format_version(p['id'], purpose, p['maxInputTokens'])))
    for pid, limit in (('qwen3-06b-512', 8192), ('bge-m3-1024', 4096), ('nomic-v2-256', 512)):
        cases.append(dict(name=f'{pid}-ctx{limit}', kind='formatVersion', profileId=pid, effectiveLimit=limit,
                          query=format_version(pid, 'query', limit), document=format_version(pid, 'document', limit)))
    cases += [
        dict(name='unknown-profile', kind='require', profileId='nomic-v2-128', error='unknownProfile'),
        dict(name='unknown-profile-model-spelling', kind='require', profileId='nomic-embed-text-v2-moe',
             error='unknownProfile'),
        dict(name='identity-ok', kind='identity', profileId='nomic-v2-256', model='nomic-embed-text-v2-moe',
             dims=256, queryFormatVersion=format_version('nomic-v2-256', 'query', 512),
             docFormatVersion=format_version('nomic-v2-256', 'document', 512), error=None),
        dict(name='wrong-dims', kind='identity', profileId='nomic-v2-256', model='nomic-embed-text-v2-moe',
             dims=768, queryFormatVersion=format_version('nomic-v2-256', 'query', 512),
             docFormatVersion=format_version('nomic-v2-256', 'document', 512), error='profileIdentityMismatch'),
        dict(name='wrong-model', kind='identity', profileId='bge-m3-1024', model='bge-m3:latest',
             dims=1024, queryFormatVersion=format_version('bge-m3-1024', 'query', 8192),
             docFormatVersion=format_version('bge-m3-1024', 'document', 8192), error='profileIdentityMismatch'),
        dict(name='mixed-context', kind='identity', profileId='qwen3-06b-256', model='qwen3-embedding:0.6b',
             dims=256, queryFormatVersion=format_version('qwen3-06b-256', 'query', 8192),
             docFormatVersion=format_version('qwen3-06b-256', 'document', 4096), error='profileIdentityMismatch'),
        dict(name='context-above-ceiling', kind='identity', profileId='paraphrase-768',
             model='paraphrase-multilingual', dims=768,
             queryFormatVersion=format_version('paraphrase-768', 'query', 1024),
             docFormatVersion=format_version('paraphrase-768', 'document', 1024), error='profileIdentityMismatch'),
    ]
    vector_cases = [
        ('nomic-project', 'project', dict(vector=[3, 4, 12], nativeDims=3, dims=2)),
        ('project-full-dims', 'project', dict(vector=[0, 3, 4], nativeDims=3, dims=3)),
        ('project-zero', 'project', dict(vector=[0, 0], nativeDims=2, dims=2)),
        ('project-zero-prefix', 'project', dict(vector=[0, 0, 5], nativeDims=3, dims=2)),
        ('project-nan', 'project', dict(vector=vec([float('nan'), 1]), nativeDims=2, dims=2)),
        ('project-infinity', 'project', dict(vector=vec([float('inf'), 1]), nativeDims=2, dims=2)),
        ('project-wrong-length', 'project', dict(vector=[1, 2, 3], nativeDims=2, dims=2)),
        ('project-dims-above-native', 'project', dict(vector=[1, 2], nativeDims=2, dims=3)),
        ('pool', 'pool', dict(vectors=[[1, 0], [0, 1]], scalarWeights=[1, 2])),
        ('pool-zero-sum', 'pool', dict(vectors=[[1, 0], [-1, 0]], scalarWeights=[1, 1])),
        ('pool-nonfinite', 'pool', dict(vectors=[[1, 0], vec([float('-inf'), 0])], scalarWeights=[1, 1])),
        ('pool-wrong-length', 'pool', dict(vectors=[[1, 0], [1]], scalarWeights=[1, 1])),
        ('pool-zero-weight', 'pool', dict(vectors=[[1, 0], [0, 1]], scalarWeights=[0, 1])),
        ('pool-count-mismatch', 'pool', dict(vectors=[[1, 0]], scalarWeights=[1, 1])),
        ('pool-empty', 'pool', dict(vectors=[], scalarWeights=[])),
    ]
    for name, kind, inp in vector_cases:
        try:
            out = project(inp['vector'], inp['nativeDims'], inp['dims']) if kind == 'project' \
                else pool(inp['vectors'], inp['scalarWeights'])
            cases.append(dict(name=name, kind=kind, **inp, expectedMillionths=millionths(out)))
        except ValueError as error:
            cases.append(dict(name=name, kind=kind, **inp, error=str(error)))
    for name, text in (('bisect-astral', 'ab😀cd'), ('bisect-astral-left', '😀😀😀'), ('bisect-one', 'a'),
                       ('bisect-empty', '')):
        try:
            left, right = bisect(text)
            cases.append(dict(name=name, kind='bisect', text=text, left=left, right=right))
        except ValueError as error:
            cases.append(dict(name=name, kind='bisect', text=text, error=str(error)))
    return dict(contract='embedding-profiles', version=1,
                formatPolicy='wp7:<profileId>:<purpose>:split1:scalarpool1:prefixl2:ctx<effectiveLimit>',
                vectorSentinels=['NaN', 'Infinity', '-Infinity'],
                profiles=copy.deepcopy(PROFILES), cases=cases)


# ------------------------------------------------------------ strict inputs

FIXTURE_PROFILE = dict(id='fixture', model='fixture', tokenizerId=FIXTURE_FAMILY, queryPrefix='q:',
                       documentPrefix='', nativeDims=2, dims=2, maxInputTokens=5, matryoshka=False)


def ok(inp, vector, tokens):
    return dict(input=inp, outcome='ok', vector=vec(vector), promptTokens=tokens)


def rejected(inp):
    return dict(input=inp, outcome='lengthRejected')


def strict_reference(case):
    """Execute the frozen recursion against the scripted transport (see benchmark-v1 §3)."""
    profile, purpose, limit = case['profile'], case['purpose'], case['effectiveLimit']
    script = list(case['exchanges'])
    counter = case.get('counter')
    events, leaves, counter_calls = [], [], []
    state = dict(rejected=0)
    text = case['text']

    def emit(kind, **fields):
        events.append(dict(kind=kind, purpose=purpose, tokens=fields.get('tokens'),
                           start=fields.get('start'), end=fields.get('end')))

    def visit(raw, start):
        formatted = format_input(profile, raw, purpose)
        exchange = script.pop(0)
        assert exchange['input'] == formatted, (case['name'], exchange['input'], formatted)
        emit('request')
        outcome = exchange['outcome']
        if outcome == 'cancel':
            raise ValueError('cancelled')
        if outcome == 'httpError':
            raise ValueError('providerError')
        if outcome == 'lengthRejected':
            state['rejected'] += 1
            emit('lengthRejected')
        else:
            projected = project(exchange['vector'], profile['nativeDims'], profile['dims'])
            native = exchange.get('promptTokens')
            if native is not None and native < 0:
                raise ValueError('invalidTokenCount')
            emit('response', tokens=native)
            if native is not None:
                count = native
            elif counter is not None and formatted in counter:
                counter_calls.append(dict(text=formatted, tokenizerId=profile['tokenizerId']))
                count = counter[formatted]
            else:
                raise ValueError('tokenCountUnavailable')
            if count < 0:
                raise ValueError('invalidTokenCount')
            if count <= limit:
                end = start + len(raw)
                leaves.append((projected, dict(start=start, end=end, tokens=count)))
                emit('partAccepted', tokens=count, start=start, end=end)
                return
        left, right = bisect(raw)
        visit(left, start)
        visit(right, start + len(left))

    result = dict(events=events, counterCalls=counter_calls)
    try:
        if text == '':
            raise ValueError('emptyInput')
        if not 1 <= limit <= profile['maxInputTokens']:
            raise ValueError('invalidEffectiveLimit')
        visit(text, 0)
        pooled = pool([v for v, _ in leaves], [p['end'] - p['start'] for _, p in leaves])
        result.update(parts=[p for _, p in leaves], successfulTokens=sum(p['tokens'] for _, p in leaves),
                      rejectedRequests=state['rejected'], vectorMillionths=millionths(pooled), error=None)
    except ValueError as error:
        result.update(error=str(error))
    assert not script, (case['name'], 'unconsumed exchanges')
    result['requestCount'] = sum(1 for e in events if e['kind'] == 'request')
    result['telemetry'] = telemetry_snapshot(events, purpose)
    return result


def telemetry_snapshot(events, purpose):
    rows = [e for e in events if e['purpose'] == purpose]
    requests = sum(1 for e in rows if e['kind'] == 'request')
    counted = [e['tokens'] for e in rows if e['kind'] == 'response' and e['tokens'] is not None]
    uncounted = requests - len(counted)
    status = 'measured' if uncounted == 0 else ('partial' if counted else 'not_available')
    accepted = [e for e in rows if e['kind'] == 'partAccepted']
    return dict(serviceTokens=sum(counted) if uncounted == 0 else None,
                successfulTokens=sum(e['tokens'] for e in accepted), requestCount=requests,
                rejectedRequests=sum(1 for e in rows if e['kind'] == 'lengthRejected'),
                splitParts=len(accepted), uncountedRequests=uncounted, serviceTokenStatus=status)


def pipeline_case(name, text, exchanges, purpose='query', limit=5, profile=None, counter=None, note=None):
    case = dict(name=name, kind='pipeline', profile=copy.deepcopy(profile or FIXTURE_PROFILE), purpose=purpose,
                text=text, effectiveLimit=limit, exchanges=exchanges, counter=counter)
    if note:
        case['note'] = note
    case['expected'] = strict_reference(case)
    return case


def wire(name, call, request, response, expected):
    return dict(name=name, kind='wire', call=call, request=request, response=response, expected=expected)


def embed_body(model, inp, native, limit):
    return dict(model=model, input=[inp], dimensions=native, truncate=False, options=dict(num_ctx=limit))


def ollama_model(name, dgst, family='fixture'):
    return dict(name=name, modified_at='2026-10-09T00:00:00Z', size=1, digest=dgst,
                details=dict(format='gguf', family=family, parameter_size='fixture', quantization_level='fixture'))


def prepare_reference(case):
    """Exact-ID tags lookup, show context, min(profile ceiling, context) — captured root only."""
    provider, profile = case['provider'], PROFILE_BY_ID[case['profileId']]
    root = provider['root']
    requests = []
    if provider['type'] != 'ollama' or not provider['enabled'] or not provider['consented'] \
            or not provider['embeddingCapable']:
        return dict(error='unsupportedEmbeddingProfile', requests=requests, embeddingRequests=0)
    requests.append(dict(method='GET', url=root + '/api/tags', body=None))
    wanted = {profile['model']} | ({profile['model'] + ':latest'} if ':' not in profile['model'] else set())
    matches = [m for m in case['tags']['models'] if m['name'] in wanted]
    if len(matches) != 1 or normalize_digest(matches[0]['digest']) is None:
        return dict(error='embeddingModelUnavailable', requests=requests, embeddingRequests=0)
    model_digest = normalize_digest(matches[0]['digest'])
    requests.append(dict(method='POST', url=root + '/api/show', body=dict(model=profile['model'])))
    info = (case['show'] or {}).get('model_info', {})
    arch = info.get('general.architecture')
    ctx = info.get(f'{arch}.context_length') if isinstance(arch, str) and arch else None
    if not isinstance(ctx, int) or isinstance(ctx, bool) or not 2 <= ctx <= INT32_MAX:
        return dict(error='modelMetadataUnavailable', requests=requests, embeddingRequests=0)
    limit = min(profile['maxInputTokens'], ctx)
    return dict(error=None, requests=requests, embeddingRequests=0, effectiveLimit=limit,
                identity=identity_for(profile['id'], endpoint_revision('ollama', root), model_digest, limit))


def strict_fixture():
    a = FIXTURE_PROFILE
    cases = [
        pipeline_case('fits', 'abc', [ok('q:abc', [1, 0], 5)]),
        pipeline_case('split', 'ab😀cd', [rejected('q:ab😀cd'), ok('q:ab', [1, 0], 4), ok('q:😀cd', [1, 0], 5)],
                      note='typed rejection then accepted children; telemetry 3 requests/2 responses'),
        pipeline_case('three-leaf-unequal-depth', 'abcdefg',
                      [rejected('q:abcdefg'), ok('q:abc', [1, 0], 5), rejected('q:defg'),
                       ok('q:de', [0, 1], 4), ok('q:fg', [1, 0], 4)],
                      note='pool all leaves once by scalar length; never normalize intermediate nodes'),
        pipeline_case('prefix-exhausts', 'ab', [rejected('q:ab'), rejected('q:a')], limit=2),
        pipeline_case('server-limit', 'abcdefgh',
                      [rejected('abcdefgh'), ok('abcd', [0, 1], 4), ok('efgh', [0, 1], 4)], purpose='document'),
        pipeline_case('count-over-limit', 'abcdefgh',
                      [ok('abcdefgh', [1, 0], 8), ok('abcd', [1, 0], 4), ok('efgh', [0, 1], 4)], purpose='document',
                      note='successful response above the ceiling splits; service count kept, no useful tokens'),
        pipeline_case('unrelated-400', 'abc', [dict(input='q:abc', outcome='httpError', status=400,
                                                    body='{"error":"model \\"fixture\\" not found"}')]),
        pipeline_case('http-500', 'abc', [dict(input='q:abc', outcome='httpError', status=500,
                                               body='{"error":"internal"}')]),
        pipeline_case('cancel', 'ab😀cd', [dict(input='q:ab😀cd', outcome='cancel')]),
        pipeline_case('no-count', 'abc', [ok('q:abc', [1, 0], None)], counter={'q:abc': 5}),
        pipeline_case('no-count-no-tokenizer', 'abc', [ok('q:abc', [1, 0], None)]),
        pipeline_case('negative-count', 'abc', [ok('q:abc', [1, 0], -1)]),
        pipeline_case('wrong-dim', 'abc', [ok('q:abc', [1, 0, 0], 5)]),
        pipeline_case('nonfinite', 'abc', [ok('q:abc', [float('nan'), 0], 5)]),
        pipeline_case('empty-input', '', []),
        pipeline_case('limit-above-profile', 'abc', [], limit=6),
    ]
    # Telemetry view of the split case (Task 4/5 collector assertions).
    split = next(c for c in cases if c['name'] == 'split')
    cases.append(dict(name='telemetry-split', kind='telemetry', source='split',
                      events=split['expected']['events'], snapshot=split['expected']['telemetry']))
    over = next(c for c in cases if c['name'] == 'count-over-limit')
    cases.append(dict(name='telemetry-over-limit', kind='telemetry', source='count-over-limit',
                      events=over['expected']['events'], snapshot=over['expected']['telemetry']))

    fixture_call = dict(method='embed', root=OLLAMA_ROOT, model='fixture', input='q:abc', nativeDims=2, inputLimit=5)
    ok_body = dict(model='fixture', embeddings=[[0.6, 0.8]], total_duration=1000, load_duration=0,
                   prompt_eval_count=5)

    def embed_case(name, response, expected, call=None, url=OLLAMA_ROOT + '/api/embed'):
        c = dict(fixture_call, **(call or {}))
        return wire(name, c, dict(method='POST', url=url,
                                  body=embed_body(c['model'], c['input'], c['nativeDims'], c['inputLimit'])),
                    response, expected)
    cases += [
        embed_case('wire-embed', dict(status=200, body=ok_body),
                   dict(vectorMillionths=[600000, 800000], promptTokens=5, totalDurationNs=1000, loadDurationNs=0)),
        embed_case('wire-proxy-root', dict(status=200, body=ok_body),
                   dict(vectorMillionths=[600000, 800000], promptTokens=5, totalDurationNs=1000, loadDurationNs=0),
                   call=dict(root='https://proxy.example/ollama'), url='https://proxy.example/ollama/api/embed'),
        embed_case('wire-profile-request', dict(status=200, body=dict(
            model='nomic-embed-text-v2-moe', embeddings=[[1] + [0] * 767], prompt_eval_count=7)),
            dict(vectorLength=768, firstComponentMillionths=1000000, promptTokens=7, totalDurationNs=None,
                 loadDurationNs=None),
            call=dict(model='nomic-embed-text-v2-moe', input='search_query: Kdo ručí?', nativeDims=768,
                      inputLimit=512)),
        embed_case('wire-missing-count', dict(status=200, body=dict(model='fixture', embeddings=[[0.6, 0.8]])),
                   dict(vectorMillionths=[600000, 800000], promptTokens=None, totalDurationNs=None,
                        loadDurationNs=None)),
        embed_case('wire-length-rejection', dict(status=400, body=dict(error=STRICT_TOO_LONG)),
                   dict(error='inputTooLong')),
        embed_case('wire-unrelated-400', dict(status=400, body=dict(error='the input length exceeds the limit')),
                   dict(error='providerError', status=400)),
        embed_case('wire-413', dict(status=413, body=dict(error=STRICT_TOO_LONG)),
                   dict(error='providerError', status=413)),
        embed_case('wire-401', dict(status=401, body=dict(error='unauthorized')),
                   dict(error='providerError', status=401)),
        embed_case('wire-500', dict(status=500, body=dict(error='internal')), dict(error='providerError', status=500)),
        embed_case('wire-empty-vectors', dict(status=200, body=dict(model='fixture', embeddings=[],
                                                                       prompt_eval_count=5)),
                   dict(error='invalidEmbedding')),
        embed_case('wire-multiple-vectors', dict(status=200, body=dict(
            model='fixture', embeddings=[[0.6, 0.8], [0.6, 0.8]], prompt_eval_count=5)),
            dict(error='invalidEmbedding')),
        embed_case('wire-wrong-dimension', dict(status=200, body=dict(
            model='fixture', embeddings=[[0.6, 0.8, 0]], prompt_eval_count=5)), dict(error='invalidEmbedding')),
        embed_case('wire-negative-count', dict(status=200, body=dict(
            model='fixture', embeddings=[[0.6, 0.8]], prompt_eval_count=-1)), dict(error='invalidTokenCount')),
        embed_case('wire-fractional-count', dict(status=200, body=dict(
            model='fixture', embeddings=[[0.6, 0.8]], prompt_eval_count=1.5)), dict(error='invalidTokenCount')),
        embed_case('wire-malformed', dict(status=200, bodyText='{"embeddings":'), dict(error='invalidResponse')),
    ]
    raw_options = dict(runtimeContext=8192, maxOutputTokens=1)
    raw_request = dict(method='POST', url=OLLAMA_ROOT + '/api/generate',
                       body=dict(model=CHAT_MODEL, prompt='Záruka platí.', raw=True, stream=False,
                                 options=dict(num_ctx=8192, num_predict=1, temperature=0)))
    raw_call = dict(method='observeRaw', root=OLLAMA_ROOT, model=CHAT_MODEL, text='Záruka platí.', options=raw_options)
    messages = [dict(role='system', content='rules'), dict(role='user', content='[SCOPE]\nScope\n[/SCOPE]\n\nQ')]
    cases += [
        wire('raw-calibration', raw_call, raw_request,
             dict(status=200, body=dict(model=CHAT_MODEL, response='x', done=True, prompt_eval_count=6,
                                        eval_count=1)),
             dict(text='x', promptTokens=6, outputTokens=1, method='ollama-raw-prompt')),
        wire('raw-missing-count', raw_call, raw_request,
             dict(status=200, body=dict(model=CHAT_MODEL, response='x', done=True)),
             dict(text='x', promptTokens=None, outputTokens=None, method='documented-tokenizer',
                  fallbackRequest=dict(requestId='raw-missing-count', tokenizerId='fixture-chat-tokenizer',
                                       text='Záruka platí.'),
                  fallbackResponse=dict(requestId='raw-missing-count', tokens=7, tokenizerId='fixture-chat-tokenizer',
                                        revision='fixture-revision', assetsSha256=hex64('c')),
                  observedTokens=7)),
        wire('raw-negative-count', raw_call, raw_request,
             dict(status=200, body=dict(model=CHAT_MODEL, response='x', done=True, prompt_eval_count=-1,
                                        eval_count=1)),
             dict(error='invalidTokenCount')),
        wire('chat-full-prompt', dict(method='observeChat', root=OLLAMA_ROOT, model=CHAT_MODEL, messages=messages,
                                      options=raw_options),
             dict(method='POST', url=OLLAMA_ROOT + '/api/chat',
                  body=dict(model=CHAT_MODEL, messages=messages, stream=False,
                            options=dict(num_ctx=8192, num_predict=1, temperature=0))),
             dict(status=200, body=dict(model=CHAT_MODEL, message=dict(role='assistant', content='[1]'), done=True,
                                        prompt_eval_count=40, eval_count=1)),
             dict(text='[1]', promptTokens=40, outputTokens=1, method='ollama-chat-prompt')),
    ]

    # Captured-profile preparation (Task 4/5 prepareEmbeddingProfile).
    provider = dict(id=OLLAMA_PROVIDER_ID, type='ollama', root=OLLAMA_ROOT, enabled=True, consented=True,
                    embeddingCapable=True)

    def prep(name, profile_id, models, show, provider_patch=None, mutations=None, note=None):
        c = dict(name=name, kind='prepare', provider=dict(provider, **(provider_patch or {})), profileId=profile_id,
                 tags=dict(models=models), show=show, mutations=mutations or [])
        if note:
            c['note'] = note
        c['expected'] = prepare_reference(c)
        return c

    def show(arch, ctx):
        return dict(model_info={'general.architecture': arch, f'{arch}.context_length': ctx})
    cases += [
        prep('prepare-profile', 'qwen3-06b-512', [ollama_model('qwen3-embedding:0.6b', hex64('1'))],
             show('qwen3', 40960), note='context above the profile ceiling is capped at 32768'),
        prep('prepare-profile-context-cap', 'bge-m3-1024', [ollama_model('bge-m3:latest', hex64('2'))],
             show('bert', 4096)),
        prep('prepare-profile-root-change', 'nomic-v2-256',
             [ollama_model('nomic-embed-text-v2-moe:latest', hex64('3'))], show('nomic-bert-moe', 2048),
             mutations=[dict(after='tags', field='root', value='http://10.0.0.2:11434')],
             note='settings change after /api/tags; /api/show and every embed stay on the captured root'),
        prep('prepare-profile-no-model', 'bge-m3-1024', [ollama_model('bge-m3-large:latest', hex64('4'))], None),
        prep('prepare-profile-no-context', 'bge-m3-1024', [ollama_model('bge-m3', hex64('4'))],
             dict(model_info={'general.architecture': 'bert'})),
        prep('prepare-profile-invalid-context', 'bge-m3-1024', [ollama_model('bge-m3', hex64('4'))],
             show('bert', 1)),
        prep('prepare-profile-chat-only', 'bge-m3-1024', [], None, provider_patch=dict(embeddingCapable=False),
             note='converted chat-only provider; never substitutes another provider'),
        prep('prepare-profile-remote-type', 'bge-m3-1024', [], None,
             provider_patch=dict(type='openai', root='https://api.openai.com/v1')),
        prep('latest-alias-exact', 'nomic-v2-768', [ollama_model('nomic-embed-text-v2-moe:latest', hex64('5'))],
             show('nomic-bert-moe', 2048), note='an untagged profile model equals only its explicit :latest alias'),
        prep('latest-alias-no-substring', 'nomic-v2-768',
             [ollama_model('nomic-embed-text-v2-moe:q8_0', hex64('5')),
              ollama_model('nomic-embed-text-v2-moe-latest', hex64('6'))], None),
        prep('tagged-model-no-substring', 'qwen3-06b-256', [ollama_model('qwen3-embedding:0.6b-q8_0', hex64('7')),
                                                            ollama_model('qwen3-embedding:latest', hex64('8'))], None),
        prep('duplicate-model-rows', 'bge-m3-1024', [ollama_model('bge-m3', hex64('4')),
                                                     ollama_model('bge-m3:latest', hex64('9'))], None),
        prep('prefixed-digest', 'bge-m3-1024', [ollama_model('bge-m3', digest('a'))], show('bert', 8192)),
        prep('truncated-digest', 'bge-m3-1024', [ollama_model('bge-m3', 'a' * 12)], None),
    ]
    resume_identity = identity_for('nomic-v2-256', endpoint_revision('ollama', OLLAMA_ROOT), digest('3'), 512)
    for name, models, error in (
            ('resume-digest-same', [ollama_model('nomic-embed-text-v2-moe:latest', hex64('3'))], None),
            ('resume-digest-changed', [ollama_model('nomic-embed-text-v2-moe:latest', hex64('d'))],
             'embeddingModelChanged'),
            ('resume-digest-missing', [ollama_model('nomic-embed-text-v2-moe:latest', '')], 'embeddingModelChanged'),
            ('resume-model-removed', [], 'embeddingModelChanged')):
        cases.append(dict(name=name, kind='resume', identity=resume_identity, tags=dict(models=models),
                          expected=dict(error=error, requests=[dict(method='GET', url=OLLAMA_ROOT + '/api/tags',
                                                                    body=None)],
                                        embeddingRequests=0, effectiveLimit=None if error else 512,
                                        note='ctx suffix is parsed from the stored identity; never re-probed')))
    cases.append(dict(name='publish-digest-changed', kind='publish', identity=resume_identity,
                      tags=dict(models=[ollama_model('nomic-embed-text-v2-moe:latest', hex64('d'))]),
                      expected=dict(error='embeddingModelChanged', activated=False, activeGenerationUnchanged=True)))
    cases.append(dict(name='publish-digest-same', kind='publish', identity=resume_identity,
                      tags=dict(models=[ollama_model('nomic-embed-text-v2-moe:latest', hex64('3'))]),
                      expected=dict(error=None, activated=True, activeGenerationUnchanged=False)))
    return dict(contract='embedding-strict', version=1, lengthRejectionError=STRICT_TOO_LONG,
                fixtureProfile=copy.deepcopy(a), vectorSentinels=['NaN', 'Infinity', '-Infinity'], cases=cases)


# ------------------------------------------------------------ calibration

def sample_plan(documents, queries):
    """Frozen train/holdout partition and sample windows (benchmark-v1 §5.2)."""
    partition, samples, windows = {}, [], {}
    for language in BODY_LANGUAGES:
        docs = sorted((d for d in documents if d['language'] == language),
                      key=lambda d: list(map(ord, d['document_id'])))
        for index, d in enumerate(docs):
            split = 'train' if index % 4 < 3 else 'holdout'
            partition[d['document_id']] = split
            text, n = d['text'], len(d['text'])
            spans = [(s, min(s + 256, n)) for s in range(0, n, 256)]
            for s, e in spans:
                windows.setdefault((language, split), []).append((d, s, e))
            if 256 < n <= 1024:
                spans.append((0, n))
            for s, e in spans:
                body = text[s:e]
                samples.append(dict(id=f"{d['document_id']}:{s}:{e}", language=language, split=split,
                                    documentId=d['document_id'], start=s, end=e, scalars=len(body),
                                    utf8Bytes=len(body.encode('utf-8')), kind='body', sources=None))
    for q in sorted(queries, key=lambda q: list(map(ord, q['query_id']))):
        if q['case_type'] not in ('answer', 'exact_identifier') or not q['gold_document_ids'] \
                or q['language'] not in BODY_LANGUAGES or q['text'] == '':
            continue
        splits = {partition.get(d) for d in q['gold_document_ids']}
        split = splits.pop() if len(splits) == 1 and None not in splits else 'holdout'
        n = len(q['text'])
        samples.append(dict(id=f"query:{q['query_id']}:0:{n}", language=q['language'], split=split,
                            documentId=f"query:{q['query_id']}", start=0, end=n, scalars=n,
                            utf8Bytes=len(q['text'].encode('utf-8')), kind='query', sources=None))
    for split in ('train', 'holdout'):
        lists = [windows.get((language, split), []) for language in MIXED_ORDER]
        for j in range(min(len(x) for x in lists)):
            parts = [x[j] for x in lists]
            body = '\n'.join(d['text'][s:e] for d, s, e in parts)
            ids = [f"{d['document_id']}:{s}:{e}" for d, s, e in parts]
            samples.append(dict(id='+'.join(ids), language='mixed', split=split, documentId=None, start=None,
                                end=None, scalars=len(body), utf8Bytes=len(body.encode('utf-8')), kind='mixed',
                                sources=ids))
    samples.sort(key=lambda s: list(map(ord, s['id'])))
    return samples


def calibration_report(status, method, family, samples, rates, prompt_checks, error_code=None, digest_value=None,
                       tokenizer=(None, None, None), platform='macos'):
    holdout = [s for s in samples if s['split'] == 'holdout']
    measured = all(s['tokens'] is not None for s in samples)
    if measured and rates:
        rows = undercount_rows([dict(s, family=family) for s in holdout], rates)
        body_under = sum(1 for r in rows if r['undercount'] > 0)
        over = [r['estimated'] - r['actual'] for r in rows]
    else:
        body_under, over = None, []
    prompts = [p for p in prompt_checks if p['split'] == 'holdout']
    if measured and all(p['actualTokens'] is not None for p in prompts):
        prompt_under = sum(1 for p in prompts if p['actualTokens'] > p['estimatedTokens'])
        over += [p['estimatedTokens'] - p['actualTokens'] for p in prompts]
    else:
        prompt_under = None
    complete = status == 'complete'
    calibrated = (complete and body_under == 0 and prompt_under == 0 and bool(holdout) and bool(prompts))
    tid, trev, tsha = tokenizer
    return dict(contract='token-calibration-report', version=1, status=status, corpusHash=sha256_text('wp7-cal-corpus'),
                platform=platform, model=CHAT_MODEL, modelDigest=digest_value or digest('a'),
                ollamaVersion='0.0.0-fixture', showTemplateSha256=hex64('e'), family=family, method=method,
                tokenizerId=tid, tokenizerRevision=trev, tokenizerAssetsSha256=tsha,
                samples=[{k: s[k] for k in ('id', 'language', 'split', 'documentId', 'start', 'end', 'scalars',
                                            'utf8Bytes', 'tokens')} for s in samples],
                rates=rates, headroomBp=HEADROOM_BP, promptChecks=prompt_checks,
                bodyHoldoutUndercounts=body_under, promptHoldoutUndercounts=prompt_under,
                maxOverestimateTokens=(max(0, max(over)) if over else 0) if body_under is not None else None,
                calibrated=calibrated, errorCode=error_code)


def validate_calibration_report(r):
    if r['contract'] != 'token-calibration-report' or r['version'] != 1 or r['status'] not in ('complete', 'incomplete') \
            or r['headroomBp'] != HEADROOM_BP:
        raise ValueError('invalidCalibration')
    if r['method'] == 'ollama-raw-prompt':
        if any(r[k] is not None for k in ('tokenizerId', 'tokenizerRevision', 'tokenizerAssetsSha256')) \
                or r['family'] != 'ollama:' + r['modelDigest']:
            raise ValueError('invalidCalibration')
    elif r['method'] == 'documented-tokenizer':
        if not r['tokenizerId'] or not r['tokenizerRevision'] or not is_hex64(r['tokenizerAssetsSha256']) \
                or r['family'] != f"hf:{r['tokenizerId']}@{r['tokenizerRevision']}:{r['tokenizerAssetsSha256']}":
            raise ValueError('invalidCalibration')
    else:
        raise ValueError('invalidCalibration')
    if not is_digest(r['modelDigest']) or not is_hex64(r['corpusHash']) or not is_hex64(r['showTemplateSha256']):
        raise ValueError('invalidCalibration')
    ids = [s['id'] for s in r['samples']]
    if len(ids) != len(set(ids)) or ids != sorted(ids, key=lambda x: list(map(ord, x))):
        raise ValueError('invalidCalibration')
    if r['status'] == 'incomplete':
        if not r['errorCode'] or r['calibrated']:
            raise ValueError('invalidCalibration')
        return
    if r['errorCode'] is not None or any(s['tokens'] is None for s in r['samples']):
        raise ValueError('invalidCalibration')
    train = [dict(id=s['id'], family=r['family'], language=s['language'], split='train', scalars=s['scalars'],
                  tokens=s['tokens']) for s in r['samples'] if s['split'] == 'train']
    if fit(train) != r['rates']:
        raise ValueError('invalidCalibration')
    expected = calibration_report('complete', r['method'], r['family'],
                                  [dict(s, kind='body') for s in r['samples']], r['rates'], r['promptChecks'],
                                  digest_value=r['modelDigest'],
                                  tokenizer=(r['tokenizerId'], r['tokenizerRevision'], r['tokenizerAssetsSha256']),
                                  platform=r['platform'])
    for key in ('bodyHoldoutUndercounts', 'promptHoldoutUndercounts', 'maxOverestimateTokens', 'calibrated'):
        if expected[key] != r[key]:
            raise ValueError('invalidCalibration')


def md_escape(text):
    return text.replace('\\', '\\\\').replace('|', '\\|').replace('\r\n', '<br>').replace('\r', '<br>') \
        .replace('\n', '<br>')


def md_value(value):
    if value is None:
        return 'not measured'
    if isinstance(value, bool):
        return 'yes' if value else 'no'
    return md_escape(str(value))


def calibration_markdown(r):
    lines = ['# Token calibration report v1', '',
             f"Status: {r['status']}", f"Platform: {md_value(r['platform'])}",
             f"Model: {md_value(r['model'])} ({md_value(r['modelDigest'])})",
             f"Ollama: {md_value(r['ollamaVersion'])}", f"Template: {md_value(r['showTemplateSha256'])}",
             f"Family: {md_value(r['family'])}", f"Method: {md_value(r['method'])}",
             'Tokenizer: none' if r['tokenizerId'] is None else
             f"Tokenizer: {md_value(r['tokenizerId'])} @ {md_value(r['tokenizerRevision'])} "
             f"({md_value(r['tokenizerAssetsSha256'])})",
             f"Corpus: {md_value(r['corpusHash'])}", f"Headroom: {r['headroomBp']} bp",
             f"Calibrated: {md_value(r['calibrated'])}", f"Error: {md_value(r['errorCode'] or 'none')}", '',
             '| sample | language | split | scalars | utf8 bytes | tokens |', '|---|---|---|---:|---:|---:|']
    for s in r['samples']:
        lines.append(f"| {md_value(s['id'])} | {s['language']} | {s['split']} | {s['scalars']} | {s['utf8Bytes']} "
                     f"| {md_value(s['tokens'])} |")
    lines += ['', '| family | language | tokens per scalar bp |', '|---|---|---:|']
    for x in r['rates']:
        lines.append(f"| {md_value(x['family'])} | {x['language']} | {x['tokensPerScalarBp']} |")
    lines += ['', '| query | split | prepared | wire | actual | estimated |', '|---|---|---|---|---:|---:|']
    for p in r['promptChecks']:
        lines.append(f"| {md_value(p['queryId'])} | {p['split']} | {p['preparedHash']} | {p['wireMessagesHash']} "
                     f"| {md_value(p['actualTokens'])} | {md_value(p['estimatedTokens'])} |")
    lines += ['', f"Body holdout undercounts: {md_value(r['bodyHoldoutUndercounts'])}",
              f"Prompt holdout undercounts: {md_value(r['promptHoldoutUndercounts'])}",
              f"Max overestimate tokens: {md_value(r['maxOverestimateTokens'])}"]
    return '\n'.join(lines) + '\n'


PLAN_DOCUMENTS = [
    dict(document_id='cs-a', language='cs', text='Záruka platí dva roky. ' * 12),
    dict(document_id='cs-b', language='cs', text='Kdo ručí za škodu?'),
    dict(document_id='cs-c', language='cs', text='Smlouva'),
    dict(document_id='cs-d', language='cs', text='Reklamace se podává písemně.'),
    dict(document_id='de-a', language='de', text='Die Garantie gilt.'),
    dict(document_id='de-b', language='de', text=''),
    dict(document_id='en-a', language='en', text='The warranty applies. ' * 60),
    dict(document_id='sk-a', language='sk', text='Záruka platí.'),
    dict(document_id='sk-b', language='sk', text='Kto ručí?'),
]
PLAN_QUERIES = [
    dict(query_id='q-cs-1', language='cs', case_type='answer', text='Jak dlouho platí záruka?',
         gold_document_ids=['cs-a']),
    dict(query_id='q-cs-2', language='cs', case_type='answer', text='Kdy podat reklamaci?',
         gold_document_ids=['cs-d']),
    dict(query_id='q-mixed-gold', language='sk', case_type='answer', text='Záruka a ručenie',
         gold_document_ids=['sk-a', 'cs-d']),
    dict(query_id='q-scope', language='en', case_type='scope', text='Only the warranty folder',
         gold_document_ids=['en-a']),
    dict(query_id='q-absent', language='de', case_type='absent', text='Wer zahlt?', gold_document_ids=[]),
    dict(query_id='q-overview', language='en', case_type='overview', text='Summarize', gold_document_ids=[]),
]


def token_estimate_fixture():
    train = lambda i, lang, s, t, fam=FIXTURE_FAMILY: dict(id=i, family=fam, language=lang, split='train',
                                                           scalars=s, tokens=t)
    cases = []

    def fit_case(name, samples, note=None):
        c = dict(name=name, kind='fit', samples=samples, **expect(fit, samples))
        if note:
            c['note'] = note
        cases.append(c)
    fit_case('ceil-rate', [train('a', 'cs', 3, 2), train('b', 'cs', 10, 3)])
    multi = [train('a', 'cs', 3, 2), train('b', 'cs', 10, 3), train('c', 'en', 4, 1), train('d', 'mixed', 7, 5),
             train('e', 'de', 9, 4), train('f', 'en', 5, 2, 'fixture-other')]
    fit_case('training-multi', multi)
    fit_case('training-order', [multi[i] for i in (5, 3, 1, 4, 0, 2)], note='permutation of training-multi')
    fit_case('invalid-zero-scalars', [train('a', 'cs', 0, 2)])
    fit_case('fit-negative-tokens', [train('a', 'cs', 3, -1)])
    fit_case('fit-holdout-rejected', [dict(train('a', 'cs', 3, 2), split='holdout')])
    fit_case('fit-duplicate-id', [train('a', 'cs', 3, 2), train('a', 'en', 3, 2)])
    fit_case('fit-unsupported-language', [train('a', 'fr', 3, 2)])
    fit_case('fit-family-whitespace', [train('a', 'cs', 3, 2, 'fixture only')])
    fit_case('fit-rate-overflow', [train('a', 'cs', 1, 101)])
    fit_case('fit-scalar-ceiling', [train('a', 'cs', MAX_SCALARS + 1, 1)])
    fit_case('fit-empty', [])
    for name, text, lang, rate in (('ceil-headroom', 'abc', 'cs', 6667), ('empty', '', 'cs', 6667),
                                   ('astral', 'a😀b', 'cs', 10000), ('rate5000-astral', 'a😀b', 'cs', 5000),
                                   ('english-rate', 'The warranty applies.', 'en', 2500),
                                   ('zero-rate', 'abc', 'de', 0)):
        cases.append(dict(name=name, kind='estimate', text=text, language=lang, rateBp=rate, scalars=len(text),
                          expected=estimate_text(text, lang, FIXTURE_FAMILY,
                                                 [dict(family=FIXTURE_FAMILY, language=lang, tokensPerScalarBp=rate)])))
    est_rates = [dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=3000),
                 dict(family=FIXTURE_FAMILY, language='en', tokensPerScalarBp=6667)]
    for name, family, lang, text in (('unknown-language', FIXTURE_FAMILY, 'sk', 'abc'),
                                     ('und-runtime', FIXTURE_FAMILY, 'und', 'abc'),
                                     ('known-language', FIXTURE_FAMILY, 'cs', 'abc'),
                                     ('unknown-family', 'unverified', 'cs', 'a😀b'),
                                     ('unknown-family-empty-rates', 'unverified', 'en', 'Záruka')):
        rates = [] if name == 'unknown-family-empty-rates' else est_rates
        cases.append(dict(name=name, kind='estimator', family=family, rates=rates, language=lang, text=text,
                          expected=estimate_text(text, lang, family, rates)))
    big = dict(name='saturate-scalars', kind='estimatorBound', family=FIXTURE_FAMILY,
               rates=[dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=10000)], language='cs',
               scalars=MAX_SCALARS + 1, expected=INT32_MAX,
               note='harness builds a string of this many "a" scalars; estimate saturates, never traps')
    cases.append(big)
    for name, samples in (('holdout-under', [dict(id='h1', family=FIXTURE_FAMILY, language='cs', split='holdout',
                                                  scalars=3, tokens=5),
                                             dict(id='h2', family=FIXTURE_FAMILY, language='cs', split='holdout',
                                                  scalars=3, tokens=4)]),
                          ('holdout-unknown-family', [dict(id='h1', family='other', language='cs',
                                                           split='holdout', scalars=3, tokens=5)])):
        rates = [dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=6667)]
        try:
            rows = undercount_rows(samples, rates)
            cases.append(dict(name=name, kind='undercount', samples=samples, rates=rates,
                              rows=rows, undercounts=sum(1 for r in rows if r['undercount'] > 0)))
        except ValueError as error:
            cases.append(dict(name=name, kind='undercount', samples=samples, rates=rates, error=str(error)))
    for name, rates in (('constructor-negative', [dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=-1)]),
                        ('constructor-duplicate', [dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=1),
                                                   dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=2)]),
                        ('constructor-rate-overflow', [dict(family=FIXTURE_FAMILY, language='cs',
                                                            tokensPerScalarBp=MAX_RATE_BP + 1)]),
                        ('constructor-language', [dict(family=FIXTURE_FAMILY, language='pl', tokensPerScalarBp=1)]),
                        ('constructor-empty-family', [dict(family='', language='cs', tokensPerScalarBp=1)]),
                        ('constructor-ok', [dict(family=FIXTURE_FAMILY, language='und', tokensPerScalarBp=5000),
                                            dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=MAX_RATE_BP)])):
        try:
            validate_rates(rates)
            cases.append(dict(name=name, kind='constructor', family=FIXTURE_FAMILY, rates=rates, error=None))
        except ValueError as error:
            cases.append(dict(name=name, kind='constructor', family=FIXTURE_FAMILY, rates=rates, error=str(error)))
    bindings = [dict(model=CHAT_MODEL, modelDigest=digest('a'), family=FIXTURE_FAMILY)]
    for name, model, dgst in (('binding-exact', CHAT_MODEL, digest('a')), ('binding-missing-digest', CHAT_MODEL, None),
                              ('binding-changed-digest', CHAT_MODEL, digest('b')),
                              ('binding-other-model', 'llama3.2:1b', digest('a')),
                              ('binding-alias-not-substring', 'llama3.2', digest('a'))):
        cases.append(dict(name=name, kind='binding', model=model, modelDigest=dgst, bindings=bindings,
                          expected=resolve_family(model, dgst, bindings)))
    observations = [dict(kind='body', method='ollama-raw-prompt', sample=train('cs-a:0:3', 'cs', 3, 2)),
                    dict(kind='embedding', method='ollama-embed-prompt', profileId='nomic-v2-256',
                         sample=train('cs-a:0:3#embed', 'cs', 3, 9)),
                    dict(kind='prompt', method='ollama-chat-prompt', sample=train('prompt:q1', 'cs', 3, 40))]
    cases.append(dict(name='calibration-observations', kind='calibration-observations', observations=observations,
                      expected=dict(trainingIds=['cs-a:0:3'],
                                    rates=fit([o['sample'] for o in observations if o['kind'] == 'body'])),
                      note='embedding and full-prompt counts never enter chat body rates'))
    plan = sample_plan(PLAN_DOCUMENTS, PLAN_QUERIES)
    cases.append(dict(name='sample-plan', kind='sample-plan', documents=PLAN_DOCUMENTS, queries=PLAN_QUERIES,
                      expected=plan))

    # Complete/incomplete calibration report goldens.
    fam = 'ollama:' + digest('a')
    body = [s for s in plan if s['kind'] in ('body', 'mixed')][:8]
    counted = [dict(s, tokens=ceildiv(s['scalars'] * 3, 10)) for s in body]
    train_rows = [dict(id=s['id'], family=fam, language=s['language'], split='train', scalars=s['scalars'],
                       tokens=s['tokens']) for s in counted if s['split'] == 'train']
    rates = fit(train_rows)
    checks = [dict(queryId='q-cs-1', split='train', preparedHash=hex64('1'), wireMessagesHash=hex64('2'),
                   actualTokens=700, estimatedTokens=760),
              dict(queryId='q-cs-2', split='holdout', preparedHash=hex64('3'), wireMessagesHash=hex64('4'),
                   actualTokens=650, estimatedTokens=702)]
    reports = []
    complete = calibration_report('complete', 'ollama-raw-prompt', fam, counted, rates, checks)
    reports.append(('calibration-complete', complete, None))
    missing = [dict(s, tokens=None if i == 1 else s['tokens']) for i, s in enumerate(counted)]
    reports.append(('calibration-incomplete-missing-count',
                    calibration_report('incomplete', 'ollama-raw-prompt', fam, missing, [],
                                       [dict(c, actualTokens=None) for c in checks], 'tokenCountUnavailable'), None))
    hf = ('fixture-chat-tokenizer', 'fixture-revision', hex64('c'))
    hf_family = f'hf:{hf[0]}@{hf[1]}:{hf[2]}'
    hf_train = [dict(r, family=hf_family) for r in train_rows]
    reports.append(('calibration-documented-tokenizer',
                    calibration_report('complete', 'documented-tokenizer', hf_family, counted, fit(hf_train), checks,
                                       tokenizer=hf), None))
    under = copy.deepcopy(checks)
    under[1]['actualTokens'] = 703
    reports.append(('calibration-holdout-undercount',
                    calibration_report('complete', 'ollama-raw-prompt', fam, counted, rates, under), None))
    bad = copy.deepcopy(complete)
    bad['family'] = FIXTURE_FAMILY
    reports.append(('calibration-family-mismatch', bad, 'invalidCalibration'))
    lying = calibration_report('complete', 'ollama-raw-prompt', fam, counted, rates, under)
    lying['calibrated'] = True
    reports.append(('calibration-claims-calibrated-with-undercount', lying, 'invalidCalibration'))
    refit = copy.deepcopy(complete)
    refit['rates'][0]['tokensPerScalarBp'] += 1
    reports.append(('calibration-rates-not-from-training', refit, 'invalidCalibration'))
    for name, report, error in reports:
        if error is None:
            validate_calibration_report(report)
            cases.append(dict(name=name, kind='calibration-report', input=report, expectedJson=copy.deepcopy(report),
                              expectedMarkdown=calibration_markdown(report)))
        else:
            try:
                validate_calibration_report(report)
                raise AssertionError(name)
            except ValueError as e:
                assert str(e) == error, (name, e)
            cases.append(dict(name=name, kind='calibration-report', input=report, error=error))

    pending = estimate_resource()
    tampered = copy.deepcopy(pending)
    tampered['payloadHash'] = hex64('0')
    fixture_bound = estimate_resource('calibrated', [dict(model=CHAT_MODEL, modelDigest=digest('a'),
                                                          family=FIXTURE_FAMILY)],
                                      [dict(family=FIXTURE_FAMILY, language='cs', tokensPerScalarBp=5000)])
    measured_shape = estimate_resource('calibrated', [dict(model=CHAT_MODEL, modelDigest=digest('a'), family=fam)],
                                       rates, [dict(family=fam, note='synthetic provenance shape')])
    pending_with_rates = estimate_resource('pending', [], rates)
    for name, resource, production in (('resource-pending', pending, True), ('resource-hash-mismatch', tampered, True),
                                       ('resource-fixture-family', fixture_bound, True),
                                       ('resource-fixture-family-test-mode', fixture_bound, False),
                                       ('resource-calibrated-shape', measured_shape, True),
                                       ('resource-pending-with-rates', pending_with_rates, True)):
        try:
            validate_estimate_resource(resource, production)
            cases.append(dict(name=name, kind='resource', production=production, input=resource,
                              expected=dict(payloadHash=resource['payloadHash'], status=resource['status'])))
        except ValueError as error:
            cases.append(dict(name=name, kind='resource', production=production, input=resource, error=str(error)))
    head = estimate_resource()
    del head['payloadHash']
    return dict(head, payloadHash=pending['payloadHash'], cases=cases)


# ------------------------------------------------------------ report model

def metric(found, total):
    return dict(status='measured', found=found, total=total, recall_bp=10000 * found // total)


NA = dict(status='not_applicable', found=0, total=0, recall_bp=None)
UNAVAILABLE = dict(status='not_available', found=None, total=None, recall_bp=None)


def recall(gold, evidence):
    if not gold:
        return dict(NA)
    found = sum(1 for g in gold if any(e['document_id'] == g['document_id'] and e['content_hash'] == g['content_hash']
                                       and e['start'] <= g['start'] and e['end'] >= g['end'] for e in evidence))
    return metric(found, len(gold))


def aggregate(metrics):
    measured = [m for m in metrics if m['status'] == 'measured']
    total = sum(m['total'] for m in measured)
    if total > 0:
        return metric(sum(m['found'] for m in measured), total)
    return dict(UNAVAILABLE) if any(m['status'] == 'not_available' for m in metrics) else dict(NA)


def aggregates(rows):
    def agg(rs):
        return {n: aggregate([r['eval']['metrics'][n] for r in rs]) for n in METRICS}
    return (agg(rows), {lang: agg([r for r in rows if r['eval']['language'] == lang]) for lang in LANGUAGES},
            {ct: agg([r for r in rows if r['eval']['case_type'] == ct]) for ct in CASE_TYPES})


def span(doc, start, end):
    return dict(document_id=doc['id'], content_hash=sha256_text(doc['text']), start=start, end=end)


REPORT_DOCS = {d['id']: d for d in (
    dict(id='cs-warranty', text='Záruka platí dva roky od převzetí zboží.', language='cs'),
    dict(id='en-warranty', text='The warranty applies for two years.', language='en'),
    dict(id='de-garantie', text='Die Garantie gilt zwei Jahre.', language='de'),
)}


def quality_query(qid, text, language, case_type, gold, lexical, fused, packed, citations, answer, files=(3, 3),
                  top_k=16, overview=None, timing=True):
    if case_type in ('absent', 'empty_selection', 'overview'):
        metrics = {n: dict(NA) for n in METRICS}
    else:
        metrics = dict(lexical_recall_at_top_k=recall(gold, lexical[:top_k]),
                       lexical_recall_at_fetch_k=recall(gold, lexical),
                       hybrid_recall_at_top_k=recall(gold, fused[:top_k]),
                       candidate_recall_at_fetch_k=recall(gold, fused),
                       packed_evidence_recall=recall(gold, packed))
    row = dict(query_id=qid, text=text, language=language, case_type=case_type, status='measured',
               files_in_scope=files[0], candidates_with_chunks=files[1], lexical=lexical, vector=fused, fused=fused,
               metrics=metrics)
    return dict(eval=row, packed=packed, citationMap=citations, answerText=answer,
                preparedHash=None if case_type == 'empty_selection' else hashlib.sha256(qid.encode()).hexdigest(),
                timing=dict(embeddingUs=1200, retrievalUs=3400, hydrationUs=560, endToEndUs=5300)
                if timing and case_type not in ('empty_selection', 'overview') else None,
                overview=overview)


def citation(marker, chunk, source, revision, doc, start, end, rel):
    text = doc['text'][start:end]
    return dict(marker=marker, chunkId=chunk, sourceId=source, snippet=text[:240], folderId=1, relPath=rel,
                displayName=rel.rsplit('/', 1)[-1], revisionId=revision, spans=[dict(start=start, end=end)],
                chunkIds=[chunk], text=text)


def quality_rows(variant):
    cs, en, de = REPORT_DOCS['cs-warranty'], REPORT_DOCS['en-warranty'], REPORT_DOCS['de-garantie']
    gold_cs, gold_en = [span(cs, 0, 21)], [span(en, 4, 34)]
    full_cs, full_en, full_de = span(cs, 0, len(cs['text'])), span(en, 0, len(en['text'])), span(de, 0, len(de['text']))
    rows = [
        quality_query('q-01', 'Jak dlouho platí záruka?', 'cs', 'answer', gold_cs, [full_cs, full_de], [full_cs],
                      [full_cs], [citation(1, 101, 10, 11, cs, 0, len(cs['text']), 'docs/zaruka.txt')],
                      'Dva roky [1].'),
        quality_query('q-02', 'How long is the warranty?', 'en', 'answer', gold_en,
                      [full_de] if variant else [full_en], [full_en, full_de] if variant == 0 else [full_de],
                      [full_en] if variant == 0 else [],
                      [citation(1, 201, 20, 21, en, 0, len(en['text']), 'docs/warranty.txt')] if variant == 0 else [],
                      'Two years [1] [7].' if variant == 0 else 'Not found.'),
        quality_query('q-03', 'Wer zahlt die Reparatur?', 'de', 'absent', [], [full_de], [full_de], [],
                      [], 'Nicht im Korpus.'),
        quality_query('q-04', 'Kto ručí?', 'sk', 'empty_selection', [], [], [], [], [], None, files=(0, 0)),
        quality_query('q-05', 'Shrň složku.', 'cs', 'overview', [], [], [], [full_cs, full_en],
                      [citation(1, 101, 10, 11, cs, 0, len(cs['text']), 'docs/zaruka.txt'),
                       citation(2, 201, 20, 21, en, 0, len(en['text']), 'docs/warranty.txt')], 'Přehled [1] [2].',
                      overview=dict(filesInScope=3, publishedCandidateFiles=2, filesIncluded=2)),
    ]
    return rows


def perf_row(chunks, concurrent, scale, offset, queries=200, warmup=20, dims=256):
    samples = []
    for i in range(queries):
        r = scale * (1 + (i * 37) % queries) + offset
        e, h = 1000 + (i % 7), 200 + (i % 5)
        samples.append(dict(queryId=i, embeddingUs=e, retrievalUs=r, hydrationUs=h, endToEndUs=e + r + h + 3))
    warm = [s['retrievalUs'] for s in samples]
    total = [s['endToEndUs'] for s in samples]
    hyd = [s['hydrationUs'] for s in samples]
    rows = chunks * (dims * 4 + 32)
    cached = rows <= CACHE_BUDGET_BYTES
    p95 = percentile(warm, 9500)
    return dict(chunks=chunks, concurrent=concurrent, queries=queries, warmupQueries=warmup,
                warmP50Us=percentile(warm, 5000), warmP95Us=p95, endToEndP50Us=percentile(total, 5000),
                endToEndP95Us=percentile(total, 9500), hydrationP95Us=percentile(hyd, 9500),
                coldCacheLoadUs=150000 + chunks // 10 if cached else None, cacheMode='cached' if cached else 'streamed',
                residentBytes=rows if cached else 0, peakPageBytes=1024 * (dims * 4 + 32),
                completedWrites=12 if concurrent else 0, overlapUs=900000 if concurrent else 0,
                gatePassed=warm_gate(chunks, concurrent, queries, p95), samples=samples)


GATED_ROWS = ((100_000, False, 200), (100_000, True, 200), (200_000, False, 200), (200_000, True, 200))
SMALL_ROWS = ((1000, False, 3), (1000, True, 3))


def candidate(profile_id, variant, scale, platform_offset, limit=None, status='complete', rows_spec=GATED_ROWS):
    p = PROFILE_BY_ID[profile_id]
    limit = limit or p['maxInputTokens']
    rows = quality_rows(variant)
    metrics, by_lang, by_case = aggregates(rows)
    cite = dict(snapshotsCorrect=4 if variant == 0 else 3, snapshotsTotal=4 if variant == 0 else 3,
                answerMarkersCorrect=4 if variant == 0 else 3, answerMarkersTotal=5 if variant == 0 else 3,
                answerGoldSupported=2 if variant == 0 else 1, answerMarkersJudged=3 if variant == 0 else 1,
                semanticReview='not_measured')
    ingest = dict(serviceTokens=48210 + variant, successfulTokens=48000 + variant, rejectedRequests=variant,
                  splitParts=3 + variant, elapsedUs=60_000_000 + 1000 * variant,
                  tokensPerSecondMilli=tokens_per_second_milli(48000 + variant, 60_000_000 + 1000 * variant),
                  runnerPeakRssBytes=900_000_000, serverPeakRssBytes=1_400_000_000 + p['dims'] * 1000,
                  combinedPeakRssBytes=2_100_000_000 + p['dims'] * 1000, serviceTokenStatus='measured',
                  uncountedRequests=0, memoryMethod='ps-rss', sampleIntervalMs=100)
    perf = [perf_row(c, cc, scale, platform_offset + 7 * variant, queries=n, warmup=min(20, n), dims=p['dims'])
            for c, cc, n in rows_spec]
    return dict(profileId=profile_id,
                identity=identity_for(profile_id, endpoint_revision('ollama', OLLAMA_ROOT),
                                      digest(format(PROFILE_ORDER.index(profile_id) + 1, 'x')), limit),
                status=status, errorCode=None,
                quality=dict(metrics=metrics, byLanguage=by_lang, byCaseType=by_case, queries=rows),
                citations=cite, ingest=ingest, performance=perf)


def environment(platform, cpu=None):
    if platform == 'macos':
        return dict(cpu=cpu or 'Apple M2 (fixture)', ramBytes=17_179_869_184, os='macOS 26.6.2 (fixture)',
                    architecture='arm64', buildCommit='f' * 40, ollamaVersion='0.0.0-fixture', accelerator='metal')
    return dict(cpu=cpu or 'Intel Core i7 (fixture)', ramBytes=17_179_869_184, os='Windows 11 (fixture)',
                architecture='x64', buildCommit='f' * 40, ollamaVersion='0.0.0-fixture', accelerator='cpu')


def report(platform, candidates, status='complete', mode='fixture', calibration_hash=None, cpu=None,
           token_family=FIXTURE_FAMILY):
    return dict(contract='benchmark-report', version=1, status=status, backend=BACKEND, mode=mode, platform=platform,
                environment=environment(platform, cpu),
                corpus=dict(id='wp7-fixture-corpus', hash=sha256_text('wp7-fixture-corpus'), documents=3, queries=5,
                            chunkerVersion='2'),
                calibrationHash=calibration_hash or hex64('7'),
                parameters=dict(fetchK=32, topK=16, evidenceShareBp=6000, runtimeContext=8192, maxOutputTokens=1024,
                                seed=17),
                chat=dict(model=CHAT_MODEL, modelDigest=digest('a'), tokenFamily=token_family,
                          showTemplateSha256=hex64('e')),
                candidates=candidates)


def failed_candidate(profile_id):
    p = PROFILE_BY_ID[profile_id]
    rows = []
    metrics, by_lang, by_case = aggregates(rows)
    return dict(profileId=profile_id,
                identity=identity_for(profile_id, endpoint_revision('ollama', OLLAMA_ROOT), None, p['maxInputTokens']),
                status='failed', errorCode='embeddingModelUnavailable',
                quality=dict(metrics=metrics, byLanguage=by_lang, byCaseType=by_case, queries=rows),
                citations=dict(snapshotsCorrect=0, snapshotsTotal=0, answerMarkersCorrect=0, answerMarkersTotal=0,
                               answerGoldSupported=0, answerMarkersJudged=0, semanticReview='not_measured'),
                ingest=dict(serviceTokens=None, successfulTokens=None, rejectedRequests=None, splitParts=None,
                            elapsedUs=None, tokensPerSecondMilli=None, runnerPeakRssBytes=None,
                            serverPeakRssBytes=None, combinedPeakRssBytes=None, serviceTokenStatus='not_available',
                            uncountedRequests=0, memoryMethod='ps-rss', sampleIntervalMs=100),
                performance=[])


def scalar_key(s):
    return list(map(ord, s))


def validate_metric(m):
    if m['status'] == 'measured':
        ok_ = (isinstance(m['found'], int) and isinstance(m['total'], int) and m['total'] > 0
               and 0 <= m['found'] <= m['total'] and m['recall_bp'] == 10000 * m['found'] // m['total'])
    elif m['status'] == 'not_applicable':
        ok_ = m['found'] == 0 and m['total'] == 0 and m['recall_bp'] is None
    elif m['status'] == 'not_available':
        ok_ = m['found'] is None and m['total'] is None and m['recall_bp'] is None
    else:
        ok_ = False
    if not ok_:
        raise ValueError('invalidMetric')


def validate_report(r):
    """benchmark-v1 §6.3, checked in this order; the first failure's code is the error."""
    if (r['contract'] != 'benchmark-report' or r['version'] != 1 or r['backend'] != BACKEND
            or r['status'] not in ('complete', 'incomplete') or r['mode'] not in ('fixture', 'live')
            or r['platform'] not in ('macos', 'windows')):
        raise ValueError('invalidReport')
    if not is_hex64(r['corpus']['hash']) or not is_hex64(r['calibrationHash']) \
            or (r['chat']['modelDigest'] is not None and not is_digest(r['chat']['modelDigest'])):
        raise ValueError('invalidHash')
    p = r['parameters']
    if not (0 < p['topK'] <= p['fetchK'] <= 1024 and 0 <= p['evidenceShareBp'] <= 10000
            and 0 < p['maxOutputTokens'] < p['runtimeContext']):
        raise ValueError('invalidReport')
    ids = [c['profileId'] for c in r['candidates']]
    if len(ids) != len(set(ids)):
        raise ValueError('duplicateProfile')
    if any(i not in PROFILE_BY_ID for i in ids):
        raise ValueError('unknownProfile')
    if ids != sorted(ids, key=PROFILE_ORDER.index):
        raise ValueError('invalidOrder')
    for c in r['candidates']:
        prof, ident = PROFILE_BY_ID[c['profileId']], c['identity']
        q, d = ident['queryFormatVersion'], ident['docFormatVersion']
        prefix_q, prefix_d = format_version(prof['id'], 'query', ''), format_version(prof['id'], 'document', '')
        limit = q[len(prefix_q):] if q.startswith(prefix_q) else ''
        if (ident['model'] != prof['model'] or ident['dims'] != prof['dims'] or ident['normalization'] != 'l2'
                or ident['chunkerVersion'] != '2' or not limit.isdigit() or limit.startswith('0')
                or not 1 <= int(limit) <= prof['maxInputTokens'] or d != prefix_d + limit):
            raise ValueError('profileIdentityMismatch')
        if ident['modelDigest'] is not None and not is_digest(ident['modelDigest']):
            raise ValueError('invalidHash')
        if c['status'] not in ('complete', 'failed', 'incomplete') or (c['status'] == 'complete') != (c['errorCode'] is None):
            raise ValueError('invalidReport')
        rows = c['quality']['queries']
        qids = [x['eval']['query_id'] for x in rows]
        if len(qids) != len(set(qids)):
            raise ValueError('duplicateQuery')
        if qids != sorted(qids, key=scalar_key):
            raise ValueError('invalidOrder')
        for x in rows:
            for n in METRICS:
                validate_metric(x['eval']['metrics'][n])
            for s in x['packed']:
                if s['start'] < 0 or s['end'] <= s['start']:
                    raise ValueError('invalidMetric')
            if x['preparedHash'] is not None and not is_hex64(x['preparedHash']):
                raise ValueError('invalidHash')
        metrics, by_lang, by_case = aggregates(rows)
        for group in (c['quality']['metrics'], *c['quality']['byLanguage'].values(),
                      *c['quality']['byCaseType'].values()):
            for n in METRICS:
                validate_metric(group[n])
        if (metrics != c['quality']['metrics'] or by_lang != c['quality']['byLanguage']
                or by_case != c['quality']['byCaseType']):
            raise ValueError('inconsistentAggregate')
        ct = c['citations']
        if (ct['semanticReview'] != 'not_measured'
                or any(not isinstance(ct[k], int) or ct[k] < 0 for k in ct if k != 'semanticReview')
                or ct['snapshotsCorrect'] > ct['snapshotsTotal']
                or ct['answerMarkersCorrect'] > ct['answerMarkersTotal']
                or ct['answerGoldSupported'] > ct['answerMarkersCorrect']
                or ct['answerMarkersJudged'] > ct['answerMarkersTotal']):
            raise ValueError('invalidCitations')
        ig = c['ingest']
        for k in ('serviceTokens', 'successfulTokens', 'rejectedRequests', 'splitParts', 'elapsedUs',
                  'tokensPerSecondMilli', 'runnerPeakRssBytes', 'serverPeakRssBytes', 'combinedPeakRssBytes',
                  'uncountedRequests', 'sampleIntervalMs'):
            if ig[k] is not None and (not isinstance(ig[k], int) or ig[k] < 0):
                raise ValueError('invalidSamples')
        if ig['serviceTokenStatus'] == 'measured':
            if ig['uncountedRequests'] != 0 or (c['status'] == 'complete' and ig['serviceTokens'] is None):
                raise ValueError('invalidSamples')
        elif ig['serviceTokenStatus'] in ('partial', 'not_available'):
            if ig['serviceTokens'] is not None:
                raise ValueError('invalidSamples')
        else:
            raise ValueError('invalidSamples')
        if ig['successfulTokens'] is not None and ig['elapsedUs'] is not None \
                and ig['tokensPerSecondMilli'] != tokens_per_second_milli(ig['successfulTokens'], ig['elapsedUs']):
            raise ValueError('summaryMismatch')
        if None not in (ig['runnerPeakRssBytes'], ig['serverPeakRssBytes'], ig['combinedPeakRssBytes']):
            if not max(ig['runnerPeakRssBytes'], ig['serverPeakRssBytes']) <= ig['combinedPeakRssBytes'] \
                    <= ig['runnerPeakRssBytes'] + ig['serverPeakRssBytes']:
                raise ValueError('summaryMismatch')
        keys = [(x['chunks'], x['concurrent']) for x in c['performance']]
        if len(keys) != len(set(keys)) or keys != sorted(keys):
            raise ValueError('invalidOrder')
        for x in c['performance']:
            s = x['samples']
            if (x['queries'] <= 0 or x['warmupQueries'] < 0 or len(s) != x['queries']
                    or [y['queryId'] for y in s] != list(range(len(s)))
                    or any(y[k] < 0 for y in s for k in ('embeddingUs', 'retrievalUs', 'hydrationUs', 'endToEndUs'))
                    or any(y['endToEndUs'] < y['embeddingUs'] + y['retrievalUs'] + y['hydrationUs'] for y in s)
                    or (x['chunks'] == 100_000 and not x['concurrent'] and x['queries'] != 200)):
                raise ValueError('invalidSamples')
            warm = [y['retrievalUs'] for y in s]
            expected = dict(warmP50Us=percentile(warm, 5000), warmP95Us=percentile(warm, 9500),
                            endToEndP50Us=percentile([y['endToEndUs'] for y in s], 5000),
                            endToEndP95Us=percentile([y['endToEndUs'] for y in s], 9500),
                            hydrationP95Us=percentile([y['hydrationUs'] for y in s], 9500))
            if any(x[k] != v for k, v in expected.items()) \
                    or x['gatePassed'] != warm_gate(x['chunks'], x['concurrent'], x['queries'], x['warmP95Us']):
                raise ValueError('summaryMismatch')
            if x['cacheMode'] not in ('cached', 'streamed') or (x['cacheMode'] == 'streamed'
                                                                 and x['coldCacheLoadUs'] is not None):
                raise ValueError('invalidSamples')
            if x['concurrent']:
                if x['completedWrites'] < 2 or x['overlapUs'] <= 0:
                    raise ValueError('insufficientIngestionOverlap')
            elif x['completedWrites'] != 0 or x['overlapUs'] != 0:
                raise ValueError('invalidSamples')
    if r['status'] == 'complete':
        if r['chat']['modelDigest'] is None or r['chat']['tokenFamily'] is None:
            raise ValueError('incompleteMeasurement')
        for c in r['candidates']:
            ig = c['ingest']
            if (c['status'] != 'complete' or c['identity']['modelDigest'] is None or not c['performance']
                    or ig['successfulTokens'] is None or ig['elapsedUs'] is None or ig['combinedPeakRssBytes'] is None
                    or any(x['eval']['metrics']['packed_evidence_recall']['status'] == 'not_available'
                           for x in c['quality']['queries'])
                    or any(x['cacheMode'] == 'cached' and x['coldCacheLoadUs'] is None for x in c['performance'])):
                raise ValueError('incompleteMeasurement')


def fmt_bp(m):
    bp = m['recall_bp']
    return 'not measured' if bp is None else f'{bp // 100}.{bp % 100:02d}%'


def fmt_milli(v):
    return None if v is None else f'{v // 1000}.{v % 1000:03d}'


def unit(v, suffix):
    """A null value prints `not measured` without a unit."""
    return 'not measured' if v is None else f'{v} {suffix}'


def report_markdown(r):
    e, c0, p, ch = r['environment'], r['corpus'], r['parameters'], r['chat']
    lines = ['# Benchmark report v1', '', f"Status: {r['status']}", f"Mode: {r['mode']}",
             f"Platform: {r['platform']}", f"Backend: {r['backend']}", '', '## Environment', '',
             '| field | value |', '|---|---|']
    for k in ('cpu', 'ramBytes', 'os', 'architecture', 'buildCommit', 'ollamaVersion', 'accelerator'):
        lines.append(f'| {k} | {md_value(e[k])} |')
    lines += ['', f"Corpus: {md_value(c0['id'])} ({c0['hash']}); documents {c0['documents']}; "
                  f"queries {c0['queries']}; chunker {md_value(c0['chunkerVersion'])}",
              f"Calibration: {r['calibrationHash']}",
              f"Parameters: fetchK {p['fetchK']}; topK {p['topK']}; evidenceShareBp {p['evidenceShareBp']}; "
              f"runtimeContext {p['runtimeContext']}; maxOutputTokens {p['maxOutputTokens']}; seed {p['seed']}",
              f"Chat: {md_value(ch['model'])} ({md_value(ch['modelDigest'])}); token family "
              f"{md_value(ch['tokenFamily'])}; template {md_value(ch['showTemplateSha256'])}"]
    for c in r['candidates']:
        i, q, ct, ig = c['identity'], c['quality'], c['citations'], c['ingest']
        lines += ['', f"## Candidate {c['profileId']}", '',
                  f"Status: {c['status']}; error: {md_value(c['errorCode'] or 'none')}",
                  f"Identity: provider {md_value(i['providerId'])}; endpoint {md_value(i['endpointRevision'])}; "
                  f"model {md_value(i['model'])} ({md_value(i['modelDigest'])}); dims {i['dims']}; "
                  f"normalization {md_value(i['normalization'])}; chunker {md_value(i['chunkerVersion'])}",
                  f"Query format: {md_value(i['queryFormatVersion'])}",
                  f"Document format: {md_value(i['docFormatVersion'])}", '',
                  '| metric | found | total | recall | status |', '|---|---:|---:|---:|---|']
        for n in METRICS:
            m = q['metrics'][n]
            lines.append(f"| {n} | {md_value(m['found'])} | {md_value(m['total'])} | {fmt_bp(m)} | {m['status']} |")
        lines += ['', '| language | ' + ' | '.join(METRICS) + ' |', '|---|' + '---:|' * len(METRICS)]
        for lang in LANGUAGES:
            lines.append(f'| {lang} | ' + ' | '.join(fmt_bp(q['byLanguage'][lang][n]) for n in METRICS) + ' |')
        lines += ['', f"Citations: snapshots {ct['snapshotsCorrect']}/{ct['snapshotsTotal']}; answer markers "
                      f"{ct['answerMarkersCorrect']}/{ct['answerMarkersTotal']}; gold-supported "
                      f"{ct['answerGoldSupported']}/{ct['answerMarkersJudged']} judged; semantic review "
                      f"{ct['semanticReview']}",
                  f"Ingestion: service tokens {md_value(ig['serviceTokens'])} ({ig['serviceTokenStatus']}); "
                  f"successful tokens {md_value(ig['successfulTokens'])}; rejected requests "
                  f"{md_value(ig['rejectedRequests'])}; split parts {md_value(ig['splitParts'])}; uncounted "
                  f"requests {md_value(ig['uncountedRequests'])}; elapsed {unit(ig['elapsedUs'], 'us')}; "
                  f"throughput {unit(fmt_milli(ig['tokensPerSecondMilli']), 'tokens/s')}",
                  f"Memory: runner peak {unit(ig['runnerPeakRssBytes'], 'bytes')}; server peak "
                  f"{unit(ig['serverPeakRssBytes'], 'bytes')}; combined peak {unit(ig['combinedPeakRssBytes'], 'bytes')}; "
                  f"method {md_value(ig['memoryMethod'])}; interval {unit(ig['sampleIntervalMs'], 'ms')}", '',
                  '| chunks | concurrent | queries | warmup | warm p50 us | warm p95 us | end-to-end p50 us '
                  '| end-to-end p95 us | hydration p95 us | cold cache us | cache | resident bytes | peak page bytes '
                  '| writes | overlap us | gate |',
                  '|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---|']
        for x in c['performance']:
            gate = 'not measured' if x['gatePassed'] is None else ('pass' if x['gatePassed'] else 'fail')
            lines.append('| ' + ' | '.join([str(x['chunks']), md_value(x['concurrent'])] + [
                md_value(x[k]) for k in ('queries', 'warmupQueries', 'warmP50Us', 'warmP95Us', 'endToEndP50Us',
                                         'endToEndP95Us', 'hydrationP95Us', 'coldCacheLoadUs', 'cacheMode',
                                         'residentBytes', 'peakPageBytes', 'completedWrites', 'overlapUs')]
                + [gate]) + ' |')
    return '\n'.join(lines) + '\n'


def decision_resource_for(calibration_rates):
    fam = FIXTURE_FAMILY
    return estimate_resource('calibrated', [dict(model=CHAT_MODEL, modelDigest=digest('a'), family=fam)],
                             calibration_rates,
                             [dict(family=fam, model=CHAT_MODEL, modelDigest=digest('a'), method='ollama-raw-prompt',
                                   ollamaVersion='0.0.0-fixture', showTemplateSha256=hex64('e'), tokenizerId=None,
                                   tokenizerRevision=None, tokenizerAssetsSha256=None, trainSamples=12,
                                   holdoutSamples=4, promptChecks=4, bodyHoldoutUndercounts=0,
                                   promptHoldoutUndercounts=0, maxOverestimateTokens=9,
                                   macReportSha256=hex64('5'), windowsReportSha256=hex64('6'))])


def report_fixture():
    cases = []

    def report_case(name, r, error=None, note=None):
        if error is None:
            validate_report(r)
            c = dict(name=name, kind='report', input=r, expectedJson=copy.deepcopy(r),
                     expectedMarkdown=report_markdown(r))
        else:
            try:
                validate_report(r)
                raise AssertionError(name + ' unexpectedly valid')
            except ValueError as e:
                assert str(e) == error, (name, str(e), error)
            c = dict(name=name, kind='report', input=r, error=error)
        if note:
            c['note'] = note
        cases.append(c)

    # One gated candidate (100K row has the 200 required samples) plus one small fixture-mode candidate.
    complete = report('macos', [candidate('nomic-v2-256', 0, 900, 0,
                                          rows_spec=((100_000, False, 200), (100_000, True, 20),
                                                     (200_000, False, 20), (200_000, True, 20))),
                                candidate('bge-m3-1024', 1, 1100, 0, rows_spec=SMALL_ROWS)])
    report_case('complete', complete)
    # Validation cases mutate a small two-candidate base; none needs the 200-sample rows.
    small = report('macos', [candidate('nomic-v2-256', 0, 900, 0, rows_spec=SMALL_ROWS),
                             candidate('bge-m3-1024', 1, 1100, 0, rows_spec=SMALL_ROWS)])
    report_case('complete-small', small)
    escaped = copy.deepcopy(small)
    escaped['environment']['cpu'] = 'A|B\nC\\D'
    report_case('markdown-escape', escaped, note='cpu renders as A\\|B<br>C\\\\D')
    incomplete = report('windows', [candidate('nomic-v2-256', 0, 900, 50, rows_spec=SMALL_ROWS),
                                    failed_candidate('bge-m3-1024')],
                        status='incomplete')
    report_case('incomplete-honest', incomplete, note='failed row stays null; never zero')
    bad = copy.deepcopy(small)
    bad['candidates'][0]['identity']['dims'] = 768
    report_case('bad-identity', bad, 'profileIdentityMismatch')
    unmeasured = copy.deepcopy(small)
    unmeasured['candidates'][1]['ingest'].update(successfulTokens=None, tokensPerSecondMilli=None)
    report_case('unmeasured-counts', unmeasured, 'incompleteMeasurement')
    packed = copy.deepcopy(small)
    row = packed['candidates'][0]['quality']['queries'][0]
    row['eval']['metrics']['packed_evidence_recall'] = dict(UNAVAILABLE)
    m, bl, bc = aggregates(packed['candidates'][0]['quality']['queries'])
    packed['candidates'][0]['quality'].update(metrics=m, byLanguage=bl, byCaseType=bc)
    report_case('unmeasured-packed', packed, 'incompleteMeasurement')
    mismatch = copy.deepcopy(small)
    mismatch['candidates'][0]['performance'][0]['warmP95Us'] -= 1
    report_case('summary-mismatch', mismatch, 'summaryMismatch')
    gate = copy.deepcopy(small)
    gate['candidates'][0]['performance'][0]['gatePassed'] = False
    report_case('gate-mismatch', gate, 'summaryMismatch')
    dup = copy.deepcopy(small)
    dup['candidates'][1] = copy.deepcopy(dup['candidates'][0])
    report_case('duplicate-profile', dup, 'duplicateProfile')
    order = copy.deepcopy(small)
    order['candidates'].reverse()
    report_case('catalog-order', order, 'invalidOrder')
    found = copy.deepcopy(small)
    found['candidates'][0]['quality']['queries'][0]['eval']['metrics']['lexical_recall_at_top_k'].update(found=2)
    report_case('found-above-total', found, 'invalidMetric')
    agg = copy.deepcopy(small)
    agg['candidates'][0]['quality']['metrics']['packed_evidence_recall'] = metric(1, 2)
    report_case('inconsistent-aggregate', agg, 'inconsistentAggregate')
    count = copy.deepcopy(small)
    count['candidates'][0]['performance'][0]['samples'].pop()
    report_case('wrong-sample-count', count, 'invalidSamples')
    overlap = copy.deepcopy(small)
    overlap['candidates'][0]['performance'][1]['overlapUs'] = 0
    report_case('no-overlap', overlap, 'insufficientIngestionOverlap')
    cites = copy.deepcopy(small)
    cites['candidates'][0]['citations']['answerGoldSupported'] = 9
    report_case('citations-inconsistent', cites, 'invalidCitations')

    for name, inp, exp in (('percentiles-200', dict(samples=list(range(1, 201))), dict(p50=100, p95=190)),
                           ('percentiles-one', dict(samples=[7]), dict(p50=7, p95=7)),
                           ('percentiles-unsorted', dict(samples=[5, 1, 4, 2, 3]), dict(p50=3, p95=5))):
        cases.append(dict(name=name, kind='percentile', input=inp,
                          expected=dict(p50=percentile(inp['samples'], 5000), p95=percentile(inp['samples'], 9500))))
        assert cases[-1]['expected'] == exp
    cases.append(dict(name='percentile-empty', kind='percentile', input=dict(samples=[]), error='invalidSamples'))
    cases.append(dict(name='percentile-negative', kind='percentile', input=dict(samples=[1, -1]),
                      error='invalidSamples'))
    for name, chunks, conc, queries, p95 in (('threshold-equal', 100_000, False, 200, 300_000),
                                             ('threshold-below', 100_000, False, 200, 299_999),
                                             ('threshold-200k', 200_000, False, 200, 1),
                                             ('threshold-concurrent', 100_000, True, 200, 1),
                                             ('threshold-query-count', 100_000, False, 199, 1)):
        cases.append(dict(name=name, kind='gate', input=dict(chunks=chunks, concurrent=conc, queries=queries,
                                                             p95Us=p95),
                          expected=warm_gate(chunks, conc, queries, p95)))
    for name, tokens, elapsed in (('tokens-per-second', 120, 2_000_000), ('denominator-zero', 120, 0),
                                  ('throughput-floor', 7, 3)):
        cases.append(dict(name=name, kind='throughput', input=dict(tokens=tokens, elapsedUs=elapsed),
                          expected=dict(tokensPerSecondMilli=tokens_per_second_milli(tokens, elapsed))))
    cases.append(dict(name='throughput-overflow', kind='throughput',
                      input=dict(tokens=INT64_MAX // 1_000_000_000 + 1, elapsedUs=1), error='invalidSamples'))
    cases.append(dict(name='markdown-title', kind='escape', input='A|B\nC\\D', expected=md_escape('A|B\nC\\D')))
    cases.append(dict(name='markdown-crlf', kind='escape', input='x\r\ny\rz', expected=md_escape('x\r\ny\rz')))
    cases.append(dict(name='recall-format', kind='recallFormat',
                      input=[metric(1, 3), metric(2, 2), dict(NA), dict(UNAVAILABLE)],
                      expected=[fmt_bp(metric(1, 3)), fmt_bp(metric(2, 2)), 'not measured', 'not measured']))

    # Decision pair for the Task 12 verifier: all seven profiles, both platforms.
    cal_rates = [dict(family=FIXTURE_FAMILY, language=lang, tokensPerScalarBp=3500) for lang in BODY_LANGUAGES]
    calibration = decision_resource_for(cal_rates)

    def pair_candidate(pid, platform_offset):
        c = candidate(pid, 0, 1, 0)
        for row in c['performance']:
            for s in row['samples']:
                s.update(embeddingUs=1, hydrationUs=1, endToEndUs=s['retrievalUs'] + 2)
            warm = [s['retrievalUs'] for s in row['samples']]
            row.update(warmP50Us=percentile(warm, 5000), warmP95Us=percentile(warm, 9500),
                       endToEndP50Us=percentile([s['endToEndUs'] for s in row['samples']], 5000),
                       endToEndP95Us=percentile([s['endToEndUs'] for s in row['samples']], 9500),
                       hydrationP95Us=1, gatePassed=warm_gate(row['chunks'], row['concurrent'], row['queries'],
                                                             percentile(warm, 9500)))
        c['ingest']['serverPeakRssBytes'] += platform_offset
        c['ingest']['combinedPeakRssBytes'] += platform_offset
        return c
    mac = report('macos', [pair_candidate(pid, 0) for pid in PROFILE_ORDER],
                 calibration_hash=calibration['payloadHash'])
    win = report('windows', [pair_candidate(pid, 1000) for pid in PROFILE_ORDER],
                 calibration_hash=calibration['payloadHash'])
    validate_report(mac)
    validate_report(win)
    cases.append(dict(name='decision-pair', kind='verify', mac=mac, windows=win, calibration=calibration,
                      expectedEligible=list(PROFILE_ORDER),
                      note='synthetic fixture-mode pair; release verification additionally requires mode live'))
    # Derived verifier cases patch decision-pair instead of repeating 11,200 samples:
    # apply each {path, value} replacement to a deep copy of {mac, windows, calibration}.
    cases.append(dict(name='missing-windows', kind='verify', derivedFrom='decision-pair',
                      patches=[dict(path=['windows'], value={})], error='missing_platform'))
    under = copy.deepcopy(calibration)
    under['provenance'][0]['promptHoldoutUndercounts'] = 1
    new_hash = payload_hash(under['bindings'], under['rates'], under['provenance'])
    cases.append(dict(name='prompt-undercount', kind='verify', derivedFrom='decision-pair',
                      patches=[dict(path=['calibration', 'provenance', 0, 'promptHoldoutUndercounts'], value=1),
                               dict(path=['calibration', 'payloadHash'], value=new_hash),
                               dict(path=['mac', 'calibrationHash'], value=new_hash),
                               dict(path=['windows', 'calibrationHash'], value=new_hash)],
                      error='calibration_failed'))
    cases.append(dict(name='corpus-mismatch', kind='verify', derivedFrom='decision-pair',
                      patches=[dict(path=['windows', 'corpus', 'hash'], value=hex64('0'))],
                      error='incomparable_reports'))
    return dict(contract='benchmark-report', version=1, backend=BACKEND, cases=cases)


# ------------------------------------------------------------ run fixture

def pack_reference():
    spec = importlib.util.spec_from_file_location('wp7_pack_reference', ROOT / 'tools' / 'contracts' / 'gen_fixtures.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_with(g, inp, tokens, share_bp, version):
    """Run the frozen WP8 builder reference under an injected estimator and evidence share."""
    original_tokens, original_share = g.context_tokens, g.CONST['pack']['evidenceShareBp']
    try:
        g.context_tokens = tokens
        g.CONST['pack']['evidenceShareBp'] = share_bp
        out = g.context_pack(copy.deepcopy(inp))
    finally:
        g.context_tokens = original_tokens
        g.CONST['pack']['evidenceShareBp'] = original_share
    if 'error' not in out:
        out['estimatorVersion'] = version
    return out


def v1_tokens(text, language):
    divisor = 4 if language == 'en' else 3
    return ((len(text) + divisor - 1) // divisor * 11500 + 9999) // 10000


def decision(status, profile_id, fetch_k, top_k, share):
    return dict(contract='embedding-decision', version=1, status=status, profileId=profile_id,
                parameters=dict(fetchK=fetch_k, topK=top_k, evidenceShareBp=share))


def tuning_reference(d):
    if d.get('status') == 'pending':
        return dict(fetchK=32, topK=16, evidenceShareBp=6000)
    p = d.get('parameters')
    if d.get('status') != 'accepted' or not isinstance(p, dict):
        raise ValueError('invalidTuning')
    f, t, s = p.get('fetchK'), p.get('topK'), p.get('evidenceShareBp')
    if not all(isinstance(v, int) and not isinstance(v, bool) for v in (f, t, s)) \
            or not (f >= t and t > 0 and f <= 1024 and 0 <= s <= 10000):
        raise ValueError('invalidTuning')
    return dict(fetchK=f, topK=t, evidenceShareBp=s)


def memory_peaks(samples):
    if not samples:
        raise ValueError('invalidSamples')
    last = None
    runner = server = combined = 0
    for s in samples:
        if s['runnerBytes'] < 0 or s['serverTreeBytes'] < 0 or s['atUs'] < 0 or (last is not None and s['atUs'] < last):
            raise ValueError('invalidSamples')
        last = s['atUs']
        both = s['runnerBytes'] + s['serverTreeBytes']
        if both > INT64_MAX:
            raise ValueError('invalidSamples')
        runner, server, combined = max(runner, s['runnerBytes']), max(server, s['serverTreeBytes']), max(combined, both)
    return dict(runnerBytes=runner, serverBytes=server, combinedBytes=combined)


def process_sample(ps_output, root_pid, runner_pid):
    rows = {}
    for line in ps_output.split('\n'):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 3 or not all(p.isdigit() for p in parts):
            raise ValueError('invalidSamples')
        pid, ppid, rss_kib = map(int, parts)
        if rss_kib * 1024 > INT64_MAX or pid in rows:
            raise ValueError('invalidSamples')
        rows[pid] = (ppid, rss_kib * 1024)
    if root_pid not in rows or runner_pid not in rows:
        raise ValueError('processUnavailable')
    children = {}
    for pid, (ppid, _) in rows.items():
        children.setdefault(ppid, []).append(pid)
    seen, stack = set(), [root_pid]
    while stack:
        pid = stack.pop()
        if pid in seen or pid == runner_pid:
            continue
        seen.add(pid)
        stack.extend(sorted(children.get(pid, [])))
    server = sum(rows[pid][1] for pid in seen)
    if server > INT64_MAX:
        raise ValueError('invalidSamples')
    return dict(runnerBytes=rows[runner_pid][1], serverTreeBytes=server, serverPids=sorted(seen))


DEFAULT_OPTIONS = dict(command='benchmark', mode='live', root='eval/multilingual', host=OLLAMA_ROOT,
                       profileIds=list(PROFILE_ORDER), chunkCounts=[100000, 200000], chatModel=CHAT_MODEL,
                       calibration=None, tokenizerRoot=None, embeddingCounts=None, queries=200, warmup=20,
                       concurrent='both', seed=17, fetchK=32, topK=16, evidenceShareBp=6000, runtimeContext=8192,
                       maxOutput=1024, ollamaPid=None, json=None, out=None)
FLAG_FIELDS = {'--mode': 'mode', '--root': 'root', '--host': 'host', '--profiles': 'profileIds',
               '--chunks': 'chunkCounts', '--chat-model': 'chatModel', '--calibration': 'calibration',
               '--tokenizer-root': 'tokenizerRoot', '--embedding-counts': 'embeddingCounts', '--queries': 'queries',
               '--warmup': 'warmup', '--concurrent': 'concurrent', '--seed': 'seed', '--fetch-k': 'fetchK',
               '--top-k': 'topK', '--evidence-share-bp': 'evidenceShareBp', '--runtime-context': 'runtimeContext',
               '--max-output': 'maxOutput', '--ollama-pid': 'ollamaPid', '--json': 'json', '--out': 'out'}
INT_FIELDS = {'queries', 'warmup', 'seed', 'fetchK', 'topK', 'evidenceShareBp', 'runtimeContext', 'maxOutput',
              'ollamaPid'}


def parse_options(args):
    """Reference for BenchmarkOptions.parse; every failure is invalidArguments (exit 2)."""
    o, seen, commands = copy.deepcopy(DEFAULT_OPTIONS), set(), []
    i = 0

    def number(text):
        if not text.isdigit() or not text.isascii() or len(text) > 10 or int(text) > INT32_MAX:
            raise ValueError('invalidArguments')
        return int(text)
    while i < len(args):
        a = args[i]
        if a in ('--benchmark', '--calibrate'):
            commands.append(a[2:])
            i += 1
            continue
        if a not in FLAG_FIELDS or a in seen or i + 1 >= len(args):
            raise ValueError('invalidArguments')
        seen.add(a)
        field, value = FLAG_FIELDS[a], args[i + 1]
        if field in INT_FIELDS:
            o[field] = number(value)
        elif field == 'profileIds':
            ids = list(PROFILE_ORDER) if value == 'all' else value.split(',')
            if not ids or len(ids) != len(set(ids)) or any(x not in PROFILE_BY_ID for x in ids):
                raise ValueError('invalidArguments')
            o[field] = ids
        elif field == 'chunkCounts':
            counts = [number(x) for x in value.split(',')]
            if len(counts) != len(set(counts)) or any(x <= 0 for x in counts):
                raise ValueError('invalidArguments')
            o[field] = counts
        else:
            if value == '':
                raise ValueError('invalidArguments')
            o[field] = value
        i += 2
    if len(commands) != 1:
        raise ValueError('invalidArguments')
    o['command'] = commands[0]
    if (o['mode'] not in ('live', 'fixture') or o['concurrent'] not in ('both', 'off', 'on')
            or o['json'] is None or o['out'] is None or o['json'] == o['out']
            or o['topK'] <= 0 or o['fetchK'] < o['topK'] or o['fetchK'] > 1024 or o['evidenceShareBp'] > 10000
            or o['maxOutput'] <= 0 or o['maxOutput'] >= o['runtimeContext'] or o['queries'] <= 0
            or (o['embeddingCounts'] is not None and (o['command'] != 'calibrate' or o['embeddingCounts'] != 'all'))
            or (o['ollamaPid'] is not None and o['ollamaPid'] <= 0)):
        raise ValueError('invalidArguments')
    if o['command'] == 'benchmark' and o['mode'] == 'live' and (o['calibration'] is None or o['ollamaPid'] is None):
        raise ValueError('invalidArguments')
    return o


def run_fixture():
    g = pack_reference()
    cases = []
    phases = ('inspect', 'ingest', 'quality')

    def trace(profiles, chunks, concurrent='both', stop=None):
        out = []
        for pid in profiles:
            for ph in phases:
                out.append(dict(phase=ph, profileId=pid, chunks=None))
            for c in chunks:
                if concurrent in ('both', 'off'):
                    for ph in ('cold', 'warmup', 'measure'):
                        out.append(dict(phase=ph, profileId=pid, chunks=c))
                if concurrent in ('both', 'on'):
                    out.append(dict(phase='concurrent', profileId=pid, chunks=c))
            out.append(dict(phase='verifyModels', profileId=pid, chunks=None))
            out.append(dict(phase='report', profileId=pid, chunks=None))
        if stop is not None:
            out = out[:stop]
        return out
    cases.append(dict(name='phase-order', kind='phase',
                      input=dict(profiles=['nomic-v2-256', 'bge-m3-1024'], chunkCounts=[1000, 2000],
                                 concurrent='both', queries=3, warmup=1),
                      expected=dict(trace=trace(['nomic-v2-256', 'bge-m3-1024'], [1000, 2000]),
                                    counters=dict(candidates=2, performanceRows=8, httpCalls=0, leakedPins=0,
                                                  measuredQueriesPerRow=3, warmupQueriesPerRow=1))))
    cases.append(dict(name='phase-concurrent-off', kind='phase',
                      input=dict(profiles=['paraphrase-768'], chunkCounts=[1000], concurrent='off', queries=3,
                                 warmup=1),
                      expected=dict(trace=trace(['paraphrase-768'], [1000], 'off'),
                                    counters=dict(candidates=1, performanceRows=1, httpCalls=0, leakedPins=0,
                                                  measuredQueriesPerRow=3, warmupQueriesPerRow=1))))
    cases.append(dict(name='cancel-query', kind='phase',
                      input=dict(profiles=['nomic-v2-256'], chunkCounts=[1000], concurrent='both', queries=3, warmup=1,
                                 cancelAt=dict(phase='concurrent', chunks=1000, measuredQuery=1)),
                      expected=dict(trace=trace(['nomic-v2-256'], [1000], stop=7), error='cancelled',
                                    counters=dict(completedMeasuredQueries=1, leakedPins=0, writerAwaited=True,
                                                  samplerAwaited=True, successArtifact=False,
                                                  privateDatabasesRemoved=True))))

    # Staging cases (Tasks 8a/9a): one notebook, published revisions, injected document embedder.
    identity = dict(providerId='fixture', endpointRevision='fixture', model='m', modelDigest=None, dims=2,
                    normalization='l2', queryFormatVersion='1', docFormatVersion='1', chunkerVersion='2')
    sources = [dict(sourceId=1, text='needle', publishedRevision=1), dict(sourceId=2, text='', publishedRevision=1)]

    def stage(name, script, expected, sources_=None, events=None, note=None):
        c = dict(name=name, kind='stage', identity=identity, sources=sources_ or sources,
                 activeBefore=dict(generationId=1, identity=identity), embedScript=script,
                 events=events or [], expected=expected)
        if note:
            c['note'] = note
        cases.append(c)
    stage('stage-success', [dict(inputs=['needle'], outcome='ok', vectors=[[1, 0]])],
          dict(error=None, embeddingRequests=1, stagedState='building', activeAfter=1,
               manifest=[dict(sourceId=1, state='done'), dict(sourceId=2, state='done')], vectorsWritten=1,
               publishedRevisionsUnchanged=True))
    stage('cancel-build', [dict(inputs=['needle'], outcome='cancel')],
          dict(error='cancelled', embeddingRequests=1, stagedState='retired', activeAfter=1, vectorsWritten=0,
               publishedRevisionsUnchanged=True))
    stage('failed-generation', [dict(inputs=['needle'], outcome='ok', vectors=[[1, 0, 0]])],
          dict(error='invalidEmbedding', embeddingRequests=1, stagedState='retired', activeAfter=1, vectorsWritten=0,
               publishedRevisionsUnchanged=True), note='store rejects wrong dimensions; no activation')
    stage('dual-revisions', [dict(inputs=['needle'], outcome='ok', vectors=[[1, 0]])],
          dict(error='staleRevision', embeddingRequests=1, stagedState='retired', activeAfter=1, vectorsWritten=0,
               publishedRevisionsUnchanged=False),
          events=[dict(afterRequest=1, kind='publishRevision', sourceId=1, revision=2, text='needle v2')],
          note='a refreshed revision published during the embedding await')
    stage('empty-publication', [], dict(error=None, embeddingRequests=0, stagedState='building', activeAfter=1,
                                        manifest=[dict(sourceId=2, state='done')], vectorsWritten=0,
                                        publishedRevisionsUnchanged=True),
          sources_=[dict(sourceId=2, text='', publishedRevision=1)])
    stage('refresh-pending', [], dict(error='refreshPending', embeddingRequests=0, stagedState=None, activeAfter=1,
                                      vectorsWritten=0, publishedRevisionsUnchanged=True),
          sources_=[dict(sourceId=1, text='needle', publishedRevision=1, currentRevision=2)])
    stage('identity-mismatch', [], dict(error='profileIdentityMismatch', embeddingRequests=0, stagedState=None,
                                        activeAfter=1, vectorsWritten=0, publishedRevisionsUnchanged=True),
          events=[dict(kind='sessionIdentity', identity=dict(identity, docFormatVersion='2'))],
          note='captured session identity differs from the requested identity; no generation is created')

    # Quality/citation cases (Tasks 8c/9c audit kernel).
    text = 'prefix gold'
    h = sha256_text(text)
    revision = dict(sourceId=1, revisionId=10, documentId='d', contentHash=h, text=text,
                    chunks=[dict(chunkId=100, sourceId=1, revisionId=10, ord=0)])
    base_cite = dict(marker=1, chunkId=100, sourceId=1, snippet='prefix', revisionId=10,
                     spans=[dict(start=0, end=6)], chunkIds=[100], text='prefix')
    gold = [dict(document_id='d', content_hash=h, start=7, end=11)]

    def audit(name, citations, answer, expected, gold_=None):
        cases.append(dict(name=name, kind='audit', revisions=[revision], citations=citations, answer=answer,
                          gold=gold if gold_ is None else gold_, expected=expected))
    packed_prefix = [dict(document_id='d', content_hash=h, start=0, end=6)]
    audit('truncated-away-gold', [base_cite], 'Claim [1] [99]',
          dict(packed=packed_prefix, snapshotsCorrect=1, snapshotsTotal=1, answerMarkersCorrect=1,
               answerMarkersTotal=2, answerGoldSupported=0, answerMarkersJudged=2,
               packedRecall=dict(status='measured', found=0, total=1, recall_bp=0)))
    audit('citation-wrong-revision', [dict(base_cite, revisionId=11)], '[1]',
          dict(packed=[], snapshotsCorrect=0, snapshotsTotal=1, answerMarkersCorrect=0, answerMarkersTotal=1,
               answerGoldSupported=0, answerMarkersJudged=1,
               packedRecall=dict(status='measured', found=0, total=1, recall_bp=0)))
    audit('citation-unknown-marker', [dict(base_cite, spans=[dict(start=0, end=11)], text=text, snippet=text)],
          'See [1] and [2] and [1].',
          dict(packed=[dict(document_id='d', content_hash=h, start=0, end=11)], snapshotsCorrect=1, snapshotsTotal=1,
               answerMarkersCorrect=2, answerMarkersTotal=3, answerGoldSupported=2, answerMarkersJudged=3,
               packedRecall=dict(status='measured', found=1, total=1, recall_bp=10000)))
    audit('citation-wrong-chunk', [dict(base_cite, chunkId=101, chunkIds=[101])], '[1]',
          dict(packed=[], snapshotsCorrect=0, snapshotsTotal=1, answerMarkersCorrect=0, answerMarkersTotal=1,
               answerGoldSupported=0, answerMarkersJudged=1,
               packedRecall=dict(status='measured', found=0, total=1, recall_bp=0)))
    audit('citation-text-mismatch', [dict(base_cite, text='prefiX', snippet='prefiX')], '[1]',
          dict(packed=[], snapshotsCorrect=0, snapshotsTotal=1, answerMarkersCorrect=0, answerMarkersTotal=1,
               answerGoldSupported=0, answerMarkersJudged=1,
               packedRecall=dict(status='measured', found=0, total=1, recall_bp=0)))
    audit('citation-duplicate-marker', [base_cite, dict(base_cite)], '[1]',
          dict(packed=[], snapshotsCorrect=0, snapshotsTotal=2, answerMarkersCorrect=0, answerMarkersTotal=1,
               answerGoldSupported=0, answerMarkersJudged=1,
               packedRecall=dict(status='measured', found=0, total=1, recall_bp=0)))
    audit('zero-evidence', [], 'Nothing found.',
          dict(packed=[], snapshotsCorrect=0, snapshotsTotal=0, answerMarkersCorrect=0, answerMarkersTotal=0,
               answerGoldSupported=0, answerMarkersJudged=0,
               packedRecall=dict(status='measured', found=0, total=1, recall_bp=0)))
    audit('no-gold-judged-zero', [base_cite], '[1]',
          dict(packed=packed_prefix, snapshotsCorrect=1, snapshotsTotal=1, answerMarkersCorrect=1,
               answerMarkersTotal=1, answerGoldSupported=0, answerMarkersJudged=0, packedRecall=dict(NA)), gold_=[])
    cases.append(dict(name='empty-selection', kind='query',
                      input=dict(scope=dict(kind='selection', sourceIds=[], folderIds=[]), caseType='empty_selection'),
                      expected=dict(embeddingCalls=0, chatCalls=0, retrievalCalls=0, citations=0, preparedHash=None,
                                    packedRecall=dict(NA))))
    cases.append(dict(name='overview', kind='query',
                      input=dict(scope=dict(kind='all'), caseType='overview',
                                 files=[dict(sourceId=1, folderId=1, relPath='a/x.txt', firstChunkId=10),
                                        dict(sourceId=2, folderId=1, relPath='b/y.txt', firstChunkId=20),
                                        dict(sourceId=3, folderId=1, relPath='c/z.txt', firstChunkId=None)]),
                      expected=dict(embeddingCalls=0, retrievalCalls=0, chatCalls=1, neighbourCalls=0,
                                    overview=dict(filesInScope=3, publishedCandidateFiles=2, filesIncluded=2),
                                    packedRecall=dict(NA))))
    cases.append(dict(name='hit-own-revision', kind='query',
                      input=dict(hits=[dict(branch='vector', chunkId=11, sourceId=1, revisionId=1, start=0, end=5),
                                       dict(branch='lexical', chunkId=21, sourceId=1, revisionId=2, start=0, end=5)],
                                 revisions=[dict(sourceId=1, revisionId=1, documentId='d', contentHash=hex64('1')),
                                            dict(sourceId=1, revisionId=2, documentId='d', contentHash=hex64('2'))]),
                      expected=dict(spans=[dict(document_id='d', content_hash=hex64('1'), start=0, end=5),
                                           dict(document_id='d', content_hash=hex64('2'), start=0, end=5)]),
                      note='each hit maps through its own revision, never source.currentRevision'))

    # Measurement cases (Tasks 8b/9b).
    cases.append(dict(name='overlap-required', kind='overlap',
                      input=dict(measuredStartUs=100, measuredEndUs=500, completionsUs=[50, 80, 600]),
                      error='insufficientIngestionOverlap'))
    cases.append(dict(name='overlap-observed', kind='overlap',
                      input=dict(measuredStartUs=150, measuredEndUs=500, completionsUs=[90, 150, 320, 600]),
                      expected=dict(completedWrites=2, overlapUs=170)))
    cases.append(dict(name='overlap-single-write', kind='overlap',
                      input=dict(measuredStartUs=100, measuredEndUs=500, completionsUs=[200]),
                      error='insufficientIngestionOverlap'))
    for name, chunks, dims in (('cold-new-cache', 100_000, 1024), ('cache-streamed', 200_000, 1024),
                               ('cache-small-dims', 200_000, 256)):
        charge = chunks * (dims * 4 + 32)
        cached = charge <= CACHE_BUDGET_BYTES
        cases.append(dict(name=name, kind='cache', input=dict(chunks=chunks, dims=dims, budgetBytes=CACHE_BUDGET_BYTES,
                                                              coldTicksUs=[1000, 251000]),
                          expected=dict(chargeBytes=charge, cacheMode='cached' if cached else 'streamed',
                                        coldCacheLoadUs=250000 if cached else None)))
    for name, ms in (('round-half-us', 0.0005), ('round-one-half-us', 0.0015), ('round-down', 0.0014),
                     ('round-whole', 2.0)):
        cases.append(dict(name=name, kind='rounding', input=dict(ms=ms), expected=dict(us=ms_to_us(ms))))
    cases.append(dict(name='fnv-abc', kind='fnv', input='abc', expected=fnv1a32('abc')))
    cases.append(dict(name='fnv-empty', kind='fnv', input='', expected=fnv1a32('')))
    cases.append(dict(name='fnv-cs', kind='fnv', input='search_document: Záruka platí.',
                      expected=fnv1a32('search_document: Záruka platí.')))
    for name, samples in (('memory-peaks', [(0, 80, 10), (1, 20, 70)]), ('memory-single', [(5, 3, 4)]),
                          ('memory-empty', []), ('memory-negative', [(0, -1, 4)]),
                          ('memory-decreasing-time', [(5, 1, 1), (4, 1, 1)])):
        rows = [dict(atUs=a, runnerBytes=r, serverTreeBytes=s) for a, r, s in samples]
        try:
            cases.append(dict(name=name, kind='memory', input=rows, expected=memory_peaks(rows)))
        except ValueError as error:
            cases.append(dict(name=name, kind='memory', input=rows, error=str(error)))
    for name, ps, root, runner in (
            ('process-tree', '  10     1  1000\n  11    10  2000\n  12    11  3000\n  13     1  4000\n  99     1   500\n',
             10, 99),
            ('process-parent-cycle', '10 12 1000\n11 10 2000\n12 11 3000\n99 1 500\n', 10, 99),
            ('process-runner-child-excluded', '10 1 1000\n99 10 500\n100 99 700\n', 10, 99),
            ('process-missing-root', '11 10 2000\n99 1 500\n', 10, 99),
            ('process-overflow', '10 1 9007199254740992\n99 1 500\n', 10, 99),
            ('process-malformed', '10 1 x\n99 1 500\n', 10, 99),
            ('process-duplicate-pid', '10 1 1000\n10 1 1000\n99 1 500\n', 10, 99)):
        inp = dict(psOutput=ps, rootPid=root, runnerPid=runner)
        try:
            cases.append(dict(name=name, kind='process', input=inp, expected=process_sample(ps, root, runner)))
        except ValueError as error:
            cases.append(dict(name=name, kind='process', input=inp, error=str(error)))

    # CLI parser cases (Tasks 8c/9c).
    def cli(name, args, note=None):
        try:
            c = dict(name=name, kind='cli', args=args, expected=parse_options(args))
        except ValueError as error:
            c = dict(name=name, kind='cli', args=args, error=str(error), exitCode=2)
        if note:
            c['note'] = note
        cases.append(c)
    base = ['--benchmark', '--mode', 'fixture', '--json', 'a.json', '--out', 'a.md']
    cli('cli-defaults', base)
    cli('cli-live-complete', ['--benchmark', '--profiles', 'nomic-v2-256,bge-m3-1024', '--chunks', '100000',
                              '--calibration', 'cal.json', '--ollama-pid', '4242', '--json', 'b.json', '--out', 'b.md'])
    cli('cli-calibrate', ['--calibrate', '--embedding-counts', 'all', '--tokenizer-root', 'tok', '--json', 'c.json',
                          '--out', 'c.md'])
    cli('cli-repeated', base + ['--queries', '200', '--queries', '1'])
    cli('cli-missing-json', ['--benchmark', '--mode', 'fixture', '--out', 'a.md'])
    cli('cli-missing-value', base + ['--queries'])
    cli('cli-overflow', base + ['--queries', '99999999999'])
    cli('cli-negative', base + ['--seed', '-1'])
    cli('cli-nondecimal', base + ['--top-k', '0x10'])
    cli('cli-unsupported', base + ['--foo', 'bar'])
    cli('cli-two-commands', ['--benchmark', '--calibrate', '--json', 'a', '--out', 'b'])
    cli('cli-no-command', ['--json', 'a', '--out', 'b'])
    cli('cli-fetch-below-top', base + ['--fetch-k', '8', '--top-k', '16'])
    cli('cli-share-above', base + ['--evidence-share-bp', '10001'])
    cli('cli-output-above-context', base + ['--max-output', '8192'])
    cli('cli-same-output', ['--benchmark', '--mode', 'fixture', '--json', 'same', '--out', 'same'])
    cli('cli-duplicate-profile', base + ['--profiles', 'bge-m3-1024,bge-m3-1024'])
    cli('cli-unknown-profile', base + ['--profiles', 'nomic-embed-text-v2-moe'])
    cli('cli-duplicate-chunks', base + ['--chunks', '1000,1000'])
    cli('cli-live-without-calibration', ['--benchmark', '--ollama-pid', '1', '--json', 'a', '--out', 'b'])
    cli('cli-live-without-pid', ['--benchmark', '--calibration', 'c', '--json', 'a', '--out', 'b'])
    cli('cli-embedding-counts-on-benchmark', base + ['--embedding-counts', 'all'])
    cli('cli-bad-mode', ['--benchmark', '--mode', 'demo', '--json', 'a', '--out', 'b'])
    cli('cli-bad-concurrent', base + ['--concurrent', 'yes'])

    # Runtime tuning (Tasks 15/16): input is a decision resource body.
    for name, d in (('tuning-pending', decision('pending', None, 32, 16, 6000)),
                    ('tuning-accepted', decision('accepted', 'nomic-v2-256', 48, 24, 7000)),
                    ('tuning-fetch-below-top', decision('accepted', 'nomic-v2-256', 16, 24, 6000)),
                    ('tuning-top-zero', decision('accepted', 'nomic-v2-256', 32, 0, 6000)),
                    ('tuning-share-above', decision('accepted', 'nomic-v2-256', 32, 16, 10001)),
                    ('tuning-fetch-above-cap', decision('accepted', 'nomic-v2-256', 1025, 16, 6000)),
                    ('tuning-unknown-status', decision('draft', 'nomic-v2-256', 32, 16, 6000))):
        try:
            cases.append(dict(name=name, kind='tuning', input=d, expected=tuning_reference(d)))
        except ValueError as error:
            cases.append(dict(name=name, kind='tuning', input=d, error=str(error)))
    missing = decision('accepted', 'nomic-v2-256', 32, 16, 6000)
    del missing['parameters']
    cases.append(dict(name='tuning-accepted-no-parameters', kind='tuning', input=missing, error='invalidTuning'))
    zero = copy.deepcopy(g.context_pack_input('basic-cs'))
    zero['evidenceBudgetCap'] = 0
    built = build_with(g, zero, v1_tokens, 7000, 1)
    cases.append(dict(name='tuning-zero-cap', kind='tuning-build',
                      input=dict(packFixture='basic-cs', evidenceBudgetCap=0,
                                 tuning=dict(fetchK=48, topK=24, evidenceShareBp=7000), estimatorVersion=1),
                      expected=dict(citationMap=built['citationMap'],
                                    evidenceSections=sum(1 for m in built['messages'] for s in m['sections']
                                                         if s['kind'] == 'evidence'),
                                    prepared=built)))
    for name, share in (('tuning-share-7000', 7000), ('tuning-share-6000', 6000)):
        out = build_with(g, g.context_pack_input('basic-cs'), v1_tokens, share, 1)
        cases.append(dict(name=name, kind='tuning-build',
                          input=dict(packFixture='basic-cs', evidenceBudgetCap=None,
                                     tuning=dict(fetchK=32, topK=16, evidenceShareBp=share), estimatorVersion=1),
                          expected=dict(citationMap=out['citationMap'],
                                        evidenceSections=sum(1 for m in out['messages'] for s in m['sections']
                                                             if s['kind'] == 'evidence'),
                                        prepared=out)))
    return dict(contract='benchmark-run', version=1,
                phases=['inspect', 'ingest', 'quality', 'cold', 'warmup', 'measure', 'concurrent', 'verifyModels',
                        'report'], cases=cases)


# --------------------------------------------------------- default policy

PROFILE_FOR_DEFAULT = 'nomic-v2-256'   # synthetic accepted decision for tests; not the WP7 choice


def recommendation(evidence, d):
    if d['contract'] != 'embedding-decision' or d['version'] != 1 or d['status'] not in ('pending', 'accepted'):
        raise ValueError('invalidDecision')
    if d['status'] == 'pending':
        if d['profileId'] is not None:
            raise ValueError('invalidDecision')
        return None
    if d['profileId'] is None:
        raise ValueError('invalidDecision')
    if d['profileId'] not in PROFILE_BY_ID:
        raise ValueError('unknownProfile')
    return None if any(evidence.values()) else d['profileId']


def default_fixture():
    cases = []
    fresh = dict(databaseExists=False, preferencesExist=False, completedOnboarding=False, explicitSelection=False,
                 convertedChatOnly=False)
    accepted = dict(contract='embedding-decision', version=1, status='accepted', profileId=PROFILE_FOR_DEFAULT)
    pending = dict(contract='embedding-decision', version=1, status='pending', profileId=None)
    for name, patch, d in (('fresh', {}, accepted), ('database-only', dict(databaseExists=True), accepted),
                           ('settings-only', dict(preferencesExist=True), accepted),
                           ('completed-onboarding', dict(completedOnboarding=True), accepted),
                           ('explicit-custom', dict(explicitSelection=True, preferencesExist=True), accepted),
                           ('explicit-old', dict(explicitSelection=True, preferencesExist=True, databaseExists=True,
                                                 completedOnboarding=True), accepted),
                           ('converted-chat-only', dict(convertedChatOnly=True, preferencesExist=True), accepted),
                           ('pending-decision', {}, pending),
                           ('second-launch', dict(databaseExists=True, preferencesExist=True,
                                                  completedOnboarding=True), accepted)):
        ev = dict(fresh, **patch)
        cases.append(dict(name=name, kind='install', input=dict(evidence=ev, decision=d),
                          expected=dict(applyProfileId=recommendation(ev, d))))
    for name, d in (('invalid-accepted-no-profile', dict(accepted, profileId=None)),
                    ('invalid-pending-with-profile', dict(pending, profileId=PROFILE_FOR_DEFAULT)),
                    ('invalid-status', dict(accepted, status='draft')),
                    ('invalid-contract', dict(accepted, contract='embedding-default')),
                    ('invalid-unknown-profile', dict(accepted, profileId='nomic-embed-text-v2-moe'))):
        try:
            recommendation(fresh, d)
            raise AssertionError(name)
        except ValueError as error:
            cases.append(dict(name=name, kind='install-invalid', input=dict(evidence=fresh, decision=d),
                              error=str(error)))
    sel = dict(providerId=OLLAMA_PROVIDER_ID, model=PROFILE_BY_ID[PROFILE_FOR_DEFAULT]['model'],
               profileId=PROFILE_FOR_DEFAULT)
    cases.append(dict(name='selection-exact', kind='selection', profileId=PROFILE_FOR_DEFAULT, expected=sel))
    cases.append(dict(name='identity-from-selection', kind='identity', selection=sel, endpointRevision='endpoint-v1:test',
                      modelDigest='sha256:test', chunkerVersion='1', effectiveLimit=None,
                      expected=dict(identity_for(PROFILE_FOR_DEFAULT, 'endpoint-v1:test', 'sha256:test', 512),
                                    chunkerVersion='1')))
    cases.append(dict(name='identity-model-mismatch', kind='identity', selection=dict(sel, model='other'),
                      endpointRevision='endpoint-v1:test', modelDigest=None, chunkerVersion='1', effectiveLimit=None,
                      error='profileIdentityMismatch'))
    cases.append(dict(name='identity-legacy-selection', kind='identity', selection=dict(sel, profileId=None),
                      endpointRevision='endpoint-v1:test', modelDigest=None, chunkerVersion='1', effectiveLimit=None,
                      error='profileRequired'))

    # Recoverable rebuild (Tasks 10b/11b). Two notebooks unless stated.
    def rebuild(name, operation, active, selection, journal, error=None, notebooks=2, note=None, staged='retired'):
        c = dict(name=name, kind='rebuild', notebooks=notebooks, operation=operation, expectedActive=active,
                 expectedSelection=selection, journalRetained=journal, expectedError=error,
                 expectedStagedState=staged)
        if note:
            c['note'] = note
        cases.append(c)
    rebuild('publish-complete', dict(failAt=None), 'new', 'new', False, staged='active',
            note='old generations retired by activation')
    rebuild('cancel-rebuild', dict(failAt='cancelAfterStage', notebook=1), 'old', 'old', False, 'cancelled')
    rebuild('cancel-before-stage', dict(failAt='cancelBeforeStage'), 'old', 'old', False, 'cancelled',
            staged=None)
    rebuild('cancel-before-journal', dict(failAt='cancelBeforeJournal'), 'old', 'old', False, 'cancelled')
    rebuild('failed-rebuild', dict(failAt='stage', notebook=1), 'old', 'old', False, 'stageFailed')
    rebuild('second-stage-fails', dict(failAt='stage', notebook=2), 'old', 'old', False, 'stageFailed')
    rebuild('second-activation-invalid', dict(failAt='activationTarget', notebook=2), 'old', 'old', False,
            'invalidGeneration', note='complete-set rollback; first target stays building, then retired')
    rebuild('notebook-set-changed', dict(failAt='addNotebookDuringStage'), 'old', 'old', False, 'rebuildScopeChanged')
    rebuild('settings-write-fails', dict(failAt='persist'), 'new', 'old', True, 'selectionPersistenceFailed',
            staged='active', note='activation committed; startup recovery finishes it')
    rebuild('persistence-retry', dict(failAt='persist', recover=2), 'new', 'new', False, 'selectionPersistenceFailed',
            staged='active', note='recover() persists and clears; a second recover() is a no-op')
    rebuild('reopen-after-activation', dict(failAt='crashAfterActivation', recover=1), 'new', 'new', False,
            staged='active')
    rebuild('crash-after-journal', dict(failAt='crashAfterJournal', recover=1), 'old', 'old', False,
            note='journal present, every target still building: retire staged, keep previous selection')
    rebuild('duplicate-operation', dict(failAt='concurrentRebuild'), 'new', 'new', False, 'rebuildInProgress',
            staged='active', note='second request rejected; first completes')
    rebuild('recovery-conflict', dict(failAt='mixedJournalTargets', recover=1), 'mixed', 'old', True,
            'rebuildRecoveryConflict', staged=None)
    rebuild('zero-notebooks', dict(failAt=None), 'none', 'new', False, notebooks=0, staged=None)

    # Ordinary import drains (Tasks 10c/11c).
    root = OLLAMA_ROOT
    nomic256 = identity_for('nomic-v2-256', endpoint_revision('ollama', root), digest('3'), 512)
    nomic768 = identity_for('nomic-v2-768', endpoint_revision('ollama', root), digest('3'), 512)
    sel256 = dict(providerId=OLLAMA_PROVIDER_ID, model='nomic-embed-text-v2-moe', profileId='nomic-v2-256')
    common = dict(canonicalText='Záruka platí.', tags=dict(models=[ollama_model('nomic-embed-text-v2-moe:latest',
                                                                               hex64('3'))]),
                  show=dict(model_info={'general.architecture': 'nomic-bert-moe',
                                        'nomic-bert-moe.context_length': 2048}),
                  transport=dict(nativeDims=768, vector=[1] + [0] * 767, promptTokens=7))

    def drain(name, selection, active, expected, events=None, note=None, revisions=None):
        c = dict(name=name, kind='drain', selection=selection, activeBefore=active, events=events or [],
                 source=dict(dict(publishedRevision=1, currentRevision=1), **(revisions or {})), **copy.deepcopy(common),
                 expected=expected)
        if note:
            c['note'] = note
        cases.append(c)
    modern = dict(result=1, requests=['search_document: Záruka platí.'], nativeDims=768, dims=256,
                  queryFormatVersion=nomic256['queryFormatVersion'], docFormatVersion=nomic256['docFormatVersion'],
                  activeIdentity=nomic256, published=True, jobState='done', rowsWritten=1)
    drain('fresh-import', sel256, None, modern)
    drain('restart-no-work', sel256, nomic256,
          dict(result=0, requests=[], published=False, jobState=None, rowsWritten=0, activeIdentity=nomic256,
               activeGenerationUnchanged=True), note='reopen with persisted selection; zero provider requests')
    drain('same-model-other-dims', sel256, nomic768, dict(modern, previousActiveRetired=True))
    drain('legacy-no-profile', dict(sel256, profileId=None, model='nomic-embed-text'), None,
          dict(result=None, requests=[], published=False, jobState=None, rowsWritten=0, activeIdentity=None),
          note='nil means the unchanged legacy drain runs')
    drain('refresh-pending', sel256, None,
          dict(result=None, error='refreshPending', requests=[], published=False, jobState='failed', rowsWritten=0,
               activeIdentity=None), revisions=dict(currentRevision=2))
    drain('lost-lease', sel256, None,
          dict(result=None, error='leaseLost', requests=['search_document: Záruka platí.'], published=False,
               jobState='queued', rowsWritten=1, activeIdentity=None),
          events=[dict(kind='advanceClock', seconds=301, after='request')],
          note='expired lease cannot activate; WP0 transition requeues with backoff')
    drain('selected-profile-changed', sel256, None,
          dict(result=None, error='selectionChanged', requests=['search_document: Záruka platí.'], published=False,
               jobState='cancelled', rowsWritten=1, activeIdentity=None),
          events=[dict(kind='changeSelection', after='request',
                       selection=dict(sel256, profileId='nomic-v2-768'))])
    drain('changed-active-during-request', sel256, None,
          dict(result=None, error='activeChanged', requests=['search_document: Záruka platí.'], published=False,
               jobState='cancelled', rowsWritten=1, activeIdentity=nomic768),
          events=[dict(kind='activateOther', after='request', identity=nomic768)])
    return dict(contract='embedding-default', version=1, cases=cases)


# ------------------------------------------------- calibration session

def session_fixture():
    g = pack_reference()
    rates = [dict(family=FIXTURE_FAMILY, language=lang, tokensPerScalarBp=5000) for lang in ('cs', 'en', 'und')]
    bindings = [dict(model=CHAT_MODEL, modelDigest=digest('a'), family=FIXTURE_FAMILY)]
    cases = []

    def capture(name, models, calibrated, calls, model=CHAT_MODEL, ptype='ollama', next_models=None,
                list_error=None, validations=None, note=None):
        c = dict(name=name, kind='capture', providerType=ptype, model=model, bindings=bindings, rates=rates,
                 models=models, calibrated=calibrated,
                 expectedTokens=estimate_text('a😀b', 'cs', FIXTURE_FAMILY if calibrated else 'unverified', rates),
                 identityCalls=calls)
        if list_error:
            c['listError'] = list_error
        if next_models is not None:
            c['nextModels'] = next_models
        if validations:
            c['validations'] = validations
        if note:
            c['note'] = note
        cases.append(c)
    capture('matching-digest', [ollama_model(CHAT_MODEL, hex64('a'))], True, 1)
    capture('prefixed-digest', [ollama_model(CHAT_MODEL, digest('a'))], True, 1)
    capture('different-digest', [ollama_model(CHAT_MODEL, hex64('b'))], False, 1)
    capture('missing-digest', [ollama_model(CHAT_MODEL, '')], False, 1)
    capture('truncated-digest', [ollama_model(CHAT_MODEL, 'a' * 12)], False, 1)
    capture('uppercase-digest', [ollama_model(CHAT_MODEL, 'A' * 64)], False, 1)
    capture('duplicate-model', [ollama_model(CHAT_MODEL, hex64('a')), ollama_model(CHAT_MODEL, hex64('a'))], False, 1)
    capture('missing-model', [ollama_model('llama3.2:1b', hex64('a'))], False, 1)
    capture('unknown-model', [ollama_model('mistral:7b', hex64('a'))], False, 0, model='mistral:7b')
    capture('alias-not-substring', [ollama_model('llama3.2:latest', hex64('a'))], False, 0, model='llama3.2')
    capture('remote-provider', [], False, 0, ptype='openai')
    capture('metadata-failure', [], False, 1, list_error='unavailable')
    capture('changed-before-send', [ollama_model(CHAT_MODEL, hex64('a'))], True, 1,
            next_models=[ollama_model(CHAT_MODEL, hex64('b'))],
            note='validate() throws identityChanged; zero chat requests')
    capture('same-across-retry', [ollama_model(CHAT_MODEL, hex64('a'))], True, 1, validations=2,
            note='two validate() calls succeed; identity calls total 3')
    cases.append(dict(name='metadata-cancellation', kind='capture-cancel', providerType='ollama', model=CHAT_MODEL,
                      bindings=bindings, rates=rates, models=[], identityCalls=1, error='cancelled'))
    cases.append(dict(name='validate-unavailable', kind='validate', providerType='ollama', model=CHAT_MODEL,
                      bindings=bindings, rates=rates, models=[ollama_model(CHAT_MODEL, hex64('a'))],
                      validateError='unavailable', error='identityUnavailable'))
    cases.append(dict(name='validate-cancellation', kind='validate', providerType='ollama', model=CHAT_MODEL,
                      bindings=bindings, rates=rates, models=[ollama_model(CHAT_MODEL, hex64('a'))],
                      validateError='cancelled', error='cancelled'))
    cases.append(dict(name='captured-root', kind='router', providerType='ollama', model=CHAT_MODEL, root=OLLAMA_ROOT,
                      bindings=bindings, rates=rates,
                      events=[dict(kind='prepare'), dict(kind='mutateRoot', value='http://10.0.0.2:11434'),
                              dict(kind='send')],
                      tagsResponses=[[ollama_model(CHAT_MODEL, hex64('a'))], [ollama_model(CHAT_MODEL, hex64('a'))]],
                      expected=dict(requests=[dict(method='GET', url=OLLAMA_ROOT + '/api/tags'),
                                              dict(method='GET', url=OLLAMA_ROOT + '/api/tags'),
                                              dict(method='POST', url=OLLAMA_ROOT + '/api/chat')],
                                    chatModel=CHAT_MODEL, calibrated=True)))
    cases.append(dict(name='guard-blocks-send', kind='router', providerType='ollama', model=CHAT_MODEL,
                      root=OLLAMA_ROOT, bindings=bindings, rates=rates,
                      events=[dict(kind='prepare'), dict(kind='send')],
                      tagsResponses=[[ollama_model(CHAT_MODEL, hex64('a'))], [ollama_model(CHAT_MODEL, hex64('b'))]],
                      expected=dict(requests=[dict(method='GET', url=OLLAMA_ROOT + '/api/tags'),
                                              dict(method='GET', url=OLLAMA_ROOT + '/api/tags')],
                                    error='identityChanged', assistantPersisted=False, previewRetained=True)))

    def coordinator(name, estimator_rates, family, expected_tokens):
        base = g.context_pack_input('basic-cs')
        inp = copy.deepcopy(base)
        inp.update(question='a😀b', fetchK=9, topK=3, neighbours=[])
        inp['model'].update(runtimeContext=4096, maxOutputTokens=512)
        tokens = lambda text, language: estimate_text(text, language, family, estimator_rates)
        prepared = build_with(g, inp, tokens, 4500, 2)
        question = prepared['messages'][-1]['sections'][-1]
        assert question['kind'] == 'question' and question['tokens'] == expected_tokens, (name, question)
        cases.append(dict(name=name, kind='coordinator', packFixture='basic-cs', question='a😀b', fetchK=9, topK=3,
                          runtimeContext=4096, maxOutputTokens=512, evidenceShareBp=4500,
                          transportEstimator=None if not estimator_rates else dict(family=family, rates=estimator_rates),
                          expectedQuestionTokens=expected_tokens, expectedEstimatorVersion=2,
                          expectedRequestedFetchK=9, expectedFinishes=1, packInput=inp, expectedPrepared=prepared))
    coordinator('coordinator-injects', rates, FIXTURE_FAMILY, 11)
    coordinator('explicit-tuning', [], 'unverified', 15)
    return dict(contract='token-calibration-session', version=1, cases=cases)


# ------------------------------------------------------------ assembly

def make_contracts():
    out = {
        'embedding-profiles-v1.json': profiles_fixture(),
        'embedding-strict-v1.json': strict_fixture(),
        'benchmark-report-v1.json': report_fixture(),
        'benchmark-run-v1.json': run_fixture(),
        'embedding-default-v1.json': default_fixture(),
        'token-estimate-v2.json': token_estimate_fixture(),
        'token-calibration-session-v1.json': session_fixture(),
    }
    return copy.deepcopy(out)


def make_resources():
    """Production projection: no cases, no fixture-only family, pending truthfully."""
    profiles = dict(contract='embedding-profiles', version=1, profiles=copy.deepcopy(PROFILES))
    estimate_res = estimate_resource()
    validate_estimate_resource(estimate_res, production=True)
    decision_res = decision('pending', None, 32, 16, 6000)
    for resource in (profiles, estimate_res, decision_res):
        assert 'cases' not in resource and FIXTURE_FAMILY not in canonical_json(resource)
    return {'embedding-profiles-v1.json': profiles, 'token-estimate-v2.json': estimate_res,
            'embedding-decision-v1.json': decision_res}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='Compare generated bytes without writing.')
    args = parser.parse_args()
    print(f'python {sys.version.split()[0]}', file=sys.stderr)
    targets = [(OUT / n, v) for n, v in make_contracts().items()] + [(RES / n, v) for n, v in make_resources().items()]
    bad = []
    for path, value in targets:
        data = render(value)
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                bad.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if bad:
        print('out of date: ' + ', '.join(bad))
        return 1
    print('ok' if args.check else f'wrote {len(targets)} benchmark files')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
