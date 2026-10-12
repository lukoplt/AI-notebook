# WP7 — Benchmark and default embedding model implementation plan

> Execute the numbered tasks in separate worktrees, using only their listed files. This is a plan, not an implementation or a model recommendation. Do not invoke any installed skill or read the forbidden agent/skill directories from the assignment. Checkboxes record future TDD work. Task 12 is executed by Claude with local Ollama; the user supplies its Windows hardware run.

**Goal:** Compare seven multilingual embedding profiles on the production retrieval/context-pack path, ship calibrated token estimator v2 on both platforms, and use measured Mac and Windows results to select the default embedder for new installations. Existing selections and active indexes survive unchanged until an explicit rebuild succeeds.

**Architecture:** Shared JSON defines profiles, deterministic benchmark/calibration cases, and the eventual decision. Core owns formatting, strict input splitting, projection/pooling, calibration, metrics, report serialization, orchestration and default/rebuild policy. Provider adapters own all HTTP and immutable provider snapshots. WP1 supplies corpus/metric primitives; WP3/WP5 supply revision/generation storage, pinned retrieval and synthetic timing hooks; WP8 supplies the real pure builder. Native Settings binds a Core recommendation/rebuild service. Real models and hardware measurements never run in CI.

**Tech Stack:** Swift 6, Foundation, GRDB, XCTest, SwiftUI; .NET 10, System.Text.Json, Microsoft.Data.Sqlite, xUnit, WinUI 3; Python 3 standard library for fixtures/report verification; optional offline Hugging Face tokenizer helper for missing provider counts; Ollama HTTP APIs under `Providers/`.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md:254` (§9), `:28` (R6). **Master:** `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md:45`. **Contracts:** `docs/contracts/folder-rag-v1.md:102` (identity), `:154` (budget), `:200` (estimator), `:212` (Perf protocol); `docs/contracts/lang-detector-v1.md` (language labels/scalar semantics). **Prerequisite plans:** `2026-10-09-wp1-eval-assets.md`, `2026-10-09-wp2-providers.md`, `2026-10-09-wp3-storage-v19.md`, `2026-10-09-wp5-retrieval.md`, `2026-10-09-wp8-context-pack.md` under this directory. **Format exemplar:** `2026-10-09-wp0-contracts.md`.

## Global Constraints

- Planning checkout: `534c705`. Baseline actually run: **Swift 432 passed; .NET Core 525 passed; zero failures/skips**. These are planning counts, not predictions for the prerequisite-merged implementation checkout. Every implementer records its own before/after counts. Sandbox cache/socket restrictions may require approved test execution; they do not justify dropping tests.
- TDD for each behavior: write the listed test, run and observe its stated failure, implement, rerun filtered tests, then both full suites before committing. Windows workers obtain the matching-commit Swift result from the Mac worker; a missing run is pending, never green. No weakened assertions or hidden live-model dependencies. Shared cases are read through the existing `SharedFixtures` helpers (`Tests/AINotebookCoreTests/SharedFixtures.swift:12`, `windows/tests/AINotebook.Core.Tests/Helpers/SharedFixtures.cs:8`).
- Respect all eleven WP0 corrections. In particular: whole-document citation rejection; published lexical revisions versus generation-manifest vector revisions; hydration by each hit's revision; zero evidence creates no citation; sentence-prefix truncation charges actual costs and never re-extends; map redistribution retains its ceiling; folders distinguish identical relative paths; refresh errors do not remove searchable old revisions; attempt-start counting and lease fencing remain WP6's responsibility. Do not edit these algorithms to improve benchmark numbers.
- WP2's stricter output/runtime invariant, exact-ID capability lookup, 404/405/501 listing classification, one-time chat-only embedding conversion and embedding-capable picker filtering remain binding. Never substitute Ollama silently for a rejected provider. Preserve the WP2 conversion notice independently of the recommendation banner.
- No migrations in WP7, no shipped migration changes, no VERSION/version-constant edits. v19 belongs to WP3. No package identity APIs in Windows. Every Windows connection operation remains within the store's `_gate`; no `await` inside that lock.
- New HTTP is exclusively under `Sources/AINotebookCore/Providers/` or `windows/src/AINotebook.Core/Providers/`. CLI code constructs provider clients but does not construct network requests. No credentials, absolute corpus roots, or provider headers in reports.
- The gate is **p95 <300,000 microseconds**, after query embedding, application cache warm, 200 queries, 100K chunks, one notebook, no ingestion. Apply on both specified 16 GB machines. Record 200K and concurrent-ingestion runs separately; neither can replace the 100K run. A failed gate needs an explicit joint exception, never a larger threshold disguised as tuning.
- Immutable format identity includes prefix/instruction, splitting, pooling, projection policy and output dimensions. `legacy`/`1` keeps its original raw-input behavior. No substring-based model recognition; exact model IDs/digests only.
- Live token counts are observations, not invented fixture gold. Embedding tokenizer observations are **not** evidence/prompt calibration for a chat tokenizer. Until Task 12 supplies measured calibration, v2 can run with its explicitly labeled conservative fallback; no report may call it calibrated.
- Native vector floating-point differences are compared within `1e-6`; report counts, offsets, integer microseconds, rounding and Markdown are deterministic. JSON equality is structural, matching the contract, with stable array ordering and a final LF. Live reports share schema, not identical measured numbers.
- A task's allowed paths are exhaustive. A later task may reuse an earlier task's path only through an explicit dependency. Merge prerequisites before spawning dependents; never use another agent's uncommitted files. No tasks below run in parallel with an upstream WP task editing the same file.
- Every commit ends with `Co-Authored-By: Codex <noreply@openai.com>`. All commands below run from repository root. Every new Swift public DTO has an explicit public initializer for the declared fields; every error code below is a typed, equatable Core error, not text parsed from a generic exception. Stage named files, not `git add .`.

## File Structure

New directories listed here contain only the explicitly named files in their tasks. Later split tasks refine these ownership groups with exhaustive file lists. Existing files have inspected anchors; prerequisite-only files are identified as planned and cite the owning plan rather than fictitious source lines.

| Task | Files | Responsibility / current anchor |
|---|---|---|
| 1 [Shared] | `tools/contracts/gen_benchmark_fixtures.py`, `tools/benchmark/test_contracts.py`, `tools/benchmark/tokenize_offline.py`, `tools/benchmark/test_tokenize_offline.py`, `tools/benchmark/tokenizer-requirements.txt`; `Tests/fixtures/contracts/{embedding-profiles,embedding-strict,benchmark-report,benchmark-run,embedding-default}-v1.json`, `Tests/fixtures/contracts/token-estimate-v2.json`; `Sources/AINotebookCore/Resources/Benchmark/{embedding-profiles-v1,token-estimate-v2,embedding-decision-v1}.json`; `docs/contracts/benchmark-v1.md` | Shared inputs, expected results, calibration math, resource data, offline tokenizer protocol. New files. |
| 2 [Swift] | `EmbeddingProfile.swift`, `EmbeddingInput.swift` in `Sources/AINotebookCore/`; `EmbeddingProfileTests.swift` in `Tests/AINotebookCoreTests/`; `Package.swift:33` | Pure formatting/projection/split policy; register Benchmark resource, preserving WP4 resources. |
| 3 [Windows] | `windows/src/AINotebook.Core/Rag/{EmbeddingProfile,EmbeddingInput}.cs`, `windows/tests/AINotebook.Core.Tests/Rag/EmbeddingProfileTests.cs`; Core csproj `:24` | Same logic; embed exact shared production resources. |
| 4 [Swift] | `Providers/OllamaBenchmarkClient.swift`, `Providers/StrictEmbeddingPipeline.swift`; planned `Providers/ProviderEmbeddingSession.swift`, existing `Providers/ProviderRouter.swift`; `OllamaBenchmarkClientTests.swift`, `StrictEmbeddingPipelineTests.swift` | Strict transport, count telemetry, captured query/document formatting. Existing raw client discards metadata at `OllamaClient.swift:109`; do not alter that compatibility path. WP5 session plan `:1587`. |
| 5 [Windows] | `Providers/{OllamaBenchmarkClient,StrictEmbeddingPipeline,ProviderEmbeddingSession}.cs`, planned `Providers/ProviderRouter.cs`; `Providers/{OllamaBenchmarkClientTests,StrictEmbeddingPipelineTests}.cs` | Windows peers; raw client at `Ollama/OllamaClient.cs:70` remains compatible. |
| 6 [Swift] | `TokenEstimatorV2.swift`, `TokenCalibration.swift`, `BenchmarkReport.swift`; `TokenEstimatorV2Tests.swift`, `BenchmarkReportTests.swift` | Pure calibrated estimator, metrics/report math; existing estimator interface `ContextPackAlgorithms.swift:3`. |
| 7 [Windows] | `Rag/{TokenEstimatorV2,TokenCalibration}.cs`, `Eval/BenchmarkReport.cs`; `Rag/TokenEstimatorV2Tests.cs`, `Eval/BenchmarkReportTests.cs` | Same behavior; interface `Rag/ContextPackAlgorithms.cs:5`. |
| 8a/8b/8c [Swift] | new `EmbeddingGenerationBuilder.swift`, `BenchmarkMeasurements.swift`, `BenchmarkTelemetry.swift`, `BenchmarkOptions.swift`, `BenchmarkRunner.swift`; corresponding `EmbeddingGenerationBuilderTests.swift`, `BenchmarkMeasurementsTests.swift`, `BenchmarkTelemetryTests.swift`, `BenchmarkRunnerTests.swift`; existing `Sources/RetrievalEvalRunner/main.swift:234` | Separate staging, measurements and CLI tasks; WP1 dispatch and WP5 timing handoffs precede edits. |
| 9a/9b/9c [Windows] | new `Rag/EmbeddingGenerationBuilder.cs`, `Eval/{BenchmarkMeasurements,BenchmarkTelemetry,BenchmarkOptions,BenchmarkRunner}.cs`; corresponding `Rag/EmbeddingGenerationBuilderTests.cs`, `Eval/{BenchmarkMeasurementsTests,BenchmarkTelemetryTests,BenchmarkRunnerTests}.cs`; planned `windows/tools/AINotebook.Eval/Program.cs` | Three matching disjoint Windows tasks; WP1 owns initial Program. |
| 10/10b/10c [Swift] | new `EmbeddingRecommendation.swift`, `EmbeddingRebuildService.swift`, `EmbeddingRebuildJournal.swift`, `NotebookStore+EmbeddingRebuild.swift`, `ProfileEmbeddingDrain.swift`, `NotebookStore+ProfileEmbedding.swift` and their four named test files; modify `ContextPackBuilder.swift:7`, `ContextPackBuilderTests.swift:100`, `Embedder.swift:16,37`, `EmbedderTests.swift` | Policy, recoverable rebuild, and ordinary import profile propagation are separate dependency-ordered tasks. |
| 11/11b/11c [Windows] | new `Rag/{EmbeddingRecommendation,EmbeddingRebuildService,EmbeddingRebuildJournal,ProfileEmbeddingDrain}.cs`, `Storage/{NotebookStore.EmbeddingRebuild,NotebookStore.ProfileEmbedding}.cs` and their four named test files; modify `Rag/ContextPackBuilder.cs:13`, `Rag/ContextPackBuilderTests.cs:12`, `Rag/Embedder.cs:20,31`, `Rag/EmbedderTests.cs` | Matching three Windows Core tasks. |
| 12 [Shared] | Task 1's generated calibration/decision resources and calibration fixture; `tools/benchmark/verify_reports.py`, `tools/benchmark/test_verify_reports.py`; `docs/eval/README.md:1`, `docs/eval/wp7/{macos,windows}-{calibration,benchmark}.{json,md}`, `docs/eval/wp7/decision.json`, optional `docs/eval/wp7/sweep/{macos,windows}-f{32,48,64}-t{16,24}-e{6000,7000}.{json,md}`; conditional `Tests/fixtures/contracts/constants-v2.json` | Claude's real calibration, hardware comparison, decision, reproducible report validation. No invented measurements. |
| 13 [Swift-UI] | `AppSettings.swift:42,90`, `Providers/ProviderSelection.swift:41`, `Localization.swift:102,365,603`; `Sources/AINotebookApp/{AINotebookApp.swift:20,SettingsView.swift:184,Onboarding/PickModelsStepView.swift:9,ChatView.swift:540}`; `AppSettingsTests.swift:62`, new `EmbeddingRecommendationUITests.swift` | Persist fresh default, recommendation and safe reindex UI, EN/CS. |
| 14 [Win-UI] | `App.xaml.cs:56`, `Services/{SettingsService.cs:37,ISettingsService.cs:13,StringKey.cs:30}`, `ViewModels/{SettingsViewModel.cs:248,ChatViewModel.cs:419}`, `Views/{SettingsDialog.xaml:56,SettingsDialog.xaml.cs:50}`, `Onboarding/{PickModelsStep.xaml:13,PickModelsStep.xaml.cs:10}`, `Strings/{en-US,cs-CZ}/Resources.resw:317`; App tests `{SettingsServiceTests.cs:20,LocalizedStringsTests.cs:16,EmbeddingRecommendationTests.cs}` | Windows bindings/bootstrap/localization and App tests. |
| 15 [Swift] | new `RagRuntimeTuning.swift`, `RagRuntimeTuningTests.swift`; modify `ContextPackAlgorithms.swift:110,115`, `ContextPackBuilder.swift:7,56`, `Retriever.swift` (WP5 typed overloads), `ContextPackBuilderTests.swift:100` | Versioned runtime parameters; runs after10 and before8c. |
| 16 [Windows] | new `Rag/RagRuntimeTuning.cs`, `Rag/RagRuntimeTuningTests.cs`; modify `Rag/{ContextPackAlgorithms.cs:100,137,ContextPackBuilder.cs:13,Retriever.cs}`, `Rag/ContextPackBuilderTests.cs:12` | Windows runtime parameter twin after11 and before9c. |
| 17 [Swift] | new `Providers/ProviderTokenCalibration.swift`, `ProviderTokenCalibrationTests.swift`, `ContextPackEstimatorInjectionTests.swift`; modify planned `Providers/ProviderSession.swift`, current `Providers/ProviderRouter.swift:29,74,90`, planned `ContextPackCoordinator.swift`, `ContextPackAdapters.swift`, current `ChatEngine.swift:125,179` | Verified estimator injection after provider and WP8 integration. |
| 18 [Windows] | new `Providers/ProviderTokenCalibration.cs`, `Providers/ProviderTokenCalibrationTests.cs`, `Rag/ContextPackEstimatorInjectionTests.cs`; modify planned `Providers/ProviderSession.cs`, `Providers/ProviderRouter.cs`, `Rag/ContextPackCoordinator.cs`, `Rag/ContextPackAdapters.cs`, current `Rag/ChatEngine.cs:91` | Captured digest/estimator through Windows production chat. |

All unqualified production Swift files are under `Sources/AINotebookCore/`; all unqualified Swift tests under `Tests/AINotebookCoreTests/`. Tasks 3/5/7/9/11/16/18 and their subtask C# source paths in the table are relative to `windows/src/AINotebook.Core/`, tests to `windows/tests/AINotebook.Core.Tests/`. Task 14 app paths are relative to `windows/src/AINotebook.App/`, tests to `windows/tests/AINotebook.App.Tests/`.

## Execution schedule

After shared Task1, run2/3 concurrently; 4/6 follow2 and 5/7 follow3. Then4/5 enable8a/9a, while4+6 and5+7 enable8b/9b. Policy10/11 enables tuning15/16 and rebuild10b/11b; ordinary-import10c/11c follows its rebuild task. Runner8c waits15; runner9c waits16. Task12 joins both runner lanes and records real hardware/decision data. UI13/14 then binds the result, and17/18 completes production calibrated chat injection. Every task still obeys its explicit WP prerequisites. A task may start only from merged prerequisites, even when its heading appears earlier than one of them. The extra staging/measurement/drain subdivisions keep each coding task bounded to one session.

## Prerequisite handoffs and measurement rules

`EvalCorpus` is present (`Sources/AINotebookCore/EvalCorpus.swift:194`, `windows/src/AINotebook.Core/Eval/EvalCorpus.cs:49`); WP1's `EvalRunner`, `EvalMetrics`, `EvalReportV1` are planned, not present at this planning commit. The WP8 pure builders and prepared source/revision pair arrays **are already present** (`ContextPackTypes.swift:352`, C# `Rag/ContextPackTypes.cs:97`). Use those actual arrays, not the older WP8 plan's dictionary wording.

Required upstream interfaces at handoff (Tasks15/16 later replace only typed optional fetchK defaults; explicit call values retain behavior):

```swift
// WP1 plan:734–758,1175. Existing EvalSpan uses scalar offsets and content hash.
EvalRunner.load(root: URL) throws -> (corpus: EvalCorpus, hash: String)
EvalMetrics.recall(gold: [EvalSpan], evidence: [EvalSpan]) -> EvalMetric
// WP3 plan:1158; Store is MainActor-isolated.
store.createGeneration(notebookId: Int64, identity: GenerationIdentity, now: Int64) throws -> IndexGeneration
store.setManifest(generationId: Int64, entries: [ManifestEntry]) throws
store.storeGenerationEmbedding(generationId: Int64, chunkId: Int64, vector: EmbeddingVector) throws
store.activateGeneration(id: Int64, now: Int64) throws
// WP5 plan:1829–1872; successful pool takes ownership of snapshot.
retriever.search(notebookId: Int64, query: String, scope: RetrievalScope,
                 fetchK: Int = 32, includeVectors: Bool = true) async throws -> PinnedRetrievalCandidates
retriever.searchEmbedded(snapshot: ResolvedRetrievalScope, query: String,
                         queryVector: [Float]?, fetchK: Int = 32) async throws -> PinnedRetrievalCandidates
hydrator.hydrate(_ snapshot: ResolvedRetrievalScope, references: [ChunkReference],
                 neighborRadius: Int = 1) async throws -> [EvidencePassage]
ContextPackBuilder.build(_ input: ContextPackInput,
                         estimator: any ContextTokenEstimating) throws -> PreparedContextRequest
```

```csharp
// WP1 plan:758,1183; WP3:1175; WP5:1856; existing WP8 builder.
(EvalCorpus Corpus, string Hash) EvalRunner.Load(string root);
EvalMetric EvalMetrics.Recall(IReadOnlyList<EvalSpan> gold, IReadOnlyList<EvalSpan> evidence);
IndexGeneration NotebookStore.CreateGeneration(long notebookId, GenerationIdentity identity, long now);
void NotebookStore.SetManifest(long generationId, IReadOnlyList<ManifestEntry> entries);
void NotebookStore.StoreGenerationEmbedding(long generationId, long chunkId, EmbeddingVector vector);
void NotebookStore.ActivateGeneration(long id, long now);
Task<PinnedRetrievalCandidates> Retriever.SearchAsync(long notebookId, string query,
    RetrievalScope scope, int fetchK=32, bool includeVectors=true, CancellationToken ct=default);
Task<PinnedRetrievalCandidates> Retriever.SearchEmbeddedAsync(ResolvedRetrievalScope snapshot,
    string query, float[]? queryVector, int fetchK=32, CancellationToken ct=default);
IReadOnlyList<EvidencePassage> EvidenceHydrator.Hydrate(ResolvedRetrievalScope snapshot,
    IReadOnlyList<ChunkReference> references, int neighborRadius=1);
PreparedContextRequest ContextPackBuilder.Build(ContextPackInput input, IContextTokenEstimator? estimator=null);
```

WP5 `SyntheticRetrievalCorpus.populate(store:chunkCount:dims:seed:)` / `Populate(NotebookStore,int,int,int=17)` creates deterministic one-hot vectors. Its `RetrievalPerformance.measure(snapshot:embedding:retrieval:hydration:ticksPerSecond:now:)` / `MeasureAsync(...)` times embedding, retrieval and hydration separately and releases the pin. Fresh `VectorMatrixCache(budgetBytes:)` / `new VectorMatrixCache(long)` measures application-cache cold load; it does **not** flush the OS page cache. Synthetic performance says nothing about semantic recall. Multilingual ingestion uses actual model vectors and real revision publication, never WP1's legacy temporary ingestion backend.

The seven profile IDs are `nomic-v2-256`, `nomic-v2-768`, `qwen3-06b-256`, `qwen3-06b-512`, `qwen3-06b-1024`, `bge-m3-1024`, `paraphrase-768`. Freeze these exact data rows:

| Model ID | Native dimensions | Output dimensions | Total input token ceiling | Query prefix | Document prefix |
|---|---:|---|---:|---|---|
| `nomic-embed-text-v2-moe` | 768 | 256, 768 | 512 | `search_query: ` | `search_document: ` |
| `qwen3-embedding:0.6b` | 1024 | 256, 512, 1024 | 32768 | `Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:` | empty |
| `bge-m3` | 1024 | 1024 | 8192 | empty | empty |
| `paraphrase-multilingual` | 768 | 768 | 512 | empty | empty |

Ceilings include prefix and special tokens; effective ceiling is the smaller documented profile ceiling and valid `/api/show` context limit. Explicitly record `paraphrase` policy as `ollama-512`, because the upstream sentence-transformers wrapper uses 128. Primary sources checked for this plan: [Nomic](https://ollama.com/library/nomic-embed-text-v2-moe), [Qwen](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B), [BGE](https://huggingface.co/BAAI/bge-m3), [Ollama paraphrase](https://ollama.com/library/paraphrase-multilingual), [upstream paraphrase wrapper](https://huggingface.co/sentence-transformers/paraphrase-multilingual-mpnet-base-v2), [Ollama embed API](https://docs.ollama.com/api/embed). Ollama exposes aggregate `prompt_eval_count` and `truncate` defaults true. There is no documented `/api/tokenize`; do not invent one.

**Input policy:** Preserve exact scalars. Format each part once. Ask for native dimensions, explicitly `truncate:false`, then prefix-project only Matryoshka-capable Nomic/Qwen vectors, L2-normalize each part, compute original-scalar-length-weighted mean, L2-normalize the result. One immutable source chunk retains one pooled vector; the benchmark must name this pooled-chunk policy. Oversized queries use the same complete-input policy. A typed length rejection, or a successful exact count above the profile ceiling, causes balanced scalar bisection. Recurse left then right until accepted. Reuse accepted vectors; do not count them twice. One scalar plus formatting that cannot fit throws `inputCannotFit`. Other provider errors propagate. Empty input is `emptyInput`. This avoids a new vector schema and does not claim independent retrieval of split parts.

Format strings are literal: `wp7:<profileId>:query:split1:scalarpool1:prefixl2:ctx<effectiveLimit>` and `wp7:<profileId>:document:split1:scalarpool1:prefixl2:ctx<effectiveLimit>`. Any change requires new strings. Model digest and endpoint revision remain separate generation fields. The integer effective limit is frozen after `/api/show` and included in both format strings; pass it as `options.num_ctx` on every embed request. Profile IDs already include output dimension; validate that `GenerationIdentity.dims` agrees. Legacy sessions bypass all WP7 formatting/projection.

## Calibration identity and measurement protocol


A chat-token calibration family is **not** an embedder model family. Define `family = "ollama:" + modelDigest` for provider-observed counts (digest is the full lowercase model manifest SHA256 prefixed `sha256:`). For documented local tokenizer counts define `family = "hf:" + tokenizerId + "@" + revision + ":" + assetsSha256`. Keep `model`, `modelDigest`, `ollamaVersion`, `tokenizerId`, `tokenizerRevision`, `tokenizerAssetsSha256`, `showTemplateSha256` and observation method as separate provenance fields. Any changed digest/template/tokenizer inventory creates a different family. No alias substring or architecture-family heuristic may select rates. An HF family is approved for an Ollama manifest only after the same body's raw token count and complete rendered-prompt observation have passed the recorded calibration validation for that manifest. No measured family may be labeled `fixture-only`.

The current pack model has provider/model/runtime fields but **no digest** (`Sources/AINotebookCore/ContextPackTypes.swift:8–24`, `windows/src/AINotebook.Core/Rag/ContextPackTypes.cs:11–12`). Therefore the pure builder cannot prove that an arbitrary model name still has its benchmark tokenizer. Keep the builder's default estimator v2 conservative UTF8 fallback; inject a calibrated estimator only when the caller has a captured digest proven to match the resource binding. Extend the existing proposed factory:

```swift
public static func bundled(model: String, modelDigest: String? = nil) throws -> TokenEstimatorV2
public static func resolveFamily(model: String, modelDigest: String?, bindings: [TokenFamilyBinding]) -> String?
public struct TokenFamilyBinding: Codable, Equatable, Sendable {
    public let model: String, modelDigest: String, family: String
}
```

```csharp
public static TokenEstimatorV2 Bundled(string model,string? modelDigest=null);
public static string? ResolveFamily(string model,string? modelDigest,IReadOnlyList<TokenFamilyBinding> bindings);
public sealed record TokenFamilyBinding(string Model,string ModelDigest,string Family);
```

Resolve only exact `(model,modelDigest)` equality, missing digest → null → empty-rate UTF8 fallback. `bundled(model:)` remains source-compatible and is honest; the benchmark passes its verified digest. Keep prepared request contract's estimatorVersion2 unchanged; add calibrationHash/family to **benchmark reports**, not the frozen WP8 prepared JSON. Product provider-session wiring can inject the estimator without changing PackModel. Tasks17/18 own this production injection after the WP8 integration; they are required for the WP gate.

Concrete family-binding tests (place alongside existing estimator tests):

```swift
func testMutableModelAliasDoesNotSelectUnprovenRates() throws {
    let rows = [TokenFamilyBinding(model:"llama3.2:3b",modelDigest:"sha256:" + String(repeating:"a",count:64),family:"fixture-only")]
    XCTAssertNil(TokenEstimatorV2.resolveFamily(model:"llama3.2:3b",modelDigest:nil,bindings:rows))
    XCTAssertNil(TokenEstimatorV2.resolveFamily(model:"llama3.2:3b",modelDigest:"sha256:" + String(repeating:"b",count:64),bindings:rows))
    XCTAssertEqual(TokenEstimatorV2.resolveFamily(model:"llama3.2:3b",modelDigest:rows[0].modelDigest,bindings:rows),"fixture-only")
    let fallback = try TokenEstimatorV2(family:"unverified",rates:[])
    XCTAssertEqual(fallback.estimate("a😀b",language:"cs"),7) //6 UTF8 bytes +15%,ceil
}
```

```csharp
[Fact] public void MutableModelAliasDoesNotSelectUnprovenRates()
{
    var rows = new[] { new TokenFamilyBinding("llama3.2:3b","sha256:"+new string('a',64),"fixture-only") };
    Assert.Null(TokenEstimatorV2.ResolveFamily("llama3.2:3b",null,rows));
    Assert.Null(TokenEstimatorV2.ResolveFamily("llama3.2:3b","sha256:"+new string('b',64),rows));
    Assert.Equal("fixture-only",TokenEstimatorV2.ResolveFamily("llama3.2:3b",rows[0].ModelDigest,rows));
    Assert.Equal(7,new TokenEstimatorV2("unverified",[]).Estimate("a😀b","cs"));
}
```

Use `llama3.2:3b` as the initial chat calibration subject because that is the existing chat default (`AppSettings.swift:88–89`, `SettingsService.cs:48`); add it to the explicit pull list. This does not change the chat default. Record digest before any calibration, and verify it again after all requests.

For each declared cs/sk/en/de corpus language, scalar-sort documents by document_id, then assign indices0,1,2 train; index3 holdout, repeating mod4. Every derived paragraph/window/query for a document inherits that document's partition. This prevents overlapping source text crossing train/holdout. Use non-overlapping scalar windows up to256 from each canonical document and the whole document if <=1024 scalars; exclude empty samples. Add gold query text to that document's partition only when all gold docs share a partition; otherwise reserve the query entirely for holdout. Absence/scope/overview queries never fit body rates. Mixed-language samples concatenate one same-partition window from each of cs/sk/en/de with literal LF and are labeled mixed. `und` runtime uses max trained language rate; never borrow an English divisor. Sample ID is `document_id + ":" + start + ":" + end`; mixed IDs concatenate source sample IDs; source windows always use half-open scalar offsets.

Primary body count uses `/api/generate` on chat model `llama3.2:3b` with `raw:true`, `stream:false`, `options:{num_predict:1,temperature:0,num_ctx:8192}`, no system/template/context, and reads its final `prompt_eval_count`. This is a provider-observed raw prompt count including any backend-required BOS token; do not subtract an empty-prompt response or infer it from output tokens. The existing profile embedding metadata is unrelated. Add exact methods:

```swift
public func observeRaw(model: String, text: String, options: ChatRequestOptions)
    async throws -> ChatTokenObservation
```

```csharp
public Task<ChatTokenObservation> ObserveRawAsync(string model,string text,
    ChatRequestOptions options,CancellationToken ct=default);
```

Use the same `ChatTokenObservation` return type; generated text is discarded for calibration. Freeze wire cases `raw-calibration` (exact /api/generate body and response count), `raw-missing-count` (documented tokenizer fallback), `raw-negative-count` (invalidTokenCount), and `chat-full-prompt` (messages preserved, no raw flag). Count missing uses the documented offline **chat** tokenizer with `add_special_tokens=True,truncation=False`, exact revision/assets inventory and `documented-tokenizer` method. Unknown/missing fallback fails the row. Body samples have <=1024 scalars and runtime8192, so they cannot approach truncation under the UTF8-byte upper bound. No `/api/tokenize` endpoint is assumed.

Embedding input counts from `/api/embed` are separately collected for all seven profiles and all languages, including each formatted accepted part. They validate strict input limits and ingestion token throughput. **They never enter chat/evidence rates.** Explicitly report whether an observed count is provider processed tokens or documented-tokenizer count. When prefix/special-token behavior disagrees between HF and Ollama, strict `truncate:false` remains the server guard; do not label the fallback Ollama-exact.

Fit only training body rows using max per-language ceil(tokens*10000/scalars), then fixed15% headroom and existing4/message +8/section. Freeze rates before holdout. Both platforms consume the same frozen rate resource, not separately fit rates from their local nondeterministic runs. macOS and Windows repeat count validation against identical sample IDs; counts must agree when digest, tokenizer assets, Ollama version and template match, otherwise record divergence and withhold calibrated status.

Evaluate full prompt residual with the **real** `PreparedContextRequest`: `estimatedPrompt = sum(message.sections.tokens) + 4*messages.count` (actual invariant at ContextPackBuilder.swift:178). Render each wire message exactly as production: one content string from ordered section texts joined with `\n\n`. Send those frozen messages through `observeChat`, with num_ctx8192 and num_predict1 for count-only validation. Do not reconstruct a second pseudo-prompt or estimate the JSON bytes. Store prepared JSON SHA256, wire messages SHA256, exact prompt count, estimatedPrompt, actual-minus-estimated, questionID, partition, digest/template provenance. Exercise answer, empty selection, overview, history, external-note, metadata-heavy and clipped-first-passage cases. For clipping use the builder's actual chosen prefix, not the unsliced source chunk.

Require zero undercounts on held-out body rows and full prompts before marking a family `calibrated`; report max/mean overestimate too. A held-out undercount is a failed measurement, not permission to fit that sample. Claude either retains conservative fallback or revises the rate policy using training data then evaluates against a new explicitly versioned disjoint holdout partition. Never alter the fixture expected counts to hide the failure. Pending calibration resources are allowed for implementation commits only; WP release/decision gate must contain at least the actual chat-default family plus all-language body and full-prompt validation observations, or explicitly remain blocked.

Exact calibration report schema (add to Task1 contract table, with synthetic fixtures):

```text
TokenCalibrationReportV1 {contract:"token-calibration-report",version:1,status:complete|incomplete,
 corpusHash,platform,model,modelDigest,ollamaVersion,showTemplateSha256,
 family,method:documented-tokenizer|ollama-raw-prompt,
 tokenizerId,tokenizerRevision,tokenizerAssetsSha256,
 samples:[{id,language,split:train|holdout,documentId,start,end,scalars,utf8Bytes,tokens}],
 rates:[{family,language,tokensPerScalarBp}],headroomBp:1500,
 promptChecks:[{queryId,split,preparedHash,wireMessagesHash,actualTokens,estimatedTokens}],
 bodyHoldoutUndercounts,promptHoldoutUndercounts,maxOverestimateTokens,
 calibrated:boolean,errorCode}
```

Nullable tokenizer fields are required null for provider-observed counts; counters missing from a failed request are null with errorCode, never0. Runtime `token-estimate-v2.json` has `{contract:"token-estimate",version:2,status,payloadHash,bindings,rates,provenance}` plus `cases` in the fixture copy only; payloadHash excludes itself and hashes canonical JSON of bindings/rates/provenance. Initial status pending has empty bindings/rates/provenance, not fixture-only rates. Task12 replaces it from reviewed measured reports, and regenerates expected measured-resource integrity cases without erasing arithmetic fixtures.


## Tasks

### Task 1: [Shared] Freeze benchmark fixtures, production data and offline token counting protocol

**Depends on:** WP0 corrections, WP1 shared fixtures, WP2/WP5 interface freeze. **Parallel with:** no downstream WP7 task until its commit; read-only reviews may run concurrently.

**Files:** Only the Task 1 files in File Structure. Do not edit `tools/contracts/gen_fixtures.py`, WP1 fixtures, or frozen constants-v1. The Benchmark resource directory is new. Its initial decision is `{ "contract":"embedding-decision", "version":1, "status":"pending", "profileId":null }`; initial calibration has no measured families. Pending decision resources also contain baseline `parameters:{fetchK:32,topK:16,evidenceShareBp:6000}` for the runtime tuning reader. These are truthful pending data, not release artifacts.

**Interfaces — Consumes:** Swift `SharedFixtures.data(_:) throws -> Data`; C# `SharedFixtures.Json(string) -> JsonElement`. **Produces:** `python3 -B tools/contracts/gen_benchmark_fixtures.py [--check]`; `make_contracts() -> dict[str,dict]`; JSON envelopes `{contract,version,cases}`; runtime catalog `{contract,version,profiles}`. All names/fields below are the exact wire contract, consumed unchanged on both platforms. Runtime resources are derived from the same generator data, never hand-copied platform constants. `make_contracts()` returns fixture envelopes only, including `cases` on the profile fixture; a separate `make_resources()` strips fixture cases and emits the three production resources.

- [ ] **Step 1: Write and run the failing standard-library tests.**

```python
import unittest
from tools.contracts.gen_benchmark_fixtures import make_contracts, calibrate, percentile

class ContractTests(unittest.TestCase):
    def test_profile_matrix(self):
        f = make_contracts()["embedding-profiles-v1.json"]
        self.assertEqual(7, len(f["profiles"]))
        self.assertEqual([256, 512, 1024], [p["dims"] for p in f["profiles"]
                          if p["model"] == "qwen3-embedding:0.6b"])

    def test_calibration_rounding(self):
        self.assertEqual(6667, calibrate([(3, 2), (10, 3)]))
        self.assertEqual(190, percentile(list(range(1, 201)), 9500))
        self.assertEqual(100, percentile(list(range(1, 201)), 5000))

    def test_all_envelopes(self):
        for name, f in make_contracts().items():
            self.assertIsInstance(f["version"], int, name)
            names = [c["name"] for c in f["cases"]]
            self.assertEqual(len(names), len(set(names)), name)
```

Run `python3 -B -m unittest tools.benchmark.test_contracts` → **FAIL: missing generator**. Implement the reference arithmetic:

```python
def ceildiv(a, b):
    if a < 0 or b <= 0:
        raise ValueError("invalidCalibration")
    return a // b + (a % b != 0)

def calibrate(samples):
    if not samples or any(s <= 0 or t < 0 for s, t in samples):
        raise ValueError("invalidCalibration")
    return max(ceildiv(t * 10000, s) for s, t in samples)

def estimate(scalars, rate_bp, headroom_bp=1500):
    return ceildiv(ceildiv(scalars * rate_bp, 10000) * (10000 + headroom_bp), 10000)

def percentile(samples, bp):
    if not samples or not 0 < bp <= 10000 or min(samples) < 0:
        raise ValueError("invalidSamples")
    return sorted(samples)[ceildiv(len(samples) * bp, 10000) - 1]
```

- [ ] **Step 2: Write fixtures with these exact named cases and values.** The generator writes UTF-8/LF, sorted object keys, `ensure_ascii=False`, indentation 2, final LF; `--check` compares bytes without writing and exits 1 on any difference. It prints interpreter versions only as diagnostics. It does not classify Unicode using host tables or include SQLite versions in bytes.

| Fixture | Required cases and assertion data |
|---|---|
| `embedding-profiles-v1` | All seven rows above. For each: `query-cs` text `Kdo ručí?`, `document-sk` text `Záruka platí.`, exact formatted output, query/doc format strings. `unknown-profile` → `unknownProfile`; `wrong-dims` → `profileIdentityMismatch`; `nomic-project` native `[3,4,12]`, test dims2 → `expectedMillionths:[600000,800000]`; `pool` vectors `[1,0]`,`[0,1]`, scalarWeights1,2 → `expectedMillionths:[447214,894427]`; zero/nonfinite/wrong-length vectors → `invalidEmbedding`. Small vector cases exercise the projection kernel, not a fabricated 2-dimensional production profile. Vector expected values are integer millionths; compare actual Float components to expected/1000000 within1e-6. Nonfinite test inputs use string sentinels converted by the harness, never invalid JSON number tokens. |
| `embedding-strict-v1` | `fits` text `abc`, limit5, prefix `q:`, count5; `split` text `ab😀cd`, per-scalar fake count plus prefix2, limit5 → spans `[0,2)`,`[2,5)` with exact concatenation; `prefix-exhausts` limit2 → `inputCannotFit`; `server-limit` first typed length rejection then accepted children; `unrelated-400`, `http-500`, `cancel` → propagate without split; `no-count` → offline counter used; `no-count-no-tokenizer` → `tokenCountUnavailable`; `wrong-dim` and `nonfinite` fail before publication. Wire request gold includes `truncate:false`, native `dimensions`, one input, explicit model. |
| `token-estimate-v2` | `ceil-rate` samples `{scalars:3,tokens:2}`, `{scalars:10,tokens:3}` → rate6667; `ceil-headroom` scalars3/rate6667 → estimate4; `empty` →0; `astral` text `a😀b` →scalars3; `unknown-language` uses max trained rate; `unknown-family` uses UTF-8-byte fallback plus headroom; `training-order` permuted samples identical; `holdout-under` estimated4/actual5 → undercount1; `invalid-zero-scalars` → `invalidCalibration`. Synthetic test family is named `fixture-only`, never a shipped measured family. |
| `benchmark-report-v1` | `complete`/`missing-windows`/`bad-identity`/`unmeasured-counts`/`decision-pair`; `percentiles-200` samples1…200 →p50=100,p95=190; `threshold-equal` 300000 →false; `threshold-below`299999→true; tokens120/time2000000us→60 tokens/s represented `tokensPerSecondMilli:60000`; denominator0 →null; title `A|B\nC\\D` exact escaped Markdown. `input`, complete `expectedJson` and `expectedMarkdown` are generated with every report field below. |
| `benchmark-run-v1` | `phase-order`, `cancel-build`, `cancel-query`, `failed-generation`, `dual-revisions`, `zero-evidence`, `truncated-away-gold`, `empty-selection`, `overview`, `overlap-required`, `cache-streamed`, `cold-new-cache`, `citation-wrong-revision`, `citation-unknown-marker`. A phase trace is an array of literal phase names, and expected counters accompany each case. |
| `embedding-default-v1` | `fresh`: no DB/preferences/onboarding/selection→recommended; `database-only`,`settings-only`,`completed-onboarding`,`explicit-custom`,`explicit-old`,`converted-chat-only`→preserve; `pending-decision`→legacy default; `second-launch`→preserve stored profile; `cancel-rebuild`→old generation; `failed-rebuild`→old generation; `publish-complete`→new generation, old retired. |


The same Task1 generator also includes these required cases before any platform task starts:

- `embedding-strict-v1`: `raw-calibration`, `raw-missing-count`, `raw-negative-count`, `chat-full-prompt` from the calibration protocol; `prepare-profile`, `prepare-profile-root-change`, `prepare-profile-no-model`, `prepare-profile-no-context`, `prepare-profile-chat-only`, `latest-alias-exact`, `resume-digest-changed`, `publish-digest-changed`; the three-leaf unequal-depth split; telemetry split with3 requests/2 responses/1 typed rejection/2 accepted leaves/9 useful tokens/1 uncounted request.
- `token-estimate-v2`: full `TokenCalibrationReportV1` input/expectedJson/expectedMarkdown golden under `kind:"calibration-report"`, including an incomplete missing-count report; digest binding exact/missing/changed cases and constructor negative/duplicate/rate-overflow cases. `kind:"calibration-observations"` uses body count2, embedding count9 for the same3 scalars and asserts fitted rate6667, proving embed counts do not enter chat calibration.
- `benchmark-run-v1`: `kind:"tuning"` pending32/16/6000, accepted48/24/7000, invalid fetchK<topK, topK0, share10001, and zero-cap under7000; `kind:"memory"` samples(80,10),(20,70)→runner80/server70/combined90, plus process parent-cycle, missing-root and overflow; `kind:"cli"` defaults/repeated/missing/overflow/unsupported flags; `citation-wrong-chunk`, `fnv-abc`→440920331; every named phase/cancellation case above. Each case stores complete inputs and expected values, and each test dispatches every row exactly once.
- `embedding-default-v1`: install rows have `kind:"install"` and evidence/decision/expected applyProfileId objects; journal cases `kind:"rebuild"` cover each before/after-activation crash, complete-set rollback, duplicate operation and persistence retry; drain cases `kind:"drain"` cover fresh import, restart with0 requests, same model/other dims, legacy nil profile, refresh pending, lost lease, changed selection and changed active generation. Use canonical text `Záruka platí.`, expected modern request `search_document: Záruka platí.`, native768/output256 and both format strings endingctx512.
- `token-calibration-session-v1`: matching/different/missing digest, duplicate/unknown model, remote provider, metadata failure/cancellation, changed-before-send, same-across-retry, captured-root, coordinator injection and explicit tuning. Exact inputs, expected calls/errors/estimates and complete prepared JSON for coordinator rows follow Tasks17/18; rate5000 estimates `a😀b` as3, UTF8 fallback as7. Digests are real64-character fixture strings. This fixture is test data, never a production model binding.
- `benchmark-report-v1` `decision-pair` contains complete Mac/Windows synthetic reports and a valid synthetic calibration for verifier unit tests; all7 profiles have four performance rows,200 raw samples each with p50=100/p95=190 and complete correctness counts. The CLI verifier rejects fixture mode for a release decision.

All these additions remain within Task1's file list. `make_contracts()` emits the calibration-session fixture too. Production data projection excludes every fixture-only family and all cases.

Freeze report DTO fields in `docs/contracts/benchmark-v1.md`:

```text
BenchmarkReportV1 {contract:"benchmark-report", version:1, status:complete|incomplete,
 backend:"fts-or-pinned-rrf-v1", mode:fixture|live, platform:macos|windows,
 environment:{cpu,ramBytes,os,architecture,buildCommit,ollamaVersion,accelerator},
 corpus:{id,hash,documents,queries,chunkerVersion}, calibrationHash,
 parameters:{fetchK,topK,evidenceShareBp,runtimeContext,maxOutputTokens,seed},
 chat:{model,modelDigest,tokenFamily,showTemplateSha256},
 candidates:[{profileId,identity:{providerId,endpointRevision,model,modelDigest,dims,
 normalization,queryFormatVersion,docFormatVersion,chunkerVersion}, status,errorCode,
 quality:{metrics,byLanguage,byCaseType,queries},
 citations:{snapshotsCorrect,snapshotsTotal,answerMarkersCorrect,answerMarkersTotal,
           answerGoldSupported,answerMarkersJudged,semanticReview:"not_measured"},
 ingest:{serviceTokens,successfulTokens,rejectedRequests,splitParts,elapsedUs,
         tokensPerSecondMilli,runnerPeakRssBytes,serverPeakRssBytes,combinedPeakRssBytes,
         serviceTokenStatus,uncountedRequests,memoryMethod,sampleIntervalMs},
 performance:[{chunks,concurrent,queries,warmupQueries,warmP50Us,warmP95Us,
   endToEndP50Us,endToEndP95Us,hydrationP95Us,coldCacheLoadUs,cacheMode,
   residentBytes,peakPageBytes,completedWrites,overlapUs,gatePassed,
   samples:[{queryId,embeddingUs,retrievalUs,hydrationUs,endToEndUs}]}]}]}
```


Define `quality.queries` as ordered `BenchmarkQualityQuery` values, never an untyped dictionary. Swift `public struct BenchmarkQualityQuery: Codable, Sendable` fields are `eval:EvalQueryRow`, `packed:[EvalSpan]`, `citationMap:[Citation]`, `answerText:String?`, `preparedHash:String?`, `timing:BenchmarkTimingValues?`, `overview:BenchmarkOverviewCounts?`; C# `public sealed record BenchmarkQualityQuery(EvalQueryRow Eval,IReadOnlyList<EvalSpan> Packed,IReadOnlyList<Citation> CitationMap,string? AnswerText,string? PreparedHash,BenchmarkTimingValues? Timing,BenchmarkOverviewCounts? Overview)`. Swift `BenchmarkTimingValues` holds four `Int64` fields `embeddingUs,retrievalUs,hydrationUs,endToEndUs`; C# is `record BenchmarkTimingValues(long EmbeddingUs,long RetrievalUs,long HydrationUs,long EndToEndUs)`. `BenchmarkOverviewCounts` fields are `filesInScope,publishedCandidateFiles,filesIncluded` (`Int`/`int`). These DTOs, and `BenchmarkTimingSample(queryId:Int,embeddingUs:Int64,retrievalUs:Int64,hydrationUs:Int64,endToEndUs:Int64)` / C# `BenchmarkTimingSample(int QueryId,long EmbeddingUs,long RetrievalUs,long HydrationUs,long EndToEndUs)`, belong to Tasks6/7 report files; Tasks8b/9b consume them without declaring a second type. WP1's exact `EvalQueryRow` stays unchanged and embedded under `eval`; serialize its existing snake_case fields through its codec. Citation snapshots use the existing CitationsCodec v2 item serializer (extract the `items` array), excluding computed `isV2`. Complete golden reports include these fields and audit the full prepared hash, output marker occurrences, packed spans and real timing. Optional unavailable fields are explicit nulls.

`metrics` uses WP1's five metric names and its `status/found/total/recall_bp` objects unchanged. Do not alter historical `eval-report-v1.json`; its backend `legacy-fts-eval-rrf-v1` remains accurate. Every optional unavailable number is null with explicit status/error; never zero. Every sample time is integer microseconds. Candidate order follows the seven-row catalog; languages cs,de,en,sk,und,mixed; queries scalar-sort by query ID; perf rows by chunks then concurrent false/true. JSON uses the exact camelCase names above outside the embedded WP1 metric objects. Markdown lists environment, profile identity, overall/per-language metrics, citation counters, ingestion and four performance rows, with final LF; generator creates the whole golden string, not fragments.

- [ ] **Step 3: Add offline tokenizer fallback with no download code.** `tokenizer-requirements.txt` pins `transformers==4.51.3`, `tokenizers==0.21.1`, `sentencepiece==0.2.0`. `tokenize_offline.py --root DIR` reads newline JSON `{requestId,tokenizerId,text}` and emits `{requestId,tokens,tokenizerId,revision,assetsSha256}`. Load `AutoTokenizer.from_pretrained(manifest[tokenizerId]["path"],local_files_only=True,trust_remote_code=False)` once per tokenizer; count `len(tokenizer.encode(text,add_special_tokens=True,truncation=False))`. Set `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` before imports. The root manifest maps exact IDs to local asset directories, upstream immutable revision and SHA-256 inventory. Verify all hashes before answering; missing/mismatched assets terminate with `tokenizerUnavailable`. Never truncate, download, or log text. Fallback clients start this process with an argument array, pass text on stdin, and validate matching request IDs; no shell interpolation.

`test_tokenize_offline.py` injects a tokenizer factory into `count(request,manifest,factory)` and proves `add_special_tokens=True,truncation=False`, hash failure, unknown ID, supplementary scalars preserved and request-ID echo. This test requires no third-party packages. Live fallback is allowed only for the model card's documented tokenizer: `nomic-ai/nomic-embed-text-v2-moe`, `Qwen/Qwen3-Embedding-0.6B`, `BAAI/bge-m3`, `sentence-transformers/paraphrase-multilingual-mpnet-base-v2`; each catalog row stores that exact `tokenizerId` separately from its Ollama `model`; chat families have their own tokenizer IDs and provenance. An offline count is labeled `documented-tokenizer`, not `ollama-exact`; missing required counts fail a benchmark row, not silently use the estimator.

Add to `test_tokenize_offline.py` (the pure `count` receives an already verified manifest; `load_manifest(root)` owns filesystem hash validation):

```python
class OfflineCounterTests(unittest.TestCase):
    def test_count_preserves_text_and_disables_truncation(self):
        from tools.benchmark.tokenize_offline import count
        calls = []
        class Tokenizer:
            def encode(self, text, *, add_special_tokens, truncation):
                calls.append((text, add_special_tokens, truncation))
                return [1, 2, 3]
        manifest = {"fixture-tokenizer": {"path":"unused", "revision":"fixture-revision",
                                         "assetsSha256":"a" * 64}}
        result = count({"requestId":"r1","tokenizerId":"fixture-tokenizer","text":"a😀b"},
                       manifest, lambda path: Tokenizer())
        self.assertEqual([("a😀b",True,False)], calls)
        self.assertEqual(3, result["tokens"])
        self.assertEqual("r1", result["requestId"])
```

- [ ] **Step 4: Run green and commit.**

```bash
python3 -B -m unittest tools.benchmark.test_contracts tools.benchmark.test_tokenize_offline
python3 -B tools/contracts/gen_benchmark_fixtures.py
python3 -B tools/contracts/gen_benchmark_fixtures.py --check
swift test --filter SharedFixturesTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/contracts/gen_benchmark_fixtures.py tools/benchmark/test_contracts.py tools/benchmark/tokenize_offline.py tools/benchmark/test_tokenize_offline.py tools/benchmark/tokenizer-requirements.txt Tests/fixtures/contracts/embedding-profiles-v1.json Tests/fixtures/contracts/embedding-strict-v1.json Tests/fixtures/contracts/benchmark-report-v1.json Tests/fixtures/contracts/benchmark-run-v1.json Tests/fixtures/contracts/embedding-default-v1.json Tests/fixtures/contracts/token-estimate-v2.json Tests/fixtures/contracts/token-calibration-session-v1.json Sources/AINotebookCore/Resources/Benchmark docs/contracts/benchmark-v1.md
git commit -m "test(benchmark): freeze WP7 profiles and deterministic contracts" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all Python tests and both complete suites pass; generator check exits0; no live requests.

### Task 2: [Swift] Profile catalog, exact formatting and vector projection/pooling

**Depends on:** 1; WP4 Package.swift resource registration merged. **Parallel with:** 3,7. **Files:** Task 2 row only.

**Interfaces — Consumes:** catalog resource and `SharedFixtures`; C# twin signatures below. **Produces:**

```swift
public enum EmbeddingPurpose: String, Codable, Sendable { case query, document }
public struct EmbeddingProfile: Codable, Equatable, Sendable {
    public let id: String, model: String, tokenizerId: String, queryPrefix: String, documentPrefix: String
    public let nativeDims: Int, dims: Int, maxInputTokens: Int
    public let matryoshka: Bool
    public func format(_ text: String, purpose: EmbeddingPurpose) -> String
    public func formatVersion(_ purpose: EmbeddingPurpose, effectiveLimit: Int? = nil) -> String
}
public enum EmbeddingProfiles {
    public static func bundled() throws -> [EmbeddingProfile]
    public static func require(_ id: String) throws -> EmbeddingProfile
}
public enum EmbeddingInput {
    public static func project(_ vector: [Float], nativeDims: Int, dims: Int) throws -> [Float]
    public static func pool(_ vectors: [[Float]], scalarWeights: [Int]) throws -> [Float]
    public static func bisect(_ text: String) throws -> (String, String)
}
// All invalid inputs throw EmbeddingProfileError(code: String), Equatable + Sendable.
```

```csharp
public enum EmbeddingPurpose { Query, Document }
public sealed record EmbeddingProfile(string Id,string Model,string TokenizerId,string QueryPrefix,string DocumentPrefix,
    int NativeDims,int Dims,int MaxInputTokens,bool Matryoshka)
{
    public string Format(string text, EmbeddingPurpose purpose);
    public string FormatVersion(EmbeddingPurpose purpose,int? effectiveLimit=null);
}
public static IReadOnlyList<EmbeddingProfile> EmbeddingProfiles.Bundled();
public static EmbeddingProfile EmbeddingProfiles.Require(string id);
public static float[] EmbeddingInput.Project(float[] vector,int nativeDims,int dims);
public static float[] EmbeddingInput.Pool(IReadOnlyList<float[]> vectors,IReadOnlyList<int> scalarWeights);
public static (string Left,string Right) EmbeddingInput.Bisect(string text);
// EmbeddingProfileException(string code) exposes Code.
```

- [ ] **Step 1: Red fixture tests**, including every formatting row, before adding types.

```swift
import XCTest
@testable import AINotebookCore

final class EmbeddingProfileTests: XCTestCase {
    func testSharedFormats() throws {
        let root = try SharedFixtures.json("contracts/embedding-profiles-v1.json")
        for c in root["cases"] as! [[String: Any]] where c["kind"] as? String == "format" {
            let p = try EmbeddingProfiles.require(c["profileId"] as! String)
            let purpose = EmbeddingPurpose(rawValue: c["purpose"] as! String)!
            XCTAssertEqual(p.format(c["text"] as! String, purpose: purpose), c["expected"] as? String)
            XCTAssertEqual(p.formatVersion(purpose), c["formatVersion"] as? String)
        }
    }
    func testProjectionAndCompleteScalarSplit() throws {
        let v = try EmbeddingInput.project([3,4,12], nativeDims: 3, dims: 2)
        XCTAssertEqual(v[0], 0.6, accuracy: 0.000001)
        XCTAssertEqual(v[1], 0.8, accuracy: 0.000001)
        let (a,b) = try EmbeddingInput.bisect("ab😀cd")
        XCTAssertEqual(a, "ab"); XCTAssertEqual(b, "😀cd")
        XCTAssertEqual(a+b, "ab😀cd")
        XCTAssertThrowsError(try EmbeddingInput.project([0,0], nativeDims: 2, dims: 2))
    }
}
```

Run `swift test --filter EmbeddingProfileTests` → **FAIL: missing types**. Add separate fixture-driven methods for pool, unknown ID, mismatched profile dimensions and invalid vectors; no platform-specific expected formatting.

- [ ] **Step 2: Implement pure kernels and resource decode.**

```swift
public static func bisect(_ text: String) throws -> (String, String) {
    let s = Array(text.unicodeScalars)
    guard s.count > 1 else { throw EmbeddingProfileError(code: "inputCannotFit") }
    let n = s.count / 2
    return (String(String.UnicodeScalarView(s[..<n])),
            String(String.UnicodeScalarView(s[n...])))
}
public static func project(_ vector: [Float], nativeDims: Int, dims: Int) throws -> [Float] {
    guard vector.count == nativeDims, dims > 0, dims <= nativeDims,
          vector.allSatisfy({ $0.isFinite }) else {
        throw EmbeddingProfileError(code: "invalidEmbedding")
    }
    let values = vector.prefix(dims).map(Double.init)
    let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    guard norm.isFinite, norm > 0 else { throw EmbeddingProfileError(code: "invalidEmbedding") }
    return values.map { Float($0 / norm) }
}
public static func pool(_ vectors: [[Float]], scalarWeights: [Int]) throws -> [Float] {
    guard let first = vectors.first, !first.isEmpty, vectors.count == scalarWeights.count,
          scalarWeights.allSatisfy({ $0 > 0 }),
          vectors.allSatisfy({ $0.count == first.count && $0.allSatisfy(\.isFinite) }) else {
        throw EmbeddingProfileError(code: "invalidEmbedding")
    }
    var sum = Array(repeating: 0.0, count: first.count)
    for (v,w) in zip(vectors, scalarWeights) {
        for d in sum.indices { sum[d] += Double(v[d]) * Double(w) }
    }
    let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
    guard norm.isFinite, norm > 0 else { throw EmbeddingProfileError(code: "invalidEmbedding") }
    return sum.map { Float($0 / norm) }
}
```

`format` is `(purpose == .query ? queryPrefix : documentPrefix) + text`; no trimming/normalization. `formatVersion` appends `:ctx` plus `effectiveLimit ?? maxInputTokens` in invariant decimal to the literal policy above. Session preparation validates that limit is in `1...maxInputTokens`. Validate seven unique IDs, exact allowed dimensionalities, positive ceilings, and no dimension reduction when `matryoshka==false`. Register `.copy("Resources/Benchmark")` on the Core target beside, not instead of, WP4 resources. Decode using `Bundle.module`; never locate `Tests/` at runtime.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter EmbeddingProfileTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Package.swift Sources/AINotebookCore/EmbeddingProfile.swift Sources/AINotebookCore/EmbeddingInput.swift Tests/AINotebookCoreTests/EmbeddingProfileTests.swift
git commit -m "feat(core): versioned multilingual embedding profiles" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all profile cases pass, full Swift suite zero failures/skips.

### Task 3: [Windows] Profile catalog and complete-input vector kernels

**Depends on:** 1; WP4 Core resource registration merged. **Parallel with:** 2,6. **Files:** Task 3 row only.

**Interfaces — Consumes:** Task 1 JSON and C# `SharedFixtures.Json`; Swift producer/consumer signatures in Task 2 are the parity boundary. **Produces:** all C# signatures in Task 2 under `AINotebook.Core.Rag`, plus `EmbeddingProfileException.Code`.

- [ ] **Step 1: Write red tests.**

```csharp
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

public sealed class EmbeddingProfileTests
{
    [Fact] public void SharedFormats()
    {
        foreach (var c in SharedFixtures.Json("contracts/embedding-profiles-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("kind", out var k) || k.GetString() != "format") continue;
            var p = EmbeddingProfiles.Require(c.GetProperty("profileId").GetString()!);
            var purpose = c.GetProperty("purpose").GetString() == "query" ? EmbeddingPurpose.Query : EmbeddingPurpose.Document;
            Assert.Equal(c.GetProperty("expected").GetString(), p.Format(c.GetProperty("text").GetString()!, purpose));
            Assert.Equal(c.GetProperty("formatVersion").GetString(), p.FormatVersion(purpose));
        }
    }
    [Fact] public void ProjectionAndCompleteScalarSplit()
    {
        var v = EmbeddingInput.Project([3,4,12],3,2);
        Assert.InRange(Math.Abs(v[0] - 0.6f),0,0.000001f);
        Assert.InRange(Math.Abs(v[1] - 0.8f),0,0.000001f);
        var (a,b) = EmbeddingInput.Bisect("ab😀cd");
        Assert.Equal("ab",a); Assert.Equal("😀cd",b); Assert.Equal("ab😀cd",a+b);
        Assert.Throws<EmbeddingProfileException>(() => EmbeddingInput.Project([0,0],2,2));
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EmbeddingProfileTests` → **FAIL: missing types**. Add methods iterating all vector/error cases, with exact error codes.

- [ ] **Step 2: Implement kernels.** Use `System.Text` runes, not UTF-16 substring indices.

```csharp
public static (string Left,string Right) Bisect(string text)
{
    var s = text.EnumerateRunes().ToArray();
    if (s.Length < 2) throw new EmbeddingProfileException("inputCannotFit");
    int n = s.Length / 2;
    return (string.Concat(s.Take(n).Select(r=>r.ToString())),
            string.Concat(s.Skip(n).Select(r=>r.ToString())));
}
public static float[] Project(float[] vector,int nativeDims,int dims)
{
    if (vector.Length != nativeDims || dims <= 0 || dims > nativeDims || vector.Any(x=>!float.IsFinite(x)))
        throw new EmbeddingProfileException("invalidEmbedding");
    double norm = Math.Sqrt(vector.Take(dims).Sum(x=>(double)x*x));
    if (!double.IsFinite(norm) || norm == 0) throw new EmbeddingProfileException("invalidEmbedding");
    return vector.Take(dims).Select(x=>(float)(x/norm)).ToArray();
}
public static float[] Pool(IReadOnlyList<float[]> vectors,IReadOnlyList<int> scalarWeights)
{
    if (vectors.Count == 0 || vectors.Count != scalarWeights.Count || vectors[0].Length == 0
        || scalarWeights.Any(x=>x<=0) || vectors.Any(v=>v.Length!=vectors[0].Length || v.Any(x=>!float.IsFinite(x))))
        throw new EmbeddingProfileException("invalidEmbedding");
    var sum = new double[vectors[0].Length];
    for (int i=0;i<vectors.Count;i++)
        for (int d=0;d<sum.Length;d++) sum[d] += (double)vectors[i][d]*scalarWeights[i];
    double norm = Math.Sqrt(sum.Sum(x=>x*x));
    if (!double.IsFinite(norm) || norm == 0) throw new EmbeddingProfileException("invalidEmbedding");
    return sum.Select(x=>(float)(x/norm)).ToArray();
}
```

Validate unpaired UTF-16 in public input before rune enumeration (throw `invalidText`); Swift cannot represent it. Add linked `EmbeddedResource Include="../../../Sources/AINotebookCore/Resources/Benchmark/*.json" LogicalName="AINotebook.Benchmark.%(Filename)%(Extension)"` to the Core csproj. Read exact resource names from `typeof(EmbeddingProfiles).Assembly`; retain existing WP4 resources and package references. Format strings match Task 2 exactly, with invariant decimal profile IDs supplied by data.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EmbeddingProfileTests
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/AINotebook.Core.csproj windows/src/AINotebook.Core/Rag/EmbeddingProfile.cs windows/src/AINotebook.Core/Rag/EmbeddingInput.cs windows/tests/AINotebook.Core.Tests/Rag/EmbeddingProfileTests.cs
git commit -m "feat(win-core): multilingual profile formatting and vector policy" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: every shared formatting/vector case green; complete Core suite zero failures/skips.

### Task 4: [Swift] Strict provider requests, real counts and purpose-aware sessions

**Depends on:** 2; WP2 Core sessions/options and WP5 Task 10 merged. **Parallel with:** 3,5,6,7. **Files:** Task 4 row only. `ProviderEmbeddingSession.swift` is a planned WP5 file; current `ProviderRouter.swift` is read and extended only after that handoff.

**Interfaces — Consumes:** `EmbeddingProfile`, kernels, WP2 `ProviderAPIRoot` and `OllamaClient.show(model:) async throws -> Data`; WP5 `EmbeddingSessionPreparing.prepareEmbedding(identity:)`. **Produces:**

```swift
public struct StrictEmbeddingResult: Sendable {
    public let vector: [Float]
    public let promptTokens: Int? // single input only
    public let totalDurationNs: Int64?, loadDurationNs: Int64?
}
public protocol StrictEmbeddingTransport: Sendable {
    func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult
}
public protocol ExactTokenCounting: Sendable {
    func count(_ text: String, tokenizerId: String) async throws -> Int
}
public struct EmbeddingInputTooLong: Error, Sendable { public init() {} }
public struct EmbeddedInput: Sendable {
    public let vector: [Float]
    public let parts: [EmbeddedPart]
    public let successfulTokens: Int, rejectedRequests: Int
}
public struct EmbeddedPart: Codable, Equatable, Sendable {
    public let start: Int, end: Int, tokens: Int
}
public struct StrictEmbeddingPipeline: Sendable {
    public init(transport: any StrictEmbeddingTransport, counter: (any ExactTokenCounting)? = nil,
                observer: (any EmbeddingTelemetryObserving)? = nil)
    public func embed(_ text: String, profile: EmbeddingProfile, purpose: EmbeddingPurpose,
                      effectiveLimit: Int) async throws -> EmbeddedInput
}
public final class OllamaBenchmarkClient: StrictEmbeddingTransport, Sendable {
    public init(baseURL: URL, session: URLSession = .shared)
    public func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult
    public func observeRaw(model: String, text: String, options: ChatRequestOptions)
        async throws -> ChatTokenObservation
    public func observeChat(model: String, messages: [ChatTurn], options: ChatRequestOptions)
        async throws -> ChatTokenObservation
}
public struct ChatTokenObservation: Codable, Sendable {
    public let text: String, promptTokens: Int?, outputTokens: Int?
}
// Add to WP5 captured session. Existing embed remains QUERY-purpose.
public var identity: GenerationIdentity? { get } // full captured modern identity; legacy nil
public func embedDocuments(inputs: [String]) async throws -> [[Float]]
```

```csharp
public sealed record StrictEmbeddingResult(float[] Vector,int? PromptTokens,long? TotalDurationNs,long? LoadDurationNs);
public interface IStrictEmbeddingTransport {
    Task<StrictEmbeddingResult> EmbedAsync(string model,string input,int nativeDims,int inputLimit,CancellationToken ct=default);
}
public interface IExactTokenCounter {
    Task<int> CountAsync(string text,string tokenizerId,CancellationToken ct=default);
}
public sealed class EmbeddingInputTooLongException : Exception { }
public sealed record EmbeddedPart(int Start,int End,int Tokens);
public sealed record EmbeddedInput(float[] Vector,IReadOnlyList<EmbeddedPart> Parts,int SuccessfulTokens,int RejectedRequests);
public sealed class StrictEmbeddingPipeline(IStrictEmbeddingTransport transport,IExactTokenCounter? counter=null,
    IEmbeddingTelemetryObserver? observer=null) {
    public Task<EmbeddedInput> EmbedAsync(string text,EmbeddingProfile profile,EmbeddingPurpose purpose,
        int effectiveLimit,CancellationToken ct=default);
}
public sealed record ChatTokenObservation(string Text,int? PromptTokens,int? OutputTokens);
public sealed class OllamaBenchmarkClient(Uri baseUrl,HttpClient http) : IStrictEmbeddingTransport {
    public Task<StrictEmbeddingResult> EmbedAsync(string model,string input,int nativeDims,int inputLimit,CancellationToken ct=default);
    public Task<ChatTokenObservation> ObserveRawAsync(string model,string text,
        ChatRequestOptions options,CancellationToken ct=default);
    public Task<ChatTokenObservation> ObserveChatAsync(string model,IReadOnlyList<ChatTurn> messages,
        ChatRequestOptions options,CancellationToken ct=default);
}
public GenerationIdentity? ProviderEmbeddingSession.Identity { get; }
public Task<float[][]> ProviderEmbeddingSession.EmbedDocumentsAsync(IReadOnlyList<string> inputs,CancellationToken ct=default);
```

The following captured discovery and telemetry interfaces are also produced by Tasks4/5. Collector types at the end are produced later by Tasks8b/9b in their existing BenchmarkTelemetry files:

```swift
public struct PreparedEmbeddingProfile: Sendable {
    public let identity: GenerationIdentity
    public let session: ProviderEmbeddingSession
}
public struct EmbeddingTelemetryEvent: Sendable {
    public let kind: String // request, response, lengthRejected, partAccepted
    public let purpose: EmbeddingPurpose
    public let tokens: Int?, start: Int?, end: Int?
    public init(kind: String, purpose: EmbeddingPurpose, tokens: Int? = nil,
                start: Int? = nil, end: Int? = nil)
}
public protocol EmbeddingTelemetryObserving: Sendable {
    func record(_ event: EmbeddingTelemetryEvent) async
}
// Extend existing Task4 initializer; never global/static mutable telemetry.
public init(transport: any StrictEmbeddingTransport, counter: (any ExactTokenCounting)? = nil,
            observer: (any EmbeddingTelemetryObserving)? = nil)
// On ProviderRouter, in its assigned file:
public func prepareEmbeddingProfile(providerId: String, profileId: String,
    observer: (any EmbeddingTelemetryObserving)? = nil) async throws -> PreparedEmbeddingProfile
// Internal captured modern initializer in ProviderEmbeddingSession.swift:
internal init(storageKey: String, endpointRevision: String, identity: GenerationIdentity,
              profile: EmbeddingProfile, pipeline: StrictEmbeddingPipeline, effectiveLimit: Int)
```

```csharp
public sealed record PreparedEmbeddingProfile(GenerationIdentity Identity,ProviderEmbeddingSession Session);
public sealed record EmbeddingTelemetryEvent(string Kind,EmbeddingPurpose Purpose,int? Tokens=null,int? Start=null,int? End=null);
public interface IEmbeddingTelemetryObserver {
    ValueTask RecordAsync(EmbeddingTelemetryEvent observation);
}
public StrictEmbeddingPipeline(IStrictEmbeddingTransport transport,IExactTokenCounter? counter=null,
    IEmbeddingTelemetryObserver? observer=null);
public Task<PreparedEmbeddingProfile> ProviderRouter.PrepareEmbeddingProfileAsync(string providerId,string profileId,
    IEmbeddingTelemetryObserver? observer=null,CancellationToken ct=default);
internal ProviderEmbeddingSession(string storageKey,string endpointRevision,GenerationIdentity identity,
    EmbeddingProfile profile,StrictEmbeddingPipeline pipeline,int effectiveLimit);
```

`prepareEmbeddingProfile` snapshots provider config/key/root exactly once, requires an enabled/consented embedding-capable Ollama provider for these named profiles, looks up exact model ID in `/api/tags` (its documented `:latest` canonical alias is an explicit equality entry only), reads `/api/show` using the same captured adapter, resolves the architecture's context limit using WP2's frozen metadata parser, and chooses `min(profile.maxInputTokens,contextLimit)`; missing positive context metadata fails `modelMetadataUnavailable`. Construct identity `(providerId,EndpointRevision.make(type,root),profile.model,exactDigest,profile.dims,"l2",profile.formatVersion(query,effectiveLimit),profile.formatVersion(document,effectiveLimit),"2")`. Create the modern captured session directly from those values, without calling a second mutable-settings resolver. The existing `prepareEmbedding(identity:)` verifies the captured model tag still has the recorded nonnil `modelDigest` before returning a named-profile session; mismatch throws `embeddingModelChanged` with zero embedding requests (retrieval retains its existing `embeddingFailed` lexical fallback). Add same-name/different-digest and missing-digest wire fixtures on both platforms. Before publishing a background rebuilt generation, revalidate that same captured adapter/digest; a changed model cannot mix vectors under the earlier identity. It opens that historical exact identity: parse its ctx suffix and preserve it; never re-probe to silently change it. Ordinary ingestion reuses the active exact identity unless an explicit rebuild changes profile/root/context. Benchmark, Settings and fresh-import workers consume this single discovery API.

Add Task4/5 tests for `PrepareProfileCapturesIdentityOnce`: mock tags+show responses, assert digest, dimensions, doc/query prefix policies, ctx cap and endpoint hash; mutate provider root after tags but before show, assert show and every embed remain on the captured root. Missing model, wrong dimensions, missing/invalid context, unsupported provider and changed metadata at verification produce typed failures with no substituted model. Record exact `:latest` matching cases in shared fixtures, never substring matching.

The strict pipeline emits `request` immediately before each HTTP attempt, `response(tokens:r.promptTokens)` immediately after every valid successful response (including successful-over-limit inputs), `lengthRejected` only for the one typed server-length failure, and `partAccepted(tokens:count,start:...,end:...)` after exact count validation and projection. A purpose field separates document ingestion from query traffic. Negative/malformed count responses fail validation and emit no accepted part. Callback failures cannot drop embedding work because observer protocol is nonthrowing; a collector encountering overflow stores an invalid flag and makes report validation fail.

Task8b/9b owns a per-candidate actor/lock-protected collector implementing this observer. A snapshot filters document events: useful tokens=sum partAccepted.tokens, splitParts=count partAccepted, rejectedRequests=count lengthRejected, serviceTokens=sum native response.tokens only if every request has a response with native count; otherwise serviceTokens=null, serviceTokenStatus=partial/not_available, uncountedRequests=requestCount-nativeCountResponseCount. Fallback tokenizer counts determine useful accepted tokens but do not fabricate Ollama service tokens. Throughput elapsed includes every attempt and publication. Emit an accepted event once per leaf, never once per parent pooled result. Add fixture asserting split input gives request3,response2,typedReject1,acceptedLeaves2,usefulTokens9,serviceTokensnull,uncountedRequests1; a successful-over-limit request adds its real service count but contributes no useful leaf tokens.

Collector retrieval is explicit:

```swift
public struct EmbeddingTelemetrySnapshot: Sendable {
    public let serviceTokens: Int64?, successfulTokens: Int64
    public let requestCount: Int, rejectedRequests: Int, splitParts: Int, uncountedRequests: Int
    public let serviceTokenStatus: String
}
public actor BenchmarkEmbeddingTelemetry: EmbeddingTelemetryObserving {
    public init()
    public func record(_ event: EmbeddingTelemetryEvent)
    public func snapshot(purpose: EmbeddingPurpose) throws -> EmbeddingTelemetrySnapshot
}
```

```csharp
public sealed record EmbeddingTelemetrySnapshot(long? ServiceTokens,long SuccessfulTokens,int RequestCount,
    int RejectedRequests,int SplitParts,int UncountedRequests,string ServiceTokenStatus);
public sealed class BenchmarkEmbeddingTelemetry : IEmbeddingTelemetryObserver {
    public ValueTask RecordAsync(EmbeddingTelemetryEvent observation);
    public EmbeddingTelemetrySnapshot Snapshot(EmbeddingPurpose purpose);
}
```

The Swift actor's synchronous isolated `record` satisfies the async observer requirement; callers outside the actor await it. C# snapshots copy immutable values under a short collector lock. No SQL or provider call occurs inside that lock.

- [ ] **Step 1: Red protocol tests with injected transport.** Add this test before implementation, and a fixture runner that drives every `embedding-strict-v1` request/response sequence. The fake increments requests, rejects when formatted scalar count exceeds5, and otherwise returns `[1,0]` with that count; its public test profile uses nativeDims2/dims2 and prefix `q:`.

```swift
final class StrictEmbeddingPipelineTests: XCTestCase {
    actor CounterTransport: StrictEmbeddingTransport {
        var requests = 0
        func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult {
            requests += 1
            let n = input.unicodeScalars.count
            if n > 5 { throw EmbeddingInputTooLong() }
            return StrictEmbeddingResult(vector: [1,0], promptTokens: n, totalDurationNs: 1000, loadDurationNs: 0)
        }
    }
    func testSplitKeepsEveryScalarAndCountsPrefixes() async throws {
        let transport = CounterTransport()
        let p = EmbeddingProfile(id: "fixture", model: "fixture", tokenizerId: "fixture-only", queryPrefix: "q:", documentPrefix: "",
            nativeDims: 2, dims: 2, maxInputTokens: 5, matryoshka: false)
        let result = try await StrictEmbeddingPipeline(transport: transport).embed(
            "ab😀cd", profile: p, purpose: .query, effectiveLimit: 5)
        XCTAssertEqual(result.parts.map(\.start), [0,2])
        XCTAssertEqual(result.parts.map(\.end), [2,5])
        XCTAssertEqual(result.successfulTokens, 9)
        XCTAssertEqual(result.rejectedRequests, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests, 3)
    }
}
```

Run `swift test --filter 'StrictEmbeddingPipelineTests|OllamaBenchmarkClientTests'` → **FAIL: types missing**. HTTP tests use an injected URLProtocol, never Ollama. Check exact `/api/embed` suffix under proxy roots, `input:[text]`, native `dimensions`, `truncate:false`; decode telemetry; reject empty/multiple vectors, nonfinite numbers, negative counts, wrong dimension. Count missing → offline counter; missing both → `tokenCountUnavailable`. Assert generic 400/413/500, authentication, cancellation and malformed response never split. Only HTTP400 with JSON `error` exactly `the input length exceeds the context length` maps to `EmbeddingInputTooLong` ([official Ollama handler](https://github.com/ollama/ollama/blob/main/server/routes.go)); preserve sanitized unknown errors.

- [ ] **Step 2: Implement the recursive kernel.** Use bounded recursion depth (scalar bisection, at most ceil(log2(scalarCount))), task cancellation before every request/child, and preserve start offsets. This is the central implementation:

```swift
var leaves: [(vector: [Float], part: EmbeddedPart)] = []
var rejected = 0
func visit(_ raw: String, start: Int) async throws {
    try Task.checkCancellation()
    let formatted = profile.format(raw, purpose: purpose)
    do {
        let r = try await transport.embed(model: profile.model, input: formatted, nativeDims: profile.nativeDims, inputLimit: effectiveLimit)
        let validated = try EmbeddingInput.project(r.vector, nativeDims: profile.nativeDims, dims: profile.dims)
        let count: Int
        if let observed = r.promptTokens { count = observed }
        else if let counter { count = try await counter.count(formatted, tokenizerId: profile.tokenizerId) }
        else { throw EmbeddingProfileError(code: "tokenCountUnavailable") }
        guard count >= 0 else { throw EmbeddingProfileError(code: "invalidTokenCount") }
        if count <= effectiveLimit {
            leaves.append((validated, EmbeddedPart(start:start,end:start+raw.unicodeScalars.count,tokens:count)))
            return
        }
        // This successful response exceeded the profile ceiling; split its entire input.
    } catch is EmbeddingInputTooLong {
        rejected += 1
    }
    let (left,right) = try EmbeddingInput.bisect(raw)
    try await visit(left,start:start)
    try await visit(right,start:start+left.unicodeScalars.count)
}
try await visit(text,start:0)
return EmbeddedInput(vector:try EmbeddingInput.pool(leaves.map(\.vector),
    scalarWeights:leaves.map { $0.part.end-$0.part.start }),parts:leaves.map(\.part),
    successfulTokens:leaves.reduce(0) { $0+$1.part.tokens },rejectedRequests:rejected)
```

Pool all accepted leaves exactly once; normalizing intermediate pooled nodes would change weights. Add a three-leaf unequal-depth fixture to catch that error. `rejectedRequests` counts only typed length-rejected requests. The per-run telemetry collector counts every successful response's observed tokens, including successful-over-limit responses, separately from useful leaf tokens. A rejected request without a count is recorded as uncounted, never assigned fabricated service tokens. Useful throughput divides accepted leaf tokens by wall time including retries. Require exact fallback counts before accepting a leaf when metadata is absent.

`observeChat` sends `POST /api/chat`, `stream:false`, fixed `temperature:0`, `num_ctx`, `num_predict`, frozen messages; returns final prompt/output counts and answer. `/api/show` metadata and `/api/tags` digests are captured before the run and rechecked at end. Add no speculative tokenize endpoint. Offline count adapter wraps Task 1's process with `Process` pipes in this provider file.

- [ ] **Step 3: Wire named formats into immutable sessions.** Validate both format strings and dims before network; resolve exact profile; capture the WP2 normalized root, credential state and adapter once. Legacy/1 sessions use their old client path. Named profiles require a strict transport; an unsupported provider returns `unsupportedEmbeddingProfile`, never a raw-input fallback. `embed(inputs:)` loops query purpose; `embedDocuments(inputs:)` loops document purpose. No current-settings read after capture. Existing WP5 unknown-format tests still reject 99, and add a test where settings mutate during the first await while both requests retain original model/root/profile.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter 'StrictEmbeddingPipelineTests|OllamaBenchmarkClientTests|ProviderEmbeddingSessionTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/Providers/OllamaBenchmarkClient.swift Sources/AINotebookCore/Providers/StrictEmbeddingPipeline.swift Sources/AINotebookCore/Providers/ProviderEmbeddingSession.swift Sources/AINotebookCore/Providers/ProviderRouter.swift Tests/AINotebookCoreTests/OllamaBenchmarkClientTests.swift Tests/AINotebookCoreTests/StrictEmbeddingPipelineTests.swift
git commit -m "feat(providers): strict complete-input embedding sessions and telemetry" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all focused tests plus the full Swift suite pass with no network. Add the new session regression to `StrictEmbeddingPipelineTests.swift`, so the existing WP5 test file remains read-only.

### Task 5: [Windows] Strict requests, telemetry and query/document sessions

**Depends on:** 3; WP2 routing and WP5 Task 11 merged. **Parallel with:** 2,4,6,7. **Files:** Task 5 row only.

**Interfaces — Consumes:** `IEmbeddingSessionPreparing.PrepareEmbeddingAsync(GenerationIdentity,CancellationToken)`, profiles/kernels and WP2 `OllamaClient.ShowAsync(string,CancellationToken)`. Swift equivalents are Task 4's explicit signatures. **Produces:** all C# declarations in Task 4 in `AINotebook.Core.Providers`; immutable captured session gains `EmbedDocumentsAsync` and retains query-purpose `EmbedAsync`.

- [ ] **Step 1: Write red tests, including real fake HTTP handler.**

```csharp
public sealed class StrictEmbeddingPipelineTests
{
    private sealed class CounterTransport : IStrictEmbeddingTransport
    {
        public int Requests;
        public Task<StrictEmbeddingResult> EmbedAsync(string model,string input,int nativeDims,int inputLimit,CancellationToken ct=default)
        {
            ct.ThrowIfCancellationRequested(); Requests++;
            int n = input.EnumerateRunes().Count();
            if (n > 5) throw new EmbeddingInputTooLongException();
            return Task.FromResult(new StrictEmbeddingResult([1,0],n,1000,0));
        }
    }
    [Fact] public async Task SplitKeepsEveryScalarAndCountsPrefixes()
    {
        var t = new CounterTransport();
        var p = new EmbeddingProfile("fixture","fixture","fixture-only","q:","",2,2,5,false);
        var r = await new StrictEmbeddingPipeline(t).EmbedAsync("ab😀cd",p,EmbeddingPurpose.Query,5);
        Assert.Equal(new[]{0,2},r.Parts.Select(x=>x.Start));
        Assert.Equal(new[]{2,5},r.Parts.Select(x=>x.End));
        Assert.Equal(9,r.SuccessfulTokens); Assert.Equal(1,r.RejectedRequests); Assert.Equal(3,t.Requests);
    }
}
```

Use `System.Text`, xUnit and the provider namespace. Run `dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~StrictEmbeddingPipelineTests|FullyQualifiedName~OllamaBenchmarkClientTests'` → **FAIL: missing types**. The fixture theory covers all shared wire/error cases. For cancellation use a handler awaiting a cancelable `TaskCompletionSource`, then assert no second request, no pooled output. Add three-leaf unequal-depth pooling, count-missing fallback, wrong count/vector/dim, exact proxy URL, unrelated HTTP400, and captured root/model mutation.

- [ ] **Step 2: Implement exact token-aware recursion with a leaf accumulator.**

```csharp
var leaves = new List<(float[] Vector,EmbeddedPart Part)>();
int rejected = 0;
async Task Visit(string raw,int start)
{
    ct.ThrowIfCancellationRequested();
    string formatted = profile.Format(raw,purpose);
    bool split = false;
    try
    {
        var r = await transport.EmbedAsync(profile.Model,formatted,profile.NativeDims,effectiveLimit,ct);
        var validated=EmbeddingInput.Project(r.Vector,profile.NativeDims,profile.Dims);
        int count = r.PromptTokens ?? (counter is not null
            ? await counter.CountAsync(formatted,profile.TokenizerId,ct)
            : throw new EmbeddingProfileException("tokenCountUnavailable"));
        if (count < 0) throw new EmbeddingProfileException("invalidTokenCount");
        if (count <= effectiveLimit)
        {
            leaves.Add((validated,
                new EmbeddedPart(start,start+raw.EnumerateRunes().Count(),count)));
            return;
        }
        split = true; // telemetry records discarded successful response tokens
    }
    catch (EmbeddingInputTooLongException) { rejected++; split = true; }
    if (split)
    {
        var (a,b) = EmbeddingInput.Bisect(raw);
        await Visit(a,start);
        await Visit(b,start+a.EnumerateRunes().Count());
    }
}
await Visit(text,0);
return new EmbeddedInput(EmbeddingInput.Pool(leaves.Select(x=>x.Vector).ToArray(),
    leaves.Select(x=>x.Part.End-x.Part.Start).ToArray()),
    leaves.Select(x=>x.Part).ToArray(),leaves.Sum(x=>x.Part.Tokens),rejected);
```

Validate nonempty text, effective limit1…profile ceiling and profile identity before entering. HTTP requests use injected `HttpClient`, `JsonContent.Create`, cancellation passed to send/read, camelCase fields and `truncate=false`. Reject a response vector count other than1. Exact native dimension projection happens only after validation. Keep telemetry in a per-run collector, not static mutable state. Launch fallback Python with `ProcessStartInfo.ArgumentList`, redirected pipes, no shell, and kill child on cancellation. HTTP and process protocol remain in `Providers/`; store untouched.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~StrictEmbeddingPipelineTests|FullyQualifiedName~OllamaBenchmarkClientTests|FullyQualifiedName~ProviderEmbeddingSessionTests'
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Providers/OllamaBenchmarkClient.cs windows/src/AINotebook.Core/Providers/StrictEmbeddingPipeline.cs windows/src/AINotebook.Core/Providers/ProviderEmbeddingSession.cs windows/src/AINotebook.Core/Providers/ProviderRouter.cs windows/tests/AINotebook.Core.Tests/Providers/OllamaBenchmarkClientTests.cs windows/tests/AINotebook.Core.Tests/Providers/StrictEmbeddingPipelineTests.cs
git commit -m "feat(win-core): strict embedding pipeline and provider count observations" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all cases and full .NET Core suite pass; App builds are not required for this Core-only change.

### Task 6: [Swift] Calibration v2, benchmark metrics and deterministic reports

**Depends on:** 1,2; WP1 metrics/report handoff and WP8 estimator interface merged. **Parallel with:** 3,4,5,7. **Files:** Task 6 row only.

**Interfaces — Consumes:** `ContextTokenEstimating`, `EvalMetric`, `EvalMetrics.recall/aggregate`, Task 1 fixture shapes. **Produces:**

```swift
public struct TokenSample: Codable, Equatable, Sendable {
    public let id: String, family: String, language: String, split: String
    public let scalars: Int, tokens: Int
}
public struct TokenRate: Codable, Equatable, Sendable {
    public let family: String, language: String
    public let tokensPerScalarBp: Int
}
public enum TokenCalibration {
    public static func fit(_ training: [TokenSample]) throws -> [TokenRate]
    public static func undercounts(_ samples: [TokenSample], rates: [TokenRate]) throws -> Int
}
public struct TokenEstimatorV2: ContextTokenEstimating {
    public let version = 2
    public init(family: String, rates: [TokenRate]) throws
    public static func bundled(model: String, modelDigest: String? = nil) throws -> TokenEstimatorV2
    public func estimate(_ text: String, language: String) -> Int
}
public enum BenchmarkMath {
    public static func percentile(_ samples: [Int64], bp: Int) throws -> Int64
    public static func tokensPerSecondMilli(tokens: Int64, elapsedUs: Int64) throws -> Int64?
    public static func warmGate(chunks: Int, concurrent: Bool, queries: Int, p95Us: Int64) -> Bool?
}
public struct TokenCalibrationReportV1: Codable, Sendable {
    // All stored fields are exactly the calibration schema above, with public initializers.
    public func jsonData() throws -> Data
    public func markdown() -> String
    public func validate() throws
}
public struct BenchmarkReportV1: Codable, Sendable {
    // Stored fields/types exactly follow Task 1's complete schema.
    public func jsonData() throws -> Data
    public func markdown() -> String
    public func validate() throws
}
```

```csharp
public sealed record TokenSample(string Id,string Family,string Language,string Split,int Scalars,int Tokens);
public sealed record TokenRate(string Family,string Language,int TokensPerScalarBp);
public static IReadOnlyList<TokenRate> TokenCalibration.Fit(IReadOnlyList<TokenSample> training);
public static int TokenCalibration.Undercounts(IReadOnlyList<TokenSample> samples,IReadOnlyList<TokenRate> rates);
public sealed class TokenEstimatorV2(string family,IReadOnlyList<TokenRate> rates) : IContextTokenEstimator {
    public int Version => 2;
    public static TokenEstimatorV2 Bundled(string model,string? modelDigest=null);
    public int Estimate(string text,string language);
}
public static long BenchmarkMath.Percentile(IReadOnlyList<long> samples,int bp);
public static long? BenchmarkMath.TokensPerSecondMilli(long tokens,long elapsedUs);
public static bool? BenchmarkMath.WarmGate(int chunks,bool concurrent,int queries,long p95Us);
public sealed record TokenCalibrationReportV1 {
    public byte[] JsonBytes(); public string Markdown(); public void Validate();
}
public sealed record BenchmarkReportV1 {
    public byte[] JsonBytes(); public string Markdown(); public void Validate();
}
```

- [ ] **Step 1: Red calibration and complete report golden tests.**

```swift
final class TokenEstimatorV2Tests: XCTestCase {
    func testSharedCalibrationAndEstimator() throws {
        let f = try SharedFixtures.json("contracts/token-estimate-v2.json")
        for c in f["cases"] as! [[String: Any]] where c["kind"] as? String == "estimate" {
            let rate = TokenRate(family: "fixture-only", language: c["language"] as! String,
                                tokensPerScalarBp: c["rateBp"] as! Int)
            let e = try TokenEstimatorV2(family: "fixture-only", rates: [rate])
            XCTAssertEqual(e.estimate(c["text"] as! String, language: c["language"] as! String), c["expected"] as? Int)
            XCTAssertEqual(e.version, 2)
        }
    }
    func testFitNeverUsesHoldout() throws {
        let sample = TokenSample(id:"a",family:"fixture-only",language:"cs",split:"holdout",scalars:3,tokens:2)
        XCTAssertThrowsError(try TokenCalibration.fit([sample]))
    }
}
final class BenchmarkReportTests: XCTestCase {
    func testReportGoldens() throws {
        let f = try SharedFixtures.json("contracts/benchmark-report-v1.json")
        for c in f["cases"] as! [[String: Any]] where c["kind"] as? String == "report" {
            let r = try JSONDecoder().decode(BenchmarkReportV1.self,
                from: JSONSerialization.data(withJSONObject:c["input"]!))
            if c["error"] != nil { XCTAssertThrowsError(try r.validate()); continue }
            try r.validate()
            XCTAssertEqual(try JSONSerialization.jsonObject(with:r.jsonData()) as? NSDictionary,
                           c["expectedJson"] as? NSDictionary)
            XCTAssertEqual(r.markdown(),c["expectedMarkdown"] as? String)
        }
    }
    func testNearestRankAndStrictGate() throws {
        let samples = (1...200).map(Int64.init)
        XCTAssertEqual(try BenchmarkMath.percentile(samples,bp:9500),190)
        XCTAssertEqual(try BenchmarkMath.percentile(samples,bp:5000),100)
        XCTAssertEqual(BenchmarkMath.warmGate(chunks:100000,concurrent:false,queries:200,p95Us:300000),false)
        XCTAssertNil(BenchmarkMath.warmGate(chunks:200000,concurrent:false,queries:200,p95Us:900000))
    }
}
```

Run `swift test --filter 'TokenEstimatorV2Tests|BenchmarkReportTests'` → **FAIL: missing types**. Add fixture loops for fitting, unknown family/language, zero/negative values, integer overflow bounds, train-order permutation and holdout undercount. All test-only families are excluded from bundled production data.

- [ ] **Step 2: Implement conservative integer math.** `fit` accepts nonempty **training-only** samples, `scalars>0`, `tokens>=0`, unique IDs, permitted languages; groups by family/language, computes maximum `ceil(tokens*10000/scalars)`, scalar-sorts groups. Use checked Int64; reject rates above1,000,000 and text counts above5,000,000 (the extraction ceiling) before multiplication. Constructor/resource decode also validates nonnegative rates≤1,000,000, unique (family,language), supported language and nonempty family without whitespace; Swift throws `BenchmarkError(code:"invalidCalibration")`, C# `BenchmarkException("invalidCalibration")`. `undercounts` requires a known trained family (otherwise `uncalibratedFamily`); its scalar-only samples cannot calculate UTF-8 fallback. Runtime estimate saturates to Int32.max for oversized caller input so the existing rendering bound produces `invalidInput` (`ContextPackRendering.swift:53–57`), never traps or wraps; ordinary context overflow still returns `contextTooSmall`.

```swift
private func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { a / b + (a % b == 0 ? 0 : 1) }
public func estimate(_ text: String, language: String) -> Int {
    let rows = rates.filter { $0.family == family }
    let rate = rows.first { $0.language == language }?.tokensPerScalarBp
        ?? rows.map(\.tokensPerScalarBp).max()
    let base: Int64
    if let rate {
        let n = Int64(text.unicodeScalars.count)
        if n > 5_000_000 { return Int(Int32.max) }
        base = ceilDiv(n * Int64(rate), 10_000)
    } else {
        base = Int64(text.utf8.count) // explicitly uncalibrated conservative fallback
    }
    if base > Int64(Int32.max) / 2 { return Int(Int32.max) }
    return Int(min(Int64(Int32.max),ceilDiv(base * 11_500,10_000)))
}
public static func percentile(_ samples: [Int64], bp: Int) throws -> Int64 {
    guard !samples.isEmpty, (1...10000).contains(bp), samples.allSatisfy({ $0 >= 0 }) else {
        throw BenchmarkError(code:"invalidSamples")
    }
    return samples.sorted()[(samples.count * bp + 9999) / 10000 - 1]
}
public static func tokensPerSecondMilli(tokens: Int64, elapsedUs: Int64) throws -> Int64? {
    guard tokens >= 0, elapsedUs >= 0, tokens <= Int64.max / 1_000_000_000 else {
        throw BenchmarkError(code:"invalidSamples")
    }
    return elapsedUs == 0 ? nil : tokens * 1_000_000_000 / elapsedUs
}
```

`warmGate` returns nil unless100K/nonconcurrent/200; then `p95Us < 300000`. Negative p95 or wrong required query count invalidates a complete report. `gatePassed` is null on a non-gated scenario or unavailable measurement; the decision-level pass is false when required evidence is incomplete. Retain fixed +4/message and +8/section charges already owned by WP8; calibration evaluates their residual against fully rendered prompts as well as bodies.

- [ ] **Step 3: Implement report validation/Markdown.** Use separate typed nested DTOs for the exact schema, all with public initializers. Reject duplicate profile/query IDs, wrong dimensions/format identity, missing required phase, malformed hash, negative counts, found>total, total0 with a fabricated recall value, inconsistent grouped sums, a `complete` report with unmeasured packed evidence/citation snapshots, and live model changes during a run. Do not reject honest `incomplete` reports; their gate is false. Percentiles use stored raw samples during assembly; serialize summary values and raw query sample rows so they can be recomputed. Markdown escapes backslash first, pipe as `\|`, CR/LF as `<br>`; invariant decimal rendering computes `whole=bp/100`, `fraction=bp%100` rather than locale formatting. Null prints `not measured`, not `0`. Golden tests compare the full output including ordering and final LF.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter 'TokenEstimatorV2Tests|BenchmarkReportTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/TokenEstimatorV2.swift Sources/AINotebookCore/TokenCalibration.swift Sources/AINotebookCore/BenchmarkReport.swift Tests/AINotebookCoreTests/TokenEstimatorV2Tests.swift Tests/AINotebookCoreTests/BenchmarkReportTests.swift
git commit -m "feat(core): calibrated token estimates and benchmark report contract" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: fixture parity and all Swift tests green; no real token counts claimed yet.

### Task 7: [Windows] Estimator v2 and identical report math/rendering

**Depends on:** 1,3; WP1 metrics and WP8 interface merged. **Parallel with:** 2,4,5,6. **Files:** Task 7 row only.

**Interfaces — Consumes:** `IContextTokenEstimator`, `EvalMetrics.Recall/Aggregate`, shared fixture envelopes. **Produces:** all C# declarations in Task 6; Swift counterparts there define exact parity. `TokenEstimatorV2`/calibration under `AINotebook.Core.Rag`, report/math/error under `AINotebook.Core.Eval`.

- [ ] **Step 1: Red tests.**

```csharp
public sealed class TokenEstimatorV2Tests
{
    [Fact] public void SharedEstimates()
    {
        foreach(var c in SharedFixtures.Json("contracts/token-estimate-v2.json").GetProperty("cases").EnumerateArray())
        {
            if(!c.TryGetProperty("kind",out var k) || k.GetString()!="estimate") continue;
            string lang=c.GetProperty("language").GetString()!;
            var e=new TokenEstimatorV2("fixture-only",[new("fixture-only",lang,c.GetProperty("rateBp").GetInt32())]);
            Assert.Equal(c.GetProperty("expected").GetInt32(),e.Estimate(c.GetProperty("text").GetString()!,lang));
            Assert.Equal(2,e.Version);
        }
    }
    [Fact] public void HoldoutCannotFit() => Assert.Throws<BenchmarkException>(() =>
        TokenCalibration.Fit([new("a","fixture-only","cs","holdout",3,2)]));
}
public sealed class BenchmarkReportTests
{
    [Fact] public void SharedReports()
    {
        var options=new JsonSerializerOptions { PropertyNamingPolicy=JsonNamingPolicy.CamelCase };
        foreach(var c in SharedFixtures.Json("contracts/benchmark-report-v1.json").GetProperty("cases").EnumerateArray())
        {
            if(!c.TryGetProperty("kind",out var k) || k.GetString()!="report") continue;
            var r=c.GetProperty("input").Deserialize<BenchmarkReportV1>(options)!;
            if(c.TryGetProperty("error",out _)) { Assert.Throws<BenchmarkException>(r.Validate); continue; }
            r.Validate();
            using var actual=JsonDocument.Parse(r.JsonBytes());
            Assert.True(JsonElement.DeepEquals(c.GetProperty("expectedJson"),actual.RootElement));
            Assert.Equal(c.GetProperty("expectedMarkdown").GetString(),r.Markdown());
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~TokenEstimatorV2Tests|FullyQualifiedName~BenchmarkReportTests'` → **FAIL: missing types**. Add all fit/holdout/error and percentile/gate cases from the same fixtures before implementing.

- [ ] **Step 2: Implement integer kernels and immutable rate table.**

```csharp
static long CeilDiv(long a,long b) => a/b + (a%b==0 ? 0 : 1);
public int Estimate(string text,string language)
{
    var rows=rates.Where(x=>x.Family==family).ToArray();
    int? rate=rows.FirstOrDefault(x=>x.Language==language)?.TokensPerScalarBp
        ?? (rows.Length==0 ? null : rows.Max(x=>x.TokensPerScalarBp));
    long n=text.EnumerateRunes().LongCount();
    if(n>5_000_000) return int.MaxValue;
    long basis=rate.HasValue ? CeilDiv(checked(n*rate.Value),10000) : Encoding.UTF8.GetByteCount(text);
    if(basis>int.MaxValue/2) return int.MaxValue;
    return (int)Math.Min(int.MaxValue,CeilDiv(checked(basis*11500),10000));
}
public static long Percentile(IReadOnlyList<long> samples,int bp)
{
    if(samples.Count==0 || bp<1 || bp>10000 || samples.Any(x=>x<0))
        throw new BenchmarkException("invalidSamples");
    return samples.Order().ElementAt(checked((int)(((long)samples.Count*bp+9999)/10000-1)));
}
public static long? TokensPerSecondMilli(long tokens,long elapsedUs)
{
    if(tokens<0 || elapsedUs<0 || tokens>long.MaxValue/1_000_000_000)
        throw new BenchmarkException("invalidSamples");
    return elapsedUs==0 ? null : tokens*1_000_000_000/elapsedUs;
}
```

Fit only train rows, require unique sample IDs, max rate<=1,000,000, and checked positive denominators. Unknown language uses family maximum; unknown family uses UTF-8 fallback, explicitly labeled in provenance. Implement exact nested report DTOs; use `[JsonPropertyName]` for embedded WP1 snake_case metrics, `JsonNamingPolicy.CamelCase` for outer fields. Markdown and all validation conditions from Task 6 are enumerated in shared golden inputs; compare all of them. No culture-dependent interpolation of percentages. Copy rate lists on construction to prevent caller mutation.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~TokenEstimatorV2Tests|FullyQualifiedName~BenchmarkReportTests'
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/TokenEstimatorV2.cs windows/src/AINotebook.Core/Rag/TokenCalibration.cs windows/src/AINotebook.Core/Eval/BenchmarkReport.cs windows/tests/AINotebook.Core.Tests/Rag/TokenEstimatorV2Tests.cs windows/tests/AINotebook.Core.Tests/Eval/BenchmarkReportTests.cs
git commit -m "feat(win-core): token calibration v2 and deterministic benchmark reports" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: every shared golden passes and full .NET Core suite green.

### Task 8a: [Swift] Stage complete generations through purpose-aware sessions

**Depends on:** 4; WP3 Tasks 8/10 and WP5 Task 10 merged. **Parallel with:** 9a,6,7. **Files:** `Sources/AINotebookCore/EmbeddingGenerationBuilder.swift`, `Tests/AINotebookCoreTests/EmbeddingGenerationBuilderTests.swift` only. This reusable Core component contains no eval types. Current chunk identity/text are `SourceChunk.swift:4–13`; WP3 appends revision/span fields and changes `NotebookStore+Sources.swift:102` to published-only reads (WP3 plan:1344–1377). Do not edit those owners.

**Interfaces — Consumes:** WP3 `sourcesIncludingShadow(notebookId:) throws -> [Source]`, `chunks(sourceId:) throws -> [SourceChunk]`, `manifest(generationId:) throws -> [ManifestEntry]`, create/set/retire generation methods; Task 4 `ProviderEmbeddingSession.embedDocuments(inputs:) async throws -> [[Float]]`. C# twins `SourcesIncludingShadow(long)`, `Chunks(long)`, `Manifest(long)`, `EmbedDocumentsAsync(IReadOnlyList<string>,CancellationToken)`.

**Produces:**

```swift
public struct EmbeddingGenerationError: Error, Equatable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
}
@MainActor public enum EmbeddingGenerationBuilder {
    public static func stage(store: NotebookStore, notebookId: Int64,
        identity: GenerationIdentity, session: ProviderEmbeddingSession,
        existingGeneration: IndexGeneration? = nil, reuseActive: Bool = false,
        now: @escaping @Sendable () -> Int64) async throws -> IndexGeneration
    // Internal injection seam, callable by @testable tests only.
    static func stage(store: NotebookStore, notebookId: Int64, identity: GenerationIdentity,
        now: @escaping @Sendable () -> Int64,
        embedDocuments: ([String]) async throws -> [[Float]],
        existingGeneration: IndexGeneration? = nil, reuseActive: Bool = false) async throws -> IndexGeneration
}
```

```csharp
// Task 9a produces this exact peer, in AINotebook.Core.Rag.
public sealed class EmbeddingGenerationException(string code) : Exception(code) { public string Code { get; } = code; }
public static class EmbeddingGenerationBuilder {
    public static Task<IndexGeneration> StageAsync(NotebookStore store,long notebookId,
        GenerationIdentity identity,ProviderEmbeddingSession session,Func<long> now,
        IndexGeneration? existingGeneration=null,bool reuseActive=false,CancellationToken ct=default);
    internal static Task<IndexGeneration> StageAsync(NotebookStore store,long notebookId,
        GenerationIdentity identity,Func<long> now,
        Func<IReadOnlyList<string>,CancellationToken,Task<float[][]>> embedDocuments,
        IndexGeneration? existingGeneration=null,bool reuseActive=false,CancellationToken ct=default);
}
```

The optional existingGeneration must be building with the same identity/notebook. It lets a background worker retain its own durable job fence. `reuseActive` defaults false for benchmark/explicit rebuild; ordinary ingestion passes true, copies only exact-identity unchanged source/revision vectors, and re-embeds only pending rows. Add a test updating one of two published sources: unchanged source emits0 requests and retains vector bytes, changed source emits its new chunk count; differing format/dims emits all requests.

Staging never activates. The benchmark activates explicitly after success. Settings can stage all notebooks before its own atomic activation. No existing vector is deleted. On error stage retires only a generation it created; a caller-owned existingGeneration is left for the worker's fence-validated failure/retirement operation. Never retire a generation after losing a lease that another worker could now own. A source whose extraction is newer than its published revision blocks this foreground rebuild with `EmbeddingGenerationError(code:"refreshPending")`; activation cannot truthfully mark that source current. Sources without any extracted revision remain absent from the manifest as prescribed by WP3.

- [ ] **Step 1: Add this failing real-store regression.**

```swift
import XCTest
@testable import AINotebookCore

@MainActor final class EmbeddingGenerationBuilderTests: XCTestCase {
    func testStagingDoesNotActivateAndFailurePreservesActive() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try store.createNotebook(name: "benchmark")
        let notebookId = try XCTUnwrap(notebook.id)
        let source = try store.createSource(notebookId: notebookId, type: .text,
            title: "one", uri: nil, rawPath: nil)
        let sourceId = try XCTUnwrap(source.id)
        _ = try store.commitForegroundRevision(sourceId: sourceId,
            draft: RevisionDraft(contentHash: "hash", canonicalText: "needle", textFormatVersion: 1, chunkerVersion: 2),
            chunks: ScalarChunker.chunk("needle"), now: 0, leaseToken: "fixture-extract")
        let identity = GenerationIdentity(providerId: "fixture", endpointRevision: "fixture",
            model: "m", modelDigest: nil, dims: 2, normalization: "l2",
            queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        let first = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId,
            identity: identity, now: { 1 }, embedDocuments: { inputs in
                XCTAssertEqual(inputs, ["needle"]); return [[1,0]]
            })
        XCTAssertNil(try store.activeGeneration(notebookId: notebookId))
        XCTAssertEqual(try store.manifest(generationId: first.id).map(\.state), ["done"])
        try store.activateGeneration(id: first.id, now: 2)
        do {
            _ = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId,
                identity: identity, now: { 3 }, embedDocuments: { _ in throw CancellationError() })
            XCTFail("cancelled stage returned")
        } catch is CancellationError { }
        XCTAssertEqual(try store.activeGeneration(notebookId: notebookId)?.id, first.id)
        XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["needle"])
    }
}
```

Run `swift test --filter EmbeddingGenerationBuilderTests` → **FAIL: missing builder**. Before implementation add fixture-driven methods for `failed-generation`, `cancel-build`, `dual-revisions`: wrong vector dimensions fail without activation; a refreshed revision after the embedding await causes `staleRevision`; an empty published revision creates a done manifest with zero vectors. Fixture assertions inspect generation states, active ID and unchanged source revision IDs, not only thrown errors.

- [ ] **Step 2: Implement staging with bounded memory and revision revalidation.** Public overload forwards `session.embedDocuments`. The internal kernel is:

```swift
let eligible = try store.sourcesIncludingShadow(notebookId: notebookId)
    .filter { $0.availability == "present" && $0.eligible && $0.currentRevision != nil }
for source in eligible {
    guard source.currentRevision == source.publishedRevisionId else {
        throw EmbeddingGenerationError(code: "refreshPending")
    }
}
if let supplied = existingGeneration {
    guard let stored = try store.generation(id:supplied.id),
          stored.notebookId == notebookId, stored.identity == identity, stored.state == "building" else {
        throw EmbeddingGenerationError(code:"invalidGeneration")
    }
}
let generation = try existingGeneration ?? store.createGeneration(notebookId: notebookId, identity: identity, now: now())
do {
    if reuseActive, let active = try store.activeGeneration(notebookId:notebookId), active.identity == identity {
        try store.dbQueue.write { db in
            try GenerationSQL.copyUnchangedVectors(db,from:active.id,to:generation.id,excludingChunkId:nil)
        }
    }
    let manifest = try store.manifest(generationId: generation.id).sorted { $0.sourceId < $1.sourceId }
    for entry in manifest where entry.state == "pending" {
        try Task.checkCancellation()
        let chunks = try store.chunks(sourceId: entry.sourceId)
        guard chunks.allSatisfy({ $0.revisionId == entry.revisionId }) else {
            throw EmbeddingGenerationError(code: "staleRevision")
        }
        for chunk in chunks {
            try Task.checkCancellation()
            let vectors = try await embedDocuments([chunk.text])
            guard let current = try store.source(id: entry.sourceId),
                  current.currentRevision == entry.revisionId,
                  current.publishedRevisionId == entry.revisionId,
                  current.availability == "present", current.eligible else {
                throw EmbeddingGenerationError(code: "staleRevision")
            }
            guard vectors.count == 1, let chunkId = chunk.id else {
                throw EmbeddingGenerationError(code: "invalidEmbedding")
            }
            try store.storeGenerationEmbedding(generationId: generation.id, chunkId: chunkId,
                vector: EmbeddingVector(values: vectors[0]))
        }
        try Task.checkCancellation()
        guard let current = try store.source(id: entry.sourceId),
              current.currentRevision == entry.revisionId,
              current.publishedRevisionId == entry.revisionId else {
            throw EmbeddingGenerationError(code: "staleRevision")
        }
        try store.setManifest(generationId: generation.id,
            entries: [ManifestEntry(sourceId: entry.sourceId, revisionId: entry.revisionId, state: "done", reason: nil)])
    }
    return generation
} catch {
    // Caller-owned generations belong to a fenced worker; only it may retire them.
    if existingGeneration == nil { try? store.retireGeneration(id: generation.id) }
    throw error
}
```

Snapshot one source's chunk array at a time. Use the canonical `chunk.text`, not mutable enrichment `embeddingText` (`SourceChunk.swift:35`) because the profile format identity presently describes no enrichment policy. Validate the session's entire captured modern identity against the requested identity before creating the generation: providerId, endpointRevision, model, modelDigest, dims, normalization, queryFormatVersion, docFormatVersion and chunkerVersion all equal. A nil/legacy identity cannot stage a modern profile. A mismatched ctx/digest/dimensions fixture asserts zero requests and no generation created; storageKey/endpoint alone are insufficient. Store enforces finite/nonzero/dimension checks; cancellation is checked before every provider call/write. A changed corpus fails staging; caller may retry later with a fresh snapshot. No endless automatic retry or unsafe activation follows a stale result.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter EmbeddingGenerationBuilderTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/EmbeddingGenerationBuilder.swift Tests/AINotebookCoreTests/EmbeddingGenerationBuilderTests.swift
git commit -m "feat(core): stage complete embedding generations without changing active indexes" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: focused regression plus all shared build cases pass; both full suites zero failures/skips.

### Task 9a: [Windows] Stage complete generations with cancellation parity

**Depends on:** 5; WP3 Tasks 9/11 merged. **Parallel with:** 8a,6,7. **Files:** `windows/src/AINotebook.Core/Rag/EmbeddingGenerationBuilder.cs`, `windows/tests/AINotebook.Core.Tests/Rag/EmbeddingGenerationBuilderTests.cs` only.

**Interfaces — Consumes:** WP3 generation/revision/store APIs, Task 5 captured document-purpose session. **Produces:** Task 8a's exact C# signatures, with its Swift signatures as the parity boundary. All store calls are existing gated methods (`Storage/NotebookStore.cs:35–40`, `NotebookStore.Sources.cs:55,137`); the optional unchanged-vector copy alone accesses Connection inside `lock(store.Gate)` and a transaction; no gate spans an await.

- [ ] **Step 1: Add the failing real-store test and shared fixture cases.**

```csharp
using AINotebook.Core.Eval;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

public sealed class EmbeddingGenerationBuilderTests
{
    [Fact] public async Task StagingDoesNotActivateAndFailurePreservesActive()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey:null);
        long notebookId=store.CreateNotebook("benchmark").Id!.Value;
        long sourceId=store.CreateSource(notebookId,SourceType.Text,"one",null,null).Id!.Value;
        store.CommitForegroundRevision(sourceId,new RevisionDraft("hash","needle",1,2),
            ScalarChunker.Chunk("needle"),0,"fixture-extract");
        var identity=new GenerationIdentity("fixture","fixture","m",null,2,"l2","1","1","2");
        var first=await EmbeddingGenerationBuilder.StageAsync(store,notebookId,identity,()=>1,
            (inputs,ct)=> { Assert.Equal(new[]{"needle"},inputs); return Task.FromResult(new[]{new float[]{1,0}}); });
        Assert.Null(store.ActiveGeneration(notebookId));
        Assert.Equal(new[]{"done"},store.Manifest(first.Id).Select(x=>x.State));
        store.ActivateGeneration(first.Id,2);
        await Assert.ThrowsAsync<OperationCanceledException>(()=>EmbeddingGenerationBuilder.StageAsync(
            store,notebookId,identity,()=>3,(inputs,ct)=>throw new OperationCanceledException()));
        Assert.Equal(first.Id,store.ActiveGeneration(notebookId)!.Id);
        Assert.Equal(new[]{"needle"},store.Chunks(sourceId).Select(x=>x.Text));
    }
}
```

Import `AINotebook.Core.Ingestion` for ScalarChunker after the WP3 handoff. Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EmbeddingGenerationBuilderTests` → **FAIL: missing builder**. Add theory cases for cancel-build, failed-generation, refreshed revision and empty publication from `benchmark-run-v1`; use barriers to mutate after the await begins, no sleep.

- [ ] **Step 2: Implement the complete C# staging kernel.**

```csharp
foreach(var source in store.SourcesIncludingShadow(notebookId)
    .Where(x=>x.Availability=="present" && x.Eligible && x.CurrentRevision is not null))
    if(source.CurrentRevision!=source.PublishedRevisionId) throw new EmbeddingGenerationException("refreshPending");
if(existingGeneration is not null)
{
    var stored=store.Generation(existingGeneration.Id);
    if(stored is null || stored.NotebookId!=notebookId || stored.Identity!=identity || stored.State!="building")
        throw new EmbeddingGenerationException("invalidGeneration");
}
var generation=existingGeneration ?? store.CreateGeneration(notebookId,identity,now());
try
{
    if(reuseActive && store.ActiveGeneration(notebookId) is { } active && active.Identity==identity)
    {
        lock(store.Gate)
        {
            using var tx=store.Connection.BeginTransaction();
            GenerationSQL.CopyUnchangedVectors(store.Connection,tx,active.Id,generation.Id,null);
            tx.Commit();
        }
    }
    foreach(var entry in store.Manifest(generation.Id).OrderBy(x=>x.SourceId).Where(x=>x.State=="pending"))
    {
        ct.ThrowIfCancellationRequested();
        var chunks=store.Chunks(entry.SourceId);
        if(chunks.Any(x=>x.RevisionId!=entry.RevisionId)) throw new EmbeddingGenerationException("staleRevision");
        foreach(var chunk in chunks)
        {
            ct.ThrowIfCancellationRequested();
            var vectors=await embedDocuments(new[]{chunk.Text},ct);
            ct.ThrowIfCancellationRequested();
            var current=store.Source(entry.SourceId);
            if(current is null || current.CurrentRevision!=entry.RevisionId
                || current.PublishedRevisionId!=entry.RevisionId || current.Availability!="present" || !current.Eligible)
                throw new EmbeddingGenerationException("staleRevision");
            if(vectors.Length!=1 || chunk.Id is not long id) throw new EmbeddingGenerationException("invalidEmbedding");
            store.StoreGenerationEmbedding(generation.Id,id,new EmbeddingVector(vectors[0]));
        }
        ct.ThrowIfCancellationRequested();
        var latest=store.Source(entry.SourceId);
        if(latest?.CurrentRevision!=entry.RevisionId || latest.PublishedRevisionId!=entry.RevisionId)
            throw new EmbeddingGenerationException("staleRevision");
        store.SetManifest(generation.Id,new[]{new ManifestEntry(entry.SourceId,entry.RevisionId,"done",null)});
    }
    return generation;
}
catch
{
    if(existingGeneration is null)
        try { store.RetireGeneration(generation.Id); } catch { /* Preserve original stage failure. */ }
    throw;
}
```

Public overload validates captured storage key and endpoint, then delegates `session.EmbedDocumentsAsync`. Stored raw chunk text matches the frozen document format policy. No App reference, platform identity API or implicit model selection. The optional `reuseActive` copy is the only direct connection operation and remains under the existing store gate.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EmbeddingGenerationBuilderTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Rag/EmbeddingGenerationBuilder.cs windows/tests/AINotebook.Core.Tests/Rag/EmbeddingGenerationBuilderTests.cs
git commit -m "feat(win-core): stage complete generations while preserving active indexes" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: shared build cases and full suites green, zero failures/skips.

### Task 8b: [Swift] Measure phases, process memory and chat-token calibration

**Depends on:** 4,6; WP5 Task 15 merged. **Parallel with:** 8a,9a,9b. **Files:** `Sources/AINotebookCore/BenchmarkMeasurements.swift`, `Sources/AINotebookCore/BenchmarkTelemetry.swift`, `Tests/AINotebookCoreTests/BenchmarkMeasurementsTests.swift`, `Tests/AINotebookCoreTests/BenchmarkTelemetryTests.swift` only. These files contain callbacks and measurement adapters; CLI and corpus orchestration remain Task 8c.

**Interfaces — Consumes:** Task 4 `ChatTokenObservation`, `EmbeddedInput` and per-run strict transport telemetry; Task 6 `TokenSample`, `TokenCalibration.fit/undercounts`, `BenchmarkMath`; WP5 `RetrievalPerformance.measure` (plan:2100–2109), whose timer excludes embedding from warm retrieval. C# consumes the corresponding Task 5/7 methods and `RetrievalPerformance.MeasureAsync`.

**Produces:** declare all structs Codable/Sendable with public initializers in Swift; C# records have PascalCase properties, identical JSON through camelCase serialization.

```swift
// Consumes Task6 report-owned type; do not redeclare it in this task.
public struct BenchmarkTimingSample: Codable, Equatable, Sendable {
    public let queryId: Int, embeddingUs: Int64, retrievalUs: Int64, hydrationUs: Int64, endToEndUs: Int64
}
public struct BenchmarkPhaseMeasurement: Sendable {
    public let coldCacheLoadUs: Int64?
    public let samples: [BenchmarkTimingSample]
    public let completedWrites: Int, overlapUs: Int64
}
public struct CalibrationRequest: Sendable {
    public let id: String, family: String, language: String, split: String, kind: String
    public let text: String, messages: [ChatTurn]
}
public struct CalibrationObservation: Codable, Sendable {
    public let sample: TokenSample
    public let kind: String, textHash: String, method: String
    public let modelDigest: String, tokenizerRevision: String?, assetsSha256: String?
}
@MainActor public enum BenchmarkMeasurements {
    public static func run(queries: Int, warmup: Int, concurrent: Bool,
        nowUs: () -> Int64, coldLoad: () async throws -> Int64?,
        runQuery: (Int) async throws -> BenchmarkTimingSample,
        writeBatch: @escaping @MainActor (Int) async throws -> Void) async throws -> BenchmarkPhaseMeasurement
    public static func calibrate(requests: [CalibrationRequest], modelDigest: String,
        observe: (CalibrationRequest) async throws -> ChatTokenObservation) async throws -> [CalibrationObservation]
}
public struct ProcessMemorySample: Equatable, Sendable {
    public let atUs: Int64, runnerBytes: Int64, serverTreeBytes: Int64
}
public struct ProcessMemoryPeaks: Equatable, Sendable {
    public let runnerBytes: Int64, serverBytes: Int64, combinedBytes: Int64
}
public enum BenchmarkTelemetry {
    public static func peaks(_ samples: [ProcessMemorySample]) throws -> ProcessMemoryPeaks
    public static func sampleProcesses(serverRootPid: Int32) throws -> ProcessMemorySample
}
```

```csharp
// Consumes Task7 report-owned type; do not redeclare it in this task.
public sealed record BenchmarkTimingSample(int QueryId,long EmbeddingUs,long RetrievalUs,long HydrationUs,long EndToEndUs);
public sealed record BenchmarkPhaseMeasurement(long? ColdCacheLoadUs,IReadOnlyList<BenchmarkTimingSample> Samples,int CompletedWrites,long OverlapUs);
public sealed record CalibrationRequest(string Id,string Family,string Language,string Split,string Kind,string Text,IReadOnlyList<ChatTurn> Messages);
public sealed record CalibrationObservation(TokenSample Sample,string Kind,string TextHash,string Method,string ModelDigest,string? TokenizerRevision,string? AssetsSha256);
public sealed record ProcessMemorySample(long AtUs,long RunnerBytes,long ServerTreeBytes);
public sealed record ProcessMemoryPeaks(long RunnerBytes,long ServerBytes,long CombinedBytes);
public static Task<BenchmarkPhaseMeasurement> BenchmarkMeasurements.RunAsync(int queries,int warmup,bool concurrent,
    Func<long> nowUs,Func<Task<long?>> coldLoad,Func<int,Task<BenchmarkTimingSample>> runQuery,
    Func<int,CancellationToken,Task> writeBatch,CancellationToken ct=default);
public static Task<IReadOnlyList<CalibrationObservation>> BenchmarkMeasurements.CalibrateAsync(
    IReadOnlyList<CalibrationRequest> requests,string modelDigest,
    Func<CalibrationRequest,CancellationToken,Task<ChatTokenObservation>> observe,CancellationToken ct=default);
public static ProcessMemoryPeaks BenchmarkTelemetry.Peaks(IReadOnlyList<ProcessMemorySample> samples);
public static ProcessMemorySample BenchmarkTelemetry.SampleProcesses(int serverRootPid);
```

- [ ] **Step 1: Add failing deterministic timing and memory tests.**

```swift
import XCTest
@testable import AINotebookCore

@MainActor final class BenchmarkMeasurementsTests: XCTestCase {
    func testColdWarmupAndMeasuredQueriesAreSeparate() async throws {
        var calls: [(Int,Bool)] = [], ticks: [Int64] = [200,900]
        let phase = try await BenchmarkMeasurements.run(queries: 3, warmup: 2, concurrent: false,
            nowUs: { ticks.removeFirst() }, coldLoad: { calls.append((0,true)); return 100 }, runQuery: { i in
                calls.append((i,false))
                return BenchmarkTimingSample(queryId:i,embeddingUs:1000,retrievalUs:10,hydrationUs:3,endToEndUs:1013)
            }, writeBatch: { _ in XCTFail("unexpected ingestion") })
        XCTAssertEqual(calls.map(\.0), [0,0,1,0,1,2])
        XCTAssertEqual(calls.map(\.1), [true,false,false,false,false,false])
        XCTAssertEqual(phase.coldCacheLoadUs,100)
        XCTAssertEqual(phase.samples.map(\.retrievalUs),[10,10,10])
        XCTAssertEqual(phase.completedWrites,0)
        XCTAssertEqual(phase.overlapUs,0)
    }
}
final class BenchmarkTelemetryTests: XCTestCase {
    func testCombinedPeakIsNotSumOfIndependentPeaks() throws {
        let peaks = try BenchmarkTelemetry.peaks([
            ProcessMemorySample(atUs:0,runnerBytes:80,serverTreeBytes:10),
            ProcessMemorySample(atUs:1,runnerBytes:20,serverTreeBytes:70)])
        XCTAssertEqual(peaks.runnerBytes,80); XCTAssertEqual(peaks.serverBytes,70)
        XCTAssertEqual(peaks.combinedBytes,90)
    }
}
```

Run `swift test --filter 'BenchmarkMeasurementsTests|BenchmarkTelemetryTests'` → **FAIL: missing types**. Add shared calibration observations with chat counts that deliberately differ from embedding counts, asserted rates only from chat samples. Test missing counts → `tokenCountUnavailable`, negative counts → `invalidTokenCount`, calibration cancellation propagates, full prompt rows never enter training, and duplicate sample IDs fail. Add `overlap-required`: a writer that completes only before measured queries causes `insufficientIngestionOverlap`; a barrier-controlled writer completing during two measured queries passes. No sleep-based timing assertions.

- [ ] **Step 2: Implement phase order and calibration.** Use one cold callback, then warmups, then measured callbacks. The `coldLoad` callback creates a new application cache and measures only `cache.acquire(fill:)` / `AcquireAsync(fill:)`, filling pages through the pinned reader and closing its lease; it never flushes OS caches. It performs no ranking, embedding or hydration. If the candidate matrix cannot be admitted to512MiB, record no cache-load value (null) and cacheMode=streamed; the explicit nullable return type preserves that distinction. For nonconcurrent runs the complete coordinator kernel is:

```swift
guard queries > 0, warmup >= 0 else { throw BenchmarkError(code:"invalidSamples") }
let coldElapsed = try await coldLoad()
guard coldElapsed.map({ $0 >= 0 }) ?? true else { throw BenchmarkError(code:"invalidSamples") }
for i in 0..<warmup { try Task.checkCancellation(); _ = try await runQuery(i) }
let measuredStart = nowUs()
var samples: [BenchmarkTimingSample] = []
for i in 0..<queries { try Task.checkCancellation(); samples.append(try await runQuery(i)) }
let measuredEnd = nowUs()
guard measuredStart <= measuredEnd else {
    throw BenchmarkError(code:"invalidSamples")
}
return BenchmarkPhaseMeasurement(coldCacheLoadUs:coldElapsed,samples:samples,completedWrites:0,overlapUs:0)
```

For concurrent mode, start a child task after warmup. It repeatedly calls `writeBatch(batchIndex)` until cancellation, records each completed transaction's monotonic time, and yields between batches. Run the same measured loop while that child is active. Always cancel and await the child on success/error/cancellation; propagate non-cancellation writer errors. Count only completion timestamps in `[measuredStart,measuredEnd]`, require at least two, and set overlapUs=`lastCompletion-firstCompletion` >0. This guarantees writes overlapped the measured phase; unobserved or zero overlap marks the row incomplete. The writer uses a separate notebook in the same DB, bounded batches of 100 revision chunks, real publication and generation writes, so it exercises SQL/cache contention without changing the measured 100K/200K generation.

Calibration validates and observes each request exactly once, then maps it with:

```swift
let observed = try await observe(request)
guard let count = observed.promptTokens else { throw BenchmarkError(code:"tokenCountUnavailable") }
guard count >= 0 else { throw BenchmarkError(code:"invalidTokenCount") }
let sample = TokenSample(id:request.id,family:request.family,language:request.language,
    split:request.split,scalars:request.text.unicodeScalars.count,tokens:count)
let row = CalibrationObservation(sample:sample,kind:request.kind,
    textHash:EvalCorpus.sha256(Data(request.text.utf8)),method:request.kind == "body" ? "ollama-raw-prompt" : "ollama-chat-prompt",
    modelDigest:modelDigest,tokenizerRevision:nil,assetsSha256:nil)
```

Use `body` for raw body observations through Task4 `observeRaw(model:text:options:)` with raw:true and num_predict1; do not subtract an empty prompt. `prompt` rows contain complete WP8-rendered requests sent through `observeChat` and validate the estimator's total message+section estimate; they never train the body rate. Follow the frozen shared sample-partition protocol exactly (documents sorted within language, indices mod4:0/1/2train,3holdout; nonoverlapping windows up to256 plus whole documents up to1024). Split by document ID before producing prefixes, so no document contributes both training and holdout text. Only `kind=body,split=train` enters `TokenCalibration.fit`; evaluate body holdout and full prompts separately. Missing native counts may use the exact model's documented local tokenizer with recorded immutable assets; full-chat fallback requires its documented chat template, never bare text encode. Unavailable template/count makes that observation unmeasured and the calibration report incomplete.

- [ ] **Step 3: Implement RSS sampling with injected enumeration.** On macOS invoke `/bin/ps -axo pid=,ppid=,rss=` using `Process` and argument arrays every100ms plus start/end samples. Parse three unsigned invariant integers per row, RSS KiB×1024 checked; recursively include the supplied Ollama root and its descendants, deduplicate PIDs, and sum their current RSS. The runner is the current process only, excluded from the server set. A missing root or inaccessible enumeration yields unavailable RSS and an incomplete release report. On Windows Task 9b uses Toolhelp process parent IDs plus `Process.WorkingSet64`; all OS calls sit behind injectable enumeration. PID is process-local run input, not a persisted identity. `peaks` rejects empty/negative/decreasing-time samples and returns max runner, max server, and max simultaneous sum, with checked arithmetic. Parse process-list fixtures, including parent cycles/reused/unavailable PID, in unit tests; do not invoke ps/native APIs in CI tests. No networking is added.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter 'BenchmarkMeasurementsTests|BenchmarkTelemetryTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/BenchmarkMeasurements.swift Sources/AINotebookCore/BenchmarkTelemetry.swift Tests/AINotebookCoreTests/BenchmarkMeasurementsTests.swift Tests/AINotebookCoreTests/BenchmarkTelemetryTests.swift
git commit -m "feat(eval): measure benchmark phases memory and real chat token counts" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: deterministic phase/calibration/RSS tests and both complete suites green; no Ollama process or model needed.

### Task 9b: [Windows] Matching phase, calibration and process-memory measurements

**Depends on:** 5,7; WP5 Task 16 merged. **Parallel with:** 8a,9a,8b. **Files:** `windows/src/AINotebook.Core/Eval/BenchmarkMeasurements.cs`, `windows/src/AINotebook.Core/Eval/BenchmarkTelemetry.cs`, `windows/tests/AINotebook.Core.Tests/Eval/BenchmarkMeasurementsTests.cs`, `windows/tests/AINotebook.Core.Tests/Eval/BenchmarkTelemetryTests.cs` only.

**Interfaces — Consumes:** `RetrievalPerformance.MeasureAsync`, Task 5 observation/strict telemetry, Task 7 math/calibration. **Produces:** all Task 8b C# declarations exactly; Task 8b contains the explicit Swift parity interfaces.

- [ ] **Step 1: Add failing tests.**

```csharp
using AINotebook.Core.Eval;
using Xunit;
public sealed class BenchmarkMeasurementsTests
{
    [Fact] public async Task ColdWarmupAndMeasuredQueriesAreSeparate()
    {
        var calls=new List<(int,bool)>(); var ticks=new Queue<long>([200,900]);
        var phase=await BenchmarkMeasurements.RunAsync(3,2,false,()=>ticks.Dequeue(),()=> { calls.Add((0,true)); return Task.FromResult<long?>(100); },i=> {
            calls.Add((i,false)); return Task.FromResult(new BenchmarkTimingSample(i,1000,10,3,1013));
        },(i,ct)=>throw new InvalidOperationException("unexpected ingestion"));
        Assert.Equal(new[]{0,0,1,0,1,2},calls.Select(x=>x.Item1));
        Assert.Equal(new[]{true,false,false,false,false,false},calls.Select(x=>x.Item2));
        Assert.Equal(100,phase.ColdCacheLoadUs);
        Assert.Equal(new long[]{10,10,10},phase.Samples.Select(x=>x.RetrievalUs));
        Assert.Equal(0,phase.CompletedWrites); Assert.Equal(0,phase.OverlapUs);
    }
}
public sealed class BenchmarkTelemetryTests
{
    [Fact] public void CombinedPeakIsNotSumOfIndependentPeaks()
    {
        var p=BenchmarkTelemetry.Peaks([new(0,80,10),new(1,20,70)]);
        Assert.Equal(80,p.RunnerBytes); Assert.Equal(70,p.ServerBytes); Assert.Equal(90,p.CombinedBytes);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~BenchmarkMeasurementsTests|FullyQualifiedName~BenchmarkTelemetryTests'` → **FAIL: missing types**. Theory-run every shared phase, overlap, process enumeration and calibration observation case; inject `TaskCompletionSource` barriers with `RunContinuationsAsynchronously` for overlap/cancellation tests. Assert no unobserved writer task survives a canceled query.

- [ ] **Step 2: Implement precise timing and observed-count mapping.**

```csharp
if(queries<=0 || warmup<0) throw new BenchmarkException("invalidSamples");
long? coldElapsed=await coldLoad();
if(coldElapsed<0) throw new BenchmarkException("invalidSamples");
for(int i=0;i<warmup;i++) { ct.ThrowIfCancellationRequested(); await runQuery(i); }
long measuredStart=nowUs(); var samples=new List<BenchmarkTimingSample>();
for(int i=0;i<queries;i++) { ct.ThrowIfCancellationRequested(); samples.Add(await runQuery(i)); }
long measuredEnd=nowUs();
if(measuredStart>measuredEnd)
    throw new BenchmarkException("invalidSamples");
return new BenchmarkPhaseMeasurement(coldElapsed,samples,0,0);
```

Use a linked CancellationTokenSource for the concurrent writer, `ConcurrentQueue<long>` for completion times, and `finally { writerCts.Cancel(); await writer; }` with only the expected writer cancellation suppressed. Only two completions inside measured boundaries and positive overlap satisfy the row. Build one measured generation and write another notebook in the same DB. All writes use gated store APIs. `Stopwatch.GetTimestamp` is converted to integer microseconds using quotient/remainder, avoiding overflow: `ticks/frequency*1000000 + (ticks%frequency)*1000000/frequency` with checked bounds. Calibration reads actual `PromptTokens`, counts .NET runes, uses `EvalCorpus.Sha256(Encoding.UTF8.GetBytes(text))`, records method/digest and leaves body and full-prompt observations distinct. Derive training rates only from train body rows; validate held-out body/full-prompt rows independently.

- [ ] **Step 3: Implement platform memory collection behind the fixture-tested parser/aggregator.** Runtime Windows uses Toolhelp32Snapshot/Process32FirstW/Process32NextW to materialize `(pid,parentPid)` once per sample, closes its SafeHandle, then `Process.GetProcessById(pid).WorkingSet64` for runner and the Ollama root subtree. A vanished child is skipped only if enumeration confirms it exited; an inaccessible live worker invalidates that sample. On non-Windows portable runner use the macOS ps adapter so the .NET tool remains runnable in this checkout; guard P/Invoke with `OperatingSystem.IsWindows()`. No Windows App SDK or Package APIs. Unit tests inject process rows and RSS values and never invoke platform collectors.

- [ ] **Step 4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~BenchmarkMeasurementsTests|FullyQualifiedName~BenchmarkTelemetryTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Eval/BenchmarkMeasurements.cs windows/src/AINotebook.Core/Eval/BenchmarkTelemetry.cs windows/tests/AINotebook.Core.Tests/Eval/BenchmarkMeasurementsTests.cs windows/tests/AINotebook.Core.Tests/Eval/BenchmarkTelemetryTests.cs
git commit -m "feat(win-eval): measure phases token observations and process tree RSS" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: fixture cases plus both full suites green; platform memory collectors are manual live-run checks.

### Task 8c: [Swift] Orchestrate production retrieval/packing and expose benchmark CLI

**Depends on:** 8a,8b,6,15; WP1 Task 6, WP5 Task 12/15, WP8 pure builder merged. **Parallel with:** 9c. **Files:** `Sources/AINotebookCore/BenchmarkOptions.swift`, `Sources/AINotebookCore/BenchmarkRunner.swift`, `Tests/AINotebookCoreTests/BenchmarkRunnerTests.swift`, `Sources/RetrievalEvalRunner/main.swift` only. Existing dispatch begins `main.swift:234`; WP1 inserts multilingual dispatch before it (WP1 plan:1283). This task inserts benchmark/calibration dispatch before WP1's branch and preserves both existing modes.

**Interfaces — Consumes:** WP1 `EvalRunner.load(root:)`, `EvalMetrics.measure(gold:lexical:fused:topK:includeVectors:packed:)`; Task 8a stage; Task 8b measurements; WP5 `ScopeResolver.resolve`, pinned retrieval, reader, hydrator, synthetic generator and cache; current `ContextPackBuilder.build(_:estimator:)` (`ContextPackBuilder.swift:7`), `ContextPackInput` (`ContextPackTypes.swift:214`), `PreparedContextRequest.citationMap/sourceRevisions` (`:362–372`), `Citation` (`ChatMessage.swift:24–43`). Exact C# twins appear in the prerequisite handoffs and Task 9c below. Do not call WP1's old temporary ingestion backend: its `eval-scalars-v1` identity does not represent production chunking.

**Produces:**

```swift
public struct BenchmarkOptions: Equatable, Sendable {
    public let command: String, mode: String, root: String, host: String
    public let profileIds: [String], chunkCounts: [Int]
    public let chatModel: String, calibration: String?, tokenizerRoot: String?
    public let queries: Int, warmup: Int, concurrent: String, seed: Int
    public let fetchK: Int, topK: Int, evidenceShareBp: Int, runtimeContext: Int, maxOutput: Int
    public let ollamaPid: Int32?, json: String, out: String
    public static func parse(_ args: [String]) throws -> BenchmarkOptions
}
public struct BenchmarkRevision: Sendable {
    public let sourceId: Int64, revisionId: Int64
    public let documentId: String, contentHash: String, text: String
    public let chunks: [ChunkReference]
}
public struct BenchmarkCitationAudit: Sendable {
    public let packed: [EvalSpan]
    public let snapshotsCorrect: Int, snapshotsTotal: Int
    public let answerMarkersCorrect: Int, answerMarkersTotal: Int
    public let answerGoldSupported: Int, answerMarkersJudged: Int
}
@MainActor public enum BenchmarkRunner {
    public static func run(options: BenchmarkOptions) async throws -> BenchmarkReportV1
    public static func calibrate(options: BenchmarkOptions) async throws -> TokenCalibrationReportV1
    public static func audit(citations: [Citation], answer: String, revisions: [BenchmarkRevision],
        gold: [EvalSpan]) throws -> BenchmarkCitationAudit
}
```

```csharp
public sealed record BenchmarkOptions(string Command,string Mode,string Root,string Host,
    IReadOnlyList<string> ProfileIds,IReadOnlyList<int> ChunkCounts,string ChatModel,
    string? Calibration,string? TokenizerRoot,int Queries,int Warmup,string Concurrent,int Seed,
    int FetchK,int TopK,int EvidenceShareBp,int RuntimeContext,int MaxOutput,int? OllamaPid,string Json,string Out)
{
    public static BenchmarkOptions Parse(IReadOnlyList<string> args);
}
public sealed record BenchmarkRevision(long SourceId,long RevisionId,string DocumentId,string ContentHash,string Text,IReadOnlyList<ChunkReference> Chunks);
public sealed record BenchmarkCitationAudit(IReadOnlyList<EvalSpan> Packed,int SnapshotsCorrect,int SnapshotsTotal,
    int AnswerMarkersCorrect,int AnswerMarkersTotal,int AnswerGoldSupported,int AnswerMarkersJudged);
public static Task<BenchmarkReportV1> BenchmarkRunner.RunAsync(BenchmarkOptions options,CancellationToken ct=default);
public static Task<TokenCalibrationReportV1> BenchmarkRunner.CalibrateAsync(BenchmarkOptions options,CancellationToken ct=default);
public static BenchmarkCitationAudit BenchmarkRunner.Audit(IReadOnlyList<Citation> citations,string answer,
    IReadOnlyList<BenchmarkRevision> revisions,IReadOnlyList<EvalSpan> gold);
```

`TokenCalibrationReportV1` is Task 1's calibration wire schema and Task 6's typed DTO. All public value types receive memberwise initializers. Parser accepts exactly one of `--benchmark` / `--calibrate`; `--root` defaults `eval/multilingual`; `--profiles all` expands catalog order; `--host http://127.0.0.1:11434`; `--chat-model llama3.2:3b`; `--mode live|fixture` defaults live; `--chunks 100000,200000`; `--queries 200`; `--warmup 20`; `--concurrent both|off|on` defaults both; `--seed 17`; `--fetch-k 32`; `--top-k 16`; `--evidence-share-bp 6000`; `--runtime-context 8192`; `--max-output 1024`. `--json FILE` and `--out FILE` are required output paths. `--calibration FILE` is required for live benchmark; `--ollama-pid N` required for live benchmark memory accounting; `--tokenizer-root DIR` is optional until native counts are unavailable. Calibration accepts `--embedding-counts all` to record candidate-token observations separately from chat-estimator training. Reject unknown/duplicate/missing flags, nondecimal/negative/overflow numbers, duplicate profile IDs/chunk counts, fetchK<topK, evidenceShareBp outside0…10000, maxOutput>=runtimeContext, equal output paths and contradictory modes before any provider/store operation. `--mode fixture` uses the deterministic transport described below and can use `--chunks 1000 --queries 3 --warmup 1`; its report can never qualify a release decision.

- [ ] **Step 1: Write failing CLI and citation tests.**

```swift
import XCTest
@testable import AINotebookCore

@MainActor final class BenchmarkRunnerTests: XCTestCase {
    func testParserRejectsRepeatedFlagsAndKeepsContractDefaults() throws {
        let options = try BenchmarkOptions.parse(["--benchmark","--mode","fixture","--json","a.json","--out","a.md"])
        XCTAssertEqual(options.topK,16); XCTAssertEqual(options.fetchK,32)
        XCTAssertEqual(options.chunkCounts,[100000,200000]); XCTAssertEqual(options.profileIds.count,7)
        XCTAssertThrowsError(try BenchmarkOptions.parse(["--benchmark","--mode","fixture",
            "--queries","200","--queries","1","--json","a","--out","b"]))
    }
    func testPackedRecallUsesExactRetainedSpanAndRevision() throws {
        let text="prefix gold", hash=EvalCorpus.sha256(Data(text.utf8))
        let revision=BenchmarkRevision(sourceId:1,revisionId:10,documentId:"d",contentHash:hash,text:text,chunks:[ChunkReference(chunkId:100,sourceId:1,revisionId:10,ord:0)])
        var citation=Citation(marker:1,chunkId:100,sourceId:1,snippet:"prefix")
        citation.revisionId=10; citation.text="prefix"
        citation.spans=[CitationSpan(start:0,end:6,pageFrom:nil,pageTo:nil)]; citation.chunkIds=[100]
        let gold=[EvalSpan(documentId:"d",contentHash:hash,start:7,end:11)]
        let audit=try BenchmarkRunner.audit(citations:[citation],answer:"Claim [1] [99]",revisions:[revision],gold:gold)
        XCTAssertEqual(audit.snapshotsCorrect,1); XCTAssertEqual(audit.answerMarkersCorrect,1)
        XCTAssertEqual(audit.answerMarkersTotal,2); XCTAssertEqual(audit.answerGoldSupported,0)
        XCTAssertEqual(EvalMetrics.recall(gold:gold,evidence:audit.packed).found,0)
        citation.revisionId=11
        let stale=try BenchmarkRunner.audit(citations:[citation],answer:"[1]",revisions:[revision],gold:gold)
        XCTAssertEqual(stale.snapshotsCorrect,0); XCTAssertTrue(stale.packed.isEmpty)
    }
}
```

Run `swift test --filter BenchmarkRunnerTests` → **FAIL: missing types**. Add fixture-driven `phase-order`, `zero-evidence`, `truncated-away-gold`, `empty-selection`, `overview`, `citation-wrong-revision`, `citation-unknown-marker`, `citation-wrong-chunk`, `cache-streamed` cases. The end-to-end fixture run loads the actual 44-document/144-query corpus, executes one profile at1000 synthetic chunks with3 measured queries and both concurrent modes, and asserts144 quality rows, seven-or-selected profile IDs, real packed metrics, no HTTP calls, no leaked pins and deterministic report bytes after fixed environment/timestamps. Assert empty selection makes0 embedding/chat calls and has0 citations. Shared phase trace is `inspect,ingest,quality,cold,warmup,measure,concurrent,verifyModels,report` for each candidate; loops include chunkCount in recorded phase events.

- [ ] **Step 2: Implement the exact production adapter sequence.**

1. Load corpus bytes once through `EvalRunner.load`, preserving its validation/hash. Create one private file-backed temporary DB per candidate, not the user's notebook DB. Create notebooks sorted by fixture notebookId; create virtual folders sorted by `(notebookId,folderId)` with a deterministic `FolderPathIdentity` returning `FolderIdentity(volumeId:"eval",components:["folder",String(fixtureFolderId)])`, no filesystem scan. Map fixture IDs to generated IDs explicitly. For each document sorted by documentId, create Source, attach folder+relative path, use `ScalarChunker.chunk` defaults2048/256, and `commitForegroundRevision` with exact canonical text/content hash, textFormat1/chunker2. Build language metadata from corpus labels for this controlled corpus. Retain a reverse `(sourceId,revisionId)->BenchmarkRevision` map. Empty documents publish an empty chunk set, preserving file counts.
2. Capture `/api/tags` model digest, `/api/show` metadata, normalized endpoint revision, effective input ceiling, exact query/document profile formats and output dims. Use Task4 `prepareEmbeddingProfile(providerId:profileId:observer:)` / `PrepareEmbeddingProfileAsync` once to obtain the exact identity and strict captured session, attach one per-candidate telemetry collector, start memory sampler, and call `EmbeddingGenerationBuilder.stage` for each notebook. Activate each complete candidate generation explicitly. Measure ingestion wall time from first document embedding through last vector/manifest commit; record actual service tokens separately from accepted leaf tokens, successful split leaves, rejected request count and peak process-tree RSS. A failed/canceled stage produces an incomplete row and leaves any prior generation intact.
3. Query every non-overview question using its mapped RetrievalScope, the captured session and WP5 production Retriever. One pinned pool exposes lexical/vector/fused branches. Map branch spans by each `ChunkReference.revisionId`, never source.currentRevision. Feed WP1 `EvalMetrics.measure` lexical and complete fused pools; topK truncation belongs to that scorer, candidate recall uses the full per-branch fetchK union. Hydrate direct references and ±1 published neighbours while retaining the pool. Build `PackPassage` from full `EvidencePassage.text`, exact spans, document language, metadata path/title/folder and candidate `rrfMicro`; do not use displaySnippet. Retain each stored ChunkReference in BenchmarkRevision.chunks for citation membership verification. Supply `truncationCandidates:[]` so WP8 computes real sentence boundaries/costs (`ContextPackRendering.swift:130–154`). Supply the pinned published revision map in ContextPackInput; own-revision direct hits remain distinct from newer neighbours.
4. Build `PackFile` for scoped metadata from `reader.metadata(snapshot)` and corpus descriptors; include every file in coverage and count only files with published chunks as candidates. Overview bypasses retrieval/embedding, selects first published chunk per scoped source, with no neighbours, then passes those passages to WP8 `mode:"overview"`; builder applies the actual folder/directory ordering. For answers use `mode:"answer"`, no history/external/user instructions, a fixed captured `PackModel` for `--chat-model`, explicit estimator v2 from the supplied exact-digest calibration, and options fetchK/topK. Construct explicit `RagRuntimeTuning(fetchK:options.fetchK,topK:options.topK,evidenceShareBp:options.evidenceShareBp)` and pass it to `ContextPackBuilder.build(_:estimator:tuning:)`; audit **its citationMap** for packed recall so truncation cannot retain excluded gold. Preserve sourceRevision pairs from the actual output array.
5. Send full prepared messages to Task4 `observeChat`, constructing each ChatTurn content by joining its ordered sections with `"\n\n"` (the production section transport mapping); do not regenerate the prompt independently. Score structural citation snapshot correctness and marker resolution against that immutable map. `answerGoldSupported` means marker resolves to evidence containing an annotated gold span, not that an LLM judge approved the statement. Keep semanticReview=`not_measured`. A query without markers has zero marker denominator, not perfect correctness. Empty selection has no provider call; overview has its own deterministic coverage audit and is excluded from positive-answer recall aggregation under WP1's denominator rule. Close pool/snapshot on success and every error before moving to the next question.
6. For each configured synthetic count, call WP5 `SyntheticRetrievalCorpus.populate` with candidate output dims and seed. Semantic measurements never use these one-hot vectors. Use query string `"needle\(i%97)"`; its actual query vector is produced through the candidate's captured strict query-purpose session inside the WP5 embedding callback. Synthetic vectors are only a workload for retrieval, and no semantic recall is claimed against them. For the cold adapter, call `VectorMatrixCache.acquire(key:rowCount:dims:epoch:fill:)` / `AcquireAsync` directly, paginate known-valid synthetic VectorRows with <=1024 rows and append into its allocated builder; time from entry through completed lease and close it. An admission refusal is null coldCacheLoadUs and streamed mode. Use separate cache instances for the cold call and shared warm loop; `VectorMatrixCache(budgetBytes:536870912)`. Capture ScopeResolver snapshot per query, call `RetrievalPerformance.measure` with an embedding callback calling the strict candidate session on the frozen query text, and production `searchEmbedded`, hydrate fused topK, then convert each returned millisecond duration to integer microseconds with nearest rounding, ties away from zero: Swift `Int64((ms*1000).rounded(.toNearestOrAwayFromZero))`, C# `checked((long)Math.Round(ms*1000,MidpointRounding.AwayFromZero))`; shared cases include0.5us/1.5us. Record app-cache cold retrieval/load separately, 20warmups then200measured queries. Report actual embedding, retrieval, hydration and total elapsed time independently. The gate uses only warm retrieval; end-to-end includes the real query embedding. Precomputed one-hot query vectors are reserved for the separate cached/streamed-ID equivalence diagnostic. Run a second row with concurrent publication in another notebook as Task8b defines. Add a diagnostic budget0 run to prove cached/streamed IDs agree; it is not the100K warm gate. Persist raw sample rows and cache statistics for independent percentile recomputation.
7. Reinspect digests/context limits after the candidate run; any change invalidates it. Aggregate WP1 metrics by language and caseType with identical denominators. Assemble Task6 report with raw timings, exact identities, model count provenance and memory scope. On cancellation cancel/await writer and sampler, close leases, retire unfinished private generations, remove private DB files, and return cancellation without a success artifact.

Fixture-mode transport returns a unit vector at `FNV1a32(formatted UTF8) mod nativeDims`, actual fake prompt count=`unicodeScalars.count`, no network, and fake chat answer `[1]` only when an evidence marker exists. FNV-1a32 starts at2166136261; for each UTF-8 byte set `hash=(hash XOR byte)*16777619` modulo2^32 (Swift wrapping `&*`, C# `unchecked`); shared case `abc` gives440920331. Its digest/environment/ticks are fixture-provided and its report is marked `mode:"fixture"`. It tests production integration without asserting semantic quality or hardware latency. Transport remains private to BenchmarkRunner and is selected only by explicit fixture mode; no application default can choose it.

- [ ] **Step 3: Implement citation audit with full scalar equality.** A valid benchmark snapshot must have a matching source/revision row, one retained modern span, its stored content hash, exact scalar-slice text, chunkIds all belonging to that source/revision in stored ordinal order, chunkId equal to first chunkIds item, and snippet equal to the first240text scalars; benchmark generations always use modern chunker2. Duplicate markers are invalid, as are wrong revisions, out-of-range spans and overlapping foreign source IDs. Use this kernel inside the per-citation loop; keep invalid entries in `snapshotsTotal` but omit them from packed evidence and marker lookup.

```swift
guard let revisionId=citation.revisionId,
      let revision=revisions.first(where: { $0.sourceId==citation.sourceId && $0.revisionId==revisionId }),
      citation.spans.count==1, let span=citation.spans.first,
      let text=citation.text else { continue }
let scalars=Array(revision.text.unicodeScalars)
guard span.start>=0, span.end>span.start, span.end<=scalars.count else { continue }
let expected=String(String.UnicodeScalarView(scalars[span.start..<span.end]))
guard expected.utf8.elementsEqual(text.utf8),
      EvalCorpus.sha256(Data(revision.text.utf8))==revision.contentHash else { continue }
let references=revision.chunks.filter { citation.chunkIds.contains($0.chunkId) }.sorted { ($0.ord,$0.chunkId)<($1.ord,$1.chunkId) }
guard !citation.chunkIds.isEmpty, Set(citation.chunkIds).count==citation.chunkIds.count,
      references.map(\.chunkId)==citation.chunkIds, citation.chunkId==citation.chunkIds.first,
      references.allSatisfy({ $0.sourceId==citation.sourceId && $0.revisionId==revisionId }),
      citation.snippet.unicodeScalars.elementsEqual(text.unicodeScalars.prefix(240)) else { continue }
let retained=EvalSpan(documentId:revision.documentId,contentHash:revision.contentHash,start:span.start,end:span.end)
packed.append(retained)
validMarkers[citation.marker]=retained
```

Use existing `CitationParser.markers(in:)` (`CitationParser.swift:7`) for answer occurrences, including duplicates. Each resolved marker increments answerMarkersCorrect; each marker whose retained span yields `EvalMetrics.recall(gold:evidence:).found>0` increments answerGoldSupported. Marker total counts all parsed positive markers, including unknown ones; judged denominator is markersTotal only for positive-gold answer rows, otherwise0. The zero-evidence fixture yields empty packed/citations with a measured recall of0 when gold exists.

- [ ] **Step 4: Add calibration dispatch and CLI writes.** `--calibrate` implements the shared calibration sample-selection protocol: raw body observations use Task4 `observeRaw` and complete prepared prompt observations use `observeChat`; the exact chat model manifest digest identifies the family. Record candidate embedding count observations separately. Fit only train bodies, require held-out/full-prompt validation, serialize Task6 calibration report and Markdown. Do not overwrite shipped fixtures from the runner; Task12 reviews and promotes them.

CLI parses first, then calls `run` or `calibrate`, validates the returned report, writes each output to a sibling temporary file, and atomically replaces its requested destination. Return0 complete; return1 incomplete/provider/corpus/I/O failure while retaining clearly marked diagnostic reports; return2 argument error. Ctrl-C cancellation leaves no success report. No raw HTTP, credentials or process-launch shell strings in main.swift. Keep WP1 dataset validator and historical English flags intact.

- [ ] **Step 5: Green, offline CLI checks and commit.**

```bash
swift test --filter BenchmarkRunnerTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
swift run ainotebook-eval --benchmark --mode fixture --root eval/multilingual --profiles nomic-v2-256 --chunks 1000 --queries 3 --warmup 1 --concurrent both --json /tmp/wp7-swift-fixture.json --out /tmp/wp7-swift-fixture.md
swift run ainotebook-eval --dataset multilingual --root eval/multilingual --validate-only
git add Sources/AINotebookCore/BenchmarkOptions.swift Sources/AINotebookCore/BenchmarkRunner.swift Tests/AINotebookCoreTests/BenchmarkRunnerTests.swift Sources/RetrievalEvalRunner/main.swift
git commit -m "feat(eval): orchestrate multilingual generation benchmark and calibration CLI" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: both suites zero failures/skips; fixture CLI exits0 with144 query rows, one candidate,1000-chunk diagnostics and modefixture; validator still prints44documents/144queries. No live server is contacted.

### Task 9c: [Windows] Portable benchmark/calibration CLI and retrieval/packing parity

**Depends on:** 9a,9b,7,16; WP1 Task7, WP5 Tasks13/16, WP8 Core builder merged. **Parallel with:** 8c. **Files:** `windows/src/AINotebook.Core/Eval/BenchmarkOptions.cs`, `windows/src/AINotebook.Core/Eval/BenchmarkRunner.cs`, `windows/tests/AINotebook.Core.Tests/Eval/BenchmarkRunnerTests.cs`, `windows/tools/AINotebook.Eval/Program.cs` only. Program.cs is a prerequisite-owned new file, grounded at WP1 plan:1293–1303; this plan does not claim it already exists.

**Interfaces — Consumes:** `EvalRunner.Load`, `EvalMetrics.Measure`, `EmbeddingGenerationBuilder.StageAsync`, `BenchmarkMeasurements.RunAsync/CalibrateAsync`, `ScopeResolver.Resolve`, `Retriever.SearchAsync/SearchEmbeddedAsync`, `EvidenceHydrator.Hydrate`, `ContextPackBuilder.Build` (`Rag/ContextPackBuilder.cs:13`) and `PreparedContextRequest` (`Rag/ContextPackTypes.cs:97`). **Produces:** every C# Task8c signature exactly, under `AINotebook.Core.Eval`. The Swift twin declarations in Task8c are binding; property casing is the only platform difference.

- [ ] **Step 1: Add failing parser and retained-span tests.**

```csharp
using System.Text;
using AINotebook.Core.Eval;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;
public sealed class BenchmarkRunnerTests
{
    [Fact] public void ParserRejectsRepeatedFlagsAndKeepsContractDefaults()
    {
        var o=BenchmarkOptions.Parse(["--benchmark","--mode","fixture","--json","a.json","--out","a.md"]);
        Assert.Equal(16,o.TopK); Assert.Equal(32,o.FetchK); Assert.Equal(new[]{100000,200000},o.ChunkCounts);
        Assert.Equal(7,o.ProfileIds.Count);
        Assert.Throws<BenchmarkException>(()=>BenchmarkOptions.Parse(["--benchmark","--mode","fixture",
            "--queries","200","--queries","1","--json","a","--out","b"]));
    }
    [Fact] public void PackedRecallUsesExactRetainedSpanAndRevision()
    {
        const string text="prefix gold"; string hash=EvalCorpus.Sha256(Encoding.UTF8.GetBytes(text));
        var revision=new BenchmarkRevision(1,10,"d",hash,text,[new ChunkReference(100,1,10,0)]);
        var citation=new Citation(1,100,1,"prefix") { RevisionId=10,Text="prefix",
            Spans=new[]{new CitationSpan(0,6,null,null)},ChunkIds=new long[]{100} };
        var gold=new[]{new EvalSpan("d",hash,7,11)};
        var a=BenchmarkRunner.Audit([citation],"Claim [1] [99]",[revision],gold);
        Assert.Equal(1,a.SnapshotsCorrect); Assert.Equal(1,a.AnswerMarkersCorrect);
        Assert.Equal(2,a.AnswerMarkersTotal); Assert.Equal(0,a.AnswerGoldSupported);
        Assert.Equal(0,EvalMetrics.Recall(gold,a.Packed).Found);
        var stale=BenchmarkRunner.Audit([citation with { RevisionId=11 }],"[1]",[revision],gold);
        Assert.Equal(0,stale.SnapshotsCorrect); Assert.Empty(stale.Packed);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~BenchmarkRunnerTests` → **FAIL: missing types**. Then run every shared phase/query/error fixture with `SharedFixtures.Json`, plus a full144-query fixture-mode run under fixed clock/environment and injected provider transport. Compare complete JSON structurally and Markdown byte-for-byte with the Swift golden fixture; metric denominators, sort order, truncation and zero-evidence behavior must agree.

- [ ] **Step 2: Implement the complete platform orchestration.** Parse exactly Task8c's enumerated flags/defaults with invariant unsigned decimal parsing; duplicate flags are errors. Use the portable .NET10 runner with its existing Core reference, no App SDK. Create/dispose private temporary file-backed stores. Materialize notebooks/folders/sources in the frozen ordering, commit canonical production `ScalarChunker.Chunk` revisions, stage through captured document sessions, and activate only completed generations. The virtual folder identity uses exact fixture IDs and performs no filesystem scan. All storage operations use typed gated store APIs; no naked SqliteConnection or `await` inside a gate.

For every question map scope IDs, call SearchAsync once, keep its `using` pool through hydration/build/audit, and translate each reference's own revision to EvalSpan. Construct PackPassage arrays from full hydrated text and exact RrfMicro; provide published revision dictionary and explicit `new RagRuntimeTuning(options.FetchK,options.TopK,options.EvidenceShareBp)` to Build, and actual source/revision output pairs to the report. Overview selects first published chunk per scoped source and delegates ordering to Build; empty selection sends zero provider calls. Measure lexical/fused pools with EvalMetrics.Measure, packed spans from Audit, and aggregate identical WP1 denominators. Call captured ObserveChatAsync with ordered section joins and score existing `CitationParser.Markers` (`Rag/CitationParser.cs:11`) occurrences; do not treat marker validity as semantic answer correctness.

The exact scalar citation validation kernel is:

```csharp
if(citation.RevisionId is not long revisionId || citation.Spans.Count!=1 || citation.Text is null) continue;
var revision=revisions.FirstOrDefault(x=>x.SourceId==citation.SourceId && x.RevisionId==revisionId);
if(revision is null) continue;
var span=citation.Spans[0]; var scalars=revision.Text.EnumerateRunes().ToArray();
if(span.Start<0 || span.End<=span.Start || span.End>scalars.Length) continue;
string expected=string.Concat(scalars.Skip(checked((int)span.Start)).Take(checked((int)(span.End-span.Start)))
    .Select(x=>x.ToString()));
if(!string.Equals(expected,citation.Text,StringComparison.Ordinal)
    || EvalCorpus.Sha256(Encoding.UTF8.GetBytes(revision.Text))!=revision.ContentHash) continue;
var references=revision.Chunks.Where(x=>citation.ChunkIds.Contains(x.ChunkId)).OrderBy(x=>x.Ord).ThenBy(x=>x.ChunkId).ToArray();
if(citation.ChunkIds.Count==0 || citation.ChunkIds.Distinct().Count()!=citation.ChunkIds.Count
    || !references.Select(x=>x.ChunkId).SequenceEqual(citation.ChunkIds)
    || citation.ChunkId!=citation.ChunkIds[0]
    || references.Any(x=>x.SourceId!=citation.SourceId || x.RevisionId!=revisionId)
    || !citation.Snippet.EnumerateRunes().SequenceEqual(citation.Text.EnumerateRunes().Take(240))) continue;
var retained=new EvalSpan(revision.DocumentId,revision.ContentHash,checked((int)span.Start),checked((int)span.End));
packed.Add(retained); validMarkers[citation.Marker]=retained;
```

For each synthetic dimension/count pair create actual WP5 rows and run cold/new-cache, warmup, measured and concurrent phases through SearchEmbeddedAsync plus hydration. The embedding callback calls the captured strict query-purpose session for every query. Gate p95 uses retrieval only; end-to-end includes actual query embedding and hydration. Precomputed one-hot vectors are only for the cached/streamed equivalence diagnostic. Populate sample arrays, cache residency/peak page bytes, per-run successful/service token telemetry and process-tree memory measurements. Await writer/sampler cleanup in finally. Re-read model digests/effective ceilings at end; changed model invalidates candidate. Validate and emit the exact shared report. `--calibrate` uses raw body count observations, full WP8 message observations, exact chat digest family and tokenizer provenance; embedding observations do not train chat rates. Fixture mode injects the catalog-dimension unit-vector fake, fixed clocks/digests and explicit fixture marker; it never constructs an HttpClient or calls a provider.

- [ ] **Step 3: Wire CLI outputs and verify.** Dispatch new flags before WP1 multilingual branch. Write sibling temp files and atomic replacements; preserve completed diagnostic files with statusincomplete and exit1, usage2, complete0. Ctrl-C cancels through every await and removes uncommitted temp output; no success file is created by cancellation. Add `--help` text covering both commands and print fixed required reference-protocol values without contacting Ollama.

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~BenchmarkRunnerTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
dotnet run --project windows/tools/AINotebook.Eval -- --benchmark --mode fixture --root eval/multilingual --profiles nomic-v2-256 --chunks 1000 --queries 3 --warmup 1 --concurrent both --json /tmp/wp7-dotnet-fixture.json --out /tmp/wp7-dotnet-fixture.md
dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --root eval/multilingual --validate-only
git add windows/src/AINotebook.Core/Eval/BenchmarkOptions.cs windows/src/AINotebook.Core/Eval/BenchmarkRunner.cs windows/tests/AINotebook.Core.Tests/Eval/BenchmarkRunnerTests.cs windows/tools/AINotebook.Eval/Program.cs
git commit -m "feat(win-eval): portable production benchmark and calibration runner" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: both suites green; fixture CLI produces144query rows and the same deterministic fixture metrics/Markdown as Swift; platform/environment fields are normalized by the shared golden fixture before cross-runtime comparison. CI runs fixture mode only.

### Task 10: [Swift] Fresh-install policy, generation identity and production estimator v2

**Depends on:** 1,2,6; WP8 pure builder merged. **Parallel with:** 11,8a,8b,9a,9b. **Files:** new `Sources/AINotebookCore/EmbeddingRecommendation.swift`, `Tests/AINotebookCoreTests/EmbeddingRecommendationTests.swift`; existing `Sources/AINotebookCore/ContextPackBuilder.swift:7`, `Tests/AINotebookCoreTests/ContextPackBuilderTests.swift:100`. `ContextPreviewSessionTests.swift` contains no builder invocation and is not an owned edit. Do not change AppSettings or preferences in this task.

**Interfaces — Consumes:** `EmbeddingProfiles.require(_:)`, `TokenEstimatorV2.bundled(model:)`, shared `embedding-default-v1.json`, production `embedding-decision-v1.json`; Windows twins below. **Produces:**

```swift
public struct EmbeddingInstallEvidence: Codable, Equatable, Sendable {
    public let databaseExists: Bool, preferencesExist: Bool, completedOnboarding: Bool
    public let explicitSelection: Bool, convertedChatOnly: Bool
    public init(databaseExists: Bool, preferencesExist: Bool, completedOnboarding: Bool,
                explicitSelection: Bool, convertedChatOnly: Bool)
}
public struct EmbeddingDecision: Codable, Equatable, Sendable {
    public let contract: String, version: Int, status: String, profileId: String?
    public init(contract: String = "embedding-decision", version: Int = 1,
                status: String, profileId: String?)
    public static func bundled() throws -> EmbeddingDecision
}
public struct EmbeddingSelection: Codable, Equatable, Sendable {
    public let providerId: String, model: String, profileId: String?
    public init(providerId: String, model: String, profileId: String?)
}
public enum EmbeddingRecommendation {
    public static func initial(evidence: EmbeddingInstallEvidence,
                               decision: EmbeddingDecision) throws -> EmbeddingSelection?
    public static func selection(profileId: String) throws -> EmbeddingSelection
    public static func identity(selection: EmbeddingSelection, endpointRevision: String,
                                modelDigest: String?, chunkerVersion: String, effectiveLimit: Int? = nil) throws -> GenerationIdentity
}
// Existing public builder remains source-compatible; resolve nil inside the function.
public static func ContextPackBuilder.build(_ input: ContextPackInput,
    estimator: (any ContextTokenEstimating)? = nil) throws -> PreparedContextRequest
```

```csharp
public sealed record EmbeddingInstallEvidence(bool DatabaseExists,bool PreferencesExist,
    bool CompletedOnboarding,bool ExplicitSelection,bool ConvertedChatOnly);
public sealed record EmbeddingDecision(string Contract,int Version,string Status,string? ProfileId)
{ public static EmbeddingDecision Bundled(); }
public sealed record EmbeddingSelection(string ProviderId,string Model,string? ProfileId);
public static EmbeddingSelection? EmbeddingRecommendation.Initial(EmbeddingInstallEvidence evidence,EmbeddingDecision decision);
public static EmbeddingSelection EmbeddingRecommendation.Selection(string profileId);
public static GenerationIdentity EmbeddingRecommendation.Identity(EmbeddingSelection selection,
    string endpointRevision,string? modelDigest,string chunkerVersion,int? effectiveLimit=null);
public static PreparedContextRequest ContextPackBuilder.Build(ContextPackInput input,IContextTokenEstimator? estimator=null);
```

Define EmbeddingRecommendationError: Error, Sendable with public code:String and init(code:), and C# EmbeddingRecommendationException(string code):Exception(code) with public Code; these are Core policy errors independent of Eval. All public Swift structs have the explicit public initializers above. `initial` returns nil to preserve current behavior, including the legacy default for an existing installation with absent embedding preferences. A pending decision returns nil. `selection` resolves the exact profile ID, returns local Ollama plus its model and profile ID; it never infers profile from model spelling. `identity` requires nonnil profile ID and exact model match, populates dims/prefix formats from the catalog and uses `normalization="l2"`; nil profile is the caller's existing legacy path, not a modern identity with raw input.

- [ ] **Step 1: Red fixture test and default-estimator test.** Task1 gives each install case `kind:"install"`, `input:{evidence:{databaseExists,preferencesExist,completedOnboarding,explicitSelection,convertedChatOnly},decision:{contract,version,status,profileId}}`, `expected:{applyProfileId:string|null}`. Rebuild cases have `kind:"rebuild"` and are handled by Task10b.

```swift
import XCTest
@testable import AINotebookCore
final class EmbeddingRecommendationTests: XCTestCase {
    func testSharedFreshInstallDecisions() throws {
        let rows = try SharedFixtures.json("contracts/embedding-default-v1.json")["cases"] as! [[String: Any]]
        for row in rows where row["kind"] as? String == "install" {
            let input = row["input"] as! [String: Any]
            func decode<T: Decodable>(_ value: Any, as: T.Type) throws -> T {
                try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
            }
            let evidence = try decode(input["evidence"]!, as: EmbeddingInstallEvidence.self)
            let decision = try decode(input["decision"]!, as: EmbeddingDecision.self)
            let actual = try EmbeddingRecommendation.initial(evidence: evidence, decision: decision)
            let expected = row["expected"] as! [String: Any]
            XCTAssertEqual(actual?.profileId, expected["applyProfileId"] as? String, row["name"] as! String)
        }
    }
    func testIdentityIncludesDimensionAndBothFormats() throws {
        let selection = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        let identity = try EmbeddingRecommendation.identity(selection: selection,
            endpointRevision: "endpoint-v1:test", modelDigest: "sha256:test", chunkerVersion: "1")
        XCTAssertEqual(identity.dims, 256)
        XCTAssertEqual(identity.queryFormatVersion, "wp7:nomic-v2-256:query:split1:scalarpool1:prefixl2:ctx512")
        XCTAssertEqual(identity.docFormatVersion, "wp7:nomic-v2-256:document:split1:scalarpool1:prefixl2:ctx512")
        XCTAssertThrowsError(try EmbeddingRecommendation.identity(selection:
            EmbeddingSelection(providerId: selection.providerId, model: "other", profileId: selection.profileId),
            endpointRevision: "endpoint-v1:test", modelDigest: nil, chunkerVersion: "1"))
    }
}
// Add to existing ContextPackBuilderTests.
func testProductionDefaultUsesVersionTwoAndExplicitV1RemainsAvailable() throws {
    let input = try ContextPackFixtures.input("basic-cs")
    let actual = try ContextPackBuilder.build(input)
    let expected = try ContextPackBuilder.build(input, estimator: TokenEstimatorV2.bundled(model: input.model.model))
    XCTAssertEqual(actual, expected)
    XCTAssertEqual(actual.estimatorVersion, 2)
    XCTAssertEqual(try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1()).estimatorVersion, 1)
}
```

Run `swift test --filter 'EmbeddingRecommendationTests|ContextPackBuilderTests'` → **FAIL: missing policy types / production version is 1**. Keep the existing golden fixtures and all their JSON/wire/span assertions. Add explicit `estimator: PlaceholderTokenEstimatorV1()` to each historical v1 golden/build call in `ContextPackBuilderTests`; do not alter expected budgets or remove assertions. Retain explicit custom estimators unchanged. This is version selection, not test relaxation.

- [ ] **Step 2: Implement decision policy and resolve the default inside the builder.**

```swift
public static func initial(evidence e: EmbeddingInstallEvidence,
                           decision d: EmbeddingDecision) throws -> EmbeddingSelection? {
    guard d.contract == "embedding-decision", d.version == 1,
          ["pending", "accepted"].contains(d.status) else { throw EmbeddingRecommendationError(code: "invalidDecision") }
    guard d.status == "accepted" else {
        guard d.profileId == nil else { throw EmbeddingRecommendationError(code: "invalidDecision") }
        return nil
    }
    guard let id = d.profileId else { throw EmbeddingRecommendationError(code: "invalidDecision") }
    let recommended = try selection(profileId: id) // validate even if this install is preserved
    guard !e.databaseExists, !e.preferencesExist, !e.completedOnboarding,
          !e.explicitSelection, !e.convertedChatOnly else { return nil }
    return recommended
}
// At the start of build, before validate:
let estimator: any ContextTokenEstimating
if let supplied = suppliedEstimator { estimator = supplied }
else { estimator = try TokenEstimatorV2.bundled(model: input.model.model) }
```

Use external label `estimator`, internal parameter name `suppliedEstimator`. `bundled()` validates resource contract/version; `accepted` must reference the existing profile catalog; `pending` requires profileId null. No test asserts the eventual winning model; decision data changes without source/test rewrites. Malformed decision data throws `invalidDecision`, never silently resets an existing selection.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter 'EmbeddingRecommendationTests|ContextPackBuilderTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/EmbeddingRecommendation.swift Sources/AINotebookCore/ContextPackBuilder.swift Tests/AINotebookCoreTests/EmbeddingRecommendationTests.swift Tests/AINotebookCoreTests/ContextPackBuilderTests.swift
git commit -m "feat(core): explicit fresh-install embedding policy and estimator v2" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: every old v1 golden remains green with explicit v1 injection; production default test reports version2; both complete suites green.

### Task 11: [Windows] Fresh-install policy and production estimator v2

**Depends on:** 1,3,7; WP8 pure builder merged. **Parallel with:** 10,8a,8b,9a,9b. **Files:** new `windows/src/AINotebook.Core/Rag/EmbeddingRecommendation.cs`, `windows/tests/AINotebook.Core.Tests/Rag/EmbeddingRecommendationTests.cs`; existing `windows/src/AINotebook.Core/Rag/ContextPackBuilder.cs:13`, `windows/tests/AINotebook.Core.Tests/Rag/ContextPackBuilderTests.cs:13`. Do not edit `ContextPreviewSessionTests.cs`: its operations manipulate stored bytes and do not invoke the builder.

**Interfaces — Consumes:** `EmbeddingProfiles.Require`, `TokenEstimatorV2.Bundled`, production decision/catalog resources and shared install cases. **Produces:** the exact C# declarations in Task10; their Swift twins there are the parity contract.

- [ ] **Step 1: Red fixture and estimator tests.**

```csharp
using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Rag;
public sealed class EmbeddingRecommendationTests
{
    [Fact] public void SharedFreshInstallDecisions()
    {
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        foreach (var row in SharedFixtures.Json("contracts/embedding-default-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (row.GetProperty("kind").GetString() != "install") continue;
            var input = row.GetProperty("input");
            var e = input.GetProperty("evidence").Deserialize<EmbeddingInstallEvidence>(options)!;
            var d = input.GetProperty("decision").Deserialize<EmbeddingDecision>(options)!;
            var result = EmbeddingRecommendation.Initial(e,d);
            Assert.Equal(row.GetProperty("expected").GetProperty("applyProfileId").GetString(), result?.ProfileId);
        }
    }
    [Fact] public void IdentityIncludesDimensionAndBothFormats()
    {
        var s = EmbeddingRecommendation.Selection("nomic-v2-256");
        var i = EmbeddingRecommendation.Identity(s,"endpoint-v1:test","sha256:test","1");
        Assert.Equal(256,i.Dims);
        Assert.Equal("wp7:nomic-v2-256:query:split1:scalarpool1:prefixl2:ctx512",i.QueryFormatVersion);
        Assert.Equal("wp7:nomic-v2-256:document:split1:scalarpool1:prefixl2:ctx512",i.DocFormatVersion);
        Assert.Throws<EmbeddingRecommendationException>(() =>
            EmbeddingRecommendation.Identity(s with { Model="other" },"endpoint-v1:test",null,"1"));
    }
}
// Add inside ContextPackBuilderTests:
[Fact] public void ProductionDefaultIsV2WhileExplicitV1RemainsAvailable()
{
    var input = ContextPackFixtures.Input("basic-cs");
    var actual = ContextPackBuilder.Build(input);
    var expected = ContextPackBuilder.Build(input,TokenEstimatorV2.Bundled(input.Model.Model));
    Assert.Equal(PreparedContextRequestJson.Encode(expected),PreparedContextRequestJson.Encode(actual));
    Assert.Equal(2,actual.EstimatorVersion);
    Assert.Equal(1,ContextPackBuilder.Build(input,new PlaceholderTokenEstimatorV1()).EstimatorVersion);
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~EmbeddingRecommendationTests|FullyQualifiedName~ContextPackBuilderTests'` → **FAIL: missing types / default version1**. Make every historical v1 builder call explicit with `new PlaceholderTokenEstimatorV1()`; preserve custom estimator tests and full JSON/span/wire goldens.

- [ ] **Step 2: Implement Core policy and builder selection.**

```csharp
public static EmbeddingSelection? Initial(EmbeddingInstallEvidence e,EmbeddingDecision d)
{
    if (d.Contract!="embedding-decision" || d.Version!=1 || d.Status is not ("pending" or "accepted"))
        throw new EmbeddingRecommendationException("invalidDecision");
    if (d.Status=="pending")
    {
        if (d.ProfileId is not null) throw new EmbeddingRecommendationException("invalidDecision");
        return null;
    }
    if (d.ProfileId is null) throw new EmbeddingRecommendationException("invalidDecision");
    var selected=Selection(d.ProfileId);
    return e.DatabaseExists || e.PreferencesExist || e.CompletedOnboarding || e.ExplicitSelection || e.ConvertedChatOnly
        ? null : selected;
}
// ContextPackBuilder.Build, replacing the v1 fallback at line15:
estimator = new ValidatedEstimator(estimator ?? TokenEstimatorV2.Bundled(input.Model.Model));
```

Resolve the exact catalog ID; reject profile/model mismatch. `Identity` copies provider ID and model from the selection and fills dimensions, `l2`, both profile format strings, endpoint revision, digest and chunker version explicitly. Embedded JSON parsing uses the exact resource names introduced in Task3. No filesystem, SettingsService, Windows APIs or HTTP enter this pure Core policy.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~EmbeddingRecommendationTests|FullyQualifiedName~ContextPackBuilderTests'
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/EmbeddingRecommendation.cs windows/src/AINotebook.Core/Rag/ContextPackBuilder.cs windows/tests/AINotebook.Core.Tests/Rag/EmbeddingRecommendationTests.cs windows/tests/AINotebook.Core.Tests/Rag/ContextPackBuilderTests.cs
git commit -m "feat(win-core): fresh-install embedding policy and estimator v2" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: exact shared decisions, explicit historical v1 goldens and production-v2 checks pass; both full suites green.

### Task 10b: [Swift] Recoverable explicit rebuild and atomic notebook activation

**Depends on:** 8a,10; WP3 generation SQL seams merged. **Parallel with:** 11b. **Files:** new `Sources/AINotebookCore/{EmbeddingRebuildService,EmbeddingRebuildJournal,NotebookStore+EmbeddingRebuild}.swift`, new `Tests/AINotebookCoreTests/EmbeddingRebuildServiceTests.swift`. These paths are disjoint from Task10. Grounding: `NotebookStore.swift:13` has module-internal `dbQueue`; `:15` exposes notebook rows. WP3 plan:1003 defines `GenerationSQL.activate` inside an existing transaction. There is no shipped `app_settings` SQL table; do not invent one or add a migration.

**Interfaces — Consumes:** `EmbeddingGenerationBuilder.stage(store:notebookId:identity:session:now:) async throws -> IndexGeneration`, `GenerationSQL.activate(_:id:fence:now:)`, `NotebookStore.generation(id:)`, `retireGeneration(id:)`. **Produces:**

```swift
public struct EmbeddingRebuildTarget: Codable, Equatable, Sendable {
    public let notebookId: Int64, generationId: Int64
    public init(notebookId: Int64, generationId: Int64)
}
public struct EmbeddingRebuildRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let previous: EmbeddingSelection, requested: EmbeddingSelection
    public let targets: [EmbeddingRebuildTarget]
    public init(version: Int = 1, previous: EmbeddingSelection,
                requested: EmbeddingSelection, targets: [EmbeddingRebuildTarget])
}
public struct EmbeddingRebuildJournal: Sendable {
    public init(url: URL)
    public func read() throws -> EmbeddingRebuildRecord?
    public func write(_ record: EmbeddingRebuildRecord) throws
    public func clear() throws
}
@MainActor public final class EmbeddingRebuildService {
    public init(store: NotebookStore, journal: EmbeddingRebuildJournal,
        current: @escaping @MainActor () -> EmbeddingSelection,
        persist: @escaping @MainActor (EmbeddingSelection) throws -> Void,
        stage: @escaping @MainActor (Int64, EmbeddingSelection) async throws -> IndexGeneration,
        now: @escaping @Sendable () -> Int64)
    public func rebuild(_ requested: EmbeddingSelection) async throws
    public func recover() throws
}
extension NotebookStore {
    public func activateEmbeddingRebuild(_ targets: [EmbeddingRebuildTarget],
        requested: EmbeddingSelection, now: Int64) throws
}
```

```csharp
public sealed record EmbeddingRebuildTarget(long NotebookId,long GenerationId);
public sealed record EmbeddingRebuildRecord(int Version,EmbeddingSelection Previous,
    EmbeddingSelection Requested,IReadOnlyList<EmbeddingRebuildTarget> Targets);
public sealed class EmbeddingRebuildJournal(string path) {
    public EmbeddingRebuildRecord? Read(); public void Write(EmbeddingRebuildRecord record); public void Clear();
}
public sealed class EmbeddingRebuildService(NotebookStore store,EmbeddingRebuildJournal journal,
    Func<EmbeddingSelection> current,Action<EmbeddingSelection> persist,
    Func<long,EmbeddingSelection,CancellationToken,Task<IndexGeneration>> stage,Func<long> now) {
    public Task RebuildAsync(EmbeddingSelection requested,CancellationToken ct=default);
    public void Recover();
}
public void NotebookStore.ActivateEmbeddingRebuild(IReadOnlyList<EmbeddingRebuildTarget> targets,
    EmbeddingSelection requested,long now);
```

The journal lives beside db.sqlite as `embedding-rebuild-v1.json`, contains no roots/secrets/source text and is written before activation. It is a local recovery record, not a benchmark report. Store activation and preference persistence are different stores: a committed activation followed by failed preference persistence leaves the journal for startup recovery; the UI must not claim that case rolled back.

- [ ] **Step 1: Red transactional and crash-boundary tests.** Use the shared `kind:"rebuild"` rows. Add fixture cases `second-stage-fails`, `second-activation-invalid`, `settings-write-fails`, `reopen-after-activation`, `notebook-set-changed`; each has `operation`, `expectedActive:"old"|"new"`, `expectedSelection:"old"|"new"`, `journalRetained:Bool`. The concrete two-notebook test uses empty notebooks so it tests publication atomicity independently of provider/vector code:

```swift
import XCTest
@testable import AINotebookCore
@MainActor final class EmbeddingRebuildServiceTests: XCTestCase {
    func testSecondActivationFailureRollsBackFirst() throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        let identity = try EmbeddingRecommendation.identity(selection: selection,
            endpointRevision: "endpoint-v1:test", modelDigest: nil, chunkerVersion: "1")
        let a = try store.createNotebook(name: "a").id!
        let b = try store.createNotebook(name: "b").id!
        let oldA = try store.createGeneration(notebookId: a, identity: identity, now: 1)
        let oldB = try store.createGeneration(notebookId: b, identity: identity, now: 1)
        try store.activateGeneration(id: oldA.id, now: 2)
        try store.activateGeneration(id: oldB.id, now: 2)
        let nextA = try store.createGeneration(notebookId: a, identity: identity, now: 3)
        XCTAssertThrowsError(try store.activateEmbeddingRebuild([
            EmbeddingRebuildTarget(notebookId: a, generationId: nextA.id),
            EmbeddingRebuildTarget(notebookId: b, generationId: Int64.max)
        ], requested: selection, now: 4))
        XCTAssertEqual(try store.activeGeneration(notebookId: a)?.id, oldA.id)
        XCTAssertEqual(try store.activeGeneration(notebookId: b)?.id, oldB.id)
        XCTAssertEqual(try store.generation(id: nextA.id)?.state, "building")
    }
    func testCommittedActivationIsRecoveredBeforeSettingsAreReadByRouter() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NotebookStore(path: .inMemory)
        _ = try store.createNotebook(name: "one")
        let old = EmbeddingSelection(providerId: ProviderConfig.ollamaId, model: "nomic-embed-text", profileId: nil)
        let next = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        var selected = old
        var failSettingsWrite = true
        let journal = EmbeddingRebuildJournal(url: dir.appendingPathComponent("embedding-rebuild-v1.json"))
        let service = EmbeddingRebuildService(store: store, journal: journal,
            current: { selected }, persist: { value in
                if failSettingsWrite { throw EmbeddingRecommendationError(code: "settingsWriteFailed") }
                selected = value
            }, stage: { notebookId, selection in
                let identity = try EmbeddingRecommendation.identity(selection: selection,
                    endpointRevision: "endpoint-v1:test", modelDigest: nil, chunkerVersion: "1")
                return try store.createGeneration(notebookId: notebookId, identity: identity, now: 1)
            }, now: { 2 })
        do { try await service.rebuild(next); XCTFail("settings write must fail") } catch {}
        XCTAssertEqual(selected, old)
        XCTAssertNotNil(try journal.read())
        failSettingsWrite = false
        try service.recover()
        XCTAssertEqual(selected, next)
        XCTAssertNil(try journal.read())
        try service.recover() // idempotent
        XCTAssertEqual(selected, next)
    }
}
```

Run `swift test --filter EmbeddingRebuildServiceTests` → **FAIL: missing service/store API**. Add fixture-driven cancellation-before-stage, second-stage failure, invalid-second-activation, successful publication, and replay tests. Before-activation failures assert every prior generation ID remains active, selected bundle unchanged and completed staged generations retired. The settings-write failure is explicitly the committed/recoverable case shown above.

- [ ] **Step 2: Implement the atomic activation helper.** In a single `dbQueue.write` closure load sorted `SELECT id FROM notebooks`; require exact equality to sorted unique target notebook IDs. Resolve each target generation in that transaction, require its notebook matches, state building, and its provider/model/dims/queryFormatVersion/docFormatVersion equal the requested profile identity (endpoint/digest remain the captured values). Call `GenerationSQL.activate(db,id:target.generationId,fence:nil,now:now)` for every target in notebook order. A throw rolls back all state changes. Do not call the public `activateGeneration` from inside this transaction. New notebooks added/deleted during staging produce `rebuildScopeChanged`; refreshing sources produce WP3's activation-precondition failure. No partially activated set is published.

- [ ] **Step 3: Implement journal and service with this order.** `write` encodes version1, creates the existing app-support parent if needed, and calls `Data.write(to:options:.atomic)`; decoding rejects unsupported version, duplicate/invalid target IDs and malformed selections. `clear` ignores file-not-found only; other IO errors propagate. `rebuild` is guarded by an actor-isolated `busy` Boolean, rejecting a second operation with `rebuildInProgress`. Snapshot current selection and notebook IDs before the first await, stage each notebook using the captured requested selection, check cancellation after each await and immediately before journal write. Then execute synchronously, without any intervening await: write journal → atomic activation → persist the full requested selection → clear journal. On preactivation failure retire only this operation's still-building targets and remove its journal; on postactivation failure retain the journal and throw `selectionPersistenceFailed`. Never erase all embeddings or call GC on cancellation.

`recover` runs before router/worker construction. With no journal it does nothing. If every target is active with matching requested identity, persist requested and clear; for zero notebook targets, persist requested and clear. If every target remains building or retired and none is active, retain previous selection, retire remaining staged targets and clear. Mixed/foreign/missing targets fail `rebuildRecoveryConflict` and keep the journal for inspection; they cannot arise from the atomic helper and must not be papered over by changing selection. Test journal roundtrip, corrupt JSON, write failure, every crash boundary, cancellation and duplicate request. Journal tests use only temp directories.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter EmbeddingRebuildServiceTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/EmbeddingRebuildService.swift Sources/AINotebookCore/EmbeddingRebuildJournal.swift Sources/AINotebookCore/NotebookStore+EmbeddingRebuild.swift Tests/AINotebookCoreTests/EmbeddingRebuildServiceTests.swift
git commit -m "feat(core): recoverable profile rebuild with atomic notebook activation" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: failures before activation preserve all old active IDs; postactivation persistence failure is replayed exactly once; both full suites green.

### Task 11b: [Windows] Recoverable rebuild and locked atomic activation

**Depends on:** 9a,11; WP3 transaction seams merged. **Parallel with:** 10b. **Files:** new `windows/src/AINotebook.Core/Rag/{EmbeddingRebuildService,EmbeddingRebuildJournal}.cs`, new `windows/src/AINotebook.Core/Storage/NotebookStore.EmbeddingRebuild.cs`, new `windows/tests/AINotebook.Core.Tests/Rag/EmbeddingRebuildServiceTests.cs`. Grounding: the store is partial, `_conn` at `NotebookStore.cs:14`, `_gate` at `:34`; `Notebooks()` at `:163` is the existing sorted-read API. No migration edits.

**Interfaces — Consumes:** `EmbeddingGenerationBuilder.StageAsync`, `GenerationSQL.Activate(SqliteConnection,SqliteTransaction,long,JobFence?,long)`, generation read/retire APIs. **Produces:** all C# journal/service/store signatures in Task10b; Swift counterparts there are exact parity.

- [ ] **Step 1: Red rollback and recovery Facts.**

```csharp
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Providers;
using Xunit;
namespace AINotebook.Core.Tests.Rag;
public sealed class EmbeddingRebuildServiceTests
{
    [Fact] public void InvalidSecondTargetRollsBackFirstActivation()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var selection = EmbeddingRecommendation.Selection("nomic-v2-256");
        var identity = EmbeddingRecommendation.Identity(selection,"endpoint-v1:test",null,"1");
        long a=store.CreateNotebook("a").Id!.Value,b=store.CreateNotebook("b").Id!.Value;
        var oldA=store.CreateGeneration(a,identity,1); var oldB=store.CreateGeneration(b,identity,1);
        store.ActivateGeneration(oldA.Id,2); store.ActivateGeneration(oldB.Id,2);
        var nextA=store.CreateGeneration(a,identity,3);
        Assert.ThrowsAny<Exception>(()=>store.ActivateEmbeddingRebuild(
            [new(a,nextA.Id),new(b,long.MaxValue)],selection,4));
        Assert.Equal(oldA.Id,store.ActiveGeneration(a)!.Id);
        Assert.Equal(oldB.Id,store.ActiveGeneration(b)!.Id);
        Assert.Equal("building",store.Generation(nextA.Id)!.State);
    }
    [Fact] public async Task RecoveryFinishesCommittedSelectionAndIsIdempotent()
    {
        string dir=Directory.CreateTempSubdirectory("wp7-recovery-").FullName;
        try
        {
            using var store=new NotebookStore(StorePath.InMemory);
            store.CreateNotebook("one");
            var old=new EmbeddingSelection(ProviderConfig.OllamaId,"nomic-embed-text",null);
            var next=EmbeddingRecommendation.Selection("nomic-v2-256");
            var selected=old; bool fail=true;
            var journal=new EmbeddingRebuildJournal(Path.Combine(dir,"embedding-rebuild-v1.json"));
            var service=new EmbeddingRebuildService(store,journal,()=>selected,
                value=> { if(fail) throw new IOException("write failed"); selected=value; },
                (notebookId,selection,ct)=>Task.FromResult(store.CreateGeneration(notebookId,
                    EmbeddingRecommendation.Identity(selection,"endpoint-v1:test",null,"1"),1)),()=>2);
            await Assert.ThrowsAnyAsync<Exception>(()=>service.RebuildAsync(next));
            Assert.Equal(old,selected); Assert.NotNull(journal.Read());
            fail=false; service.Recover(); service.Recover();
            Assert.Equal(next,selected); Assert.Null(journal.Read());
        }
        finally { Directory.Delete(dir,true); }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EmbeddingRebuildServiceTests` → **FAIL: missing types**. Execute all shared rebuild-case rows, including cancellation and notebook membership change, through a test fake stage delegate; inspect old/new active IDs and journal retention according to each row.

- [ ] **Step 2: Implement the store transaction and journal.**

```csharp
public void ActivateEmbeddingRebuild(IReadOnlyList<EmbeddingRebuildTarget> targets,
    EmbeddingSelection requested,long now)
{
    lock (_gate)
    {
        using var tx=_conn.BeginTransaction();
        // Materialize and validate the complete notebook/target/identity set here,
        // using parameterized commands whose Transaction is tx.
        ValidateEmbeddingRebuildTargets(_conn,tx,targets,requested);
        foreach(var target in targets.OrderBy(x=>x.NotebookId))
            GenerationSQL.Activate(_conn,tx,target.GenerationId,null,now);
        tx.Commit();
    }
}
```

`ValidateEmbeddingRebuildTargets` is a private static function in this partial file. Read `SELECT id FROM notebooks ORDER BY id`, reject duplicate targets and unequal IDs, query each generation by `$id` and require matching notebook, building state, requested provider/model/dims/query/doc formats. Every command, reader and transaction operation stays inside `_gate`. Do not await or call the public transactional generation methods from the helper.

`EmbeddingRebuildJournal.Write` serializes UTF-8 JSON to a unique same-directory temporary file using `FileStream(FileMode.CreateNew,FileAccess.Write,FileShare.None)`, writes bytes, `Flush(flushToDisk:true)`, disposes, then `File.Move(temp,path,overwrite:true)`; clean only its own temp file on failure. `Read` validates the same envelope/IDs/profile selections as Swift; `Clear` ignores absent path only. Use no package identity APIs. `RebuildAsync` uses `SemaphoreSlim.WaitAsync(0,ct)` to reject concurrent rebuild with `rebuildInProgress`; captures old selection/notebook list, stages each with supplied ct, checks ct before publication, then writes journal, commits batch, persists selection and removes journal. No cancellation check splits the committed activation from selection persistence. `Recover` uses the same gate and active/building/retired rules as Swift. Settings callbacks execute on the caller's captured UI context; do not use ConfigureAwait(false) around the persistence callback.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EmbeddingRebuildServiceTests
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/EmbeddingRebuildService.cs windows/src/AINotebook.Core/Rag/EmbeddingRebuildJournal.cs windows/src/AINotebook.Core/Storage/NotebookStore.EmbeddingRebuild.cs windows/tests/AINotebook.Core.Tests/Rag/EmbeddingRebuildServiceTests.cs
git commit -m "feat(win-core): locked atomic rebuild activation and journal recovery" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: identical shared outcomes, rollback of the complete activation set, crash recovery and both full suites green.

### Task 10c: [Swift] Route normal embedding drains through the stored profile identity

**Depends on:** 4,8a,10,10b; WP3/WP5/WP6 Swift ingestion/worker ownership merged. **Parallel with:** 11c. **Files:** existing Sources/AINotebookCore/Embedder.swift:16,37 and Tests/AINotebookCoreTests/EmbedderTests.swift; new Sources/AINotebookCore/ProfileEmbeddingDrain.swift, Sources/AINotebookCore/NotebookStore+ProfileEmbedding.swift, Tests/AINotebookCoreTests/ProfileEmbeddingDrainTests.swift. EmbeddingWorker.swift is read-only: its coalescing kick/waitUntilIdle behavior at :22/:51 stays unchanged. Do not introduce a second worker or watcher.

**Interfaces — Consumes:** ProviderRouter.prepareEmbeddingProfile(providerId:profileId:) async throws -> PreparedEmbeddingProfile (identity/session); EmbeddingGenerationBuilder.stage with optional pre-created generation and reuseActive flag; WP3 enqueue/claim/renew/fail/cancel JobFence APIs; IngestLeaseClock; WP5 sessions. **Produces:**

```swift
// Append defaulted closure to Embedder's live-key initializer; old overloads unchanged.
profileDrain: (@Sendable () async throws -> Int?)? = nil
// First operation of embedAllPending:
if let profileDrain, let count = try await profileDrain() { return count }

@MainActor public final class ProfileEmbeddingDrain {
    public init(store: NotebookStore,
        selection: @escaping @Sendable () -> EmbeddingSelection,
        prepare: @escaping @Sendable (EmbeddingSelection) async throws -> PreparedEmbeddingProfile,
        resume: @escaping @Sendable (GenerationIdentity) async throws -> ProviderEmbeddingSession,
        clock: any IngestLeaseClock = SystemIngestLeaseClock())
    public func run() async throws -> Int?
}
extension NotebookStore {
    public func profileEmbeddingWork(_ selection: EmbeddingSelection) throws -> [Int64]
    public func beginProfileEmbedding(notebookId: Int64, identity: GenerationIdentity,
        now: Int64, leaseToken: String) throws -> (generation: IndexGeneration, fence: JobFence)
    public func activateProfileEmbedding(generationId: Int64, previousActiveId: Int64?,
        fence: JobFence, selected: EmbeddingSelection, now: Int64) throws -> Bool
}
```

```csharp
// Optional appended Embedder constructor parameter:
Func<CancellationToken,Task<int?>>? profileDrain=null
public sealed class ProfileEmbeddingDrain(NotebookStore store,Func<EmbeddingSelection> selection,
    Func<EmbeddingSelection,CancellationToken,Task<PreparedEmbeddingProfile>> prepare,
    Func<GenerationIdentity,CancellationToken,Task<ProviderEmbeddingSession>> resume,IIngestLeaseClock? clock=null)
{ public Task<int?> RunAsync(CancellationToken ct=default); }
public IReadOnlyList<long> NotebookStore.ProfileEmbeddingWork(EmbeddingSelection selection);
public (IndexGeneration Generation,JobFence Fence) NotebookStore.BeginProfileEmbedding(
    long notebookId,GenerationIdentity identity,long now,string leaseToken);
public bool NotebookStore.ActivateProfileEmbedding(long generationId,long? previousActiveId,
    JobFence fence,EmbeddingSelection selected,long now);
```

Nil result means legacy selection and executes the existing WP3 legacy drain unchanged; zero is a completed modern drain with no work. Never identify profile from model substring. The stage API accepts an already-created generation so a background lease exists before the first embedding request; it never unconditionally retires a caller-owned generation on failure, because a newer lease may now own it; explicit benchmark/Settings callers omit it. reuseActive=true copies unchanged same-identity source/revision vectors; benchmark false builds each candidate from scratch.

- [ ] **Step 1: Red shared fixture and legacy-dispatch tests.** Task1 extends embedding-default-v1 with kind="drain" cases fresh-import, restart-no-work, same-model-other-dims, legacy-no-profile, refresh-pending, lost-lease, selected-profile-changed, and changed-active-during-request. Include expected request count, exact document prefix, identity format/dims, published active state and rows written. Add this direct existing Embedder test before implementing dispatch:

```swift
func testExplicitProfileDrainRunsBeforeLegacyTransport() async throws {
    actor RawClient: EmbeddingProducing {
        var calls = 0
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            calls += 1; return inputs.map { _ in [1,0] }
        }
    }
    let store = try await MainActor.run { try NotebookStore(path: .inMemory) }
    let raw = RawClient()
    let embedder = Embedder(store:store,client:raw,modelKey:{"legacy-key"},
        profileDrain:{ 7 })
    let count = try await embedder.embedAllPending()
    XCTAssertEqual(count,7)
    let calls = await raw.calls
    XCTAssertEqual(calls,0)
}
```

Run swift test --filter 'EmbedderTests|ProfileEmbeddingDrainTests' → **FAIL: missing initializer/API**. In ProfileEmbeddingDrainTests feed every shared drain case into an in-memory store; create one foreground published revision with canonical text "Záruka platí." and actual scalar chunk drafts, use a fixture strict transport recording inputs/native dims and a manually advanced IngestLeaseClock. The fresh-import case asserts "search_document: Záruka platí.", output256, query/doc identity ending ctx512, done job and active generation. Reopen the same file with the persisted selection and drain again: zero provider requests and unchanged generation ID. legacy-no-profile returns nil and the original EmbedderTests exercise untouched raw behavior.

- [ ] **Step 2: Implement pending-work discovery and fenced publication.** profileEmbeddingWork materializes notebook IDs in order where an eligible/present source has a published revision absent/different in the matching active manifest, or no active generation matches selected provider/model/profile query/doc formats/dims. An empty notebook is not work. Sources whose current revision differs from published remain refresh-pending; do not replace active until published catches up. A profile's ctx limit is parsed from and preserved in the existing active identity; a server capability change never silently rewrites a serving generation.

run snapshots the full typed selection. For each work notebook, capture prior active ID. If its identity matches selected profile/model and fixed dimensions/formats, call resume(identity) and keep that complete identity including effective cap/digest. Otherwise call prepare(selection) once, which captures provider root/model digest/show ceiling and returns the new exact identity/session. Recheck selected bundle after every await before writes. beginProfileEmbedding enters one dbQueue.write transaction and composes GenerationSQL.create, RevisionJobSQL.enqueueJob(kind embed,target generation:<id>,targetRevision nil), and RevisionJobSQL.claimJob(id:theNewJobId,leaseToken:theNewUUID) to return generation plus JobFence. No scheduler can claim between creation and this exact claim. Renew every60 seconds through the injected clock while stage runs. Pass the pre-created generation plus reuseActive:true to stage. Stop/await renewal after completion; failure to renew cancels in-flight stage and never publishes. Attempts/backoff/exhaustion remain entirely in WP3/WP6 kernels.

activateProfileEmbedding runs one dbQueue.write transaction: validate selected provider/model/profile against generation, compare current active ID to captured previousActiveId, validate live fence, and call GenerationSQL.activate with that fence. It completes the job atomically. Stale selection or changed active cancels the owned attempt and returns false; leave staged data for orderly retirement, with previous active unchanged. Cancellation uses the fenced cancel overload; provider failure calls failJob with sanitized error code. Do not invoke the no-job public activation API from this background worker. The existing EmbeddingWorker remains the only coalescing drain entry point. This branch claims only its just-created exact job; it never polls the general job queue or starts another worker. WP6 may recover its expired job after a crash through the existing durable scheduler and purpose-aware session APIs.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter 'EmbedderTests|ProfileEmbeddingDrainTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/Embedder.swift Sources/AINotebookCore/ProfileEmbeddingDrain.swift Sources/AINotebookCore/NotebookStore+ProfileEmbedding.swift Tests/AINotebookCoreTests/EmbedderTests.swift Tests/AINotebookCoreTests/ProfileEmbeddingDrainTests.swift
git commit -m "feat(core): apply stored embedding profiles to ordinary ingestion" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: fresh imports use complete profile formatting/dims, restart does no redundant work, legacy tests unchanged, lost lease cannot activate, both suites green.

### Task 11c: [Windows] Profile-aware normal drains with fenced publication

**Depends on:** 5,9a,11,11b; WP3/WP5/WP6 Windows worker changes merged. **Parallel with:** 10c. **Files:** existing windows/src/AINotebook.Core/Rag/Embedder.cs:20,31 and windows/tests/AINotebook.Core.Tests/Rag/EmbedderTests.cs; new windows/src/AINotebook.Core/Rag/ProfileEmbeddingDrain.cs, windows/src/AINotebook.Core/Storage/NotebookStore.ProfileEmbedding.cs, windows/tests/AINotebook.Core.Tests/Rag/ProfileEmbeddingDrainTests.cs. Existing EmbeddingWorker.cs stays read-only and remains the sole coalescing entry point.

**Interfaces — Consumes:** PrepareEmbeddingProfileAsync/PreparedEmbeddingProfile, existing-generation StageAsync, IIngestLeaseClock and WP3 lease APIs. **Produces:** C# signatures from Task10c, whose Swift signatures fix exact parity.

- [ ] **Step 1: Red dispatch test and shared drain matrix.**

```csharp
[Fact] public async Task ExplicitProfileDrainSkipsRawLegacyTransport()
{
    using var store=new NotebookStore(StorePath.InMemory);
    var raw=new RawCounter();
    var embedder=new Embedder(store,raw,()=>"legacy-key",
        profileDrain:ct=>Task.FromResult<int?>(7));
    Assert.Equal(7,await embedder.EmbedAllPendingAsync());
    Assert.Equal(0,raw.Calls);
}
private sealed class RawCounter : IEmbeddingProducing
{
    public int Calls;
    public Task<float[][]> EmbedAsync(string model,IReadOnlyList<string> inputs,CancellationToken ct=default)
    {
        Calls++;
        return Task.FromResult(inputs.Select(_=>new[]{1f,0f}).ToArray());
    }
}
```

Run dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~EmbedderTests|FullyQualifiedName~ProfileEmbeddingDrainTests' → **FAIL: missing constructor/types**. Add AINotebook.Core.Ollama import for IEmbeddingProducing. Run all kind="drain" rows in shared embedding-default-v1 against file/in-memory stores and fake strict transport/lease clock. Assert exact recorded prefixed input, native and output dimensions, format version ctx suffix, active ID/job state, no requests on reopen, and lost-fence rejection. Compare returned tokens/vectors with shared strict-profile fixtures; no live model.

- [ ] **Step 2: Implement the profiled branch and locked store methods.**

```csharp
// At the beginning of EmbedAllPendingAsync:
if (_profileDrain is not null)
{
    int? profiled=await _profileDrain(ct);
    if (profiled.HasValue) return profiled.Value;
}
// Existing legacy loop follows unchanged.
```

ProfileEmbeddingWork reads matching active identity/manifest and eligible published membership under lock(_gate), materializes IDs and returns before any await. RunAsync snapshots immutable selection, preserves matching active identity/effective cap, otherwise calls PrepareEmbeddingProfileAsync once. BeginProfileEmbedding performs GenerationSQL.Create, RevisionJobSQL.EnqueueJob and exact-ID RevisionJobSQL.ClaimJob in one lock(_gate)+transaction, returning the generation and its fence before any embedding request. Run existing-generation stage with reuseActive:true while renewal runs every60 seconds; stop renewal with a linked CTS before publication. Use the injected IIngestLeaseClock, not wall-clock sleeps in tests.

ActivateProfileEmbedding locks _gate, begins one transaction, validates target identity/profile/selected bundle and unchanged prior active ID, validates JobFence and calls GenerationSQL.Activate(_conn,tx,id,fence,now), then commits. No unguarded connection use or await occurs in the lock. Selection changes and newer active generations prevent late publication; failure/cancellation uses fenced APIs only. The existing EmbeddingWorker remains the only coalescing drain entry point. This method claims only the just-created exact job inside its creation transaction and never polls the general queue. WP6 retains expired-job recovery, attempts/backoff and generic scheduler ownership.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~EmbedderTests|FullyQualifiedName~ProfileEmbeddingDrainTests'
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Rag/Embedder.cs windows/src/AINotebook.Core/Rag/ProfileEmbeddingDrain.cs windows/src/AINotebook.Core/Storage/NotebookStore.ProfileEmbedding.cs windows/tests/AINotebook.Core.Tests/Rag/EmbedderTests.cs windows/tests/AINotebook.Core.Tests/Rag/ProfileEmbeddingDrainTests.cs
git commit -m "feat(win-core): persist profile identity through ordinary embedding work" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: fixture matrix and existing legacy Embedder tests pass; failed/cancelled/lost-lease work preserves serving generation; both Core suites green.

### Task 15: [Swift] Carry measured tuning into production without rewriting v1

**Depends on:** 1,10; WP5 typed Retriever and WP8 builder. **Parallel with:** 16,8a/8b/9a/9b,10b/11b. **Files:** new `Sources/AINotebookCore/RagRuntimeTuning.swift`, `Tests/AINotebookCoreTests/RagRuntimeTuningTests.swift`; modify `Sources/AINotebookCore/ContextPackAlgorithms.swift:110,115`, `ContextPackBuilder.swift:7,56`, `Retriever.swift` (only the typed overloads added by WP5 plan:1849), `Tests/AINotebookCoreTests/ContextPackBuilderTests.swift:100`. Task10 completes that test/builder edit first. No constants-v1 or RagContractV1 edits.

**Interfaces — Consumes:** decision resource `{status,parameters:{fetchK,topK,evidenceShareBp}}`, `constants-v1.json` and optional v2, Task1 `benchmark-run-v1` tuning cases. **Produces:**

```swift
public struct RagRuntimeTuning: Codable, Equatable, Sendable {
    public let fetchK: Int, topK: Int, evidenceShareBp: Int
    public init(fetchK: Int, topK: Int, evidenceShareBp: Int) throws
    public static let v1: RagRuntimeTuning // 32,16,6000
    public static func decodeDecision(_ data: Data) throws -> RagRuntimeTuning
    public static func bundled() throws -> RagRuntimeTuning
}
public static func ContextPackAlgorithms.budget(_ input: PackBudgetInput,
    evidenceShareBp: Int = 6000) throws -> PackBudgetResult
public static func ContextPackBuilder.build(_ input: ContextPackInput,
    estimator: (any ContextTokenEstimating)? = nil,
    tuning: RagRuntimeTuning? = nil) throws -> PreparedContextRequest
// Only the typed overloads change defaults. Legacy topK adapters are unchanged.
public func Retriever.search(notebookId: Int64, query: String, scope: RetrievalScope,
    fetchK: Int? = nil, includeVectors: Bool = true) async throws -> PinnedRetrievalCandidates
public func Retriever.searchEmbedded(snapshot: ResolvedRetrievalScope, query: String,
    queryVector: [Float]?, fetchK: Int? = nil) async throws -> PinnedRetrievalCandidates
```

```csharp
public sealed record RagRuntimeTuning {
    public int FetchK { get; } public int TopK { get; } public int EvidenceShareBp { get; }
    public RagRuntimeTuning(int fetchK,int topK,int evidenceShareBp);
    public static RagRuntimeTuning V1 { get; }
    public static RagRuntimeTuning DecodeDecision(ReadOnlySpan<byte> bytes);
    public static RagRuntimeTuning Bundled();
}
public static PackBudgetResult ContextPackAlgorithms.Budget(PackBudgetInput input,int evidenceShareBp=6000);
public static PreparedContextRequest ContextPackBuilder.Build(ContextPackInput input,
    IContextTokenEstimator? estimator=null,RagRuntimeTuning? tuning=null);
public Task<PinnedRetrievalCandidates> Retriever.SearchAsync(long notebookId,string query,RetrievalScope scope,
    int? fetchK=null,bool includeVectors=true,CancellationToken ct=default);
public Task<PinnedRetrievalCandidates> Retriever.SearchEmbeddedAsync(ResolvedRetrievalScope snapshot,string query,
    float[]? queryVector,int? fetchK=null,CancellationToken ct=default);
```

- [ ] **Step 1: Write the red shared tuning test.** Task1 adds `kind:"tuning"` rows to `benchmark-run-v1`: pending→32/16/6000; accepted→48/24/7000; fetchK<topK, topK0, share10001→invalidTuning. The accepted row is synthetic test data, not the model decision. Also append `tuning-zero-cap` with the budget input and expected empty evidence/citations to that fixture.

```swift
final class RagRuntimeTuningTests: XCTestCase {
    func testDecisionParametersFromSharedCases() throws {
        let rows = try SharedFixtures.json("contracts/benchmark-run-v1.json")["cases"] as! [[String:Any]]
        for row in rows where row["kind"] as? String == "tuning" {
            let bytes = try JSONSerialization.data(withJSONObject: row["input"]!)
            if row["error"] != nil {
                XCTAssertThrowsError(try RagRuntimeTuning.decodeDecision(bytes)); continue
            }
            let value = try RagRuntimeTuning.decodeDecision(bytes)
            let expected = row["expected"] as! [String:Int]
            XCTAssertEqual(value.fetchK, expected["fetchK"])
            XCTAssertEqual(value.topK, expected["topK"])
            XCTAssertEqual(value.evidenceShareBp, expected["evidenceShareBp"])
        }
    }
    func testTuningCannotCreateEvidenceAtZeroCap() throws {
        var input = try ContextPackFixtures.input("basic-cs")
        input.evidenceBudgetCap = 0
        let tuned = try RagRuntimeTuning(fetchK:48,topK:24,evidenceShareBp:7000)
        let request = try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning:tuned)
        XCTAssertTrue(request.citationMap.isEmpty)
        XCTAssertFalse(request.messages.flatMap(\.sections).contains { $0.kind == "evidence" })
    }
}
```

Run `swift test --filter RagRuntimeTuningTests` → **FAIL: type/overload absent**. Add invalid constructor tests and a fixture loop that proves the v1 resource parameters equal all three frozen constants; accepted runtime params must equal constants-v2 when that file exists, otherwise v1. Do not infer tuned values from README prose.

- [ ] **Step 2: Implement immutable tuning and narrow call-site changes.**

```swift
public init(fetchK: Int, topK: Int, evidenceShareBp: Int) throws {
    guard fetchK >= topK, topK > 0, fetchK <= 1024,
          (0...10000).contains(evidenceShareBp) else { throw RagTuningError.invalidTuning }
    self.fetchK = fetchK; self.topK = topK; self.evidenceShareBp = evidenceShareBp
}
public static func decodeDecision(_ data: Data) throws -> RagRuntimeTuning {
    struct Envelope: Decodable { let status: String; let parameters: RagRuntimeTuning? }
    let value = try JSONDecoder().decode(Envelope.self,from:data)
    if value.status == "pending" { return .v1 }
    guard value.status == "accepted", let p = value.parameters else { throw RagTuningError.invalidTuning }
    return try RagRuntimeTuning(fetchK:p.fetchK,topK:p.topK,evidenceShareBp:p.evidenceShareBp)
}
```

Give `RagRuntimeTuning` a custom `init(from:)` that delegates to the validating initializer; synthesized decoding must not bypass validation. `bundled()` reads `embedding-decision-v1.json` from Bundle.module's Benchmark directory. Declare `RagTuningError: Error { case invalidTuning }`. In `budget`, validate evidenceShareBp0…10000, replace only the evidence target's v1 share with the supplied value; preserve all existing zero/truncation/redistribution/map conditions. In `build`, resolve `let tuning = try suppliedTuning ?? RagRuntimeTuning.bundled()` and pass its evidenceShareBp to budget. Keep input.fetchK/topK explicit: the coordinator sets them from its captured tuning; tests or benchmark options may pass other valid values.

Typed retriever overloads resolve their optional fetchK once using bundled tuning, before validation, then pass that concrete integer throughout. Preserve the empty-selection fast path before resource/SQL/provider access; validate an explicitly supplied nonpositive value before returning the empty pool. `searchEmbedded` uses its own supplied value if present. Replace no legacy default8 behavior. Add an internal initializer closure `defaultFetchK: @Sendable () throws -> Int = { try RagRuntimeTuning.bundled().fetchK }` to Retriever only if needed for the regression test; fake returns48 and test seeds60 lexical matches, then omitted fetchK gives48, explicit7 gives7, empty scope calls the closure zero times. This helper is a value source, not global mutable test configuration.

Historical v1 builder goldens explicitly pass `tuning:.v1`; their expected fixture output remains byte/structurally unchanged. New production-default test compares to bundled v2 estimator plus bundled tuning. Parameter changes are exercised independently of tokenizer changes.

- [ ] **Step 3: Green and commit.**

```bash
swift test --filter 'RagRuntimeTuningTests|ContextPackBuilderTests|PinnedRetrieverTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/RagRuntimeTuning.swift Sources/AINotebookCore/ContextPackAlgorithms.swift Sources/AINotebookCore/ContextPackBuilder.swift Sources/AINotebookCore/Retriever.swift Tests/AINotebookCoreTests/RagRuntimeTuningTests.swift Tests/AINotebookCoreTests/ContextPackBuilderTests.swift
git commit -m "feat(core): apply benchmark tuning through versioned runtime parameters" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: v1 goldens unchanged, tuned/invalid/zero-budget fixtures green, both full suites green. Put new retrieval default regression in `RagRuntimeTuningTests.swift`, keeping WP5 tests read-only.

### Task 16: [Windows] Apply the same runtime tuning and retain v1 goldens

**Depends on:** 1,11; WP5 typed Retriever and WP8 builder. **Parallel with:** 15,8a/8b/9a/9b,10b/11b. **Files:** new `windows/src/AINotebook.Core/Rag/RagRuntimeTuning.cs`, `windows/tests/AINotebook.Core.Tests/Rag/RagRuntimeTuningTests.cs`; modify `windows/src/AINotebook.Core/Rag/{ContextPackAlgorithms.cs:100,137,ContextPackBuilder.cs:13,Retriever.cs}` (only WP5's new overload defaults), `windows/tests/AINotebook.Core.Tests/Rag/ContextPackBuilderTests.cs:12`. Task11's edits are merged first.

**Interfaces — Consumes:** same shared parameter/decision JSON, existing IContextTokenEstimator and builder. **Produces:** every C# signature in Task15; its Swift signatures define the matching API. No SQLite access is added.

- [ ] **Step 1: Red parity tests.**

```csharp
public sealed class RagRuntimeTuningTests
{
    [Fact] public void SharedDecisionParameters()
    {
        foreach(var row in SharedFixtures.Json("contracts/benchmark-run-v1.json").GetProperty("cases").EnumerateArray())
        {
            if(!row.TryGetProperty("kind",out var kind) || kind.GetString()!="tuning") continue;
            byte[] bytes=Encoding.UTF8.GetBytes(row.GetProperty("input").GetRawText());
            if(row.TryGetProperty("error",out _)) {
                Assert.Throws<RagTuningException>(()=>RagRuntimeTuning.DecodeDecision(bytes)); continue;
            }
            var value=RagRuntimeTuning.DecodeDecision(bytes);
            var expected=row.GetProperty("expected");
            Assert.Equal(expected.GetProperty("fetchK").GetInt32(),value.FetchK);
            Assert.Equal(expected.GetProperty("topK").GetInt32(),value.TopK);
            Assert.Equal(expected.GetProperty("evidenceShareBp").GetInt32(),value.EvidenceShareBp);
        }
    }
    [Fact] public void TunedShareCannotCreateEvidenceAtZeroCap()
    {
        var input=ContextPackFixtures.Input("basic-cs") with { EvidenceBudgetCap=0 };
        var request=ContextPackBuilder.Build(input,new PlaceholderTokenEstimatorV1(),new RagRuntimeTuning(48,24,7000));
        Assert.Empty(request.CitationMap);
        Assert.DoesNotContain(request.Messages.SelectMany(m=>m.Sections),s=>s.Kind=="evidence");
    }
}
```

Use `System.Text`, xUnit, Core.Rag and existing `Helpers.SharedFixtures`. Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~RagRuntimeTuningTests` → **FAIL: missing tuning API**. Add theory cases for constructor validation, unchanged v1 fixture values, production decision/v2 fixture parity, and omitted versus explicit retrieval fetchK with60 real lexical matches. Empty selection must not invoke the injected default supplier.

- [ ] **Step 2: Implement decode, validation and three call sites.**

```csharp
public RagRuntimeTuning(int fetchK,int topK,int evidenceShareBp)
{
    if(fetchK<topK || topK<=0 || fetchK>1024 || evidenceShareBp<0 || evidenceShareBp>10000)
        throw new RagTuningException("invalidTuning");
    FetchK=fetchK; TopK=topK; EvidenceShareBp=evidenceShareBp;
}
public static RagRuntimeTuning DecodeDecision(ReadOnlySpan<byte> bytes)
{
    try {
        using var d=JsonDocument.Parse(bytes.ToArray());
        var root=d.RootElement;
        string? status=root.GetProperty("status").GetString();
        if(status=="pending") return V1;
        if(status!="accepted") throw new RagTuningException("invalidTuning");
        var p=root.GetProperty("parameters");
        return new(p.GetProperty("fetchK").GetInt32(),p.GetProperty("topK").GetInt32(),
            p.GetProperty("evidenceShareBp").GetInt32());
    } catch(Exception e) when(e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException) {
        throw new RagTuningException("invalidTuning");
    }
}
```

Use `V1=new(32,16,6000)`; read the linked `AINotebook.Benchmark.embedding-decision-v1.json` resource. `Budget` validates supplied share and replaces only the target calculation. `Build` resolves tuning once and passes the share; it keeps explicit ContextPackInput fetchK/topK. Typed retriever defaults use nullable int and resolve once after the empty-selection guard, preserving explicit validation and forwarding. Optional injected supplier is `Func<int>? defaultFetchK=null` constructor argument, defaulting to bundled tuning. Store operations retain `_gate`; no database access occurs in parameter loading. Existing builder goldens pass `RagRuntimeTuning.V1` explicitly and keep all current expected bytes.

- [ ] **Step 3: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~RagRuntimeTuningTests|FullyQualifiedName~ContextPackBuilderTests|FullyQualifiedName~PinnedRetrieverTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Rag/RagRuntimeTuning.cs windows/src/AINotebook.Core/Rag/ContextPackAlgorithms.cs windows/src/AINotebook.Core/Rag/ContextPackBuilder.cs windows/src/AINotebook.Core/Rag/Retriever.cs windows/tests/AINotebook.Core.Tests/Rag/RagRuntimeTuningTests.cs windows/tests/AINotebook.Core.Tests/Rag/ContextPackBuilderTests.cs
git commit -m "feat(win-core): apply shared benchmark tuning with v1 compatibility" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: shared tuning values and invariant tests pass, full suites green. Tasks15/16 land before the live decision; a changed accepted resource updates production parameters without a follow-up untested literal edit.


### Task 12: [Shared] Claude runs the hardware experiment, freezes calibration, and records the decision

**Executor:** Claude runs macOS, reviews both reports, and commits the decision; the same Windows CLI runs on a 16 GB Windows reference machine and returns its JSON and Markdown. This is an explicitly human hardware task. No CI job pulls models or reports invented results. **Depends on:** 8a–8c, 9a–9c, 10, 11, 15, 16, WP6 published revision/worker integration and WP8 builder. **Parallel with:** no task editing its data/resources; UI work starts after the accepted decision. A missing Windows report leaves this task and the WP gate pending.

**Files:** Modify `docs/eval/README.md:1` by appending a multilingual section, preserving the historical W-4 report; `tools/contracts/gen_benchmark_fixtures.py` only for its measured-resource import path; `Tests/fixtures/contracts/token-estimate-v2.json` and `Sources/AINotebookCore/Resources/Benchmark/{token-estimate-v2,embedding-decision-v1}.json`. Create `tools/benchmark/{verify_reports,test_verify_reports}.py`, `docs/eval/wp7/{macos,windows}-{calibration,benchmark}.{json,md}`, `docs/eval/wp7/decision.json`; optional sweep outputs owned exclusively by this task are `docs/eval/wp7/sweep/` JSON/Markdown files whose names the exact loop below computes. If tuning changes, create/update unreleased `Tests/fixtures/contracts/constants-v2.json` by the rules below; never edit constants-v1. Temporary databases, model files, tokenizer assets and raw corpus copies are outside git.

**Interfaces — Consumes:** Swift `BenchmarkOptions.parse(_:) throws -> BenchmarkOptions`, `BenchmarkRunner.run(options:) async throws -> BenchmarkReportV1`, `BenchmarkRunner.calibrate(options:) async throws -> TokenCalibrationReportV1`; Windows `BenchmarkOptions.Parse(IReadOnlyList<string>)`, `Task<BenchmarkReportV1> BenchmarkRunner.RunAsync(BenchmarkOptions,CancellationToken)`, `Task<TokenCalibrationReportV1> BenchmarkRunner.CalibrateAsync(BenchmarkOptions,CancellationToken)`. Consume the same JSON schemas as Tasks 1/6/7/8b/9b, with model digest, tokenizer provenance, raw samples and exact CPU/RAM recorded.

**Produces:** `verify_reports(mac:dict, win:dict, calibration:dict) -> list[str]` returns eligible profile IDs in catalog order, raises `ValueError` with a stable code on malformed/incomparable input; CLI `python3 -B tools/benchmark/verify_reports.py --mac FILE --windows FILE --calibration FILE --decision FILE [--write-decision]`. Without `--write-decision`, validate the existing decision and print `WP7 reports verified`; with it, create the full decision draft, then Claude records the selected ID and factual rationale. Final resource schema is `{contract:"embedding-decision",version:1,status:"accepted",profileId,model,dims,queryFormatVersion,docFormatVersion,effectiveLimit,parameters:{fetchK,topK,evidenceShareBp},calibrationSha256,macReportSha256,windowsReportSha256,reason}`. `reason` is a human explanation, never a machine-generated claim of unmeasured quality. Cross-platform recommendation readers consume exactly these names.

- [ ] **Step 1: Write verifier tests before implementing it.** These are deterministic and use the existing shared complete report input; tests never open a service.

```python
import copy
import json
import pathlib
import unittest
from tools.benchmark.verify_reports import verify_reports

ROOT = pathlib.Path(__file__).resolve().parents[2]
class VerifyReportsTests(unittest.TestCase):
    def reports(self):
        f = json.loads((ROOT / 'Tests/fixtures/contracts/benchmark-report-v1.json').read_text())
        c = next(x for x in f['cases'] if x['name'] == 'decision-pair')
        return copy.deepcopy((c['mac'], c['windows'], c['calibration']))
    def test_both_platforms_required(self):
        mac, win, cal = self.reports()
        with self.assertRaisesRegex(ValueError, 'missing_platform'):
            verify_reports(mac, {}, cal)
    def test_threshold_is_strict_and_recomputed(self):
        mac, win, cal = self.reports()
        row = win['candidates'][0]['performance'][0]
        row['samples'] = [dict(queryId=i, embeddingUs=1,
            retrievalUs=300000, hydrationUs=1,endToEndUs=300002) for i in range(200)]
        row['warmP95Us'] = 1  # a summary cannot conceal a failing raw sample
        with self.assertRaisesRegex(ValueError, 'summary_mismatch'):
            verify_reports(mac, win, cal)
    def test_corpus_and_identity_must_match(self):
        mac, win, cal = self.reports()
        win['corpus']['hash'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'incomparable_reports'):
            verify_reports(mac, win, cal)
    def test_only_measured_complete_profiles_qualify(self):
        mac, win, cal = self.reports()
        expected = [x['profileId'] for x in mac['candidates']]
        self.assertEqual(expected, verify_reports(mac, win, cal))
        win['candidates'][0]['citations']['snapshotsCorrect'] -= 1
        self.assertNotIn(expected[0], verify_reports(mac, win, cal))
```

Run `python3 -B -m unittest tools.benchmark.test_verify_reports` → **FAIL: verifier absent**. `decision-pair` is authored in Task 1, with two complete fixture reports, all four performance rows per profile and a fixture-only valid calibration. Tests explicitly allow fixture mode; CLI release verification requires live mode. Add the shared negative cases `unmeasured-counts`, `bad-identity`, `missing-windows`, and undercounted full prompts before implementation.

Verifier implements these comparisons: same corpus/hash/chunker, profile rows/model digests/formats/dimensions, calibration hash, chat model digest, fetchK/topK/evidence share/runtime/output/seed; exact 200 timed samples plus20 warmups for each 100K/200K × concurrent/nonconcurrent row; monotonic nonnegative samples; nearest-rank p50/p95 recomputed from raw samples; genuine overlap and completed writes on concurrent rows. Both reference machines must report 16 GB RAM class (allow OS reporting in decimal or binary units, record raw bytes) and correct OS/CPU class. Reject missing environment fields. Check snapshot citation counts, scoped identities, estimator undercounts and all required phase statuses. No candidate receives a passing gate from null/missing metrics. A 100K row at exactly300000us fails. Quality metrics use their stated found/total denominators; no averaging of rounded per-query percentages.

- [ ] **Step 2: Prepare identical model files and environment.** On each machine, use the same reviewed git commit, a Release CLI, AC power and normal performance mode; close the notebook app and unrelated heavy workloads. Record `ollama --version`, OS version, CPU model, RAM, architecture, acceleration/offload configuration and build commit in reports. Do not force the two machines to claim identical accelerators. Pull this exact list:

```bash
ollama pull nomic-embed-text-v2-moe
ollama pull qwen3-embedding:0.6b
ollama pull bge-m3
ollama pull paraphrase-multilingual
ollama pull llama3.2:3b
```

The last model is the unchanged application default chat model (`AppSettings.swift:89`, `SettingsService.cs:48`) used for prompt calibration and deterministic-temperature answer citation measurements; it is not an eighth embedder candidate. Record full `/api/tags` digests and `/api/show` limits for all five before starting. Tags may move: if Mac and Windows digests differ, synchronize the same Ollama model artifacts and rerun affected rows, do not compare them as one model. No `pull` runs between calibration and benchmarking. Acquire documented tokenizer assets only if provider counts are unavailable; place them under the local manifest described in Task 1 and record immutable upstream revision/hash. The offline counting helper cannot fetch missing assets.

- [ ] **Step 3: Calibrate on Mac, then independently validate on Windows.** Example commands select the unique `ollama serve` process by command line; the CLI rejects an absent/nonpositive PID or remote host for RSS measurements. The PID designates the parent plus descendant model runners. Output directories are created by the CLI; argument parsing must not create them in `--validate-only` mode.

```bash
swift build -c release --product ainotebook-eval
benchmarkOllamaPid=$(ps -axo pid=,command= | awk '$2 ~ /(^|\/)ollama$/ && $3 == "serve" { print $1 }')
case "$benchmarkOllamaPid" in ""|*[!0-9]*) exit 2 ;; esac
.build/release/ainotebook-eval --calibrate --root eval/multilingual --host http://127.0.0.1:11434 --chat-model llama3.2:3b --embedding-counts all --json docs/eval/wp7/macos-calibration.json --out docs/eval/wp7/macos-calibration.md
```

Windows PowerShell, from repository root:

```powershell
dotnet build windows/tools/AINotebook.Eval/AINotebook.Eval.csproj -c Release
dotnet run --no-build -c Release --project windows/tools/AINotebook.Eval -- --calibrate --root eval/multilingual --host http://127.0.0.1:11434 --chat-model llama3.2:3b --embedding-counts all --json docs/eval/wp7/windows-calibration.json --out docs/eval/wp7/windows-calibration.md
```

Expected: exit0, four measured chat-language buckets, nonempty held-out body and full-prompt sets, provenance on every observation, zero held-out undercounts for an accepted fitted table. A measurement failure yields exit1 and an `incomplete` report (usage errors exit2). It does not overwrite the bundled calibration. Compare token counts for the same digests/tokenizer assets and input hashes; any disagreement blocks data publication until explained. Pool training observations from both machines by sample ID only after verifying identical identity/counts; do not count duplicate observations as extra support. Freeze rates from training data only, then evaluate untouched holdout. If a held-out sample undercounts, record the failed experiment and revise the estimator on a new deterministic training/holdout split; never move a failing holdout sample into training and call the original holdout passed. Keep the failed report's hash and reason in the accepted decision provenance.

Import real observations into the generator with `--calibration docs/eval/wp7/macos-calibration.json --windows-calibration docs/eval/wp7/windows-calibration.json`; regenerate the v2 fixture's measured cases and bundled v2 resource without deleting its synthetic boundary cases. `--check` reads those committed reports to reproduce the exact resource bytes. No fixture-only family may enter production resources.

- [ ] **Step 4: Run all seven profiles sequentially at both corpus sizes.** Use the generated accepted calibration resource; a model being installed is not evidence that its tokenizer is calibrated. Baseline parameters remain fetchK32, topK16, evidence share6000, runtime8192, output1024. Keep all seven candidate results, including failures. Each candidate gets its own fresh eval generation and fresh synthetic database; benchmark never opens the user's production database. Do not materialize 200K ×1024 vectors in a second in-memory copy.

```bash
.build/release/ainotebook-eval --benchmark --mode live --root eval/multilingual --profiles all --host http://127.0.0.1:11434 --chat-model llama3.2:3b --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --chunks 100000,200000 --queries 200 --warmup 20 --concurrent both --fetch-k 32 --top-k 16 --evidence-share-bp 6000 --runtime-context 8192 --max-output 1024 --seed 17 --ollama-pid "$benchmarkOllamaPid" --json docs/eval/wp7/macos-benchmark.json --out docs/eval/wp7/macos-benchmark.md
```

```powershell
$ollamaRoots = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "ollama.exe" -and $_.CommandLine -match '(?:^|\s)serve(?:\s|$)' })
if ($ollamaRoots.Count -ne 1) { throw 'Expected exactly one ollama serve process' }
$benchmarkOllamaPid = $ollamaRoots[0].ProcessId
dotnet run --no-build -c Release --project windows/tools/AINotebook.Eval -- --benchmark --mode live --root eval/multilingual --profiles all --host http://127.0.0.1:11434 --chat-model llama3.2:3b --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --chunks 100000,200000 --queries 200 --warmup 20 --concurrent both --fetch-k 32 --top-k 16 --evidence-share-bp 6000 --runtime-context 8192 --max-output 1024 --seed 17 --ollama-pid $benchmarkOllamaPid --json docs/eval/wp7/windows-benchmark.json --out docs/eval/wp7/windows-benchmark.md
```

Expected: every profile has separate lexical/hybrid/topK/candidate/packed metrics, language and case-type breakdowns, exact snapshot/marker/gold-support counters, ingest tokens/s and sampled peak RSS, cold application-cache time and four warm performance rows. `semanticReview` remains explicitly unmeasured until human review; structural citation validity alone does not prove an answer claim. The CLI returns exit0 only when required phases are measured, not merely because the process finished. Unavailable native RSS or failed model rows remain null/incomplete, with diagnostic codes. The user sends both Windows files and calibration files to Claude; this plan grants no permission to send messages or upload files on the user's behalf.

- [ ] **Step 5: Choose and document, with numbers.** Run verifier after collecting both reports:

```bash
python3 -B -m unittest tools.benchmark.test_verify_reports
python3 -B tools/benchmark/verify_reports.py --mac docs/eval/wp7/macos-benchmark.json --windows docs/eval/wp7/windows-benchmark.json --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --decision docs/eval/wp7/decision.json --write-decision
```

Claude reviews every language's packed recall against `paraphrase-768`, cs↔sk failures, absence/empty-scope cases, peak RAM, ingestion rate and both strict100K gates. Proposed selection order: eligible candidates with no per-language packed-recall regression versus baseline; maximize the minimum cs/sk/en/de packed recall across the two platforms; ties use lower dimensions, then lower worst-machine combined RSS, then profile ID scalar order. This is an explicit experiment decision rule for Claude to approve, not a WP0 accuracy threshold. Do not choose a winner if no candidate clears correctness and performance; retain pending status and report the measured blocker. Review generated answers for every absent/empty-scope query and every incorrect/unsupported cited marker, plus the first five answer queries per language in scalar query-ID order; record reviewed counts and failure categories separately from the automatic counters.

Append `## Multilingual folder RAG — WP7` to README with linked Mac/Windows reports, exact hardware, model IDs/digests/dimensions/formats/input ceilings/pooling policy, corpus and calibration hashes, a seven-row comparison table with each platform's metrics, the chosen default and rationale, per-language results, the estimator's training/holdout counts and worst error, and fresh-install/explicit-reindex behavior. Preserve the historical W-4 reranker conclusion as historical. Correct its broad “eval never runs in CI” wording locally to distinguish deterministic multilingual fixtures from live model runs. State whether parameters remain32/16/6000.

If measured tuning is needed, do not rewrite v1: run a prespecified development sweep of fetchK32/48/64, topK16/24 subject to topK≤fetchK, and evidenceShare6000/7000 on the same build. Retain the sweep reports. Select on a deterministic query split by SHA256(queryId) parity and confirm once on the other half. `constants-v2.json` copies every v1 section and changes only approved values; if WP4 already created unreleased v2, merge only these three keys and preserve detector changes. The runtime loaders from Tasks15/16 read the accepted decision parameters. Stage the candidate parameters in a local decision resource for the confirmatory run, run both suites against constants-v2, then freeze that same resource only after both hardware confirmations pass. Never change perf thresholds or override zero-budget/truncation/map rules. A sweep-only win is not the final release report.

The optional Mac sweep is this exact loop; Windows uses the identical12 combinations by replacing only the executable prefix with the `dotnet run --no-build -c Release --project windows/tools/AINotebook.Eval --` prefix above. Each combination retains all seven candidates and uses the same corpus/query split, not independently generated test data. Claude records development/confirmation partition metrics in `decision.json`.

```bash
for benchmarkFetch in 32 48 64; do
  for benchmarkTop in 16 24; do
    for benchmarkShare in 6000 7000; do
      .build/release/ainotebook-eval --benchmark --mode live --root eval/multilingual --profiles all --host http://127.0.0.1:11434 --chat-model llama3.2:3b --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --chunks 100000,200000 --queries 200 --warmup 20 --concurrent both --fetch-k "$benchmarkFetch" --top-k "$benchmarkTop" --evidence-share-bp "$benchmarkShare" --runtime-context 8192 --max-output 1024 --seed 17 --ollama-pid "$benchmarkOllamaPid" --json "docs/eval/wp7/sweep/macos-f${benchmarkFetch}-t${benchmarkTop}-e${benchmarkShare}.json" --out "docs/eval/wp7/sweep/macos-f${benchmarkFetch}-t${benchmarkTop}-e${benchmarkShare}.md"
    done
  done
done
```


- [ ] **Step 6: Freeze the decision and verify.** Copy the accepted decision JSON into the production resource through the generator, not an independent edit. Run without `--write-decision` to validate the final selected ID, hashes and parameters. Public resources contain only profile/calibration metadata, never machine paths or tokens. Before the commit run both full suites; use the actual totals in the handoff.

```bash
python3 -B tools/contracts/gen_benchmark_fixtures.py --check
python3 -B -m unittest tools.benchmark.test_contracts tools.benchmark.test_tokenize_offline tools.benchmark.test_verify_reports
python3 -B tools/benchmark/verify_reports.py --mac docs/eval/wp7/macos-benchmark.json --windows docs/eval/wp7/windows-benchmark.json --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --decision docs/eval/wp7/decision.json
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/benchmark/verify_reports.py tools/benchmark/test_verify_reports.py tools/contracts/gen_benchmark_fixtures.py Tests/fixtures/contracts/token-estimate-v2.json Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json Sources/AINotebookCore/Resources/Benchmark/embedding-decision-v1.json docs/eval/README.md docs/eval/wp7
git commit -m "docs(eval): record multilingual benchmark and new-install embedding decision" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

If and only if the tuning branch was exercised, include `Tests/fixtures/contracts/constants-v2.json` in the explicit staged paths. The decision data and the already implemented Tasks15/16 form one integration gate; do not ship an accepted tuned resource with untuned runtime code.


### Task 13: [Swift-UI] Persist the selected profile and expose the measured recommendation

**Depends on:** 10,10b,10c,12,15; WP8 Swift UI merged; WP2 Task10 and WP3 startup changes merged. **Parallel with:** 14. **Files:** existing Sources/AINotebookCore/AppSettings.swift:42,90, Providers/ProviderSelection.swift:9,41, Localization.swift:102,365,603; Sources/AINotebookApp/AINotebookApp.swift:20,29,45,58, SettingsView.swift:184,271,411, Onboarding/PickModelsStepView.swift:9, ChatView.swift:540; Tests/AINotebookCoreTests/AppSettingsTests.swift:62; new Tests/AINotebookCoreTests/EmbeddingRecommendationUITests.swift.

**Interfaces — Consumes:** Core recommendation/rebuild/journal/profile-aware worker APIs. **Produces:**

```swift
// AppSettings remains @MainActor; init(defaults:) retains conservative legacy fallback.
public convenience init(defaults: UserDefaults, evidence: EmbeddingInstallEvidence,
                        decision: EmbeddingDecision) throws
@Published public private(set) var selectedEmbeddingProfileId: String?
public var embeddingSelection: EmbeddingSelection { get }
public func applyEmbeddingSelection(_ selection: EmbeddingSelection) throws
// ProviderSettingsKeys.embeddingSelectionV2 = "selectedEmbeddingSelectionV2".
public func DefaultsProviderSelection.embeddingProfileSelection() -> EmbeddingSelection
// Native holder in AINotebookApp.swift:
@MainActor final class EmbeddingRecommendationHolder: ObservableObject {
    let service: EmbeddingRebuildService
    @Published var isRebuilding: Bool
    @Published var errorCode: String?
    func start(_ selection: EmbeddingSelection)
    func cancel()
}
```

```csharp
// Exact platform twins implemented in Task14.
public string? ISettingsService.SelectedEmbeddingProfileId { get; }
public EmbeddingSelection ISettingsService.EmbeddingSelection { get; }
public void ISettingsService.ApplyEmbeddingSelection(EmbeddingSelection selection);
internal SettingsService(string path,EmbeddingInstallEvidence evidence,EmbeddingDecision decision);
public Task SettingsViewModel.RebuildEmbeddingAsync(EmbeddingSelection requested,CancellationToken ct=default);
public void SettingsViewModel.CancelEmbeddingRebuild();
```

Persist one Codable selection bundle containing providerId, model and profileId. Raw model cannot distinguish Nomic256/768 or Qwen256/512/1024. The bundle becomes authoritative; old provider/model keys remain compatibility mirrors. Manual provider/model changes replace the bundle with profileId null, preserving the explicit custom/legacy path. A short applyingEmbeddingSelection guard prevents programmatic application from triggering manual-change handlers.

- [ ] **Step 1: Red fresh-install, preservation and dimension-persistence tests.** Append these to AppSettingsTests; makeSuite is its existing isolated UserDefaults helper.

```swift
func testFreshInstallPersistsProfileAndRouterReadsSameSelection() throws {
    let defaults = makeSuite("test.wp7.fresh.\(UUID().uuidString)")
    let e = EmbeddingInstallEvidence(databaseExists:false,preferencesExist:false,
        completedOnboarding:false,explicitSelection:false,convertedChatOnly:false)
    let s = try AppSettings(defaults:defaults,evidence:e,
        decision:EmbeddingDecision(status:"accepted",profileId:"nomic-v2-256"))
    XCTAssertEqual(s.selectedEmbeddingProfileId,"nomic-v2-256")
    XCTAssertEqual(s.selectedEmbeddingModel,"nomic-embed-text-v2-moe")
    XCTAssertEqual(DefaultsProviderSelection(defaults:defaults).embeddingProfileSelection(),s.embeddingSelection)
    XCTAssertEqual(AppSettings(defaults:defaults).embeddingSelection,s.embeddingSelection)
}
func testExistingDatabaseWithoutPreferencesKeepsLegacySelection() throws {
    let defaults = makeSuite("test.wp7.db.\(UUID().uuidString)")
    let e = EmbeddingInstallEvidence(databaseExists:true,preferencesExist:false,
        completedOnboarding:false,explicitSelection:false,convertedChatOnly:false)
    let s = try AppSettings(defaults:defaults,evidence:e,
        decision:EmbeddingDecision(status:"accepted",profileId:"nomic-v2-256"))
    XCTAssertEqual(s.selectedEmbeddingModel,"nomic-embed-text")
    XCTAssertNil(s.selectedEmbeddingProfileId)
    XCTAssertNil(defaults.object(forKey:"selectedEmbeddingSelectionV2"))
}
func testExistingExplicitSelectionAndPreferencesAreUnchanged() throws {
    let defaults = makeSuite("test.wp7.old.\(UUID().uuidString)")
    defaults.set("provider-custom",forKey:"selectedEmbeddingProviderId")
    defaults.set("custom:model",forKey:"selectedEmbeddingModel")
    let before = defaults.dictionaryRepresentation() as NSDictionary
    let e = EmbeddingInstallEvidence(databaseExists:true,preferencesExist:true,
        completedOnboarding:true,explicitSelection:true,convertedChatOnly:false)
    let s = try AppSettings(defaults:defaults,evidence:e,
        decision:EmbeddingDecision(status:"accepted",profileId:"nomic-v2-256"))
    XCTAssertEqual(s.embeddingSelection,
        EmbeddingSelection(providerId:"provider-custom",model:"custom:model",profileId:nil))
    XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary,before)
}
func testDimensionChoicePersistsAndManualModelClearsProfile() throws {
    let defaults = makeSuite("test.wp7.dims.\(UUID().uuidString)")
    let s = AppSettings(defaults:defaults)
    try s.applyEmbeddingSelection(EmbeddingRecommendation.selection(profileId:"nomic-v2-256"))
    try s.applyEmbeddingSelection(EmbeddingRecommendation.selection(profileId:"nomic-v2-768"))
    XCTAssertEqual(AppSettings(defaults:defaults).selectedEmbeddingProfileId,"nomic-v2-768")
    s.selectedEmbeddingModel="custom:model"
    XCTAssertNil(s.selectedEmbeddingProfileId)
    XCTAssertNil(DefaultsProviderSelection(defaults:defaults).embeddingProfileSelection().profileId)
}
```

Run swift test --filter 'AppSettingsTests|EmbeddingRecommendationUITests' → **FAIL: missing init/profile methods**. Preserve testSelectedModelsDefaults with standalone init(defaults:): unknown install history intentionally keeps the legacy fallback; the explicit evidence-aware test covers the changed fresh bootstrap.

- [ ] **Step 2: Implement bootstrap before creating providers/workers.** Resolve StorePath.production and capture file existence before NotebookStore is opened. Capture the app's persistent UserDefaults domain before constructing AppSettings. A nonempty domain, database, explicit selection, onboarding completion, stored bundle or WP2 conversion marker means existing install. Do not detect production first run with dictionaryRepresentation: registered/system defaults are included. Construct AppSettings with evidence, open NotebookStore with WP3's configured legacy/composite key, create rebuild service, run recover synchronously, then construct router/retriever/worker. The rebuild stage closure captures a later-initialized router but is not called by recover. IO recovery failures remain visible and block model-changing actions/provider work; no reset to recommendation.

applyEmbeddingSelection validates profile/model equality, encodes one complete Data object, persists the authoritative bundle and old-key mirrors, then publishes all three projections under the guard. Its rebuild callback must preserve the journal until preference persistence is confirmed; do not silently swallow persistence failures. For the rebuild callback, call defaults.synchronize() after the complete bundle write and require its Bool result before returning success; failure throws settingsWriteFailed so the journal remains. This explicit persistence boundary is used only for a model-switch commit, not every ordinary preference update. Startup replay applies the complete bundle idempotently.

Create the recommendation holder in AINotebookApp and inject it as an environment object. It retains its Task across Settings dismissal; cancel cancels that task; published busy/error state comes from completion. Existing worker/import callbacks use Task10c's profile-aware branch with the same DefaultsProviderSelection bundle. Startup must not automatically reindex existing installations.

- [ ] **Step 3: Bind Settings and onboarding, including every localization key.** In SettingsView's embedding section add an @EnvironmentObject recommendation holder, recommendation label (model + dimensions), explanatory text, Use recommendation button, indeterminate ProgressView while busy and cancel button. The use button opens confirmation and then passes the captured complete EmbeddingSelection to holder.start. Reading/opening the view never writes settings. For a profiled current selection, reembedAll at SettingsView.swift:411 uses the batch rebuild service. For profileId nil, retain exactly try store.deleteAllEmbeddings(model: routerHolder.selection.embeddingKey()); await embedderHolder.worker.kick(). WP3 plan:1392 redefines that method as a safe staged legacy successor; it leaves active/pinned data intact. Do not label legacy vectors with a catalog profile.

The recommendation action holds its typed selection in @State until confirmed publication, while existing manual provider/model controls retain the WP2/WP3 confirmed legacy-selection flow at :184/:234/:251. Applying a manual selection clears any profile ID. Preserve WP2 privacy gates, embedding-capable filtering and the independent conversion notice. For the new recommendation confirmation, Cancel, Escape and outside-click write nothing. Disable model/provider/recommendation controls while busy. A persistence error after activation shows the distinct recovery text/action, not the old-index-preserved message.

PickModelsStepView.swift:9 replaces fixed embedChoices with complete typed choices: recommendation first, current selection if distinct, legacy nomic-embed-text and mxbai-embed-large, deduplicated by profile ID or legacy provider/model pair. Include dims in profile labels; select the existing typed selection without writing. Apply only a user's actual choice. Existing OnboardingViewModel.swift:69–70 reads selectedEmbeddingModel for pulling, so no edit is needed there.

Add these keys to AppText.Key and both switch arms; Task14 adds PascalCase enum names and the same camelCase .resw keys. Swift placeholders are %@/%d, Windows {0}/{1}.

| Key | EN | CS |
|---|---|---|
| embeddingRecommendedFormat | Recommended: %@ (%d dimensions) | Doporučeno: %@ (%d rozměrů) |
| embeddingRecommendationBody | Measured for multilingual search. Your current index stays available while the replacement is built. | Ověřeno pro vícejazyčné vyhledávání. Při vytváření nového indexu zůstává současný index dostupný. |
| embeddingUseRecommended | Use recommendation and reindex | Použít doporučení a přeindexovat |
| embeddingRebuildConfirm | Build replacement indexes for all notebooks with this model? The switch happens only when every index is ready. | Vytvořit nové indexy všech zápisníků tímto modelem? Přepnutí proběhne až po dokončení všech indexů. |
| embeddingRebuilding | Building replacement indexes… | Vytváření nových indexů… |
| embeddingCancelRebuild | Cancel rebuild | Zrušit přeindexování |
| embeddingRebuildFailed | The rebuild failed. Your previous indexes are still active. | Přeindexování selhalo. Původní indexy zůstávají aktivní. |
| embeddingRecoveryNeeded | The new indexes are ready. Retry saving the model selection to finish the switch. | Nové indexy jsou připravené. Dokončete přepnutí opakováním uložení modelu. |
| embeddingRetrySelection | Finish model switch | Dokončit přepnutí modelu |

Replace existing reembedConfirm text at Localization.swift:366/:604 with the new nondestructive confirmation. Add a test in EmbeddingRecommendationUITests iterating these nine AppText.Key cases under English/Czech, asserting nonempty and different from the raw key, then exact formatting:

```swift
func testRecommendationLabelBothLanguages() {
    XCTAssertEqual(String(format:AppText(language:.english).string(.embeddingRecommendedFormat),
        "nomic-embed-text-v2-moe",256),"Recommended: nomic-embed-text-v2-moe (256 dimensions)")
    XCTAssertEqual(String(format:AppText(language:.czech).string(.embeddingRecommendedFormat),
        "nomic-embed-text-v2-moe",256),"Doporučeno: nomic-embed-text-v2-moe (256 rozměrů)")
}
```

Before WP8 prepareCurrentDraft creates PackIntentKey in ChatView.swift (planned WP8 method, current send at :540), load one RagRuntimeTuning.bundled() value and set that same intent fetchK/topK from it; do not leave 32/16 literals. The resulting intent key must include these values. Explicit test/benchmark PackIntent values remain unchanged. No other chat flow changes belong here.

- [ ] **Step 4: Claude verifies the app; green and commit.** Manual checklist: fresh temp installation persists chosen profile/dims; existing DB without preferences stays legacy; custom selection and WP2 notice survive; onboarding selects/pulls correct raw model; EN↔CS updates labels; opening/declining/Escape writes nothing; missing model fails with old query still working; cancel midbuild preserves active IDs; successful all-notebook switch changes all IDs and bundle; crash after activation recovers before queries; ordinary subsequent import uses chosen document format/dims; Nomic256↔768 yields different identities.

```bash
swift test --filter 'AppSettingsTests|EmbeddingRecommendationUITests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
swift build --product AINotebookApp
git add Sources/AINotebookCore/AppSettings.swift Sources/AINotebookCore/Providers/ProviderSelection.swift Sources/AINotebookCore/Localization.swift Sources/AINotebookApp/AINotebookApp.swift Sources/AINotebookApp/SettingsView.swift Sources/AINotebookApp/Onboarding/PickModelsStepView.swift Sources/AINotebookApp/ChatView.swift Tests/AINotebookCoreTests/AppSettingsTests.swift Tests/AINotebookCoreTests/EmbeddingRecommendationUITests.swift
git commit -m "feat(mac): measured embedding recommendation and safe reindex action" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: both Core suites and macOS build green; Claude records every manual item.

### Task 14: [Win-UI] Windows fresh default, recommendation bindings and recovery

**Depends on:** 11,11b,11c,12,16; WP8 WinUI merged; WP2 Task11/WP3 Task12 merged. **Parallel with:** 13. **Files:** windows/src/AINotebook.App/App.xaml.cs:56,62,84; Services/SettingsService.cs:18,37,77, ISettingsService.cs:13, StringKey.cs:30; ViewModels/SettingsViewModel.cs:49,248, ViewModels/ChatViewModel.cs:419; Views/SettingsDialog.xaml:73, SettingsDialog.xaml.cs:50,128,290; Onboarding/PickModelsStep.xaml:13, PickModelsStep.xaml.cs:10,28; Strings/en-US/Resources.resw:317, Strings/cs-CZ/Resources.resw:317; windows/tests/AINotebook.App.Tests/SettingsServiceTests.cs:20, LocalizedStringsTests.cs:16, new EmbeddingRecommendationTests.cs. All relative App paths are under windows/src/AINotebook.App.

**Interfaces — Consumes:** C# recommendation/rebuild/journal/profile worker APIs; existing ISettingsService. Swift twins are AppSettings/holder in Task13. **Produces:**

```csharp
public string? ISettingsService.SelectedEmbeddingProfileId { get; }
public EmbeddingSelection ISettingsService.EmbeddingSelection { get; }
public void ISettingsService.ApplyEmbeddingSelection(EmbeddingSelection selection);
internal SettingsService(string path,EmbeddingInstallEvidence evidence,EmbeddingDecision decision);
public bool SettingsViewModel.IsEmbeddingRebuilding { get; }
public string? SettingsViewModel.EmbeddingRebuildErrorCode { get; }
public EmbeddingSelection? SettingsViewModel.RecommendedEmbedding { get; }
public Task SettingsViewModel.RebuildEmbeddingAsync(EmbeddingSelection requested,CancellationToken ct=default);
public void SettingsViewModel.CancelEmbeddingRebuild();
public void SettingsViewModel.FinishEmbeddingSelection();
```

- [ ] **Step 1: Red persistence/localization tests.** Add to the existing App test files:

```csharp
[Fact] public void Fresh_profile_persists_but_existing_database_keeps_legacy()
{
    var d=new EmbeddingDecision("embedding-decision",1,"accepted","nomic-v2-256");
    var fresh=new EmbeddingInstallEvidence(false,false,false,false,false);
    string path=PathFor("wp7-fresh");
    var s=new SettingsService(path,fresh,d);
    Assert.Equal("nomic-v2-256",s.SelectedEmbeddingProfileId);
    Assert.Equal("nomic-embed-text-v2-moe",s.SelectedEmbeddingModel);
    Assert.Equal(s.EmbeddingSelection,new SettingsService(path).EmbeddingSelection);
    var old=new SettingsService(PathFor("wp7-db"),fresh with { DatabaseExists=true },d);
    Assert.Equal("nomic-embed-text",old.SelectedEmbeddingModel);
    Assert.Null(old.SelectedEmbeddingProfileId);
}
[Fact] public void Corrupt_existing_file_is_not_a_fresh_install()
{
    string path=PathFor("wp7-corrupt"); File.WriteAllText(path,"{ not json");
    var s=new SettingsService(path,new(false,true,false,false,false),
        new("embedding-decision",1,"accepted","nomic-v2-256"));
    Assert.Equal("nomic-embed-text",s.SelectedEmbeddingModel);
    Assert.Null(s.SelectedEmbeddingProfileId);
    Assert.Equal("{ not json",File.ReadAllText(path));
}
[Fact] public void Dimension_profile_roundtrips_and_manual_model_clears_it()
{
    string path=PathFor("wp7-dims"); var s=new SettingsService(path);
    s.ApplyEmbeddingSelection(EmbeddingRecommendation.Selection("nomic-v2-256"));
    s.ApplyEmbeddingSelection(EmbeddingRecommendation.Selection("nomic-v2-768"));
    Assert.Equal("nomic-v2-768",new SettingsService(path).SelectedEmbeddingProfileId);
    s.SelectedEmbeddingModel="custom:model";
    Assert.Null(new SettingsService(path).SelectedEmbeddingProfileId);
}
// In LocalizedStringsTests (existing System.Xml.Linq import):
[Fact] public void Embedding_recommendation_resources_exist_and_format_correctly()
{
    string[] keys=["embeddingRecommendedFormat","embeddingRecommendationBody","embeddingUseRecommended",
        "embeddingRebuildConfirm","embeddingRebuilding","embeddingCancelRebuild","embeddingRebuildFailed",
        "embeddingRecoveryNeeded","embeddingRetrySelection"];
    foreach(string file in new[]{"en.resw","cs.resw"})
    {
        var rows=XDocument.Load(file).Root!.Elements("data")
            .ToDictionary(x=>(string)x.Attribute("name")!,x=>(string)x.Element("value")!);
        foreach(string key in keys) Assert.False(string.IsNullOrWhiteSpace(rows[key]));
        string formatted=string.Format(System.Globalization.CultureInfo.InvariantCulture,
            rows["embeddingRecommendedFormat"],"nomic-embed-text-v2-moe",256);
        Assert.Equal(file=="en.resw" ? "Recommended: nomic-embed-text-v2-moe (256 dimensions)"
            : "Doporučeno: nomic-embed-text-v2-moe (256 rozměrů)",formatted);
    }
}
```

Run on Windows dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64 --filter 'FullyQualifiedName~SettingsServiceTests|FullyQualifiedName~EmbeddingRecommendationTests|FullyQualifiedName~LocalizedStringsTests' → **FAIL: missing profile API/keys**. Add AINotebook.Core.Rag import for new types. LocalizedStringsTests:16 hardcodes239 today; increment the actual merged baseline by9, retaining exact key-count/parity/nonempty checks. WP2/WP8 may have raised that baseline. App tests cannot execute on macOS.

- [ ] **Step 2: Implement atomic settings and first-run evidence before DI.** SettingsFile gains EmbeddingSelectionV2; load it before legacy model/provider keys. ApplyEmbeddingSelection validates the catalog, builds a complete copy, writes via same-directory unique temp + FileStream.Flush(true) + File.Move(overwrite:true), then updates all fields/properties and raises notifications. It must throw on failure: existing Save at SettingsService.cs:77 swallows errors and is unsuitable for a rebuild commit. Failed write keeps old file, old in-memory selection and recovery journal. Unrelated settings saves preserve the bundle; manual provider/model changes clear profile ID; WP2 conversion-notice fields remain independent.

App.ConfigureServices captures settings-file and db-file existence before construction/resolution. A malformed existing settings file still disqualifies fresh install. Instantiate evidence-aware settings, open NotebookStore with WP3 configured key, create rebuild service, recover, then resolve router/worker. The stage delegate uses the immutable requested session and Task9 StageAsync. The profile-aware worker reads the same typed selection. No HTTP request code is added outside Providers.

- [ ] **Step 3: Bind exact controls/events and view-model state.** Add to SettingsDialog.xaml's embedding StackPanel: EmbeddingRecommendationText (TextBlock, Wrap), EmbeddingRecommendationBodyText (TextBlock, Wrap), UseRecommendedEmbeddingButton (Click="OnUseRecommendedEmbedding"), EmbeddingRebuildProgress (ProgressRing), EmbeddingRebuildStatusText (TextBlock), CancelEmbeddingRebuildButton (Click="OnCancelEmbeddingRebuild"), FinishEmbeddingSelectionButton (Click="OnFinishEmbeddingSelection"). Initially collapse progress/cancel/finish.

Keep the dialog's manual code-behind binding convention. ApplyLocalizedText sets every Task13 key, using {0}/{1} for the recommendation. OnVmChanged handles IsEmbeddingRebuilding/EmbeddingRebuildErrorCode/RecommendedEmbedding, updates progress visibility, disables embedding provider/model controls during rebuild, enables cancel only before publication, and displays localized failure versus recovery text in ErrorBar. Use Application.Current.Resources["AccentButtonStyle"] for imperative style lookup.

OnUseRecommendedEmbedding captures the complete typed choice and shows the localized confirmation through the current hide/show nested-ContentDialog pattern at SettingsDialog.xaml.cs:290. Primary calls RebuildEmbeddingAsync; cancel/Escape writes nothing. The ViewModel owns its CTS and injected rebuild service; cancellation is handled separately from failure, busy state resets in finally. OnCancelEmbeddingRebuild cancels; OnFinishEmbeddingSelection calls recover and refreshes visible settings only after success. Do not trigger writes/rebuild on dialog open. For a profiled current selection, ReembedAllAsync at SettingsViewModel.cs:248 invokes the batch service. For profileId null, retain the exact WP3 safe path: await Task.Run(() => _store.DeleteAllEmbeddings(_router.CurrentEmbeddingKey)); _worker.Kick(); its successor keeps old active/pinned data. Existing manual provider/model controls retain WP2/WP3 semantics and clear profile ID; new recommendation confirmation restores controls under _suppress on cancellation and preserves privacy/capability filtering.

Add all nine PascalCase StringKey entries and exact Task13 EN/CS strings in both .resw files, with {0}/{1} placeholders. Replace existing reembedConfirm destructive text at both resource files:320.

In PickModelsStep.xaml.cs replace fixed EmbedChoices with recommendation/current/legacy typed rows; always include current custom selection; select under an _initializing flag and ignore selection events during setup. Add DisplayMemberPath="Label" to EmbedCombo. The row class in that code-behind file has a public parameterless constructor and non-required defaults for WinUI XamlTypeInfo. On user change, ApplyEmbeddingSelection receives the row's complete bundle. Existing onboarding pull code consumes the raw selected model unchanged.

Add App tests in EmbeddingRecommendationTests using an injected Core in-memory rebuild service: OpeningRecommendationDoesNotPersist; CancelKeepsOldSelectionAndActiveGeneration; SuccessfulRebuildPersistsProfile; SelectionSaveFailureExposesFinishAction. Avoid real router/Ollama dependencies by extracting a narrow internal recommendation controller into SettingsViewModel.cs with injected current/persist/stage callbacks; assert public busy/error/selected properties and real temp settings JSON. The Core rebuild tests already exercise staged publication; these verify the UI-facing state and save callbacks.

In WP8 PrepareContext/intent creation in ChatViewModel.cs (current SendCoreAsync at :419), capture RagRuntimeTuning.Bundled() and set FetchK/TopK before PackIntentKey creation; preserve explicit benchmark/test intent values. This prevents stale UI defaults after accepted constants-v2 tuning. No XAML change is required for these internal retrieval values.

- [ ] **Step 4: Windows CI and manual verification, then commit.** Verify unpackaged launch; fresh profile/dims; old/corrupt settings preservation; EN/CS live switch; cancel nested confirmation; missing model; busy/cancel controls; all notebooks switching together; postactivation restart recovery before providers; ordinary import retaining profile formats/dims.

```powershell
dotnet test windows/tests/AINotebook.Core.Tests
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64 --filter "FullyQualifiedName~SettingsServiceTests|FullyQualifiedName~EmbeddingRecommendationTests|FullyQualifiedName~LocalizedStringsTests"
dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64
```

On macOS run both portable suites before committing; do not claim the Windows App commands ran locally.

```bash
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.App/App.xaml.cs windows/src/AINotebook.App/Services/SettingsService.cs windows/src/AINotebook.App/Services/ISettingsService.cs windows/src/AINotebook.App/Services/StringKey.cs windows/src/AINotebook.App/ViewModels/SettingsViewModel.cs windows/src/AINotebook.App/ViewModels/ChatViewModel.cs windows/src/AINotebook.App/Views/SettingsDialog.xaml windows/src/AINotebook.App/Views/SettingsDialog.xaml.cs windows/src/AINotebook.App/Onboarding/PickModelsStep.xaml windows/src/AINotebook.App/Onboarding/PickModelsStep.xaml.cs windows/src/AINotebook.App/Strings/en-US/Resources.resw windows/src/AINotebook.App/Strings/cs-CZ/Resources.resw windows/tests/AINotebook.App.Tests/SettingsServiceTests.cs windows/tests/AINotebook.App.Tests/LocalizedStringsTests.cs windows/tests/AINotebook.App.Tests/EmbeddingRecommendationTests.cs
git commit -m "feat(win-app): measured embedding recommendation and recoverable reindex UI" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: both portable Core suites green; Windows CI App build/all App tests green, with no package identity APIs.

### Task 17: [Swift] Inject calibrated estimator into the frozen production chat turn

**Depends on:** Tasks4,6,10,13,15; WP2 sessions, WP8 Core/UI integration merged. **Parallel with:**18 and disjoint Windows tasks after their dependencies; never4/13 or an upstream owner of these paths. **Files:** only Task17 row. Shared fixture is read-only.

**Interfaces — Consumes:** `OllamaClient.listModels() async throws -> [OllamaModel]` (real `OllamaClient.swift:37`); model name/digest at `OllamaModel.swift:3–8`; Task6 `TokenFamilyBinding`, `TokenRate`, `TokenEstimatorV2.init(family:rates:)` and exact family resolver; Task15 `RagRuntimeTuning.bundled()` / `.v1`; WP2 `ProviderChatSession`; WP8 ports above. **Produces (both platform signatures):**

```swift
public enum TokenCalibrationSessionError: String, Error, Sendable {
    case identityChanged, identityUnavailable
}
public struct CapturedTokenEstimator: Sendable {
    public let estimator: TokenEstimatorV2
    public let modelDigest: String
    private let check: @Sendable () async throws -> Void
    public func validate() async throws { try await check() }
    internal init(estimator:TokenEstimatorV2,modelDigest:String,
                  check:@escaping @Sendable () async throws -> Void) {
        self.estimator=estimator; self.modelDigest=modelDigest; self.check=check
    }
}
public struct ProviderTokenCalibration: Sendable {
    public init(bindings: [TokenFamilyBinding], rates: [TokenRate]) throws
    public static func bundled() throws -> ProviderTokenCalibration
    public func capture(type: ProviderType, model: String,
        listModels: @escaping @Sendable () async throws -> [OllamaModel])
        async throws -> CapturedTokenEstimator?
}
// Added to WP2 session, optional for non-router compatibility clients:
public var tokenEstimator: (any ContextTokenEstimating)? { get }
// Added to WP8 PreparedPackTransport:
var tokenEstimator: (any ContextTokenEstimating)? { get }
// Default protocol extension returns nil so existing fake transports compile.
// Optional constructor parameter on WP8 coordinator:
public init(data: any PackDataSource, transports: any PackTransportFactory,
            tuning: RagRuntimeTuning? = nil)
```

```csharp
public sealed class TokenCalibrationSessionException(string code) : Exception(code) {
    public string Code { get; } = code;
}
public sealed class CapturedTokenEstimator {
    public TokenEstimatorV2 Estimator { get; }
    public string ModelDigest { get; }
    public Task ValidateAsync(CancellationToken ct=default);
}
public sealed class ProviderTokenCalibration {
    public ProviderTokenCalibration(IReadOnlyList<TokenFamilyBinding> bindings,IReadOnlyList<TokenRate> rates);
    public static ProviderTokenCalibration Bundled();
    public Task<CapturedTokenEstimator?> CaptureAsync(ProviderType type,string model,
        Func<CancellationToken,Task<IReadOnlyList<OllamaModel>>> listModels,CancellationToken ct=default);
}
public IContextTokenEstimator? ProviderChatSession.TokenEstimator { get; }
// Add a default interface member to IPreparedPackTransport:
IContextTokenEstimator? TokenEstimator => null;
public ContextPackCoordinator(IPackDataSource data,IPackTransportFactory transports,
                              RagRuntimeTuning? tuning=null);
```

- [ ] **Step1: Write the failing shared digest/capture test.**

```swift
import Foundation
import XCTest
@testable import AINotebookCore

final class ProviderTokenCalibrationTests: XCTestCase {
    actor Models {
        var rows: [OllamaModel]
        private(set) var calls = 0
        init(_ rows: [OllamaModel]) { self.rows = rows }
        func list() -> [OllamaModel] { calls += 1; return rows }
        func replace(_ value: [OllamaModel]) { rows = value }
    }
    func testSharedModelIdentityAndPreSendGuard() async throws {
        let fixture = try SharedFixtures.json("contracts/token-calibration-session-v1.json")
        for c in fixture["cases"] as! [[String: Any]] where c["kind"] as? String == "capture" {
            let model = c["model"] as! String
            let bindings = try JSONDecoder().decode([TokenFamilyBinding].self,
                from: JSONSerialization.data(withJSONObject:c["bindings"]!))
            let rates = try JSONDecoder().decode([TokenRate].self,
                from: JSONSerialization.data(withJSONObject:c["rates"]!))
            let rows = try JSONDecoder().decode([OllamaModel].self,
                from: JSONSerialization.data(withJSONObject:c["models"]!))
            let source = Models(rows)
            let policy = try ProviderTokenCalibration(bindings:bindings,rates:rates)
            let captured = try await policy.capture(type:ProviderType(rawValue:c["providerType"] as! String)!,
                model:model,listModels:{ await source.list() })
            XCTAssertEqual(captured != nil,c["calibrated"] as! Bool,c["name"] as! String)
            let estimator = try captured?.estimator ?? TokenEstimatorV2(family:"unverified",rates:[])
            XCTAssertEqual(estimator.estimate("a😀b",language:"cs"),c["expectedTokens"] as! Int)
            let calls = await source.calls
            XCTAssertEqual(calls,c["identityCalls"] as! Int)
            if let changed = c["nextModels"] {
                let next = try JSONDecoder().decode([OllamaModel].self,
                    from:JSONSerialization.data(withJSONObject:changed))
                await source.replace(next)
                do { try await XCTUnwrap(captured).validate(); XCTFail("identity change must reject send") }
                catch let error as TokenCalibrationSessionError { XCTAssertEqual(error,.identityChanged) }
            }
        }
    }
}
```

Run `swift test --filter ProviderTokenCalibrationTests` → FAIL: new policy/session types missing. Add cancellation and unavailable-metadata scripts before implementing. Use an actor and continuations, not wall-clock sleeps, for captured-root/settings-mutation and retry tests. HTTP root test uses existing `StubURLProtocol` (`Tests/AINotebookCoreTests/StubURLProtocol.swift:6,74`) and verifies only `/api/tags` on the captured root, followed by chat on that root. New tests inject synthetic binding/rate data into router via an optional `tokenCalibration: ProviderTokenCalibration? = nil` constructor argument; nil loads bundled policy lazily inside prepareChat. Do not modify committed measured resources to make tests deterministic.

- [ ] **Step2: Implement exact lookup and an immutable pre-send guard.** `bundled` decodes bindings/rates from the already registered `Benchmark/token-estimate-v2.json`; validate using Task6 rules. Pending/empty binding data is valid and makes zero extra requests. Capture receives the already authorized/captured type/root/model from WP2 before any metadata suspension. Ignore provider display names. Only `.ollama` and an exact model ID present in bindings can probe; all other providers/models return nil. Locate exactly one `OllamaModel.name == model`; duplicate, missing, or malformed digest means unverified. Digest accepts either64 lowercase ASCII hex or `sha256:` plus those64 and normalizes to the latter; no truncated digest matching.

Central selection code:

```swift
public func capture(type: ProviderType, model: String,
    listModels: @escaping @Sendable () async throws -> [OllamaModel]) async throws -> CapturedTokenEstimator? {
    guard type == .ollama, bindings.contains(where: { $0.model == model }) else { return nil }
    let rows: [OllamaModel]
    do { rows = try await listModels() }
    catch is CancellationError { throw CancellationError() }
    catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    catch { return nil } // Identity is optional; no measured rates without evidence.
    guard let digest = Self.uniqueDigest(model:model,rows:rows),
          let family = TokenEstimatorV2.resolveFamily(model:model,modelDigest:digest,bindings:bindings) else { return nil }
    let estimator = try TokenEstimatorV2(family:family,rates:rates)
    return CapturedTokenEstimator(estimator:estimator,modelDigest:digest,check:{
        let latest: [OllamaModel]
        do { latest = try await listModels() }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw TokenCalibrationSessionError.identityUnavailable }
        guard Self.uniqueDigest(model:model,rows:latest) == digest else {
            throw TokenCalibrationSessionError.identityChanged
        }
    })
}
```

`uniqueDigest(model:rows:) -> String?` is internal static in the same new file and enforces the exact rules above. Snapshot bindings/rates in the initializer; never read current Settings in the closure. In router, construct `OllamaClient(baseURL: capturedNormalizedRoot, session: capturedURLSession)` and capture that **client value** in listModels; no fresh provider lookup. Existing auto-limit `/api/show` errors retain WP2 behavior; only this additional optional identity lookup may fall back. No calibration metadata probe runs for a missing/disabled/unconsented provider because WP2 validates those first.

- [ ] **Step3: Carry the selected estimator through the real production path.** WP2 session stores an optional private `CapturedTokenEstimator`, with source-compatible internal initializer parameter default nil. Its public `tokenEstimator` projects that immutable estimator. Before every session stream attempt, call its `validate()` inside the existing cancellable stream task; only then call the captured chat adapter. Retry and Preview→Send therefore cannot reuse measured rates after a tag changes. On guard failure do not repack or substitute another model; throw the typed error, preserve the prepared preview, and produce zero chat requests. Add that error to ChatEngine's terminal-error branch beside context-too-long, without changing existing RetryAfter behavior. The local server can still change between metadata check and chat; reports/capture document this ordinary non-atomic remote-state limitation rather than claim digest-addressed execution.

In `ContextPackAdapters.swift`, every WP2-backed implementation of `PreparedPackTransport` exposes `session.tokenEstimator`; a compatibility transport lacking a provider session returns nil. Add the optional protocol property with default nil in `ContextPackCoordinator.swift`. Immediately before first suspension, capture the injected tuning override or `try RagRuntimeTuning.bundled()`. Preserve `intent.fetchK`/`topK` exactly (explicit benchmark/test parameters are authorized). Build after hydration:

```swift
let request: PreparedContextRequest
if let estimator = transport.tokenEstimator {
    request = try ContextPackBuilder.build(input,estimator:estimator,tuning:capturedTuning)
} else {
    request = try ContextPackBuilder.build(input,tuning:capturedTuning)
}
```

The `tuning` constructor parameter is stored optional, and preparation resolves it exactly once. No digest, calibration family or secrets are added to frozen PackModel/prepared JSON; prepared estimatorVersion2 plus exact token charges are retained unchanged through Send/retries. Production intent creators use bundled fetchK/topK **before** key creation (Task13's Swift ChatView change); legacy Core convenience send/regenerate intent construction uses the same bundled defaults, while preserving any explicit compatibility topK argument. Never overwrite intent fields inside the coordinator or hash a different intent than the UI. Existing golden tests explicitly inject v1 estimator/tuning; calibration integration tests inject synthetic v2 estimator and chosen tuning.

- [ ] **Step4: Add production propagation assertions and run green.** In the new injection test file, use real `ContextPackFixtures.input("basic-cs")` (helper `:14`), with runtime4096/output512, and the `coordinator-injects` fixture's expected full prepared JSON. Supply a fake WP8 `PreparedPackTransport` with TokenEstimatorV2(fixture-only/rate5000), and a PackReadSession that returns that fixture input and its own passages. Fake search records requested fetchK; hydrate returns exact fixture passages; neighbours returns empty; finish increments a release counter. Assert exact prepared JSON, estimatorVersion2, one release, requested fetchK9/topK3 for `explicit-tuning`, and no mutation after replacing the fake factory's selection. Add a second real-router test with synthetic binding, queued tags64a, preparation, Settings changes, tags64a, chat; assert both captured metadata URLs and chat root/model remain original. Guard test queues tags64b and asserts no chat call/assistant persistence. All data comes from Task1 shared fixture; use actual WP8 ports, not an alternate test-only packer.

```bash
swift test --filter 'ProviderTokenCalibrationTests|ContextPackEstimatorInjectionTests|ChatEngineContextPackTests|ProviderSessionTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/Providers/ProviderTokenCalibration.swift Sources/AINotebookCore/Providers/ProviderSession.swift Sources/AINotebookCore/Providers/ProviderRouter.swift Sources/AINotebookCore/ContextPackCoordinator.swift Sources/AINotebookCore/ContextPackAdapters.swift Sources/AINotebookCore/ChatEngine.swift Tests/AINotebookCoreTests/ProviderTokenCalibrationTests.swift Tests/AINotebookCoreTests/ContextPackEstimatorInjectionTests.swift
git commit -m "feat(chat): inject verified token calibration into frozen Swift packs" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all shared capture cases and production propagation tests pass; full Swift and Core.NET suites zero failures/skips. No live Ollama required.


### Task 18: [Windows] Carry verified tokenizer calibration through the frozen chat session

**Depends on:** Tasks5,7,11,14,16; merged WP2 sessions and WP8 Core/UI integration. **Parallel with:**17 and disjoint Swift tasks; never5/14 or upstream owners of these files. **Files:** Task18 row only; shared fixtures read-only.

**Interfaces — Consumes:** actual `OllamaClient.ListModelsAsync(CancellationToken) -> Task<IReadOnlyList<OllamaModel>>` (`Ollama/OllamaClient.cs:41`), Name/Digest fields (`Ollama/OllamaDtos.cs:60–65`); Task7 TokenFamilyBinding/rates/estimator; Task16 RagRuntimeTuning; WP2 captured session and WP8 IPack* ports. **Produces:** all C# declarations in Task17; Swift twins there are the exact parity boundary. New policy/error/snapshot types live in `AINotebook.Core.Providers`.

- [ ] **Step1: Write the failing shared policy/guard test.**

```csharp
using System.Text.Json;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

public sealed class ProviderTokenCalibrationTests
{
    [Fact] public async Task SharedModelIdentityAndPreSendGuard()
    {
        var json=new JsonSerializerOptions { PropertyNamingPolicy=JsonNamingPolicy.CamelCase };
        foreach(var c in SharedFixtures.Json("contracts/token-calibration-session-v1.json").GetProperty("cases").EnumerateArray())
        {
            if(c.GetProperty("kind").GetString()!="capture") continue;
            string model=c.GetProperty("model").GetString()!;
            var bindings=c.GetProperty("bindings").Deserialize<TokenFamilyBinding[]>(json)!;
            var rates=c.GetProperty("rates").Deserialize<TokenRate[]>(json)!;
            IReadOnlyList<OllamaModel> rows=c.GetProperty("models").Deserialize<OllamaModel[]>(OllamaJson.Options)!;
            int calls=0;
            Task<IReadOnlyList<OllamaModel>> List(CancellationToken ct)
            { ct.ThrowIfCancellationRequested(); calls++; return Task.FromResult(rows); }
            var policy=new ProviderTokenCalibration(bindings,rates);
            var captured=await policy.CaptureAsync(
                ProviderTypeExtensions.FromStorageString(c.GetProperty("providerType").GetString()!),model,List);
            Assert.Equal(c.GetProperty("calibrated").GetBoolean(),captured is not null);
            var estimator=captured?.Estimator ?? new TokenEstimatorV2("unverified",[]);
            Assert.Equal(c.GetProperty("expectedTokens").GetInt32(),estimator.Estimate("a😀b","cs"));
            Assert.Equal(c.GetProperty("identityCalls").GetInt32(),calls);
            if(c.TryGetProperty("nextModels",out var next))
            {
                rows=next.Deserialize<OllamaModel[]>(OllamaJson.Options)!;
                var error=await Assert.ThrowsAsync<TokenCalibrationSessionException>(()=>captured!.ValidateAsync());
                Assert.Equal("identityChanged",error.Code);
            }
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ProviderTokenCalibrationTests` → FAIL for missing types. Add cancellation scripts using cancellation-aware TaskCompletionSource and fake HTTP root/model tests. Inject policy via optional Core ProviderRouter constructor argument `ProviderTokenCalibration? tokenCalibration=null`; null loads bundled policy during capture. App wrapper constructor continues calling the old argument list and receives production defaults.

- [ ] **Step2: Implement snapshot selection and validation.** Copy constructor arrays; decode existing production resource by its Task3 logical name `AINotebook.Benchmark.token-estimate-v2.json`. No Tests directory access. Exact64-hex digest normalization and duplicate name rejection follow fixture values. Kernel:

```csharp
public async Task<CapturedTokenEstimator?> CaptureAsync(ProviderType type,string model,
    Func<CancellationToken,Task<IReadOnlyList<OllamaModel>>> listModels,CancellationToken ct=default)
{
    ct.ThrowIfCancellationRequested();
    if(type!=ProviderType.Ollama || !_bindings.Any(x=>x.Model==model)) return null;
    IReadOnlyList<OllamaModel> rows;
    try { rows=await listModels(ct); }
    catch(OperationCanceledException) { throw; }
    catch { return null; }
    string? digest=UniqueDigest(model,rows);
    string? family=digest is null ? null : TokenEstimatorV2.ResolveFamily(model,digest,_bindings);
    if(family is null) return null;
    var estimator=new TokenEstimatorV2(family,_rates);
    return new CapturedTokenEstimator(estimator,digest!,async token=>
    {
        IReadOnlyList<OllamaModel> latest;
        try { latest=await listModels(token); }
        catch(OperationCanceledException) { throw; }
        catch { throw new TokenCalibrationSessionException("identityUnavailable"); }
        if(UniqueDigest(model,latest)!=digest)
            throw new TokenCalibrationSessionException("identityChanged");
    });
}
```

The new snapshot class stores a private readonly `Func<CancellationToken,Task>` and forwards ValidateAsync. The capture closure wraps a new existing OllamaClient built from the already captured root and HttpClient. There is no DB connection access in this policy and no await under `_gate`. Privacy/config checks happen first in the router. Unknown/non-Ollama model calls no identity HTTP. Initial optional metadata failure returns fallback; after calibrated capture, unavailable/changed identity stops Send before chat, because replacing estimates would invalidate the displayed pack.

- [ ] **Step3: Wire session, adapter and coordinator.** Add nullable private captured calibration to ProviderChatSession with an optional default-null internal constructor argument; project TokenEstimator. Before every StreamAsync attempt, await ValidateAsync(ct), then iterate the captured adapter stream. This is an async iterator; use its existing `[EnumeratorCancellation]` cancellation plumbing. Treat `TokenCalibrationSessionException` as terminal in ChatEngine without swallowing cancellation or retrying it.

Add `IContextTokenEstimator? TokenEstimator => null` to WP8 IPreparedPackTransport. Its WP2-backed adapter overrides it with the session estimator; legacy injected mocks keep null. At PrepareAsync entry capture `_tuning ?? RagRuntimeTuning.Bundled()` once. Keep explicit intent.FetchK/TopK; use those in retrieval/input. Production UI's PackIntent creation already uses bundled fetch/top before hashing through Task14. Compatibility Core intent construction uses bundled defaults unless its caller explicitly supplied topK. The builder call becomes:

```csharp
var request=ContextPackBuilder.Build(input,transport.TokenEstimator,capturedTuning);
```

No frozen prepared JSON fields change. Add real coordinator fixture tests for exact prepared JSON/charges, explicit intent9/3 with share4500, lease disposal, captured settings and byte-identical retries. Use actual helper `Helpers/ContextPackFixtures.cs:19` for basic-cs input, not an undefined fixture API. These tests parallel the Swift shared fixture, with no live network.

- [ ] **Step4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~ProviderTokenCalibrationTests|FullyQualifiedName~ContextPackEstimatorInjectionTests|FullyQualifiedName~ChatEngineContextPackTests|FullyQualifiedName~ProviderSessionTests'
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Providers/ProviderTokenCalibration.cs windows/src/AINotebook.Core/Providers/ProviderSession.cs windows/src/AINotebook.Core/Providers/ProviderRouter.cs windows/src/AINotebook.Core/Rag/ContextPackCoordinator.cs windows/src/AINotebook.Core/Rag/ContextPackAdapters.cs windows/src/AINotebook.Core/Rag/ChatEngine.cs windows/tests/AINotebook.Core.Tests/Providers/ProviderTokenCalibrationTests.cs windows/tests/AINotebook.Core.Tests/Rag/ContextPackEstimatorInjectionTests.cs
git commit -m "feat(win-chat): inject verified token calibration into frozen context packs" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: shared digest/guard/injection behavior green and both full suites green; no App build needed for this Core-only task. Task14's App integration remains CI-built.

#### Concrete coordinator propagation tests for Task17 Step4 and Task18 Step3

Task1 `coordinator-injects` fixture has `kind:"coordinator",question:"a😀b",fetchK:9,topK:3,evidenceShareBp:4500,expectedQuestionTokens:11,expectedEstimatorVersion:2`. The test fixture input is the already committed `basic-cs` input with only the listed question/tuning/runtime changes. Assert11 from the shared fixture: scalar3 at rate5000 →base2 →headroom3 →section charge11. A missed estimator injection produces fallback charge15, so this detects a real wiring regression.

```swift
final class ContextPackEstimatorInjectionTests: XCTestCase {
    private actor Read: PackReadSession {
        let input: ContextPackInput
        private(set) var requestedFetchK: Int?
        private(set) var finishes = 0
        init(_ input:ContextPackInput) { self.input=input }
        func search(question:String,fetchK:Int) async throws -> [PackHit] {
            requestedFetchK=fetchK
            return input.candidates.map { PackHit(chunkId:$0.chunkId,sourceId:$0.sourceId,
                revisionId:$0.revisionId,rrfMicro:$0.rrfMicro) }
        }
        func hydrate(_ hits:[PackHit]) async throws -> [PackPassage] { input.candidates }
        func overview() async throws -> [PackPassage] { input.overviewCandidates }
        func neighbours(for passages:[PackPassage]) async throws -> [PackPassage] { [] }
        func finish() async { finishes += 1 }
    }
    private struct DataSource: PackDataSource {
        let read:Read
        func pin(_ intent:PackIntent,model:PackModel) async throws -> any PackReadSession { read }
    }
    private struct Transport: PreparedPackTransport {
        let model:PackModel
        let tokenEstimator:(any ContextTokenEstimating)?
        func stream(_ request:PreparedContextRequest) -> AsyncThrowingStream<String,Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
    private struct Factory: PackTransportFactory {
        let transport:Transport
        func freeze(_ intent:PackIntent) async throws -> any PreparedPackTransport { transport }
    }
    func testCoordinatorUsesCapturedEstimatorAndPreservesExplicitIntentTuning() async throws {
        let root=try SharedFixtures.json("contracts/token-calibration-session-v1.json")
        let c=(root["cases"] as! [[String:Any]]).first { $0["name"] as? String == "coordinator-injects" }!
        var input=try ContextPackFixtures.input("basic-cs")
        input.question=c["question"] as! String
        input.fetchK=c["fetchK"] as! Int; input.topK=c["topK"] as! Int
        input.model.runtimeContext=4096; input.model.maxOutputTokens=512
        let tuning=try RagRuntimeTuning(fetchK:32,topK:16,evidenceShareBp:c["evidenceShareBp"] as! Int)
        let estimator=try TokenEstimatorV2(family:"fixture-only",rates:["cs","en","und"].map {
            TokenRate(family:"fixture-only",language:$0,tokensPerScalarBp:5000)
        })
        let read=Read(input)
        let coordinator=ContextPackCoordinator(data:DataSource(read:read),
            transports:Factory(transport:Transport(model:input.model,tokenEstimator:estimator)),tuning:tuning)
        let intent=PackIntent(notebookId:1,sessionId:1,question:input.question,mode:"answer",scope:.all,
            providerId:input.model.providerId,model:input.model.model,providerConfigurationRevision:1,
            runtimeContext:4096,maxOutputTokens:512,evidenceBudgetCap:nil,
            fetchK:input.fetchK,topK:input.topK,notebookInstructions:"",
            instructionsOverride:input.userInstructions,currentNoteContent:nil,useWebSearch:false,
            historyFingerprint:String(repeating:"a",count:64),scopeFingerprint:String(repeating:"b",count:64),
            regenerateUserId:nil,replacesAssistantId:nil)
        let handle=try await coordinator.prepare(intent)
        let question=try XCTUnwrap(handle.request.messages.last?.sections.last)
        XCTAssertEqual(question.kind,"question")
        XCTAssertEqual(question.tokens,c["expectedQuestionTokens"] as! Int)
        XCTAssertEqual(handle.request.estimatorVersion,c["expectedEstimatorVersion"] as! Int)
        XCTAssertEqual(handle.intent.fetchK,9); XCTAssertEqual(handle.intent.topK,3)
        XCTAssertEqual(handle.key,PackIntentKey.make(intent))
        let fetch=await read.requestedFetchK, finished=await read.finishes
        XCTAssertEqual(fetch,9); XCTAssertEqual(finished,1)
    }
}
```

```csharp
using System.Runtime.CompilerServices;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

public sealed class ContextPackEstimatorInjectionTests
{
    private sealed class Read(ContextPackInput input) : IPackReadSession
    {
        public ContextPackInput Input { get; }=input;
        public int? RequestedFetchK { get; private set; }
        public int Finishes { get; private set; }
        public Task<PackHit[]> SearchAsync(string question,int fetchK,CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested(); RequestedFetchK=fetchK;
            return Task.FromResult(Input.Candidates.Select(x=>new PackHit(x.ChunkId,x.SourceId,x.RevisionId,x.RrfMicro)).ToArray());
        }
        public Task<PackPassage[]> HydrateAsync(PackHit[] hits,CancellationToken ct)=>Task.FromResult(Input.Candidates);
        public Task<PackPassage[]> OverviewAsync(CancellationToken ct)=>Task.FromResult(Input.OverviewCandidates);
        public Task<PackPassage[]> NeighboursAsync(PackPassage[] passages,CancellationToken ct)=>Task.FromResult(Array.Empty<PackPassage>());
        public ValueTask DisposeAsync() { Finishes++; return ValueTask.CompletedTask; }
    }
    private sealed class DataSource(Read read) : IPackDataSource
    {
        public Task<IPackReadSession> PinAsync(PackIntent intent,PackModel model,CancellationToken ct)
            =>Task.FromResult<IPackReadSession>(read);
    }
    private sealed class Transport(PackModel model,IContextTokenEstimator estimator) : IPreparedPackTransport
    {
        public PackModel Model { get; }=model;
        public IContextTokenEstimator? TokenEstimator { get; }=estimator;
        public async IAsyncEnumerable<string> StreamAsync(PreparedContextRequest request,
            [EnumeratorCancellation] CancellationToken ct)
        { await Task.CompletedTask; ct.ThrowIfCancellationRequested(); yield break; }
    }
    private sealed class Factory(IPreparedPackTransport transport) : IPackTransportFactory
    {
        public Task<IPreparedPackTransport> FreezeAsync(PackIntent intent,CancellationToken ct)=>Task.FromResult(transport);
    }
    [Fact] public async Task CoordinatorUsesCapturedEstimatorAndPreservesExplicitIntentTuning()
    {
        var c=SharedFixtures.Json("contracts/token-calibration-session-v1.json").GetProperty("cases")
            .EnumerateArray().Single(x=>x.GetProperty("name").GetString()=="coordinator-injects");
        var basic=ContextPackFixtures.Input("basic-cs");
        var input=basic with { Question=c.GetProperty("question").GetString()!,
            FetchK=c.GetProperty("fetchK").GetInt32(),TopK=c.GetProperty("topK").GetInt32(),
            Model=basic.Model with { RuntimeContext=4096,MaxOutputTokens=512 } };
        var tuning=new RagRuntimeTuning(32,16,c.GetProperty("evidenceShareBp").GetInt32());
        var estimator=new TokenEstimatorV2("fixture-only",new[]{"cs","en","und"}
            .Select(x=>new TokenRate("fixture-only",x,5000)).ToArray());
        var read=new Read(input);
        var coordinator=new ContextPackCoordinator(new DataSource(read),new Factory(new Transport(input.Model,estimator)),tuning);
        var intent=new PackIntent(1,1,input.Question,"answer",new RetrievalScope.All(),
            input.Model.ProviderId,input.Model.Model,1,4096,512,null,input.FetchK,input.TopK,"",
            input.UserInstructions,null,false,new string('a',64),new string('b',64),null,null);
        var handle=await coordinator.PrepareAsync(intent);
        var question=handle.Request.Messages[^1].Sections[^1];
        Assert.Equal("question",question.Kind);
        Assert.Equal(c.GetProperty("expectedQuestionTokens").GetInt32(),question.Tokens);
        Assert.Equal(c.GetProperty("expectedEstimatorVersion").GetInt32(),handle.Request.EstimatorVersion);
        Assert.Equal(9,handle.Intent.FetchK); Assert.Equal(3,handle.Intent.TopK);
        Assert.Equal(PackIntentKey.Make(intent),handle.Key);
        Assert.Equal(9,read.RequestedFetchK); Assert.Equal(1,read.Finishes);
    }
}
```


## WP gate

Run from the integration checkout containing every required task, with actual before/after test totals recorded. The task dependency graph, not numerical heading order, controls merges. Do not close WP7 while a hardware/UI result is pending.

```bash
python3 -B tools/contracts/gen_benchmark_fixtures.py --check
python3 -B -m unittest tools.benchmark.test_contracts tools.benchmark.test_tokenize_offline tools.benchmark.test_verify_reports
swift test
dotnet test windows/tests/AINotebook.Core.Tests
swift run ainotebook-eval --benchmark --mode fixture --root eval/multilingual --profiles nomic-v2-256 --chunks 1000 --queries 3 --warmup 1 --concurrent both --json /tmp/wp7-swift-fixture.json --out /tmp/wp7-swift-fixture.md
dotnet run --project windows/tools/AINotebook.Eval -- --benchmark --mode fixture --root eval/multilingual --profiles nomic-v2-256 --chunks 1000 --queries 3 --warmup 1 --concurrent both --json /tmp/wp7-dotnet-fixture.json --out /tmp/wp7-dotnet-fixture.md
python3 -B tools/benchmark/verify_reports.py --mac docs/eval/wp7/macos-benchmark.json --windows docs/eval/wp7/windows-benchmark.json --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --decision docs/eval/wp7/decision.json
git diff --check
git status --short
```

On Windows CI, separately:

```powershell
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
```

Criteria:

- Every shared fixture is exercised on both platforms; generator check and Python/Swift/.NET suites pass without skips. Full report JSON is structurally equal and Markdown byte-identical for each same-input shared golden. Local fixture CLI integration has the same counts, IDs, recall denominators and citation audits after only explicit platform/environment normalization; no measured live fields are removed to force agreement.
- All seven profiles retain every input scalar, apply exact role-specific formatting once per accepted part, use explicit `truncate:false` and captured input ceiling, and publish only valid dimensions/normalization. Legacy generations keep their old input behavior. Input-limit fallback never invents token counts.
- Benchmark uses actual eval revisions/generations, production scoped retrieval and WP8 builder. Lexical, hybrid rank-cut, full candidate union, packed-evidence recall and citation metrics have distinct denominators. Tests prove old/new revisions, empty selection, zero budget, clipped gold, first-chunk Overview and wrong citation identities. Scope/citation correctness cannot be traded for speed.
- Accepted calibration contains measured chat-default/tokenizer identity, cs/sk/en/de training and disjoint holdout body counts plus full rendered prompt checks. Embedding throughput observations are separately labeled. No held-out undercount is concealed; unknown or changed model identity uses the labeled v2 fallback. Product per-turn capture injects verified calibration and retains it through preview/send.
- Both exact reference machines have complete live reports. The chosen dimensions achieve strict p95<300ms at100K after embedding with200 samples and no ingestion. 200K, application-cache load/streamed status, genuine concurrent ingestion overlap, real end-to-end latency and sampled process-tree RSS are reported. Any performance exception requires a jointly recorded decision in README; thresholds remain frozen. Missing Windows hardware evidence is a pending gate, never a presumed pass.
- README has numbers, links, default model+dims, identities/input policy, parameter/calibration versions and the rationale. If tuning changed, constants-v2, decision resource, runtime loaders and confirmatory reports agree. Live model runs are absent from CI.
- Fresh installs persist the chosen complete profile; existing preference/index state stays unchanged at startup. Ordinary imports honor the selected document format/dimensions. Settings shows EN/CS recommendation and explicit safe reindex; cancel/failure preserves old active generations, and a crash at publication is recoverable. Claude records the Mac checklist; Windows CI build/App tests and the Windows checklist are recorded.
- Existing `.github/workflows/core-ci.yml:32` privacy scan and `.github/workflows/windows-ci.yml` pass. New networking is under Providers; no new migration, VERSION change, package-identity access or unlocked SqliteConnection operation exists. Worktrees contain only their declared changes, all commits have the required trailer, and final `git status --short` is empty.

The implementation handoff records commits and owned files, both suites' before/after counts, fixture/generator checks, Mac/Windows report paths, actual hardware, and any explicit Claude decision or unresolved gate. This planning commit supplies no live results and selects no default model.
