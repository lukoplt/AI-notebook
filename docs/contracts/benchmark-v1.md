# WP7 benchmark, embedding profiles and token calibration — contract v1

*Status: WP7 Task 1, frozen 2026-10-09. Plan: `docs/superpowers/plans/2026-10-09-wp7-benchmark.md`. Parent contract: `folder-rag-v1.md` (identity §4, budget §8, estimator §12, Perf protocol). Executable reference: `tools/contracts/gen_benchmark_fixtures.py`; `python3 -B tools/contracts/gen_benchmark_fixtures.py --check` must pass and `python3 -B -m unittest tools.benchmark.test_contracts tools.benchmark.test_tokenize_offline` must be green. Swift and C# reproduce every fixture output exactly (vectors within 1e-6).*

Everything in the fixtures is **synthetic**: fake transports, fake digests (`sha256:aaaa…`), fixed clocks and invented counts that exist only to pin arithmetic and control flow. No fixture value is a measurement of a real model, tokenizer or machine. Real observations arrive only through Task 12 reports.

Conventions: integers for every frozen number; `ceilDiv(a,b) = a/b + (a%b != 0)` for `a ≥ 0, b > 0`; scalar = Unicode scalar value; scalar order = lexicographic over scalar values; JSON files are UTF-8, sorted keys, indent 2, `ensure_ascii=false`, final LF. Nonfinite test inputs are string sentinels `"NaN"`, `"Infinity"`, `"-Infinity"` that the harness converts; they never appear as JSON number tokens. Vector expectations are integer millionths (`round(|x|·10⁶)`, half away from zero, sign kept); compare `|actual − expected/10⁶| ≤ 1e-6`.

## 1. Files

| File | Content |
|---|---|
| `Tests/fixtures/contracts/embedding-profiles-v1.json` | `profiles` (the catalog) + cases `format`, `formatVersion`, `require`, `identity`, `project`, `pool`, `bisect` |
| `Tests/fixtures/contracts/embedding-strict-v1.json` | `fixtureProfile` + cases `pipeline`, `telemetry`, `wire`, `prepare`, `resume`, `publish` |
| `Tests/fixtures/contracts/token-estimate-v2.json` | the pending runtime resource fields + cases `fit`, `estimate`, `estimator`, `estimatorBound`, `undercount`, `constructor`, `binding`, `calibration-observations`, `sample-plan`, `calibration-report`, `resource` |
| `Tests/fixtures/contracts/benchmark-report-v1.json` | cases `report`, `percentile`, `gate`, `throughput`, `escape`, `recallFormat`, `verify` |
| `Tests/fixtures/contracts/benchmark-run-v1.json` | `phases` + cases `phase`, `stage`, `audit`, `query`, `overlap`, `cache`, `rounding`, `fnv`, `memory`, `process`, `cli`, `tuning`, `tuning-build` |
| `Tests/fixtures/contracts/embedding-default-v1.json` | cases `install`, `install-invalid`, `selection`, `identity`, `rebuild`, `drain` |
| `Tests/fixtures/contracts/token-calibration-session-v1.json` | cases `capture`, `capture-cancel`, `validate`, `router`, `coordinator` |
| `Sources/AINotebookCore/Resources/Benchmark/embedding-profiles-v1.json` | `{contract, version, profiles}` — the catalog without cases |
| `Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json` | `{contract:"token-estimate", version:2, status:"pending", payloadHash, bindings:[], rates:[], provenance:[]}` |
| `Sources/AINotebookCore/Resources/Benchmark/embedding-decision-v1.json` | `{contract:"embedding-decision", version:1, status:"pending", profileId:null, parameters:{fetchK:32, topK:16, evidenceShareBp:6000}}` |

Production resources are a projection of the same generator data (`make_resources()`); they never contain `cases` or the `fixture-only` family, and are never hand-copied into platform constants. Task 2 registers `.copy("Resources/Benchmark")` in `Package.swift`; Task 3 links `AINotebook.Benchmark.<file>` embedded resources. Until then SwiftPM may report the directory as unhandled files (warning only).

Every case has a unique `name` and a `kind`; a platform test dispatches each kind it owns and must consume every row of that kind exactly once.

## 2. Embedding profiles

Catalog row fields (exact wire names): `id, model, tokenizerId, queryPrefix, documentPrefix, nativeDims, dims, maxInputTokens, matryoshka, ceilingSource`. Seven rows in this order: `nomic-v2-256`, `nomic-v2-768`, `qwen3-06b-256`, `qwen3-06b-512`, `qwen3-06b-1024`, `bge-m3-1024`, `paraphrase-768`. Ceilings include prefix and special tokens. `ceilingSource` is `model-card` except `paraphrase-768`, recorded as `ollama-512` (the upstream sentence-transformers wrapper uses 128). `tokenizerId` names the model card's documented tokenizer and is distinct from the Ollama `model`. Only `matryoshka` rows may have `dims < nativeDims`.

- `format(text, purpose) = (purpose == query ? queryPrefix : documentPrefix) + text` — no trimming or normalization. The Qwen query prefix ends `\nQuery:` with no trailing space.
- `formatVersion(purpose, effectiveLimit?) = "wp7:" + id + ":" + purpose + ":split1:scalarpool1:prefixl2:ctx" + (effectiveLimit ?? maxInputTokens)` in invariant decimal. Any policy change requires new strings.
- `project(vector, nativeDims, dims)`: requires `count == nativeDims`, `0 < dims ≤ nativeDims`, all finite; take the prefix, L2-normalize in double; zero/nonfinite norm → `invalidEmbedding`.
- `pool(vectors, scalarWeights)`: nonempty, equal counts, equal nonzero lengths, finite, weights > 0; weighted sum in double, L2-normalize; else `invalidEmbedding`. Pool all accepted leaves once; never normalize intermediate nodes.
- `bisect(text)`: scalars `< 2` → `inputCannotFit`; split at `count/2` scalars (left is the shorter half for odd counts).
- Identity agreement (`identity` cases): `model`, `dims`, both format strings with **one** shared `ctx` value in `1…maxInputTokens`, else `profileIdentityMismatch`. Unknown ID → `unknownProfile`; a model name is never accepted as a profile ID.

## 3. Strict complete-input embedding

Wire (`OllamaBenchmarkClient.embed`): `POST <root>/api/embed` with body `{model, input:[formatted], dimensions:nativeDims, truncate:false, options:{num_ctx:effectiveLimit}}`. Response must contain exactly one vector of `nativeDims` finite numbers; `prompt_eval_count`, `total_duration`, `load_duration` are optional integers (a missing count is `null`, a negative or fractional count is `invalidTokenCount`). Only HTTP 400 whose JSON `error` equals exactly `the input length exceeds the context length` maps to the typed length rejection (`inputTooLong`); every other status/body (including 413 and 401) is `providerError` and is never split. Malformed JSON is `invalidResponse`.

Pipeline (`pipeline` cases, transport outcomes `ok | lengthRejected | httpError | cancel`, scripted in request order — the harness asserts each request's formatted input equals the script's `input`):

1. Empty text → `emptyInput`; `effectiveLimit ∉ 1…maxInputTokens` → `invalidEffectiveLimit`; zero requests.
2. `visit(raw, start)`: format, emit `request`, call the transport. `cancel` → `cancelled`; `httpError` → `providerError` (propagate, no split). `lengthRejected` → count it, emit `lengthRejected`, split. `ok` → project (fails `invalidEmbedding`), reject negative native count (`invalidTokenCount`), emit `response(tokens: native count or null)`; count = native count, else the exact offline counter for `(formatted, tokenizerId)`, else `tokenCountUnavailable`. If `count ≤ effectiveLimit` accept the leaf `{start, end: start + scalars(raw), tokens: count}` and emit `partAccepted`; otherwise split.
3. Split = `bisect(raw)` then `visit(left, start)`, `visit(right, start + scalars(left))`. Recursion depth is bounded by `ceil(log2(scalars))`; cancellation is checked before every request.
4. Result: `parts` in visit order, `successfulTokens = Σ leaf tokens`, `rejectedRequests` = typed rejections, pooled vector weighted by leaf scalar length.

Telemetry snapshot for one purpose: `requestCount`, `rejectedRequests` = `lengthRejected` events, `splitParts` = `partAccepted` events, `successfulTokens` = Σ accepted tokens, `uncountedRequests = requestCount − responses with a native count`, `serviceTokens` = Σ native response counts only when `uncountedRequests == 0` (else `null`), `serviceTokenStatus` = `measured` | `partial` (some counted) | `not_available` (none counted). A successful over-limit response adds its real service count but no useful tokens. Fallback counts never become service tokens.

Captured preparation (`prepare` cases): provider must be `ollama`, enabled, consented and embedding-capable, else `unsupportedEmbeddingProfile` with zero requests. `GET <root>/api/tags`; exactly one row whose `name` equals the profile model, or — only for an untagged model — equals `model + ":latest"`; no substring or prefix matching; zero/duplicate rows or a digest that is neither 64 lowercase hex nor `sha256:` + 64 lowercase hex → `embeddingModelUnavailable`. Digests normalize to `sha256:<hex>`. `POST <root>/api/show` with `{model: profile.model}`; context = `model_info["<general.architecture>.context_length"]` as an integer in `2…2³¹−1` (WP2 parser), else `modelMetadataUnavailable`. `effectiveLimit = min(maxInputTokens, context)`. Identity = `(providerId, endpointRevision = sha256_lowerhex(type + "\n" + normalizedRoot), profile.model, digest, dims, "l2", formatVersion(query, limit), formatVersion(document, limit), "2")`. The root, credential and adapter are captured once; later Settings mutations never change the show/embed root. Resuming a stored identity (`resume`) re-reads only `/api/tags`; a changed, missing or removed digest → `embeddingModelChanged` with zero embedding requests; the ctx suffix is parsed from the stored identity and never re-probed. Publication (`publish`) revalidates the digest the same way and leaves the active generation unchanged on mismatch.

Chat count wire: `observeRaw` sends `POST <root>/api/generate` `{model, prompt, raw:true, stream:false, options:{num_ctx, num_predict, temperature:0}}` (options from `ChatRequestOptions(runtimeContext, maxOutputTokens)`); `observeChat` sends `POST <root>/api/chat` `{model, messages, stream:false, options:{…}}` with no `raw` flag. Both return `{text, promptTokens, outputTokens}` from `response`/`message.content`, `prompt_eval_count`, `eval_count`. No `/api/tokenize` endpoint exists or is assumed. Method labels: `ollama-raw-prompt`, `ollama-chat-prompt`, `ollama-embed-prompt` (embedding observation), `documented-tokenizer` (offline fallback, §7).

## 4. Token estimator v2

`TokenRate {family, language, tokensPerScalarBp}`; languages `cs, de, en, sk, und, mixed`; family nonempty without whitespace; `0 ≤ rate ≤ 1 000 000`; `(family, language)` unique — else `invalidCalibration`.

- `fit(training)`: nonempty; every sample `split == "train"`, unique `id`, permitted language, `0 < scalars ≤ 5 000 000`, `tokens ≥ 0`; per `(family, language)` rate = `max ceilDiv(tokens·10000, scalars)`; output sorted by family then language (scalar order); a rate above 1 000 000 → `invalidCalibration`. Holdout rows can never be fitted.
- `estimate(text, language)` for family `F`: rate = exact language row of `F`, else max rate of `F` (so `und` never borrows an English divisor). With a rate: `n > 5 000 000` → `Int32.max`; `base = ceilDiv(n·rate, 10000)`. Without any row for `F` (unknown or `unverified` family): `base = UTF-8 bytes` (explicitly uncalibrated). `base > Int32.max/2` → `Int32.max`; result `min(Int32.max, ceilDiv(base·11500, 10000))`. `version == 2`. Message `+4` and section `+8` charges stay in the WP8 builder.
- `undercounts(samples, rates)` counts samples with `tokens > estimate(scalars, rate)`; a family without rates → `uncalibratedFamily`.
- `resolveFamily(model, modelDigest, bindings)`: exact `(model, modelDigest)` equality only; a missing digest → `null`.
- Runtime resource: `{contract:"token-estimate", version:2, status:"pending"|"calibrated", payloadHash, bindings, rates, provenance}`; `payloadHash = sha256_lowerhex(canonical({bindings, provenance, rates}))` where canonical = sorted keys, `,`/`:` separators, literal UTF-8, JSON-required escapes only, no slash escaping. `pending` has empty arrays. Every binding digest is `sha256:` + 64 hex and every binding family has rates. A production loader rejects `fixture-only` anywhere. The fixture copy adds `cases`; the pending `payloadHash` is identical in both.

## 5. Calibration protocol and report

### 5.1 Families

Provider-observed counts: `family = "ollama:" + modelDigest` (full `sha256:` digest). Documented local tokenizer: `family = "hf:" + tokenizerId + "@" + revision + ":" + assetsSha256`. Any changed digest/template/tokenizer inventory is a different family. `fixture-only` is reserved for synthetic test data and never ships. The initial chat calibration subject is `llama3.2:3b` (the unchanged chat default).

### 5.2 Sample plan (`sample-plan` case)

For each body language `cs, de, en, sk`: sort that language's documents by `document_id` (scalar order); index `i` is `train` when `i mod 4 ∈ {0,1,2}`, else `holdout`. Every sample derived from a document inherits its partition. Per document of `n > 0` scalars: non-overlapping windows `[k·256, min((k+1)·256, n))`, plus the whole document `[0, n)` when `256 < n ≤ 1024`; empty documents contribute nothing. Sample ID = `document_id + ":" + start + ":" + end` (half-open scalar offsets). Queries with `case_type ∈ {answer, exact_identifier}`, a body language, nonempty text and gold documents become `query:<query_id>:0:<n>` samples with `documentId = "query:<query_id>"`, in the shared partition of all gold documents, else `holdout`; absent/scope/empty_selection/overview queries never fit body rates. Mixed samples, per partition: take the 256-windows of each language in order `cs, sk, en, de` (document order, then offset), and for `j < min(count)` join window `j` of each with LF; ID = source IDs joined with `+`, language `mixed`, `documentId/start/end = null`. Output sorted by sample ID (scalar order).

### 5.3 Observations

Body counts use `observeRaw` on the chat model (`num_ctx 8192`, `num_predict 1`, raw prompt, no template); the provider count is used as-is, including any BOS token. Full-prompt checks render the real `PreparedContextRequest`: each wire message's content is its ordered section texts joined with `"\n\n"`, sent via `observeChat`; `estimatedPrompt = Σ section tokens + 4·messages`. Only `kind=body, split=train` observations enter `fit`; embedding counts (`/api/embed`, all seven profiles) and full prompts never do (`calibration-observations`). A missing count may use the documented offline chat tokenizer (`add_special_tokens=true, truncation=false`); otherwise the observation is unmeasured and the report incomplete.

### 5.4 `TokenCalibrationReportV1`

```text
{contract:"token-calibration-report", version:1, status:complete|incomplete, corpusHash, platform,
 model, modelDigest, ollamaVersion, showTemplateSha256, family, method:documented-tokenizer|ollama-raw-prompt,
 tokenizerId, tokenizerRevision, tokenizerAssetsSha256,
 samples:[{id, language, split:train|holdout, documentId, start, end, scalars, utf8Bytes, tokens}],
 rates:[{family, language, tokensPerScalarBp}], headroomBp:1500,
 promptChecks:[{queryId, split, preparedHash, wireMessagesHash, actualTokens, estimatedTokens}],
 bodyHoldoutUndercounts, promptHoldoutUndercounts, maxOverestimateTokens, calibrated, errorCode}
```

Validation (`invalidCalibration`): exact contract/version/headroom; `ollama-raw-prompt` has all three tokenizer fields `null` and family `ollama:<digest>`; `documented-tokenizer` has all three non-null and the `hf:` family; hashes well-formed; sample IDs unique and scalar-sorted. `incomplete` requires `errorCode` and `calibrated:false`; its missing counters are `null`, never 0. `complete` requires `errorCode:null`, every sample counted, `rates == fit(train samples)`, `bodyHoldoutUndercounts` = undercounting holdout samples, `promptHoldoutUndercounts` = holdout checks with `actual > estimated`, `maxOverestimateTokens = max(0, max(estimate − actual))` over holdout bodies and holdout prompt checks, and `calibrated = (both undercounts == 0 ∧ holdout bodies ≠ ∅ ∧ holdout prompts ≠ ∅)`. An honest complete report with a holdout undercount is valid with `calibrated:false`.

Markdown (`calibration-report` goldens): header lines, then sample, rate and prompt-check tables, then the three counters; final LF. Text cells use the escaping of §6.4.

## 6. Benchmark report

### 6.1 `BenchmarkReportV1`

```text
{contract:"benchmark-report", version:1, status:complete|incomplete, backend:"fts-or-pinned-rrf-v1",
 mode:fixture|live, platform:macos|windows,
 environment:{cpu, ramBytes, os, architecture, buildCommit, ollamaVersion, accelerator},
 corpus:{id, hash, documents, queries, chunkerVersion}, calibrationHash,
 parameters:{fetchK, topK, evidenceShareBp, runtimeContext, maxOutputTokens, seed},
 chat:{model, modelDigest, tokenFamily, showTemplateSha256},
 candidates:[{profileId, identity:{providerId, endpointRevision, model, modelDigest, dims, normalization,
   queryFormatVersion, docFormatVersion, chunkerVersion}, status:complete|failed|incomplete, errorCode,
   quality:{metrics, byLanguage, byCaseType, queries:[BenchmarkQualityQuery]},
   citations:{snapshotsCorrect, snapshotsTotal, answerMarkersCorrect, answerMarkersTotal,
              answerGoldSupported, answerMarkersJudged, semanticReview:"not_measured"},
   ingest:{serviceTokens, successfulTokens, rejectedRequests, splitParts, elapsedUs, tokensPerSecondMilli,
           runnerPeakRssBytes, serverPeakRssBytes, combinedPeakRssBytes, serviceTokenStatus,
           uncountedRequests, memoryMethod, sampleIntervalMs},
   performance:[{chunks, concurrent, queries, warmupQueries, warmP50Us, warmP95Us, endToEndP50Us,
     endToEndP95Us, hydrationP95Us, coldCacheLoadUs, cacheMode:cached|streamed, residentBytes,
     peakPageBytes, completedWrites, overlapUs, gatePassed,
     samples:[{queryId, embeddingUs, retrievalUs, hydrationUs, endToEndUs}]}]}]}
```

`BenchmarkQualityQuery = {eval, packed, citationMap, answerText, preparedHash, timing, overview}`: `eval` is WP1's unchanged `EvalQueryRow` (snake_case), `packed` is `[EvalSpan]` (snake_case), `citationMap` items use the CitationsCodec v2 item form (null optionals omitted), `timing = {embeddingUs, retrievalUs, hydrationUs, endToEndUs} | null`, `overview = {filesInScope, publishedCandidateFiles, filesIncluded} | null`. Metric objects are WP1's `{status, found, total, recall_bp}`; aggregation is WP1 micro aggregation. `byLanguage` always has the six keys `cs, de, en, sk, und, mixed`; `byCaseType` always has `answer, exact_identifier, scope, absent, empty_selection, overview`. Every unavailable optional is an explicit `null`, never 0. The JSON output is structurally equal to the input (`expectedJson`); key order is irrelevant, array order is not.

### 6.2 Math (`percentile`, `gate`, `throughput` cases)

`percentile(samples, bp) = sorted[ceilDiv(n·bp, 10000) − 1]`, empty/negative → `invalidSamples`. `warmGate(chunks, concurrent, queries, p95Us)` is `null` unless `chunks == 100000 ∧ !concurrent ∧ queries == 200`, then `p95Us < 300000` (300000 fails). `tokensPerSecondMilli(tokens, elapsedUs) = floor(tokens·10⁹ / elapsedUs)`, `null` when `elapsedUs == 0`, `invalidSamples` for negatives or `tokens > Int64.max/10⁹`. CLI millisecond durations convert to integer microseconds rounding half away from zero (`rounding` cases).

### 6.3 Validation (checked in this order; the first failure's code is the error)

1. contract/version/backend/status/mode/platform; parameters `0 < topK ≤ fetchK ≤ 1024`, share `0…10000`, `0 < maxOutputTokens < runtimeContext` → `invalidReport`. Corpus hash and calibrationHash 64 lowercase hex, chat digest `sha256:`+64 hex or null → `invalidHash`.
2. Candidates: duplicate ID → `duplicateProfile`; unknown → `unknownProfile`; not in catalog order → `invalidOrder`.
3. Per candidate: identity must match its profile (model, dims, `l2`, chunker `"2"`, both format strings with one ctx in `1…maxInputTokens`) → `profileIdentityMismatch`; candidate status set and `errorCode == null ⇔ status == complete` → `invalidReport`; query IDs unique (`duplicateQuery`) and scalar-sorted (`invalidOrder`); every metric object valid (`measured`: `0 ≤ found ≤ total`, `total > 0`, `recall_bp = 10000·found/total`; `not_applicable`: 0/0/null; `not_available`: null/null/null) → `invalidMetric`; `metrics/byLanguage/byCaseType` equal recomputed aggregates → `inconsistentAggregate`; citation counters nonnegative with `correct ≤ total`, `goldSupported ≤ markersCorrect`, `judged ≤ markersTotal`, `semanticReview == "not_measured"` → `invalidCitations`; ingest integers nonnegative or null, `serviceTokenStatus` rules of §3 → `invalidSamples`; throughput equals §6.2 and `max(runner, server) ≤ combined ≤ runner + server` → `summaryMismatch`; performance rows unique and sorted by `(chunks, concurrent false<true)` → `invalidOrder`; `samples.count == queries > 0`, `queryId` = 0…n−1, nonnegative times, `endToEndUs ≥ embedding + retrieval + hydration`, 100K non-concurrent rows have 200 queries → `invalidSamples`; summaries and `gatePassed` recomputed from raw samples → `summaryMismatch`; `streamed` rows have null cold time → `invalidSamples`; concurrent rows need `completedWrites ≥ 2 ∧ overlapUs > 0` → `insufficientIngestionOverlap`, non-concurrent rows have 0/0 → `invalidSamples`.
4. `status == complete` additionally requires chat digest/family, every candidate `complete` with a digest, ≥ 1 performance row, measured `successfulTokens`, `elapsedUs`, `combinedPeakRssBytes`, no `not_available` packed metric and a cold time on every `cached` row → `incompleteMeasurement`. Honest `incomplete` reports validate; their decision gate is false.

### 6.4 Markdown

Escape text cells: backslash → `\\` first, then `|` → `\|`, CRLF/CR/LF → `<br>`. `null` prints `not measured` (without a unit); booleans print `yes`/`no`; recall prints `bp/100 "." bp%100 (2 digits) "%"`; throughput prints `v/1000 "." v%1000 (3 digits)`; gate prints `pass`/`fail`/`not measured`. Layout (byte-exact in the goldens): header lines, environment table, corpus/calibration/parameters/chat lines, then per candidate: status, identity, formats, the five-metric table, the per-language recall table, citation, ingestion and memory lines, and the performance table. Final LF.

### 6.5 Verifier (`verify` cases, Task 12)

`decision-pair` holds complete synthetic `mac`/`windows` reports (all seven profiles, four rows of 200 samples each, p50 100 / p95 190) and a synthetic `calibrated` estimator resource whose `payloadHash` equals both reports' `calibrationHash`. Derived cases name `derivedFrom: "decision-pair"` and a list of `{path, value}` replacements applied to a deep copy of `{mac, windows, calibration}`; this avoids repeating 11 200 samples. Fixture mode is accepted by verifier unit tests only; release verification requires `mode: live`.

## 7. Offline tokenizer protocol

`tools/benchmark/tokenize_offline.py --root DIR` (no download code; sets `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` before any import). `DIR/manifest.json = {version:1, tokenizers:{<id>:{path, revision, assetsSha256, files:{<relative file>: <sha256>}}}}`; `assetsSha256 = sha256` over sorted lines `"<sha256>  <file>\n"`. Every file and the inventory are verified before answering; any missing/mismatched/escaping asset exits 3 with `{"error":"tokenizerUnavailable"}` on stderr. Requests on stdin are newline JSON `{requestId, tokenizerId, text}`; responses `{requestId, tokens, tokenizerId, revision, assetsSha256}` or `{requestId, error}` (`unknownTokenizer`, `invalidRequest`). Count = `len(encode(text, add_special_tokens=True, truncation=False))` with `AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=False)`, loaded once per tokenizer. Text is never logged or truncated. Clients start the process with an argument array (no shell), write text on stdin and match request IDs. Live fallback is allowed only for each catalog row's documented `tokenizerId`; chat families have their own IDs. Such counts are labeled `documented-tokenizer`, never Ollama-exact.

## 8. Run, policy and session fixtures

- **Phases** (`phase`): per candidate `inspect, ingest, quality`, then per chunk count `cold, warmup, measure` (non-concurrent) and `concurrent`, then `verifyModels, report`; each event `{phase, profileId, chunks|null}`. Cancellation stops the trace, awaits writer/sampler, leaks no pins and writes no success artifact.
- **Staging** (`stage`): never activates; a failure retires only a generation it created; refresh-pending sources block with `refreshPending`; a revision published during the await → `staleRevision`; wrong dimensions → `invalidEmbedding`; an empty published revision is `done` with zero vectors; a session identity differing from the requested identity → `profileIdentityMismatch` before any generation exists.
- **Citation audit** (`audit`): a snapshot counts as correct only with matching source/revision, one span, exact scalar text, content hash, ordered chunk membership, `chunkId == chunkIds[0]`, snippet = first 240 scalars and a unique marker; invalid entries stay in `snapshotsTotal` and are excluded from `packed`. Marker totals count every parsed positive marker occurrence; `answerMarkersJudged` is the marker total only for rows with gold, else 0.
- **Overlap** (`overlap`): count writer completions inside `[measuredStart, measuredEnd]`; fewer than two or zero span → `insufficientIngestionOverlap`; `overlapUs = last − first`.
- **Cache** (`cache`): admission charge `rows·(dims·4 + 32)` against 536 870 912 bytes; refusal → `cacheMode:"streamed"`, `coldCacheLoadUs:null`.
- **Memory/process**: peaks reject empty, negative and decreasing-time samples; combined peak is the maximum simultaneous sum. Process trees parse `pid ppid rssKiB` rows (invariant unsigned decimals, KiB·1024 checked), include the root and descendants once (cycles tolerated), exclude the runner and its children; a missing root/runner → `processUnavailable`.
- **CLI** (`cli`): flags and defaults of plan Task 8c; every rejection is `invalidArguments` (exit 2). `--embedding-counts all` is accepted only with `--calibrate` and is carried as `embeddingCounts`.
- **Tuning** (`tuning`, `tuning-build`): `pending` → 32/16/6000 regardless of stored parameters; `accepted` requires `fetchK ≥ topK > 0`, `fetchK ≤ 1024`, share `0…10000`, else `invalidTuning`. `tuning-build` rows carry the full prepared request from the WP8 reference built with v1 estimates and the given share.
- **Install policy** (`install`): `initial` returns the accepted profile only when no database, preferences, completed onboarding, explicit selection or chat-only conversion exists; pending returns null. Malformed decisions → `invalidDecision`; an unknown accepted profile → `unknownProfile` (`install-invalid`). The accepted fixture decision is synthetic test data, not the WP7 choice.
- **Rebuild** (`rebuild`): failures before activation keep every old active generation and the old selection and clear the journal; a committed activation with failed persistence keeps the journal for idempotent recovery.
- **Drain** (`drain`): exact document prefix, native 768 → output 256, both formats ending `ctx512`; restart with matching active identity makes zero requests; a nil profile runs the unchanged legacy drain.
- **Session** (`capture` …): only `ollama` plus a bound exact model probes `/api/tags`; exactly one row with a digest that normalizes to the bound `sha256:` value selects the family; otherwise the UTF-8 fallback (rate 5000 estimates `a😀b` as 3, fallback as 7). `validate()` before every send re-reads tags: changed → `identityChanged`, unavailable → `identityUnavailable`, cancellation propagates. `coordinator` rows carry the full overridden `basic-cs` pack input and the builder output (`expectedPrepared`) under the injected estimator and share 4500; the question section costs 11 with rate 5000 and 15 with the fallback.

## 9. Deviations from the plan text (recorded at Task 1)

1. `BenchmarkOptions` needs one extra field, `embeddingCounts: String?` (`--embedding-counts all`), which the plan's DTO omits.
2. `coordinator` rows freeze the **builder** output for the stated input (with `neighbours: []`, as the fake read session returns). The WP8 coordinator is not merged at Task 1; Tasks 17/18 must confirm the coordinator passes exactly that input.
3. Derived verifier cases use `derivedFrom` + `patches` instead of full report copies; `report` error cases mutate a small two-candidate base (`complete-small`) rather than the 200-sample `complete` golden.
4. Added kinds beyond the plan's list (`formatVersion`, `estimatorBound`, `sample-plan`, `resource`, `stage`, `audit`, `query`, `cache`, `rounding`, `process`, `tuning-build`, `install-invalid`, `selection`, `identity`, `validate`, `router`) so every protocol rule the plan states in prose has a shared row.
5. The calibration family for synthetic reports follows §5.1 (`ollama:<digest>`); `fixture-only` remains the synthetic estimator/binding family only.
