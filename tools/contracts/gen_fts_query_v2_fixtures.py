#!/usr/bin/env python3
"""fts-query-v2 reference: multilingual lexical query terms for chunk and path search.

Addendum to folder-rag-v1 §7 (frozen v1 builder unchanged and still tested by
fts-query-v1.json). v2 keeps the v1 tokenizer and exact phrases, drops cs/sk/en/de
function words and adds one stem-prefix phrase per inflectable word, so a Czech
question finds "smlouva" when it asks about "smlouvy". Normative text:
docs/contracts/fts-query-v2.md. Swift (`FTSQueryBuilder.matchExpression`) and C#
(`FtsQueryBuilder.MatchExpression`) must reproduce `expectedMatchExpr` byte for byte
and their built-in stopword/suffix lists must equal the ones recorded here.

Scalar properties (General_Category, canonical decomposition, simple lowercase)
come from the pinned Unicode 15.1 tables in
Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json, the same file both
runtimes load. Every case is executed against a real SQLite FTS5 table with the
production tokenizer; the observed match is asserted and recorded.
Standard library only.
"""

import argparse
import json
import sqlite3
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = 'Tests/fixtures/contracts/fts-query-v2.json'
TABLES = json.loads((ROOT / 'Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json').read_text(encoding='utf-8'))
CONST = json.loads((ROOT / 'Tests/fixtures/contracts/constants-v1.json').read_text(encoding='utf-8'))
MAX_TOKENS = CONST['retrieval']['maxFtsTokens']
MIN_STEM = 4

# Function words in key form (simple lowercase, combining marks removed after NFD).
# Deliberately conservative: words that are also content words in another supported
# language are left out (cs "byt" = flat, cs "den" = day, en "war").
STOPWORDS = {
    'cs': """a aby ale ani asi az bez bude budou by byl byla byli bylo co coz do i jak jaka jake
        jaky jakou jakym je jeho jeji jejich jen jsem jsi jsme jsou jste k kam kde kdo kdy kdyz ke
        kolik ktera ktere kteri kterou ktery kterym ma maji mame mate me mezi mi mit mu muze my na
        nad nam nas ne nebo neni nez o od ode on ona oni ono pod podle pokud po pro proc protoze
        pri s se si sve ta tak take tam te ten tedy tento teto tim to tom tomu toto tu ty u uz v
        ve vsak z za ze zda najdi najit ukaz rekni vypis uved""",
    'sk': """a aby aj ak ako aka ake aky akym ale alebo ani bez bol bola boli bolo by co do este i
        ich je jeho jej k kde kedy kolko kto ktora ktore ktori ktory ku lebo ma maju na nad nie o
        od po pod podla pre preco pri s sa si so som sme ste su ta tak tam to tu uz v vo z za ze
        zo""",
    'en': """a about an and are as at be been by can could did do does find for from had has have
        how i in is it its me my of on or our please should show tell that the their there these
        this those to was were what when where which who whom why will with would you your""",
    'de': """aber als am an auch auf aus bei bin bis bitte das dass dem der des die ein eine einem
        einen einer eines er es fur gibt hat haben ich im in ist mit nach nicht oder sein sich sie
        sind so um und uns uber von vom was wann warum welche welcher welches wer wie wir wo zu
        zum zur""",
}
STOPWORDS = {lang: sorted(set(words.split())) for lang, words in STOPWORDS.items()}
STOP = set().union(*STOPWORDS.values())

# Inflectional endings in key form; the longest one leaving >= MIN_STEM key scalars is cut.
SUFFIXES = sorted(set("""
    ami emi ech ich ych ach ove ovi ova ovy ovu ost osti eho emu imu ymu ymi imi ou em om um am im
    ym ho mu ej ia ie iu a e i o u y en es s ing ed ungen ung
    """.split()), key=lambda s: (-len(s), s))

# ---------------------------------------------------------------- pinned scalar tables

CATEGORY_RANGES = TABLES['categories']
DECOMPOSITION = {cp: mapping for cp, mapping in TABLES['decomposition']}
LOWER = {cp: lower for cp, lower in TABLES['simpleLower']}


def category(cp):
    lo, hi = 0, len(CATEGORY_RANGES) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        start, end, name = CATEGORY_RANGES[mid]
        if cp < start:
            hi = mid - 1
        elif cp > end:
            lo = mid + 1
        else:
            return name
    return 'Cn'


def decompose(cp):
    # Hangul syllables never occur in fixtures; the runtimes decompose them algorithmically.
    assert not (0xAC00 <= cp <= 0xD7A3), 'Hangul is out of fixture scope'
    mapping = DECOMPOSITION.get(cp)
    if mapping is None:
        return [cp]
    return [x for m in mapping for x in decompose(m)]


def nfd_base(token):
    """Canonical decomposition, then grouped as (base scalar, its following marks)."""
    groups = []
    for ch in token:
        for cp in decompose(ord(ch)):
            if category(cp)[0] == 'M' and groups:
                groups[-1].append(cp)
            else:
                groups.append([cp])
    return groups


def host_agrees(text):
    for ch in text:
        cp = ord(ch)
        assert unicodedata.category(ch) == category(cp), (ch, 'host category differs from pinned UCD')
        assert [ord(c) for c in unicodedata.normalize('NFD', ch)] == decompose(cp), (ch, 'host NFD differs')

# ---------------------------------------------------------------- builder


def tokens(query):
    out, run = [], []
    for ch in unicodedata.normalize('NFC', query):
        cat = category(ord(ch))
        if cat[0] in 'LN' or cat == 'Co' or (run and cat[0] == 'M'):
            run.append(ch)
        else:
            if run:
                out.append(''.join(run))
            run = []
    if run:
        out.append(''.join(run))
    return out


def key(token):
    return ''.join(chr(LOWER.get(group[0], group[0])) for group in nfd_base(token))


def prefixable(token):
    groups = nfd_base(token)
    if len(groups) < MIN_STEM or any(category(g[0])[0] != 'L' for g in groups):
        return False
    # Acronyms and camel case (an upper-case letter after the first) stay exact: ZXQV != ZXQVR.
    return not any(category(g[0]) in ('Lu', 'Lt') for g in groups[1:])


def stem_length(k):
    for suffix in SUFFIXES:
        if k.endswith(suffix) and len(k) - len(suffix) >= MIN_STEM:
            return len(k) - len(suffix)
    return len(k)


def phrase(text):
    return '"' + text.replace('"', '""') + '"'


def match_expression(query):
    unique, seen = [], set()
    for t in tokens(query):
        k = key(t)
        if k not in seen:
            seen.add(k)
            unique.append(t)
    content = [t for t in unique if key(t) not in STOP] or unique
    phrases = []
    for t in content[:MAX_TOKENS]:
        phrases.append(phrase(t))
        if prefixable(t):
            groups = nfd_base(t)[:stem_length(key(t))]
            stem = unicodedata.normalize('NFC', ''.join(chr(cp) for g in groups for cp in g))
            p = phrase(stem) + '*'
            if p not in phrases:
                phrases.append(p)
    return ' OR '.join(phrases) if phrases else None

# ---------------------------------------------------------------- cases

CASES = [
    ('cs-inflection', 'Smlouva končí 31. prosince.', 'Kdy končí smlouvy?', True),
    ('cs-genitive', 'Nájemné činí 15 000 Kč měsíčně.', 'Jaká je výše nájemného?', True),
    ('cs-accusative', 'Faktury za elektřinu v březnu.', 'faktura elektřina', True),
    ('cs-plural', 'Výpovědní lhůta je dva měsíce.', 'lhůty', True),
    ('cs-no-diacritics', 'Smlouva o dílo s dodavatelem.', 'smlouve s dodavatelem', True),
    ('cs-stop-no-diacritics', 'Faktura byla uhrazena.', 'jake jsou faktury', True),
    ('cs-instrumental-plural', 'Pracuje se smlouvami.', 'smlouva', True),
    ('cs-short-exact', 'Daně a poplatky.', 'daň', False),
    ('sk-inflection', 'Zmluva o dielo bola podpísaná.', 'zmluvy o diele', True),
    ('de-compound-plural', 'Die Kündigungsfristen betragen drei Monate.', 'Wann endet die Kündigungsfrist?', True),
    ('de-genitive', 'Der Vertrag endet im Mai.', 'des Vertrags', True),
    ('en-plural', 'The invoices were paid in March.', 'When was the invoice paid?', True),
    ('acronym-exact', 'Nabídka pro ZXQVR na Azure.', 'ZXQV', False),
    ('acronym-and-word', 'Nabídka pro ZXQVR na Azure.', 'nabídky ZXQV 2026', True),
    ('camel-case-exact', 'SharePointServer migration', 'SharePoint', False),
    ('identifier', 'Invoice INV-2024-0042 was paid.', 'INV-2024-0042', True),
    ('alnum-exact', 'Doklad FV20240042 uhrazen.', 'FV2024', False),
    ('all-stopwords-fallback', 'To je ono.', 'to je ono', True),
    ('dedupe-by-key', 'Kůň a kun', 'kůň kun KŮŇ', True),
    ('decomposed-query', 'Podle smlouvy platí.', 'smlouvě', True),
    ('slovak-caron', 'Ľúbiť sa dá aj v zime.', 'Ľúbiť', True),
    ('emoji-only', 'anything', '❤️🎉', None),
    ('empty', 'anything', '', None),
    ('cap', 'token token', ' '.join(f'w{i}' for i in range(40)), False),
]


def fts_matches(doc, expr):
    con = sqlite3.connect(':memory:')
    con.execute("create virtual table t using fts5(text, tokenize='unicode61 remove_diacritics 2')")
    con.execute('insert into t values (?)', (doc,))
    return bool(list(con.execute('select 1 from t where t match ?', (expr,))))


def build():
    cases = []
    for name, doc, query, should in CASES:
        host_agrees(unicodedata.normalize('NFC', doc + query) + doc + query)
        expr = match_expression(query)
        if expr is None:
            assert should is None, (name, 'expected null')
            got = None
        else:
            got = fts_matches(doc, expr)
            assert got == should, (name, expr, got)
        cases.append({'name': name, 'documentText': doc, 'query': query,
                      'expectedMatchExpr': expr, 'shouldMatchDocument': got})
    return {'contract': 'fts-query', 'version': 2, 'provisional': False,
            'maxTokens': MAX_TOKENS, 'minStem': MIN_STEM,
            'stopwords': STOPWORDS, 'suffixes': SUFFIXES, 'cases': cases}


def render(fixture):
    return (json.dumps(fixture, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Compare generated bytes without writing.')
    args = parser.parse_args()
    path = ROOT / OUTPUT
    data = render(build())
    if args.check:
        if not path.is_file() or path.read_bytes() != data:
            print('out of date: ' + OUTPUT)
            return 1
        print('ok')
        return 0
    path.write_bytes(data)
    print('wrote ' + OUTPUT)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
