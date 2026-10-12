# WP6 — Folder Ingestion Implementation Plan

**Goal:** Persist and reconcile notebook folders on both platforms; extract bounded, canonical, multilingual revisions; publish through fenced durable jobs; build replacement indexes without interrupting chat; expose folder management, explicit chat scopes and re-index progress in English and Czech.

**Architecture:** Native filesystem adapters provide identities, bounded reads and rescan signals. Core owns glob rules, inventory reconciliation, canonical extraction, scalar chunks, language metadata, queue admission and generation orchestration. SQLite transactions own observation/publication fences. A process-wide coordinator survives view changes. Shared fixtures exercise the same state transitions in Swift and C#. Active generations remain immutable; changed content creates a building successor, with unchanged vectors copied only across identical generation identities.

**Tech Stack:** Swift 6, Foundation/PDFKit, ZIPFoundation, GRDB, XCTest, SwiftUI/AppKit/FSEvents; .NET 10, System.IO/Compression/Xml, PdfPig, Microsoft.Data.Sqlite/Dapper, xUnit, WinUI 3; Python 3 standard library for deterministic fixtures. Use existing dependencies. .NET 10 supplies `System.Text.Encoding.CodePages`; register its provider explicitly.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md` §§4.2–4.7, 5.3, 6.3. **Master:** `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md`. **Contracts:** `docs/contracts/folder-rag-v1.md` §§1–4, 6; `docs/contracts/lang-detector-v1.md` §§2, 4–6. **Predecessors:** `docs/superpowers/plans/2026-10-09-wp3-storage-v19.md`, `docs/superpowers/plans/2026-10-09-wp4-language-detector.md`. **Format exemplar:** `docs/superpowers/plans/2026-10-09-wp0-contracts.md`. No installed skill is invoked by this plan.

## Global Constraints

- This is an implementation plan, not an implementation commit. Execute each numbered task in a separate worktree after its dependencies have landed. Only edit its **Files**. Read-only inputs do not confer ownership. Do not update this plan while implementing it. Commit every task with the trailer shown below and leave the worktree clean.
- TDD: add the shown tests and named boundary cases, run red, implement, run the targeted tests and both complete Core suites. A missing new symbol is the first red; additional bug fixes require behavioral red tests. Never change an expected value to accommodate production output. Every fixture dispatcher rejects unknown operations and asserts all case names were visited.
- Swift reads `Tests/fixtures/` with `SharedFixtures` (`Tests/AINotebookCoreTests/SharedFixtures.swift:12`); C# uses `SharedFixtures.Path/Json` (`windows/tests/AINotebook.Core.Tests/Helpers/SharedFixtures.cs:8`). The test project already copies all fixture extensions (`windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj:36`). Neither loader nor project needs modification.
- Shared fixtures land first. Preserve frozen `glob-v1.json`, `job-transitions-v1.json`, constants and language fixtures. New contracts use envelope `{contract,version:1,cases:[...]}`, UTF-8 without BOM, LF, unique case names, integer arithmetic, stable scalar ordering. Use a separate ingestion generator; do not edit concurrent WP0/WP3/WP4 generators.
- WP3 and WP4 must land before runtime tasks. References to their **planned** outputs below are explicitly labeled; they do not exist at the inspected planning base `b1ea245`. Read the landed code before implementation and verify signatures, rather than manufacturing a parallel store or detector.
- WP0 decisions 2/8/10 govern glob normalization, attempt-start counting and two-dimensional coverage. The amended contract overrides older spec prose and predecessor-plan examples. All other binding WP0/WP2 decisions remain intact. No provider conversion, model-default, migration-version or VERSION edits belong here.
- Windows: every connection, transaction, reader, raw test SQL and disposal stays under `lock (_gate)` / `lock (store.Gate)`. Never await inside a lock. Swift compound changes use one `dbQueue.write`; call WP3 transaction kernels with that `Database`, not public methods that nest transactions. Keep file IO, hashing, extraction and detector work outside SQL transactions and off the UI thread.
- Networking stays in existing providers and allowlisted extractors; ingestion calls `EmbeddingProducing` / `IEmbeddingProducing`, never creates network clients. Preserve provider snapshots and privacy checks for background embeddings. Chat-only providers remain unsupported for embeddings; no silent substitution.
- UTC scheduling uses integer epoch seconds, file mtimes integer nanoseconds, watcher deadlines monotonic milliseconds. Revision IDs are `source_revisions.id`, not source-local ordinals. Use injected clocks and barriers, not test sleeps.
- Default limits are `RagContractV1.Scan`: file 52,428,800 bytes, Office expanded 209,715,200 bytes, canonical 5,000,000 scalars, PDF 2,000 pages, chunks 5,000, extraction concurrency 2, reconciliation 30 minutes, debounce 500 ms, maximum coalesce 5,000 ms. Folder rules may lower these limits; do not silently raise the process safety ceilings.
- No following interior symlinks/junctions/reparse points, no deletion of user files, no native folder enumeration on a UI thread. Root identity is resolved once on addition and checked against WP3's persisted identity on every scan. Path comparison follows the volume/directory, not global lowercase. Glob folding alone uses pinned Unicode simple lowercase.
- Reserve ownership of `ChatEngine`, app composition, Sources/Chat/Settings views against WP8 integration and WP2 UI work. WP2 changes land first; WP6 integration/UI then land; WP8 chat integration branches afterward, because it depends on WP6. Independent WP8 pure-builder tasks may run in parallel.
- Windows App cannot build on macOS. Verify Core locally and require Windows CI build plus App tests; Claude runs the macOS manual checklists. Do not present an unrun App build as green.

## Required WP3 handoff corrections before runtime execution

These are precise integration findings for Claude/WP3, not permission for a WP6 worker to amend a shipped migration. The shared-fixture task can proceed now. Runtime tasks require the corrected v19 handoff below to be merged. If v19 has already shipped, stop at this dependency gate and have Claude assign a new migration; do not create tables opportunistically on startup.

1. **Jobs:** WP3 plan lines 888–918 queue failures directly, use a nonnullable retry deadline and reset it on resume. That conflicts with contract lines 49–57 and the actual 21-case `job-transitions-v1.json`. WP3 must make `ingest_jobs.next_retry_at` nullable, `IngestJob.nextRetryAt: Int64?` / `long?`, leave attempts 1–4 failures in `failed` with a deadline, and make attempt 5 failures/expiry terminal with no deadline. Add `requeueRetryableJobs(now: Int64) throws -> Int` / `int RequeueRetryableJobs(long now)`; it changes only due `failed` rows with attempts < 5 and nonnull deadlines to `queued`. Claim accepts queued due rows, increments once and clears retry time. Queued-only pause and paused-only resume preserve the deadline. Retain WP3's unexpired token predicates and expected-current extraction fence. Do not translate `failed` into `queued` in test adapters.
2. **Revision page maps:** WP3 `RevisionDraft` and `RevisionChunkDraft` (plan lines 836–838) have no immutable PDF page map. A single `page_hint` cannot describe a chunk crossing pages. Add this table to the **unshipped v19 migration on both platforms**, with no backfill invention for legacy revisions:

   ```sql
   CREATE TABLE revision_pages (
     revision_id INTEGER NOT NULL REFERENCES source_revisions(id) ON DELETE CASCADE,
     page INTEGER NOT NULL CHECK(page>0),
     char_start INTEGER NOT NULL CHECK(char_start>=0),
     char_end INTEGER NOT NULL CHECK(char_end>=char_start),
     PRIMARY KEY(revision_id,page)
   );
   CREATE TRIGGER revision_pages_no_update BEFORE UPDATE ON revision_pages
   BEGIN SELECT RAISE(ABORT,'immutable revision page'); END;
   ```

   WP6 inserts the complete map only in its fenced publication transaction, before commit. Empty pages have equal start/end. No synthetic map for old revisions. WP5/WP8 hydration consumes the immutable map by revision ID; mutable `sources.descriptor` is insufficient. WP6 supplies `revisionPages` APIs in Tasks 12/13. This schema addition needs Claude's upstream review before WP3 lands.
3. **Coverage is an owned WP6 correction:** WP3's DTO intentionally retains `pending`/`error` fields (plan line 585). Define `notSearchable = pending + error`, `current = searchable + pending + error - refreshPending - refreshError`. Tasks 8/9 amend WP3's coverage query (plan lines 647–649) to include observed changes awaiting extraction (`status IN ('pending','chunking')` even while `current_revision == published_revision_id`). This requires no migration.

4. **Durable options and first-batch dimensions:** add `ingest_jobs.options_json TEXT NOT NULL DEFAULT '{}'` to unshipped v19; options may be coalesced only while queued and become immutable at claim. Extend the validated embed target grammar to accept `notebook:<id>` for a dimension-discovery job as well as `generation:<id>`. This job embeds the first real corpus batch, never a probe string. Fenced completion may atomically retarget it to the resulting generation. WP3 orphan cancellation must recognize notebook embed targets. Scan options are `{"verifyAll":false}`; embed options store only the nonsecret EmbeddingSelection and `copyExisting` flag. Secrets never enter SQLite. A queued scan upgrade must not mutate a running job's options.
5. **Root object identity:** append `rootFileId:String` / `string RootFileId` to WP3 `FolderIdentity` and its persisted `path_identity` JSON. Keep volume/components for overlap checks; compare rootFileId separately against the opened root handle on each scan. Canonical names alone do not detect a replacement directory at the same path. Update WP3 identity fixtures/constructors before landing; this adds no SQL column. Native adapters must return a real volume/file ID, never a pathname hash.
6. **Refresh retry status:** the corrected WP3 claim transaction also sets the targeted extract source to `chunking` and clears its error when the expected current pointer still matches. Due failed→queued retry sets it to `pending` and clears the prior error atomically. A stale target is cancelled without clearing a newer failure. Generic failed job rows remain governed by job-transitions-v1. This makes decision-10 freshness correct while a retry runs. Include failure→due retry→claim coverage in WP3/WP6 tests.

These handoffs are merge dependencies requiring Claude's review. The planner changes only this plan; no schema or predecessor plan is edited here.

**WP5/UI notification handoff:** the inspected stores have only note callbacks, not a generic change event (`Sources/AINotebookCore/NotebookStore.swift:12–28`, `windows/src/AINotebook.Core/Storage/NotebookStore.cs:13–48`). Tasks8/9 add the post-commit seam below in their owned store extensions. Tasks12–17 use it after successful publication, generation and lifecycle mutations; rejected fences and rollbacks emit nothing. WP5 must derive eligibility from a fresh SQL snapshot for each retrieval turn and must not reuse an eligibility mask across turns. Immutable vector data may remain cached. Notification-based cache eviction is an optimization, never the correctness fence; a separate store connection/process need not receive these process-local events. This is an explicit WP5 integration contract, not an assumed existing API.

```swift
// NotebookStore+FolderIngestion.swift; store is already @MainActor.
public extension Notification.Name {
    static let folderIngestionDidChange = Notification.Name("AINotebook.folderIngestionDidChange")
}
extension NotebookStore {
    func notifyFolderIngestionChanged(notebookId:Int64) {
        NotificationCenter.default.post(name:.folderIngestionDidChange, object:self,
                                        userInfo:["notebookId":notebookId])
    }
}
```

```csharp
// NotebookStore.FolderIngestion.cs, namespace AINotebook.Core.Storage.
public sealed partial class NotebookStore {
    public event Action<long>? FolderIngestionChanged;
    internal void NotifyFolderIngestionChanged(long notebookId) {
        var handlers=FolderIngestionChanged;
        if(handlers is null) return;
        foreach(Action<long> handler in handlers.GetInvocationList()) {
            try { handler(notebookId); }
            catch(Exception e) { System.Diagnostics.Trace.TraceError("Folder observer failed: {0}",e.GetType().Name); }
        }
    }
}
```

Invoke the Swift helper after `dbQueue.write` returns and the C# helper after committing **and releasing `_gate`**. Observer failure must not turn a committed write into a retried job. UI subscriptions filter by store identity and notebook ID, dispatch presentation work to MainActor/DispatcherQueue, and detach when hidden. Runtime commands that call WP3 create/remove/watch APIs send one notification after that API returns; transaction kernels never send their own notification.

## File Structure

Paths in braces enumerate exact files, not permission to modify an entire directory. New files have no current line citation. Existing line numbers refer to `b1ea245`; predecessor-plan line numbers refer to the checked-in plans.

| Task | Files | Responsibility and current anchor |
|---|---|---|
| 1 [Shared] | `tools/contracts/{gen_ingestion_fixtures.py,test_ingestion_fixtures.py}`; `Tests/fixtures/contracts/ingestion-{encoding,canonical,office,scan,jobs,pipeline,generations,coverage,ui}-v1.json`; `Tests/fixtures/ingestion/{paragraphs.docx,slides.pptx,workbook.xlsx,pages.pdf,corrupt.docx,external.xlsx,bad-index.xlsx}` | New generator and exact cross-platform inputs. Fixture rules: `Tests/fixtures/README.md:1`. |
| 2 [Swift] | `Sources/AINotebookCore/FolderGlob.swift`; `Sources/AINotebookCore/IngestionTypes.swift`; `Sources/AINotebookCore/TextDecoding.swift`; `Sources/AINotebookCore/CanonicalText.swift`; `Sources/AINotebookCore/ScalarChunker.swift`; `Tests/AINotebookCoreTests/IngestionPrimitivesTests.swift` | New primitives; extend WP3 ScalarChunker (WP3 plan:1348). Old trimming/graphemes: `PlainTextExtractor.swift:14`, `Chunker.swift:16`. |
| 3 [Windows] | `windows/src/AINotebook.Core/Ingestion/{FolderGlob.cs,IngestionTypes.cs,TextDecoding.cs,CanonicalText.cs}`; `windows/src/AINotebook.Core/Rag/ScalarChunker.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/IngestionPrimitivesTests.cs` | Twin primitives; old UTF-8-only decode: `Extractors/PlainTextExtractor.cs:31`. |
| 4 [Swift] | `Sources/AINotebookCore/{BoundedDocumentExtractor.swift,BoundedOfficeReader.swift,XlsxReader.swift}`; `Tests/AINotebookCoreTests/BoundedDocumentExtractorTests.swift` | New bounded extraction path; old XLSX sharedStrings-only: `OfficeExtractor.swift:20`. |
| 5 [Windows] | `windows/src/AINotebook.Core/Ingestion/{BoundedDocumentExtractor.cs,BoundedOfficeReader.cs,XlsxReader.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/BoundedDocumentExtractorTests.cs` | Twin; old unbounded ZIP copy: `Extractors/OfficeTextExtractor.cs:51`. |
| 6 [Swift] | `Sources/AINotebookCore/{FolderFileSystem.swift,NativeFolderFileSystem.swift,FolderWalk.swift}`; `Tests/AINotebookCoreTests/FolderFileSystemTests.swift` | Identity, no-follow reads and completed-subtree traversal. WP3 identity protocol: plan:590. |
| 7 [Windows] | `windows/src/AINotebook.Core/Ingestion/{FolderFileSystem.cs,NativeFolderFileSystem.cs,FolderWalk.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderFileSystemTests.cs` | Portable fake FS plus Windows handle/reparse tests. |
| 8 [Swift] | `Sources/AINotebookCore/{FolderScanner.swift,NotebookStore+FolderIngestion.swift,NotebookStore+Coverage.swift}`; `Tests/AINotebookCoreTests/FolderScannerTests.swift` | Scan generations, durable observations, rules and coverage; coverage file is a WP3 output. |
| 9 [Windows] | `windows/src/AINotebook.Core/Ingestion/FolderScanner.cs`; `windows/src/AINotebook.Core/Storage/{NotebookStore.FolderIngestion.cs,NotebookStore.Coverage.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderScannerTests.cs` | Twin transactions. |
| 10 [Swift] | `Sources/AINotebookCore/{JobQueue.swift,IngestionAdmission.swift,RescanSchedule.swift}`; `Tests/AINotebookCoreTests/IngestionQueueTests.swift` | Claim/renew loop, memory admission, chat priority and rescan deadlines. |
| 11 [Windows] | `windows/src/AINotebook.Core/Ingestion/{JobQueue.cs,IngestionAdmission.cs,RescanSchedule.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/IngestionQueueTests.cs` | Twin policies. |
| 12 [Swift] | `Sources/AINotebookCore/{FolderExtractionWorker.swift,SourceDescriptor.swift,NotebookStore+IngestionPublication.swift}`; `Tests/AINotebookCoreTests/FolderPublicationTests.swift` | Language hooks, stat/hash fence, immutable pages and atomic publish/enqueue. |
| 13 [Windows] | `windows/src/AINotebook.Core/Ingestion/{FolderExtractionWorker.cs,SourceDescriptor.cs}`; `windows/src/AINotebook.Core/Storage/NotebookStore.IngestionPublication.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderPublicationTests.cs` | Twin worker/publication. |
| 14 [Swift] | `Sources/AINotebookCore/{FolderIndexCoordinator.swift,NotebookStore+IngestionGenerations.swift,FolderReconciler.swift}`; `Sources/AINotebookCore/Providers/FolderEmbeddingSession.swift`; `Tests/AINotebookCoreTests/FolderGenerationTests.swift` | Fenced embedding batches, successor lifecycle, startup/periodic recovery. |
| 15 [Windows] | `windows/src/AINotebook.Core/Ingestion/{FolderIndexCoordinator.cs,FolderReconciler.cs}`; `windows/src/AINotebook.Core/Providers/FolderEmbeddingSession.cs`; `windows/src/AINotebook.Core/Storage/NotebookStore.IngestionGenerations.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderGenerationTests.cs` | Twin generation orchestration. |
| 16 [Swift] | `Sources/AINotebookCore/{FolderIngestionRuntime.swift,NotebookStore+IngestionPublication.swift,IngestionService.swift,Embedder.swift,EmbeddingWorker.swift,ChatEngine.swift,FolderWatcher.swift,LiveSourceSync.swift}`; `Sources/AINotebookApp/{AINotebookApp.swift,FolderWatchController.swift}`; `Tests/AINotebookCoreTests/{FolderIntegrationTests.swift,LiveSourceSyncTests.swift,FolderWatcherTests.swift}` | Replace duplicate entry points and session-only watcher; preserve E2. Existing wiring: `AINotebookApp.swift:46`, `LiveSourceSync.swift:54`. |
| 17 [Windows] | `windows/src/AINotebook.Core/Ingestion/{FolderIngestionRuntime.cs,IngestionService.cs,FolderWatchService.cs}`; `windows/src/AINotebook.Core/Storage/NotebookStore.IngestionPublication.cs`; `windows/src/AINotebook.Core/Rag/{Embedder.cs,EmbeddingWorker.cs,ChatEngine.cs}`; `windows/src/AINotebook.App/App.xaml.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/{FolderIntegrationTests.cs,FolderWatchServiceTests.cs}` | Twin integration and recursive FileSystemWatcher. |
| 18 [Swift-UI] | `Sources/AINotebookApp/{SourceListView.swift,FolderSourcesModel.swift,FolderRulesSheet.swift,FolderWatchController.swift}`; `Sources/AINotebookCore/Localization.swift`; `Tests/AINotebookCoreTests/FolderLocalizationTests.swift` | Persisted folder rows/picker/drop/rules and **all** WP6 EN/CS keys; existing view: `SourceListView.swift:28`. |
| 19 [Win-UI] | `windows/src/AINotebook.App/ViewModels/SourcesViewModel.cs`; `windows/src/AINotebook.App/Views/{SourceListPage.xaml,SourceListPage.xaml.cs,FolderRulesDialog.xaml,FolderRulesDialog.xaml.cs}`; `windows/src/AINotebook.App/Services/StringKey.cs`; `windows/src/AINotebook.App/Strings/{en-US,cs-CZ}/Resources.resw`; `windows/tests/AINotebook.App.Tests/{FolderSourcesTests.cs,LocalizedStringsTests.cs}` | Twin folder UI and all Windows keys. |
| 20 [Swift-UI] | `Sources/AINotebookApp/{ChatView.swift,FolderScopeModel.swift,SettingsView.swift,IndexingStatusBadge.swift}`; `Sources/AINotebookCore/{FolderScopeSelection.swift,NotebookStore+FolderScope.swift}`; `Tests/AINotebookCoreTests/FolderScopeTests.swift` | Explicit scopes and durable re-index progress. Current scope conflation: `ChatView.swift:48`; destructive action: `SettingsView.swift:408`. |
| 21 [Win-UI] | `windows/src/AINotebook.App/ViewModels/{ChatViewModel.cs,SettingsViewModel.cs,FolderScopeModel.cs}`; `windows/src/AINotebook.App/Views/{ChatPage.xaml,ChatPage.xaml.cs,SettingsDialog.xaml,SettingsDialog.xaml.cs,IndexingStatusBadge.xaml,IndexingStatusBadge.xaml.cs}`; `windows/src/AINotebook.Core/Rag/FolderScopeSelection.cs`; `windows/src/AINotebook.Core/Storage/NotebookStore.FolderScope.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderScopeTests.cs`; `windows/tests/AINotebook.App.Tests/FolderScopeBindingTests.cs` | Twin scope/re-index binding and App regression tests. |

Execution graph: **1 → (2 ∥ 3); 2 → (4 ∥ 6 ∥ 10); 3 → (5 ∥ 7 ∥ 11); 6 → 8; 7 → 9; (4,8,10) → 12; (5,9,11) → 13; 12 → 14 → 16 → 18 → 20; 13 → 15 → 17 → 19 → 21.** Every parallel pair has disjoint files. A task's opposite-platform twin is always independent after shared prerequisites. Tasks 18/19 own translations for subsequent tasks as well, avoiding localization conflicts.

## Frozen WP6 value types and operational rules

Tasks 2/3 produce public immutable `Sendable` Swift structs with explicit public initializers and C# records. All IDs/times/bytes are `Int64`/`long`; counts/offsets `Int`/`int`. Optional values map to nullable values. Collections are arrays in Swift and `IReadOnlyList<T>` in C#. This field table specifies constructor order on both platforms; C# uses PascalCase field names.

| Type | Fields (Swift spelling/types) |
|---|---|
| IngestionLimits | `fileBytes:Int64, officeBytes:Int64, textScalars:Int, pdfPages:Int, chunks:Int, cells:Int` |
| FolderRules | `includeExts:[String], ignoreGlobs:[String], limits:IngestionLimits, encodingFallback:String` |
| FileStamp | `identity:String, mtimeNs:Int64, sizeBytes:Int64` |
| PageBoundary | `page:Int, start:Int, end:Int` |
| CanonicalDocument | `text:String, title:String?, kind:String, pages:[PageBoundary], sheetNames:[String], encoding:String?` |
| DecodedText | `text:String, encoding:String` |
| FolderObservation | `relPath:String, stamp:FileStamp, kind:String, skipReason:String?, contentHash:String?` |
| ScanTicket | `folderId:Int64, generation:Int64, fence:JobFence` |
| ScanCompletion | `completed:[String], incomplete:[String], rootUnavailable:Bool, error:String?` |
| ExtractionRequest | `sourceId:Int64, folderId:Int64, relPath:String, stamp:FileStamp, hash:String, rules:FolderRules` |
| EmbeddingSelection | `providerId:String, endpointRevision:String, model:String, modelDigest:String?, dims:Int?, normalization:String, queryFormatVersion:String, docFormatVersion:String, chunkerVersion:String` |
| PublicationMetadata | `encoding:String?, lang:String?, coverageJSON:String?, descriptorJSON:String, pages:[PageBoundary]` |

`IngestionLimits.defaults` / `IngestionLimits.Defaults` uses the frozen scan constants plus **cells = 1,000,000** (an explicit WP6 additional safety ceiling; Claude reviews this value). Validate positive limits and maxima before scheduling work. JSON `limits` keys are `maxFileBytes,maxOfficeDecompressedBytes,maxExtractedChars,maxPdfPages,maxChunksPerFile,maxCells`; absent keys mean defaults. `FolderRules.defaults` / `Defaults`: supported extensions `pdf,txt,md,markdown,docx,pptx,xlsx`; ignore `.*,node_modules,.git,build,dist,.venv,__pycache__,target,bin,obj,~$*`; fallback `cp1250`. Normalize extension names by ASCII lowercase and optional leading dot; reject wildcards in the extension field.

`IngestionError` (Swift Error with `code:String`) / `FolderIngestionException` (`Code:string`) codes: `unsupportedSyntax`, `unsupportedEncoding`, `fileLimit`, `officeLimit`, `textLimit`, `pageLimit`, `chunkLimit`, `cellLimit`, `corruptArchive`, `invalidRelationship`, `invalidCell`, `rootUnavailable`, `rootIdentityChanged`, `outsideRoot`, `interiorLink`, `changedDuringExtraction`, `cancelled`, `invalidVector`. Declare Swift `public struct IngestionError: Error, Sendable { public let code:String; public init(code:String) { self.code=code } }` and C# `public sealed class FolderIngestionException(string code) : Exception(code) { public string Code { get; } = code; }` in the primitive type files. The latter deliberately does not collide with existing abstract IngestionException/UnsupportedExtension. Persist codes, localize display at the App boundary. Cancellation and stale leases never overwrite the new owner's error state.

Source metadata is deterministic JSON: descriptor `{version:1,title,type,pageCount,sheetCount,sizeBytes,lang}`; lang coverage `{version:1,langCoverageBp,sharesBp,unknownShareBp}`. Descriptor lang is an explicit JSON null when unknown: Swift custom encode calls `try container.encode(lang,forKey:.lang)` rather than synthesized encodeIfPresent; C# keeps null properties. Title preference: nonblank embedded title, first Markdown `# ` heading, filename without extension. Descriptors contain no summaries, LLM calls or absolute paths. Detector unavailability yields SQL NULL language/coverage, not `und`; completed inconclusive detection stores `und`.

## Task 1: [Shared] Freeze ingestion fixtures and bounded archive inputs

**Depends on:** corrected WP0 contracts; WP3/WP4 plans reviewed. **Parallel with:** no WP6 runtime task until this commit lands; independent predecessor work outside these files.

**Files:** `tools/contracts/{gen_ingestion_fixtures.py,test_ingestion_fixtures.py}`; `Tests/fixtures/contracts/ingestion-{encoding,canonical,office,scan,jobs,pipeline,generations,coverage,ui}-v1.json`; `Tests/fixtures/ingestion/{paragraphs.docx,slides.pptx,workbook.xlsx,pages.pdf,corrupt.docx,external.xlsx,bad-index.xlsx}`; no modification of the frozen generator.

**Interfaces — Consumes:** Swift `SharedFixtures.data(_ relativePath:String) throws -> Data`, `json(_:) throws -> [String:Any]`; C# `SharedFixtures.Path(string) -> string`, `Json(string) -> JsonElement`. **Produces:** Python `make_contracts() -> dict[str,dict]`, `write_assets(root:Path) -> None`, `generate(root:Path, check:bool=False) -> None`; CLI below. Each case has `name,operation,input,expected`; file inputs use a relative fixture `asset` path. Tests read actual expected objects; implementations never read fixtures.

- [ ] **Step 1 — write and run red generator tests.**

```python
import tempfile
import unittest
from pathlib import Path
from tools.contracts.gen_ingestion_fixtures import make_contracts, generate

class IngestionFixtureTests(unittest.TestCase):
    def test_deterministic_and_coverage_failure_keeps_old_evidence(self):
        contracts = make_contracts()
        cases = contracts['ingestion-coverage-v1.json']['cases']
        old = next(c for c in cases if c['name'] == 'published-refresh-error')
        self.assertEqual(old['expected'], dict(searchable=1, notSearchable=0,
            current=0, refreshPending=0, refreshError=1, skipped=0,
            missing=0, unavailable=0, isLowerBound=False))
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            generate(Path(a)); generate(Path(b))
            for p in Path(a).rglob('*'):
                if p.is_file():
                    self.assertEqual(p.read_bytes(), (Path(b)/p.relative_to(a)).read_bytes())
        for value in contracts.values():
            names = [c['name'] for c in value['cases']]
            self.assertEqual(len(names), len(set(names)))

if __name__ == '__main__': unittest.main()
```

Run `python3 -B -m unittest discover -s tools/contracts -p test_ingestion_fixtures.py -v` → FAIL: missing generator module. Also add tests rejecting invalid scalar spans, unknown trace operations and unreferenced assets.

- [ ] **Step 2 — encode these concrete cases.** The following is the fixture oracle, including exact additional syntax needed to remove parser ambiguity. Keep expected outputs literal or computed by the small independent arithmetic below; never run either production implementation to generate expected values.

| Contract | Required inputs and exact outcomes |
|---|---|
| encoding | Bytes are integer arrays. `utf8-bom`: `[239,187,191,65,10]` → text `A\n`, encoding `utf-8-bom`; `utf16le`: `[255,254,65,0,61,216,0,222]` → `A😀`, `utf-16le`; `utf16be`: `[254,255,0,65,216,61,222,0]` → `A😀`, `utf-16be`; `plain-utf8`: UTF-8 of `  Čau\r\n` preserves every scalar, `utf-8`; `cp1250`: `[80,248,237,108,105,154]` → `Příliš`, `windows-1250`. |
| encoding | `cp1250-disabled` uses those bytes/fallback `none` → `unsupportedEncoding`; `bad-bom-utf8` `[239,187,191,255]`, `odd-utf16` `[255,254,65]`, `unpaired-utf16` `[254,255,216,0]` fail even with fallback enabled. An explicit BOM commits to its codec. `bad-utf8-cp1250` `[195,40]` with fallback cp1250 → `Ă(`. `undefined-cp1250` `[129]` → `unsupportedEncoding` on both platforms. `empty` → empty canonical text and zero chunks. |
| canonical | `scalar-trim`: input `  A😀éZ  `, window2048/overlap256 → canonical unchanged, chunk `A😀éZ` at [2,7), tokenCount2. `pdf-empty-middle`: pages [`A😀`, ``, `éZ`] → `A😀\n\n\n\néZ`; page intervals (1,0,2),(2,4,4),(3,6,9). Chunk [0,9) crosses pages1–3. |
| canonical | `docx`: paragraphs [`A`,`B😀`,``] → `A\nB😀\n`. `pptx`: slide texts [`A`,`B`] → `## Slide 1\nA\n\n## Slide 2\nB`. `window-cross-page`: PDF pages lengths2050 and30, expected chunks computed by the WP3 whitespace algorithm, including overlap/scalar ends and page ranges. `long-word`: 4097 `x`, windows2048/256 → spans [0,2048),[1792,3840),[3584,4097). `chunk-limit`: same input/maxChunks2 → `chunkLimit`, never partial publication. |
| office | `workbook-order`: workbook sheets Zeta→rIdB then Alpha→rIdA; relationships deliberately target sheet2.xml and sheet1.xml. Zeta A1 shared string `Příliš`, C1 inline rich text `A😀B`, A2 number `42`, B2 boolean `TRUE`, C2 error `#DIV/0!`, A3 formula/cached value `2 [cached formula]`, C3 date-style serial `45292 [date serial]`. Alpha A1 `last`. Expected text: `## Zeta\nA1: Příliš\tC1: A😀B\nA2: 42\tB2: TRUE\tC2: #DIV/0!\nA3: 2 [cached formula]\tC3: 45292 [date serial]\n\n## Alpha\nA1: last`. |
| office | `paragraphs` and `slides` assets match canonical cases; slide relationship order differs from lexical filenames (slide10 before slide2 in XML order). `formula-no-cache` renders `[formula; no cached value]`; cached formula+date appends `[cached formula] [date serial]`. Blank cells omitted, coordinates preserve gaps; rows/cells sorted numerically by row/column. Empty sheet retains its header. Invalid shared index/cell reference/duplicate coordinate → `invalidCell`; missing/external/escaping relationship → `invalidRelationship`; malformed XML/ZIP → `corruptArchive`. Formula strings are never evaluated or used to access anything. |
| office | Lower injected limits: archive expansion one byte beyond ceiling → `officeLimit`; canonical one scalar beyond → `textLimit`; cells limit2 with third cell → `cellLimit`; page limit1 for 3-page PDF → `pageLimit` before fetching page text. Actual decompressed-byte counter catches dishonest ZIP length headers. DTD/external entity input rejected; no external resolver. |
| scan | Event traces use `list`, `stat`, `read`, `deny`, `cancel`, `rootUnavailable`, `finish`. Cases: nested eligible file; every default ignore; unsupported `.png`; oversize file; directory skip still lists regular descendants into skipped inventory; interior file/dir link; root alias allowed once; retargeted root rejected; outside component (`docs2`) rejected; case-sensitive Docs/docs distinct; case-insensitive aliases one source; reparse/junction skipped; no-follow open race; directory identity swap. |
| scan | `fast-path`: stored stamp(file1,10,5)/hash h, observed equal → readCalls0/extractJobs0. `same-hash`: mtime11/size5/read hash h → metadata only/readCalls1/jobs0. `verify-all`: equal stat forces readCalls1. `changed`: hash differs → one queued extract/status pending, old published retained. Two scans coalesce duplicate work. Same bytes renamed produce missing old path and new source (no identity-based merge). |
| scan | `partial-sibling`: old `good/gone.md`,`bad/gone.md`,`gone.md`; root listing succeeds, good subtree completes, bad fails → only good/gone missing; bad/gone and root/gone unchanged because the root subtree is incomplete. Full follow-up marks the remaining absent paths missing. `cancelled`, `late-old-generation`, `root-offline`, `unexpected-error` never mark unseen files outside completed subtrees. Reappearance restores present. Rule disable marks eligible0 without missing; rule re-enable creates pending work only when needed. |
| jobs | supplement frozen job transitions with `two-claims`, `restart-expiry`, `renew-60` (lease300→360 at60), `stale-fail`, `stale-publish`, `token-unique` (100 claims all distinct), `exhausted-user-retry` (new id attempts0), `concurrency-two`, `memory-one`, `chat-two-tokens`, `chat-query-unblocked`, `cancel-releases`, `debounce` signals0,400,800 → due1300, `max-coalesce` signals0..4900 every100 → due5000, `signal-during-scan` → exactly one trailing scan. |
| pipeline | `publish-short`: canonical `A😀éZ`, detector enabled → `und`, coverage0, inheritedfalse, encodingutf-8, one scalar-span chunk. `detector-unavailable` → null language/coverage. `inherit-short` uses a cs-winning synthetic test model and short final chunk, expected cs/true; low-confidence-und and mixed document never inherit. `stat-changed`, `hash-changed-same-stat`, `new-observation-before-commit`, `expired-owner`, `replaced-owner` publish nothing and retain old revision; genuine change requeues fresh work. `metadata-and-embed-atomic` rollback proves no partial chunks/descriptor/page-map/job. |
| generations | `new-generation`, `copy-identical`, `different-model-no-copy`, `ingest-during-build`, `stale-batch`, `lease-lost-batch`, `chat-pause-between-batches`, `activate-atomic`, `failed-build-keeps-active`, `discard-keeps-active`, `restart-resumes`, `selected-provider-changed`, `lexical-only`, `scope-revocation`, `periodic-1800`, `watch-disabled-startup`, `unknown-dimensions-bootstrap`, `empty-bootstrap`, `endpoint-changed-between-batches`, `fifth-embed-failure`, `bootstrap-stale-fence`. Expected active id unchanged until every latest manifest row done/excluded; pin keeps old vectors; paused chat starts no new background batch, question embedding runs. |
| coverage | Six contract table rows: first pending→notSearchable1/refreshPending1; first failed→notSearchable1/refreshError1; published current→searchable1/current1; published refresh queued→searchable1/refreshPending1; published refresh failed→searchable1/refreshError1; newly published with older/no vectors→searchable1/current1. Add `observed-not-extracted` with equal current/published pointers and pending status; availability precedence, skipped-source/inventory dedup, source-less skipped/eligible, empty selection, other notebook, duplicate folder/source selection, partial empty folder lower-bound, explicit source in partial folder. All unspecified counts are zero. |

| ui | 51 localization cases from the UI text table, operation `localization`, input `{key}`, expected `{en,cs}`. Scope cases use operation `scope`, input `{wholeNotebook,sourceIds,folderIds,setIds,members:[{setId,sourceIds,folderIds}]}`, expected typed `{kind,sourceIds,folderIds}` (all omits ID fields). Freeze all, empty, duplicate union, all-sources-explicit, set membership old/new, removed-set cases. Removed explicit folder and cross-notebook rejection are separate `scope-store` cases with seeded notebooks/sources/folders/sets and expected `{scope}` or `{error}`; the real-store tests dispatch them, not the pure reducer. Event cases use operation `watch`, input `{kind}`, expected `{forceHash}`: created=false, changed/renamed/deleted/overflow=true. Runtime cases use operation `runtime`, seed folders/jobs and events start/stop/watch/remove/signal/tick/drain, expected watchedFolderIds/queuedJobIds/providerCallCount. Include two notebooks, watch-disabled, callback-after-remove, source/URL-refresh and one trailing scan. |

Trace inputs have explicit folder/source/revision IDs and `at`, with `expected` projections after **each** event: source status/availability/eligibility/pointers, scan state/generation, inventory, jobs, filesystem read counts. Generation cases likewise contain seed identities, source revisions, deterministic vectors `[1,0]`/`[0,1]`, ordered events and expected manifests/active IDs/provider-call counts. Use operation switches, not case-name substring matching.

### Concrete walk fixture and adapter

For `operation="walk"`, `input.root` has the exact fields below; `directories` maps relative directory paths to immediate entry arrays (`relPath,isDirectory,isLink`); `stats` maps relative paths to `FileStamp`; `listErrors` maps paths to `permissionDenied`. `""` denotes root. Every listed entry must have a stat. An absent directory listing is an unexpected-access test failure, never an empty directory. `seedSources` defines the scanner's preexisting rows (published canonical text `old`, scalar chunk `[0,3)`); the walker ignores these rows. The scanner's separate test asserts `missingSourceIds`; the pure walk test asserts `completion` and `listCalls`. No mock produces a ScanCompletion.

```json
{
  "name":"partial-sibling","operation":"walk",
  "input":{
    "root":{"id":1,"notebookId":1,"rootPath":"/docs","displayName":"Docs",
      "volumeId":"test","components":["docs"],"rootFileId":"root-1"},
    "caseSensitive":true,
    "directories":{
      "":[{"relPath":"bad","isDirectory":true,"isLink":false},
            {"relPath":"good","isDirectory":true,"isLink":false}],"good":[]},
    "stats":{
      "":{"identity":"root-1","mtimeNs":0,"sizeBytes":0},
      "bad":{"identity":"dir-bad","mtimeNs":0,"sizeBytes":0},
      "good":{"identity":"dir-good","mtimeNs":0,"sizeBytes":0}},
    "listErrors":{"bad":"permissionDenied"},
    "seedSources":[
      {"id":101,"relPath":"good/gone.md","canonicalText":"old"},
      {"id":102,"relPath":"bad/gone.md","canonicalText":"old"},
      {"id":103,"relPath":"gone.md","canonicalText":"old"}]
  },
  "expected":{
    "completion":{"completed":["good"],"incomplete":["bad",""],"rootUnavailable":false},
    "listCalls":["","bad","good"],"missingSourceIds":[101]
  }
}
```


- [ ] **Step 3 — implement deterministic generation.** `json.dumps(value,ensure_ascii=False,sort_keys=True,indent=2)+'\n'`; fixed ZIP entry order, UTF-8 XML, ZIP_STORED and timestamp `(1980,1,1,0,0,0)`; compute PDF xref offsets from actual bytes, fixed metadata, Helvetica text `A`, blank page, `B` (PDF engine integration tests avoid font-dependent Unicode extraction). Canonical Unicode/page tests use explicit page strings. Assets are deliberately tiny; simulated streams exercise large limits without committing 200 MB files. Copy the existing synthetic `lang-score-v1.json` model into pipeline fixture input, relabel xa→cs and xb→sk consistently, retaining integer weights; this is only a test model supplied through WP4's internal test constructor, never bundled for production.

```python
def scalar_windows(text, window=2048, overlap=256):
    white = set(range(9,14)) | {32,133,160,5760,8232,8233,8239,8287,12288} | set(range(8192,8203))
    out, start = [], 0
    while start < len(text):
        end = min(start + window, len(text))
        if end < len(text):
            probe, floor = end, max(end-200,start+1)
            while probe > floor and ord(text[probe-1]) not in white: probe -= 1
            if probe > floor: end = probe
        lo, hi = start, end
        while lo < hi and ord(text[lo]) in white: lo += 1
        while hi > lo and ord(text[hi-1]) in white: hi -= 1
        if lo < hi: out.append(dict(text=text[lo:hi],start=lo,end=hi,tokens=max(1,(hi-lo+3)//4)))
        if end == len(text): break
        start = max(end-overlap,start+1)
    return out
```

The coverage fixture seed is `input:{availability,eligible,status,currentRevision,publishedRevisionId,activeVectorRevision,scanState,hasScanItem,scanKind}`; null revision IDs are explicit. A nonnull revision seed creates immutable text `old` and chunk `[0,3)` owned by that source before pointers are set. The oracle projects exactly `{searchable,notSearchable,current,refreshPending,refreshError,skipped,missing,unavailable,isLowerBound}`; no legacy pending/error names appear in expected JSON. These six rows are literal inputs/outputs (source present/eligible, folder idle, no separate skipped inventory):

| Case | status / current / published / vector | searchable | notSearchable | current | refreshPending | refreshError |
|---|---|---:|---:|---:|---:|---:|
| first-pending | pending / null / null / null | 0 | 1 | 0 | 1 | 0 |
| first-error | error / null / null / null | 0 | 1 | 0 | 0 | 1 |
| published-current | ready / 1 / 1 / 1 | 1 | 0 | 1 | 0 | 0 |
| published-refresh-pending | chunking / 2 / 1 / 1 | 1 | 0 | 0 | 1 | 0 |
| published-refresh-error | error / 2 / 1 / 1 | 1 | 0 | 0 | 0 | 1 |
| newly-published | ready / 2 / 2 / 1 | 1 | 0 | 1 | 0 | 0 |

For every row skipped/missing/unavailable=0 and isLowerBound=false. Also run newly-published with activeVectorRevision=null. Observed-not-extracted is status=pending/current=1/published=1 and has exactly the published-refresh-pending projection. `scope-store` fixtures carry full seed arrays with notebook IDs, followed by selected IDs and expected typed scope/error; pure `scope` fixtures never require a database or existence pruning.

Build coverage expected values independently from the decision table, not SQL. Exclude timestamps, SQLite/tool versions and machine paths from bytes. `--check` regenerates in a temporary directory and compares every owned asset; normal generation writes only the listed paths. Unknown case operations and missing references fail generator validation.

- [ ] **Step 4 — green and commit.**

```bash
python3 -B tools/contracts/gen_ingestion_fixtures.py
python3 -B tools/contracts/gen_ingestion_fixtures.py --check
python3 -B -m unittest discover -s tools/contracts -p test_ingestion_fixtures.py -v
swift test --filter SharedFixturesTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/contracts/gen_ingestion_fixtures.py tools/contracts/test_ingestion_fixtures.py Tests/fixtures/contracts/ingestion-encoding-v1.json Tests/fixtures/contracts/ingestion-canonical-v1.json Tests/fixtures/contracts/ingestion-office-v1.json Tests/fixtures/contracts/ingestion-scan-v1.json Tests/fixtures/contracts/ingestion-jobs-v1.json Tests/fixtures/contracts/ingestion-pipeline-v1.json Tests/fixtures/contracts/ingestion-generations-v1.json Tests/fixtures/contracts/ingestion-coverage-v1.json Tests/fixtures/contracts/ingestion-ui-v1.json Tests/fixtures/ingestion/paragraphs.docx Tests/fixtures/ingestion/slides.pptx Tests/fixtures/ingestion/workbook.xlsx Tests/fixtures/ingestion/pages.pdf Tests/fixtures/ingestion/corrupt.docx Tests/fixtures/ingestion/external.xlsx Tests/fixtures/ingestion/bad-index.xlsx
git commit -m "test(ingestion): freeze shared folder ingestion cases" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: generator/check exit0, Python tests OK, both fixture-envelope tests and full suites green. Record case counts for all nine new contracts in the handoff.

## Task 2: [Swift] Glob, strict decoding, canonical assembly and bounded scalar chunks

**Depends on:** 1, corrected WP3, WP4 UnicodeTables. **Parallel with:** 3 and its downstream lane.

**Files:** `Sources/AINotebookCore/FolderGlob.swift`, `Sources/AINotebookCore/IngestionTypes.swift`, `Sources/AINotebookCore/TextDecoding.swift`, `Sources/AINotebookCore/CanonicalText.swift`, `Sources/AINotebookCore/ScalarChunker.swift`, `Tests/AINotebookCoreTests/IngestionPrimitivesTests.swift`; `ScalarChunker.swift` is WP3's output, not today's legacy `Chunker.swift`.

**Interfaces — Consumes:** `UnicodeTables.bundled() throws -> UnicodeTables`, `simpleLowercase(_ scalar:UInt32)->UInt32`; C# `UnicodeTables.LoadBundled()`, `SimpleLowercase(int)->int`. WP3 `ScalarChunker.chunk(_:pageStarts:window:overlap:)` / `ScalarChunker.Chunk(string,IReadOnlyList<(int Offset,int Page)>?,int,int)` returns revision chunk drafts. **Produces:** frozen value types above and:

```swift
public struct FolderGlob: Sendable {
    public init(_ pattern: String, caseSensitive: Bool, tables: UnicodeTables) throws
    public func matches(_ relativePath: String) -> Bool
}
public enum TextDecoding {
    public static func decode(_ bytes: Data, fallback: String, maxScalars: Int) throws -> DecodedText
}
public enum CanonicalText {
    public static func assemble(kind: String, parts: [String], names: [String] = [],
                                maxScalars: Int) throws -> CanonicalDocument
}
extension ScalarChunker {
    public static func bounded(_ text: String, pages: [PageBoundary], window: Int = 2048,
                               overlap: Int = 256, maxChunks: Int) throws -> [RevisionChunkDraft]
}
```

C# peer: `FolderGlob(string pattern,bool caseSensitive,UnicodeTables tables)`, `bool Matches(string relativePath)`; `TextDecoding.Decode(byte[] bytes,string fallback,int maxScalars)->DecodedText`; `CanonicalText.Assemble(string kind,IReadOnlyList<string> parts,IReadOnlyList<string>? names,int maxScalars)->CanonicalDocument`; `ScalarChunker.Bounded(string text,IReadOnlyList<PageBoundary> pages,int maxChunks,int window=2048,int overlap=256)->IReadOnlyList<RevisionChunkDraft>`.

- [ ] **Step 1 — red tests.**

```swift
import XCTest
@testable import AINotebookCore
final class IngestionPrimitivesTests: XCTestCase {
    func testStrictEncodingFixtures() throws {
        let f = try SharedFixtures.json("contracts/ingestion-encoding-v1.json")
        for c in try XCTUnwrap(f["cases"] as? [[String:Any]]) {
            let i = c["input"] as! [String:Any], e = c["expected"] as! [String:Any]
            let data = Data((i["bytes"] as! [Int]).map { UInt8($0) })
            if let code = e["error"] as? String {
                XCTAssertThrowsError(try TextDecoding.decode(data, fallback:i["fallback"] as! String, maxScalars:100)) {
                    XCTAssertEqual(($0 as? IngestionError)?.code, code)
                }
            } else {
                let got = try TextDecoding.decode(data, fallback:i["fallback"] as! String, maxScalars:100)
                XCTAssertEqual(Array(got.text.unicodeScalars), Array((e["text"] as! String).unicodeScalars))
                XCTAssertEqual(got.encoding,e["encoding"] as? String)
            }
        }
    }
    func testGlobUsesPinnedSimpleLowercase() throws {
        let tables = try UnicodeTables.bundled()
        XCTAssertTrue(try FolderGlob("/İ/**/𐐀?.md/",caseSensitive:false,tables:tables).matches("i/𐐨😀.md"))
        XCTAssertThrowsError(try FolderGlob("///",caseSensitive:true,tables:tables))
    }
}
```

Run `swift test --filter IngestionPrimitivesTests` → missing TextDecoding/FolderGlob FAIL. Add `testAllGlobFixtures` (all 53 cases, native expected syntax), `testCanonicalAndSpans`, `testLimitsBeforeAppend`, `testRuleValidation` before implementing.

- [ ] **Step 2 — implement normalized glob dynamic programming.** Determine anchored from the original leading `/` or inner `/` after stripping outer separators. Reject empty, slash-only, leading `!`, `[ ] { } \`. Split normalized components once, dropping repeated separators. For unanchored single-component rules test every path component. For anchored rules match every ancestor prefix including the full path. Component wildcard matching uses scalar arrays with memoized `(patternOffset,textOffset)`; `*` branches zero/one scalar, `?` consumes exactly one, literal equality after pinned simple lowercase. Whole-component `**` branches zero/one **component**. Avoid recursive exponential backtracking; memoize or use iterative DP. Never use regex or native lowercase. Embedded `a**b` is ordinary repeated `*` within one component.

- [ ] **Step 3 — implement bounded decoding and canonical assembly.** Check bytes length in the file reader before allocation. Decode BOM first; reject invalid BOM-selected content instead of retrying cp1250. Use strict UTF-8 validation and strict UTF-16 surrogate pairing/odd-byte rejection. Reject undefined cp1250 bytes 81/83/88/90/98 hex explicitly; Foundation's fallback must not replace them. Decode remaining cp1250 through `.windowsCP1250`, checking exact round-trip bytes. Record the encoding names from fixtures. Preserve CR/LF/whitespace and never normalize canonical text. Count scalars incrementally while decoding and append only if new count ≤ limit.

Assembly appends separators and headers through a checked builder. PDF preserves empty pages; store content intervals excluding inserted separators. DOCX `\n`, PPTX `## Slide n\n` + `\n\n`, XLSX `## name\n` and contract rows, plain text exactly decoded. No trailing global trim. Extend WP3 scalar chunker with bounded overload; keep old API and algorithm unchanged. Before appending each chunk, enforce maxChunks; return no partial result on error. `pageHint` is the first intersecting nonempty page; pageFrom/pageTo are later computed from the immutable page map. Separator-only spans have no page evidence.

```swift
func checkedAppend(_ value: String, to result: inout String, count: inout Int, limit: Int) throws {
    let added = value.unicodeScalars.count
    guard added <= limit - count else { throw IngestionError(code: "textLimit") }
    result += value
    count += added
}
```

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter IngestionPrimitivesTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/FolderGlob.swift Sources/AINotebookCore/IngestionTypes.swift Sources/AINotebookCore/TextDecoding.swift Sources/AINotebookCore/CanonicalText.swift Sources/AINotebookCore/ScalarChunker.swift Tests/AINotebookCoreTests/IngestionPrimitivesTests.swift
git commit -m "feat(ingestion): Swift glob decoding and canonical scalar primitives" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: six new test methods, every glob/encoding/canonical case green; existing chunker tests unchanged; both full suites pass.

## Task 3: [Windows] Glob, strict decoding, canonical assembly and bounded scalar chunks

**Depends on:** 1, corrected WP3, WP4 UnicodeTables. **Parallel with:** 2 and its downstream lane.

**Files:** `windows/src/AINotebook.Core/Ingestion/{FolderGlob.cs,IngestionTypes.cs,TextDecoding.cs,CanonicalText.cs}`; `windows/src/AINotebook.Core/Rag/ScalarChunker.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/IngestionPrimitivesTests.cs`

**Interfaces — Consumes:** C# UnicodeTables and WP3 ScalarChunker signatures in Task 2; Swift twins are the same named boundary there. **Produces:** every C# primitive signature in Task 2 plus the frozen DTOs; Swift parity signatures are the complete Swift declaration block there.

- [ ] **Step 1 — red tests.**

```csharp
using System.Text;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;
public sealed class IngestionPrimitivesTests {
    [Fact] public void StrictEncodingFixtures() {
        foreach (var c in SharedFixtures.Json("contracts/ingestion-encoding-v1.json").GetProperty("cases").EnumerateArray()) {
            var i=c.GetProperty("input"); var e=c.GetProperty("expected");
            var bytes=i.GetProperty("bytes").EnumerateArray().Select(x=>x.GetByte()).ToArray();
            if(e.TryGetProperty("error",out var error)) {
                var ex=Assert.Throws<FolderIngestionException>(()=>TextDecoding.Decode(bytes,i.GetProperty("fallback").GetString()!,100));
                Assert.Equal(error.GetString(),ex.Code);
            } else {
                var got=TextDecoding.Decode(bytes,i.GetProperty("fallback").GetString()!,100);
                Assert.Equal(e.GetProperty("text").GetString(),got.Text);
                Assert.Equal(e.GetProperty("encoding").GetString(),got.Encoding);
            }
        }
    }
    [Fact] public void GlobUsesPinnedSimpleLowercase() {
        var tables=UnicodeTables.LoadBundled();
        Assert.True(new FolderGlob("/İ/**/𐐀?.md/",false,tables).Matches("i/𐐨😀.md"));
        Assert.Equal("unsupportedSyntax",Assert.Throws<FolderIngestionException>(()=>new FolderGlob("///",true,tables)).Code);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~IngestionPrimitivesTests` → missing primitive symbols FAIL. Add Facts `AllGlobFixtures`, `CanonicalAndSpans`, `LimitsBeforeAppend`, `RuleValidation` covering every shared case.

- [ ] **Step 2 — implement the normalized component matcher.** Save original anchoring, remove outer/repeated separators once, reject unsupported grammar. Enumerate runes to integer arrays, applying `tables.SimpleLowercase` only on case-insensitive volumes. Two iterative DP tables implement component wildcard and path-component `**`; anchored matches include ancestor prefixes, unanchored matches any component. `?` consumes one rune, never one UTF-16 char. No `ToLowerInvariant`/regex matcher.

- [ ] **Step 3 — strict codecs and scalar assembly.** Register once with `Encoding.RegisterProvider(CodePagesEncodingProvider.Instance)`. Use `new UTF8Encoding(false,true)`, `new UnicodeEncoding(false,false,true)`, `new UnicodeEncoding(true,false,true)` and `Encoding.GetEncoding(1250,EncoderFallback.ExceptionFallback,DecoderFallback.ExceptionFallback)`. Explicitly reject undefined cp1250 bytes `0x81,0x83,0x88,0x90,0x98` before that decoder. BOM errors are terminal. For bounded file paths feed `Decoder.Convert` into a fixed buffer and count decoded runes, carrying a trailing high surrogate across buffers. A `byte[]` test facade uses the identical engine. Preserve original decoded text and named encoding.

```csharp
static void CheckedAppend(StringBuilder builder,string value,ref int count,int limit) {
    int added=value.EnumerateRunes().Count();
    if(added>limit-count) throw new FolderIngestionException("textLimit");
    builder.Append(value); count+=added;
}
```

Canonical assembly retains empty PDF pages, separators, DOCX paragraphs, slide headers and sheet headers. Extend WP3 `Rag/ScalarChunker.cs` with Bounded: enumerate scalars, use its fixed whitespace set/window algorithm, enforce chunk count before append, preserve exact scalar spans. No change to legacy Chunker or its tests.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~IngestionPrimitivesTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Ingestion/FolderGlob.cs windows/src/AINotebook.Core/Ingestion/IngestionTypes.cs windows/src/AINotebook.Core/Ingestion/TextDecoding.cs windows/src/AINotebook.Core/Ingestion/CanonicalText.cs windows/src/AINotebook.Core/Rag/ScalarChunker.cs windows/tests/AINotebook.Core.Tests/Ingestion/IngestionPrimitivesTests.cs
git commit -m "feat(win-ingestion): glob strict codecs and canonical scalar primitives" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: six new Facts and every shared primitive case pass; both full suites green. No package/version change.

## Task 4: [Swift] Bounded PDF/text and relationship-driven Office extraction

**Depends on:** 2. **Parallel with:** 3, 5, 6, 7, 10, 11 after their dependencies.

**Files:** `Sources/AINotebookCore/{BoundedDocumentExtractor.swift,BoundedOfficeReader.swift,XlsxReader.swift}`; `Tests/AINotebookCoreTests/BoundedDocumentExtractorTests.swift`. Existing extractors remain compatibility wrappers until Task16 changes the production dispatch; do not edit their old tests to excuse malformed fixtures.

**Interfaces — Consumes:** Swift `TextDecoding.decode`, `CanonicalText.assemble`, frozen `IngestionLimits`; C# exact peers from Tasks2/3. **Produces:**

```swift
public struct BoundedDocumentExtractor: Sendable {
    public init()
    public func extract(url: URL, kind: SourceType, rules: FolderRules) async throws -> CanonicalDocument
}
struct BoundedOfficeReader {
    init(url: URL, limits: IngestionLimits) throws
    func read(kind: SourceType) throws -> CanonicalDocument
}
enum XlsxReader {
    static func read(_ archive: BoundedOfficeReader) throws -> CanonicalDocument
}
```

C# peers: `BoundedDocumentExtractor.ExtractAsync(Uri url,SourceType kind,FolderRules rules,CancellationToken ct=default)->Task<CanonicalDocument>`; internal `BoundedOfficeReader(string path,IngestionLimits limits) : IDisposable`, `CanonicalDocument Read(SourceType kind)`; `XlsxReader.Read(BoundedOfficeReader archive)->CanonicalDocument`. The extractor facade is injectable through a closure in later workers; no network method.

- [ ] **Step 1 — red golden test and limit test.**

```swift
import XCTest
@testable import AINotebookCore
final class BoundedDocumentExtractorTests: XCTestCase {
    func testWorkbookRelationshipOrderAndValues() async throws {
        let f = try SharedFixtures.json("contracts/ingestion-office-v1.json")
        let c = try XCTUnwrap((f["cases"] as? [[String:Any]])?.first { $0["name"] as? String == "workbook-order" })
        let input=c["input"] as! [String:Any], expected=c["expected"] as! [String:Any]
        let result=try await BoundedDocumentExtractor().extract(
            url:SharedFixtures.url(input["asset"] as! String),kind:.xlsx,rules:.defaults)
        XCTAssertEqual(Array(result.text.utf8),Array((expected["text"] as! String).utf8))
        XCTAssertEqual(result.sheetNames,["Zeta","Alpha"])
    }
    func testPageLimitBeforeTextRead() async throws {
        let limits=IngestionLimits(fileBytes:52_428_800,officeBytes:209_715_200,
            textScalars:5_000_000,pdfPages:1,chunks:5_000,cells:1_000_000)
        let rules=FolderRules(includeExts:["pdf"],ignoreGlobs:[],limits:limits,encodingFallback:"none")
        do {
            _=try await BoundedDocumentExtractor().extract(url:SharedFixtures.url("ingestion/pages.pdf"),kind:.pdf,rules:rules)
            XCTFail("expected pageLimit")
        } catch { XCTAssertEqual((error as? IngestionError)?.code,"pageLimit") }
    }
}
```

Run `swift test --filter BoundedDocumentExtractorTests` → missing extractor FAIL. Add `testAllOfficeCases`, `testCanonicalTextAndPDF`, `testExpandedBytesActualCount`, `testCellAndScalarBounds`, `testCancellationClosesReaders` (seven methods total). Use internal reader callbacks in the test file to count decompressed bytes/cells/page text accesses and prove no third cell/page access after the corresponding limit.

- [ ] **Step 2 — implement bounded text/PDF.** Open local files only, check file size before reading, use 64 KiB blocks and incremental strict decoding for text. PDFKit: inspect page count immediately after opening, reject over limit before `page(at:)?.string`; visit every page in order including empty pages; trim only the page-local PDF engine's outer whitespace using the fixed chunker whitespace set, then append via canonical builder. A PDF page string is an unavoidable PDFKit allocation; do not claim the scalar cap bounds the internals of PDFKit. Limit total output before builder append, reserve the worker's PDF memory allowance, and record this library limitation in the gate's memory test. Empty decoded text/empty document is a successful empty revision (legacy wrappers may retain their old `emptyContent` behavior). Read title metadata but never normalize extracted Unicode.

- [ ] **Step 3 — implement streaming Office readers.** Preflight all ZIP members (including unused members) with overflow-safe sum of declared uncompressed lengths against officeBytes. Reject encrypted/duplicate-normalized names, absolute names and normalized archive traversal. Normalize relationship targets relative to the owning part; permit legitimate `../` only when normalization stays within archive root; reject external targets and unknown required relation IDs. Actual extraction wraps each ZIPFoundation callback with a shared expanded-byte counter before buffering. Never concatenate the whole archive. Feed XMLParser from a bounded temporary spool/InputStream; delete spool on cancellation/error; disable external entities and reject DOCTYPE. Parse namespaces and element roles, not every arbitrary character node.

DOCX uses document/body `w:p`; concatenate `w:t` runs without inserted spaces, `w:tab` as tab and `w:br` as LF; join paragraphs with LF, preserving empty paragraphs. PPTX reads `presentation.xml` sldId order and its relationships, joins slide paragraphs with LF, prefixes every slide including empty slides. Excel resolves workbook/sheets and relationships in workbook order; sharedStrings concatenates rich-text `t` runs, inline strings likewise. Numeric lexemes are retained, booleans 0/1 become FALSE/TRUE, errors retain their text. Missing formula cache renders the frozen marker. For styles, read cellXfs→numFmtId; built-in date IDs 14–22,27–36,45–47,50–58 are date-style. Custom formats strip quoted/escaped literals and color/condition brackets; unquoted y/m/d/h/s or `[h]`/`[m]`/`[s]` classify date/time; numeric scientific `E` does not. Retain raw numeric serial, including 1904 workbook mode; append the marker, never invent a date conversion.

Count every `<c>` before allocating a cell record; parse and validate A1 coordinates, ordered row/column identity and shared-string indices; repeated coordinates fail. Count scalar output before appending each value/header/tab/newline, including markers. Shared strings and metadata also share the Office byte ceiling; no unconstrained dictionary sized from an attacker-supplied count. Numeric cell text/format strings are bounded by the text ceiling even before row assembly. Use a dictionary only for actually referenced style/string IDs; archive entry count/metadata itself remains subject to the input-byte bound. Error maps are exact typed `IngestionError` codes.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter BoundedDocumentExtractorTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/BoundedDocumentExtractor.swift Sources/AINotebookCore/BoundedOfficeReader.swift Sources/AINotebookCore/XlsxReader.swift Tests/AINotebookCoreTests/BoundedDocumentExtractorTests.swift
git commit -m "feat(ingestion): bounded canonical PDF and Office extraction" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: seven methods green, all office cases visited, old extractor tests still green.

## Task 5: [Windows] Bounded PDF/text and relationship-driven Office extraction

**Depends on:** 3. **Parallel with:** 2, 4, 6, 7, 10, 11 after their dependencies.

**Files:** `windows/src/AINotebook.Core/Ingestion/{BoundedDocumentExtractor.cs,BoundedOfficeReader.cs,XlsxReader.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/BoundedDocumentExtractorTests.cs`

**Interfaces — Consumes:** `TextDecoding.Decode`, `CanonicalText.Assemble`, `IngestionLimits`; Swift twins from Task2. **Produces:** all C# extractor/Office/XLSX signatures in Task4; Swift `BoundedDocumentExtractor.extract(url:kind:rules:) async throws -> CanonicalDocument` is its parity boundary.

- [ ] **Step 1 — red test.**

```csharp
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Tests.Helpers;
using Xunit;
public sealed class BoundedDocumentExtractorTests {
    [Fact] public async Task WorkbookRelationshipOrderAndValues() {
        var c=SharedFixtures.Json("contracts/ingestion-office-v1.json").GetProperty("cases")
            .EnumerateArray().Single(x=>x.GetProperty("name").GetString()=="workbook-order");
        var got=await new BoundedDocumentExtractor().ExtractAsync(
            new Uri(SharedFixtures.Path(c.GetProperty("input").GetProperty("asset").GetString()!)),
            SourceType.Xlsx,FolderRules.Defaults);
        Assert.Equal(c.GetProperty("expected").GetProperty("text").GetString(),got.Text);
        Assert.Equal(new[]{"Zeta","Alpha"},got.SheetNames);
    }
    [Fact] public async Task PageLimitBeforeTextRead() {
        var rules=FolderRules.Defaults with { Limits=IngestionLimits.Defaults with { PdfPages=1 } };
        var ex=await Assert.ThrowsAsync<FolderIngestionException>(()=>new BoundedDocumentExtractor().ExtractAsync(
            new Uri(SharedFixtures.Path("ingestion/pages.pdf")),SourceType.Pdf,rules));
        Assert.Equal("pageLimit",ex.Code);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~BoundedDocumentExtractorTests` → missing API FAIL. Add Facts `AllOfficeCases`, `CanonicalTextAndPDF`, `ExpandedBytesActualCount`, `CellAndScalarBounds`, `CancellationClosesReaders`, with counters proving bounds before cell/page/output accumulation.

- [ ] **Step 2 — implement text/PDF with bounded output.** FileStream size precheck and fixed-size reads; strict incremental decoder carries partial UTF sequences between buffers. PdfPig page count check precedes `GetPage`, include empty pages, use fixed outer page whitespace trimming and checked canonical appends. Preserve metadata title and original Unicode. PdfPig page extraction also materializes a page internally; record the same limitation as PDFKit, and do not materialize all page strings before checking the scalar cap. Dispose file/PDF/ZIP/XML objects even when cancellation interrupts an awaited block.

- [ ] **Step 3 — implement relationships and cell interpretation.** ZipArchive central-directory sum uses checked long arithmetic; a shared counting stream enforces actual expanded bytes during read. `XmlReaderSettings` uses `DtdProcessing.Prohibit`, `XmlResolver=null`, `MaxCharactersInDocument=limits.OfficeBytes`; read directly from the bounded entry stream, never `XDocument.Load` or unbounded `CopyTo(MemoryStream)`. Validate duplicate/escaping part names and required relationships. DOCX w:p/w:t/tab/br, presentation sldId order, workbook sheet order, shared/inline rich strings, numbers/booleans/errors/formula cache and sparse A1 references use the literal fixture output. Parse styles with the fixed ID/custom-format rules in the shared fixture oracle. Do not use culture-sensitive number/date formatting. Cell count increments before cell allocation, and canonical scalar count increments before StringBuilder append.

```csharp
static long Account(long used,int incoming,long maximum) {
    if(incoming<0 || incoming>maximum-used) throw new FolderIngestionException("officeLimit");
    return used+incoming;
}
```

The counting stream shares one counter across entries and returns at most requested buffer bytes; it reads one bounded block to discover overflow, throws before handing that block to the XML/string accumulator. Errors distinguish malformed archive, bad relation, bad cell and the actual exceeded limit. Cancellation remains `OperationCanceledException`, handled by the worker as cancellation rather than extraction failure.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~BoundedDocumentExtractorTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Ingestion/BoundedDocumentExtractor.cs windows/src/AINotebook.Core/Ingestion/BoundedOfficeReader.cs windows/src/AINotebook.Core/Ingestion/XlsxReader.cs windows/tests/AINotebook.Core.Tests/Ingestion/BoundedDocumentExtractorTests.cs
git commit -m "feat(win-ingestion): bounded canonical PDF and Office extraction" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: seven Facts green, all shared office rows pass; both complete suites green.

## Filesystem and scan interfaces (Tasks 6–9)

The interfaces below are exact Swift/C# parity seams. `FolderEntry` has `relPath:String, isDirectory:Bool, isLink:Bool, stamp:FileStamp`; `FolderRead` has `bytes:Data, stamp:FileStamp, sha256:String` (C# byte[]). Production large-file extraction uses an opened-file handle and spool described below; `read` is a bounded helper for tests/small files, never an unbounded read-all API.

```swift
public protocol FolderFileSystem: FolderPathIdentity {
    func caseSensitive(root: FolderSource) throws -> Bool
    func list(root: FolderSource, directory: String) throws -> [FolderEntry]
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot
}
public struct NativeFolderFileSystem: FolderFileSystem { public init() }
public struct FolderWalk: Sendable {
    public init(fileSystem: any FolderFileSystem)
    public func walk(root: FolderSource, cancelled: @Sendable () -> Bool,
                     visit: @Sendable (FolderEntry) async throws -> Void) async throws -> ScanCompletion
}
```

```csharp
public interface IFolderFileSystem : IFolderPathIdentity {
    bool CaseSensitive(FolderSource root);
    IReadOnlyList<FolderEntry> List(FolderSource root,string directory);
    FileStamp Stat(FolderSource root,string relativePath);
    FolderRead Hash(FolderSource root,string relativePath,long maxBytes);
    FolderFileSnapshot Snapshot(FolderSource root,string relativePath,long maxBytes);
}
public sealed class NativeFolderFileSystem : IFolderFileSystem { public NativeFolderFileSystem(); }
public sealed class FolderWalk {
    public FolderWalk(IFolderFileSystem fileSystem);
    public Task<ScanCompletion> WalkAsync(FolderSource root,Func<bool> cancelled,
        Func<FolderEntry,Task> visit,CancellationToken ct=default);
}
```

`hash/Hash` streams SHA-256; `FolderRead.bytes/Bytes` is empty for this operation (the payload type is retained for fake/test byte streams), not a buffered file copy. Add explicit comments and assert zero retained payload bytes in the file-size test. Root/entry stamp identity is filesystem file ID plus volume, not a pathname hash.

```swift
public final class FolderScanner: Sendable {
    public init(store: NotebookStore, fileSystem: any FolderFileSystem, tables: UnicodeTables,
                clock: any IngestLeaseClock = SystemIngestLeaseClock())
    public func scan(folderId: Int64, verifyAll: Bool, fence: JobFence,
                     now: Int64, cancelled: @escaping @Sendable () -> Bool) async throws
    public func applyRules(folderId: Int64, rules: FolderRules, now: Int64) async throws
}
extension NotebookStore {
    public func beginFolderScan(folderId: Int64, fence: JobFence, now: Int64) throws -> ScanTicket?
    public func observeFolderFile(ticket: ScanTicket, observation: FolderObservation, now: Int64) throws -> ExtractionRequest?
    public func finishFolderScan(ticket: ScanTicket, completion: ScanCompletion, now: Int64) throws -> Bool
    public func applyFolderRules(folderId: Int64, rules: FolderRules,
                                  eligibility: [String: Bool], now: Int64) throws
    public func extractionRequest(sourceId: Int64) throws -> ExtractionRequest?
}
```

```csharp
public sealed class FolderScanner {
    public FolderScanner(NotebookStore store,IFolderFileSystem fileSystem,UnicodeTables tables,
        IIngestLeaseClock? clock=null);
    public Task ScanAsync(long folderId,bool verifyAll,JobFence fence,long now,CancellationToken ct=default);
    public Task ApplyRulesAsync(long folderId,FolderRules rules,long now,CancellationToken ct=default);
}
public ScanTicket? BeginFolderScan(long folderId,JobFence fence,long now);
public ExtractionRequest? ObserveFolderFile(ScanTicket ticket,FolderObservation observation,long now);
public bool FinishFolderScan(ScanTicket ticket,ScanCompletion completion,long now);
public void ApplyFolderRules(long folderId,FolderRules rules,IReadOnlyDictionary<string,bool> eligibility,long now);
public ExtractionRequest? ExtractionRequest(long sourceId);
```

`ExtractionRequest` snapshots the observed stamp/hash/rules; folder source content_hash is the hash of the **last committed bytes**, so a newly observed hash must not overwrite it before successful extraction. To avoid a new unowned schema column, `observeFolderFile` persists mtime/size, clears error and sets pending, queues an extract job with expected current revision, and the worker hashes the file again when it opens. For a new source, hash is absent until publication; the returned request carries the just-computed hash in memory. `extractionRequest` for restarted jobs derives hash from committed content_hash (possibly empty), and the worker always replaces this with its opened-file hash. This distinction is tested; metadata equality alone must never suppress a pending/failed extraction.

## Task 6: [Swift] Native identity, no-follow file access and completed-subtree walk

**Depends on:** 2. **Parallel with:** 4, 5, 7, 10, 11.

**Files:** `Sources/AINotebookCore/{FolderFileSystem.swift,NativeFolderFileSystem.swift,FolderWalk.swift}`; `Tests/AINotebookCoreTests/FolderFileSystemTests.swift`

**Interfaces — Consumes:** WP3 `FolderPathIdentity.resolve(rootPath:) throws -> FolderIdentity`, C# `IFolderPathIdentity.Resolve(string)->FolderIdentity`, plus primitive stamps. **Produces:** all Swift filesystem/walk declarations above; C# declarations there define parity.

- [ ] **Step 1 — red traversal test.** Put `ScriptedFS` in this test file: a value-type fake backed by the fixture's directory entries/errors; `list` throws for denied directories and logs calls under a lock, `resolve/stat/hash` return fixture values.

```swift
import XCTest
@testable import AINotebookCore
final class FolderFileSystemTests: XCTestCase {
    func testPartialSiblingCompletion() async throws {
        let c=try SharedFixtures.json("contracts/ingestion-scan-v1.json")
        let row=try XCTUnwrap((c["cases"] as? [[String:Any]])?.first { $0["name"] as? String == "partial-sibling" })
        let fs=try ScriptedFS(caseJSON:row)
        let result=try await FolderWalk(fileSystem:fs).walk(root:fs.root,cancelled:{false},visit:{_ in})
        XCTAssertEqual(result.completed,["good"])
        XCTAssertEqual(result.incomplete,["bad",""])
        XCTAssertFalse(result.rootUnavailable)
    }
}
```

Run `swift test --filter FolderFileSystemTests` → missing FolderWalk FAIL. Add `testAllWalkTraces`, `testNativeSymlinkAndContainment`, `testOpenRace`, `testStreamingHashAndCancellation`, `testVolumeIdentity` (six methods). Fake constructor must decode fixture entries/expected root, not return a canned ScanCompletion.

Add this fixture-backed adapter to the same test file; it never returns a prepared ScanCompletion. Import Foundation/XCTest on Swift; System.Text.Json and Storage on C#. Assert the exact list-call order `["","bad","good"]` in the test above.

```swift
private final class WalkCalls: @unchecked Sendable {
    private let gate = NSLock()
    private var paths: [String] = []
    func record(_ path: String) { gate.lock(); defer { gate.unlock() }; paths.append(path) }
    var snapshot: [String] { gate.lock(); defer { gate.unlock() }; return paths }
}
private struct ScriptedFS: FolderFileSystem {
    let root: FolderSource
    private let sensitive: Bool
    private let directories: [String:[FolderEntry]]
    private let stamps: [String:FileStamp]
    private let denied: Set<String>
    private let calls = WalkCalls()
    var listCalls: [String] { calls.snapshot }
    init(caseJSON: [String:Any]) throws {
        let i = try XCTUnwrap(caseJSON["input"] as? [String:Any])
        let r = try XCTUnwrap(i["root"] as? [String:Any])
        let identity = FolderIdentity(volumeId:r["volumeId"] as! String,
            components:r["components"] as! [String],rootFileId:r["rootFileId"] as! String)
        let draft = FolderDraft(rootPath:r["rootPath"] as! String,displayName:r["displayName"] as! String,
            includeExts:["md"],ignoreGlobs:[],limitsJSON:"{}",encodingFallback:"cp1250",watchEnabled:true)
        root = FolderSource(id:(r["id"] as! NSNumber).int64Value,
            notebookId:(r["notebookId"] as! NSNumber).int64Value,draft:draft,identity:identity,
            scanState:"idle",scanGeneration:0,lastFullScanAt:nil,lastScanError:nil,createdAt:0)
        sensitive = i["caseSensitive"] as! Bool
        let values = (i["stats"] as! [String:[String:Any]]).mapValues { v in
            FileStamp(identity:v["identity"] as! String,mtimeNs:(v["mtimeNs"] as! NSNumber).int64Value,
                sizeBytes:(v["sizeBytes"] as! NSNumber).int64Value)
        }
        stamps = values
        directories = try (i["directories"] as! [String:[[String:Any]]]).mapValues { rows in
            try rows.map { row in
                let path = row["relPath"] as! String
                return FolderEntry(relPath:path,isDirectory:row["isDirectory"] as! Bool,
                    isLink:row["isLink"] as! Bool,stamp:try XCTUnwrap(values[path]))
            }
        }
        let errors = i["listErrors"] as! [String:String]
        XCTAssertTrue(errors.values.allSatisfy { $0 == "permissionDenied" })
        denied = Set(errors.keys)
    }
    func resolve(rootPath: String) throws -> FolderIdentity {
        XCTAssertEqual(rootPath,root.draft.rootPath); return root.identity
    }
    func caseSensitive(root: FolderSource) throws -> Bool { sensitive }
    func list(root: FolderSource,directory: String) throws -> [FolderEntry] {
        calls.record(directory)
        if denied.contains(directory) { throw CocoaError(.fileReadNoPermission) }
        return try XCTUnwrap(directories[directory],"unexpected list: \(directory)")
    }
    func stat(root: FolderSource,relativePath: String) throws -> FileStamp {
        try XCTUnwrap(stamps[relativePath],"unexpected stat: \(relativePath)")
    }
    func hash(root: FolderSource,relativePath: String,maxBytes: Int64) throws -> FolderRead {
        XCTFail("walk must not hash file bodies"); throw CocoaError(.fileReadUnknown)
    }
    func snapshot(root: FolderSource,relativePath: String,maxBytes: Int64) throws -> FolderFileSnapshot {
        XCTFail("walk must not snapshot file bodies"); throw CocoaError(.fileReadUnknown)
    }
}
```

- [ ] **Step 2 — implement component identity and safe IO.** Resolve selected root once with realpath; use volume identifier and actual on-disk canonical component spellings from directory lookup. Determine volume case sensitivity from URL volume resources; do not apply UnicodeTables to filesystem identity. On case-insensitive/normalization-insensitive volumes, recover canonical directory entry spelling so aliases share equality keys. Open root, fstat and compare saved rootFileId and volume before walking. Traverse descendants using `openat`/`fstatat` with `O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW`, retain parent descriptors through open, reject links and paths outside root components; fstat opened file and verify identity agrees with enumeration. Root-symlink retargeting returns rootIdentityChanged/unavailable. Resolve only the selected root's link, never interior links. Hash 64 KiB reads incrementally with CryptoKit SHA256 and reject size overflow before appending/processing excess. Close descriptors with defer.

- [ ] **Step 3 — explicit postorder completion.** Walk deterministic scalar-sorted entries and track a result for each directory. Mark a directory completed only when its own listing and all descendants completed. A failed child prevents ancestors being completed but does not erase a completed sibling. Use `""` for root. Minimize completed prefixes (if root complete, just `[""]`); retain incomplete directories in deterministic deepest-first order, scalar tie-break, yielding `["bad",""]` in the fixture. Cancellation checks before listing and between entries; do not manufacture completion for a directory not visited. Links are skipped entries and never descended; emit them for diagnostics but scanner creates inventory only for supported regular-file classifications. An ignored directory is still enumerated without opening file bodies so skipped-file coverage is exact; permission failure inside it still makes coverage a lower bound. If root cannot be opened, return rootUnavailable and no completed prefix.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter FolderFileSystemTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/FolderFileSystem.swift Sources/AINotebookCore/NativeFolderFileSystem.swift Sources/AINotebookCore/FolderWalk.swift Tests/AINotebookCoreTests/FolderFileSystemTests.swift
git commit -m "feat(ingestion): Swift safe folder traversal and subtree completion" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: six methods pass, native symlink target read count zero, no wall-clock sleeps; both full suites green.

## Task 7: [Windows] Filesystem identity, reparse exclusion and subtree walk

**Depends on:** 3. **Parallel with:** 4, 5, 6, 10, 11.

**Files:** `windows/src/AINotebook.Core/Ingestion/{FolderFileSystem.cs,NativeFolderFileSystem.cs,FolderWalk.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderFileSystemTests.cs`

**Interfaces — Consumes:** C# WP3 identity/stamps and Swift peers stated above. **Produces:** C# filesystem/walk declarations above; Swift `FolderWalk.walk(root:cancelled:visit:) async throws -> ScanCompletion` is the exact parity result.

- [ ] **Step 1 — red test.**

```csharp
using AINotebook.Core.Ingestion;
using AINotebook.Core.Tests.Helpers;
using Xunit;
public sealed class FolderFileSystemTests {
    [Fact] public async Task PartialSiblingCompletion() {
        var row=SharedFixtures.Json("contracts/ingestion-scan-v1.json").GetProperty("cases")
            .EnumerateArray().Single(c=>c.GetProperty("name").GetString()=="partial-sibling");
        var fs=new ScriptedFS(row);
        var result=await new FolderWalk(fs).WalkAsync(fs.Root,()=>false,_=>Task.CompletedTask);
        Assert.Equal(new[]{"good"},result.Completed);
        Assert.Equal(new[]{"bad",""},result.Incomplete);
        Assert.False(result.RootUnavailable);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderFileSystemTests` → missing walk FAIL. `ScriptedFS` in the same test file interprets fixture entries/errors and counts calls. Add `AllWalkTraces`, `NativeLinksAndContainment`, `OpenRace`, `StreamingHashAndCancellation`, `VolumeIdentity`. Windows-only subcases run inside these Facts under `OperatingSystem.IsWindows()`; the fake reparse/junction cases run on every OS, so no whole test is skipped on macOS.

Add this fixture-backed adapter to the same test file; it never returns a prepared ScanCompletion. Import Foundation/XCTest on Swift; System.Text.Json and Storage on C#. Assert the exact list-call order `["","bad","good"]` in the test above.

```csharp
internal sealed class ScriptedFS : IFolderFileSystem {
    public FolderSource Root { get; }
    private readonly bool sensitive;
    private readonly Dictionary<string,FileStamp> stamps;
    private readonly Dictionary<string,FolderEntry[]> directories;
    private readonly HashSet<string> denied;
    private readonly object callsGate = new();
    private readonly List<string> calls = new();
    public string[] ListCalls { get { lock(callsGate) return calls.ToArray(); } }
    public ScriptedFS(JsonElement row) {
        var i=row.GetProperty("input"); var r=i.GetProperty("root");
        var identity=new FolderIdentity(r.GetProperty("volumeId").GetString()!,
            r.GetProperty("components").EnumerateArray().Select(x=>x.GetString()!).ToArray(),
            r.GetProperty("rootFileId").GetString()!);
        var draft=new FolderDraft(r.GetProperty("rootPath").GetString()!,r.GetProperty("displayName").GetString()!,
            new[]{"md"},Array.Empty<string>(),"{}","cp1250",true);
        Root=new FolderSource(r.GetProperty("id").GetInt64(),r.GetProperty("notebookId").GetInt64(),
            draft,identity,"idle",0,null,null,0);
        sensitive=i.GetProperty("caseSensitive").GetBoolean();
        stamps=i.GetProperty("stats").EnumerateObject().ToDictionary(p=>p.Name,p=>
            new FileStamp(p.Value.GetProperty("identity").GetString()!,
                p.Value.GetProperty("mtimeNs").GetInt64(),p.Value.GetProperty("sizeBytes").GetInt64()));
        directories=i.GetProperty("directories").EnumerateObject().ToDictionary(p=>p.Name,p=>
            p.Value.EnumerateArray().Select(e=>new FolderEntry(e.GetProperty("relPath").GetString()!,
                e.GetProperty("isDirectory").GetBoolean(),e.GetProperty("isLink").GetBoolean(),
                stamps[e.GetProperty("relPath").GetString()!])).ToArray());
        var errors=i.GetProperty("listErrors").EnumerateObject().ToArray();
        Assert.All(errors,e=>Assert.Equal("permissionDenied",e.Value.GetString()));
        denied=errors.Select(e=>e.Name).ToHashSet();
    }
    public FolderIdentity Resolve(string rootPath) {
        Assert.Equal(Root.Draft.RootPath,rootPath); return Root.Identity;
    }
    public bool CaseSensitive(FolderSource root)=>sensitive;
    public IReadOnlyList<FolderEntry> List(FolderSource root,string directory) {
        lock(callsGate) calls.Add(directory);
        if(denied.Contains(directory)) throw new UnauthorizedAccessException(directory);
        Assert.True(directories.ContainsKey(directory),$"unexpected list: {directory}");
        return directories[directory];
    }
    public FileStamp Stat(FolderSource root,string relativePath) {
        Assert.True(stamps.ContainsKey(relativePath),$"unexpected stat: {relativePath}"); return stamps[relativePath];
    }
    public FolderRead Hash(FolderSource root,string relativePath,long maxBytes) {
        Assert.Fail("walk must not hash file bodies"); throw new InvalidOperationException();
    }
    public FolderFileSnapshot Snapshot(FolderSource root,string relativePath,long maxBytes) {
        Assert.Fail("walk must not snapshot file bodies"); throw new InvalidOperationException();
    }
}
```

- [ ] **Step 2 — native handle implementation.** Windows use `CreateFileW` with `FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT`, `GetFileInformationByHandleEx` for file IDs/case-sensitive-directory flags, and `GetFinalPathNameByHandleW` for canonical volume/component identity. Check attributes before descent and again on the opened handle. Reject any interior reparse point, including symlink, junction and mount-point. Resolve selected-root link once without OPEN_REPARSE_POINT and persist its target identity; live retarget fails. Retain/revalidate parent directory identities through open, compare resolved components (not string prefix) to root, and refuse a renamed/swapped path before passing a handle to extraction. Case-insensitive keys use actual canonical entry names, case-sensitive directories retain distinct names. `IFolderFileSystem` fake supplies mixed-directory comparison behavior in tests; a root-level caseSensitive boolean applies to glob policy only.

On macOS .NET Core tests, use System.IO's link-target/reparse detection, file handle identity via libc stat/fstat and a path-component adapter; do not invoke Win32 unconditionally. Native Windows CI adds `Directory.CreateSymbolicLink` and a junction built in a temporary test directory when permitted; if developer-mode symlinks cannot be created, the junction test remains mandatory and reports the capability separately instead of treating no test as success. Directory entries are scalar-sorted using Rune arrays, not `StringComparer.Ordinal` for supplementary/BMP ordering. SHA256 uses incremental 64 KiB reads and cancellation checks.

- [ ] **Step 3 — postorder walk.** A directory completes only after all listed descendants complete; return minimal completed prefixes and deepest-first failed ancestors. Denied sibling leaves good child completed, root incomplete. Traverse ignored directories for skipped regular-file inventory, never descend links. Return rootUnavailable for root access failure, retain old source availability until scanner transaction sets root unavailable, and make cancellation an incomplete scan without fabricated missing rows. Close every SafeFileHandle/enumerator/stream on all exits.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderFileSystemTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Ingestion/FolderFileSystem.cs windows/src/AINotebook.Core/Ingestion/NativeFolderFileSystem.cs windows/src/AINotebook.Core/Ingestion/FolderWalk.cs windows/tests/AINotebook.Core.Tests/Ingestion/FolderFileSystemTests.cs
git commit -m "feat(win-ingestion): safe recursive filesystem adapter" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: six Facts green on macOS with fake traces; Windows CI additionally executes native junction/handle races. Both Core suites green.

## Task 8: [Swift] Scanner transactions, rules and coverage

**Depends on:** 6, corrected WP3 catalog/jobs, 1. **Parallel with:** 4, 5, 9, 10, 11.

**Files:** `Sources/AINotebookCore/{FolderScanner.swift,NotebookStore+FolderIngestion.swift,NotebookStore+Coverage.swift}`; `Tests/AINotebookCoreTests/FolderScannerTests.swift`; amend the WP3-produced coverage implementation here, retaining its existing tests and adding decision-10 tests.

**Interfaces — Consumes:** Swift `NotebookStore.claimJob(now:leaseToken:id:) throws -> IngestJob?`, `coverage(notebookId:scope:) throws -> CoverageSnapshot`, filesystem/walk from Task6 and FolderGlob from Task2. C# twins: `ClaimJob(long,string,long?)`, `Coverage(long,RetrievalScope)`, `FolderWalk.WalkAsync`. **Produces:** Swift scan/store signatures in the preceding interface block; C# exact counterparts there are normative. Add a clock constructor argument to scanner on both platforms: `clock:any IngestLeaseClock = SystemIngestLeaseClock()` / `IIngestLeaseClock? clock=null`. The scan's `now` argument is the start timestamp; every later fence check uses `clock.now()` / `clock.Now`, never the stale start timestamp.

- [ ] **Step 1 — red test for observed-change freshness.**

```swift
import XCTest
@testable import AINotebookCore
private struct ScanIdentity: FolderPathIdentity {
    func resolve(rootPath:String) throws -> FolderIdentity {
        FolderIdentity(volumeId:"test",components:["docs"],rootFileId:"root-1")
    }
}
@MainActor final class FolderScannerTests: XCTestCase {
    func testObservedChangeKeepsPublishedSearchable() throws {
        let store=try NotebookStore(path:.inMemory)
        let nb=try store.createNotebook(name:"scan")
        let folder=try store.createFolder(notebookId:nb.id!,draft:FolderDraft(
            rootPath:"/docs",displayName:"Docs",includeExts:["md"],ignoreGlobs:[],
            limitsJSON:"{}",encodingFallback:"cp1250",watchEnabled:true),identity:ScanIdentity(),now:0)
        let source=try store.createSource(notebookId:nb.id!,type:.markdown,title:"a",uri:nil,rawPath:"/docs/a.md")
        try store.attachSource(sourceId:source.id!,folderId:folder.id,relPath:"a.md")
        _=try store.commitForegroundRevision(sourceId:source.id!,draft:RevisionDraft(
            contentHash:"old",canonicalText:"old",textFormatVersion:1,chunkerVersion:2),
            chunks:ScalarChunker.chunk("old"),now:0,leaseToken:"initial")
        let id=try store.enqueueJob(IngestJobDraft(kind:"scan",target:"folder:\(folder.id)",targetRevision:nil),now:1)
        _=try store.claimJob(now:1,leaseToken:"scan",id:id)
        let ticket=try XCTUnwrap(store.beginFolderScan(folderId:folder.id,fence:JobFence(jobId:id,leaseToken:"scan"),now:1))
        let changed=expectation(description:"one committed observation")
        changed.assertForOverFulfill=true
        let observer=NotificationCenter.default.addObserver(forName:.folderIngestionDidChange,
            object:store,queue:nil) { note in
            XCTAssertEqual(note.userInfo?["notebookId"] as? Int64,nb.id!)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _=try store.observeFolderFile(ticket:ticket,observation:FolderObservation(relPath:"a.md",
            stamp:FileStamp(identity:"f",mtimeNs:2,sizeBytes:3),kind:"eligible",skipReason:nil,contentHash:"new"),now:1)
        wait(for:[changed],timeout:1)
        let coverage=try store.coverage(notebookId:nb.id!,scope:.all)
        XCTAssertEqual(coverage.searchable,1)
        XCTAssertEqual(coverage.refreshPending,1)
        XCTAssertEqual(coverage.refreshError,0)
    }
}
```

Run `swift test --filter FolderScannerTests` → missing scan APIs FAIL. Add `testAllScanTraces`, `testAllCoverageRows`, `testRuleChangeRevokesImmediately`, `testStaleScanCannotFinish`, `testPartialAndUnavailable`, `testFingerprintFastPath`, `testRestartPendingWork` (eight methods). Each uses in-memory/file-backed real store, scripted FS and the exact shared projections. The stale-finish and failed-rule cases also assert no notifications. Coverage runner uses every fixture row, including the six corrected table cases; asserts both raw DTO and derived notSearchable/current.

- [ ] **Step 2 — implement transactional observations.** Execute the entire async walk from `Task.detached(priority:.utility)`; await each visit's `MainActor.run` store transaction before requesting the next entry. `FolderWalk.walk` has an async throwing visitor, so there is at most one pending observation and no whole-tree buffered inventory. Cancellation of scanner cancels and joins the detached task. The filesystem object is Sendable; no native listing/hash is performed inside MainActor.run. In C#, `ScanAsync` wraps `FolderWalk.WalkAsync` in `Task.Run` and awaits the visitor; SQL calls are synchronous under the gate and filesystem operations remain outside it.

 `beginFolderScan` checks running scan fence/expiry/target, advances generation and sets scanning in one write. A recovered abandoned scanning row may start again only after the old job's lease has been reclaimed; old ticket fails both generation/token guards. Observation transaction validates path, folder/target and generation. Upsert every regular eligible/skipped file into `scan_items`. Precedence for skipped reason: ignored, unsupported_ext, over_limit. Interior links are not regular files and are never followed or created as sources; a previously stored source replaced by a link becomes ineligible and its jobs are cancelled, with a skipped inventory reason `ignored` and diagnostic `interiorLink` on the scan.

Eligible new paths create source and attach within the same transaction. Existing source identity is `(folder_id,rel_path)` resolved using native canonical path spelling, not content hash. Set present for seen files, including returning unavailable files. Skip file reads only when stamp matches, source has committed hash, published pointer exists, status ready and no forced verification. Otherwise hash through FS; same hash updates metadata and inventory only; changed hash sets pending/error NULL and enqueues one extract job with target_revision=current pointer. Cancel superseded running/queued/paused/retryable extract jobs when a new observation supersedes their observed bytes; do not call `beginExtraction` (it starts an attempt before a worker exists). Coalesce identical pending observations. Jobs carry expected current pointer; worker also compares persisted observation stamp at commit. Add the exact notification seam above to this task's store extension and emit after committed observations/rules/scan completion. WP5's fresh per-turn eligibility query observes revocation immediately; no WP5 file is edited by this task.

The stamp's native identity is an in-memory/open-handle check, while mtime+size are durable WP3 columns. A same-size/same-mtime replacement can only be discovered by Verify all or a native event forced-hash scan; document this inherent fast-path tradeoff, do not claim mtime+size detects every replacement.

- [ ] **Step 3 — finish only completed subtrees; reconcile inventory and rules.** Use bound prefix membership by components. Never `LIKE prefix%` (it confuses `a` with `ab` and SQL wildcards). For each candidate path, membership is `prefix=="" || path==prefix || path.hasPrefix(prefix+"/")` with byte/scalar identity; parameterize any SQL prefix with exact `substr` checks. Within one fenced transaction, mark unseen known sources missing only in completed prefixes, cancel their unfinished extraction jobs, and delete unseen **source-less** scan_items only there. Retain matching source inventory until its missing precedence is counted. Root unavailable sets folder state unavailable and currently present sources unavailable, without marking missing; missing sources remain missing. Unexpected scan error performs no missing marking. Partial sets `last_full_scan_at` unchanged; a full root completion sets idle and timestamp. Complete the scan job atomically with final state. A cancelled job cannot finish; coordinator performs a separate current-generation-only partial marker after cancellation, never missing marking beyond previously committed completed-subtree information.

Rules compile and validate before any write. Compute eligibility for every known source and inventory row from stored size/path and new rules; commit rules + all flags + skipped reasons + job cancellation/queueing atomically. No filesystem availability changes. Re-enabled current sources reuse published chunks; changed/failed/unpublished files get pending work. Store helper rechecks source list/version inside transaction, so sources observed between calculation and commit are evaluated too; keep the pure classification function in this file and recompute from row values rather than accepting a stale eligibility dictionary as authoritative. A folder-wide rescan is queued after rule changes for unknown files/limits/encoding re-extraction. Changed encoding or extraction limits forces extraction of eligible files; simple ignore changes alone need not re-extract unchanged published content.

Coverage keeps WP3's one-read-transaction scope/entity union. Freshness predicate becomes:

```sql
eligible=1 AND availability='present' AND status<>'error'
AND (published IS NULL OR current IS NOT published OR status IN ('pending','chunking'))
```

Error wins over pending; present skipped inventory/source is counted once; unavailable/missing wins over skipped; active-vector state never changes corpus count. Empty selection returns an all-zero snapshot before any SQL query. Derive current count without adding freshness and corpus totals together.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter FolderScannerTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/FolderScanner.swift Sources/AINotebookCore/NotebookStore+FolderIngestion.swift Sources/AINotebookCore/NotebookStore+Coverage.swift Tests/AINotebookCoreTests/FolderScannerTests.swift
git commit -m "feat(ingestion): Swift durable scans rules and freshness coverage" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight methods green, all scan/coverage fixtures executed; both full suites pass.

## Task 9: [Windows] Scanner transactions, rules and coverage

**Depends on:** 7, corrected WP3 catalog/jobs, 1. **Parallel with:** 4, 5, 8, 10, 11.

**Files:** `windows/src/AINotebook.Core/Ingestion/FolderScanner.cs`; `windows/src/AINotebook.Core/Storage/{NotebookStore.FolderIngestion.cs,NotebookStore.Coverage.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderScannerTests.cs`

**Interfaces — Consumes:** `ClaimJob`, `Coverage`, `IFolderFileSystem`, `FolderGlob`; Swift counterparts in Task8. **Produces:** all C# scan/store signatures above, including optional IIngestLeaseClock scanner constructor; Swift block fixes matching behavior and names.

- [ ] **Step 1 — red regression.**

```csharp
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;
public sealed class FolderScannerTests {
    sealed class Identity : IFolderPathIdentity {
        public FolderIdentity Resolve(string rootPath)=>new("test",new[]{"docs"},"root-1");
    }
    [Fact] public void ObservedChangeKeepsPublishedSearchable() {
        using var store=new NotebookStore(StorePath.InMemory);
        long nb=store.CreateNotebook("scan").Id!.Value;
        var f=store.CreateFolder(nb,new FolderDraft("/docs","Docs",new[]{"md"},Array.Empty<string>(),"{}","cp1250",true),new Identity(),0);
        var source=store.CreateSource(nb,SourceType.Markdown,"a",null,"/docs/a.md");
        long sid=source.Id!.Value;
        store.AttachSource(sid,f.Id,"a.md");
        store.CommitForegroundRevision(sid,new RevisionDraft("old","old",1,2),ScalarChunker.Chunk("old"),0,"initial");
        long id=store.EnqueueJob(new IngestJobDraft("scan",$"folder:{f.Id}",null),1);
        store.ClaimJob(1,"scan",id);
        var ticket=store.BeginFolderScan(f.Id,new JobFence(id,"scan"),1)!;
        var notifications=new List<long>();
        store.FolderIngestionChanged+=changedNotebook=> {
            Assert.False(System.Threading.Monitor.IsEntered(store.Gate));
            notifications.Add(changedNotebook);
        };
        store.ObserveFolderFile(ticket,new FolderObservation("a.md",new FileStamp("f",2,3),"eligible",null,"new"),1);
        Assert.Equal(new[]{nb},notifications);
        var got=store.Coverage(nb,new RetrievalScope.All());
        Assert.Equal(1,got.Searchable); Assert.Equal(1,got.RefreshPending); Assert.Equal(0,got.RefreshError);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderScannerTests` → missing APIs FAIL. Add Facts `AllScanTraces`, `AllCoverageRows`, `RuleChangeRevokesImmediately`, `StaleScanCannotFinish`, `PartialAndUnavailable`, `FingerprintFastPath`, `RestartPendingWork` (eight total). The stale-finish and failed-rule cases also assert no notifications. Fixture seed SQL uses `lock(store.Gate)` and real transactions; all case output arrays compare structurally and deterministically.

- [ ] **Step 2 — implement scan state kernel.** Lock the store gate, begin immediate transaction, validate fence/expiry/target plus scan_generation before every compound write. Begin advances generation; observe canonicalizes paths through native adapter before database access, upserts inventory including skipped rows, creates/attaches source for eligible new files, updates present/stat, and queues/coalesces extract work only on changed hash or absent/failed published content. Hash outside the lock in 64 KiB blocks. Fast path requires ready/published/hash/equal stat, not merely an existing path. Store committed content hash remains unchanged until publication. A newer observation cancels old tokens and makes old metadata/outputs ineligible to commit. No network/file IO inside SQLite lock.

- [ ] **Step 3 — finish/rules/coverage.** Completed-prefix matching uses exact component equality or prefix plus `/`, never unescaped LIKE. Complete job + folder state + missing/source-less-inventory cleanup atomically; partial preserves last full time, root unavailable excludes present sources but never calls them missing, stale completion changes nothing. Observe returning files restores present. Rule transaction compiles all glob patterns first, recomputes against the latest rows under gate, updates flags/inventory and cancels or queues work; changed encoding/limits forces new extraction. Implement the exact FolderIngestionChanged event above in this task's partial store; emit after committed observations/rules/scan completion and outside the lock. Immediate eligibility revocation is guaranteed by WP5's fresh SQL snapshot per turn.

Modify WP3 Coverage SQL to add pending/chunking to refreshPending when error is absent. Derive notSearchable/current from existing fields, preserve single snapshot and early empty-scope return. This exact statement replaces the stale pointer-only test:

```sql
coalesce(sum(availability='present' AND eligible=1 AND status<>'error'
 AND (published IS NULL OR current IS NOT published OR status IN ('pending','chunking'))),0) AS refreshPending
```

Test old published + error as searchable1/refreshError1, old published + observed pending as searchable1/refreshPending1, and newly published + no active vectors as searchable1/current1. Do not sum the dimensions in a total.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderScannerTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Ingestion/FolderScanner.cs windows/src/AINotebook.Core/Storage/NotebookStore.FolderIngestion.cs windows/src/AINotebook.Core/Storage/NotebookStore.Coverage.cs windows/tests/AINotebook.Core.Tests/Ingestion/FolderScannerTests.cs
git commit -m "feat(win-ingestion): durable scans rules and freshness coverage" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight Facts, all scan/coverage cases green, both full suites pass.

## Queue/admission contract (Tasks 10–11)

Use WP3's corrected durable job state machine, not a second in-memory state machine. The new queue selects an eligible due job **after** reserving the resource it needs, then calls atomic `claimJob` for that id. Enumerating candidates is a read query on the store queue/gate; no claim sits running indefinitely waiting for an extraction permit. Add candidate querying in the task-owned JobQueue file via a NotebookStore extension/partial declaration, not a WP3 edit: `dueJobs(kind:String,now:Int64,limit:Int) throws -> [IngestJob]` / `IReadOnlyList<IngestJob> DueJobs(string kind,long now,int limit)`; filter kind before LIMIT; order coalesce(next_retry_at,0),id, null deadline means immediately due for queued only. Limit=32.

```swift
public actor IngestionAdmission {
    public init(maxExtractions: Int = 2, memoryBytes: Int64 = 536_870_912)
    public func acquireExtraction(bytes: Int64) async throws -> UUID
    public func releaseExtraction(_ token: UUID)
    public func beginChat() -> UUID
    public func endChat(_ token: UUID)
    public func waitForBackgroundBatch() async throws
}
public actor JobQueue {
    public init(store: NotebookStore, clock: any IngestLeaseClock,
        admission: IngestionAdmission, token: @escaping @Sendable () -> String = { UUID().uuidString })
    public func runOne(kind: String, reservedBytes: Int64,
        execute: @Sendable (IngestJob, JobFence) async throws -> Void) async throws -> Bool
    public func stop() async
}
public struct RescanSchedule: Sendable {
    public init()
    public mutating func signal(at milliseconds: Int64)
    public var dueAt: Int64? { get }
    public mutating func started()
    public mutating func finished(at milliseconds: Int64)
}
```

```csharp
public sealed class IngestionAdmission {
    public IngestionAdmission(int maxExtractions=2,long memoryBytes=536870912);
    public Task<Guid> AcquireExtractionAsync(long bytes,CancellationToken ct=default);
    public void ReleaseExtraction(Guid token);
    public Guid BeginChat();
    public void EndChat(Guid token);
    public Task WaitForBackgroundBatchAsync(CancellationToken ct=default);
}
public sealed class JobQueue {
    public JobQueue(NotebookStore store,IIngestLeaseClock clock,IngestionAdmission admission,Func<string>? token=null);
    public Task<bool> RunOneAsync(string kind,long reservedBytes,Func<IngestJob,JobFence,CancellationToken,Task> execute,CancellationToken ct=default);
    public Task StopAsync();
}
public sealed class RescanSchedule {
    public void Signal(long milliseconds); public long? DueAt { get; }
    public void Started(); public void Finished(long milliseconds);
}
```

Memory reservation is conservative and deterministic: text `min(fileBytes,limit.fileBytes)*4 + textScalars*8 + chunks*256`; Office adds officeBytes; PDF adds officeBytes as a parser allowance. Checked arithmetic, ceiling at process budget for a single permitted extraction. A request whose declared reservation exceeds budget runs alone reserving the entire budget, never deadlocks waiting for an impossible permit. This bounds admitted concurrent work, not undocumented allocations inside PDFKit/PdfPig. Defaults allow two small text extractions; a maximum Office/PDF extraction can occupy the budget alone. Release on success/error/cancel/lease loss. Runtime memory-pressure warning pauses new admissions until pressure clears; existing work is cancellable. Inject pressure as `setMemoryPressure(_ blocked:Bool)` / `SetMemoryPressure(bool blocked)` for deterministic tests. No change to frozen constants is implied by this WP6 operational 512 MiB budget; Claude reviews it together with the cell ceiling.

## Task 10: [Swift] Durable queue, renewal, memory and chat admission

**Depends on:** 2, corrected WP3 job handoff, 1. **Parallel with:** 4–9 and 11 after their prerequisites.

**Files:** `Sources/AINotebookCore/{JobQueue.swift,IngestionAdmission.swift,RescanSchedule.swift}`; `Tests/AINotebookCoreTests/IngestionQueueTests.swift`

**Interfaces — Consumes:** `claimJob`, `renewJob(fence:now:) throws -> Bool`, `failJob(fence:error:now:) throws -> Bool`, `recoverExpiredJobs(now:)`, `requeueRetryableJobs(now:)`; C# `IngestJob? ClaimJob(long now,string leaseToken,long? id=null)`, `bool RenewJob(JobFence fence,long now)`, `bool FailJob(JobFence fence,string error,long now)`, `int RecoverExpiredJobs(long now)`, `int RequeueRetryableJobs(long now)`. **Produces:** all Swift queue/admission/schedule APIs above; C# block specifies parity.

- [ ] **Step 1 — red deadline test plus real job-fixture runner.**

```swift
import XCTest
@testable import AINotebookCore
final class IngestionQueueTests: XCTestCase {
    func testCoalesceHasMaximumDeadline() {
        var schedule=RescanSchedule()
        for t in stride(from:Int64(0),through:4_900,by:100) { schedule.signal(at:t) }
        XCTAssertEqual(schedule.dueAt,5_000)
        schedule.started()
        schedule.signal(at:5_100)
        schedule.finished(at:5_200)
        XCTAssertEqual(schedule.dueAt,5_600)
    }
}
```

Run `swift test --filter IngestionQueueTests` → missing RescanSchedule FAIL. Add `testEveryJobTransition`, `testTwoDatabaseClaimers`, `testRenewalAndRestart`, `testFiveAttemptsAndNewUserRetry`, `testMemoryAndConcurrency`, `testChatTokensAndCancellation`, `testNoResourceLeakOnLostLease`. Use fixture job state/event fields directly: seed exact rows under dbQueue.write, call the relevant store method for start/fail/retry/expire/renew/publish, and assert state/attempts/deadlines/token/accepted/published after every event. Publication fixture setup creates real source/revision/chunks; rejected events assert unchanged rows, not just false return. Use file-backed two-store races with a barrier, never two MainActor serial calls.

Add this executable store regression before implementation. Swift imports GRDB for SQL counts; C# imports Models, Storage and Dapper. It exercises the real predecessor seam; the shared WP6 worker cases must additionally verify metadata/page-map atomicity.

```swift
@MainActor
func testFailuresRequeueAtDeadlineAndExhaustAfterFiveStarts() throws {
    let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
    let notebook = try store.createNotebook(name: "retries")
    let source = try store.createSource(notebookId: XCTUnwrap(notebook.id), type: .text,
        title: "kept", uri: nil, rawPath: nil)
    let sourceId = try XCTUnwrap(source.id)
    let published = try store.commitForegroundRevision(sourceId: sourceId,
        draft: RevisionDraft(contentHash: "kept-hash", canonicalText: "kept", textFormatVersion: 1, chunkerVersion: 2),
        chunks: [RevisionChunkDraft(text: "kept", tokenCount: 1, pageHint: nil,
            charStart: 0, charEnd: 4, lang: nil, langInherited: false)], now: 0, leaseToken: "seed")
    var fence = try store.beginExtraction(sourceId: sourceId, now: 100, leaseToken: "attempt-1")
    let jobId = fence.jobId
    var startedAt: Int64 = 100
    for attempt in 1...5 {
        let running = try XCTUnwrap(store.job(id: jobId))
        XCTAssertEqual(running.state, "running")
        XCTAssertEqual(running.attempts, attempt)
        XCTAssertNil(running.nextRetryAt)
        let failedAt = startedAt + 1
        XCTAssertTrue(try store.failJob(fence: fence, error: "extract-failed", now: failedAt))
        let failed = try XCTUnwrap(store.job(id: jobId))
        XCTAssertEqual(failed.state, "failed")
        XCTAssertEqual(failed.attempts, attempt)
        XCTAssertNil(failed.leaseToken)
        XCTAssertNil(failed.leaseUntil)
        XCTAssertEqual(try store.source(id: sourceId)?.publishedRevisionId, published.id)
        XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["kept"])
        if attempt < 5 {
            let retryAt = failedAt + (Int64(1) << attempt) * 30
            XCTAssertEqual(failed.nextRetryAt, retryAt)
            XCTAssertEqual(try store.requeueRetryableJobs(now: retryAt - 1), 0)
            XCTAssertNil(try store.claimJob(now: retryAt - 1, leaseToken: "too-early-\(attempt)", id: jobId))
            XCTAssertEqual(try store.requeueRetryableJobs(now: retryAt), 1)
            let queued = try XCTUnwrap(store.job(id: jobId))
            XCTAssertEqual(queued.state, "queued")
            XCTAssertEqual(queued.attempts, attempt)
            XCTAssertEqual(queued.nextRetryAt, retryAt)
            let token = "attempt-\(attempt + 1)"
            let claimed = try XCTUnwrap(store.claimJob(now: retryAt, leaseToken: token, id: jobId))
            XCTAssertEqual(claimed.attempts, attempt + 1)
            fence = JobFence(jobId: jobId, leaseToken: token)
            startedAt = retryAt
        } else {
            XCTAssertNil(failed.nextRetryAt)
            XCTAssertEqual(try store.requeueRetryableJobs(now: failedAt + 10_000), 0)
            XCTAssertNil(try store.claimJob(now: failedAt + 10_000, leaseToken: "sixth", id: jobId))
            XCTAssertEqual(try store.job(id: jobId)?.attempts, 5)
        }
    }
    let retryId = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
        targetRevision: published.id), now: startedAt + 20_000)
    XCTAssertNotEqual(retryId, jobId)
    XCTAssertEqual(try store.job(id: retryId)?.attempts, 0)
    XCTAssertEqual(try store.job(id: jobId)?.state, "failed")
}
```

- [ ] **Step 2 — queue ownership/renewal.** Recover expired and requeue due retryable failed jobs at startup and each scheduling tick. Claim exact candidate with a fresh UUID token; tests inject deterministic unique strings but production never reuses tokens. Start a child renewal task at claimTime+60, renew with current clock, repeat at 60-second intervals while execution is active. Failed renewal cancels execution and prevents publication; join renewal on completion. `runOne` returns false if no due candidate/claim race lost. Worker execute closure owns kind-specific atomic completion; queue never generically completes extraction. Exception calls failJob only with its current fence; stale failure has no effect. User cancellation calls fenced cancel; stop cancels and awaits all tasks. Expired fifth attempt is terminal; manual retry creates a new row instead of resetting attempts.

- [ ] **Step 3 — implement actor permits and scheduler.** Admission maintains token→reservedBytes plus FIFO cancellable waiters; grant while running<2 and requested bytes fit. Cancellation removes the waiter and resumes its continuation once. Chat uses a set of tokens; background waiters resume only when empty. Question embedding never calls waitForBackgroundBatch. A batch already sent may finish; acquire gate immediately before every next background call. There is no queue-level pause of extraction on chat. Resource release is idempotent for an already released token.

```swift
// Within RescanSchedule.signal, preserving firstSignal until a scan starts:
firstSignal = firstSignal ?? milliseconds
lastSignal = milliseconds
dueAt = min(milliseconds + 500, firstSignal! + 5_000)
```

If scan is running, accumulate a separate trailing first/last signal pair, and schedule exactly one follow-up after finished. Continuous signals cannot postpone the first deadline past 5s. Memory pressure adds an admission predicate; clearing it drains FIFO. Tests control clock/barriers and prove the third extraction did not start, one cancellation releases capacity, two chat tokens require two releases, and normal question provider call is not gated.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter IngestionQueueTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/JobQueue.swift Sources/AINotebookCore/IngestionAdmission.swift Sources/AINotebookCore/RescanSchedule.swift Tests/AINotebookCoreTests/IngestionQueueTests.swift
git commit -m "feat(ingestion): Swift durable worker admission and chat priority" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: nine methods green, all 21 frozen transition cases plus ingestion-jobs cases checked; both full suites green.

## Task 11: [Windows] Durable queue, renewal, memory and chat admission

**Depends on:** 3, corrected WP3 job handoff, 1. **Parallel with:** 4–10 after their dependencies.

**Files:** `windows/src/AINotebook.Core/Ingestion/{JobQueue.cs,IngestionAdmission.cs,RescanSchedule.cs}`; `windows/tests/AINotebook.Core.Tests/Ingestion/IngestionQueueTests.cs`

**Interfaces — Consumes:** `ClaimJob/RenewJob/FailJob/RecoverExpiredJobs/RequeueRetryableJobs` and `IIngestLeaseClock`; Swift names/signatures in Task10. **Produces:** C# queue/admission/schedule APIs above; Swift actor block fixes parity.

- [ ] **Step 1 — red test and SQL fixture runner.**

```csharp
using AINotebook.Core.Ingestion;
using Xunit;
public sealed class IngestionQueueTests {
    [Fact] public void CoalesceHasMaximumDeadline() {
        var schedule=new RescanSchedule();
        for(long t=0;t<=4900;t+=100) schedule.Signal(t);
        Assert.Equal(5000,schedule.DueAt);
        schedule.Started(); schedule.Signal(5100); schedule.Finished(5200);
        Assert.Equal(5600,schedule.DueAt);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~IngestionQueueTests` → missing schedule FAIL. Add Facts `EveryJobTransition`, `TwoDatabaseClaimers`, `RenewalAndRestart`, `FiveAttemptsAndNewUserRetry`, `MemoryAndConcurrency`, `ChatTokensAndCancellation`, `NoResourceLeakOnLostLease`. Seed/read fixture jobs in locked real SQLite, including real publish data for publish events; compare every nullable field and reject unknown operations. Race two file-backed stores with TaskCompletionSource barrier and separate gates.

Add this executable store regression before implementation. Swift imports GRDB for SQL counts; C# imports Models, Storage and Dapper. It exercises the real predecessor seam; the shared WP6 worker cases must additionally verify metadata/page-map atomicity.

```csharp
[Fact]
public void FailuresRequeueAtDeadlineAndExhaustAfterFiveStarts()
{
    using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
    long notebookId = store.CreateNotebook("retries").Id!.Value;
    long sourceId = store.CreateSource(notebookId, SourceType.Text, "kept", null, null).Id!.Value;
    var published = store.CommitForegroundRevision(sourceId,
        new RevisionDraft("kept-hash", "kept", 1, 2),
        new[] { new RevisionChunkDraft("kept", 1, null, 0, 4, null, false) }, 0, "seed");
    var fence = store.BeginExtraction(sourceId, 100, "attempt-1");
    long jobId = fence.JobId;
    long startedAt = 100;
    for (int attempt = 1; attempt <= 5; attempt++)
    {
        var running = store.Job(jobId)!;
        Assert.Equal("running", running.State);
        Assert.Equal(attempt, running.Attempts);
        Assert.Null(running.NextRetryAt);
        long failedAt = startedAt + 1;
        Assert.True(store.FailJob(fence, "extract-failed", failedAt));
        var failed = store.Job(jobId)!;
        Assert.Equal("failed", failed.State);
        Assert.Equal(attempt, failed.Attempts);
        Assert.Null(failed.LeaseToken);
        Assert.Null(failed.LeaseUntil);
        Assert.Equal(published.Id, store.Source(sourceId)!.PublishedRevisionId);
        Assert.Equal(new[] { "kept" }, store.Chunks(sourceId).Select(c => c.Text));
        if (attempt < 5)
        {
            long retryAt = failedAt + (1L << attempt) * 30;
            Assert.Equal(retryAt, failed.NextRetryAt);
            Assert.Equal(0, store.RequeueRetryableJobs(retryAt - 1));
            Assert.Null(store.ClaimJob(retryAt - 1, $"too-early-{attempt}", jobId));
            Assert.Equal(1, store.RequeueRetryableJobs(retryAt));
            var queued = store.Job(jobId)!;
            Assert.Equal("queued", queued.State);
            Assert.Equal(attempt, queued.Attempts);
            Assert.Equal(retryAt, queued.NextRetryAt);
            string token = $"attempt-{attempt + 1}";
            var claimed = store.ClaimJob(retryAt, token, jobId)!;
            Assert.Equal(attempt + 1, claimed.Attempts);
            fence = new JobFence(jobId, token);
            startedAt = retryAt;
        }
        else
        {
            Assert.Null(failed.NextRetryAt);
            Assert.Equal(0, store.RequeueRetryableJobs(failedAt + 10_000));
            Assert.Null(store.ClaimJob(failedAt + 10_000, "sixth", jobId));
            Assert.Equal(5, store.Job(jobId)!.Attempts);
        }
    }
    long retryId = store.EnqueueJob(new IngestJobDraft("extract", $"source:{sourceId}", published.Id),
        startedAt + 20_000);
    Assert.NotEqual(jobId, retryId);
    Assert.Equal(0, store.Job(retryId)!.Attempts);
    Assert.Equal("failed", store.Job(jobId)!.State);
}
```

- [ ] **Step 2 — implement queue.** Select due candidates under store gate, release gate before reserving capacity/execution, then ClaimJob exact id with Guid.NewGuid string. Atomic claim handles race/orphan. Linked cancellation source is owned by one running attempt. Renewal loop awaits injected clock until claim+60, calls RenewJob synchronously under store's internal lock, and cancels attempt on false. Stop renewal and await it in finally; no fire-and-forget task survives the attempt. Exceptions call FailJob with same token; cancellation calls fenced CancelJob. Retryable failed→queued is explicit due scheduler step. No attempts increment outside ClaimJob, no sixth attempt, no attempt count reset.

- [ ] **Step 3 — admission and debounce.** Small private lock protects permit dictionaries/FIFO waiter list/chat token set; resume TaskCompletionSources outside that lock with RunContinuationsAsynchronously. Cancellation removes and completes each waiter once. Grant ≤2 extractions and byte budget; oversized reservation runs alone occupying full budget. Memory pressure prevents new grants. Chat gate is independent and only wraps new background batches, not question embedding or extraction. Idempotent release and EndChat handle exception paths. Rescan deadline is `Math.Min(last+500,first+5000)`; Started transfers future signals to a trailing pair and Finished preserves their accumulated deadline. Test max pressure, cancellation and overlapping chat requests without Task.Delay.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~IngestionQueueTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Ingestion/JobQueue.cs windows/src/AINotebook.Core/Ingestion/IngestionAdmission.cs windows/src/AINotebook.Core/Ingestion/RescanSchedule.cs windows/tests/AINotebook.Core.Tests/Ingestion/IngestionQueueTests.cs
git commit -m "feat(win-ingestion): durable worker admission and chat priority" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: nine Facts, all shared job/admission cases pass; both full suites green.

## Publication and generation interfaces (Tasks 12–15)

`FolderExtractionWorker` receives a queue-claimed job/fence. It never calls `beginExtraction` after claim. Native filesystem also exposes `snapshot(root:FolderSource,relativePath:String,maxBytes:Int64) throws -> FolderFileSnapshot` / `FolderFileSnapshot Snapshot(FolderSource root,string relativePath,long maxBytes)` (owned by Tasks6/7). Define Swift `public final class FolderFileSnapshot: @unchecked Sendable` with `public let url:URL`, `stamp:FileStamp`, `hash:String` and idempotent `public func close()`; C# `public sealed class FolderFileSnapshot : IDisposable` with read-only `string Path`, `FileStamp Stamp`, `string Hash` and `void Dispose()`. Constructors are internal and take exactly these three values. The disposable snapshot owns a private temporary file with the original extension, read-only URL/Path, opened-file `stamp`/`Stamp` and SHA256 `hash`/`Hash`; `close()` / `Dispose()` removes it. Copy through the validated no-follow handle in bounded blocks while hashing; re-fstat before closing, reject changed stat/identity. Extraction reads this snapshot, never reopens an unvalidated user path through PDF/ZIP libraries. Post-extraction stat **and** streaming hash of the original must match the snapshot before publication. This closes extraction's path-swap and same-stat mutation gaps.

```swift
public struct SourceDescriptor: Codable, Sendable {
    public let version: Int; public let title: String; public let type: String
    public let pageCount: Int; public let sheetCount: Int; public let sizeBytes: Int64; public let lang: String?
    public static func make(document: CanonicalDocument, filename: String, sizeBytes: Int64, lang: String?) -> SourceDescriptor
}
public struct FolderExtractionWorker: Sendable {
    public init(store: NotebookStore, fileSystem: any FolderFileSystem,
        detector: LanguageDetector, clock: any IngestLeaseClock,
        embeddingSelection: @escaping @Sendable (Int64) async throws -> EmbeddingSelection?,
        extract: @escaping @Sendable (URL, SourceType, FolderRules) async throws -> CanonicalDocument)
    public func execute(job: IngestJob, fence: JobFence) async throws
}
extension NotebookStore {
    public func publishFolderExtraction(request: ExtractionRequest, draft: RevisionDraft,
        chunks: [RevisionChunkDraft], metadata: PublicationMetadata, embeddingSelection: EmbeddingSelection?,
        fence: JobFence, now: Int64) throws -> SourceRevision?
    public func revisionPages(revisionId: Int64) throws -> [PageBoundary]
}
```

```csharp
public sealed record SourceDescriptor(int Version,string Title,string Type,int PageCount,int SheetCount,long SizeBytes,string? Lang) {
    public static SourceDescriptor Make(CanonicalDocument document,string filename,long sizeBytes,string? lang);
}
public sealed class FolderExtractionWorker {
    public FolderExtractionWorker(NotebookStore store,IFolderFileSystem fileSystem,LanguageDetector detector,
        IIngestLeaseClock clock,Func<long,Task<EmbeddingSelection?>> embeddingSelection,
        Func<Uri,SourceType,FolderRules,CancellationToken,Task<CanonicalDocument>> extract);
    public Task ExecuteAsync(IngestJob job,JobFence fence,CancellationToken ct=default);
}
public SourceRevision? PublishFolderExtraction(ExtractionRequest request,RevisionDraft draft,
    IReadOnlyList<RevisionChunkDraft> chunks,PublicationMetadata metadata,EmbeddingSelection? embeddingSelection,JobFence fence,long now);
public IReadOnlyList<PageBoundary> RevisionPages(long revisionId);
```

Tasks12/13 also expose internal transaction helper `IngestionGenerationSQL.ensureBuilding(_ db:Database,notebookId:Int64,identity:GenerationIdentity,copyExisting:Bool,now:Int64) throws -> IndexGeneration` / `IngestionGenerationSQL.EnsureBuilding(SqliteConnection c,SqliteTransaction tx,long notebookId,GenerationIdentity identity,bool copyExisting,long now)->IndexGeneration`. It lives in the task-owned publication file. Reuse an identical building generation for incremental ingestion; explicit reindex (`copyExisting=false`) creates a fresh one and retires only prior building work for that notebook/identity. Copy unaffected vectors only if full identity and manifest revision agree. This helper composes WP3 `GenerationSQL.Create/Reconcile/CopyUnchangedVectors` and performs no IO.

```swift
public struct GenerationProgress: Sendable, Equatable {
    public let generationId: Int64?; public let done: Int; public let total: Int
    public let excluded: Int; public let failed: Bool; public let pausedForChat: Bool; public let hasActive: Bool
    public let jobId: Int64?; public let preparing: Bool; public let errorCode: String?
}
public actor FolderIndexCoordinator {
    public init(store: NotebookStore, admission: IngestionAdmission, clock: any IngestLeaseClock,
                session: @escaping @Sendable (Int64) async throws -> FolderEmbeddingSession?,
                selectedSelection: @escaping @Sendable (Int64) async throws -> EmbeddingSelection?)
    public func execute(job: IngestJob, fence: JobFence) async throws
    public func reindex(notebookId: Int64, identity: GenerationIdentity) async throws -> Int64
    public func discard(generationId: Int64) async throws
    public func discardJob(jobId: Int64) async throws
    public func progress(notebookId: Int64) async throws -> GenerationProgress
}
public actor FolderReconciler {
    public init(store: NotebookStore, clock: any IngestLeaseClock,
                requestScan: @escaping @Sendable (Int64, Bool) async throws -> Void)
    public func start() async throws
    public func stop() async
    public func reconcile(now: Int64) async throws
}
```

```csharp
public sealed record GenerationProgress(long? GenerationId,int Done,int Total,int Excluded,bool Failed,bool PausedForChat,bool HasActive,long? JobId,bool Preparing,string? ErrorCode);
public sealed class FolderIndexCoordinator {
    public FolderIndexCoordinator(NotebookStore store,IngestionAdmission admission,IIngestLeaseClock clock,
        Func<long,CancellationToken,Task<FolderEmbeddingSession?>> session,
        Func<long,Task<EmbeddingSelection?>> selectedSelection);
    public Task ExecuteAsync(IngestJob job,JobFence fence,CancellationToken ct=default);
    public Task<long> ReindexAsync(long notebookId,GenerationIdentity identity,CancellationToken ct=default);
    public Task DiscardAsync(long generationId,CancellationToken ct=default);
    public Task DiscardJobAsync(long jobId,CancellationToken ct=default);
    public Task<GenerationProgress> ProgressAsync(long notebookId,CancellationToken ct=default);
}
public sealed class FolderReconciler {
    public FolderReconciler(NotebookStore store,IIngestLeaseClock clock,Func<long,bool,Task> requestScan);
    public Task StartAsync(CancellationToken ct=default);
    public Task StopAsync();
    public Task ReconcileAsync(long now,CancellationToken ct=default);
}
```

Task14/15 store outputs: `requestReindex(notebookId:identity:now:) throws -> Int64`, `commitEmbeddingBatch(generationId:Int64,chunkIds:[Int64],revisionIds:[Int64],vectors:[[Float]],fence:JobFence,now:Int64) throws -> Bool`, `activateBuiltGeneration(id:Int64,selectedIdentity:GenerationIdentity,fence:JobFence,now:Int64) throws -> Bool`, `discardBuildingGeneration(id:Int64,now:Int64) throws`, `generationProgress(notebookId:Int64) throws -> GenerationProgress`; C# `long RequestReindex(long,GenerationIdentity,long)`, `bool CommitEmbeddingBatch(long,IReadOnlyList<long>,IReadOnlyList<long>,IReadOnlyList<float[]>,JobFence,long)`, `bool ActivateBuiltGeneration(long,GenerationIdentity,JobFence,long)`, `void DiscardBuildingGeneration(long,long)`, `GenerationProgress GenerationProgress(long)`. Define public named parameters with these same meanings. Typed APIs call WP3 kernels under one transaction; they are not a lease-free worker completion bypass.

## Task 12: [Swift] Extraction, descriptors, detector hooks and atomic publication

**Depends on:** 4, 8, 10, WP4 detector and WP3 revision_pages handoff. **Parallel with:** 13 and the Windows lane.

**Files:** `Sources/AINotebookCore/{FolderExtractionWorker.swift,SourceDescriptor.swift,NotebookStore+IngestionPublication.swift}`; `Tests/AINotebookCoreTests/FolderPublicationTests.swift`

**Interfaces — Consumes:** Swift `LanguageDetector.detectDocument(_:) -> LanguageDocumentResult?`, `detectText(_:) -> LanguageTextResult?`, `ChunkLanguage.resolve(label:reason:documentLabel:) -> ChunkLanguage`; C# `DetectDocument`, `DetectText`, `ChunkLanguage.Resolve(string?,string?,string?)`. Also WP3 `RevisionJobSQL.commitExtraction(_:sourceId:draft:chunks:fence:now:) throws -> SourceRevision?`. **Produces:** Swift publication/worker/descriptor/helper signatures above; C# publication block is exact parity.

- [ ] **Step 1 — red descriptor test and real fenced publication regression.**

```swift
import XCTest
@testable import AINotebookCore
final class FolderPublicationTests: XCTestCase {
    func testDescriptorUsesMetadataWithoutSummary() throws {
        let doc=CanonicalDocument(text:"# Body\nSecret prose",title:"Metadata",kind:"markdown",
            pages:[],sheetNames:[],encoding:"utf-8")
        let descriptor=SourceDescriptor.make(document:doc,filename:"fallback.md",sizeBytes:32,lang:"cs")
        XCTAssertEqual(descriptor.title,"Metadata")
        XCTAssertEqual(descriptor.lang,"cs")
        let data=try JSONEncoder().encode(descriptor)
        let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(fields.keys),Set(["version","title","type","pageCount","sheetCount","sizeBytes","lang"]))
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("Secret prose"))
    }
}
```

Run `swift test --filter FolderPublicationTests` → missing descriptor FAIL. Add `testAllPipelineFixtures`, `testMetadataAndEmbeddingRollback`, `testOriginalChangesDuringExtraction`, `testStaleTokenChangesNothing`, `testDocumentAndChunkDetection`, `testRevisionPageMapSurvivesRefresh`, `testEmptyRevision` (eight). Test harness in this file seeds real folder/source via WP3 APIs, queues and claims real extract jobs, blocks extraction at an actor barrier, changes fake FS or claims a replacement, then releases it; compare canonical bytes, scalar spans, source metadata, pages and queued generation job to shared projections. The test model is only created with WP4's internal `LanguageDetector(testModelData:tables:)` seam.

Add this executable store regression before implementation. Swift imports GRDB for SQL counts; C# imports Models, Storage and Dapper. It exercises the real predecessor seam; the shared WP6 worker cases must additionally verify metadata/page-map atomicity.

```swift
@MainActor
func testReclaimedJobRejectsOldCommitWithoutInsertingRows() throws {
    let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
    let notebook = try store.createNotebook(name: "fencing")
    let source = try store.createSource(notebookId: XCTUnwrap(notebook.id), type: .text,
        title: "document", uri: nil, rawPath: nil)
    let sourceId = try XCTUnwrap(source.id)
    let original = try store.commitForegroundRevision(sourceId: sourceId,
        draft: RevisionDraft(contentHash: "old-hash", canonicalText: "old", textFormatVersion: 1, chunkerVersion: 2),
        chunks: [RevisionChunkDraft(text: "old", tokenCount: 1, pageHint: nil,
            charStart: 0, charEnd: 3, lang: nil, langInherited: false)], now: 0, leaseToken: "seed")
    let stale = try store.beginExtraction(sourceId: sourceId, now: 10, leaseToken: "old-owner")
    XCTAssertEqual(try store.recoverExpiredJobs(now: 310), 1)
    let recovered = try XCTUnwrap(store.job(id: stale.jobId))
    XCTAssertEqual(recovered.state, "queued")
    XCTAssertEqual(recovered.nextRetryAt, 370)
    let replacement = try XCTUnwrap(store.claimJob(now: 370, leaseToken: "new-owner", id: stale.jobId))
    XCTAssertEqual(replacement.attempts, 2)
    let current = JobFence(jobId: stale.jobId, leaseToken: "new-owner")
    let next = RevisionDraft(contentHash: "new-hash", canonicalText: "new", textFormatVersion: 1, chunkerVersion: 2)
    let chunks = [RevisionChunkDraft(text: "new", tokenCount: 1, pageHint: nil,
        charStart: 0, charEnd: 3, lang: nil, langInherited: false)]
    XCTAssertNil(try store.commitExtraction(sourceId: sourceId, draft: next, chunks: chunks, fence: stale, now: 371))
    XCTAssertFalse(try store.failJob(fence: stale, error: "late-failure", now: 371))
    let kept = try XCTUnwrap(store.source(id: sourceId))
    XCTAssertEqual(kept.currentRevision, original.id)
    XCTAssertEqual(kept.publishedRevisionId, original.id)
    XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["old"])
    XCTAssertEqual(try store.job(id: stale.jobId)?.state, "running")
    XCTAssertEqual(try store.job(id: stale.jobId)?.leaseToken, "new-owner")
    try store.dbQueue.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE source_id=?", arguments: [sourceId]), 1)
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE source_id=?", arguments: [sourceId]), 1)
    }
    let published = try XCTUnwrap(store.commitExtraction(sourceId: sourceId, draft: next,
        chunks: chunks, fence: current, now: 372))
    XCTAssertEqual(try store.source(id: sourceId)?.publishedRevisionId, published.id)
    XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["new"])
    XCTAssertNil(try store.commitExtraction(sourceId: sourceId, draft: next, chunks: chunks, fence: stale, now: 373))
    XCTAssertEqual(try store.revision(id: original.id)?.draft.canonicalText, "old")
    XCTAssertEqual(try store.job(id: stale.jobId)?.state, "done")
    try store.dbQueue.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE source_id=?", arguments: [sourceId]), 2)
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE source_id=?", arguments: [sourceId]), 2)
    }
}
```

- [ ] **Step 2 — pipeline order.** Load current extraction request; missing/ineligible/unavailable source cancels current job. Open bounded snapshot through native adapter, determine SourceType from admitted extension, extract snapshot, build scalar chunks with maxChunks, detect document once from **canonical text**, then each original chunk. Apply ChunkLanguage.resolve: only minLetters/minWords abstention may inherit a confident document label; low-confidence/background/mixed/und/null cannot. Canonical text/spans never use normalized detector offsets. Encode coverage integer basis points and descriptor deterministically. Validate pre/post original identity+mtime+size+hash. Any changed bytes returns changedDuringExtraction, cancels current attempt and transactionally queues fresh work without publishing; normal IO/codec/limit failure uses failJob and leaves old published revision available.

```swift
let documentResult = detector.detectDocument(document.text)
let chunks = try ScalarChunker.bounded(document.text,pages:document.pages,maxChunks:request.rules.limits.chunks)
let annotated = chunks.map { chunk -> RevisionChunkDraft in
    let result = detector.detectText(chunk.text)
    let language = ChunkLanguage.resolve(label:result?.label,reason:result?.reason,documentLabel:documentResult?.label)
    return RevisionChunkDraft(text:chunk.text,tokenCount:chunk.tokenCount,pageHint:chunk.pageHint,
        charStart:chunk.charStart,charEnd:chunk.charEnd,lang:language.lang,langInherited:language.langInherited)
}
```

- [ ] **Step 3 — one fenced publication transaction.** Validate running unexpired token, kind/target, expected current pointer, present/eligible, folder still exists, matching persisted observation mtime/size and unchanged rules. Recheck rules from latest folder row and request; rule update cancels old jobs. On mismatch return nil with no metadata/chunk changes (current owner superseded → cancel). Compose `RevisionJobSQL.commitExtraction`, insert all revision_pages, set source committed content_hash/mtime/size/encoding/lang/coverage/descriptor, and call ensureBuilding + enqueue one generation embed job if an embedding selection exists with verified dimensions. If dimensions are unknown, enqueue one notebook-target bootstrap embed job with persisted selection options. No configured embedding selection → lexical publication still succeeds. Never infer dimensions from a model name. If any SQL/page/vector-target validation fails, rollback the job completion, revision, chunks, source pointer and metadata together. Call `notifyFolderIngestionChanged(notebookId:)` once after commit only. Revision page reader sorts page ascending and validates owner from revision; old maps survive new publication and are GC-cascaded with their revision.

`requestFreshExtraction(sourceId:fence:now:) throws -> Bool` / `bool RequestFreshExtraction(long sourceId,JobFence fence,long now)` is also produced in this publication extension: validate fence, cancel only this owner, enqueue new expected-current job, mark pending, all in one transaction. It is used for changed-during-extraction; an expired owner may not create duplicate work after replacement.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter FolderPublicationTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/FolderExtractionWorker.swift Sources/AINotebookCore/SourceDescriptor.swift Sources/AINotebookCore/NotebookStore+IngestionPublication.swift Tests/AINotebookCoreTests/FolderPublicationTests.swift
git commit -m "feat(ingestion): Swift multilingual fenced revision publication" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: nine tests and every pipeline fixture green; stale workers publish zero rows; both full suites green.

## Task 13: [Windows] Extraction, descriptors, detector hooks and atomic publication

**Depends on:** 5, 9, 11, WP4 detector and WP3 revision_pages. **Parallel with:** 12 and Swift lane.

**Files:** `windows/src/AINotebook.Core/Ingestion/{FolderExtractionWorker.cs,SourceDescriptor.cs}`; `windows/src/AINotebook.Core/Storage/NotebookStore.IngestionPublication.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderPublicationTests.cs`

**Interfaces — Consumes:** C# `LanguageDetector.DetectDocument/DetectText`, `ChunkLanguage.Resolve`, `RevisionJobSQL.CommitExtraction`; Swift counterparts specified in Task12. **Produces:** C# publication/descriptor/worker/helper signatures above including RequestFreshExtraction; Swift publication block fixes parity.

- [ ] **Step 1 — red descriptor test and pipeline harness.**

```csharp
using System.Text.Json;
using AINotebook.Core.Ingestion;
using Xunit;
public sealed class FolderPublicationTests {
    [Fact] public void DescriptorUsesMetadataWithoutSummary() {
        var doc=new CanonicalDocument("# Body\nSecret prose","Metadata","markdown",
            Array.Empty<PageBoundary>(),Array.Empty<string>(),"utf-8");
        var descriptor=SourceDescriptor.Make(doc,"fallback.md",32,"cs");
        Assert.Equal("Metadata",descriptor.Title); Assert.Equal("cs",descriptor.Lang);
        var json=JsonSerializer.SerializeToElement(descriptor,new JsonSerializerOptions{PropertyNamingPolicy=JsonNamingPolicy.CamelCase});
        Assert.Equal(new[]{"lang","pageCount","sheetCount","sizeBytes","title","type","version"},
            json.EnumerateObject().Select(p=>p.Name).Order(StringComparer.Ordinal));
        Assert.DoesNotContain("Secret prose",json.GetRawText());
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderPublicationTests` → missing descriptor FAIL. Add Facts `AllPipelineFixtures`, `MetadataAndEmbeddingRollback`, `OriginalChangesDuringExtraction`, `StaleTokenChangesNothing`, `DocumentAndChunkDetection`, `RevisionPageMapSurvivesRefresh`, `EmptyRevision`. Fixture harness uses real store/job claims, fake FS and TaskCompletionSource barriers; seed/read connection under Gate. Test-only detector is `LanguageDetector.CreateForTests(bytes,UnicodeTables.LoadBundled())`, unavailable path uses `LanguageDetector.Unavailable`.

Add this executable store regression before implementation. Swift imports GRDB for SQL counts; C# imports Models, Storage and Dapper. It exercises the real predecessor seam; the shared WP6 worker cases must additionally verify metadata/page-map atomicity.

```csharp
[Fact]
public void ReclaimedJobRejectsOldCommitWithoutInsertingRows()
{
    using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
    long notebookId = store.CreateNotebook("fencing").Id!.Value;
    long sourceId = store.CreateSource(notebookId, SourceType.Text, "document", null, null).Id!.Value;
    var original = store.CommitForegroundRevision(sourceId, new RevisionDraft("old-hash", "old", 1, 2),
        new[] { new RevisionChunkDraft("old", 1, null, 0, 3, null, false) }, 0, "seed");
    var stale = store.BeginExtraction(sourceId, 10, "old-owner");
    Assert.Equal(1, store.RecoverExpiredJobs(310));
    var recovered = store.Job(stale.JobId)!;
    Assert.Equal("queued", recovered.State);
    Assert.Equal(370, recovered.NextRetryAt);
    var replacement = store.ClaimJob(370, "new-owner", stale.JobId)!;
    Assert.Equal(2, replacement.Attempts);
    var current = new JobFence(stale.JobId, "new-owner");
    var next = new RevisionDraft("new-hash", "new", 1, 2);
    var chunks = new[] { new RevisionChunkDraft("new", 1, null, 0, 3, null, false) };
    Assert.Null(store.CommitExtraction(sourceId, next, chunks, stale, 371));
    Assert.False(store.FailJob(stale, "late-failure", 371));
    var kept = store.Source(sourceId)!;
    Assert.Equal(original.Id, kept.CurrentRevision);
    Assert.Equal(original.Id, kept.PublishedRevisionId);
    Assert.Equal(new[] { "old" }, store.Chunks(sourceId).Select(c => c.Text));
    Assert.Equal("running", store.Job(stale.JobId)!.State);
    Assert.Equal("new-owner", store.Job(stale.JobId)!.LeaseToken);
    lock (store.Gate)
    {
        Assert.Equal(1, store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM source_revisions WHERE source_id=$id", new { id = sourceId }));
        Assert.Equal(1, store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM source_chunks WHERE source_id=$id", new { id = sourceId }));
    }
    var published = store.CommitExtraction(sourceId, next, chunks, current, 372);
    Assert.NotNull(published);
    Assert.Equal(published.Id, store.Source(sourceId)!.PublishedRevisionId);
    Assert.Equal(new[] { "new" }, store.Chunks(sourceId).Select(c => c.Text));
    Assert.Null(store.CommitExtraction(sourceId, next, chunks, stale, 373));
    Assert.Equal("old", store.Revision(original.Id)!.Draft.CanonicalText);
    Assert.Equal("done", store.Job(stale.JobId)!.State);
    lock (store.Gate)
    {
        Assert.Equal(2, store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM source_revisions WHERE source_id=$id", new { id = sourceId }));
        Assert.Equal(2, store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM source_chunks WHERE source_id=$id", new { id = sourceId }));
    }
}
```

- [ ] **Step 2 — implement worker.** Validate request, acquire native snapshot and dispose it in finally, extract admitted type, chunk canonical scalars, run document detection once and per-chunk detection, construct metadata and strict exact page intervals. Never route through old grapheme Chunker or old sharedStrings extractor. Re-stat and re-hash original; changes use RequestFreshExtraction, no partial publication. Cancellation propagates to queue; normal failed codec/limit/IO attempt is recorded by FailJob with the claimed fence. No BeginExtraction call inside already claimed worker.

```csharp
var documentResult=detector.DetectDocument(document.Text);
var chunks=ScalarChunker.Bounded(document.Text,document.Pages,request.Rules.Limits.Chunks)
    .Select(chunk=>{
        var result=detector.DetectText(chunk.Text);
        var lang=ChunkLanguage.Resolve(result?.Label,result?.Reason,documentResult?.Label);
        return chunk with { Lang=lang.Lang,LangInherited=lang.LangInherited };
    }).ToArray();
```

- [ ] **Step 3 — atomic locked transaction.** Under `_gate`, begin immediate transaction, validate lease/kind/target/current pointer and latest folder rules/eligibility/observation. Call RevisionJobSQL.CommitExtraction with the supplied transaction; null returns without metadata updates. Insert immutable pages, update descriptor/language/coverage/encoding/hash, create/reconcile a compatible building successor for verified dimensions or enqueue a notebook bootstrap embed job when dimensions are unknown, in the same transaction. Do not call a public store method that starts another transaction. Empty detector result serializes as SQL NULL; completed und persists as und. Metadata serializer uses camelCase and deterministic dictionary ordering for shares. Rollback fault injection after page insertion proves old source pointer, metadata and job state remain intact. After the transaction commits and `_gate` is released, call `NotifyFolderIngestionChanged` once. Rejected fences and rollback emit nothing; retrieval re-derives its SQL eligibility mask each turn.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderPublicationTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Ingestion/FolderExtractionWorker.cs windows/src/AINotebook.Core/Ingestion/SourceDescriptor.cs windows/src/AINotebook.Core/Storage/NotebookStore.IngestionPublication.cs windows/tests/AINotebook.Core.Tests/Ingestion/FolderPublicationTests.cs
git commit -m "feat(win-ingestion): multilingual fenced revision publication" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: nine Facts green, exact shared metadata/spans/page maps; both full suites pass.

## Captured embedding sessions and dimension bootstrap (Tasks 14–15)

The current provider interface (`Embedder.swift:5`, `Ollama/ChatTurn.cs:15`) supplies vectors but no dimension metadata; ProviderConfig has no dimensions (`Providers/ProviderConfig.swift:8`, Windows `Providers/ProviderConfig.cs:3`). The current router rereads its config on each batch (`Providers/ProviderRouter.swift:136`). WP2 supplies immutable **chat** sessions, not embedding sessions (WP2 plan:141). Implement these new provider-owned types in `Sources/AINotebookCore/Providers/FolderEmbeddingSession.swift` and `windows/src/AINotebook.Core/Providers/FolderEmbeddingSession.cs`, owned by Tasks14/15:

```swift
public struct FolderEmbeddingSession: Sendable {
    public init(config:ProviderConfig, model:String, apiKey:String?, modelDigest:String?,
                queryFormatVersion:String, docFormatVersion:String, session:URLSession = .shared) throws
    public var selection: EmbeddingSelection { get } // dims nil until verified by a response
    public func identity(dims:Int) throws -> GenerationIdentity
    public func embed(inputs:[String]) async throws -> [[Float]]
}
```

```csharp
public sealed class FolderEmbeddingSession {
    public FolderEmbeddingSession(ProviderConfig config,string model,string? apiKey,string? modelDigest,
        string queryFormatVersion,string docFormatVersion,HttpClient http);
    public EmbeddingSelection Selection { get; }
    public GenerationIdentity Identity(int dims);
    public Task<float[][]> EmbedAsync(IReadOnlyList<string> inputs,CancellationToken ct=default);
}
```

Construction copies config and checks enabled, nonblank raw model, WP2 root validity, privacy acknowledgement, and embedding endpoint capability. Chat-only types throw unsupportedEndpoint; do not route to Ollama. Copy the API key into a private captured adapter; it is neither logged nor Codable/ToString output. `endpointRevision` is lowercase SHA256 of UTF-8 `type.storageString + "\n" + normalizedRoot`; providerId/model/digest/formats/chunker2 are separate identity fields. A key rotation does not change vector space identity; endpoint/type changes do. Session selections compare every field except unknown dimensions; a supplied known dimension must match the response.

Use the corrected WP2 adapters with captured root: Swift `OpenAIEmbeddingAdapter(baseURL:apiKey:session:)` (`Providers/OpenAIAdapters.swift:45`) or `OllamaClient(baseURL:session:)` (`OllamaClient.swift:12`); C# `OpenAIEmbeddingAdapter(http,baseUrl,apiKey)` (`Providers/OpenAIEmbeddingAdapter.cs:20`) or `OllamaClient(http,new Uri(root))` (`Ollama/OllamaClient.cs:15`). The latter requires WP2 Task3's landed absolute-URL fix (WP2 plan:795): it must never assign HttpClient.BaseAddress and every request uses ProviderApiRoot.Build with its captured root. No new client factory is required. In the session test give the injected HttpClient a different BaseAddress and assert the actual embedding request still reaches the captured root. The session calls existing provider methods, with document formatting captured by docFormatVersion. No network constructor belongs in ingestion files.

Task14/15 add `requestEmbeddingBuild(notebookId:Int64,selection:EmbeddingSelection,copyExisting:Bool,now:Int64) throws -> Int64` / `long RequestEmbeddingBuild(long notebookId,EmbeddingSelection selection,bool copyExisting,long now)`, returning **job ID**, and coordinator `requestReindex(notebookId:Int64) async throws -> Int64` / `Task<long> RequestReindexAsync(long notebookId,CancellationToken ct=default)`. The latter captures a session and persists its selection. Existing `requestReindex(...identity...)` helper remains useful when dimensions are already verified; UI uses the capture method. Folder/loose publication calls requestEmbeddingBuild's transaction kernel so revision publication and enqueue remain atomic.

Unknown dimensions follow this exact sequence:

1. Enqueue one `kind=embed,target=notebook:<id>` job with `{selection,copyExisting}` in options_json; coalesce only identical queued options. Capture source/chunk/revision IDs for the first eligible published batch. If no batch exists, complete the notebook job through its live fence without creating/activating a generation; later publication enqueues fresh work.
2. Claim/renew normally, acquire chat admission before provider call, and verify captured session selection equals the durable options and currently selected target. Send that real batch once. Validate response count, all dimensions equal and >0, finite nonzero vectors. Never discover dimensions using an extra user-billed probe.
3. In **one** transaction validate lease, notebook target, selection and every source/revision fence; derive full identity from returned dimensions; create/reuse compatible building generation; reconcile manifest; insert accepted vectors; retarget the same running job to `generation:<id>` without changing attempts/token/lease/options. Commit no generation/vector if the lease or selection changed. Changed revisions are discarded and recaptured; they cannot lend their vectors to replacement chunks. If all captured rows became stale, leave the notebook job running and select a fresh batch.
4. Continue through normal fenced generation batches using this same immutable session. A setting change after the call prevents activation and cancels the superseded running job under its live fence; mark its building generation failed with embeddingSelectionChanged (bootstrap has no generation). Restart may reconstruct a session only if it matches durable options. Terminal fifth failure marks the associated generation `failed` in the same fenced transaction as job failure; a bootstrap failure has no generation row to change. Retry creates a new job/build. Progress exposes jobId/preparing/errorCode even before a generation exists. DiscardJob validates that job belongs to the notebook, cancels a bootstrap or delegates generation discard; Retry captures current selection into a new job, never resets old attempts. Chat admission waits leave the job running with lease renewals and generation.state=`building`; they do not invoke pauseJob. User pause applies only to queued jobs under the frozen contract. Never write `paused` into index_generations.

Tasks14/15 also produce `invalidateEmbeddingSelection(fence:JobFence,now:Int64) throws -> Bool` / `bool InvalidateEmbeddingSelection(JobFence fence,long now)`. In one transaction require a running, unexpired matching embed token; update that job to cancelled with error=embeddingSelectionChanged and NULL lease/token/retry; if its target is a building generation, mark that generation failed. Return false without changes for a stale owner or non-building generation. Notebook bootstrap targets have no generation to update. Retry captures the current selection into a new job; the old attempts are immutable. Shared selected-provider-changed and endpoint-changed-between-batches cases assert these states plus unchanged active manifest/vectors.

Add transaction kernel `IngestionGenerationSQL.enqueueBuild` / `EnqueueBuild` to the publication file owned12/13, returning jobId; it accepts notebookId, selection, copyExisting and now plus caller Database/connection+transaction. It must exist before Tasks14/15 branch. Task14/15 implement bootstrap commit in their owned generation store extension:

```swift
public func commitBootstrapBatch(notebookId:Int64,selection:EmbeddingSelection,dims:Int,
    chunkIds:[Int64],revisionIds:[Int64],vectors:[[Float]],copyExisting:Bool,
    fence:JobFence,now:Int64) throws -> Int64? // generation ID or nil when fenced out
```

```csharp
public long? CommitBootstrapBatch(long notebookId,EmbeddingSelection selection,int dims,
    IReadOnlyList<long> chunkIds,IReadOnlyList<long> revisionIds,IReadOnlyList<float[]> vectors,
    bool copyExisting,JobFence fence,long now);
```

Concrete vector-shape validation before entering the store (Swift in coordinator file; C# in coordinator class):

```swift
func validatedDimensions(_ vectors:[[Float]], count:Int) throws -> Int {
    guard vectors.count == count, let dims=vectors.first?.count, dims>0,
          vectors.allSatisfy({ $0.count == dims && $0.allSatisfy(\.isFinite)
              && $0.contains(where: { $0 != 0 }) }) else {
        throw IngestionError(code:"invalidVector")
    }
    return dims
}
```

```csharp
static int ValidatedDimensions(float[][] vectors,int count) {
    if(vectors.Length!=count || vectors.Length==0 || vectors[0].Length==0)
        throw new FolderIngestionException("invalidVector");
    int dims=vectors[0].Length;
    if(vectors.Any(v=>v.Length!=dims || v.Any(x=>!float.IsFinite(x)) || !v.Any(x=>x!=0)))
        throw new FolderIngestionException("invalidVector");
    return dims;
}
```

The generation fixtures include 2D first-response success, empty corpus, mismatched response lengths, dimensions changing on second batch, stale bootstrap token, settings changing while first batch is in flight, endpoint changing between batches, no API-key serialization, rejected chat-only selection and exhausted provider failure. Both test files include provider request capture through existing URLProtocol/HttpMessageHandler test seams; assert captured URL/model stays fixed and generation identity equals the response space. The old active generation remains readable in every failure case.

## Task 14: [Swift] Generation worker, re-index action and durable reconciliation

**Depends on:** 12, WP2 corrected provider adapters. **Parallel with:** 13, 15 and downstream Windows lane.

**Files:** `Sources/AINotebookCore/{FolderIndexCoordinator.swift,NotebookStore+IngestionGenerations.swift,FolderReconciler.swift}`; `Sources/AINotebookCore/Providers/FolderEmbeddingSession.swift`; `Tests/AINotebookCoreTests/FolderGenerationTests.swift`

**Interfaces — Consumes:** `EmbeddingProducing.embed(model:String,inputs:[String]) async throws -> [[Float]]`, WP3 GenerationSQL transaction seams, JobQueue and IngestionAdmission. C# twin `IEmbeddingProducing.EmbedAsync(string,IReadOnlyList<string>,CancellationToken)->Task<float[][]>` (preserve the landed provider interface's collection type); its source is `windows/src/AINotebook.Core/Ollama/ChatTurn.cs:15`. **Produces:** Swift coordinator/reconciler/store signatures above; C# equivalents there are exact outputs of Task15. Also expose `requestFolderScan(folderId:Int64,verifyAll:Bool,now:Int64) throws -> Int64` / `long RequestFolderScan(long folderId,bool verifyAll,long now)` and `watchedFolders() throws -> [FolderSource]` / `IReadOnlyList<FolderSource> WatchedFolders()` in the new generation extension for app-wide coordination.

Durable scan mode uses the WP3 `options_json` handoff above. `scanOptions(jobId:Int64) throws -> Bool` / `bool ScanOptions(long jobId)` reads `verifyAll`. Coalescing upgrades false→true only for an unclaimed job; a running normal scan gets one queued verify-all successor. Task14/15 own the request/read helpers, and Task16/17 dispatch the persisted mode after claim.

- [ ] **Step 1 — red no-destructive-reindex test.**

```swift
import XCTest
@testable import AINotebookCore
@MainActor final class FolderGenerationTests: XCTestCase {
    func testReindexDoesNotActivateEmptyBuild() throws {
        let store=try NotebookStore(path:.inMemory)
        let nb=try store.createNotebook(name:"index")
        let identity=GenerationIdentity(providerId:"local",endpointRevision:"1",model:"m",modelDigest:nil,
            dims:2,normalization:"l2",queryFormatVersion:"1",docFormatVersion:"1",chunkerVersion:"2")
        let id=try store.requestReindex(notebookId:nb.id!,identity:identity,now:0)
        XCTAssertEqual(try store.generation(id:id)?.state,"building")
        XCTAssertNil(try store.activeGeneration(notebookId:nb.id!))
        XCTAssertEqual(try store.generationProgress(notebookId:nb.id!).generationId,id)
    }
}
```

Run `swift test --filter FolderGenerationTests` → missing requestReindex FAIL. Add `testAllGenerationFixtures`, `testStaleBatchAndActivationFence`, `testChatPausesOnlyNextBatch`, `testRestartAndPeriodicReconcile`, `testDiscardAndPrivacyFailure`, `testVerifyAllSurvivesRestart`, `testPinnedOldRevisionSurvives` (eight). Seed an actual active generation with vectors for preservation tests; empty-generation test alone is not sufficient. Use fake embedder barriers, fake clock and real generation SQL.

Add this nonempty active-index regression to the same test class (C# imports Models and Rag in addition to Storage). It prevents a green empty-build test from masking destructive re-index behavior.

```swift
func testReindexLeavesActiveRevisionAndVectorsAvailable() throws {
    let store=try NotebookStore(path:.inMemory,configuredEmbeddingModelKey:nil)
    let nb=try store.createNotebook(name:"active")
    let source=try store.createSource(notebookId:nb.id!,type:.text,title:"doc",uri:nil,rawPath:nil)
    let revision=try store.commitForegroundRevision(sourceId:source.id!,draft:RevisionDraft(
        contentHash:"h",canonicalText:"kept",textFormatVersion:1,chunkerVersion:2),
        chunks:ScalarChunker.chunk("kept"),now:0,leaseToken:"seed")
    let identity=GenerationIdentity(providerId:"local",endpointRevision:"1",model:"m",modelDigest:nil,
        dims:2,normalization:"l2",queryFormatVersion:"1",docFormatVersion:"1",chunkerVersion:"2")
    let active=try store.createGeneration(notebookId:nb.id!,identity:identity,now:0)
    try store.setManifest(generationId:active.id,entries:[ManifestEntry(sourceId:source.id!,revisionId:revision.id,state:"pending",reason:nil)])
    let chunk=try XCTUnwrap(store.chunks(sourceId:source.id!).first)
    try store.storeGenerationEmbedding(generationId:active.id,chunkId:chunk.id!,vector:EmbeddingVector(values:[1,0]))
    try store.setManifest(generationId:active.id,entries:[ManifestEntry(sourceId:source.id!,revisionId:revision.id,state:"done",reason:nil)])
    try store.activateGeneration(id:active.id,now:1)
    let build=try store.requestReindex(notebookId:nb.id!,identity:identity,now:2)
    XCTAssertNotEqual(build,active.id)
    XCTAssertEqual(try store.activeGeneration(notebookId:nb.id!)?.id,active.id)
    XCTAssertEqual(try store.manifest(generationId:active.id).first?.revisionId,revision.id)
    XCTAssertEqual(try store.chunks(sourceId:source.id!).map(\.text),["kept"])
    try store.discardBuildingGeneration(id:build,now:3)
    XCTAssertEqual(try store.activeGeneration(notebookId:nb.id!)?.id,active.id)
    XCTAssertEqual(try store.source(id:source.id!)?.publishedRevisionId,revision.id)
}
```

- [ ] **Step 2 — build beside active.** requestReindex creates a fresh building generation from fully captured provider/endpoint/model/dimensions/format identity, copyExisting=false, queue exactly one generation job. Incremental publication reuses compatible building or creates successor/copies unchanged vectors. Batch size16; select eligible pending manifest's **published** chunk text with explicit chunk/revision IDs and format with captured document-format identity. Immediately before provider call await background admission; then recheck lease because waiting chat may span renewals. The captured FolderEmbeddingSession below owns endpoint/model/secret/consent; compare it with persisted job options before sending. Errors propagate through the current fence. No raw text silently truncated to embedder context; use declared tokenizer/input cap if available and fail with visible exclusion reason if unsupported, retaining lexical evidence. A future different chunker version requires a new generation; this WP does not relabel truncated text as v2.

Commit batch transaction validates running embed fence, generation still building and identical requested identity, each manifest revision equals captured revision, source still eligible/present/published, vector count/dimensions/finite/nonzero norm, then stores through WP3 kernel. Any stale member is discarded and reconciled to newest published revision; no vector attaches to a different revision. Mark a source done only when every chunk is covered; empty published revision is done with zero vectors. Explicit exclusions record reason for unavailable/ineligible or terminal extraction/embedding failure. An excluded failed refresh may still keep old lexical published revision; never delete it.

- [ ] **Step 3 — activation and reconciliation.** Reconcile immediately before activation in the same transaction, verify selected identity is unchanged, call `GenerationSQL.activate` with nonnil fence so retirement/activation/job completion are atomic. If new pending source appears, continue the same job, keep active; if selected provider changed, call the fenced invalidation helper below, cancelling the superseded job and failing its building generation without changing the active generation. Never convert a running job directly to paused. Discard cancels its jobs and retires building only; active and pinned generations survive. Queue gc via generation target only after retirement, delegating retention to WP3/WP5 kernels.

FolderReconciler.start recovers leases, requeues retryable failures, repairs orphan scans to partial without missing marking, schedules every persisted watch-enabled folder once, resumes queued extract/embed/gc jobs and starts clock-driven 1,800-second reconciliation. It enumerates all notebooks from store, not only selected one. Disabled folders do not auto-scan; manual Scan now/Verify all still works. Shutdown cancels timer and workers and waits for disposal. Reconcile coalesces duplicate due scans and queued embed jobs, excludes orphan targets and marks unavailable roots through scanner result. last_full_scan_at changes only after full success, not startup scheduling.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter FolderGenerationTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/Providers/FolderEmbeddingSession.swift Sources/AINotebookCore/FolderIndexCoordinator.swift Sources/AINotebookCore/NotebookStore+IngestionGenerations.swift Sources/AINotebookCore/FolderReconciler.swift Tests/AINotebookCoreTests/FolderGenerationTests.swift
git commit -m "feat(ingestion): Swift generation worker and folder reconciliation" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: nine methods, generation/reconcile/restart fixtures green; old active/pinned vectors unchanged through failed/restarted builds; both suites pass.

## Task 15: [Windows] Generation worker, re-index action and durable reconciliation

**Depends on:** 13, WP2 corrected provider adapters. **Parallel with:** 14 and downstream Swift lane.

**Files:** `windows/src/AINotebook.Core/Ingestion/{FolderIndexCoordinator.cs,FolderReconciler.cs}`; `windows/src/AINotebook.Core/Providers/FolderEmbeddingSession.cs`; `windows/src/AINotebook.Core/Storage/NotebookStore.IngestionGenerations.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderGenerationTests.cs`

**Interfaces — Consumes:** `IEmbeddingProducing.EmbedAsync`, WP3 GenerationSQL, JobQueue, admission; Swift twin from Task14. **Produces:** C# generation/reconciler/store signatures above plus RequestFolderScan/ScanOptions/WatchedFolders; Swift declarations fix identical behavior. Requires the durable options_json handoff, not transient error-field storage.

- [ ] **Step 1 — red test.**

```csharp
using AINotebook.Core.Storage;
using Xunit;
public sealed class FolderGenerationTests {
    [Fact] public void ReindexDoesNotActivateEmptyBuild() {
        using var store=new NotebookStore(StorePath.InMemory);
        long nb=store.CreateNotebook("index").Id!.Value;
        var identity=new GenerationIdentity("local","1","m",null,2,"l2","1","1","2");
        long id=store.RequestReindex(nb,identity,0);
        Assert.Equal("building",store.Generation(id)!.State);
        Assert.Null(store.ActiveGeneration(nb));
        Assert.Equal(id,store.GenerationProgress(nb).GenerationId);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderGenerationTests` → missing methods FAIL. Add Facts `AllGenerationFixtures`, `StaleBatchAndActivationFence`, `ChatPausesOnlyNextBatch`, `RestartAndPeriodicReconcile`, `DiscardAndPrivacyFailure`, `VerifyAllSurvivesRestart`, `PinnedOldRevisionSurvives`. Seed nonempty active index in shared-case harness; barriers permit source mutation/chat start/lease loss while a provider batch is in flight.

Add this nonempty active-index regression to the same test class (C# imports Models and Rag in addition to Storage). It prevents a green empty-build test from masking destructive re-index behavior.

```csharp
[Fact] public void ReindexLeavesActiveRevisionAndVectorsAvailable() {
    using var store=new NotebookStore(StorePath.InMemory,configuredEmbeddingModelKey:null);
    long nb=store.CreateNotebook("active").Id!.Value;
    long sid=store.CreateSource(nb,SourceType.Text,"doc",null,null).Id!.Value;
    var revision=store.CommitForegroundRevision(sid,new RevisionDraft("h","kept",1,2),
        ScalarChunker.Chunk("kept"),0,"seed");
    var identity=new GenerationIdentity("local","1","m",null,2,"l2","1","1","2");
    var active=store.CreateGeneration(nb,identity,0);
    store.SetManifest(active.Id,new[]{new ManifestEntry(sid,revision.Id,"pending",null)});
    var chunk=Assert.Single(store.Chunks(sid));
    store.StoreGenerationEmbedding(active.Id,chunk.Id!.Value,new EmbeddingVector(new float[]{1,0}));
    store.SetManifest(active.Id,new[]{new ManifestEntry(sid,revision.Id,"done",null)});
    store.ActivateGeneration(active.Id,1);
    long build=store.RequestReindex(nb,identity,2);
    Assert.NotEqual(active.Id,build);
    Assert.Equal(active.Id,store.ActiveGeneration(nb)!.Id);
    Assert.Equal(revision.Id,Assert.Single(store.Manifest(active.Id)).RevisionId);
    Assert.Equal(new[]{"kept"},store.Chunks(sid).Select(c=>c.Text));
    store.DiscardBuildingGeneration(build,3);
    Assert.Equal(active.Id,store.ActiveGeneration(nb)!.Id);
    Assert.Equal(revision.Id,store.Source(sid)!.PublishedRevisionId);
}
```

- [ ] **Step 2 — implement generation worker.** Snapshot provider identity before await, select explicit manifest revision chunks in batches16, format captured document input, await chat gate before each batch, and revalidate lease/generation before sending. Query embeddings bypass this gate. Validate response vector count/dimensions/finiteness and input-size support; never silently truncate. Store batch under gate in one immediate transaction, verify current eligible publication and manifest revision for each chunk, discard stale entries and reconcile. Mark done only on whole revision coverage; excluded requires reason. Preserve active index during provider/privacy errors and process restart.

- [ ] **Step 3 — atomic activation and persisted scheduling.** RequestReindex creates new building without copying; incremental successor copies only full-identity-equal unchanged rows. CommitEmbeddingBatch and ActivateBuiltGeneration always require a matching unexpired embed fence. Activation reconciles then verifies latest eligible current/published state, matches current selected identity and calls WP3 GenerationSQL.Activate with fence; old retirement and done job occur together. Discard cancels build work/retains active; gc delegates pin/current/published retention. RequestFolderScan stores verifyAll in options_json, coalesces queued options, preserves mode after claim/restart.

StartAsync performs lease recovery and due retries, marks abandoned scan partial without inventing missing files, schedules persisted enabled folders from all notebooks, resumes jobs, and runs injected-clock 1,800-second periodic reconciliation. Timer and worker lifetimes belong to app coordinator, not pages. Every SQL call stays inside gate, all awaits outside. StopAsync cancels and joins timers/workers; no background exception is swallowed without recording a job/folder error.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderGenerationTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Providers/FolderEmbeddingSession.cs windows/src/AINotebook.Core/Ingestion/FolderIndexCoordinator.cs windows/src/AINotebook.Core/Ingestion/FolderReconciler.cs windows/src/AINotebook.Core/Storage/NotebookStore.IngestionGenerations.cs windows/tests/AINotebook.Core.Tests/Ingestion/FolderGenerationTests.cs
git commit -m "feat(win-ingestion): generation worker and persisted reconciliation" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: nine Facts green including cancellation/restart and no-active lexical preservation; both Core suites pass.

## Runtime integration contract (Tasks 16–17)

Produce the following in new Core `FolderIngestionRuntime.swift` / `Ingestion/FolderIngestionRuntime.cs`. Swift runtime is an actor; C# runtime is `IAsyncDisposable`. Its constructor consumes `NotebookStore`, `FolderScanner`, `FolderExtractionWorker`, `FolderIndexCoordinator`, `JobQueue`, `IngestLeaseClock` and `IngestionAdmission`. Construction does no IO. Native handles are created through the exact injectable factory below. The `start/StartAsync` method is idempotent, owns the reconciler and dispatch tasks, and `stop/StopAsync` joins them. All callbacks carry a folder ID; no currently selected notebook is consulted.


```swift
public protocol FolderWatchHandle: Sendable { func start() throws; func stop() }
public protocol FolderWatchFactory: Sendable {
    func make(folder:FolderSource,onEvent:@escaping @Sendable (String)->Void) throws -> any FolderWatchHandle
}
public init(store:NotebookStore,scanner:FolderScanner,extraction:FolderExtractionWorker,
    index:FolderIndexCoordinator,queue:JobQueue,clock:any IngestLeaseClock,
    admission:IngestionAdmission,watches:any FolderWatchFactory)
```

```csharp
public interface IFolderWatchHandle : IDisposable { void Start(); }
public interface IFolderWatchFactory {
    IFolderWatchHandle Create(FolderSource folder,Action<string> onEvent);
}
public FolderIngestionRuntime(NotebookStore store,FolderScanner scanner,FolderExtractionWorker extraction,
    FolderIndexCoordinator index,JobQueue queue,IIngestLeaseClock clock,
    IngestionAdmission admission,IFolderWatchFactory watches);
```

NativeFolderWatchFactory (declared in the owned runtime file) returns FolderWatcher / NativeFolderWatchHandle. Test factory stores callbacks and returns a handle with start/stop counters, allowing lifecycle assertions without filesystem sleeps. The runtime owns these handles; Swift FolderWatchController only holds the runtime and presentation state.

| Swift public method | C# public method |
|---|---|
| `start() async throws` | `Task StartAsync(CancellationToken ct=default)` |
| `stop() async` | `Task StopAsync()` |
| `addFolder(notebookId:Int64,url:URL) async throws -> FolderSource` | `Task<FolderSource> AddFolderAsync(long notebookId,string path,CancellationToken ct=default)` |
| `scanNow(folderId:Int64,verifyAll:Bool) async throws -> Int64` | `Task<long> ScanNowAsync(long folderId,bool verifyAll,CancellationToken ct=default)` |
| `setWatching(folderId:Int64,enabled:Bool) async throws` | `Task SetWatchingAsync(long folderId,bool enabled,CancellationToken ct=default)` |
| `removeFolder(folderId:Int64) async throws` | `Task RemoveFolderAsync(long folderId,CancellationToken ct=default)` |
| `signal(folderId:Int64,at milliseconds:Int64,forceHash:Bool) async` | `Task SignalAsync(long folderId,long milliseconds,bool forceHash)` |
| `waitForFolderIdle(folderId:Int64) async throws` | `Task WaitForFolderIdleAsync(long folderId,CancellationToken ct=default)` |
| `drainOnce() async throws -> Bool` | `Task<bool> DrainOnceAsync(CancellationToken ct=default)` |

`drainOnce` attempts due work through JobQueue and returns whether an attempt ran; it is also the deterministic test seam. Startup launches two extract dispatch loops plus one scan and one embed/gc loop; JobQueue retains atomic claim and memory admission. For scanning, load `scanOptions(jobId:)` after claim and pass it to scanner; no view launches its own ingestion Task. `addFolder` resolves native identity off UI, persists defaults with WP3 createFolder, then enqueues a scan; overlapping roots fail before any watch starts. `setWatching(false)` persists the flag and disposes only that native watch, leaving manual scans possible. `removeFolder` first invalidates watch callback tokens, cancels folder/source jobs, then calls WP3 database deletion; it never calls a filesystem delete operation.

Native watcher adapters expose `start()/stop()` (Swift existing `FolderWatcher`) / `Start()/Dispose()` (new C# native adapter constructor `NativeFolderWatchHandle(string folder,Action<string> signal)`). The string is an event kind; FolderWatchEventPolicy maps it to a forced-hash boolean, which is OR-coalesced for one folder's pending rescan. The runtime is the **only** owner of `RescanSchedule`: native adapters send raw signals, with no second quiet-period timer. FSEvents stream latency remains 0.2 seconds, but the measured 500/5000 ms scheduling contract starts when Core receives a signal. Watch lifecycle runs process-wide in the Swift `FolderWatchController` holder and the Windows runtime registration. Tests inject watches with a token-guarded signal closure, without waiting on an OS event.

## Task 16: [Swift] Connect the durable runtime, native watcher and chat lifetime

**Depends on:** 14, WP2 router/provider conversion, WP3 compatibility bridge, WP5 typed-scope chat boundary if already landed. **Parallel with:** 17 and Windows lane. **Coordination:** lands before WP8 chat integration; WP8 then preserves the admission bracket. Never require WP8 first (its integration depends on WP6).

**Files:** `Sources/AINotebookCore/{FolderIngestionRuntime.swift,NotebookStore+IngestionPublication.swift,IngestionService.swift,Embedder.swift,EmbeddingWorker.swift,ChatEngine.swift,FolderWatcher.swift,LiveSourceSync.swift}`; `Sources/AINotebookApp/{AINotebookApp.swift,FolderWatchController.swift}`; `Tests/AINotebookCoreTests/{FolderIntegrationTests.swift,LiveSourceSyncTests.swift,FolderWatcherTests.swift}`.

**Interfaces — Consumes:** Swift runtime constructor dependencies and exact runtime signatures above; `IngestionService.ingestURL(_:into:) async throws -> Source` and `reIngest(sourceId:) async throws -> Source` (`IngestionService.swift:101,120`), `TextExtractor.extract(from:kind:) async throws -> ExtractedText` (`TextExtractor.swift:32`). C# parity consumes `IngestUrlAsync(Uri,long)->Task<Source>`, `ReIngestAsync(long,CancellationToken)->Task<Source>`, `ITextExtractor.ExtractAsync(Uri,SourceType)->Task<ExtractedText>`. **Produces:** runtime API above, `LiveSourceSync.recrawl(sourceId:) async throws -> Source` retained, and optional `admission:IngestionAdmission? = nil` parameter appended to `ChatEngine` constructor. C# twin appends `IngestionAdmission? admission=null`. Existing constructor arguments/defaults remain source compatible.

- [ ] **Step 1 — write red E2 and watcher-policy tests.** Put this test in `FolderIntegrationTests.swift`; the actor stub makes no network requests.

```swift
import XCTest
@testable import AINotebookCore
private actor RecrawlText: TextExtractor {
    var value = "first"
    func change(_ value: String) { self.value = value }
    func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        ExtractedText(title: "web", text: value)
    }
}
@MainActor final class FolderIntegrationTests: XCTestCase {
    func testRecrawlPreservesIdentityAndPublishesNewText() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "E2")
        let web = RecrawlText()
        let service = IngestionService(store: store, web: web)
        let original = try await service.ingestURL(URL(string:"https://example.invalid/doc")!, into: nb.id!)
        let oldRevision = try XCTUnwrap(store.source(id:original.id!)?.publishedRevisionId)
        await web.change("second")
        let refreshed = try await LiveSourceSync(store:store, ingestion:service).recrawl(sourceId:original.id!)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.uri, original.uri)
        XCTAssertEqual(try store.sources(notebookId:nb.id!).count, 1)
        XCTAssertEqual(try store.chunks(sourceId:original.id!).map(\.text), ["second"])
        XCTAssertNotEqual(refreshed.publishedRevisionId, oldRevision)
        XCTAssertNotNil(refreshed.lastSyncedAt)
        XCTAssertEqual(try store.revision(id:oldRevision)?.draft.canonicalText, "first")
    }
    func testChangedAndOverflowEventsRequireHash() {
        XCTAssertTrue(FolderWatchEventPolicy.forceHash(kind:"changed"))
        XCTAssertTrue(FolderWatchEventPolicy.forceHash(kind:"overflow"))
        XCTAssertTrue(FolderWatchEventPolicy.forceHash(kind:"renamed"))
        XCTAssertFalse(FolderWatchEventPolicy.forceHash(kind:"created"))
    }
}
```

`FolderWatchEventPolicy` is a pure enum in the owned runtime file with `static func forceHash(kind:String)->Bool`; its C# peer is `static bool ForceHash(string kind)`. Both consume `ingestion-ui-v1.json` watcher cases. Run `swift test --filter FolderIntegrationTests` → FAIL on the missing policy. The E2 test may already pass after WP3 and remains a regression, not an invented red. Add fixture-driven `testStartRestoresAllNotebooks`, `testDisableAndRemoveInvalidateCallbacks`, `testOneTrailingScan`, `testChatErrorAndCancellationReleaseAdmission`, `testLooseOfficeUsesCanonicalExtractor` and `testLegacyKickDoesNotDoubleEmbed` before integration.

- [ ] **Step 2 — runtime and watcher wiring.** Implement command methods in the contract. Replace `FolderWatcher.swift:126`'s unbounded trailing debounce with raw signal forwarding in runtime mode. Keep the existing initializer's configurable latency/debounce for standalone legacy watcher tests, but add `init(folder:URL,onEvent:@escaping @Sendable (String)->Void)` for runtime mode, with no native debounce; it classifies FSEvents flags (`MustScanSubDirs`, `UserDropped`, `KernelDropped`→overflow; rename/remove/content modification→their event kind). Native event paths are hints only; never extract them directly. RootChanged schedules full reconciliation; set WatchRoot flag. Check FSEventStreamStart's Bool result; release a failed stream and persist folder error via runtime. A stopped watch invalidates a captured UUID so queued callbacks cannot reschedule removed folders.

`FolderWatchController.swift:13` becomes one app-owned ObservableObject holding runtime and watches indexed by folder ID. Keep the complete zero-argument facade until Task18 removes SourceListView's old StateObject: `watchedFolder`, `isSyncing`, `isWatching`, `start(folder:sync:)` and `stop()` remain source-compatible. They delegate to the shared runtime and do no extraction. App construction installs the single runtime into this compatibility holder before views are made. `start` invokes the supplied sync closure once to register/persist the root; subsequent native signals belong to runtime. `stop` delegates setWatching(false) for that registered root. No second watcher is created. `AINotebookApp.swift:46,54,59,76,104` builds one admission/runtime, injects the holder as environment object, starts it once per process (not once per WindowGroup view), and stops it on termination. Register DispatchSource memory-pressure events with admission and clear the predicate on normal pressure. Creating another window must not start another queue.

- [ ] **Step 3 — one publication and embedding path.** Keep WP3's lease renewal for foreground loose files, text, web and notes. For loose PDF/Office/text production extraction route through BoundedDocumentExtractor and ScalarChunker v2, attach encoding/descriptor/language/page map with the same fenced metadata transaction used by folder publication; add a sibling `publishLooseExtraction` helper in the sequentially owned `NotebookStore+IngestionPublication.swift` extension, accepting sourceId, revision draft, chunks, metadata, identity, fence and now (C# same ordered arguments and `SourceRevision?` return). It omits folder-specific stat/rule checks but retains lease/current-pointer checks. Explicit injected legacy extractor test doubles continue to work; the production default path never uses old Office sharedStrings extraction. A folder source's reIngest schedules a durable extract rather than opening the old path directly. Raw-text and URL behavior remains callable and publishes canonical extractor output unchanged.

Replace `LiveSourceSync.syncFolder` implementation with a deprecated runtime-forwarding facade and migrate its existing tests to runtime add/scan/drain, retaining the changed-count 1/0/1 and stable-source assertions (`LiveSourceSyncTests.swift:26`). Add optional `folderRuntime:FolderIngestionRuntime? = nil` to IngestionService; the App injects it, and LiveSourceSync.syncFolder calls that runtime to find/add the persisted folder, request a scan, await that specific scan/extract completion and return the number of changed publications. It never scans files itself; absence of the optional runtime is an explicit unsupported legacy call error. Retain `contentHash(of:)` as a legacy MD5 utility for its existing test, but no durable path calls it. `recrawl` updates the timestamp using the **published SHA-256**, not an MD5 override. Preserve old revision evidence through refresh failures.

Production `EmbeddingWorker.kick()` now wakes runtime generation work, including loose/note publications; it must not also run legacy Embedder. Retain the old Embedder constructor for isolated compatibility tests, with the same shared admission gate before each background batch when supplied. Runtime requests a correctly captured generation identity/session, not a model string reread between batches. Start admission at the async send/regenerate method entry, before retrieval/query embedding; release in an awaited `do/catch` success/error/cancellation exit, including task cancellation and callback failure. Do not put async release in a detached defer. Question embedding bypasses the background gate. Regenerate uses the same entry point.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter 'FolderIntegrationTests|LiveSourceSyncTests|FolderWatcherTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/FolderIngestionRuntime.swift Sources/AINotebookCore/NotebookStore+IngestionPublication.swift Sources/AINotebookCore/IngestionService.swift Sources/AINotebookCore/Embedder.swift Sources/AINotebookCore/EmbeddingWorker.swift Sources/AINotebookCore/ChatEngine.swift Sources/AINotebookCore/FolderWatcher.swift Sources/AINotebookCore/LiveSourceSync.swift Sources/AINotebookApp/AINotebookApp.swift Sources/AINotebookApp/FolderWatchController.swift Tests/AINotebookCoreTests/FolderIntegrationTests.swift Tests/AINotebookCoreTests/LiveSourceSyncTests.swift Tests/AINotebookCoreTests/FolderWatcherTests.swift
git commit -m "feat(ingestion): connect Swift durable runtime and native watches" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight integration tests plus migrated watcher/sync tests green, all runtime fixture operations visited, both Core suites green. Swift App compile is included in the package build; Claude verifies process/window lifetime while running the app in Task18.

## Task 17: [Windows] Connect runtime, recursive watcher and chat lifetime

**Depends on:** 15, WP2 Core router/conversion, WP3 compatibility bridge. **Parallel with:** 16 and Swift lane; lands before WP8 chat integration.

**Files:** `windows/src/AINotebook.Core/Ingestion/{FolderIngestionRuntime.cs,IngestionService.cs,FolderWatchService.cs}`; `windows/src/AINotebook.Core/Storage/NotebookStore.IngestionPublication.cs`; `windows/src/AINotebook.Core/Rag/{Embedder.cs,EmbeddingWorker.cs,ChatEngine.cs}`; `windows/src/AINotebook.App/App.xaml.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/{FolderIntegrationTests.cs,FolderWatchServiceTests.cs}`.

**Interfaces — Consumes:** C# runtime contract and `ITextExtractor.ExtractAsync(Uri,SourceType)->Task<ExtractedText>`; Swift `TextExtractor.extract(from:kind:) async throws -> ExtractedText`. **Produces:** C# runtime API, raw-signal `NativeFolderWatchHandle(string folder,Action<string> signal)`, `void Start()`, `void Dispose()`, read-only `bool IsActive`, `string WatchedFolder`; Swift `FolderWatcher.init(folder:onEvent:)`, `start() throws`, `stop()`. Chat constructor appends the optional admission argument. Existing C# `IngestUrlAsync`/`ReIngestAsync` signatures above are preserved.

- [ ] **Step 1 — red tests.**

```csharp
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;
public sealed class FolderIntegrationTests {
    sealed class WebText : ITextExtractor {
        public string Value = "first";
        public Task<ExtractedText> ExtractAsync(Uri url,SourceType kind) =>
            Task.FromResult(new ExtractedText("web",Value));
    }
    [Fact] public async Task RecrawlPreservesIdentityAndPublishedEvidence() {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb=store.CreateNotebook("E2").Id!.Value;
        var web=new WebText();
        var service=new IngestionService(store,web:web);
        var old=await service.IngestUrlAsync(new Uri("https://example.invalid/doc"),nb);
        long oldRevision=store.Source(old.Id!.Value)!.PublishedRevisionId!.Value;
        web.Value="second";
        var refreshed=await service.ReIngestAsync(old.Id.Value);
        Assert.Equal(old.Id,refreshed.Id); Assert.Equal(old.Uri,refreshed.Uri);
        Assert.Single(store.Sources(nb));
        Assert.Equal(new[]{"second"},store.Chunks(old.Id.Value).Select(c=>c.Text));
        Assert.NotEqual(oldRevision,refreshed.PublishedRevisionId);
        Assert.Equal("first",store.Revision(oldRevision)!.Draft.CanonicalText);
    }
    [Fact] public void EventPolicyForcesChangedRenamedAndOverflow() {
        Assert.True(FolderWatchEventPolicy.ForceHash("changed"));
        Assert.True(FolderWatchEventPolicy.ForceHash("renamed"));
        Assert.True(FolderWatchEventPolicy.ForceHash("overflow"));
        Assert.False(FolderWatchEventPolicy.ForceHash("created"));
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderIntegrationTests` → FAIL on policy; retain passing E2 regression. Add Facts `StartRestoresAllNotebooks`, `DisableAndRemoveInvalidateCallbacks`, `OneTrailingScan`, `ChatErrorAndCancellationReleaseAdmission`, `LooseOfficeUsesCanonicalExtractor`, `LegacyKickDoesNotDoubleEmbed`. Runtime cases share the same event/projection fixture with Swift.

- [ ] **Step 2 — replace the old service.** At `FolderWatchService.cs:33` set IncludeSubdirectories=true and NotifyFilter FileName|DirectoryName|LastWrite|Size. Subscribe Created, Changed, Deleted, Renamed and Error **before** EnableRaisingEvents=true. Each handler only invokes the named-event callback; Error produces kind=overflow and a full scan, never swallows overflow. Remove per-event Task.Delay, MD5 and direct ReIngest calls (`:54–102`). Disposal disables, unsubscribes every event, and invalidates callback token. Keep `FolderWatchService` as a deprecated runtime facade with `FolderWatchService(FolderIngestionRuntime runtime)`, `Enable(long notebookId,string folder)`, `Disable()`, `Dispose()`, `IsActive` and `WatchedFolder` until Task19 replaces its view callers. Keep its DI registration in Task17. Enable/Disable enqueue runtime commands and route async errors to runtime status; no native extraction/MD5 code remains. The raw native adapter is `NativeFolderWatchHandle` in the same owned file. Update existing FolderWatchServiceTests constructor/setup to drive the runtime; preserve all unchanged/edit/source-count assertions and add deletion, directory rename and overflow. Portable fake events run on macOS; actual recursive FileSystemWatcher behavior also runs on Windows CI.

- [ ] **Step 3 — connect the app graph and publication.** `App.xaml.cs:105,117,126,146,173,226` registers one runtime/admission, attaches the retained NoteIndexer callback to durable generation scheduling, starts after store construction and legacy backfill, and joins shutdown on MainWindow.Closed handler before disposal; guard one-time initialization. Keep view lifetime out of runtime lifetime. Production worker kicks dispatch durable jobs; legacy constructor remains for tests but is not registered in DI. Route production loose PDF/Office/text through bounded extractors and the fenced loose publication helper, propagate CancellationToken, and keep URL re-crawl injected web extractor path. No SqliteConnection escapes its gate and no await occurs while holding it.

ChatEngine's Task<ChatMessage> send/regenerate lifetime acquires `admission.BeginChat()` before retrieval and uses `try/finally { admission.EndChat(token); }`, including cancellation of the provider stream, retrieval failure, and callback exceptions. Every background batch awaits admission; question embedding does not. Register memory pressure sampling with an injectable `Func<bool>` whose production predicate uses `GC.GetGCMemoryInfo()` and returns true at memory load ≥90% of HighMemoryLoadThresholdBytes (when threshold is positive); clearing resumes waiters. Check every second through the owned runtime timer, and account for already reserved bytes.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~FolderIntegrationTests|FullyQualifiedName~FolderWatchServiceTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
# Windows CI only:
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
git add windows/src/AINotebook.Core/Ingestion/FolderIngestionRuntime.cs windows/src/AINotebook.Core/Storage/NotebookStore.IngestionPublication.cs windows/src/AINotebook.Core/Ingestion/IngestionService.cs windows/src/AINotebook.Core/Ingestion/FolderWatchService.cs windows/src/AINotebook.Core/Rag/Embedder.cs windows/src/AINotebook.Core/Rag/EmbeddingWorker.cs windows/src/AINotebook.Core/Rag/ChatEngine.cs windows/src/AINotebook.App/App.xaml.cs windows/tests/AINotebook.Core.Tests/Ingestion/FolderIntegrationTests.cs windows/tests/AINotebook.Core.Tests/Ingestion/FolderWatchServiceTests.cs
git commit -m "feat(win-ingestion): connect durable runtime and recursive watches" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight new integration Facts and all migrated watcher tests pass; both Core suites green. Windows CI must compile the App and pass App tests before merge.

## UI text contract (Tasks 18–21)

Task18 owns Swift `Sources/AINotebookCore/Localization.swift` (Key enum at line2, EN switch at264 and CS switch in the same file). Task19 owns Windows `Services/StringKey.cs` and **both** `Strings/en-US/Resources.resw` and `Strings/cs-CZ/Resources.resw`. `LocalizedStrings.Get(StringKey)` already maps PascalCase to camelCase (`Services/LocalizedStrings.cs:59`); do not edit that mapping. Each table row is one new key, with PascalCase enum spelling on Windows and exactly the camelCase resource spelling below. Task1 puts this table into `ingestion-ui-v1.json` localization cases so both platforms check identical semantic strings. All keys land before scope/reindex UI branches.

| Key | English | Czech |
|---|---|---|
| addFolderButton | Add folder… | Přidat složku… |
| folderLastFullScan | Last full scan | Poslední úplný sken |
| folderNeverScanned | Never scanned | Dosud neskenováno |
| folderWatchEnabled | Watch for changes | Sledovat změny |
| folderScanNow | Scan now | Skenovat teď |
| folderVerifyAll | Verify all | Ověřit vše |
| folderRulesTitle | Folder rules | Pravidla složky |
| folderIncludeExtensions | Include extensions | Zahrnuté přípony |
| folderIgnoreGlobs | Ignore patterns (one per line) | Ignorované vzory (jeden na řádek) |
| folderMaxFileBytes | Maximum file bytes | Nejvýše bajtů souboru |
| folderMaxOfficeBytes | Maximum expanded Office bytes | Nejvýše rozbalených bajtů Office |
| folderMaxTextScalars | Maximum text characters | Nejvýše znaků textu |
| folderMaxPdfPages | Maximum PDF pages | Nejvýše stran PDF |
| folderMaxChunks | Maximum passages per file | Nejvýše pasáží na soubor |
| folderMaxCells | Maximum spreadsheet cells | Nejvýše buněk tabulky |
| folderEncodingFallback | Text encoding fallback | Náhradní kódování textu |
| folderEncodingNone | Strict UTF only | Pouze striktní UTF |
| folderEncodingCp1250 | Windows-1250 | Windows-1250 |
| folderEncodingUsed | Encoding | Kódování |
| folderRulesInvalid | Check patterns, extensions and positive limits. | Zkontrolujte vzory, přípony a kladné limity. |
| folderRemoveButton | Remove from notebook | Odebrat z notebooku |
| folderRemoveConfirm | Remove this folder from the notebook? | Odebrat tuto složku z notebooku? |
| folderRemoveKeepsFiles | Files on disk will be kept. | Soubory na disku zůstanou zachovány. |
| folderSearchable | Searchable | Prohledatelné |
| folderNotSearchable | Not yet searchable | Dosud neprohledatelné |
| folderCurrent | Current | Aktuální |
| folderRefreshPending | Refresh pending | Čeká na aktualizaci |
| folderRefreshError | Refresh failed | Aktualizace selhala |
| folderSkipped | Skipped | Přeskočené |
| folderMissing | Missing | Chybějící |
| folderUnavailable | Unavailable | Nedostupné |
| folderAtLeast | At least | Alespoň |
| folderOverlapError | This folder overlaps a folder already in this notebook. | Tato složka se překrývá se složkou již přidanou do notebooku. |
| folderReadError | The folder or file could not be read. | Složku nebo soubor se nepodařilo přečíst. |
| folderLimitError | The extraction limit was exceeded. | Byl překročen limit extrakce. |
| folderEncodingError | The text encoding is not supported. | Kódování textu není podporováno. |
| folderDocumentError | The document is damaged or unsupported. | Dokument je poškozený nebo nepodporovaný. |
| scopeWholeNotebook | Whole notebook | Celý notebook |
| scopeSelection | Selected items | Vybrané položky |
| scopeFolders | Folders | Složky |
| scopeSourceSets | Source sets | Sady zdrojů |
| scopeSources | Individual sources | Jednotlivé zdroje |
| scopeEmpty | No sources selected | Nejsou vybrány žádné zdroje |
| reindexButton | Re-index | Přeindexovat |
| reindexProgress | Re-index progress | Průběh přeindexování |
| reindexDiscovering | Preparing the new index | Připravuje se nový index |
| reindexPausedForChat | Background indexing paused for chat | Indexování na pozadí je pozastaveno kvůli chatu |
| reindexFailed | Re-indexing failed; existing search remains available. | Přeindexování selhalo; stávající vyhledávání zůstává dostupné. |
| reindexDualSpaceNote | The existing index stays available while the new index is built. Temporary extra disk space is required. | Stávající index zůstává dostupný během vytváření nového indexu. Dočasně je potřeba více místa na disku. |
| reindexDiscard | Discard new index | Zahodit nový index |
| reindexRetry | Retry re-indexing | Zkusit přeindexování znovu |

There are **51 new keys**. Existing cancel/save keys are reused. Labels and integer counts are separate accessible text elements (`Searchable: 3` / `Prohledatelné: 3`); dates use the selected UI locale, not frozen strings. Progress is label plus `done / total` plus a separately labeled excluded count; do not invent a percentage with a zero denominator. This avoids different `%@`/`{0}` formatting contracts. Coverage displays corpus and freshness on separate lines; never add searchable+refreshError into a total. `isLowerBound` prepends At least to the inventory total, including an empty partial folder.

## Task 18: [Swift-UI] Persisted folder rows, picker/drop, rules and localization

**Depends on:** 16; WP2 Swift localization/Settings work must be merged before branching. **Parallel with:** 19 and Windows lane. Task20 follows because it consumes these keys and the runtime holder.

**Files:** `Sources/AINotebookApp/{SourceListView.swift,FolderSourcesModel.swift,FolderRulesSheet.swift,FolderWatchController.swift}`; `Sources/AINotebookCore/Localization.swift`; `Tests/AINotebookCoreTests/FolderLocalizationTests.swift`. FolderWatchController is sequential ownership after Task16, never parallel.

**Interfaces — Consumes:** Swift runtime `addFolder/scanNow/setWatching/removeFolder`, scanner `applyRules(folderId:rules:now:)`, store `folders(notebookId:) throws -> [FolderSource]`, `coverage(notebookId:scope:) throws -> CoverageSnapshot`; C# `AddFolderAsync/ScanNowAsync/SetWatchingAsync/RemoveFolderAsync`, `ApplyRulesAsync`, `Folders(long)`, `Coverage(long,RetrievalScope)`. **Produces:** `@MainActor final class FolderSourcesModel: ObservableObject` with `@Published private(set) var rows:[FolderRow]`, `@Published var errorKey:AppText.Key?`, `reload(notebookId:Int64) async`, `add(url:URL,notebookId:Int64) async`, `scan(id:Int64,verifyAll:Bool) async`, `setWatching(id:Int64,enabled:Bool) async`, `remove(id:Int64) async`. FolderRow has `folder:FolderSource, coverage:CoverageSnapshot`; identity is folder.id. C# view-model counterpart is Task19 `FolderRows` and command methods below; Core semantics come exclusively from the consumed APIs.

- [ ] **Step 1 — localization red test.**

```swift
import XCTest
@testable import AINotebookCore
final class FolderLocalizationTests: XCTestCase {
    func testFolderAndScopeCopy() {
        let en=AppText(language:.english), cs=AppText(language:.czech)
        XCTAssertEqual(en.string(.addFolderButton),"Add folder…")
        XCTAssertEqual(cs.string(.addFolderButton),"Přidat složku…")
        XCTAssertEqual(en.string(.scopeEmpty),"No sources selected")
        XCTAssertEqual(cs.string(.folderRefreshError),"Aktualizace selhala")
        XCTAssertEqual(en.string(.folderRemoveKeepsFiles),"Files on disk will be kept.")
    }
    func testAllSharedFolderStrings() throws {
        let f=try SharedFixtures.json("contracts/ingestion-ui-v1.json")
        let rows=(f["cases"] as! [[String:Any]]).filter { $0["operation"] as? String == "localization" }
        XCTAssertEqual(rows.count,51)
        let keys=Dictionary(uniqueKeysWithValues:AppText.Key.allCases.map { (String(describing:$0),$0) })
        for row in rows {
            let i=row["input"] as! [String:Any], e=row["expected"] as! [String:String]
            let key=try XCTUnwrap(keys[i["key"] as! String])
            XCTAssertEqual(AppText(language:.english).string(key),e["en"])
            XCTAssertEqual(AppText(language:.czech).string(key),e["cs"])
        }
    }
}
```

Run `swift test --filter FolderLocalizationTests` → FAIL on missing keys. Add all 51 enum cases and both switch translations exactly; preserve existing strings and tests, including `reembedButton` (`LocalizationTests.swift:95`).

- [ ] **Step 2 — bind folder management.** Replace per-view state `SourceListView.swift:28` and watch-button block `:344–383` with the app environment holder. Remove its now-unused compatibility methods from FolderWatchController. Use `FolderSourcesModel` for presentation only; store/runtime remain process-wide. List persisted folders above loose files, with folder-contained sources grouped beneath their folder. Folder row binds title, all corpus/freshness/availability counts, lastFullScanAt or Never scanned, watch Toggle and Scan now/Verify all/Rules/Remove actions. Keep a folder visible if it has no eligible sources, all files are skipped, or the root is unavailable. Empty state at `:91` means no folder rows **and** no loose sources.

Add folder button opens NSOpenPanel on MainActor with canChooseDirectories=true, canChooseFiles=false, allowsMultipleSelection=false. On success call model.add; overlap error maps to folderOverlapError. Drop handler at `:152,315` checks URL resource isDirectory before file ingestion, resolves selected root aliases through Core, and calls add for directories. File URLs continue ingestFile; nonfile URLs continue ingestURL. A failed item does not discard successful siblings; surface its localized error and continue. Existing E2 recrawl action at `:333` stays visible and functional. Show recorded source.encoding in the source detail row using folderEncodingUsed.

- [ ] **Step 3 — rules sheet and UI lifecycle.** `FolderRulesSheet(folder:FolderSource,onSave:@escaping (FolderRules) async throws -> Void)` binds comma-separated include extensions, newline ignore patterns, six positive integer limit fields, and cp1250/none picker. Parse into a temporary FolderRules, compile every glob with the actual volume policy/tables, validate process ceilings, and disable Save when invalid with folderRulesInvalid. Saving awaits scanner.applyRules, closes on success, and refreshes the rows; errors keep the sheet open. Cancellation changes no store row. Use existing .save/.cancel keys. Remove action presents folderRemoveConfirm + folderRemoveKeepsFiles, then runtime.removeFolder; no disk operation.

Subscribe to `.folderIngestionDidChange` for this store and notebook while the view is visible, coalesce presentation reloads and cancel that subscription on disappearance. Polling progress can stop with the view; ingestion/watch state cannot. Keep the selected notebook ID as a captured reload token so an old asynchronous load cannot overwrite the newly selected notebook's rows. Scope counts use `.selection(sourceIds:[],folderIds:[id])` once per row snapshot. On language changes recreate presentation labels from AppText; raw DB error codes never become unexplained English text.

- [ ] **Step 4 — verification and commit.**

```bash
swift test --filter FolderLocalizationTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookApp/SourceListView.swift Sources/AINotebookApp/FolderSourcesModel.swift Sources/AINotebookApp/FolderRulesSheet.swift Sources/AINotebookApp/FolderWatchController.swift Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/FolderLocalizationTests.swift
git commit -m "feat(ui): Swift persisted folder management and bilingual rules" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: two localization tests, all 51 shared translations, and both Core suites green. **Claude manual checklist:** EN and CS; add a folder and an overlapping child; drop mixed folder/file/URL; nested add/edit/rename/delete; ignored-only empty folder remains visible; watch off then Scan now; Verify all detects changed same-stat bytes; invalid glob/limit keeps Rules open; change include/encoding revokes/reprocesses immediately; restart restores enabled folders across notebooks; disconnect/remount leaves unavailable without false missing; remove preserves file bytes; URL re-crawl still updates one source. Record the observed app build/commit and checklist outcome.

## Task 19: [Win-UI] Persisted folder rows, picker/drop, rules and resource parity

**Depends on:** 17; WP2 Windows localization/Settings work merged. **Parallel with:** 18 and Swift lane.

**Files:** `windows/src/AINotebook.App/ViewModels/SourcesViewModel.cs`; `windows/src/AINotebook.App/Views/{SourceListPage.xaml,SourceListPage.xaml.cs,FolderRulesDialog.xaml,FolderRulesDialog.xaml.cs}`; `windows/src/AINotebook.App/Services/StringKey.cs`; `windows/src/AINotebook.App/Strings/{en-US,cs-CZ}/Resources.resw`; `windows/tests/AINotebook.App.Tests/{FolderSourcesTests.cs,LocalizedStringsTests.cs}`.

**Interfaces — Consumes:** C# runtime, scanner and store methods listed in Task18; the Swift methods there specify parity. **Produces:** `SourcesViewModel.FolderRows:ObservableCollection<FolderRowViewModel>`, `Task AddFolderAsync(string path)`, `Task ScanFolderAsync(long id,bool verifyAll)`, `Task SetFolderWatchingAsync(long id,bool enabled)`, `Task RemoveFolderAsync(long id)`, `Task SaveFolderRulesAsync(long id,FolderRules rules)`. Define FolderRowViewModel in the owned SourcesViewModel file, with `FolderSource Folder`, `CoverageSnapshot Coverage`, `bool WatchEnabled`, and computed localized label/count properties. Dialog constructor `FolderRulesDialog(FolderSource folder,Func<FolderRules,Task> save,ILocalizedStrings strings)`; Swift peer is FolderRulesSheet above.

- [ ] **Step 1 — red resource and view-binding test.** Test actual resw XML without initializing a WinUI window:

```csharp
using System.Xml.Linq;
using AINotebook.App.Services;
using Xunit;
public sealed class FolderSourcesTests {
    [Theory]
    [InlineData("en.resw","Add folder…","No sources selected")]
    [InlineData("cs.resw","Přidat složku…","Nejsou vybrány žádné zdroje")]
    public void FolderResourcesExist(string path,string add,string empty) {
        var rows=XDocument.Load(path).Root!.Elements("data")
            .ToDictionary(e=>(string)e.Attribute("name")!,e=>(string)e.Element("value")!);
        Assert.Equal(add,rows["addFolderButton"]);
        Assert.Equal(empty,rows["scopeEmpty"]);
        Assert.True(Enum.IsDefined(typeof(StringKey),"FolderRefreshError"));
    }
}
```

Run on Windows `dotnet test windows/tests/AINotebook.App.Tests --filter FullyQualifiedName~FolderSourcesTests -c Release -p:Platform=x64` → FAIL on missing resources. Add `AllSharedFolderStrings`, `FolderOnlyNotebookIsNotEmpty`, `RulesRejectUnsupportedGlob`, `FolderRemovalKeepsDisk`, `SourceXamlBindsFolderRows` tests. AllSharedFolderStrings locates `Tests/fixtures` by walking parents from this test file's `[CallerFilePath]`, reads ingestion-ui cases, and compares the same 51 EN/CS values; App project cannot import Core test helper assembly. No new fixture copying/project changes are needed. Pure tests exercise projection/rules without DispatcherQueue; controller integration uses existing Core runtime fixtures. SourceXamlBindsFolderRows loads the repo XAML and asserts FolderRows binding, WatchEnabled TwoWay, and all five action handlers exist. It complements, but does not replace, the Windows build.

- [ ] **Step 2 — resources and view/model.** Add exactly the table's keys to StringKey and both resw files (XML-escape text). Update the existing exact-count assertions in `LocalizedStringsTests.cs:27` to the predecessor branch's verified count +51; preserve set-equality and nonempty assertions. Current planning-base total is239, so without additional predecessor keys the new total is290. Do not replace the guard with “greater than”. No LocalizedStrings.cs change is needed.

Replace SourcesViewModel's single watch boolean/command (`:37,:203`) with persisted FolderRows and runtime dependency. Preserve constructor compatibility until SourceListPage.cs is updated in the same task. Load folder snapshot and source rows off UI; marshal one result onto captured DispatcherQueue. IsEmpty becomes `Sources.Count==0 && FolderRows.Count==0`. Row toggles persist via runtime and rollback displayed value on error. All collection mutations happen on UI dispatcher. Subscribe/unsubscribe store and language updates at page Loaded/Unloaded without stopping runtime.

SourceListPage.xaml adds a folder ListView with `ItemsSource="{x:Bind ViewModel.FolderRows, Mode=OneWay}"`; its template uses `x:DataType="vm:FolderRowViewModel"`, `Text="{x:Bind DisplayName}"`, coverage label fields, and `ToggleSwitch IsOn="{x:Bind WatchEnabled, Mode=TwoWay}"`. Buttons pass `Tag="{x:Bind Folder.Id}"` to `OnScanFolder`, `OnVerifyFolder`, `OnFolderRules`, `OnRemoveFolder`; watch setter dispatches SetFolderWatchingAsync. Actions catch errors into ErrorMessage. Do not keep duplicate old watch buttons at `SourceListPage.xaml:30`.

- [ ] **Step 3 — native picker, drop and dialog.** Reuse FolderPicker at `SourceListPage.xaml.cs:232`; initialize with `InitializeWithWindow.Initialize(picker,WindowNative.GetWindowHandle(App.MainWindow))`, add `"*"` to FileTypeFilter, and on success call AddFolderAsync(path). In drop at `:140`, iterate all IStorageItems, route StorageFolder to AddFolderAsync and StorageFile to IngestFileAsync; unsupported item errors are displayed, not swallowed. Keep the RefreshUrl handler and SourcesViewModel.RefreshUrlAsync action at `:188`, but replace its URL-as-hash override at `:195–196`: read the refreshed published source.ContentHash and pass that SHA-256 while updating LastSyncedAt. Never store the URL string as content hash. Add a regression asserting the returned revision hash survives the UI refresh action.

FolderRulesDialog.xaml binds named controls IncludeExtensionsBox, IgnoreGlobsBox, FileBytesBox, OfficeBytesBox, TextScalarsBox, PdfPagesBox, ChunksBox, CellsBox and EncodingBox to a private draft. EncodingBox holds explicit `cp1250`/`none` tags. Validate on each field change using Core rules/glob validation, set IsPrimaryButtonEnabled and ValidationText; PrimaryButtonClick takes a deferral, cancels closure on failed save, and awaits SaveFolderRulesAsync. Localize Title, PrimaryButtonText, CloseButtonText and labels. Set XamlRoot from caller. Code-behind styles use `Application.Current.Resources["..."]`; never page Resources or package-only APIs. Remove confirmation is a ContentDialog using the two exact remove strings and invokes runtime only after the user chooses Remove.

- [ ] **Step 4 — verification and commit.**

```bash
swift test
dotnet test windows/tests/AINotebook.Core.Tests
# Windows CI only:
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
git add windows/src/AINotebook.App/ViewModels/SourcesViewModel.cs windows/src/AINotebook.App/Views/SourceListPage.xaml windows/src/AINotebook.App/Views/SourceListPage.xaml.cs windows/src/AINotebook.App/Views/FolderRulesDialog.xaml windows/src/AINotebook.App/Views/FolderRulesDialog.xaml.cs windows/src/AINotebook.App/Services/StringKey.cs windows/src/AINotebook.App/Strings/en-US/Resources.resw windows/src/AINotebook.App/Strings/cs-CZ/Resources.resw windows/tests/AINotebook.App.Tests/FolderSourcesTests.cs windows/tests/AINotebook.App.Tests/LocalizedStringsTests.cs
git commit -m "feat(win-ui): persisted folder rows rules picker and bilingual resources" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: two resource Theory rows plus five named Facts pass, every shared UI string checked; both Core suites and Windows App build/tests green. **Windows manual checklist:** EN/CS and keyboard focus; add/drop folders; overlapping root rejects; recursive rename/delete updates counts; unavailable/ignored-only folder remains visible; toggle watch persists across restart; rules reject unsupported syntax; Scan now and Verify all enqueue distinct requested modes; removal preserves disk files; E2 re-crawl retains source ID and updates timestamp.

## Task 20: [Swift-UI] Explicit scopes and generation re-index progress

**Depends on:** 18, 14, WP3 source-set folder membership. **Parallel with:** 21 and downstream Windows work. WP8 integration follows this task and preserves the explicit scope value.

**Files:** `Sources/AINotebookApp/{ChatView.swift,FolderScopeModel.swift,SettingsView.swift,IndexingStatusBadge.swift}`; `Sources/AINotebookCore/{FolderScopeSelection.swift,NotebookStore+FolderScope.swift}`; `Tests/AINotebookCoreTests/FolderScopeTests.swift`.

**Interfaces — Consumes:** existing `RetrievalScope.all/.selection(sourceIds:Set<Int64>,folderIds:Set<Int64>)` (`RetrievalScope.swift:4`), WP3 sourceSetFolders/setSourceSetFolders, current `sourceSetMembers(setId:) throws -> [Int64]` (`NotebookStore+SourceSets.swift:79`); C# `RetrievalScope.All/Selection`, `SourceSetFolders/SetSourceSetFolders`, `SourceSetMembers(long)`. **Produces:** the following pure Core types/API, with C# peers implemented in Task21:

```swift
public struct FolderScopeSelection: Sendable, Equatable {
    public var wholeNotebook: Bool
    public var sourceIds: Set<Int64>
    public var folderIds: Set<Int64>
    public var setIds: Set<Int64>
    public init(wholeNotebook:Bool = true, sourceIds:Set<Int64> = [],
                folderIds:Set<Int64> = [], setIds:Set<Int64> = []) {
        self.wholeNotebook=wholeNotebook; self.sourceIds=sourceIds
        self.folderIds=folderIds; self.setIds=setIds
    }
    public func resolved(setScopes:[Int64:RetrievalScope]) -> RetrievalScope {
        if wholeNotebook { return .all }
        var scopes:[RetrievalScope] = [.selection(sourceIds:sourceIds,folderIds:folderIds)]
        for id in setIds.sorted() {
            // Persisted source sets always represent an explicit selection.
            if let scope=setScopes[id], case .selection = scope { scopes.append(scope) }
        }
        return RetrievalScope.union(scopes)
    }
}
extension NotebookStore {
    public func resolveFolderScope(notebookId:Int64, selection:FolderScopeSelection) throws -> RetrievalScope
}
```

C# exact counterpart: `public sealed record FolderScopeSelection(bool WholeNotebook,IReadOnlySet<long> SourceIds,IReadOnlySet<long> FolderIds,IReadOnlySet<long> SetIds)`; `public RetrievalScope Resolved(IReadOnlyDictionary<long,RetrievalScope> setScopes)`; `public RetrievalScope ResolveFolderScope(long notebookId,FolderScopeSelection selection)`. Copy input sets on construction to prevent mutation after snapshot. Swift App `@MainActor FolderScopeModel` wraps the value with `@Published var selection`, `reload(notebookId:) throws`, `resolveForTurn() throws -> RetrievalScope`. The pure type stays in Core because the existing Swift test target depends only on Core (`Package.swift:50`).

- [ ] **Step 1 — red explicit-empty and dynamic-set tests.**

```swift
import XCTest
@testable import AINotebookCore
final class FolderScopeTests: XCTestCase {
    func testEmptySelectionNeverBecomesAll() {
        let s=FolderScopeSelection(wholeNotebook:false)
        XCTAssertEqual(s.resolved(setScopes:[:]),.selection(sourceIds:[],folderIds:[]))
        XCTAssertEqual(FolderScopeSelection().resolved(setScopes:[:]),.all)
    }
    func testResolveSetsEachTurnWithoutExpandingFolders() {
        let s=FolderScopeSelection(wholeNotebook:false,sourceIds:[1],folderIds:[8],setIds:[9])
        XCTAssertEqual(s.resolved(setScopes:[9:.selection(sourceIds:[2],folderIds:[7])]),
            .selection(sourceIds:[1,2],folderIds:[7,8]))
        XCTAssertEqual(s.resolved(setScopes:[9:.selection(sourceIds:[3],folderIds:[10])]),
            .selection(sourceIds:[1,3],folderIds:[8,10]))
        XCTAssertEqual(s.resolved(setScopes:[:]),.selection(sourceIds:[1],folderIds:[8]))
    }
    func testAllSharedScopeCases() throws {
        let root=try SharedFixtures.json("contracts/ingestion-ui-v1.json")
        let cases=(root["cases"] as! [[String:Any]]).filter { $0["operation"] as? String == "scope" }
        XCTAssertFalse(cases.isEmpty)
        func ids(_ x:Any?) -> Set<Int64> { Set((x as! [NSNumber]).map(\.int64Value)) }
        for c in cases {
            let i=c["input"] as! [String:Any], e=c["expected"] as! [String:Any]
            let s=FolderScopeSelection(wholeNotebook:i["wholeNotebook"] as! Bool,
                sourceIds:ids(i["sourceIds"]),folderIds:ids(i["folderIds"]),setIds:ids(i["setIds"]))
            var sets:[Int64:RetrievalScope]=[:]
            for row in i["members"] as! [[String:Any]] {
                sets[(row["setId"] as! NSNumber).int64Value] = .selection(
                    sourceIds:ids(row["sourceIds"]),folderIds:ids(row["folderIds"]))
            }
            let expected:RetrievalScope = e["kind"] as! String == "all" ? .all :
                .selection(sourceIds:ids(e["sourceIds"]),folderIds:ids(e["folderIds"]))
            XCTAssertEqual(s.resolved(setScopes:sets),expected,c["name"] as! String)
        }
    }
}
```

Run `swift test --filter FolderScopeTests` → missing FolderScopeSelection FAIL. Add `testStoreRejectsCrossNotebookIDs` and `testRemovedSelectedFolderStaysEmpty` with real store fixtures before writing the store resolver. Resolve in one read transaction: an ID that exists in another notebook throws notebookMismatch, a deleted/nonexistent ID is dropped, and selected IDs must belong to the notebook; selected sets contribute their **current** explicit source IDs and folder IDs. Keep folder IDs as folder IDs for WP5's per-turn membership query. Do not catch SQL errors by returning `.all`.

- [ ] **Step 2 — scope picker and send integration.** Replace ChatView.swift:48–54's effectiveSourceIds count shortcut with FolderScopeModel. Popover at `:150` contains explicit whole notebook / selected items radio controls, folder checkboxes, saved-set checkboxes and individual-source checkboxes. Selecting any checkbox switches to selected mode; selecting all visible rows does not switch back to whole notebook. Saved sets remain IDs in selection; fetch current membership immediately before each new send/regenerate, using resolveFolderScope. Scope toolbar must be enabled even when source list is empty, show scopeEmpty for empty selection, and retain that empty selection after a folder/set is removed. Display published sources with refresh failures; do not filter solely on status ready. Reset selection to whole notebook only when deliberately switching notebook, never on a reload.

At send (`ChatView.swift:553`) and regenerate (`:510`), use the typed methods produced by Task16/17 below. These match WP8 plan:1127–1140 so WP8 can replace their internals after WP6 without another UI API migration. Task16/17 own these Core edits, not this UI task:

```swift
public func send(sessionId:Int64, notebookId:Int64, userText:String,
    scope:RetrievalScope, mode:String = "answer", currentNoteContent:String? = nil,
    useWebSearch:Bool = false, model:String? = nil, instructionsOverride:String? = nil,
    onToken:@escaping @Sendable(String)->Void,
    onRetry:@escaping @Sendable()->Void = {}) async throws -> ChatMessage
public func regenerate(sessionId:Int64, notebookId:Int64, scope:RetrievalScope,
    currentNoteContent:String? = nil, model:String? = nil,
    onToken:@escaping @Sendable(String)->Void,
    onRetry:@escaping @Sendable()->Void = {}) async throws -> ChatMessage
```

```csharp
public Task<ChatMessage> SendAsync(long sessionId,long notebookId,string userText,
    RetrievalScope scope,string mode="answer",string? currentNoteContent=null,
    IReadOnlyList<WebSearchResult>? webResults=null,string? model=null,
    string? instructionsOverride=null,Action<string>? onToken=null,
    Action? onRetry=null,CancellationToken ct=default);
```

Before WP8, mode accepts only `answer`; the existing callback-based send pipeline returns ChatMessage (`ChatEngine.swift:47`, `Rag/ChatEngine.cs:31`), not an async iterator. Add internal store helper `chatSourceIds(notebookId:Int64,scope:RetrievalScope) throws -> Set<Int64>?` / `IReadOnlySet<long>? ChatSourceIds(long notebookId,RetrievalScope scope)` in `NotebookStore+IngestionPublication.swift` / `Storage/NotebookStore.IngestionPublication.cs`, owned by Tasks16/17. Keep the C# partial in namespace `AINotebook.Core.Storage`; `Rag/ChatEngine.cs` has a file-scoped Rag namespace and cannot contain this partial. One read query resolves explicit/folder IDs with bound notebook+present+eligible predicates: `.all` returns nil; explicit selection returns its materialized set, including empty. For empty set, set retrieval hits to empty without calling legacy Retriever; nonempty uses its existing sourceIds argument. This bridge evaluates live folder membership each turn and preserves WP3's revision filtering. WP5/WP8 may replace the bridge with typed retrieval, preserving these semantics. Do not convert an empty typed selection into the old overload's empty-means-all convention. Existing personas that apply source sets select the set ID; save-source-set persists both selected source IDs and folder IDs via WP3 APIs in one store write helper in this task's extension, `saveFolderScopeSet(notebookId:Int64,name:String,selection:FolderScopeSelection) throws -> SourceSet` / C# `SourceSet SaveFolderScopeSet(long,string,FolderScopeSelection)`. Resolve selected named sets first, and reject whole-notebook save rather than materializing all present files as a misleading permanent scope.

- [ ] **Step 3 — re-index and progress.** Replace SettingsView.swift:408's old direct deleteAllEmbeddings action with runtime coordinator reindex request for each notebook using the captured selected embedder. Use the dimension-bootstrap request when unknown; never guess dimensions or silently choose another provider. Show a progress row for each notebook's persisted generation/job: preparing before dimensions are known, done/total plus exclusions during build, pausedForChat text when appropriate, failed with Retry, and Discard for building work. Retry creates a new job after exhaustion; Discard cancels building only. Present reindexDualSpaceNote next to the action, not a second permission flow. Keep WP2 conversion notice and embedding-capable-only picker intact.

IndexingStatusBadge.swift:40 stops using legacy unembeddedCount as a completeness signal; read generationProgress and queue state. With no active index show preparing/failed/lexical status accurately; no green Complete merely because no vector rows exist. UI refresh subscribes to `.folderIngestionDidChange` for this store/notebook and polls once per second while visible for live chat pause state; cancellation stops only presentation polling. Old active remains usable until fenced activation; failed reindex does not clear it.

- [ ] **Step 4 — green, manual checks and commit.**

```bash
swift test --filter FolderScopeTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookApp/ChatView.swift Sources/AINotebookApp/FolderScopeModel.swift Sources/AINotebookApp/SettingsView.swift Sources/AINotebookApp/IndexingStatusBadge.swift Sources/AINotebookCore/FolderScopeSelection.swift Sources/AINotebookCore/NotebookStore+FolderScope.swift Tests/AINotebookCoreTests/FolderScopeTests.swift
git commit -m "feat(ui): explicit folder scopes and durable re-index progress" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: five scope tests and all shared scope cases green, both Core suites pass. **Claude manual checklist:** EN/CS; whole notebook works; empty selected mode returns no evidence; source+folder+set union deduplicates; a newly ingested folder member appears next turn; changed set membership applies next turn; removing selected folder retains empty selection; persona/set and regenerate use same typed scope; reindex while chatting pauses only new background batches; old active answers until atomic switch; restart resumes progress; failed provider/retry/discard retain old active; dual-space note visible; embedding picker excludes chat-only providers.

## Task 21: [Win-UI] Explicit scopes, source sets and re-index progress

**Depends on:** 19, 15, WP3 source-set folder membership. **Parallel with:** 20 and Swift lane. WP8 chat integration follows this task.

**Files:** `windows/src/AINotebook.App/ViewModels/{ChatViewModel.cs,SettingsViewModel.cs,FolderScopeModel.cs}`; `windows/src/AINotebook.App/Views/{ChatPage.xaml,ChatPage.xaml.cs,SettingsDialog.xaml,SettingsDialog.xaml.cs,IndexingStatusBadge.xaml,IndexingStatusBadge.xaml.cs}`; `windows/src/AINotebook.Core/Rag/FolderScopeSelection.cs`; `windows/src/AINotebook.Core/Storage/NotebookStore.FolderScope.cs`; `windows/tests/AINotebook.Core.Tests/Ingestion/FolderScopeTests.cs`; `windows/tests/AINotebook.App.Tests/FolderScopeBindingTests.cs`.

**Interfaces — Consumes:** C# typed RetrievalScope (`Rag/RetrievalScope.cs:9`), store source/folder/set membership, FolderIndexCoordinator and persisted progress. Swift exact peers are defined in Task20. **Produces:** C# FolderScopeSelection, ResolveFolderScope and SaveFolderScopeSet signatures in Task20, plus `FolderScopeModel.Selection:FolderScopeSelection`, `void Reload(long notebookId)`, `RetrievalScope ResolveForTurn()`. ChatViewModel exposes `FolderScopeModel Scope`, SettingsViewModel exposes `ObservableCollection<GenerationProgressRow> IndexBuilds`, `Task ReindexAsync()`, `Task DiscardIndexAsync(long jobId)`, `Task RetryIndexAsync(long notebookId)`; Swift peer is the FolderScopeModel + Settings presentation above. Define `GenerationProgressRow` in this owned SettingsViewModel.cs as `record GenerationProgressRow(long NotebookId,string NotebookName,long? GenerationId,long? JobId,int Done,int Total,int Excluded,bool Preparing,bool Failed,bool PausedForChat,bool HasActive,string? ErrorCode)`. Bind actions by JobId; a preparing row has no generation ID.

- [ ] **Step 1 — red pure scope tests on macOS or Windows.**

```csharp
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;
public sealed class FolderScopeTests {
    [Fact] public void EmptySelectionNeverBecomesAll() {
        var s=new FolderScopeSelection(false,new HashSet<long>(),new HashSet<long>(),new HashSet<long>());
        Assert.True(s.Resolved(new Dictionary<long,RetrievalScope>()).IsEmptySelection);
        Assert.IsType<RetrievalScope.All>((s with { WholeNotebook=true }).Resolved(new Dictionary<long,RetrievalScope>()));
    }
    [Fact] public void SetsResolveEachTurnWithoutExpandingFolders() {
        var s=new FolderScopeSelection(false,new HashSet<long>{1},new HashSet<long>{8},new HashSet<long>{9});
        var first=s.Resolved(new Dictionary<long,RetrievalScope>{[9]=new RetrievalScope.Selection(new HashSet<long>{2},new HashSet<long>{7})});
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long>{1,2},new HashSet<long>{7,8}),first);
        var second=s.Resolved(new Dictionary<long,RetrievalScope>{[9]=new RetrievalScope.Selection(new HashSet<long>{3},new HashSet<long>{10})});
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long>{1,3},new HashSet<long>{8,10}),second);
    }
    [Fact] public void AllSharedScopeCases() {
        var cases=SharedFixtures.Json("contracts/ingestion-ui-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c=>c.GetProperty("operation").GetString()=="scope").ToArray();
        Assert.NotEmpty(cases);
        static HashSet<long> Ids(System.Text.Json.JsonElement e,string key) =>
            e.GetProperty(key).EnumerateArray().Select(x=>x.GetInt64()).ToHashSet();
        foreach(var c in cases) {
            var i=c.GetProperty("input"); var e=c.GetProperty("expected");
            var s=new FolderScopeSelection(i.GetProperty("wholeNotebook").GetBoolean(),Ids(i,"sourceIds"),Ids(i,"folderIds"),Ids(i,"setIds"));
            var sets=i.GetProperty("members").EnumerateArray().ToDictionary(x=>x.GetProperty("setId").GetInt64(),
                x=>(RetrievalScope)new RetrievalScope.Selection(Ids(x,"sourceIds"),Ids(x,"folderIds")));
            RetrievalScope expected=e.GetProperty("kind").GetString()=="all" ? new RetrievalScope.All() :
                new RetrievalScope.Selection(Ids(e,"sourceIds"),Ids(e,"folderIds"));
            Assert.Equal(expected,s.Resolved(sets));
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderScopeTests` → FAIL on missing type. Add StoreRejectsCrossNotebookIDs and RemovedSelectedFolderStaysEmpty before locked resolver implementation.

- [ ] **Step 2 — implement the Core reducer and SQL snapshot.**

```csharp
public RetrievalScope Resolved(IReadOnlyDictionary<long,RetrievalScope> setScopes) {
    if(WholeNotebook) return new RetrievalScope.All();
    var scopes=new List<RetrievalScope>{new RetrievalScope.Selection(SourceIds,FolderIds)};
    foreach(long id in SetIds.Order())
        if(setScopes.TryGetValue(id,out var scope) && scope is RetrievalScope.Selection) scopes.Add(scope);
    return RetrievalScope.Union(scopes);
}
```

ResolveFolderScope takes `_gate`, opens one read transaction and rejects an existing foreign-notebook ID with notebookMismatch, drops deleted IDs, and materializes only notebook-owned IDs/set memberships; folder IDs remain unexpanded. SaveFolderScopeSet validates the same notebook and writes set/source/folder memberships in one transaction. No source-set change can partially persist. A removed selection stays empty. This file uses a `NotebookStore` partial in the Storage namespace, separate from the Rag type file.

- [ ] **Step 3 — scope/re-index bindings.** In ChatViewModel.cs:268 remove empty/count-based EffectiveSourceIds. At send `:445`, regenerate and persona application use `Scope.ResolveForTurn()` and the typed Core overload; add explicit whole-notebook mode rather than source-checkbox count inference. `ChatPage.xaml:134` flyout adds WholeNotebookRadio, SelectedItemsRadio, FolderScopeList, SetScopeList, SourceScopeList and EmptyScopeText. Bind lists OneWay, check state TwoWay, and mode to Scope.Selection via model setters. Change SourceSets behavior to hold selected set IDs and query on every turn. Error loading membership surfaces ErrorMessage, never silently `.All`.

SettingsViewModel.cs:248 requests builds through FolderIndexCoordinator; SettingsDialog.xaml:79 binds IndexBuilds with progress/paused/failure state, Retry/Discard commands and reindexDualSpaceNote. Update direct constructor composition in SettingsDialog.xaml.cs:28 to supply the existing runtime/coordinator, without changing App.xaml.cs (Task17 owns that registration). IndexingStatusBadge.xaml.cs:51 reads persisted generation/queue progress rather than UnembeddedCount. DispatcherQueue marshals observable changes; Unloaded unsubscribes UI listeners only. Code-behind uses Application.Current.Resources and LocalizedStrings, and all text keys already exist from Task19. Keep WP2 embedding-capability filtering and one-time conversion notice.

Add App tests in FolderScopeBindingTests.cs that parse the actual XAML paths (CallerFilePath-based repo discovery): assert four scope groups, mode control names and TwoWay check bindings; assert Settings dialog binds IndexBuilds and has Retry/Discard actions and dual-space text key. Add a pure FolderScopeModel test with an injected in-memory store asserting resolved scope after set mutation. These tests do not pretend to automate WinUI rendering; CI compilation validates x:Bind names/types.

- [ ] **Step 4 — verification and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~FolderScopeTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
# Windows CI only:
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
git add windows/src/AINotebook.App/ViewModels/ChatViewModel.cs windows/src/AINotebook.App/ViewModels/SettingsViewModel.cs windows/src/AINotebook.App/ViewModels/FolderScopeModel.cs windows/src/AINotebook.App/Views/ChatPage.xaml windows/src/AINotebook.App/Views/ChatPage.xaml.cs windows/src/AINotebook.App/Views/SettingsDialog.xaml windows/src/AINotebook.App/Views/SettingsDialog.xaml.cs windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml.cs windows/src/AINotebook.Core/Rag/FolderScopeSelection.cs windows/src/AINotebook.Core/Storage/NotebookStore.FolderScope.cs windows/tests/AINotebook.Core.Tests/Ingestion/FolderScopeTests.cs windows/tests/AINotebook.App.Tests/FolderScopeBindingTests.cs
git commit -m "feat(win-ui): explicit folder scopes and durable re-index progress" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: five Core scope Facts plus shared scope cases pass; App binding/model tests and Windows build green; both complete Core suites pass. **Windows manual checklist:** EN/CS; selected-empty vs all; folders/sets/sources union; new member discovered next turn; removed folder does not widen scope; regenerate/persona respect scope; restart during rebuild; chat continues on active generation; background resumes after success/error/cancel; provider error and retry retain active evidence; discard leaves active untouched; dual-space note and exact counts visible.

## WP gate

Run from the repository root after every task has landed, using a clean worktree. This plan adds no implementation now; the commands below gate its later execution.

```bash
python3 -B tools/contracts/gen_fixtures.py --check
python3 -B tools/contracts/gen_ingestion_fixtures.py --check
python3 -B -m unittest discover -s tools/contracts -p test_ingestion_fixtures.py -v
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git diff --check
git status --short
# Windows CI runner only:
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
```

Gate criteria:

- All shared fixture cases are dispatched on both Core platforms; no unknown operation is ignored. Golden scalar text/spans, encoding labels, cell markers, integer language shares, job projections, coverage dimensions and scopes agree. Existing 53 glob and 21 transition cases remain unchanged and green.
- Both complete Core suites have zero failures and no newly skipped tests. Record actual counts at each task's base and commit; do not add claimed future test counts to a historical baseline. This planning worktree baseline is **Swift 381 / .NET 459**, both green on 2026-10-09. The plan-only commit must leave those counts unchanged.
- Two file-backed store connections cannot claim the same job. Attempt5 exhaustion is terminal; stale renewal/failure/publication/batch/activation produces no data changes. Crash/restart, retry, cancellation and rule changes retain old published evidence. Root outage never marks absent files missing; partial scans mark only completed subtrees.
- Native Windows CI executes reparse/junction/handle tests; Swift native symlink tests pass. Watchers resume all enabled folders after restart, debounce at500ms with5s cap, retain one trailing rescan, and recover from overflow/deletion/rename. Worker extraction concurrency is≤2 and pressure blocks new reservations. Chat query embedding remains unblocked.
- PDF/DOCX/PPTX/XLSX/text flow through canonical v1 + scalar chunker2; no production fallback to sharedStrings-only Excel. ZIP/cell/scalar/chunk/page bounds fail before accumulation; document the unavoidable single-page PDF-library allocation in measured peak-memory results rather than claiming a hard allocator cap. Descriptors make no LLM call.
- New generations preserve active/pinned vectors, capture endpoint/model/formats, discover unknown dimensions from a real batch, and activate only with reconciled done/excluded manifests under a live fence. Failed or discarded builds keep active search available. Empty corpus does not activate a misleading empty vector generation.
- Claude's macOS checklist and Windows CI build/App tests pass; Windows manual checklist is recorded before release. Folder rows remain visible for partial/empty/unavailable folders, source encoding is visible, UI strings are EN/CS, empty scope yields no evidence, and URL re-crawl E2 still works.
- Existing privacy-grep CI passes (`.github/workflows/core-ci.yml`); new networking remains only in Providers. No VERSION/constants/shipped migration changes, no user-file deletion, no Package.Current/ApplicationData use. Every task commit contains the required coauthor trailer and only its listed paths.

**Claude review before implementation:** approve the six WP3 handoffs above (nullable retry/state fix, revision_pages, coverage correction ownership, options/bootstrap target, rootFileId, refresh retry status), captured embedding-session identity format, the fresh per-turn WP5 eligibility snapshot/notification handoff, and the proposed 1,000,000-cell / 512 MiB admission ceilings. Review these together with WP3/WP5/WP8 hydration/publication boundaries before merging their schema/API tasks. PDF page allocation remains a library limitation to measure. These are explicit integration decisions; workers must not silently invent a migration or change the frozen contract to unblock themselves.
