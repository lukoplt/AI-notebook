# Folder RAG — normative contract v1

*Status: WP0, frozen 2026-10-09 (§7 FTS query frozen in WP5 after both production SQLite conformance runs); includes the jointly directed cross-review corrections before release. These corrections retain the unreleased fixture versions (including citations v2). This contract governs where the earlier spec is less precise or conflicts with those corrections. Spec: `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md`. Parameters: `Tests/fixtures/contracts/constants-v1.json` (`RagContractV1` in code). Executable reference: `tools/contracts/gen_fixtures.py` — it generates the expected values of every algorithm fixture below; `python3 tools/contracts/gen_fixtures.py --check` must pass. Swift and C# must reproduce every fixture output exactly.*

Conventions: integer arithmetic only; `share(x, bp) = floor(x × bp / 10000)`; `ceilDiv(a, b) = floor((a + b − 1) / b)` for `a ≥ 0, b > 0`; "scalar" = Unicode scalar value; string order = lexicographic over scalar values (not locale, not UTF-16 units).

## 1. Scope and eligibility

`RetrievalScope = all | selection(sourceIds, folderIds)` (type + JSON: `scope-v1.json`). `union` of scopes: any `all` → `all`, else set unions; union of none = empty selection.

**Eligible source** for a turn — all must hold:

1. source has `notebook_id` = the chat's notebook;
2. scope is `all`, or source id ∈ `sourceIds`, or the source's `folder_id` ∈ `folderIds` (current membership, evaluated per turn);
3. `sources.availability = 'present'` and `sources.eligible = 1`.

`sources.published_revision_id` is nullable and references the source's **latest fully chunked revision**. Publication updates this pointer atomically only after the complete chunk set is ready; a failed or unfinished refresh leaves the old pointer unchanged. This publication is independent of vector generation activation.

- BM25, metadata, neighbours, the folder map and Overview use eligible sources' `published_revision_id`. A null pointer contributes no published chunks.
- The vector branch uses each eligible source's manifest revision with `state='done'` in the active generation pinned at query start. This revision may be older than `published_revision_id`. With no active generation, the vector branch is empty; lexical retrieval still uses published revisions.
- Every hit carries its own `revisionId`; evidence is hydrated from that revision, never silently substituted with the latest one. Neighbour candidates follow the published-revision rule and may be merged with a hit only when their revision IDs agree. Prepared requests retain every referenced revision, including multiple revisions of one source if both branches contribute.

Empty selection → return `[]` **without querying**. The same notebook, scope, availability and eligibility predicate filters every branch; revision membership follows the rules above. `legacy-generation-v1.json` supplies fixture-backed migration and lexical-fallback examples; WP3/WP5 add the SQL behaviour fixtures.

## 1b. State transitions and frozen DTO field lists

`job-transitions-v1.json` supplies reference job transitions now; database/concurrency fixtures and the other tables' fixtures are authored in their implementing WP and reviewed by both owners.

**Folder scan (`folder_sources.scan_state`)**

| From | Event | To | Effects |
|---|---|---|---|
| any but `scanning` | scan requested | `scanning` | `scan_generation += 1` |
| `scanning` | enumeration finished, every subtree completed | `idle` | missing-marking for all unseen files; `last_full_scan_at = now` |
| `scanning` | some subtrees incomplete (cancel, permission error) | `partial` | missing-marking only inside completed subtrees |
| `scanning` | root inaccessible | `unavailable` | no missing-marking; sources keep their availability except root-level `unavailable` |
| `scanning` | unexpected error | `error` | `last_scan_error` set; nothing marked |

A subtree is *completed* when every directory in it was listed without error in the current `scan_generation`.

**Eligibility**: rules change → recompute `eligible` for every source of the folder in one transaction; `0` removes it from all retrieval branches and the cache immediately; availability untouched.

**`ingest_jobs.state`**: `attempts` starts at zero and counts attempts **started**, including attempts that fail normally. All state changes below are atomic and conditional on the stored state/token; `now` and fixture times are integer epoch seconds.

| From | Event/condition | To | Effects |
|---|---|---|---|
| `queued` | start, `attempts < 5`, `now >= next_retry_at` if set | `running` | Increment `attempts` once; issue a fresh, never-reused `lease_token`; `lease_until = now + 300`; clear `next_retry_at` |
| `running` | renewal every 60 s, matching token and `now < lease_until` | `running` | `lease_until = now + 300`; attempts unchanged |
| `running` | failure, matching unexpired token, `attempts < 5` | `failed` (retryable) | Clear lease/token; `next_retry_at = now + 2^attempts × 30` |
| `failed` | retryable and `now >= next_retry_at` | `queued` | Attempts unchanged; the next start increments them |
| `running` | lease expires, `attempts < 5` | `queued` | Clear lease/token; `next_retry_at = now + 2^attempts × 30`; attempts unchanged |
| `running` | failure or lease expiry, `attempts = 5` | `failed` (terminal) | Clear lease/token and retry time; no further automatic starts/retries |
| `running` | publish, matching unexpired token and still-requested `target_revision` | `done` | Publish result and clear lease/token atomically |
| `running` | current worker completes a superseded `target_revision` | `cancelled` | Publish nothing; clear lease/token |
| `queued` / `paused` | user pauses / resumes | `paused` / `queued` | Attempts unchanged; retry deadline still applies |

Publishing, failing and renewing require the worker's `lease_token` to match the stored token **and** its lease to be unexpired. A stale/expired worker is rejected without changing the replacement's job or publishing any result. The target-revision check alone does not fence duplicate workers. At exhaustion a user-requested retry must create a new job; it cannot reset an exhausted job's counter.

The reference fixture uses input `{job: {state, attempts, nextRetryAt, leaseUntil, leaseToken, targetRevision}, event: {kind, now, leaseToken?, requestedRevision?}}` and output `{job, accepted, published}` for start/fail/retry/expire/renew/publish. Nullable lease/retry fields are explicit nulls; start events supply a fresh token, and publish events supply the requested revision. A rejected event preserves the entire job. The pure reference assumes the scheduler supplies never-reused start tokens; WP6 verifies generated-token uniqueness, the atomic SQL fence and the 60-second renewal schedule.

**Generations (`index_generations.state`)**: `building → active` (activation preconditions §4) `→ retired`; `building → failed` (unrecoverable) or discarded by user; at most one `active` per notebook — activation retires the previous one in the same transaction. GC deletes vectors of `retired` generations and chunks of revisions referenced by no `sources.published_revision_id`, no `active`/`building` generation and no running query/prepared request.

**Coverage** (§2) counts from one read transaction.

**Frozen DTO fields**

- `provider_model_limits(provider_id, model, context_window INTEGER NULL, runtime_context INTEGER NOT NULL, max_output_tokens INTEGER NOT NULL, source TEXT CHECK IN ('auto','user'))`, PK `(provider_id, model)`.
- `source_revisions(id, source_id, revision INTEGER, content_hash TEXT, canonical_text TEXT, text_format_version INTEGER, chunker_version INTEGER, created_at)`, unique `(source_id, revision)`.
- `sources.published_revision_id INTEGER NULL` → `source_revisions.id`; the referenced revision must belong to that source. `ingest_jobs.lease_token TEXT NULL` is the attempt's fencing identity.
- Prepared request: `{ estimatorVersion, model {providerId, model, runtimeContext, maxOutputTokens, contextWindowKnown}, messages [{role, sections [{kind, text, tokens}]}], options {numCtx?, maxTokens?}, citationMap, included [...], omitted [{kind, id, reason}], coverage {corpus, turn}, generationId (nullable), sourceRevisions [{sourceId, revisionId}] }` (unique source/revision pairs, ordered by source ID then revision ID).
- Citation map entry = citations v2 item (`citations-v2.json`): `marker, chunkId (= chunkIds[0]), sourceId, snippet, folderId?, relPath?, displayName?, revisionId?, spans [{start, end, pageFrom?, pageTo?}], chunkIds [...], text`.

## 2. Coverage categories

All counts come from one read snapshot. Availability/eligibility categories are disjoint: `missing` and `unavailable` take precedence for known sources; among present files, `skipped` comes from `scan_items.kind='skipped'` (ignored, unsupported extension, size limit). After applying this precedence, **eligible present files = eligible `scan_items` ∪ eligible present `sources`**, within the notebook and scope. Match a scan item to its source by `(folder_id, rel_path)` so each file is counted once. An eligible present scan item with no `sources` row yet is an observed change awaiting extraction and contributes `notSearchable + refreshPending`. Such scan-only files enter the scope through their folder (`all` or a selected folder ID).

For eligible present files, report **two separate dimensions**, not a sum:

- Corpus: `searchable` = has `published_revision_id`; `notSearchable` = has none. Vector-generation state does not change this published/searchable count.
- Freshness, with disjoint precedence: `refreshError` first (`sources.status='error'`, including extraction failure, unsupported encoding or extraction limit); otherwise `refreshPending` if no published revision exists, the current extraction is newer than the published revision, or an observed change awaits extraction; otherwise `current`. Each eligible present file contributes exactly one freshness count. A queued/running refresh that has cleared the previous error counts as pending.

| Published revision | Latest extraction/refresh | Corpus count | Freshness count |
|---|---|---|---|
| none (no source row yet) | eligible file observed in scan inventory | `notSearchable` | `refreshPending` |
| none | first extraction queued/running | `notSearchable` | `refreshPending` |
| none | first extraction failed | `notSearchable` | `refreshError` |
| r1 | r1 published, no refresh | `searchable` | `current` |
| r1 | newer r2 extraction/chunking pending | `searchable` | `refreshPending` |
| r1 | newer r2 refresh failed | `searchable` | `refreshError` |
| r2 | r2 published; active vectors still r1, or no active generation | `searchable` | `current` |

Thus an old usable revision survives a failed refresh and contributes `searchable + refreshError` across the two dimensions. There is no ambiguous `indexed/pending/error` partition. WP6 adds coverage fixtures for these table cases. While a folder is `partial`, its total is reported as "at least N".

## 3. Revisions, canonical text and spans

- `canonical_text` is the extractor output for one revision; spans are `[start, end)` **scalar** offsets into it.
- Assembly (`text_format_version = 1`): PDF pages joined with `"\n\n"` (a page-boundary table maps offsets → pages; `pageFrom/pageTo` derive from it); DOCX paragraphs joined with `"\n"`; PPTX slides joined with `"\n\n"`, each prefixed `"## Slide <n>"`; XLSX sheets in workbook order, each prefixed `"## <sheet name>"`, rows as `"<A1-ref>: <value>"` tab-separated cells; plain text as decoded.
- `chunker_version = 2`: today's 2048/256 scalar window applied to `canonical_text` (not per page), recording scalar offsets. Legacy chunks (version 1, no spans) are never merged.
- `maxExtractedChars` counts scalars of `canonical_text`.

## 4. Index generations

Identity: `provider_id, endpoint_revision, model, model_digest?, dims, normalization ('l2'), query_format_version, doc_format_version, chunker_version`. Manifest rows `(generation_id, source_id, revision_id, state pending|done|excluded, reason)`.

Activation preconditions: every manifest row `done` or `excluded`; sources whose current revision changed after manifest creation get a new row (new revision) first. A running query keeps the generation it pinned at its start.

**Legacy migration** (`legacy-generation-v1.json`): one legacy generation per `(notebookId, modelKey, dims)` with ≥ 1 well-formed vector (malformed = BLOB length ≠ `dims × 4`; dropped and counted); identity fields other than model/dims = `legacy`. Active = the configured key's generation (several dims → larger `vectorCount`, tie → smaller dims). **No configured match → no active generation** (lexical-only + reindex status). Never activate another provider/model automatically. The resumable legacy revision backfill publishes fully available legacy chunk sets through `sources.published_revision_id` even when no generation can be activated; it requires no new extraction or embedding. Once published, those chunks participate in BM25/metadata by §1 while vector results remain empty. SQL migration/backfill tests belong to WP3; retrieval SQL tests belong to WP5.

## 5. API root

Stored `baseURL` is the exact endpoint prefix. Reject C0/C1 controls anywhere in the original input, including surrounding tabs/newlines. Trim other surrounding Unicode whitespace; reject any whitespace remaining inside. Parse safely: any parsing/authority error returns `invalidBaseURL`, never throws. Require scheme `http|https`, **no userinfo, no query, no fragment**, and a valid non-empty hostname or IP literal:

- DNS names use ASCII labels of 1–63 alphanumeric/hyphen characters with alphanumeric first/last characters; at most 253 characters excluding an optional final root dot. Single labels (such as `localhost`) and IDNA A-labels are accepted. Non-ASCII hostnames must be supplied as IDNA A-labels.
- A dotted numeric hostname, after removing an optional final DNS root dot, must be an IPv4 address with exactly four decimal components in `0…255`, with no leading zeros except the component `0`. IPv6 must be valid and bracketed; scoped literals and IPvFuture are unsupported. Percent-escaped hostnames are rejected.
- **Numeric last label** (WHATWG “ends in a number”): if the final DNS label consists only of decimal digits, or is `0x` followed by zero or more hex digits (bare `0x` included), the whole host must be a strict dotted-quad IPv4 address; otherwise `invalidBaseURL`. URL parsers (including .NET `System.Uri`) would silently reinterpret such hosts as IPv4 (`1234` → `0.0.4.210`). `123abc` is an ordinary DNS label.
- An explicitly supplied port must be ASCII decimal digits in `1…65535`; an empty port, signs, non-digits or overflow are invalid. An absent port is allowed.

All failures return `invalidBaseURL`. Successful normalization preserves the supplied prefix and removes trailing `/` only (after surrounding whitespace trimming).

| type | chat | models | embeddings |
|---|---|---|---|
| `openai`, `openai_compatible` | `chat/completions` | `models` | `embeddings` |
| `anthropic` | `v1/messages` | `v1/models` | `unsupportedEndpoint` |
| `openwebui` | `api/chat/completions` | `api/models` | `unsupportedEndpoint` |
| `ollama` | `api/chat` | `api/tags` | `api/embed` |

URL = `root + "/" + path`. **Legacy conversion** (one-time, for configs stored before v19): `openai`/`openai_compatible` roots not ending in `/v1` get `/v1` appended (old code always appended `/v1`; roots already ending in `/v1` were broken as `/v1/v1` and are kept). Default `openai` root becomes `https://api.openai.com/v1`. Fixture: `api-root-v1.json`.

## 6. Glob grammar

Patterns are matched against `rel_path` (`/`-separated, no leading `/`). Normalize the pattern **once** before matching:

- Rejected (`unsupportedSyntax`): empty pattern, leading `!`, any of `[ ] { } \`, or a pattern containing only `/`.
- Remember anchoring from the original pattern: anchored iff it starts with `/` or contains an inner `/` after stripping the outer separators. Strip leading/trailing `/` and collapse repeated `/` into one separator. Matching always receives these normalized components. A trailing slash alone does not anchor a component-name rule: `build/` behaves like `build`; `/build/` is anchored; `a//b///` normalizes to anchored `a/b`.
- `*` = any run of scalars within one component (incl. empty); `?` = exactly one scalar; `**` as a whole component = zero or more components.
- Unanchored pattern: matches if **any component** of the path matches it.
- Anchored pattern: matches at the folder root if it matches the path itself or **any ancestor directory prefix** (excluding a directory excludes its subtree).
- Case: on a case-insensitive volume, map each scalar on both sides through **Simple_Lowercase_Mapping from the pinned Unicode 15.1.0 `UnicodeData.txt`**, otherwise leave it unchanged. The file and hash are pinned by `lang-detector-v1.md` §2.1. This is locale-independent and never expands a scalar: U+0130 `İ` → U+0069 `i`; U+10400 `𐐀` → U+10428 `𐐨`; `ß` stays `ß`. WP4 exposes a shared `UnicodeTables` component for detector, glob and FTS tokenizer; native Swift/.NET or Python casing is not the contract.

Fixture: `glob-v1.json`.

## 7. FTS query — frozen v1

Index tokenizer: `unicode61 remove_diacritics 2` for `chunks_fts`, `sources_fts`.

Query builder:

1. NFC-normalize the query.
2. Tokens = maximal runs where a run **starts** with a scalar of category `L*`, `N*` or `Co` and continues with such scalars or combining marks (`M*`); everything else separates (punctuation, symbols incl. emoji, `_ + $`, whitespace).
3. Deduplicate by first occurrence (exact scalar equality — SQLite folds case/diacritics itself), keep the first `maxFtsTokens`.
4. Emit each as `"tok"` (inner `"` doubled), joined with `" OR "`. No prefix `*`, no stoplist. No tokens → no `MATCH` query (lexical branch empty).

Observed behaviour (recorded in `fts-query-v1.json`, asserted by the generator against a real FTS5 table): decomposed and precomposed accents match; `ß` ≠ `ss`; `ł` is not folded to `l`; emoji are separators. The executing SQLite version is diagnostic console output, never byte-compared fixture content. Generator-classified fixtures use only scalars whose General_Category agrees between Unicode 13 and 15.1, and the generator asserts the pinned expected categories. Glob edge-case mappings likewise come from the pinned simple-lowercase table, independent of the host's full lowercase operation. WP4 supplies `UnicodeTables`. Frozen after the WP5 GRDB system SQLite and Windows e_sqlite3 conformance runs; runtime versions are retained in the platform conformance logs.

Conformance evidence (2026-10-09, all 24 `fts-query-v1.json` cases — 24 expressions, 21 non-null `MATCH` outcomes — 0 failures, algorithms and case results unchanged):

| Engine | Provider | Host | SQLite | Test (log line) |
|---|---|---|---|---|
| macOS system SQLite | GRDB 7.10.0 (`DatabaseQueue`) | macOS 26.6.2 (25G83), Swift 6.3.3 | 3.51.0 | `FTSQueryBuilderTests.testSharedCasesOnSystemSQLite` passed — `FTS provider=GRDB-system platform=macOS sqlite=3.51.0` |
| e_sqlite3 | Microsoft.Data.Sqlite 9.0.16 + SQLitePCLRaw.bundle_e_sqlite3 3.0.3 → SourceGear.sqlite3 3.50.4.5 | macOS 26.6.2 (osx-arm64 native), .NET SDK 10.0.302 | 3.50.4 | `Rag.FtsQueryBuilderTests.SharedCasesOnESqlite3` passed — `FTS provider=SQLitePCLRaw-e_sqlite3 os=Unix 26.6.2 sqlite=3.50.4` |

The e_sqlite3 run used the Windows Core test project on macOS. The Windows App's locked graph (`windows/src/AINotebook.App/packages.lock.json`) resolves the same SQLitePCLRaw.bundle_e_sqlite3 3.0.3 / SourceGear.sqlite3 3.50.4.5, so the native Windows `e_sqlite3.dll` is built from the same SQLite 3.50.4 amalgamation and FTS5/unicode61 sources; Windows CI (`build-and-test`) re-runs the same `SharedCasesOnESqlite3` test against the same fixture on the native Windows binary. A SQLite or SQLitePCLRaw bump on either platform must re-run both conformance tests before release.

## 8. Token budget

Inputs: `runtimeContext C`, `maxOutputTokens O`, `mandatoryTokens M` (framing + rules + user instructions + scope header + question), optional `evidenceBudgetCap`, `topK`, passages in diversity order `{id, tokens, truncationCandidates?}`, `mapTokensDesired`, `noteWebTokensDesired`, `historyTurnTokensNewestFirst` (complete turns).

`truncationCandidates` is an optional list of valid sentence-boundary prefixes `{tokens, endScalar}`. Each candidate's positive `tokens` is its **actual** cost including any truncation marker/framing charged to evidence; `endScalar` is the positive exclusive scalar end offset relative to the passage start. Costs and offsets are strictly increasing and every prefix is shorter/cheaper than the full passage. The coordinator supplies these candidates from the actual text and active tokenizer/estimator; the packer does not invent a boundary or assume a prefix costs exactly the available budget.

1. `B = C − O`; if `B ≤ 0` or `M > B` → `contextTooSmall`.
2. `R = B − M`; `E = share(R, evidenceShareBp)`, then `min(E, evidenceBudgetCap)` if set; `limit = min(topK, maxPassages)`.
3. If `E == 0`, evidence remains empty in both initial packing and redistribution: no passage, no truncation and no citation. Otherwise, if the **first** passage alone has `tokens > E` and `limit > 0`, choose its largest truncation candidate with cost `≤ E`. Include that prefix and debit its actual cost; if none fits (including absent/empty candidates), skip the first passage. Continue through following passages normally: include whole passages while `count < limit` and each fits the remaining `E`; skip a misfit and try the next passage. Only the first passage is eligible for truncation.
4. `map = min(mapTokensDesired, share(R, mapMaxShareBp))`; `noteWeb = min(noteWebTokensDesired, share(R, noteWebMaxShareBp))`.
5. History: with `R − evidence − map − noteWeb`, add turns newest-first while each fits; **stop at the first turn that does not fit**.
6. Redistribution of the leftover, in order: (a) evidence — if `E > 0`, iterate not-yet-included passages in diversity order and add whole passages with room `evidence + leftover` (still ≤ `evidenceBudgetCap` and the passage limit). A previously skipped first passage may now fit whole; an included truncated passage is **never re-extended**, and redistribution performs no new truncation. (b) History — continue from the first not-included turn, stop at the first misfit. (c) Map — grow only to `min(mapTokensDesired, share(R, mapMaxShareBp))`; the share is a ceiling throughout. Note/web is never redistributed; remaining tokens stay unused.
7. Output `includedPassageIds` in diversity order. `truncatedPassageId`, `truncatedPassageEndScalar` and `truncatedPassageTokens` identify the chosen prefix, or are all null. Citations are created only for included evidence; a truncated citation uses its actual prefix span/text. History is sent chronologically (§11).

Fixture: `budget-v1.json` (output fields: `remainder, evidenceTarget, includedPassageIds, truncatedPassageId, truncatedPassageEndScalar, truncatedPassageTokens, evidenceTokens, mapTokens, noteWebTokens, historyTurnsIncluded, historyTokens, unusedTokens` or `error`).

## 9. Diversity ordering

Production scoring on both platforms is integer-only (no float path left behind).
- RRF ranks are **1-based** per branch; `rrfMicro = Σ_branches floor(1_000_000 / (rrfK + rank))` (absent branch contributes 0).
- Greedy: repeatedly pick the remaining candidate with the highest effective score `eff = rrfMicro`, multiplied `n` times by `diversityPenaltyBp / 10000` with floor after **each** multiplication, where `n` = direct hits already picked from the same source (neighbours and merged blocks do not count). Ties → smaller `chunkId`.
- Explicit single-source scope → penalty `10000`.
- The output is a full ordering; the budget (§8) consumes it.

Fixture: `diversity-v1.json`.

## 10. Overview selection

`filesInScope` counts every eligible present file in scope, including files with no published chunks. Candidates are the subset with a first chunk of their **published** revision; count these separately as `filesWithPublishedChunks`. Fixture files have `{sourceId, folderId, relPath, firstChunkId, firstChunkTokens}`; `folderId` is nullable and both first-chunk fields are null when the file has no published chunks.

Directory identity is `(folderId, dir)`, where `dir` is `relPath` up to the last `/` (`""` for the root). Loose sources form the `folderId = null` group first; other folders follow display order, defined as ascending `folderId`. Within a folder, directories use scalar order. Files within a directory sort by `relPath` in scalar order, then ascending `sourceId` as the final tie-break. Identical relative paths in different folders never share a directory bucket.

Visit order = round-robin: the first file of each directory in the order above, then the second, and so on. Include in visit order while `count < maxPassages` and the first chunk fits the remaining evidence budget (non-fitting files are skipped). Report all of `filesIncluded`, `filesWithPublishedChunks` and `filesInScope`; no candidate count may masquerade as the total in scope. Permuting input cannot change visit or selection order.

Fixture: `overview-v1.json`.

## 11. Wire message order

Logical input: `rulesText`, `userInstructions`, `history` (chronological complete turns), `finalUserContent` (context blocks + question, exactly once).
- System text = `rulesText` if `userInstructions` is blank (whitespace only), else `rulesText + "\n\n" + userInstructions`.
- `openai`, `openai_compatible`, `openwebui`, `ollama`: `messages = [{system}, ...history, {user: finalUserContent}]`.
- `anthropic`: top-level `system` string; `messages = [...history, {user: finalUserContent}]`.
- The current question is never also part of `history`.

Fixture: `wire-order-v1.json` (WP2 executes it against the adapters; today Swift Anthropic joins all system turns, Windows uses only the first).

## 12. Token estimation — development placeholder (not release-safe)

`base = ceilDiv(scalarCount, divisor[lang])` with `en 4, de 3, cs 3, sk 3, und 3, mixed 3`; `estimate = ceilDiv(base × (10000 + tokenEstimateHeadroomBp), 10000)`. Framing: `+4` tokens per message, `+8` per section header. Each prepared request pins `estimatorVersion = 1`. WP7 calibrates per model/tokenizer family and ships `token-estimate-v2.json`.

## 13. Citations codec v2

Fixture: `citations-v2.json`. Decode accepts a legacy array or `{ "v": 2, "items": [...] }`, returning `[]` for absent/empty input, malformed JSON, unsupported versions or invalid envelopes. Before item decoding, validate the **entire document**, including ignored fields, property names and nested values: every number token must parse to a finite double and every string must decode without an unpaired surrogate escape. Any failure, such as `1e400` or `"\ud800"`, rejects the whole document and returns `[]`, even when valid siblings follow. Both codecs must enforce this before lossy item decoding; C# walks its parsed `JsonDocument`, validating numbers and decoding all strings/property names.

After document validation, malformed citation items are skipped individually; valid siblings survive. Required fields are `marker, chunkId, sourceId, snippet`; number fields require integer tokens (no decimal point or exponent), with marker in `1…2^31−1` and IDs/offsets in `0…2^53−1`. Unknown fields are ignored after document validation. Optional nulls count as absent; an optional field of the wrong kind invalidates the item. `spans` and `chunkIds` are all-or-nothing per item; spans require `0 ≤ start < end` and `pageFrom ≤ pageTo` when both exist. Duplicate markers preserve input order.

Encode returns null for an empty list, a legacy array if no v2 fields are present, otherwise the v2 envelope; null optionals and empty optional lists are omitted. `chunkId` remains the first ordered `chunkIds` element for merged evidence. These unreleased corrections keep contract version 2.

## Perf protocol

Gate: warm retrieval p95 < `warmRetrievalP95Ms` at 100 000 chunks (200 000 characterised), measured after query embedding, cache warm, 200 queries, single notebook, no concurrent ingestion (a second run with concurrent ingestion is reported). Reference hardware: macOS — Apple Silicon, 16 GB RAM; Windows — Intel Core i5/i7 class laptop, 16 GB RAM (user's machine, 2026-10-09; WP7 records the exact CPU model with the results). The gate applies to both.
