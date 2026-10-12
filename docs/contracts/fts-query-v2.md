# FTS query terms — normative contract v2

*Status: 2026-10-11. Addendum to `folder-rag-v1.md` §7, which stays frozen: its builder is kept as `matchExpressionV1` / `MatchExpressionV1` and still reproduces `fts-query-v1.json`. Fixture: `Tests/fixtures/contracts/fts-query-v2.json`. Executable reference: `tools/contracts/gen_fts_query_v2_fixtures.py` (`--check` must pass; it runs every case against a real SQLite FTS5 table with the production tokenizer and asserts the recorded match). Swift `FTSQueryBuilder.matchExpression` and C# `FtsQueryBuilder.MatchExpression` produce the production lexical expression and must reproduce `expectedMatchExpr` byte for byte; their built-in `stopwords`, `suffixes`, `minStem` must equal the fixture's.*

## 1. Why

v1 OR-ed every query token as an exact phrase. A typical Czech question ("Jaké nabídky jsme poslali v 2026 pro ACME?") then (a) matched a large share of all chunks through function words (`jaké`, `v`, `pro`), making bm25 slow and its ranking dominated by noise, and (b) missed inflected forms: the index has no stemmer, so `smlouvy` never matched `smlouva`/`smlouvě`/`smlouvou`.

## 2. Algorithm

Index tokenizer is unchanged (`unicode61 remove_diacritics 2`). Scalar properties come from the pinned Unicode 15.1 tables (`UnicodeTables`, `lang-detector-v1.md` §2.1): General_Category, canonical decomposition, Simple_Lowercase_Mapping.

1. **Tokens** — exactly v1 §7 steps 1–2 (NFC; maximal runs starting with `L*`/`N*`/`Co`, continued by `M*`).
2. **Groups and key** — canonically decompose the token; each non-mark scalar starts a group, each mark joins the current group. `key` = the simple-lowercase of each group's base scalar (marks dropped). Example: `Nájemného` → key `najemneho`.
3. **Deduplicate by key**, first occurrence wins (`kůň kun KŮŇ` → `kůň`).
4. **Stopwords** — drop tokens whose key is in the union of the `cs`, `sk`, `en`, `de` lists. If that removes every token, keep all deduplicated tokens (v1 behaviour). Keep the first `maxFtsTokens` (32).
5. **Phrases**, per kept token in order:
   - the exact phrase `"tok"` (original NFC scalars, inner `"` doubled);
   - a **stem prefix** `"stem"*` iff the token is *prefixable*: ≥ `minStem` (4) groups, every base scalar is a letter (`L*`), and no base scalar after the first is `Lu`/`Lt` (acronyms and camel case stay exact: `ZXQV` must not match `ZXQVR`). `stemLength` = key length minus the **longest** listed suffix that the key ends with and that leaves ≥ `minStem` scalars; with no such suffix, the whole key. `stem` = NFC of the first `stemLength` groups (original scalars with their marks, so FTS5 folds it exactly as it folds documents). A prefix phrase already emitted is not repeated.
6. Join with `" OR "`. No tokens → no MATCH (lexical branch empty).

Suffix list (key form, longest first): `ungen osti ach ami ech eho emi emu ich imi imu ing ost ova ove ovi ovu ovy ung ych ymi ymu am ed ej em en es ho ia ie im iu mu om ou um ym a e i o s u y` (ties in code-point order). They cover Czech/Slovak case endings and German/English plural/inflection endings; the stem is only a prefix, so over-stemming costs ranking precision, never recall of the exact form (the exact phrase is always present and counts twice in bm25).

Stopword lists are deliberately conservative and leave out words that are content words in another supported language (`byt` = flat, `den` = day, `war`).

## 3. Behaviour recorded in the fixture

Inflection (`smlouvy` ↔ `smlouva`, `nájemného` ↔ `nájemné`, `zmluvy` ↔ `zmluva`, `Vertrags` ↔ `Vertrag`, `invoice` ↔ `invoices`), diacritic-free queries (`smlouve`), stopword-only fallback, acronym/camel-case exactness, digit-bearing identifiers (exact only), decomposed input, the 32-token cap and empty queries.

## 4. Consumers

`Retriever` (both platforms) builds the lexical expression with v2. The path/metadata search (`retrieval-paths-v1.md`) uses the same content tokens and stems. Evaluation reports compare against the v1 builder through the retained `matchExpressionV1`.
