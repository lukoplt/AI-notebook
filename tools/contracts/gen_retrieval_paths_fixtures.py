#!/usr/bin/env python3
"""retrieval-paths-v1 reference: path and metadata matching for folder sources.

A folder's structure often carries the answer ("Client/2026/P-0001 Project/Offers/
20260617_offer.xlsx") while chunk text never names
client, year or document kind. This oracle ranks in-scope sources by how many of the
question's fts-query-v2 content tokens their relative path and title match, with year
signals from path segments, YYYYMMDD name prefixes and file mtime. Normative text:
docs/contracts/retrieval-paths-v1.md. Swift `PathMatcher.rank` and C# `PathMatcher.Rank`
must reproduce every expected output exactly. Standard library only; the tokenizer and
stem rules are imported from the fts-query-v2 reference.
"""

import argparse
import datetime
import json
from pathlib import Path

import gen_fixtures as pack
import gen_fts_query_v2_fixtures as fts

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = 'Tests/fixtures/contracts/retrieval-paths-v1.json'
OUTPUT_V2 = 'Tests/fixtures/contracts/retrieval-paths-v2.json'
MAX_MATCHING_FILES = 30

# v2 (§6): document-type classes in key form. A query term whose key starts with one of a
# class's stems is a type cue; it also matches every file key starting with any stem of its
# class (an English "offers" finds the Czech "Nabidky" folder). First class wins.
TYPE_CLASSES = [
    ('offer', ['nabid', 'ponuk', 'offer', 'proposal', 'quotation', 'angebot']),
    ('order', ['objednav', 'order', 'bestell']),
    ('contract', ['smlouv', 'smluv', 'zmluv', 'contract', 'agreement', 'vertrag']),
    ('invoice', ['faktur', 'invoice', 'rechnung']),
    ('tender', ['vyberov', 'tender', 'ausschreib']),
]


def query_terms(query):
    """fts-query-v2 steps 1-4 (content tokens) with the path-matching role of each."""
    unique, seen = [], set()
    for t in fts.tokens(query):
        k = fts.key(t)
        if k not in seen:
            seen.add(k)
            unique.append(t)
    content = ([t for t in unique if fts.key(t) not in fts.STOP] or unique)[:fts.MAX_TOKENS]
    terms = []
    for t in content:
        k = fts.key(t)
        year = len(k) == 4 and k.isascii() and k.isdigit() and 1900 <= int(k) <= 2099
        stem = k[:fts.stem_length(k)] if fts.prefixable(t) else None
        terms.append({'key': k, 'stem': stem, 'year': int(k) if year else None})
    return terms


def valid_date(k):
    if len(k) != 8 or not (k.isascii() and k.isdigit()):
        return None
    y, m, d = int(k[:4]), int(k[4:6]), int(k[6:])
    if not (1900 <= y <= 2099 and 1 <= m <= 12 and 1 <= d <= 31):
        return None
    return int(k)


def file_tokens(f):
    path = f['relPath'] if f['relPath'] is not None else ''
    keys = [fts.key(t) for t in fts.tokens(path + '/' + f['title'])]
    name = path.rsplit('/', 1)[-1] if path else f['title']
    return keys, [fts.key(t) for t in fts.tokens(name)]


def file_date(f, keys, name_keys):
    for group in (name_keys, keys):
        dates = [d for d in (valid_date(k) for k in group) if d is not None]
        if dates:
            return dates[-1]
    if f['mtime'] is not None:
        t = datetime.datetime.fromtimestamp(f['mtime'], tz=datetime.timezone.utc)
        return t.year * 10000 + t.month * 100 + t.day
    return 0


def matches(term, f, keys):
    if term['year'] is not None:
        y = term['year']
        if str(y) in keys or any((valid_date(k) or 0) // 10000 == y for k in keys):
            return True
        if f['mtime'] is not None:
            return datetime.datetime.fromtimestamp(f['mtime'], tz=datetime.timezone.utc).year == y
        return False
    if term['stem'] is not None:
        return any(k.startswith(term['stem']) for k in keys)
    return term['key'] in keys


def rank(query, files):
    terms = query_terms(query)
    if not terms or not files:
        return []
    rows = []
    for f in files:
        keys, name_keys = file_tokens(f)
        hits = [i for i, term in enumerate(terms) if matches(term, f, keys)]
        rows.append((f, hits, file_date(f, keys, name_keys)))
    n = len(files)
    df = [sum(1 for _, hits, _ in rows if i in hits) for i in range(len(terms))]
    best = max(len(hits) for _, hits, _ in rows)
    need = max(1, (len(terms) + 1) // 2)
    if best < need:
        return []
    out = [{'sourceId': f['sourceId'], 'matched': len(hits), 'weight': sum(n - df[i] for i in hits), 'date': date}
           for f, hits, date in rows if len(hits) == best]
    out.sort(key=lambda r: (-r['weight'], -r['date'], r['sourceId']))
    return out


# ---------------------------------------------------------------- v2 (§6)

def type_stems(k):
    for _, stems in TYPE_CLASSES:
        if any(k.startswith(stem) for stem in stems):
            return stems
    return None


def query_terms_v2(query):
    terms = query_terms(query)
    for term in terms:
        term['types'] = None if term['year'] is not None else type_stems(term['key'])
    return terms


def year_segment(segment):
    return len(segment) == 4 and segment.isascii() and segment.isdigit() and 1900 <= int(segment) <= 2099


def file_parts(f):
    """(directory segments, directory keys, name keys) of a file; loose files have no directories."""
    path = f['relPath'] if f['relPath'] is not None else ''
    segments = path.split('/')[:-1] if path else []
    dir_keys = [fts.key(t) for t in fts.tokens('/'.join(segments))]
    name = path.rsplit('/', 1)[-1] if path else ''
    name_keys = [fts.key(t) for t in fts.tokens(name + '/' + f['title'])]
    return segments, dir_keys, name_keys


def term_hit(term, keys):
    if term['stem'] is not None and any(k.startswith(term['stem']) for k in keys):
        return True
    if term['types'] is not None and any(k.startswith(stem) for k in keys for stem in term['types']):
        return True
    return term['stem'] is None and term['key'] in keys


def strength_v2(term, f, segments, dir_keys, name_keys):
    """0 = no match; year 3/2/1 (segment / key or date / undated file's mtime); others 2/1 (directory / name)."""
    keys = dir_keys + name_keys
    if term['year'] is not None:
        y = term['year']
        if str(y) in segments:
            return 3
        if str(y) in keys or any((valid_date(k) or 0) // 10000 == y for k in keys):
            return 2
        dated = any(year_segment(s) for s in segments) or any(valid_date(k) for k in keys)
        if not dated and f['mtime'] is not None:
            return 1 if datetime.datetime.fromtimestamp(f['mtime'], tz=datetime.timezone.utc).year == y else 0
        return 0
    if term_hit(term, dir_keys):
        return 2
    return 1 if term_hit(term, name_keys) else 0


def project_of(segments):
    """Directory below the last year segment, else the parent of the first type folder, else the file's directory."""
    years = [i for i, s in enumerate(segments) if year_segment(s)]
    if years:
        return '/'.join(segments[:min(years[-1] + 2, len(segments))])
    for i, segment in enumerate(segments):
        if i > 0 and any(type_stems(fts.key(t)) for t in fts.tokens(segment)):
            return '/'.join(segments[:i])
    return '/'.join(segments)


def rank_v2(query, files):
    """{'matches': [...], 'inventory': bool}: v1 tiers with v2 strengths, ordered by score."""
    terms = query_terms_v2(query)
    if not terms or not files:
        return {'matches': [], 'inventory': False}
    rows = []
    for f in files:
        segments, dir_keys, name_keys = file_parts(f)
        strengths = [strength_v2(t, f, segments, dir_keys, name_keys) for t in terms]
        hits = [i for i, v in enumerate(strengths) if v]
        rows.append((f, hits, sum(strengths), file_date(f, *file_tokens(f)), project_of(segments)))
    n = len(files)
    df = [sum(1 for row in rows if i in row[1]) for i in range(len(terms))]
    best = max(len(row[1]) for row in rows)
    if best < max(1, (len(terms) + 1) // 2):
        return {'matches': [], 'inventory': False}
    tier = [row for row in rows if len(row[1]) == best]
    out = [{'sourceId': f['sourceId'], 'matched': best, 'score': score, 'weight': sum(n - df[i] for i in hits),
            'date': date, 'project': project} for f, hits, score, date, project in tier]
    out.sort(key=lambda r: (-r['score'], -r['weight'], -r['date'], r['sourceId']))
    inventory = any(terms[i]['year'] is not None or terms[i]['types'] is not None for row in tier for i in row[1])
    return {'matches': out, 'inventory': inventory}


def ts(y, m, d):
    return int(datetime.datetime(y, m, d, 12, tzinfo=datetime.timezone.utc).timestamp())


def F(sid, rel, mtime=None, title=None):
    return {'sourceId': sid, 'relPath': rel, 'title': title or rel.rsplit('/', 1)[-1], 'mtime': mtime}


# Synthetic folder shaped like a sales archive: <Client>/<Year>/<P-nnnn Project>/<document type>/<file>.
ARCHIVE = [
    F(1, 'ACME/2026/P-0001 Portal/Nabidky/20260617_Migrace_portal.xlsx', ts(2026, 6, 17)),
    F(2, 'ACME/2026/P-0001 Portal/Nabidky/Nabidka_ACME_portal.pdf', ts(2026, 6, 18)),
    F(3, 'ACME/2026/P-0001 Portal/Objednávky/objednavka_podepsana.pdf', ts(2026, 7, 2)),
    F(4, 'ACME/2026/P-0002 Helpdesk/Nabidky/RE_ potvrzeni.msg', ts(2026, 3, 9)),
    F(5, 'ACME/2025/P-0003 Evidence majetku/Nabidky/ACME_Realizace_v4.docx', ts(2026, 9, 1)),
    F(6, 'ACME/2025/P-0003 Evidence majetku/Nabidky/20250312_Nabidka_v1.pdf', ts(2025, 3, 12)),
    F(7, 'ACMER/2026/P-0004 Cloud/Nabidky/20260201_Cloud.pdf', ts(2026, 2, 1)),
    F(8, 'Beta/2026/P-0005 Intranet/Vyberove_rizeni/Zadani_intranet.pdf', ts(2026, 1, 5)),
    F(9, 'Beta/2024/P-0006 Servis/Smlouvy/Rámcová smlouva Beta.docx', ts(2024, 5, 5)),
    F(10, 'Gamma/2026/P-0007 Provoz/Faktury/faktura_2026_03.pdf', ts(2026, 3, 31)),
    {'sourceId': 11, 'relPath': None, 'title': 'poznámky k nabídkám ACME 2026.txt', 'mtime': None},
]

CASES = [
    ('inventory-client-year', 'jaké nabídky jsme poslali v 2026 pro ACME?', ARCHIVE),
    ('inventory-year-phrase', 'Které nabídky pro ACME jsme poslali v roce 2026?', ARCHIVE),
    ('client-only-acronym', 'ACME', ARCHIVE),
    ('acronym-exact-other-client', 'nabídky ACMER', ARCHIVE),
    ('inflected-folder', 'smlouvy Beta', ARCHIVE),
    ('year-from-name-date', 'faktury 2026', ARCHIVE),
    ('below-threshold', 'jaká je výpovědní lhůta smlouvy o dílo', ARCHIVE),
    ('no-content-tokens', '?!', ARCHIVE),
    ('mtime-year-only', 'objednávka 2026', ARCHIVE),
    ('loose-title', 'poznámky nabídky', ARCHIVE),
]


def map_file(sid, rel, descriptor, rank=None, date=None, folder=7, metadata=False):
    f = {'sourceId': sid, 'folderId': folder, 'relPath': rel, 'displayName': rel.rsplit('/', 1)[-1],
         'descriptor': descriptor, 'metadataMatch': metadata, 'publishedRevisionId': sid * 10}
    if rank is not None:
        f['pathRank'] = rank
    if date is not None:
        f['matchDate'] = date
    return f


MAP_FILES = [
    map_file(1, 'ACME/2026/P-0001/Nabidky/20260617_Migrace.xlsx', 'xlsx, cs', rank=2, date=20260617),
    map_file(2, 'ACME/2026/P-0001/Nabidky/Nabidka.pdf', 'pdf, cs', rank=1, date=20260618),
    map_file(3, 'ACME/2026/P-0001/Objednavky/objednavka.pdf', 'pdf, cs'),
    map_file(4, 'ACMER/2026/P-0004/Nabidky/Cloud.pdf', 'pdf, cs', metadata=True),
    map_file(5, 'poznamky.txt', 'txt, cs', rank=3, folder=None),
]

# The map ceiling is in placeholder tokens (folder-rag-v1 §8 charging: 8 + ceil(scalars/3) x 1.15).
MAP_CASES = [
    ('matching-first', MAP_FILES, [], 10_000),
    ('matching-with-retrieved', MAP_FILES, [3], 10_000),
    ('matching-tight', MAP_FILES, [], 60),
    ('matching-header-only-misfit', MAP_FILES, [], 20),
    ('no-path-ranks-unchanged', [dict((k, v) for k, v in f.items() if k not in ('pathRank', 'matchDate')) for f in MAP_FILES], [], 10_000),
]


def build_map_cases():
    cases = []
    for name, files, direct, ceiling in MAP_CASES:
        section, included, omitted = pack.context_map({'folderMap': files}, ceiling, [{'sourceId': d} for d in direct])
        cases.append({'name': name, 'folderMap': files, 'directSourceIds': direct, 'ceiling': ceiling,
                      'expected': {'text': section['text'] if section else None, 'included': included, 'omitted': omitted}})
    return cases


def build():
    cases = []
    for name, query, files in CASES:
        for f in files:
            fts.host_agrees((f['relPath'] or '') + f['title'])
        fts.host_agrees(query)
        cases.append({'name': name, 'query': query, 'files': files, 'expected': rank(query, files)})
    return {'contract': 'retrieval-paths', 'version': 1, 'maxMatchingFiles': MAX_MATCHING_FILES, 'cases': cases,
            'mapCases': build_map_cases()}


# ---------------------------------------------------------------- v2 fixture (§6)

def archive_v2():
    """A larger synthetic sales archive: ACME 2026 offers spread over six projects, ACME 2025 projects
    whose files were touched in 2026 (mtime trap), a 2025 project with a 2026-dated archive file,
    an ACMER (acronym superset) project, Beta projects and a project without a year folder."""
    files, sid = [], 0

    def add(rel, mtime, title=None):
        nonlocal sid
        sid += 1
        files.append(F(sid, rel, mtime, title))

    for d in range(6):
        project = f'ACME/2026/P-01{d:02d} Projekt modernizace číslo {d + 1} pro centralni sklad a expedici'
        for v in range(4):
            add(f'{project}/Dokumenty_projektu/Nabidky/2026{d + 1:02d}{10 + v:02d}_Nabidka_modernizace_{d + 1}_verze_{v + 1}.docx',
                ts(2026, d + 1, 10 + v))
        add(f'{project}/Dokumenty_projektu/Objednávky/objednavka_{d + 1}.pdf', ts(2026, d + 2, 1))
        add(f'{project}/Dokumenty_projektu/Odhady/ODH_ACME_2026{d + 1:02d}01.xlsx', ts(2026, d + 1, 1))
    for d in range(4):
        project = f'ACME/2025/P-02{d:02d} Starší zakázka {d + 1} (archiv)'
        for v in range(3):
            add(f'{project}/Dokumenty_projektu/Nabidky/Nabidka_starsi_{d + 1}_{v + 1}.pdf', ts(2026, 9, 20 + v))
    add('ACME/2025/P-0200 Starší zakázka 1 (archiv)/Dokumenty_projektu/Nabidky/archiv/20260217_Výkaz_cen_revize.xlsx',
        ts(2026, 2, 17))
    for d in range(2):
        project = f'ACMER/2026/P-03{d:02d} Cloud {d + 1} - migrace'
        add(f'{project}/Dokumenty_projektu/Nabidky/20260301_Cloud_{d + 1}.pdf', ts(2026, 3, 1))
    for d in range(2):
        project = f'Beta/2026/P-04{d:02d} Intranet {d + 1} - provoz'
        add(f'{project}/Dokumenty_projektu/Nabidky/20260401_Intranet_{d + 1}.pdf', ts(2026, 4, 1))
    add('Gamma/P-0501 Portal - podpora/Nabidky_EN/Offer_portal.pdf', ts(2026, 5, 5))
    add('Gamma/P-0501 Portal - podpora/Nabidky_EN/Nabidka_portal_v2.pdf', ts(2026, 5, 6))
    add('Gamma/Smlouvy/ramcova_smlouva.pdf', ts(2024, 1, 1))
    add('Delta/readme.txt', ts(2026, 1, 2))
    files.append({'sourceId': sid + 1, 'relPath': None, 'title': 'poznámky k nabídkám ACME 2026.txt', 'mtime': None})
    return files


ARCHIVE_V2 = archive_v2()

CASES_V2 = [
    ('inventory-cs-2026', 'jaké nabídky jsme poslali v 2026 pro ACME?', ARCHIVE_V2),
    ('inventory-en-type-cue', 'Which offers did we submit to ACME in 2026?', ARCHIVE_V2),
    ('inventory-de-type-cue', 'Welche Angebote für ACME 2026?', ARCHIVE_V2),
    ('inventory-2025-no-mtime-leak', 'nabídky ACME 2025', ARCHIVE_V2),
    ('client-only-not-inventory', 'ACME', ARCHIVE_V2),
    ('type-folder-project', 'nabídky Gamma', ARCHIVE_V2),
    ('undated-mtime-year', 'readme 2026', ARCHIVE_V2),
    ('acronym-superset-kept-apart', 'nabídky ACMER 2026', ARCHIVE_V2),
] + [(name, query, files) for name, query, files in CASES]


def pack_files(files, ranking, folder=1, descriptor=lambda f: 'pdf, cs'):
    ranks = {m['sourceId']: (i + 1, m) for i, m in enumerate(ranking['matches'])}
    out = []
    for f in files:
        rel = f['relPath'] if f['relPath'] is not None else f['title']
        row = {'sourceId': f['sourceId'], 'relPath': rel, 'displayName': rel.rsplit('/', 1)[-1],
               'descriptor': descriptor(f), 'metadataMatch': False, 'publishedRevisionId': f['sourceId'] * 10}
        if f['relPath'] is not None:
            row['folderId'] = folder
        if f['sourceId'] in ranks:
            rank, match = ranks[f['sourceId']]
            row['pathRank'] = rank
            if match['date']:
                row['matchDate'] = match['date']
            row['matchProject'] = match['project'] if f['relPath'] is not None else ''
        out.append(row)
    return out


def map_cases_v2():
    query = 'jaké nabídky jsme poslali v 2026 pro ACME?'
    ranking = rank_v2(query, ARCHIVE_V2)
    files = pack_files(ARCHIVE_V2, ranking)
    few = pack_files(ARCHIVE_V2, rank_v2('nabídky Gamma', ARCHIVE_V2))
    cases = [
        ('grouped-by-project', files, [], 10_000, {'ceiling': 10_000, 'floorLimit': 10_000}),
        ('grouped-floor-raises-ceiling', files, [], 40, {'ceiling': 60, 'floorLimit': 400}),
        ('grouped-floor-limited', files, [], 40, {'ceiling': 60, 'floorLimit': 120}),
        ('grouped-header-misfit', files, [], 10, {'ceiling': 10, 'floorLimit': 20}),
        ('inventory-few-file-level', few, [], 10_000, {'ceiling': 10_000, 'floorLimit': 10_000}),
        ('not-inventory-file-level', files, [], 400, None),
    ]
    out = []
    for name, folder_map, direct, ceiling, budget in cases:
        section, included, omitted = pack.context_map({'folderMap': folder_map}, ceiling,
                                                      [{'sourceId': d} for d in direct], budget)
        out.append({'name': name, 'folderMap': folder_map, 'directSourceIds': direct, 'ceiling': ceiling,
                    'matchingBudget': budget,
                    'expected': {'text': section['text'] if section else None, 'included': included, 'omitted': omitted}})
    return out


def pack_cases_v2():
    query = 'jaké nabídky jsme poslali v 2026 pro ACME?'
    ranking = rank_v2(query, ARCHIVE_V2)
    files = pack_files(ARCHIVE_V2, ranking, descriptor=lambda f: 'Nabídka · docx · 3 strany')
    by_id = {f['sourceId']: f for f in files}
    body = ('Cenová nabídka na modernizaci informačního systému zahrnuje analýzu, implementaci, testování '
            'a zaškolení uživatelů. Harmonogram počítá se třemi etapami a průběžnou akceptací výstupů. ')
    passages = []
    for n, source in enumerate([1, 7, 13, 19, 25, 31]):
        f = by_id[source]
        passages.append(pack.context_literal_passage(source * 100, source, source * 10, 1, f['relPath'],
                                                     body * 3, score=30000 - n * 500))
    coverage = dict(filesInScope=len(files), searchable=len(files), pending=0, error=0, skipped=0, missing=0,
                    unavailable=0, refreshPending=0, refreshError=0, partial=False)
    seed = dict(question=query, mode='answer', userInstructions='', history=[], external=[], candidates=passages,
                neighbours=[], overviewCandidates=[], folderMap=files,
                scope=dict(kind='all', name='Archiv', sourceIds=[], folderIds=[], languages=['cs'],
                           lastFullScan='2026-10-12T00:00:00Z', scanState='idle'),
                coverage=coverage,
                model=dict(providerId='p', model='example/chat-model', providerType='openwebui',
                           runtimeContext=8192, maxOutputTokens=1024, contextWindowKnown=False),
                generationId=None, sourceRevisions={str(f['sourceId']): f['publishedRevisionId'] for f in files},
                evidenceBudgetCap=None, fetchK=32, topK=16, pathInventory=True)
    out = []
    for name, mutate in [
        ('inventory-8k', lambda i: None),
        ('inventory-4k', lambda i: i['model'].update(runtimeContext=4096)),
        ('inventory-2k-floor', lambda i: i['model'].update(runtimeContext=2048, maxOutputTokens=512)),
        ('same-input-not-inventory-8k', lambda i: i.pop('pathInventory')),
    ]:
        inp = json.loads(json.dumps(seed))
        mutate(inp)
        out.append({'name': name, 'input': inp, 'expected': pack.context_pack(inp)})
    return out


def build_v2(v1):
    cases, supersedes = [], {}
    v1_expected = {c['name']: c['expected'] for c in v1['cases']}
    for name, query, files in CASES_V2:
        for f in files:
            fts.host_agrees((f['relPath'] or '') + f['title'])
        fts.host_agrees(query)
        expected = rank_v2(query, files)
        cases.append({'name': name, 'query': query, 'files': files, 'expected': expected})
        if name in v1_expected:
            projected = [{k: m[k] for k in ('date', 'matched', 'sourceId', 'weight')} for m in expected['matches']]
            if projected != v1_expected[name]:
                supersedes[name] = projected
    return {'contract': 'retrieval-paths', 'version': 2, 'maxMatchingFiles': MAX_MATCHING_FILES,
            'typeClasses': [{'name': n, 'stems': stems} for n, stems in TYPE_CLASSES],
            'inventory': pack.INVENTORY, 'cases': cases, 'mapCases': map_cases_v2(), 'packCases': pack_cases_v2(),
            'supersedes': {'retrieval-paths-v1.json': {'cases': supersedes}}}


def render(fixture):
    return (json.dumps(fixture, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Compare generated bytes without writing.')
    args = parser.parse_args()
    v1 = build()
    outputs = [(OUTPUT, render(v1)), (OUTPUT_V2, render(build_v2(v1)))]
    if args.check:
        stale = [name for name, data in outputs if not (ROOT / name).is_file() or (ROOT / name).read_bytes() != data]
        for name in stale:
            print('out of date: ' + name)
        if stale:
            return 1
        print('ok')
        return 0
    for name, data in outputs:
        (ROOT / name).write_bytes(data)
        print('wrote ' + name)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
