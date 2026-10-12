# Path and metadata matching — normative contract v1

*Status: 2026-10-11. Extends `folder-rag-v1.md` (frozen) without changing its fixtures: inputs without the new fields render and fuse exactly as before. Fixture: `Tests/fixtures/contracts/retrieval-paths-v1.json` (`cases`: ranking; `mapCases`: the map section). Executable reference: `tools/contracts/gen_retrieval_paths_fixtures.py` (`--check`), which reuses the fts-query-v2 reference for tokens and the folder-rag-v1 reference (`gen_fixtures.context_map`, extended backward-compatibly) for the map. Swift `PathMatcher`, `Retriever`, `ContextPackRendering.map`; C# `PathMatcher`, `Retriever`, `ContextPackRendering.RenderMap`. **Addendum v2 (2026-10-12, §6):** inventory questions — fixture `retrieval-paths-v2.json` (same generator; the v1 fixture is byte-identical, its changed ranking cases are replaced through `supersedes`).*

## 1. Why

In a sales or project archive the answer to "jaké nabídky jsme poslali v 2026 pro ACME?" lives in the folder structure (e.g. `<Client>/<Year>/<P-nnnn Project>/Nabidky/<YYYYMMDD>_<name>`), not in chunk text. Neither BM25 over chunks nor embeddings can list those files, and the folder map listed directories in alphabetical order until the budget ran out.

## 2. Terms

The question's terms are its fts-query-v2 content tokens (stopwords removed, deduplicated by key, ≤ 32). Per term: its key; its stem key when prefixable (fts-query-v2 §2.5; acronyms such as `ZXQV` are never prefixes, so `ZXQV` does not match `ZXQVR`); and a **year** when the key is four ASCII digits in 1900…2099.

## 3. Ranking

Files: the scope's sources with a published revision (`relPath`, `title`, `mtime` in UTC seconds; `sources.mtime` is stored in nanoseconds). A file's keys are the token keys of `relPath + "/" + title` (the folder root is not included). A term matches a file when:

- year `Y`: a key equals `Y`, or an 8-digit key is a valid date `YYYYMMDD` (1900–2099, month 1–12, day 1–31) with year `Y`, or the UTC year of `mtime` is `Y`;
- prefixable term: some key starts with its stem key;
- otherwise: some key equals its key.

`matched` = number of matching terms; `df(t)` = number of files term `t` matches; `weight` = Σ over matched terms of `files − df(t)`. `date` = the last valid `YYYYMMDD` key of the file name, else of the whole path, else the UTC date of `mtime`, else 0. Let `best` = the maximum `matched`. If `best < max(1, ⌈terms / 2⌉)` there is no match. Otherwise the result is every file with `matched == best`, ordered by weight descending, date descending, source id ascending.

## 4. Retrieval branch

`Retriever` ranks the pinned scope once per query. The lowest-ordinal chunk of each of the first `fetchK` matched files' published revision forms the **path branch**, re-filtered by the permission mask on every revocation pass. Integer RRF (`rrfK`) fuses lexical, vector and path branches with identical rules; an empty path branch leaves fusion unchanged. `PinnedRetrievalCandidates.path` and `.pathMatches` (the permitted best tier) expose them.

## 5. Context pack: matching files

`PackFile.pathRank` (1-based position in §3's order) and `PackFile.matchDate` (`YYYYMMDD`, omitted when 0) are optional and omitted from JSON when absent. When any published file has a `pathRank`, the map section starts with

```
Matching files (path, name or date; best first): <n>
  <relPath> — <descriptor> [match YYYY-MM-DD]      (or [match] without a date)
```

for the first 30 files by `(pathRank, sourceId)`, admitted line by line while the map ceiling allows; the block's ledger identity is `group:matching`, each admitted file `file:<id>`. Admitted files are not repeated in their directory group (group counts are unchanged). If even the header does not fit, `group:matching` is omitted and the files stay in their groups. The map keeps its existing budget share (`mapMaxShareBp`); evidence, history and note/web budgets are unchanged.

## 6. Addendum v2 (2026-10-12): inventory questions

In a large archive at the 8 192-token default context, v1 answered an inventory question such as "jaké nabídky jsme poslali v 2026 pro ACME?" with files of a 2025 project that were touched in 2026 (§3's mtime signal matched and their newer date sorted them first), and the 2026 projects never reached the budgeted map (the synthetic v2 archive contains this mtime trap). v2 changes ranking, rendering and budget for such questions; everything else in §1–§5 stands. Fixture `retrieval-paths-v2.json`: `typeClasses`, `inventory` (constants), `cases` (ranking: `{matches, inventory}`), `mapCases` (map section with an optional `matchingBudget`), `packCases` (whole prepared requests, placeholder estimator, tuning v1), `supersedes["retrieval-paths-v1.json"].cases` (v1 cases whose `{sourceId, matched, weight, date}` list changed; every harness of the v1 fixture applies it).

### 6.1 Terms and strengths

A non-year term is a **document-type cue** when its key starts with a stem of one of these classes (key form, first class wins): offer `nabid ponuk offer proposal quotation angebot`; order `objednav order bestell`; contract `smlouv smluv zmluv contract agreement vertrag`; invoice `faktur invoice rechnung`; tender `vyberov tender ausschreib`. A cue also matches any file key starting with any stem of its class ("offers" finds `Nabidky`).

A file's **segments** are the `/`-separated directories of `relPath` (not the file name; none for a loose file); its directory keys are the token keys of the segments joined by `/`, its name keys those of `<file name>/<title>`. A **year segment** is a whole segment of four ASCII digits in 1900…2099. Each term gets a strength (0 = no match):

- year `Y`: **3** when a segment equals `Y`; else **2** when a key equals `Y` or is a valid date of year `Y`; else **1** when the file has no year segment and no valid date key at all and its mtime (UTC) year is `Y`; else 0. *A dated path or name is authoritative: `ACME/2025/…` no longer matches 2026 through its mtime (a deliberate change from §3).*
- other terms (§3 rule, plus the cue rule): **2** when a directory key matches, else **1** when a name key matches.

`matched` = number of terms with strength > 0; `df`, `weight`, `date`, the tier threshold and the best tier are §3's. `score` = Σ strengths. Order: score desc, weight desc, date desc, source id asc. A match also carries its **project**: the segments up to and including the one after the last year segment (all segments when the year is the last one); else, the segments before the first segment (index ≥ 1) containing a cue key; else all segments (`""` for none). The ranking is an **inventory** ranking when some best-tier file matched a year term or a cue term.

### 6.2 Map: matching block

`PackFile.matchProject` (optional, omitted when null) carries the project; `ContextPackInput.pathInventory` (optional, written only when `true`) carries the inventory signal; the adapter sets both from the retriever's ranking (`PinnedRetrievalCandidates.pathInventory`). Without `pathInventory` the map is §5 exactly. With it (and at least one published `pathRank`):

- At most `fileLevelMax` = 8 matching files: §5's file lines.
- More: every matching file (not only 30) is grouped by `(folderId, matchProject ?? directory of relPath)` in `(pathRank, sourceId)` order; at most 30 project lines, in order of their best member:

```
Matching files by project (path, name or date; best first): <files> files in <projects> projects
  <project or .> — <n> file[s] (<ext>, …), dates YYYY-MM-DD–YYYY-MM-DD, e.g. <name>, <name>
```

  Extensions: ASCII-lowercased text after the last `.` of `displayName` when that dot is neither first nor last, distinct, scalar order, the parenthesis omitted when none. Dates: min and max of the members' `matchDate`; `date YYYY-MM-DD` when equal; omitted when none. Examples: the first two members' `displayName`. Every inserted text is escaped like §5. Ledger: an admitted line adds `project:<folder|loose>:<project or .>` and `file:<id>` of every member; members are then not repeated in their directory groups.
- The block is admitted line by line (a line that does not fit is skipped, later lines may fit) against its own limit `L = max(matchingBudget.ceiling, min(F, matchingBudget.floorLimit))`, where `F` is the charged cost of the header plus the first `floorEntries` = 5 entries. Directory groups that follow keep the §5 ceiling (`mapMaxShareBp` of the remainder), so they only fit when the block left room within it.

### 6.3 Budget

For an inventory input the builder passes `matchingBudget = {ceiling: share(remaining, 3 500 bp), floorLimit: share(remaining, 5 000 bp)}` to the map, then calls the §8 budget with two optional inputs: `mapCeilingTokens` = the rendered map's cost (replaces `share(r, mapMaxShareBp)` as the map's cap) and `evidenceCeilingTokens` = `remaining − mapCost − noteWebCost` (an extra upper bound on the evidence target). Absent, the budget is folder-rag-v1 §8 byte for byte (all frozen budget and context-pack fixtures are unchanged). Evidence therefore only loses what the matching block actually uses; at the 8 192 default the 35 % share holds ≥ 15 grouped project lines.

