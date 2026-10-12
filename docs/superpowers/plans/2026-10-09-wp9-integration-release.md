# WP9 — Integration and 0.15.0 Release Implementation Plan

> **For independent Codex workers:** This is an implementation plan, not an implementation. Execute each numbered task in its own worktree, branched from its merged dependencies. Touch only that task's Files. Do not invoke skills or read `~/.claude/`, `~/.agents/`, `.claude/skills/`, or `agents/`. Run the red step before implementing, then the focused tests and the full affected suite. Claude owns integration and the approval-dependent PR, merge and tag.

**Goal:** Prove the complete v18 upgrade → multilingual folder ingestion → scoped context pack → persisted citation → restart workflow on both platforms, add a Windows executable startup smoke, record native UI verification, and prepare one evidence-backed 0.15.0 release.

**Architecture:** A shared release fixture fixes inputs and observable outcomes. Two platform lanes use real file-backed stores, native filesystem adapters, extractors, detector, durable queue, generation coordinator, retriever and ChatEngine. Only embeddings, chat transport, watches and scheduling are controlled test doubles. Tests capture the prepared request at the provider boundary, never supply a fabricated pack or seeded v19 evidence. A separate Windows task exercises the actual unpackaged executable with an isolated temporary profile. Documentation, verification records and the final version bump follow the platform work.

**Tech Stack:** Swift 6/XCTest/Foundation/GRDB; .NET 10/xUnit/Microsoft.Data.Sqlite/Dapper; WinUI 3; Python 3 standard library; PowerShell/GitHub Actions. Existing packages only.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md:291` (§11 WP9) and `:295` (§12); `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md:51` (release gates); `docs/contracts/folder-rag-v1.md`; `docs/contracts/lang-detector-v1.md`. Format exemplar: `docs/superpowers/plans/2026-10-09-wp0-contracts.md`.

## Global Constraints

- **Planning baseline:** branch `codex/plan-wp9`, 2026-10-09; `swift test`: **432 passed, 0 failed**; `dotnet test windows/tests/AINotebook.Core.Tests`: **530 passed, 0 failed, 0 skipped**. The planning commit changes only this document. Implementation workers record their own before/after totals; these are not forecasts for the merged release.
- Read WP0, WP1, WP2, WP3, WP4, WP5, WP6 and WP8. **There is no WP7 detailed plan in this checkout.** `docs/eval/README.md` contains earlier W4 measurements, not the required multilingual release results. Tasks 1–8 can proceed after their named prerequisites. Tasks 9–10 and the WP gate require Claude's landed WP7 plan, actual reports, calibrated estimator and default-model decision. Do not invent measurements, a new benchmark CLI, or a passing exception.
- This plan does not reimplement upstream work: WP2 owns provider conversion/presets/limits and embedding capability filtering; WP3 owns v19; WP4 owns detector/Unicode/provenance; WP5 owns retrieval; WP6 owns folder UI, coverage, durable ingestion and re-index UI; WP8 owns the builder, chat integration, Overview, preview and citation UI. WP9's only planned production Core correction is the endpoint-identity join described in Tasks 2/3.
- Treat the binding WP0 corrections as normative: whole-document malformed-number/surrogate rejection; normalized glob with pinned simple lowercase; strict URL authority; zero evidence means no citations; actual sentence-prefix cost; map share ceiling; published lexical versus manifest-vector revisions; attempts counted on start with five-attempt exhaustion/60-second renewal/token fencing; folder-aware Overview ordering; searchable corpus separate from refresh freshness; deterministic fixture bytes independent of SQLite/host Unicode version. Keep the existing fixture tests in the full gates, rather than rewriting those algorithms here.
- `PreparedContextRequest.sourceRevisions` is an ordered **array of unique `(sourceId, revisionId)` pairs**, not the obsolete dictionary in part of the WP8 plan. Current implementations agree: `Sources/AINotebookCore/ContextPackTypes.swift:352,372`, `windows/src/AINotebook.Core/Rag/ContextPackTypes.cs:97,103`; contract `folder-rag-v1.md:70`. Evidence can retain two revisions of one source.
- Use fixture loaders unchanged: Swift `SharedFixtures.data(_:)`/`url(_:)` at `Tests/AINotebookCoreTests/SharedFixtures.swift:12,16`; C# `SharedFixtures.Json(string)`/`Path(string)` at `windows/tests/AINotebook.Core.Tests/Helpers/SharedFixtures.cs:8,11`. No platform-specific expected-value copies.
- No live model, HTTP server, API key, OS watcher event or timer sleep in Core integration tests. Dedicated URLProtocol/HttpMessageHandler intercepts embedding requests in memory; a prepared transport captures the real request and returns fixture answer text. The native filesystem and database remain real.
- Every Windows connection access, including test assertions, is inside `lock (store.Gate)`; production uses `lock (_gate)`. Await only outside those locks. Swift access uses MainActor/store queue. Never patch shipped migrations or introduce v20; upgrade is through the ordinary store initializer.
- Both suites remain green. A failing cross-WP seam outside the task's file list is a reproducible upstream defect: retain the failing assertion and have Claude assign the owner a separate disjoint fix before dependent tasks merge. Do not turn it into a skip, fake the data adapter, or expand scope silently.
- Cancellation is not pause. A cancelled running attempt is terminal and fenced. Resume the ingestion operation by scheduling a new verified scan/new extraction job; never call ResumeJob on a cancelled job or reset attempts. Restart means stopping/joining workers, releasing old services/store, and constructing a new store at the same path.
- Windows is unpackaged: no `Windows.Storage.ApplicationData` or `Package.Current`. The smoke changes no visible UI. Any WinUI resource lookup uses `Application.Current.Resources[...]`. App compilation and App tests run on Windows CI, not macOS.
- Networking remains under `Providers/` and existing precise exceptions. No new allowlist exception is needed. NOTICE and attribution are hashed WP4 artifacts: verify them without editing their bytes; corrections must regenerate WP4 artifact/manifest/package copies together.
- Only Task 10 changes `VERSION` and both constants. Every task commits explicit paths with final trailer `Co-Authored-By: Codex <noreply@openai.com>`. No implementation task creates a PR, merges main, or pushes a release tag. Claude performs those actions only after explicit user approval of the concrete release result.

## File Structure

New files have no current line number. Existing-file anchors below were read in this checkout. An upstream output not yet present is explicitly identified by its plan location, not given a fictitious source line.

| Task | Files (exclusive write ownership) | Purpose/current grounding |
|---|---|---|
| 1 [Shared] | `tools/contracts/gen_release_fixtures.py`, `tools/contracts/test_release_fixtures.py`, `Tests/fixtures/contracts/release-integration-v1.json` | New shared seven-scenario contract; existing envelope rules `Tests/fixtures/README.md:6` |
| 2 [Swift] | `Sources/AINotebookCore/Providers/FolderEmbeddingSession.swift`; `Tests/AINotebookCoreTests/ReleaseIntegrationSupport.swift`, `ReleaseUpgradeChatTests.swift` | Correct WP6 output (WP6 plan:1603); new real integration support/tests; current store initializer `NotebookStore.swift:26`, retriever `Retriever.swift:26`, old chat path `ChatEngine.swift:138` |
| 3 [Windows] | `windows/src/AINotebook.Core/Providers/FolderEmbeddingSession.cs`; `windows/tests/AINotebook.Core.Tests/Integration/ReleaseIntegrationSupport.cs`, `ReleaseUpgradeChatTests.cs` | WP6 output (plan:1613); current store `Storage/NotebookStore.cs:50`, retriever `Rag/Retriever.cs:17`, old chat path `Rag/ChatEngine.cs:49` |
| 4 [Swift] | `Tests/AINotebookCoreTests/ReleaseIntegrationSupport.swift`, `ReleaseLifecycleTests.swift` | Sequential extension of Task 2 support; no Core edits |
| 5 [Windows] | `windows/tests/AINotebook.Core.Tests/Integration/ReleaseIntegrationSupport.cs`, `ReleaseLifecycleTests.cs` | Sequential extension of Task 3 support; no Core edits |
| 6 [Win-UI] | `windows/src/AINotebook.App/App.xaml.cs`, `windows/src/AINotebook.App/Services/StartupSmokeProfile.cs`, `windows/tests/AINotebook.App.Tests/StartupSmokeProfileTests.cs`, `.github/workflows/windows-ci.yml` | Existing startup `App.xaml.cs:24,42,56,84,160,226`; existing App build/tests `windows-ci.yml:45,63` |
| 7 [Swift-UI] | `docs/releases/0.15.0-macos-verification.md` | New checklist and Claude's actual execution record |
| 8 [Win-UI] | `docs/releases/0.15.0-windows-verification.md` | New user checklist and actual execution record |
| 9 [Shared] | `README.md`, `docs/roadmap.md`, `CHANGELOG.md`, `docs/releases/0.15.0-release-evidence.md` | Features `README.md:79,98,102,260`; R-1 `roadmap.md:80`, D1 `:147`; changelog insertion `CHANGELOG.md:3` |
| 10 [Shared] | `VERSION`, `Sources/AINotebookCore/AINotebookVersion.swift`, `windows/src/AINotebook.Core/AINotebookVersion.cs`, `docs/releases/0.15.0-release-evidence.md` | Current 0.14.0 at lines 1/4/7 respectively; existing equality guards at `AINotebookVersionTests.swift:21` and C# `AINotebookVersionTests.cs:14` |

Read-only assets: `Tests/fixtures/storage/v18.sqlite`; `eval/multilingual/manifest.json` and the five document paths in Task 1; WP6 `Tests/fixtures/ingestion/workbook.xlsx` and `contracts/ingestion-office-v1.json`; WP8 `contracts/context-pack-v1.json`; existing contract generators, workflows and localization files named below. No test copies these into the working tree; all mutable copies are under a unique temporary directory.

**Execution DAG:** 1 → (2 ∥ 3); 2 → 4; 3 → 5. Task 6 can run with 2–5 after WP6/WP8 App integration. Task 7 can run with 2–6 after Task 1 and its upstream UI dependencies; Task 8 follows Tasks 1/6 and can run with 2–5/7. Task 9 depends on 1–8 **and WP7**; 10 follows 9 and successful pre-bump acceptance; it then runs the final post-bump gate. Only 2→4, 3→5 and 9→10 share files, and they are strictly sequential. Tasks never run from unmerged copies of their shared/support dependency.

## Upstream readiness record

Before Task 1, record dependency commit IDs in its handoff. Before each platform task, confirm the following declarations have landed. They are planned interfaces, not claims about today's source tree.

| Boundary | Swift | C# |
|---|---|---|
| Open real upgrade | `NotebookStore.init(path:StorePath, language:AppLanguage = .english, configuredEmbeddingModelKey:String? = nil) throws` | `NotebookStore(StorePath path, AppLanguage language=AppLanguage.English, string? configuredEmbeddingModelKey=null)` |
| Disk path | `StorePath.init(fileURL:URL?)` | `StorePath(string? filePath)` |
| Runtime add/drain | `addFolder(notebookId:Int64,url:URL) async throws -> FolderSource`; `drainOnce() async throws -> Bool`; `stop() async` | `Task<FolderSource> AddFolderAsync(long,string,CancellationToken=default)`; `Task<bool> DrainOnceAsync(CancellationToken=default)`; `Task StopAsync()` |
| Reconcile | `FolderReconciler.init(store:NotebookStore,clock:any IngestLeaseClock,requestScan:@escaping @Sendable(Int64,Bool) async throws -> Void)`; `reconcile(now:Int64) async throws` | `FolderReconciler(NotebookStore,IIngestLeaseClock,Func<long,bool,Task>)`; `Task ReconcileAsync(long,CancellationToken=default)` |
| Queue execution | `JobQueue.runOne(kind:String,reservedBytes:Int64,execute:@Sendable(IngestJob,JobFence) async throws -> Void) async throws -> Bool` | `Task<bool> RunOneAsync(string,long,Func<IngestJob,JobFence,CancellationToken,Task>,CancellationToken=default)` |
| Rescan/rules | `requestFolderScan(folderId:Int64,verifyAll:Bool,now:Int64) throws -> Int64`; `FolderScanner.applyRules(folderId:Int64,rules:FolderRules,now:Int64) async throws` | `long RequestFolderScan(long,bool,long)`; `Task ApplyRulesAsync(long,FolderRules,long,CancellationToken=default)` |
| Real pack data | `CompatibilityPackDataSource.init(store:NotebookStore,retriever:Retriever)` | `CompatibilityPackDataSource(NotebookStore,Retriever)` |
| Prepare/send | `ChatEngine.prepare(_ intent:PackIntent) async throws -> PreparedPackHandle`; `sendPrepared(_:expectedKey:onToken:onRetry:) async throws -> ChatMessage` | `Task<PreparedPackHandle> PrepareAsync(PackIntent,CancellationToken=default)`; `Task<ChatMessage> SendPreparedAsync(PreparedPackHandle,byte[],Action<string>?,Action?,CancellationToken=default)` |

These come from WP3 Tasks 10/11, WP6 runtime contract at plan:1825–1856 and WP8 late handoff at plan:1107–1193. WP6 schema handoffs (options_json, immutable pages and fenced retry publication) must already be in v19. The data adapter must invoke WP5's pinned retrieval and WP6 coverage/map, not old display snippets. WP2's chat-only embedding conversion must include persisted one-time notice state and an embedding-capable-only picker on both platforms. Its final notice key is an upstream handoff decision missing from the current WP2 plan; Tasks 7/8 record the actual landed key, not a second conversion implementation.

### Task 1: [Shared] Freeze release inputs and observable scenarios

**Depends on:** WP0 corrections, WP1 assets, WP6 shared ingestion fixtures, WP8 rendering fixtures. **Parallel with:** none in WP9 until this commit lands; unrelated upstream files can proceed.

**Files:** The three Task 1 files only.

**Interfaces — Consumes:** Swift `SharedFixtures.data(_ relativePath:String) throws -> Data`; C# `SharedFixtures.Json(string relativePath) -> JsonElement`. Python reads WP1 manifest objects (`document_id,path,raw_sha256,content_hash,encoding,language`) and WP6 workbook bytes. **Produces:** Python `build(root:Path) -> dict`, `encoded(root:Path) -> bytes`, `generate(root:Path,check:bool=False,output:Path|None=None) -> None`; UTF-8/LF contract `release-integration`, version 1. Both platforms decode `assets`, `endpointCases`, `rulesText`, `question`, `answer`, and `cases` verbatim. No database IDs are preassigned except legacy fixture assertions. For a single selected folder, require the WP8 adapter to use its persisted displayName for scope.name (the temporary root is named Folder); confirm this handoff before platform tests start.

- [ ] **Step 1 — red fixture tests.** Create `test_release_fixtures.py` first:

```python
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from tools.contracts.gen_release_fixtures import build, encoded, generate

ROOT = Path(__file__).resolve().parents[2]

class ReleaseFixtureTests(unittest.TestCase):
    def test_scenarios_and_real_inputs(self):
        f = build(ROOT)
        self.assertEqual('release-integration', f['contract'])
        self.assertEqual(1, f['version'])
        self.assertEqual([
            'upgrade-chat', 'restart-reconcile', 'cancel-resume',
            'delete-completed-scan', 'rules-restrict', 'empty-selection',
            'zero-evidence'], [x['name'] for x in f['cases']])
        self.assertEqual(6, len(f['assets']))
        self.assertEqual({'cs','sk','en','de'},
                         {x['language'] for x in f['assets'] if x['kind'] == 'invoice'})
        for a in f['assets']:
            raw = (ROOT / a['repoPath']).read_bytes()
            self.assertEqual(a['rawSha256'], hashlib.sha256(raw).hexdigest())
        cp = next(a for a in f['assets'] if a['kind'] == 'cp1250')
        raw = (ROOT / cp['repoPath']).read_bytes()
        with self.assertRaises(UnicodeDecodeError):
            raw.decode('utf-8', errors='strict')
        self.assertIn('Příliš žluťoučký kůň', raw.decode('cp1250'))

    def test_deterministic_and_rejects_stale_file(self):
        self.assertEqual(encoded(ROOT), encoded(ROOT))
        f = build(ROOT)
        self.assertEqual('endpoint-v1:' + hashlib.sha256(
            b'openai_compatible\0https://wp9.invalid/v1').hexdigest(),
            f['endpointCases'][0]['expected'])
        self.assertEqual([2,1], f['cases'][0]['expected']['savedMarkers'])
        self.assertEqual(0, f['cases'][-1]['expected']['citations'])
        with tempfile.TemporaryDirectory() as d:
            # The generator's output path is overridable for its own unit test;
            # it still reads the repository's real immutable inputs.
            out = Path(d) / 'fixture.json'
            out.write_bytes(encoded(ROOT))
            self.assertEqual(json.loads(out.read_bytes()), f)
            generate(ROOT, True, output=out)
            out.write_bytes(b'{}\n')
            with self.assertRaises(SystemExit):
                generate(ROOT, True, output=out)

if __name__ == '__main__':
    unittest.main()
```

Run `python3 -B -m unittest discover -s tools/contracts -p test_release_fixtures.py -v` → **FAIL, missing gen_release_fixtures import**. Do not claim a failed integration assertion before its prerequisites exist.

- [ ] **Step 2 — implement deterministic assembly.** Use this exact asset inventory. Read each manifest row by document ID; assert the row's actual path equals the listed repoPath suffix and its recomputed raw/canonical hashes equal the manifest. Do not copy or rewrite corpus bytes. For the XLSX read the WP6 workbook and its independently authored canonical expected text from the office contract's exact `workbook-order` case, reading `expected.text`; require exactly one matching case.

| document ID/kind | repoPath | destination `relPath` | expected language |
|---|---|---|---|
| cs-03 / invoice | `eval/multilingual/documents/cs/customer/finance/2026/10/invoice.md` | `cs/invoice.md` | cs |
| sk-03 / invoice | `eval/multilingual/documents/sk/customer/finance/2026/10/invoice.md` | `sk/invoice.md` | sk |
| en-03 / invoice | `eval/multilingual/documents/en/customer/finance/2026/10/invoice.md` | `en/invoice.md` | en |
| de-03 / invoice | `eval/multilingual/documents/de/customer/finance/2026/10/invoice.md` | `de/invoice.md` | de |
| cs-10 / cp1250 | `eval/multilingual/documents/cs/customer/technical/legacy/terminal.txt` | `cs/terminal.txt` | cs |
| workbook / xlsx | `Tests/fixtures/ingestion/workbook.xlsx` | `sheets/workbook.xlsx` | und or detector's actual label; do not invent a gold language for a tiny spreadsheet |

Each asset carries `kind,repoPath,relPath,rawSha256,canonicalText,encoding,language`; XLSX `encoding=null,language=null`. The generator strictly decodes text and reads the workbook expected canonical text from WP6, never calls a production extractor. Current text lengths are 1188/1112/1121/1357/2040 scalars: each fits one 2048-scalar chunk. Assert this precondition so a corpus edit does not silently invalidate six-file coverage expectations.

Take the exact English rules paragraph from the shared context-pack fixture's `expected.messages` system `rules` section, require every fixture instance to agree, and store it in `rulesText`. Do not read production Swift/C# to generate the oracle. Fixed top-level values:

```python
question = 'Porovnej FA-CS-2026-031, FA-SK-2026-041, INV-EN-2026-051 a RE-DE-2026-061.'
answer = 'Odpověď [2][1][2][99].'
instructions = 'Odpověz stručně česky.'
endpoint_cases = [
    ('openai_compatible', 'https://wp9.invalid/v1'),
    ('openai_compatible', 'https://wp9.invalid/proxy/v1'),
    ('ollama', 'http://127.0.0.1:11434'),
]
endpointCases = [dict(type=t, root=r, expected='endpoint-v1:' +
    hashlib.sha256((t+'\0'+r).encode('utf-8')).hexdigest()) for t,r in endpoint_cases]
cases = [
    dict(name='upgrade-chat', expected=dict(files=6, searchable=6,
         refreshPending=0, refreshError=0, savedMarkers=[2,1], citationVersion=2)),
    dict(name='restart-reconcile', relPath='en/invoice.md',
         append='\nWP9-RESTART: added while the application was stopped.\n',
         expected=dict(files=6, searchable=6, sameSource=True, newRevision=True)),
    dict(name='cancel-resume', relPath='cs/invoice.md',
         append='\nWP9-RESUME: dokončená nová revize.\n',
         expected=dict(cancelledState='cancelled', oldRevisionRetained=True,
                       newJob=True, newRevision=True, searchable=6)),
    dict(name='delete-completed-scan', relPath='de/invoice.md',
         expected=dict(before='present', after='missing', searchable=5,
                       missing=1, oldCitationReadable=True)),
    dict(name='rules-restrict', pattern='de/**', relPath='de/invoice.md',
         expected=dict(eligible=False, availability='present', searchable=5,
                       vectorIncludes=False, lexicalIncludes=False,
                       mapIncludes=False, overviewIncludes=False)),
    dict(name='empty-selection', expected=dict(citations=0, queryEmbeddingCalls=0)),
    dict(name='zero-evidence', cap=0, expected=dict(citations=0, evidenceSections=0)),
]
```

`build` returns those fields plus the six assets, `dbFixture='storage/v18.sqlite'`, its SHA-256, `runtimeContext=32768,maxOutputTokens=1024,fetchK=32,topK=8`. Verify the read-only SQLite fixture has `v18_personas`, no `v19_folder_rag`, and message 41 in session 31 is `saved answer` with one legacy citation to chunk 1101/source 101. The existing migration identifier is grounded at `Sources/AINotebookCore/MigrationV18.swift:5,8`; do not confuse migration count with version 18 (there are skipped numbers). The current fixture SHA-256 is `6922d230d6daf7f62d1db515397893c5297884f0e2397c9f49f2047523edc579`.

Canonical serialization and CLI:

```python
def encoded(root):
    return (json.dumps(build(root), ensure_ascii=False, sort_keys=True, indent=2)
            + '\n').encode('utf-8')

def generate(root: Path, check: bool = False, output: Path | None = None) -> None:
    path = output or root / 'Tests/fixtures/contracts/release-integration-v1.json'
    data = encoded(root)
    if check:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit('release-integration-v1.json is stale')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generate(Path(__file__).resolve().parents[2], args.check)
```

No current timestamp, platform absolute path, SQLite version, random ID or host Unicode classification enters bytes. Add a test that calls `generate(ROOT,True)` after generation; hand-edit a temporary output copy and verify stale comparison fails without changing the real fixture.

- [ ] **Step 3 — green and commit.**

```bash
python3 -B tools/contracts/gen_release_fixtures.py
python3 -B tools/contracts/gen_release_fixtures.py --check
python3 -B -m unittest discover -s tools/contracts -p test_release_fixtures.py -v
swift test --filter SharedFixturesTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/contracts/gen_release_fixtures.py tools/contracts/test_release_fixtures.py Tests/fixtures/contracts/release-integration-v1.json
git commit -m "test(release): freeze multilingual integration scenarios" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: Python tests OK, generator check exit 0, both fixture loaders accept all seven uniquely named cases, both full suites pass. No gold values are generated from the implementation under test.

## Paired integration support contract (Tasks 2–5)

This is test infrastructure, never a production fixture reader. Every helper below lives in the platform's named `ReleaseIntegrationSupport` file. Tasks 2/3 implement the upgrade/chat subset; Tasks 4/5 extend it sequentially for lifecycle operations.

| Test helper | Exact Swift signature | Exact C# signature |
|---|---|---|
| fixture | `ReleaseFixture.load() throws -> ReleaseFixture`; `caseNamed(_ name:String) -> ReleaseCase` | `static ReleaseFixture Load()`; `ReleaseCase CaseNamed(string name)` |
| open six-file tree/upgrade | `@MainActor ReleaseHarness.open() async throws -> ReleaseHarness` | `static Task<ReleaseHarness> OpenAsync()` |
| graph lifetime | `close() async`; `reopen() async throws`; `removeTemporaryFiles() throws` | `Task CloseAsync()`; `Task ReopenAsync()`; `void RemoveTemporaryFiles()` |
| drain | `drain() async throws` | `Task DrainAsync()` |
| lookup | `source(_ relPath:String) throws -> Source` | `Source Source(string relPath)` |
| prepare | `prepare(scope:RetrievalScope? = nil,mode:String = "answer",cap:Int? = nil) async throws -> PreparedPackHandle` | `Task<PreparedPackHandle> PrepareAsync(RetrievalScope? scope=null,string mode="answer",int? cap=null)` |
| send | `send(_ handle:PreparedPackHandle) async throws -> ChatMessage` | `Task<ChatMessage> SendAsync(PreparedPackHandle handle)` |
| DB assertions | `integer(_ sql:String) throws -> Int`; `rawCitations(assistantId:Int64) throws -> String` | `int Integer(string sql)`; `string RawCitations(long assistantId)` |
| lifecycle | `scanOnly() async throws`; `reconcile() async throws`; `append(caseName:String) throws`; `delete(relPath:String) throws` | `Task ScanOnlyAsync()`; `Task ReconcileAsync()`; `void Append(string caseName)`; `void Delete(string relPath)` |
| query | `pool(query:String,includeVectors:Bool = true) async throws -> PinnedRetrievalCandidates` | `Task<PinnedRetrievalCandidates> PoolAsync(string query,bool includeVectors=true)` |

The harness exposes `fixture, root, folderURL/folderPath, databaseURL/databasePath, notebookId, sessionId, folderId, store, runtime, scanner, worker, queue, retriever, transport, queryEmbedding, gate, clock, previews, engine`. Swift graph-owned members are computed from an optional `ReleaseGraph`; C# uses a nullable private graph. `close` stops runtime and queue and discards the whole graph (including store, engine, retriever, index, scanner, worker, transport and preview cache). C# disposes the store and HttpClient; Swift invalidates URLSession and releases all store references. `reopen` builds a new graph with the same notebook/session/folder IDs; never copy or overwrite the DB a second time. Cleanup is in success and catch/finally, after all tasks are joined.

`ReleaseFixture` decodes the exact Task 1 wire fields (Swift Decodable structs, C# JsonSerializer with `PropertyNameCaseInsensitive=true`). Assertions consume every case by name; each suite's scenario-name test verifies exactly the seven names in the fixture, so an added case cannot go silently unexecuted. `expected` numeric and boolean fields are decoded, not replaced with platform literals.

Open algorithm: create a unique temporary parent and its `Folder` subdirectory; hash and copy the v18 fixture to `db.sqlite`; copy the six assets byte-for-byte to their relative destinations; verify SHA-256 first; open the ordinary production store with `configuredEmbeddingModelKey:nil/null`; create a new notebook `WP9 integration` and session `Release chat` (legacy notebook IDs remain untouched); persist the `wp9` provider; build the graph below; call runtime addFolder once, then drain. Default folder name is the root leaf `Folder`, default rules include md/txt/xlsx and cp1250. No v19 INSERT seed, direct publication call or migration helper is allowed in this open path.

Swift asset source resolution uses `SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent()` as repo root. C# maps the `eval/multilingual/` prefix to `AppContext.BaseDirectory/EvalMultilingual/` and `Tests/fixtures/` to `SharedFixtures.Path(asset.RepoPath["Tests/fixtures/".Length..])`; reject all other prefixes. Existing links already cover both at `AINotebook.Core.Tests.csproj:36,43`, so no project edit is needed. Check every relative destination is nonempty, not rooted, and has no `..` component before creating its parent directories.

### Task 2: [Swift] Join generation identity and prove upgraded-folder chat

**Depends on:** 1; merged WP2, WP3, WP4, WP5, WP6 Core runtime and WP8 Task 8. **Parallel with:** 3, 5, 6, 7, 8 once their dependencies exist. **Files:** Only Task 2 paths in the table. Task 4 waits for this commit.

**Interfaces — Consumes:** All Swift support/upstream signatures above. Production identity from WP5 plan:1584–1601 is `EmbeddingEndpointRevision.make(type:ProviderType,normalizedRoot:String) -> String`. WP6 plan:1603 has `FolderEmbeddingSession.init(config:ProviderConfig,model:String,apiKey:String?,modelDigest:String?,queryFormatVersion:String,docFormatVersion:String,session:URLSession = .shared) throws`, `selection:EmbeddingSelection`, `identity(dims:Int) throws -> GenerationIdentity`, `embed(inputs:[String]) async throws -> [[Float]]`. C# twins are `EmbeddingEndpointRevision.Make(ProviderType,string)`, the constructor and `Selection`, `Identity(int)`, `EmbedAsync(IReadOnlyList<string>,CancellationToken)` in Task 3. **Produces:** Swift harness contract and four test methods below; same behavior is Task 3's C# contract. No new production public signature.

- [ ] **Step 1 — red identity test first.** WP5 specifies `endpoint-v1:` + SHA256(type + NUL + root), whereas WP6 plan:1620 specifies SHA256(type + newline + root). This is a genuine joined behavior defect, not a new algorithm. Add:

```swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor final class ReleaseUpgradeChatTests: XCTestCase {
    func testFolderSessionUsesRetrievalEndpointIdentity() throws {
        let f = try SharedFixtures.json("contracts/release-integration-v1.json")
        for c in f["endpointCases"] as! [[String:Any]] {
            let type = try XCTUnwrap(ProviderType(rawValue:c["type"] as! String))
            let config = ProviderConfig(id:"wp9",type:type,name:"WP9",
                baseURL:c["root"] as! String,privacyAcknowledged:true)
            let session = try FolderEmbeddingSession(config:config,model:"wp9-2d",
                apiKey:nil,modelDigest:nil,queryFormatVersion:"1",docFormatVersion:"1")
            XCTAssertEqual(session.selection.endpointRevision,c["expected"] as? String)
            XCTAssertEqual(try session.identity(dims:2).endpointRevision,
                EmbeddingEndpointRevision.make(type:type,normalizedRoot:c["root"] as! String))
        }
    }
}
```

Run `swift test --filter ReleaseUpgradeChatTests.testFolderSessionUsesRetrievalEndpointIdentity` → expected **FAIL fingerprint mismatch** if WP6 follows its current plan. If upstream already corrected it, record that this regression is initially green; the missing-harness tests in Step 3 provide the red run. Never deliberately damage correct production code to manufacture red.

- [ ] **Step 2 — fix the join in the one owned Core file.** Replace WP6's private SHA256 construction with:

```swift
let normalizedRoot = try ProviderAPIRoot.normalize(config.baseURL)
let endpointRevision = EmbeddingEndpointRevision.make(
    type:config.type, normalizedRoot:normalizedRoot)
```

Use this value for both `selection` and `identity(dims:)`; remove the duplicate hashing code. Keep validation, capture, privacy, model/dimensions/formats and key handling unchanged. Existing unreleased generated indexes with the old incompatible fingerprint are not relabelled: rebuild through the normal generation path. No shipped v18 index has this modern identity.

- [ ] **Step 3 — write three real integration tests before the harness.**

```swift
extension ReleaseUpgradeChatTests {
    func testUpgradeFolderChatAndCitationReload() async throws {
        let h = try await ReleaseHarness.open()
        do {
            XCTAssertEqual(try h.integer("SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'"),1)
            XCTAssertEqual(try h.store.messages(sessionId:31).first?.content,"saved answer")
            XCTAssertEqual(try h.store.messages(sessionId:31).first?.citations.first?.chunkId,1101)
            let handle = try await h.prepare()
            XCTAssertTrue(try h.store.messages(sessionId:h.sessionId).isEmpty)
            try await h.assertPack(handle.request,caseName:"upgrade-chat")
            let reply = try await h.send(handle)
            let captured = await h.transport.requests
            XCTAssertEqual(captured,[try PreparedContextRequestJSON.encode(handle.request)])
            XCTAssertEqual(reply.citations.map(\.marker),h.fixture.caseNamed("upgrade-chat").expected.savedMarkers)
            for citation in reply.citations {
                XCTAssertEqual(citation,handle.request.citationMap.first { $0.marker == citation.marker })
            }
            let raw = try h.rawCitations(assistantId:XCTUnwrap(reply.id))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
            XCTAssertEqual(json["v"] as? Int,h.fixture.caseNamed("upgrade-chat").expected.citationVersion)
            let saved = reply.citations
            let assistantId = try XCTUnwrap(reply.id)
            await h.close()
            try await h.reopen()
            XCTAssertEqual(try h.store.messages(sessionId:h.sessionId).last?.citations,saved)
            let preview = await h.previews.sent(sessionId:h.sessionId,assistantId:assistantId)
            XCTAssertNil(preview)
            await h.close()
            try h.removeTemporaryFiles()
        } catch {
            await h.close(); try h.removeTemporaryFiles(); throw error
        }
    }

    func testExplicitEmptyScopeDoesNotEmbedOrCite() async throws {
        let h = try await ReleaseHarness.open()
        do {
            let before = await h.queryEmbedding.calls
            let handle = try await h.prepare(scope:.selection(sourceIds:[],folderIds:[]))
            XCTAssertEqual(handle.request.citationMap.count,h.fixture.caseNamed("empty-selection").expected.citations)
            let after = await h.queryEmbedding.calls
            XCTAssertEqual(after-before,h.fixture.caseNamed("empty-selection").expected.queryEmbeddingCalls)
            XCTAssertFalse(handle.request.messages.flatMap(\.sections).contains { $0.kind == "map" })
            let reply = try await h.send(handle)
            XCTAssertTrue(reply.citations.isEmpty)
            await h.close(); try h.removeTemporaryFiles()
        } catch { await h.close(); try h.removeTemporaryFiles(); throw error }
    }

    func testZeroEvidenceBudgetPersistsNoCitations() async throws {
        let h = try await ReleaseHarness.open()
        do {
            let handle = try await h.prepare(cap:h.fixture.caseNamed("zero-evidence").cap!)
            XCTAssertEqual(handle.request.citationMap.count,h.fixture.caseNamed("zero-evidence").expected.citations)
            XCTAssertEqual(handle.request.messages.flatMap(\.sections).filter { $0.kind == "evidence" }.count,
                h.fixture.caseNamed("zero-evidence").expected.evidenceSections)
            let reply = try await h.send(handle)
            XCTAssertTrue(reply.citations.isEmpty)
            XCTAssertTrue(try h.store.messages(sessionId:h.sessionId).last!.citations.isEmpty)
            await h.close(); try h.removeTemporaryFiles()
        } catch { await h.close(); try h.removeTemporaryFiles(); throw error }
    }
}
```

Run `swift test --filter ReleaseUpgradeChatTests` → **FAIL, ReleaseHarness undefined**. Keep the assertions when filling the harness.

- [ ] **Step 4 — implement the graph and controlled boundaries.** Imports in support: Foundation, CryptoKit, XCTest, GRDB, `@testable import AINotebookCore`. A dedicated URLProtocol intercepts every URL (unknown URLs fail; none reach the network). Reuse only the current read-only `URLRequest.bodyData` extension at `Tests/AINotebookCoreTests/MockURLProtocol.swift:67`, not its global mutable handler.

```swift
final class ReleaseEmbeddingURLProtocol: URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.absoluteString == "https://wp9.invalid/v1/embeddings",
                let body=request.bodyData,
                let json=try JSONSerialization.jsonObject(with:body) as? [String:Any],
                json["model"] as? String == "wp9-2d", let inputs=json["input"] as? [String]
            else { throw URLError(.badURL) }
            let data=try JSONSerialization.data(withJSONObject:["data":inputs.enumerated().map {
                ["index":$0.offset,"embedding":[1,0]] as [String:Any]
            }])
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,
                httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

actor ReleaseQueryEmbedding: EmbeddingProducing, EmbeddingSessionPreparing {
    private(set) var calls = 0
    func embed(model:String,inputs:[String]) async throws -> [[Float]] {
        try Task.checkCancellation(); calls += 1
        return inputs.map { _ in [1,0] }
    }
    func prepareEmbedding(identity:GenerationIdentity) async throws -> ProviderEmbeddingSession {
        XCTAssertEqual(identity.endpointRevision,EmbeddingEndpointRevision.make(
            type:.openaiCompatible,normalizedRoot:"https://wp9.invalid/v1"))
        return ProviderEmbeddingSession(client:self,model:identity.model,
            storageKey:identity.providerId+":"+identity.model,endpointRevision:identity.endpointRevision)
    }
}

struct ReleaseClock: IngestLeaseClock {
    func now()->Int64 { 1_800_000_000 }
    func wait(until:Int64) async throws {
        if until <= now() { return }
        let pair=AsyncStream<Void>.makeStream()
        defer { pair.continuation.finish() }
        for await _ in pair.stream {}
        try Task.checkCancellation()
    }
}
struct ReleaseSilentWatches: FolderWatchFactory {
    struct Handle: FolderWatchHandle { func start() throws {}; func stop() {} }
    func make(folder:FolderSource,onEvent:@escaping @Sendable(String)->Void) throws -> any FolderWatchHandle { Handle() }
}

actor ReleaseTransport: PreparedPackTransport {
    nonisolated let model: PackModel
    nonisolated let answer: String
    private(set) var requests:[Data] = []
    init(model:PackModel,answer:String) { self.model=model; self.answer=answer }
    private func record(_ request:PreparedContextRequest) throws {
        requests.append(try PreparedContextRequestJSON.encode(request))
    }
    nonisolated func stream(_ request:PreparedContextRequest)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream { continuation in
            let task=Task {
                do {
                    try await self.record(request); try Task.checkCancellation()
                    continuation.yield(self.answer); continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
}
struct ReleaseTransportFactory: PackTransportFactory {
    let transport: ReleaseTransport
    func freeze(_ intent:PackIntent) async throws -> any PreparedPackTransport { transport }
}
```

The fixed clock is for short deterministic attempts; WP6 already tests lease deadlines/renewal. It never advances automatically. Release waits are cancelled and joined on shutdown. The full extraction gate is added in Task 4; Task 2's gate is an actor with `afterExtraction() async throws { try Task.checkCancellation() }`.

Construct and retain this exact graph in `ReleaseHarness.makeGraph` after store creation:

```swift
let config=ProviderConfig(id:"wp9",type:.openaiCompatible,name:"WP9",
    baseURL:"https://wp9.invalid/v1",privacyAcknowledged:true,createdAt:Date(timeIntervalSince1970:0))
try store.saveProvider(config)
let urlConfig=URLSessionConfiguration.ephemeral
urlConfig.protocolClasses=[ReleaseEmbeddingURLProtocol.self]
let http=URLSession(configuration:urlConfig)
let embedding=try FolderEmbeddingSession(config:config,model:"wp9-2d",apiKey:nil,
    modelDigest:nil,queryFormatVersion:"1",docFormatVersion:"1",session:http)
let fs=NativeFolderFileSystem()
let clock=ReleaseClock()
let admission=IngestionAdmission()
let scanner=FolderScanner(store:store,fileSystem:fs,tables:try UnicodeTables.bundled(),clock:clock)
let gate=ReleaseExtractionGate()
let worker=FolderExtractionWorker(store:store,fileSystem:fs,detector:LanguageDetector.bundled(),
    clock:clock,embeddingSelection:{ _ in embedding.selection },extract:{ url,kind,rules in
        let document=try await BoundedDocumentExtractor().extract(url:url,kind:kind,rules:rules)
        try await gate.afterExtraction()
        return document
    })
let index=FolderIndexCoordinator(store:store,admission:admission,clock:clock,
    session:{ _ in embedding },selectedSelection:{ _ in embedding.selection })
let queue=JobQueue(store:store,clock:clock,admission:admission)
let runtime=FolderIngestionRuntime(store:store,scanner:scanner,extraction:worker,index:index,
    queue:queue,clock:clock,admission:admission,watches:ReleaseSilentWatches())
let queryEmbedding=ReleaseQueryEmbedding()
let retriever=Retriever(store:store,client:queryEmbedding,model:"wp9:wp9-2d")
let transport=ReleaseTransport(model:PackModel(providerId:"wp9",model:"wp9-chat",
    runtimeContext:fixture.runtimeContext,maxOutputTokens:fixture.maxOutputTokens,
    contextWindowKnown:true,providerType:"openai_compatible"),answer:fixture.answer)
let previews=ContextPreviewSession()
let coordinator=ContextPackCoordinator(data:CompatibilityPackDataSource(store:store,retriever:retriever),
    transports:ReleaseTransportFactory(transport:transport))
let engine=ChatEngine(store:store,coordinator:coordinator,previews:previews,chatModel:"wp9-chat")
```

`LanguageDetector.bundled()` is WP4's nonthrowing fail-closed loader; assert its result produces the four fixture language labels through real extraction. A missing artifact is a failed integration prerequisite, not a reason to inject a fake detector. All graph components above are retained; no native watches start because the test uses drain/reconcile rather than the asynchronous process loop.

Implement preparation with the real store fingerprints and fixture values:

```swift
func prepare(scope:RetrievalScope? = nil,mode:String="answer",cap:Int?=nil) async throws -> PreparedPackHandle {
    let selected=scope ?? .selection(sourceIds:[],folderIds:[folderId])
    let intent=PackIntent(notebookId:notebookId,sessionId:sessionId,question:fixture.question,
        mode:mode,scope:selected,providerId:"wp9",model:"wp9-chat",providerConfigurationRevision:0,
        runtimeContext:fixture.runtimeContext,maxOutputTokens:fixture.maxOutputTokens,
        evidenceBudgetCap:cap,fetchK:fixture.fetchK,topK:fixture.topK,notebookInstructions:"",
        instructionsOverride:fixture.instructions,currentNoteContent:nil,useWebSearch:false,
        historyFingerprint:try store.contextHistoryFingerprint(sessionId:sessionId),
        scopeFingerprint:try store.contextScopeFingerprint(notebookId:notebookId,scope:selected),
        regenerateUserId:nil,replacesAssistantId:nil)
    return try await engine.prepare(intent)
}
func drain() async throws {
    for _ in 0..<256 { if try await !runtime.drainOnce() { return } }
    XCTFail("durable queue did not quiesce in 256 attempts")
    throw IngestionError(code:"releaseDrainExceeded")
}
func send(_ handle:PreparedPackHandle) async throws -> ChatMessage {
    try await engine.sendPrepared(handle,expectedKey:handle.key,onToken:{ _ in })
}
func integer(_ sql:String) throws -> Int {
    try store.runOnDatabase { try Int.fetchOne($0,sql:sql)! }
}
func rawCitations(assistantId:Int64) throws -> String {
    try store.runOnDatabase { try String.fetchOne($0,
        sql:"SELECT citations_json FROM messages WHERE id=?",arguments:[assistantId])! }
}
```

- [ ] **Step 5 — implement exact pack assertions.** `assertPack(_:caseName:) async throws` checks the shared expected counts and actual DB state together:

```swift
func assertPack(_ request:PreparedContextRequest,caseName:String) async throws {
    let expected=fixture.caseNamed(caseName).expected
    XCTAssertEqual(request.coverage.corpus.filesInScope,expected.files)
    XCTAssertEqual(request.coverage.corpus.searchable,expected.searchable)
    XCTAssertEqual(request.coverage.corpus.refreshPending,expected.refreshPending)
    XCTAssertEqual(request.coverage.corpus.refreshError,expected.refreshError)
    XCTAssertFalse(request.coverage.corpus.partial)
    XCTAssertNotNil(request.generationId)
    XCTAssertEqual(request.messages.first?.sections.map(\.kind),["rules","instructions"])
    XCTAssertEqual(request.messages.first?.sections.first?.text,fixture.rulesText)
    XCTAssertEqual(request.messages.first?.sections.last?.text,fixture.instructions)
    let sections=try XCTUnwrap(request.messages.last?.sections)
    XCTAssertEqual(sections.map(\.kind),["scope","map"] + Array(repeating:"evidence",count:6) + ["question"])
    XCTAssertEqual(sections.filter { $0.kind == "question" }.count,1)
    XCTAssertEqual(sections.last?.text,"[QUESTION]\n"+fixture.question+"\n[/QUESTION]")
    let scope=sections[0].text
    XCTAssertTrue(scope.contains("Scope: Folder"))
    XCTAssertTrue(scope.contains("Scan: idle; last complete:"))
    XCTAssertFalse(scope.contains("last complete: unknown"))
    XCTAssertTrue(scope.contains("Corpus: 6 files; 6 searchable"))
    XCTAssertTrue(scope.contains("Freshness: 0 refresh pending; 0 refresh error"))
    XCTAssertTrue(scope.contains("Turn: 6 passages from 6 files"))
    let map=sections[1].text
    for asset in fixture.assets {
        let source=try self.source(asset.relPath)
        XCTAssertEqual(source.availability,"present")
        XCTAssertTrue(source.eligible)
        let revisionId=try XCTUnwrap(source.publishedRevisionId)
        let canonical=try XCTUnwrap(store.revision(id:revisionId)).draft.canonicalText
        XCTAssertEqual(Array(canonical.utf8),Array(asset.canonicalText.utf8))
        XCTAssertTrue(map.contains(asset.relPath))
        let citation=try XCTUnwrap(request.citationMap.first { $0.sourceId == source.id })
        XCTAssertEqual(citation.folderId,folderId)
        XCTAssertEqual(citation.relPath,asset.relPath)
        XCTAssertEqual(citation.revisionId,revisionId)
        XCTAssertFalse(citation.spans.isEmpty)
        XCTAssertEqual(citation.chunkId,citation.chunkIds.first)
        let citationText=try XCTUnwrap(citation.text)
        XCTAssertFalse(citationText.isEmpty)
        let scalars=Array(asset.canonicalText.unicodeScalars)
        for span in citation.spans {
            XCTAssertGreaterThanOrEqual(span.start,0)
            XCTAssertLessThanOrEqual(span.end,scalars.count)
            XCTAssertLessThan(span.start,span.end)
            let slice=String(String.UnicodeScalarView(scalars[span.start..<span.end]))
            XCTAssertEqual(Array(citationText.utf8),Array(slice.utf8))
        }
        if let language=asset.language {
            XCTAssertEqual(source.lang,language)
            XCTAssertTrue(sections.contains { $0.kind == "evidence" &&
                $0.text.contains(asset.relPath+" · "+language) })
        }
    }
    XCTAssertEqual(try source("cs/terminal.txt").encoding,"windows-1250")
    let bytes=try PreparedContextRequestJSON.encode(request)
    XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains(root.path))
    let expectedPairs=Set(request.citationMap.map {
        PackSourceRevision(sourceId:$0.sourceId,revisionId:$0.revisionId!) })
    XCTAssertTrue(expectedPairs.isSubset(of:Set(request.sourceRevisions)))
    XCTAssertEqual(request.sourceRevisions.count,Set(request.sourceRevisions).count)
    let pool=try await retriever.search(notebookId:notebookId,query:fixture.question,
        scope:.selection(sourceIds:[],folderIds:[folderId]),fetchK:fixture.fetchK)
    XCTAssertEqual(pool.diagnostics.vectorStatus,"used")
    let sourceIds=try Set(fixture.assets.map { try XCTUnwrap(source($0.relPath).id) })
    XCTAssertEqual(Set(pool.vector.map(\.reference.sourceId)),sourceIds)
    await pool.close()
}
```

Also assert `sourceRevisions` sorted by sourceId/revisionId, retained generation equals `store.activeGeneration(notebookId:)?.id`, legacy chunk 1101 remains spanless with `legacy context`, and SQLite `PRAGMA foreign_key_check` returns no rows. These are real store observations, not fixture reconstruction. Close every returned pool before closing the store; use do/catch to close if an additional throwing assertion helper is inserted.

The full-text assertion must use UTF-8/scalar equality (not Swift canonical-equivalence alone). A citation has **no language field**; headers/source chunks provide language assertions. Estimator version and exact token counts may change in WP7: assert total message framing plus section costs and output allowance fit `runtimeContext`; do not pin the development estimator to version 1.

- [ ] **Step 6 — green and commit.**

```bash
swift test --filter ReleaseUpgradeChatTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/Providers/FolderEmbeddingSession.swift Tests/AINotebookCoreTests/ReleaseIntegrationSupport.swift Tests/AINotebookCoreTests/ReleaseUpgradeChatTests.swift
git commit -m "test(release): prove Swift upgrade ingestion pack and citation persistence" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four new test methods pass; all endpoint cases and upgrade/empty/zero scenarios execute, both full suites green. Record actual baseline/final counts and endpoint correction status.

### Task 3: [Windows] Join generation identity and prove upgraded-folder chat

**Depends on:** 1; merged WP2, WP3, WP4, WP5, WP6 Core runtime and WP8 Task 9. **Parallel with:** 2, 4, 6, 7, 8. **Files:** Only Task 3 paths in the table; Task 5 waits for this commit.

**Interfaces — Consumes:** `FolderEmbeddingSession(ProviderConfig config,string model,string? apiKey,string? modelDigest,string queryFormatVersion,string docFormatVersion,HttpClient http)`, `EmbeddingSelection Selection`, `GenerationIdentity Identity(int dims)`, `Task<float[][]> EmbedAsync(IReadOnlyList<string>,CancellationToken=default)` (WP6 plan:1613); `EmbeddingEndpointRevision.Make(ProviderType,string) -> string` (WP5 plan:1605); all C# upstream/support contracts above. Swift peers: `FolderEmbeddingSession.init(config:model:apiKey:modelDigest:queryFormatVersion:docFormatVersion:session:) throws`, `.selection`, `.identity(dims:)`, `.embed(inputs:)`, `EmbeddingEndpointRevision.make(type:normalizedRoot:)`. **Produces:** C# ReleaseHarness/support and four Facts; no new production public API.

- [ ] **Step 1 — red shared endpoint regression.**

```csharp
using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Integration;

public sealed class ReleaseUpgradeChatTests
{
    [Fact]
    public void FolderSessionUsesRetrievalEndpointIdentity()
    {
        using var http=new HttpClient(new ReleaseEmbeddingHandler());
        foreach(var row in SharedFixtures.Json("contracts/release-integration-v1.json")
            .GetProperty("endpointCases").EnumerateArray())
        {
            var type=row.GetProperty("type").GetString() switch {
                "ollama"=>ProviderType.Ollama,
                "openai_compatible"=>ProviderType.OpenAICompatible,
                _=>throw new InvalidDataException("unhandled endpoint fixture type")
            };
            string root=row.GetProperty("root").GetString()!;
            var config=new ProviderConfig("wp9",type,"WP9",root,true,true,DateTime.UnixEpoch);
            var session=new FolderEmbeddingSession(config,"wp9-2d",null,null,"1","1",http);
            Assert.Equal(row.GetProperty("expected").GetString(),session.Selection.EndpointRevision);
            Assert.Equal(EmbeddingEndpointRevision.Make(type,root),session.Identity(2).EndpointRevision);
        }
    }
}
```

Initially use `new HttpClient()` solely for construction (the constructor must not send); replace it with the dedicated handler once support is implemented. Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ReleaseUpgradeChatTests.FolderSessionUsesRetrievalEndpointIdentity` → **FAIL fingerprint mismatch** for the current WP6 recipe. If already fixed upstream, preserve the green regression and use Step 3's missing support as the red evidence.

- [ ] **Step 2 — production join.** In the owned FolderEmbeddingSession constructor use:

```csharp
string normalizedRoot=ProviderApiRoot.Normalize(config.BaseUrl);
string endpointRevision=EmbeddingEndpointRevision.Make(config.Type,normalizedRoot);
```

Both Selection and Identity must use that captured value. Do not mutate generations or add migration SQL. Keep credentials out of identity and captured request serialization.

- [ ] **Step 3 — red Core integration Facts.** Add Models/Rag/Storage imports and these methods to the same class:

```csharp
[Fact]
public async Task UpgradeFolderChatAndCitationReload()
{
    var h=await ReleaseHarness.OpenAsync();
    try
    {
        Assert.Equal(1,h.Integer("SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'"));
        var legacy=Assert.Single(h.Store.Messages(31));
        Assert.Equal("saved answer",legacy.Content);
        Assert.Equal(1101,Assert.Single(legacy.Citations).ChunkId);
        var handle=await h.PrepareAsync();
        Assert.Empty(h.Store.Messages(h.SessionId));
        await h.AssertPackAsync(handle.Request,"upgrade-chat");
        var reply=await h.SendAsync(handle);
        Assert.Equal(PreparedContextRequestJson.Encode(handle.Request),Assert.Single(h.Transport.Requests));
        Assert.Equal(h.Fixture.CaseNamed("upgrade-chat").Expected.SavedMarkers,
            reply.Citations.Select(c=>c.Marker).ToArray());
        foreach(var citation in reply.Citations)
            Assert.Equal(CitationsCodec.Encode([handle.Request.CitationMap.Single(c=>c.Marker==citation.Marker)]),
                         CitationsCodec.Encode([citation]));
        long assistantId=Assert.IsType<long>(reply.Id);
        using(var raw=JsonDocument.Parse(h.RawCitations(assistantId)))
            Assert.Equal(h.Fixture.CaseNamed("upgrade-chat").Expected.CitationVersion,
                         raw.RootElement.GetProperty("v").GetInt32());
        string saved=CitationsCodec.Encode(reply.Citations)!;
        await h.CloseAsync();
        await h.ReopenAsync();
        Assert.Equal(saved,CitationsCodec.Encode(h.Store.Messages(h.SessionId).Last().Citations));
        Assert.Null(h.Previews.Sent(h.SessionId,assistantId));
    }
    finally { await h.CloseAsync(); h.RemoveTemporaryFiles(); }
}

[Fact]
public async Task ExplicitEmptyScopeDoesNotEmbedOrCite()
{
    var h=await ReleaseHarness.OpenAsync();
    try
    {
        int before=h.QueryEmbedding.Calls;
        var handle=await h.PrepareAsync(new RetrievalScope.Selection(new HashSet<long>(),new HashSet<long>()));
        Assert.Equal(h.Fixture.CaseNamed("empty-selection").Expected.Citations,handle.Request.CitationMap.Length);
        Assert.Equal(h.Fixture.CaseNamed("empty-selection").Expected.QueryEmbeddingCalls,h.QueryEmbedding.Calls-before);
        Assert.DoesNotContain(handle.Request.Messages.SelectMany(m=>m.Sections),s=>s.Kind=="map");
        Assert.Empty((await h.SendAsync(handle)).Citations);
    }
    finally { await h.CloseAsync(); h.RemoveTemporaryFiles(); }
}

[Fact]
public async Task ZeroEvidenceBudgetPersistsNoCitations()
{
    var h=await ReleaseHarness.OpenAsync();
    try
    {
        var row=h.Fixture.CaseNamed("zero-evidence");
        var handle=await h.PrepareAsync(cap:row.Cap);
        Assert.Equal(row.Expected.Citations,handle.Request.CitationMap.Length);
        Assert.Equal(row.Expected.EvidenceSections,
            handle.Request.Messages.SelectMany(m=>m.Sections).Count(s=>s.Kind=="evidence"));
        Assert.Empty((await h.SendAsync(handle)).Citations);
        Assert.Empty(h.Store.Messages(h.SessionId).Last().Citations);
    }
    finally { await h.CloseAsync(); h.RemoveTemporaryFiles(); }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ReleaseUpgradeChatTests` → **FAIL, ReleaseHarness missing**.

- [ ] **Step 4 — implement the actual C# graph.** Support imports System.Net, System.Text, System.Text.Json, System.Runtime.CompilerServices, Dapper, Xunit and Core Models/Storage/Providers/Ollama/Rag/Ingestion/Language plus Tests.Helpers. No WinUI dependency.

```csharp
internal sealed class ReleaseEmbeddingHandler : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)
    {
        Assert.Equal("https://wp9.invalid/v1/embeddings",request.RequestUri!.AbsoluteUri);
        using var json=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
        Assert.Equal("wp9-2d",json.RootElement.GetProperty("model").GetString());
        int count=json.RootElement.GetProperty("input").GetArrayLength();
        return new HttpResponseMessage(HttpStatusCode.OK) {
            Content=new StringContent(JsonSerializer.Serialize(new {
                data=Enumerable.Range(0,count).Select(i=>new { index=i,embedding=new[]{1,0} })
            }),Encoding.UTF8,"application/json")
        };
    }
}
internal sealed class ReleaseQueryEmbedding : IEmbeddingProducing,IEmbeddingSessionPreparing
{
    private int _calls;
    internal int Calls=>Volatile.Read(ref _calls);
    public Task<float[][]> EmbedAsync(string model,IReadOnlyList<string> inputs,CancellationToken ct=default)
    {
        ct.ThrowIfCancellationRequested(); Interlocked.Increment(ref _calls);
        return Task.FromResult(inputs.Select(_=>new float[]{1,0}).ToArray());
    }
    public Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity,CancellationToken ct=default)
    {
        Assert.Equal(EmbeddingEndpointRevision.Make(ProviderType.OpenAICompatible,"https://wp9.invalid/v1"),identity.EndpointRevision);
        return Task.FromResult(new ProviderEmbeddingSession(this,identity.Model,
            identity.ProviderId+":"+identity.Model,identity.EndpointRevision));
    }
}
internal sealed class ReleaseClock : IIngestLeaseClock
{
    public long Now=>1_800_000_000;
    public Task WaitUntilAsync(long deadline,CancellationToken ct)=>deadline<=Now ? Task.CompletedTask :
        new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously).Task.WaitAsync(ct);
}
internal sealed class ReleaseSilentWatches : IFolderWatchFactory
{
    private sealed class Handle : IFolderWatchHandle { public void Start() {} public void Dispose() {} }
    public IFolderWatchHandle Create(FolderSource folder,Action<string> onEvent)=>new Handle();
}
internal sealed class ReleaseTransport(PackModel model,string answer) : IPreparedPackTransport
{
    public PackModel Model { get; }=model;
    internal List<byte[]> Requests { get; }=[];
    public async IAsyncEnumerable<string> StreamAsync(PreparedContextRequest request,[EnumeratorCancellation] CancellationToken ct)
    {
        Requests.Add(PreparedContextRequestJson.Encode(request));
        await Task.Yield(); ct.ThrowIfCancellationRequested(); yield return answer;
    }
}
internal sealed class ReleaseTransportFactory(ReleaseTransport transport) : IPackTransportFactory
{
    public Task<IPreparedPackTransport> FreezeAsync(PackIntent intent,CancellationToken ct)
        =>Task.FromResult<IPreparedPackTransport>(transport);
}
```

Requests is observed only after sequential awaited sends complete. No test concurrently sends on a shared session. Persist the provider before constructing the graph:

```csharp
var config=new ProviderConfig("wp9",ProviderType.OpenAICompatible,"WP9",
    "https://wp9.invalid/v1",true,true,DateTime.UnixEpoch);
store.SaveProvider(config);
var http=new HttpClient(new ReleaseEmbeddingHandler());
var embedding=new FolderEmbeddingSession(config,"wp9-2d",null,null,"1","1",http);
var fs=new NativeFolderFileSystem();
var clock=new ReleaseClock();
var admission=new IngestionAdmission();
var scanner=new FolderScanner(store,fs,UnicodeTables.LoadBundled(),clock);
var gate=new ReleaseExtractionGate();
var worker=new FolderExtractionWorker(store,fs,LanguageDetector.LoadBundled(),clock,
    _=>Task.FromResult<EmbeddingSelection?>(embedding.Selection),async (url,kind,rules,ct)=> {
        var document=await new BoundedDocumentExtractor().ExtractAsync(url,kind,rules,ct);
        await gate.AfterExtractionAsync(ct);
        return document;
    });
var index=new FolderIndexCoordinator(store,admission,clock,
    (_,_)=>Task.FromResult<FolderEmbeddingSession?>(embedding),
    _=>Task.FromResult<EmbeddingSelection?>(embedding.Selection));
var queue=new JobQueue(store,clock,admission);
var runtime=new FolderIngestionRuntime(store,scanner,worker,index,queue,clock,admission,new ReleaseSilentWatches());
var queryEmbedding=new ReleaseQueryEmbedding();
var retriever=new Retriever(store,queryEmbedding,"wp9:wp9-2d");
var transport=new ReleaseTransport(new PackModel("wp9","wp9-chat",fixture.RuntimeContext,
    fixture.MaxOutputTokens,true,"openai_compatible"),fixture.Answer);
var previews=new ContextPreviewSession();
var coordinator=new ContextPackCoordinator(new CompatibilityPackDataSource(store,retriever),new ReleaseTransportFactory(transport));
var engine=new ChatEngine(store,coordinator,previews,"wp9-chat");
```

Retain these values in the graph. Task 3 gate method initially calls `ct.ThrowIfCancellationRequested()` and returns CompletedTask; Task 5 adds the controllable barrier. Harness methods:

```csharp
internal async Task DrainAsync()
{
    for(int i=0;i<256;i++) if(!await Runtime.DrainOnceAsync()) return;
    throw new InvalidOperationException("durable queue did not quiesce in 256 attempts");
}
internal Task<PreparedPackHandle> PrepareAsync(RetrievalScope? scope=null,string mode="answer",int? cap=null)
{
    var selected=scope ?? new RetrievalScope.Selection(new HashSet<long>(),new HashSet<long>{FolderId});
    var intent=new PackIntent(NotebookId,SessionId,Fixture.Question,mode,selected,"wp9","wp9-chat",0,
        Fixture.RuntimeContext,Fixture.MaxOutputTokens,cap,Fixture.FetchK,Fixture.TopK,"",Fixture.Instructions,
        null,false,Store.ContextHistoryFingerprint(SessionId),Store.ContextScopeFingerprint(NotebookId,selected),null,null);
    return Engine.PrepareAsync(intent);
}
internal Task<ChatMessage> SendAsync(PreparedPackHandle handle)
    =>Engine.SendPreparedAsync(handle,handle.Key,null,null);
internal int Integer(string sql) { lock(Store.Gate) return Store.Connection.ExecuteScalar<int>(sql); }
internal string RawCitations(long assistantId)
{
    lock(Store.Gate) return Store.Connection.QuerySingle<string>(
        "SELECT citations_json FROM messages WHERE id=$id",new { id=assistantId });
}
```

`Source(relPath)` calls Store.Sources(NotebookId), then Single with matching FolderId/RelPath. `OpenAsync` verifies assets, copies v18, constructs a new store, creates the notebook/session, and calls AddFolderAsync/DrainAsync; `CloseAsync` awaits Runtime.StopAsync and Queue.StopAsync before disposing the graph. `ReopenAsync` constructs an entirely new graph at DatabasePath without calling AddFolderAsync; this catches duplicate-source bugs instead of hiding them.

- [ ] **Step 5 — implement exact paired assertions.**

```csharp
internal async Task AssertPackAsync(PreparedContextRequest request,string caseName)
{
    var e=Fixture.CaseNamed(caseName).Expected;
    Assert.Equal(e.Files,request.Coverage.Corpus.FilesInScope);
    Assert.Equal(e.Searchable,request.Coverage.Corpus.Searchable);
    Assert.Equal(e.RefreshPending,request.Coverage.Corpus.RefreshPending);
    Assert.Equal(e.RefreshError,request.Coverage.Corpus.RefreshError);
    Assert.False(request.Coverage.Corpus.Partial);
    Assert.NotNull(request.GenerationId);
    Assert.Equal(new[]{"rules","instructions"},request.Messages[0].Sections.Select(s=>s.Kind));
    Assert.Equal(Fixture.RulesText,request.Messages[0].Sections[0].Text);
    Assert.Equal(Fixture.Instructions,request.Messages[0].Sections[1].Text);
    var sections=request.Messages[^1].Sections;
    Assert.Equal(new[]{"scope","map"}.Concat(Enumerable.Repeat("evidence",6)).Append("question"),sections.Select(s=>s.Kind));
    Assert.Single(sections.Where(s=>s.Kind=="question"));
    Assert.Equal("[QUESTION]\n"+Fixture.Question+"\n[/QUESTION]",sections[^1].Text);
    Assert.Contains("Scope: Folder",sections[0].Text);
    Assert.Contains("Scan: idle; last complete:",sections[0].Text);
    Assert.DoesNotContain("last complete: unknown",sections[0].Text);
    Assert.Contains("Corpus: 6 files; 6 searchable",sections[0].Text);
    Assert.Contains("Freshness: 0 refresh pending; 0 refresh error",sections[0].Text);
    Assert.Contains("Turn: 6 passages from 6 files",sections[0].Text);
    foreach(var asset in Fixture.Assets)
    {
        var source=Source(asset.RelPath);
        Assert.Equal("present",source.Availability); Assert.True(source.Eligible);
        long revisionId=Assert.IsType<long>(source.PublishedRevisionId);
        Assert.Equal(asset.CanonicalText,Store.Revision(revisionId)!.Draft.CanonicalText);
        Assert.Contains(asset.RelPath,sections[1].Text);
        var citation=Assert.Single(request.CitationMap.Where(c=>c.SourceId==source.Id));
        Assert.Equal(FolderId,citation.FolderId); Assert.Equal(asset.RelPath,citation.RelPath);
        Assert.Equal(revisionId,citation.RevisionId); Assert.NotEmpty(citation.Spans);
        Assert.Equal(citation.ChunkIds[0],citation.ChunkId); Assert.NotEmpty(citation.Text!);
        var scalars=asset.CanonicalText.EnumerateRunes().ToArray();
        foreach(var span in citation.Spans)
            Assert.Equal(string.Concat(scalars.Skip(checked((int)span.Start)).Take(checked((int)(span.End-span.Start))).Select(r=>r.ToString())),citation.Text);
        if(asset.Language is not null)
        {
            Assert.Equal(asset.Language,source.Lang);
            Assert.Contains(sections,s=>s.Kind=="evidence" && s.Text.Contains(asset.RelPath+" · "+asset.Language,StringComparison.Ordinal));
        }
    }
    Assert.Equal("windows-1250",Source("cs/terminal.txt").Encoding);
    Assert.DoesNotContain(Root,Encoding.UTF8.GetString(PreparedContextRequestJson.Encode(request)));
    var pairs=request.SourceRevisions.Select(p=>(p.SourceId,p.RevisionId)).ToArray();
    Assert.Equal(pairs.Length,pairs.Distinct().Count());
    Assert.Equal(pairs.OrderBy(p=>p.SourceId).ThenBy(p=>p.RevisionId),pairs);
    foreach(var citation in request.CitationMap) Assert.Contains((citation.SourceId,citation.RevisionId!.Value),pairs);
    using var pool=await Retriever.SearchAsync(NotebookId,Fixture.Question,
        new RetrievalScope.Selection(new HashSet<long>(),new HashSet<long>{FolderId}),Fixture.FetchK);
    Assert.Equal("used",pool.Diagnostics.VectorStatus);
    Assert.Equal(Fixture.Assets.Select(a=>Assert.IsType<long>(Source(a.RelPath).Id)).Order(),pool.Vector.Select(p=>p.Reference.SourceId).Distinct().Order());
    lock(Store.Gate) Assert.Empty(Store.Connection.Query("PRAGMA foreign_key_check"));
}
```

Also assert active-generation equality, legacy chunk 1101 identity/text/context/null spans, exact persisted citation list via the codec's canonical encoding (record list equality would compare references), and total charged context plus output fits RuntimeContext. Prepared request bytes are compared against the fake transport capture; token estimates are not fabricated from fixture lengths. Real SQLite statements are never executed outside Gate.

- [ ] **Step 6 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ReleaseUpgradeChatTests
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/src/AINotebook.Core/Providers/FolderEmbeddingSession.cs windows/tests/AINotebook.Core.Tests/Integration/ReleaseIntegrationSupport.cs windows/tests/AINotebook.Core.Tests/Integration/ReleaseUpgradeChatTests.cs
git commit -m "test(release): prove Windows upgrade ingestion pack and citation persistence" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four Facts pass, all shared endpoints/upgrade/empty/zero scenarios execute, both full suites green. Windows Core runs on macOS; no App build is claimed here.

### Task 4: [Swift] Restart, cancelled extraction, deletion and immediate rule changes

**Depends on:** 1 and 2 merged. **Parallel with:** 3/5, 6, 7, 8. **Files:** Task 4 support and lifecycle test files only.

**Interfaces — Consumes:** Swift `FolderScanner.scan(folderId:Int64,verifyAll:Bool,fence:JobFence,now:Int64,cancelled:@escaping @Sendable()->Bool) async throws`; `FolderExtractionWorker.execute(job:IngestJob,fence:JobFence) async throws`; `NotebookStore.dueJobs(kind:String,now:Int64,limit:Int) throws -> [IngestJob]`, `job(id:Int64) throws -> IngestJob?`; runtime/reconciler/rules APIs above. C# parity consumes `ScanAsync(long,bool,JobFence,long,CancellationToken)`, `ExecuteAsync(IngestJob,JobFence,CancellationToken)`, `DueJobs(string,long,int)`, `Job(long)`. **Produces:** four Swift test methods and lifecycle helpers; matching C# tests/helpers in Task 5. No new Core API.

- [ ] **Step 1 — write four red tests.** Each uses a fresh six-file tree. The cleanup wrapper is concrete test code:

```swift
import XCTest
@testable import AINotebookCore

@MainActor final class ReleaseLifecycleTests: XCTestCase {
    private func run(_ body:@MainActor(ReleaseHarness) async throws -> Void) async throws {
        let h=try await ReleaseHarness.open()
        do { try await body(h); await h.close(); try h.removeTemporaryFiles() }
        catch { await h.close(); try h.removeTemporaryFiles(); throw error }
    }

    func testRestartReconcilesChangesMadeWhileStopped() async throws {
        try await run { h in
            let row=h.fixture.caseNamed("restart-reconcile")
            let before=try h.source(row.relPath!)
            let first=try await h.prepare()
            let answer=try await h.send(first)
            let snapshots=answer.citations
            await h.close()
            try h.append(caseName:row.name)
            try await h.reopen()
            XCTAssertEqual(try h.source(row.relPath!).publishedRevisionId,before.publishedRevisionId)
            try await h.reconcile()
            try await h.drain()
            let after=try h.source(row.relPath!)
            XCTAssertEqual(after.id,before.id)
            XCTAssertNotEqual(after.publishedRevisionId,before.publishedRevisionId)
            let revision=try XCTUnwrap(h.store.revision(id:XCTUnwrap(after.publishedRevisionId)))
            XCTAssertTrue(revision.draft.canonicalText.hasSuffix(row.append!))
            XCTAssertEqual(try h.store.messages(sessionId:h.sessionId).last?.citations,snapshots)
            let prepared=try await h.prepare()
            XCTAssertEqual(prepared.request.coverage.corpus.searchable,row.expected.searchable)
            XCTAssertEqual(try h.store.sources(notebookId:h.notebookId).filter { $0.folderId == h.folderId }.count,row.expected.files)
        }
    }

    func testCancelMidExtractionThenResumeWithNewJob() async throws {
        try await run { h in
            let row=h.fixture.caseNamed("cancel-resume")
            let old=try h.source(row.relPath!)
            let oldRevisionId=try XCTUnwrap(old.publishedRevisionId)
            let oldText=try XCTUnwrap(h.store.revision(id:oldRevisionId)).draft.canonicalText
            try h.append(caseName:row.name)
            try await h.scanOnly()
            let target="source:\(try XCTUnwrap(old.id))"
            let jobs=try h.store.dueJobs(kind:"extract",now:h.clock.now(),limit:32).filter { $0.draft.target == target }
            XCTAssertEqual(jobs.count,1)
            let job=try XCTUnwrap(jobs.first)
            do {
                let entered=expectation(description:"real extraction reached publication barrier")
                await h.gate.arm { entered.fulfill() }
                let queue=h.queue, worker=h.worker
                let attempt=Task {
                    try await queue.runOne(kind:"extract",reservedBytes:1) { job,fence in
                        try await worker.execute(job:job,fence:fence)
                    }
                }
                do {
                    await fulfillment(of:[entered],timeout:10)
                    guard await h.gate.hasEntered else {
                        throw IngestionError(code:"releaseGateTimeout")
                    }
                    XCTAssertEqual(try h.store.job(id:job.id)?.state,"running")
                    XCTAssertEqual(try h.store.job(id:job.id)?.attempts,1)
                } catch {
                    attempt.cancel(); await h.gate.release()
                    do { _=try await attempt.value } catch is CancellationError {}
                    throw error
                }
                attempt.cancel(); await h.gate.release()
                do { _=try await attempt.value } catch is CancellationError {} // other errors fail
            } // release captured worker/queue before closing the graph
            XCTAssertEqual(try h.store.job(id:job.id)?.state,row.expected.cancelledState)
            XCTAssertNil(try h.store.job(id:job.id)?.leaseToken)
            XCTAssertNil(try h.store.job(id:job.id)?.leaseUntil)
            XCTAssertEqual(try h.source(row.relPath!).currentRevision,old.currentRevision)
            XCTAssertEqual(try h.source(row.relPath!).publishedRevisionId,old.publishedRevisionId)
            let retainedText=try XCTUnwrap(h.store.revision(id:oldRevisionId)).draft.canonicalText
            XCTAssertEqual(Array(retainedText.utf8),Array(oldText.utf8))
            let oldPack=try await h.prepare()
            XCTAssertEqual(oldPack.request.coverage.corpus.searchable,row.expected.searchable)
            XCTAssertTrue(oldPack.request.citationMap.contains { $0.sourceId == old.id && $0.revisionId == old.publishedRevisionId })
            await h.close()
            try await h.reopen()
            try await h.scanOnly()
            let retries=try h.store.dueJobs(kind:"extract",now:h.clock.now(),limit:32).filter { $0.draft.target == target }
            XCTAssertEqual(retries.count,1)
            let retry=try XCTUnwrap(retries.first)
            XCTAssertNotEqual(retry.id,job.id)
            XCTAssertEqual(retry.attempts,0)
            try await h.drain()
            XCTAssertEqual(try h.store.job(id:retry.id)?.state,"done")
            XCTAssertEqual(try h.store.job(id:retry.id)?.attempts,1)
            let freshRevisionId=try XCTUnwrap(h.source(row.relPath!).publishedRevisionId)
            XCTAssertNotEqual(freshRevisionId,oldRevisionId)
            XCTAssertTrue(try XCTUnwrap(h.store.revision(id:freshRevisionId)).draft.canonicalText.hasSuffix(row.append!))
            XCTAssertEqual(try h.store.job(id:job.id)?.state,row.expected.cancelledState)
            let fresh=try await h.prepare()
            XCTAssertEqual(fresh.request.coverage.corpus.searchable,row.expected.searchable)
            XCTAssertTrue(fresh.request.citationMap.contains { $0.sourceId == old.id && $0.text!.contains("WP9-RESUME") })
        }
    }

    func testDeletionBecomesMissingAfterCompletedScanAndKeepsCitation() async throws {
        try await run { h in
            let row=h.fixture.caseNamed("delete-completed-scan")
            let source=try h.source(row.relPath!)
            let one=try await h.prepare(scope:.selection(sourceIds:[try XCTUnwrap(source.id)],folderIds:[]))
            let answer=try await h.send(one)
            let snapshot=try XCTUnwrap(answer.citations.first?.text)
            try h.delete(relPath:row.relPath!)
            XCTAssertEqual(try h.source(row.relPath!).availability,row.expected.before)
            try await h.scanOnly(); try await h.drain()
            XCTAssertEqual(try h.source(row.relPath!).availability,row.expected.after)
            let pack=try await h.prepare()
            XCTAssertEqual(pack.request.coverage.corpus.searchable,row.expected.searchable)
            XCTAssertEqual(pack.request.coverage.corpus.missing,row.expected.missing)
            XCTAssertFalse(pack.request.citationMap.contains { $0.sourceId == source.id })
            let pool=try await h.pool(query:"RE-DE-2026-061")
            XCTAssertFalse(pool.vector.contains { $0.reference.sourceId == source.id })
            XCTAssertFalse(pool.lexical.contains { $0.reference.sourceId == source.id })
            await pool.close()
            await h.close(); try await h.reopen()
            XCTAssertEqual(try h.store.messages(sessionId:h.sessionId).last?.citations.first?.text,snapshot)
        }
    }

    func testRulesImmediatelyRevokeAllBranchesMapAndOverview() async throws {
        try await run { h in
            let row=h.fixture.caseNamed("rules-restrict")
            let source=try h.source(row.relPath!)
            let warm=try await h.pool(query:"RE-DE-2026-061")
            XCTAssertTrue(warm.vector.contains { $0.reference.sourceId == source.id })
            XCTAssertTrue(warm.lexical.contains { $0.reference.sourceId == source.id })
            await warm.close()
            let defaults=FolderRules.defaults
            let rules=FolderRules(includeExts:defaults.includeExts,ignoreGlobs:defaults.ignoreGlobs+[row.pattern!],
                limits:defaults.limits,encodingFallback:defaults.encodingFallback)
            try await h.scanner.applyRules(folderId:h.folderId,rules:rules,now:h.clock.now())
            // No scan/drain between applying rules and observing every retrieval surface.
            let after=try h.source(row.relPath!)
            XCTAssertEqual(after.eligible,row.expected.eligible)
            XCTAssertEqual(after.availability,row.expected.availability)
            let pool=try await h.pool(query:"RE-DE-2026-061")
            XCTAssertEqual(pool.vector.contains { $0.reference.sourceId == source.id },row.expected.vectorIncludes)
            XCTAssertEqual(pool.lexical.contains { $0.reference.sourceId == source.id },row.expected.lexicalIncludes)
            await pool.close()
            let answer=try await h.prepare()
            XCTAssertFalse(answer.request.citationMap.contains { $0.sourceId == source.id })
            XCTAssertEqual(answer.request.messages.flatMap(\.sections).filter { $0.kind == "map" }
                .contains { $0.text.contains(row.relPath!) },row.expected.mapIncludes)
            let overview=try await h.prepare(mode:"overview")
            XCTAssertEqual(overview.request.citationMap.contains { $0.sourceId == source.id },row.expected.overviewIncludes)
            XCTAssertEqual(overview.request.coverage.corpus.searchable,row.expected.searchable)
        }
    }
}
```

Run `swift test --filter ReleaseLifecycleTests` → **FAIL missing lifecycle helpers/gate**. The 10-second XCTest timeout bounds gate entry; the actor's hasEntered check prevents a timed-out test from continuing as though extraction had started. Both success and failure cancel/release/join the attempt before closing the graph. Do not use Task.sleep to synchronize.

- [ ] **Step 2 — implement barrier and operations.**

```swift
actor ReleaseExtractionGate {
    private var armed=false, entered=false, released=false
    private var onEntered:(@Sendable () -> Void)?
    private var releaseWaiter:CheckedContinuation<Void,Never>?
    var hasEntered:Bool { entered }
    func arm(_ callback:@escaping @Sendable () -> Void) {
        armed=true; entered=false; released=false; onEntered=callback
    }
    func afterExtraction() async throws {
        guard armed else { try Task.checkCancellation(); return }
        armed=false; entered=true; onEntered?(); onEntered=nil
        if !released { await withCheckedContinuation { releaseWaiter=$0 } }
        try Task.checkCancellation()
    }
    func release() { released=true; releaseWaiter?.resume(); releaseWaiter=nil }
}
```

The gate runs after the real bounded extractor finishes and before language/chunk publication. Only one modified file is queued. Look up the running job after the entry signal and verify source identity, attempt and lease; releasing a cancelled task cannot publish. A final cleanup release covers assertion failures as well as success.

```swift
func scanOnly() async throws {
    _=try store.requestFolderScan(folderId:folderId,verifyAll:true,now:clock.now())
    let scanner=self.scanner, folderId=self.folderId, clock=self.clock
    let ran=try await queue.runOne(kind:"scan",reservedBytes:0) { _,fence in
        try await scanner.scan(folderId:folderId,verifyAll:true,fence:fence,
            now:clock.now(),cancelled:{ Task.isCancelled })
    }
    XCTAssertTrue(ran)
}
func reconcile() async throws {
    let store=self.store, clock=self.clock
    let reconciler=FolderReconciler(store:store,clock:clock,requestScan:{ id,verify in
        _=try await MainActor.run { try store.requestFolderScan(folderId:id,verifyAll:verify,now:clock.now()) }
    })
    do { try await reconciler.start(); await reconciler.stop() }
    catch { await reconciler.stop(); throw error }
}
func append(caseName:String) throws {
    let row=fixture.caseNamed(caseName)
    let path=folderURL.appendingPathComponent(row.relPath!)
    var bytes=try Data(contentsOf:path); bytes.append(Data(row.append!.utf8))
    try bytes.write(to:path,options:.atomic)
}
func delete(relPath:String) throws { try FileManager.default.removeItem(at:folderURL.appendingPathComponent(relPath)) }
func pool(query:String,includeVectors:Bool=true) async throws -> PinnedRetrievalCandidates {
    try await retriever.search(notebookId:notebookId,query:query,
        scope:.selection(sourceIds:[],folderIds:[folderId]),fetchK:fixture.fetchK,includeVectors:includeVectors)
}
```

`close` calls gate.release before joining queue/runtime. Append modifies only UTF-8 invoices, not the cp1250 file. Reconciliation uses persisted watch-enabled folders and the real reconciler's startup operation; constructing a new Runtime alone is not reconciliation. Tests assert folder count stays one and file identities stay six on restart, preventing accidental re-registration.

- [ ] **Step 3 — strengthen the observable boundaries.** Consume each scenario's booleans (`sameSource,newRevision,oldRevisionRetained,newJob,oldCitationReadable`) by comparing the actual identities/text, not by asserting the fixture booleans alone. Assert a static explicitly supported-name set equals fixture case names; do not rely on test order or a mutable cross-test visited set. In the rule test also make a fresh source selection for the revoked file and assert zero evidence; no selected stale ID may broaden to notebook scope. In the delete test verify last-full-scan timestamp is nonnull and state idle before accepting missing. These use the same helper files and no new tests with duplicated implementation logic.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter 'ReleaseUpgradeChatTests|ReleaseLifecycleTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Tests/AINotebookCoreTests/ReleaseIntegrationSupport.swift Tests/AINotebookCoreTests/ReleaseLifecycleTests.swift
git commit -m "test(release): cover Swift restart cancellation and eligibility lifecycle" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight release test methods total (four upgrade/identity, four lifecycle), seven named scenarios consumed, both full suites green. No sleep-based flakiness or unjoined task remains.

### Task 5: [Windows] Restart, cancelled extraction, deletion and immediate rule changes

**Depends on:** 1 and 3 merged. **Parallel with:** 2/4, 6, 7, 8. **Files:** Only Task 5 paths in the table.

**Interfaces — Consumes:** `FolderScanner.ScanAsync(long folderId,bool verifyAll,JobFence fence,long now,CancellationToken ct=default)`, `FolderExtractionWorker.ExecuteAsync(IngestJob,JobFence,CancellationToken=default)`, `NotebookStore.DueJobs(string kind,long now,int limit) -> IReadOnlyList<IngestJob>`, `Job(long)->IngestJob?`, `RequestFolderScan(long,bool,long)->long`, `FolderReconciler.ReconcileAsync(long,CancellationToken=default)` and `StopAsync()`. Swift counterparts are `scan(folderId:verifyAll:fence:now:cancelled:)`, `execute(job:fence:)`, `dueJobs(kind:now:limit:)`, `job(id:)`, `requestFolderScan(folderId:verifyAll:now:)`, `reconcile(now:)`, `stop()`. **Produces:** four C# Facts and lifecycle helpers with the paired support signatures above; no production API.

- [ ] **Step 1 — write the four red Facts.** Imports Core Models/Storage/Rag/Ingestion, Xunit and the Integration namespace.

```csharp
public sealed class ReleaseLifecycleTests
{
    private static async Task Run(Func<ReleaseHarness,Task> test)
    {
        var h=await ReleaseHarness.OpenAsync();
        try { await test(h); }
        finally { await h.CloseAsync(); h.RemoveTemporaryFiles(); }
    }

    [Fact]
    public Task RestartReconcilesChangesMadeWhileStopped()=>Run(async h=> {
        var row=h.Fixture.CaseNamed("restart-reconcile");
        var before=h.Source(row.RelPath!);
        var answer=await h.SendAsync(await h.PrepareAsync());
        string snapshots=CitationsCodec.Encode(answer.Citations)!;
        await h.CloseAsync(); h.Append(row.Name); await h.ReopenAsync();
        Assert.Equal(before.PublishedRevisionId,h.Source(row.RelPath!).PublishedRevisionId);
        await h.ReconcileAsync(); await h.DrainAsync();
        var after=h.Source(row.RelPath!);
        Assert.Equal(before.Id,after.Id);
        Assert.NotEqual(before.PublishedRevisionId,after.PublishedRevisionId);
        Assert.EndsWith(row.Append!,h.Store.Revision(after.PublishedRevisionId!.Value)!.Draft.CanonicalText);
        Assert.Equal(snapshots,CitationsCodec.Encode(h.Store.Messages(h.SessionId).Last().Citations));
        Assert.Equal(row.Expected.Searchable,(await h.PrepareAsync()).Request.Coverage.Corpus.Searchable);
        Assert.Equal(row.Expected.Files,h.Store.Sources(h.NotebookId).Count(s=>s.FolderId==h.FolderId));
    });

    [Fact]
    public Task CancelMidExtractionThenResumeWithNewJob()=>Run(async h=> {
        var row=h.Fixture.CaseNamed("cancel-resume");
        var old=h.Source(row.RelPath!);
        long oldRevisionId=Assert.IsType<long>(old.PublishedRevisionId);
        string oldText=h.Store.Revision(oldRevisionId)!.Draft.CanonicalText;
        h.Append(row.Name); await h.ScanOnlyAsync();
        string target=$"source:{old.Id}";
        var job=Assert.Single(h.Store.DueJobs("extract",h.Clock.Now,32).Where(j=>j.Draft.Target==target));
        h.Gate.Arm();
        using var cancellation=new CancellationTokenSource();
        var attempt=h.Queue.RunOneAsync("extract",1,(j,f,ct)=>h.Worker.ExecuteAsync(j,f,ct),cancellation.Token);
        try
        {
            await h.Gate.WaitUntilEnteredAsync();
            Assert.Equal("running",h.Store.Job(job.Id)!.State);
            Assert.Equal(1,h.Store.Job(job.Id)!.Attempts);
        }
        finally
        {
            cancellation.Cancel(); h.Gate.Release();
            try { await attempt; } catch(OperationCanceledException) {} // no other swallowed error
        }
        Assert.Equal(row.Expected.CancelledState,h.Store.Job(job.Id)!.State);
        Assert.Null(h.Store.Job(job.Id)!.LeaseToken);
        Assert.Null(h.Store.Job(job.Id)!.LeaseUntil);
        Assert.Equal(old.CurrentRevision,h.Source(row.RelPath!).CurrentRevision);
        Assert.Equal(old.PublishedRevisionId,h.Source(row.RelPath!).PublishedRevisionId);
        Assert.Equal(oldText,h.Store.Revision(oldRevisionId)!.Draft.CanonicalText);
        var oldPack=await h.PrepareAsync();
        Assert.Equal(row.Expected.Searchable,oldPack.Request.Coverage.Corpus.Searchable);
        Assert.Contains(oldPack.Request.CitationMap,c=>c.SourceId==old.Id && c.RevisionId==old.PublishedRevisionId);
        await h.CloseAsync(); await h.ReopenAsync(); await h.ScanOnlyAsync();
        var retry=Assert.Single(h.Store.DueJobs("extract",h.Clock.Now,32).Where(j=>j.Draft.Target==target));
        Assert.NotEqual(job.Id,retry.Id); Assert.Equal(0,retry.Attempts);
        await h.DrainAsync();
        Assert.Equal("done",h.Store.Job(retry.Id)!.State);
        Assert.Equal(1,h.Store.Job(retry.Id)!.Attempts);
        long freshRevisionId=Assert.IsType<long>(h.Source(row.RelPath!).PublishedRevisionId);
        Assert.NotEqual(oldRevisionId,freshRevisionId);
        Assert.EndsWith(row.Append!,h.Store.Revision(freshRevisionId)!.Draft.CanonicalText);
        Assert.Equal(row.Expected.CancelledState,h.Store.Job(job.Id)!.State);
        var fresh=await h.PrepareAsync();
        Assert.Equal(row.Expected.Searchable,fresh.Request.Coverage.Corpus.Searchable);
        Assert.Contains(fresh.Request.CitationMap,c=>c.SourceId==old.Id && c.Text!.Contains("WP9-RESUME",StringComparison.Ordinal));
    });

    [Fact]
    public Task DeletionBecomesMissingAfterCompletedScanAndKeepsCitation()=>Run(async h=> {
        var row=h.Fixture.CaseNamed("delete-completed-scan");
        var source=h.Source(row.RelPath!);
        var one=await h.PrepareAsync(new RetrievalScope.Selection(new HashSet<long>{Assert.IsType<long>(source.Id)},new HashSet<long>()));
        var answer=await h.SendAsync(one);
        string snapshot=Assert.Single(answer.Citations).Text!;
        h.Delete(row.RelPath!);
        Assert.Equal(row.Expected.Before,h.Source(row.RelPath!).Availability);
        await h.ScanOnlyAsync(); await h.DrainAsync();
        Assert.Equal(row.Expected.After,h.Source(row.RelPath!).Availability);
        var pack=await h.PrepareAsync();
        Assert.Equal(row.Expected.Searchable,pack.Request.Coverage.Corpus.Searchable);
        Assert.Equal(row.Expected.Missing,pack.Request.Coverage.Corpus.Missing);
        Assert.DoesNotContain(pack.Request.CitationMap,c=>c.SourceId==source.Id);
        using(var pool=await h.PoolAsync("RE-DE-2026-061"))
        {
            Assert.DoesNotContain(pool.Vector,c=>c.Reference.SourceId==source.Id);
            Assert.DoesNotContain(pool.Lexical,c=>c.Reference.SourceId==source.Id);
        }
        await h.CloseAsync(); await h.ReopenAsync();
        Assert.Equal(snapshot,Assert.Single(h.Store.Messages(h.SessionId).Last().Citations).Text);
    });

    [Fact]
    public Task RulesImmediatelyRevokeAllBranchesMapAndOverview()=>Run(async h=> {
        var row=h.Fixture.CaseNamed("rules-restrict");
        var source=h.Source(row.RelPath!);
        using(var warm=await h.PoolAsync("RE-DE-2026-061"))
        {
            Assert.Contains(warm.Vector,c=>c.Reference.SourceId==source.Id);
            Assert.Contains(warm.Lexical,c=>c.Reference.SourceId==source.Id);
        }
        var defaults=FolderRules.Defaults;
        var rules=new FolderRules(defaults.IncludeExts,defaults.IgnoreGlobs.Append(row.Pattern!).ToArray(),
            defaults.Limits,defaults.EncodingFallback);
        await h.Scanner.ApplyRulesAsync(h.FolderId,rules,h.Clock.Now);
        Assert.Equal(row.Expected.Eligible,h.Source(row.RelPath!).Eligible);
        Assert.Equal(row.Expected.Availability,h.Source(row.RelPath!).Availability);
        using(var pool=await h.PoolAsync("RE-DE-2026-061"))
        {
            Assert.Equal(row.Expected.VectorIncludes,pool.Vector.Any(c=>c.Reference.SourceId==source.Id));
            Assert.Equal(row.Expected.LexicalIncludes,pool.Lexical.Any(c=>c.Reference.SourceId==source.Id));
        }
        var answer=await h.PrepareAsync();
        Assert.DoesNotContain(answer.Request.CitationMap,c=>c.SourceId==source.Id);
        Assert.Equal(row.Expected.MapIncludes,answer.Request.Messages.SelectMany(m=>m.Sections)
            .Where(s=>s.Kind=="map").Any(s=>s.Text.Contains(row.RelPath!,StringComparison.Ordinal)));
        var overview=await h.PrepareAsync(mode:"overview");
        Assert.Equal(row.Expected.OverviewIncludes,overview.Request.CitationMap.Any(c=>c.SourceId==source.Id));
        Assert.Equal(row.Expected.Searchable,overview.Request.Coverage.Corpus.Searchable);
    });
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ReleaseLifecycleTests` → **FAIL missing lifecycle methods/barrier**.

- [ ] **Step 2 — implement the deterministic operations.**

```csharp
internal sealed class ReleaseExtractionGate
{
    private int _armed;
    private TaskCompletionSource _entered=new(TaskCreationOptions.RunContinuationsAsynchronously);
    private TaskCompletionSource _released=new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal void Arm()
    {
        _entered=new(TaskCreationOptions.RunContinuationsAsynchronously);
        _released=new(TaskCreationOptions.RunContinuationsAsynchronously);
        Interlocked.Exchange(ref _armed,1);
    }
    internal async Task AfterExtractionAsync(CancellationToken ct)
    {
        if(Interlocked.Exchange(ref _armed,0)==1)
        {
            _entered.TrySetResult(); await _released.Task.WaitAsync(ct);
        }
        ct.ThrowIfCancellationRequested();
    }
    internal Task WaitUntilEnteredAsync()=>_entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
    internal void Release()=>_released.TrySetResult();
}
```

If gate-entry/assertion throws, always cancel/release **and await** attempt before the harness is closed; retain that exception after joining. Use an outer catch/finally in the cancellation Fact so a timeout cannot leave a task using a disposed store. Only OperationCanceledException is expected from the attempt.

```csharp
internal async Task ScanOnlyAsync()
{
    Store.RequestFolderScan(FolderId,true,Clock.Now);
    Assert.True(await Queue.RunOneAsync("scan",0,(_,f,ct)=>Scanner.ScanAsync(FolderId,true,f,Clock.Now,ct)));
}
internal async Task ReconcileAsync()
{
    var reconciler=new FolderReconciler(Store,Clock,(id,verify)=> {
        Store.RequestFolderScan(id,verify,Clock.Now); return Task.CompletedTask;
    });
    try { await reconciler.StartAsync(); }
    finally { await reconciler.StopAsync(); }
}
internal void Append(string caseName)
{
    var row=Fixture.CaseNamed(caseName);
    File.AppendAllText(Path.Combine(FolderPath,row.RelPath!),row.Append!,new UTF8Encoding(false,true));
}
internal void Delete(string relPath)=>File.Delete(Path.Combine(FolderPath,relPath));
internal Task<PinnedRetrievalCandidates> PoolAsync(string query,bool includeVectors=true)
    =>Retriever.SearchAsync(NotebookId,query,new RetrievalScope.Selection(new HashSet<long>(),new HashSet<long>{FolderId}),
        Fixture.FetchK,includeVectors);
```

The harness releases its gate before joining services. No direct SQL is needed for these mutations. Existing public store methods hold their gate; any supplemental read/count assertion holds `Store.Gate` for the entire command and reader lifetime.

- [ ] **Step 3 — complete fixture coverage.** Compare observed identity/text changes to all scenario booleans, assert exactly one folder and six source identities after restart, assert idle/non-null last-full-scan before accepting missing, and test explicit selection of the newly excluded source yields zero evidence. A static supported-name set exactly equals the fixture names; do not use test-order-dependent global visitation state. Each named scenario is dispatched by an explicit test, unknown case names fail validation. Keep all seven expectations shared with Swift.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~ReleaseUpgradeChatTests|FullyQualifiedName~ReleaseLifecycleTests'
dotnet test windows/tests/AINotebook.Core.Tests
swift test
git add windows/tests/AINotebook.Core.Tests/Integration/ReleaseIntegrationSupport.cs windows/tests/AINotebook.Core.Tests/Integration/ReleaseLifecycleTests.cs
git commit -m "test(release): cover Windows restart cancellation and eligibility lifecycle" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: eight release Facts total, all shared scenarios consumed, both complete suites green; file handles are released so temp-tree deletion also passes on Windows CI.

### Task 6: [Win-UI] Launch the actual unpackaged executable in CI

**Depends on:** WP2 App router bridge, WP3 ordinary-store migration, WP6 Task 17 and WP8 App graph integration; Task 1 is not needed for this separate smoke. **Parallel with:** 2–5 and 7 (all files disjoint); Task 8 waits for the smoke result. **Files:** Task 6's four files only.

**Interfaces — Consumes:** C# `internal SettingsService(string path)` (`Services/SettingsService.cs:37`), `NotebookStore(StorePath path, AppLanguage language=AppLanguage.English, string? configuredEmbeddingModelKey=null)`, `AttachmentStore(NotebookStore,string root)` (`Storage/AttachmentStore.cs:15`), `FolderIngestionRuntime : IAsyncDisposable`, `NotebookStore.Folders(long notebookId) -> IReadOnlyList<FolderSource>` (WP3 plan:618). Swift peers for the shared migration proof are `NotebookStore.init(path:language:configuredEmbeddingModelKey:)`, `folders(notebookId:Int64) throws -> [FolderSource]`, already tested in Tasks 2/4; no Swift App smoke API is introduced. **Produces:** App-only `StartupSmokeProfile.Parse(IReadOnlyList<string>) -> StartupSmokeProfile?`, `Create()`, path properties; `ConfigureServices(DispatcherQueue,StartupSmokeProfile? = null) -> IServiceProvider`; `RunStartupSmokeAsync(StartupSmokeProfile) -> Task<int>`; executable `--startup-smoke <absolute-temp-profile>` exits 0/1/2. Zero means complete graph/migration/reopen success, 1 runtime failure, 2 invalid arguments.

**UI surface:** `App.xaml.cs` only. No XAML, view-model binding or EN/CS key is added because this mode never opens a window. Read `App.xaml:1`, `MainWindow.xaml.cs:18` and `NotebookTabCompositionTests.cs:14` to preserve the separation between headless service initialization and XAML UI activation. macOS manual UI is Task 7; Windows visible UI remains Task 8.

- [ ] **Step 1 — red App tests on Windows.** Create:

```csharp
using AINotebook.App.Services;
using Xunit;
namespace AINotebook.App.Tests;

public sealed class StartupSmokeProfileTests
{
    [Fact] public void OrdinaryLaunchHasNoOverride()
        =>Assert.Null(StartupSmokeProfile.Parse([]));
    [Fact] public void OverridesEveryPersistentPath()
    {
        string root=Path.Combine(Path.GetTempPath(),"ainotebook-smoke-test");
        var p=Assert.IsType<StartupSmokeProfile>(StartupSmokeProfile.Parse(["--startup-smoke",root]));
        Assert.Equal(Path.Combine(root,"db.sqlite"),p.DatabasePath);
        Assert.Equal(Path.Combine(root,"settings.json"),p.SettingsPath);
        Assert.Equal(Path.Combine(root,"attachments"),p.AttachmentsPath);
        Assert.Equal(Path.Combine(root,"smoke-result.json"),p.ResultPath);
    }
    [Fact] public void MissingProfileFails()
        =>Assert.Throws<ArgumentException>(()=>StartupSmokeProfile.Parse(["--startup-smoke"]));
    [Fact] public void RelativeProfileFails()
        =>Assert.Throws<ArgumentException>(()=>StartupSmokeProfile.Parse(["--startup-smoke","profile"]));
    [Fact] public void TemporaryPrefixIsNotContainment()
    {
        string sibling=Path.TrimEndingDirectorySeparator(Path.GetTempPath())+"-outside"+Path.DirectorySeparatorChar+"profile";
        Assert.Throws<ArgumentException>(()=>StartupSmokeProfile.Parse(["--startup-smoke",sibling]));
    }
    [Fact] public void ExtraArgumentsFail()
        =>Assert.Throws<ArgumentException>(()=>StartupSmokeProfile.Parse([
            "--startup-smoke",Path.Combine(Path.GetTempPath(),"ainotebook-smoke-test"),"--unexpected"]));
}
```

Run on Windows:

```powershell
dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64 --filter FullyQualifiedName~StartupSmokeProfileTests
```

Expected **FAIL missing StartupSmokeProfile**. The macOS worker records “App tests not runnable on macOS”; it must wait for Windows CI red/green evidence before declaring this task verified, not claim a local Core test proves WinUI startup.

- [ ] **Step 2 — implement profile parsing and inject paths before resolving anything.**

```csharp
namespace AINotebook.App.Services;
internal sealed record StartupSmokeProfile(string Root)
{
    internal string DatabasePath=>Path.Combine(Root,"db.sqlite");
    internal string SettingsPath=>Path.Combine(Root,"settings.json");
    internal string AttachmentsPath=>Path.Combine(Root,"attachments");
    internal string ResultPath=>Path.Combine(Root,"smoke-result.json");
    internal static StartupSmokeProfile? Parse(IReadOnlyList<string> args)
    {
        if(!args.Contains("--startup-smoke")) return null;
        if(args.Count!=2 || args[0]!="--startup-smoke")
            throw new ArgumentException("Expected --startup-smoke <temporary-profile>.");
        if(!Path.IsPathFullyQualified(args[1])) throw new ArgumentException("Smoke profile must be absolute.");
        string root=Path.GetFullPath(args[1]);
        string parent=Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()))+Path.DirectorySeparatorChar;
        if(!root.StartsWith(parent,StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Smoke profile must be below the temporary directory.");
        return new(root);
    }
    internal void Create() { Directory.CreateDirectory(Root); Directory.CreateDirectory(AttachmentsPath); }
}
```

In `App` constructor parse `Environment.GetCommandLineArgs().Skip(1).ToArray()` before `ConfigureServices`, retaining readonly `_smokeProfile`; call Create when nonnull. Invalid smoke arguments are logged and `Environment.Exit(2)`, never a fall-through to production paths. Keep InitializeComponent to exercise actual WinUI/PRI bootstrap. Wrap constructor graph creation failures with existing LogCrash and exit 1 in smoke mode; normal behavior retains its existing exception path.

Change `ConfigureServices(DispatcherQueue uiQueue)` at current line 56 to accept the optional profile; replace only these registrations:

```csharp
services.AddSingleton<ISettingsService>(_=>smokeProfile is null
    ? new SettingsService() : new SettingsService(smokeProfile.SettingsPath));
services.AddSingleton<NotebookStore>(sp=>new NotebookStore(
    smokeProfile is null ? StorePath.Production() : new StorePath(smokeProfile.DatabasePath),
    sp.GetRequiredService<ISettingsService>().Language));
services.AddSingleton<AttachmentStore>(sp=>new AttachmentStore(
    sp.GetRequiredService<NotebookStore>(),
    smokeProfile is null ? AttachmentStore.DefaultRoot() : smokeProfile.AttachmentsPath));
```

Preserve the existing StartupException wrapper on production DB failure. Any WP6 startup code in the constructor must be inside `_smokeProfile is null`; checking only OnLaunched is insufficient if upstream starts services earlier. Constructors for runtime/provider/engine must stay inert. Do not use `ValidateOnBuild=true`: runtime notebook parameters in transient view models are not registered services.

- [ ] **Step 3 — run and dispose the real graph, then reopen.** Add the following to App.xaml.cs (System.Text.Json import); qualification disambiguates WP2's retained App router facade from its Core implementation:

```csharp
private async Task<int> RunStartupSmokeAsync(StartupSmokeProfile profile)
{
    int code=1;
    long notebookId=0;
    try
    {
        var store=Services.GetRequiredService<NotebookStore>();
        _=Services.GetRequiredService<AINotebook.App.Services.ProviderRouter>();
        _=Services.GetRequiredService<IChatStreaming>();
        _=Services.GetRequiredService<IEmbeddingProducing>();
        _=Services.GetRequiredService<Retriever>();
        _=Services.GetRequiredService<ChatEngine>();
        _=Services.GetRequiredService<FolderIngestionRuntime>();
        _=Services.GetRequiredService<AttachmentStore>();
        _=Services.GetRequiredService<ILocalizedStrings>();
        _=Services.GetRequiredService<ISettingsService>();
        var notebook=store.CreateNotebook("Startup smoke");
        notebookId=notebook.Id ?? throw new InvalidOperationException("Notebook ID missing.");
        if(store.Folders(notebookId).Count!=0) throw new InvalidOperationException("Unexpected folder rows.");
        code=0;
    }
    catch(Exception ex) { LogCrash("StartupSmoke",ex); }
    finally
    {
        try { await ((ServiceProvider)Services).DisposeAsync(); }
        catch(Exception ex) { LogCrash("StartupSmokeDispose",ex); code=1; }
    }
    if(code!=0) return code;
    try
    {
        using(var reopened=new NotebookStore(new StorePath(profile.DatabasePath)))
        {
            if(!reopened.Notebooks().Any(n=>n.Id==notebookId))
                throw new InvalidOperationException("Smoke notebook did not survive reopening.");
            _=reopened.Folders(notebookId);
        }
        await File.WriteAllTextAsync(profile.ResultPath,JsonSerializer.Serialize(new {
            status="passed",version=AINotebookVersion.Current,notebookId,profile=profile.Root
        }));
        return 0;
    }
    catch(Exception ex) { LogCrash("StartupSmokeReopen",ex); return 1; }
}
```

At the top of `protected override async void OnLaunched(LaunchActivatedEventArgs args)` set Ui and, when `_smokeProfile` is nonnull, `Environment.Exit(await RunStartupSmokeAsync(_smokeProfile)); return;`. Only the ordinary branch wires callbacks, starts the folder runtime, creates/activates MainWindow and runs update checks. Do not synchronously dispose the provider because WP6 runtime implements IAsyncDisposable. No direct SQL, discovery, embedding, watch, update check or secret read is invoked by the smoke body. The actual services must still resolve successfully; do not substitute a mock graph.

- [ ] **Step 4 — extend existing Windows CI after App tests.** Retain existing restore/build/test and diagnostics steps. Add:

```yaml
      - name: Smoke unpackaged App startup and v18 migration
        shell: pwsh
        run: |
          $project = 'windows/src/AINotebook.App/AINotebook.App.csproj'
          $target = (& dotnet msbuild $project -nologo -getProperty:TargetPath -p:Configuration=Release -p:Platform=x64).Trim()
          if ($LASTEXITCODE -ne 0) { throw 'Could not resolve App TargetPath' }
          $exe = [IO.Path]::ChangeExtension($target, '.exe')
          if (-not (Test-Path $exe)) { throw "App executable missing: $exe" }
          $profile = Join-Path ([IO.Path]::GetTempPath()) ('ainotebook-smoke-' + [Guid]::NewGuid().ToString('N'))
          New-Item -ItemType Directory -Path $profile | Out-Null
          Copy-Item Tests/fixtures/storage/v18.sqlite (Join-Path $profile 'db.sqlite')
          $process = Start-Process -FilePath $exe -ArgumentList "--startup-smoke `"$profile`"" -PassThru
          if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            throw 'App startup smoke timed out after 60 seconds'
          }
          if ($process.ExitCode -ne 0) {
            Get-Content (Join-Path ([IO.Path]::GetTempPath()) 'ainotebook-crash.log') -ErrorAction SilentlyContinue
            throw "App startup smoke exited $($process.ExitCode)"
          }
          $resultPath = Join-Path $profile 'smoke-result.json'
          if (-not (Test-Path $resultPath)) { throw 'Smoke result missing' }
          $result = Get-Content $resultPath -Raw | ConvertFrom-Json
          if ($result.status -ne 'passed') { throw 'Smoke did not pass' }
          if ($result.version -ne (Get-Content VERSION -Raw).Trim()) { throw 'Smoke version mismatch' }
          if ($result.profile -ne $profile) { throw 'Smoke used wrong profile' }
          Write-Host 'PASS: unpackaged App DI, v18 migration, and store reopen'
          Remove-Item $profile -Recurse -Force
```

Use GetTempPath, **not RUNNER_TEMP**: they can be different on hosted Windows. `TargetPath` is queried from MSBuild, so no guessed bin-directory layout. Both result marker and process exit are required; a crash that returns no marker cannot pass.

- [ ] **Step 5 — verification/manual checklist and commit.** On Windows run:

```powershell
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.Core.Tests
```

Expected: build exit 0, six new profile Facts pass with existing App tests, Core suite green; the workflow smoke emits its PASS line. Execute the PowerShell smoke body locally once too: verify no window flashes, temp DB is migrated/reopenable, and ordinary launch still opens onboarding/shell. Test missing argument exits 2 without touching the normal profile.

If windows-latest cannot initialize WinUI in its session, retain the actual failure diagnostics and runner image/runtime identity. Claude may document a specifically evidenced runner limitation and require Task 8's actual manual run; no catch-all `continue-on-error`, suppressed timeout, or generic “headless unsupported” converts an application defect into green. An approved runner exception is visible in the release evidence, not silently counted as a passed smoke.

```bash
git add windows/src/AINotebook.App/App.xaml.cs windows/src/AINotebook.App/Services/StartupSmokeProfile.cs windows/tests/AINotebook.App.Tests/StartupSmokeProfileTests.cs .github/workflows/windows-ci.yml
git commit -m "test(win-app): smoke isolated startup migration and DI in CI" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Native UI verification contract (Tasks 7–8)

These are verification/documentation tasks. They do not own UI implementation or localization edits. A failed interaction is assigned back to the named WP2/WP6/WP8 owner, then the relevant checklist step is rerun on the corrected merged commit. Do not declare a UI task passed from a Core test or a source-text assertion.

The exact shared localization homes are `Sources/AINotebookCore/Localization.swift:2,264` (both EN/CS switches, no .strings files), `windows/src/AINotebook.App/Services/StringKey.cs:49`, and `windows/src/AINotebook.App/Strings/en-US/Resources.resw:737` plus `cs-CZ/Resources.resw:737`. Windows enum names use PascalCase; the resw keys below remain camelCase. These are upstream-owned keys to verify on **both** platforms:

| Swift AppText/resw key | EN | CS |
|---|---|---|
| addFolderButton | Add folder… | Přidat složku… |
| folderWatchEnabled | Watch for changes | Sledovat změny |
| folderScanNow | Scan now | Skenovat teď |
| folderVerifyAll | Verify all | Ověřit vše |
| folderRulesTitle | Folder rules | Pravidla složky |
| folderEncodingCp1250 | Windows-1250 | Windows-1250 |
| folderRefreshError | Refresh failed | Aktualizace selhala |
| scopeWholeNotebook | Whole notebook | Celý notebook |
| scopeSelection | Selected items | Vybrané položky |
| scopeEmpty | No sources selected | Nejsou vybrány žádné zdroje |
| chatOverviewToggle | Overview | Přehled |
| contextPreviewBeforeSend | Show what will be sent | Zobrazit, co se pošle |
| contextPreviewSent | Show sent context | Zobrazit odeslaný kontext |
| contextPreviewTitle | Context preview | Náhled kontextu |
| citationOpenOriginal | Open original | Otevřít originál |
| citationRevisionChanged | The original has changed since this answer. | Originál se od této odpovědi změnil. |
| citationOriginalUnavailable | The original is unavailable. | Originál není dostupný. |
| providerPresetLabel | Preset | Předvolba |
| providerRefreshModels | Refresh models | Obnovit modely |
| providerManualModelId | Model ID | ID modelu |
| providerRuntimeContext | Runtime context | Použitý kontext |
| providerMaxOutputTokens | Maximum output tokens | Maximum tokenů odpovědi |
| providerLimitsReset | Reset to automatic | Obnovit automatické nastavení |
| reindexButton | Re-index | Přeindexovat |
| reindexPausedForChat | Background indexing paused for chat | Indexování na pozadí je pozastaveno kvůli chatu |

WP2's additional one-time conversion notice is a binding requirement but has no exact key in its current table. Before executing Tasks 7/8, Claude records its landed Swift/resw/enum key and exact EN/CS strings in both verification documents from the implementation. Absence of that key/notice blocks the provider checklist; WP9 does not guess a replacement key or waive the requirement. This is an explicit upstream API/localization handoff, not a request to implement another migration here.

### Task 7: [Swift-UI] Author and execute the macOS verification record

**Depends on:** 1; WP2 Task 10, WP6 Tasks 18/20, WP8 Task 10 merged. **Parallel with:** 2–6 and 8. **Files:** `docs/releases/0.15.0-macos-verification.md` only.

**Interfaces — Consumes:** Swift UI `FolderSourcesModel.rows`, `add(url:notebookId:)`, `FolderRulesSheet(folder:onSave:)`, `FolderScopeModel`, `ChatView.overviewForNextMessage`, `prepared`, `showingContext`, `ContextPreviewPanel(snapshot:text:)`, `CitationPopover`, Settings model/limit drafts and generation progress. C# peers `SourcesViewModel.FolderRows`, `AddFolderAsync(string)`, `FolderRulesDialog(FolderSource,Func<FolderRules,Task>,ILocalizedStrings)`, `FolderScopeModel`, `ChatViewModel.OverviewForNextMessage`, `PrepareContextCommand`, `IsContextPreviewOpen`, `ContextPreview.Rows` and `SettingsViewModel.IndexBuilds` are verified by Task 8. **Produces:** a Markdown checklist with actual build commit, macOS version, hardware, UI language, actor (Claude), date, per-step result and defect links. No new Core/UI API.

Read-only view/binding inventory to name in the record:

| View/model | Current anchor or upstream output | Binding/action |
|---|---|---|
| `Sources/AINotebookApp/SourceListView.swift` | `:28,152,315,367` | process holder, `FolderSourcesModel.rows`, directory NSOpenPanel, directory/file drop routing |
| `Sources/AINotebookApp/FolderSourcesModel.swift`, `FolderRulesSheet.swift` | WP6 new output, plan:2080–2115 | persisted coverage/watch rows, validated FolderRules onSave |
| `Sources/AINotebookApp/FolderWatchController.swift` | current `:13`; replaced by WP6 | one process runtime, not a view-owned watcher |
| `Sources/AINotebookApp/ChatView.swift`, `FolderScopeModel.swift` | current ChatView `:48,150,398,603`; WP6/WP8 additions | typed scope, Overview toggle, prepare/preview/send state |
| `Sources/AINotebookApp/ContextPreviewPanel.swift` | WP8 new output | logical sections, wire order/options, omission and token ledger |
| `Sources/AINotebookApp/CitationPopover.swift` | `:23,37` | saved text/spans and click-time original decision |
| `Sources/AINotebookApp/SettingsView.swift`, `AddProviderSheet.swift`, `IndexingStatusBadge.swift` | Settings `:18,19,408`; WP2/WP6 replacement behavior | preset/model/limits drafts, non-destructive generation progress/retry/discard |

- [ ] **Step 1 — author the checklist with every step initially unchecked.** Preparation uses a disposable folder copied from Task 1's six assets, plus a second folder for union/drop testing. Record source hashes and use a dedicated notebook; never point destructive manual scenarios at user documents. Include these exact acceptance steps:

1. EN: add first folder through NSOpenPanel, which selects directories only. Coverage reaches six searchable; four invoice languages are cs/sk/en/de. cp1250 text displays the Czech phrase without replacement characters; XLSX preview contains sheet names, coordinates, gaps/cached formula annotations from its fixture.
2. Drag/drop the second folder, a loose file and a URL. Folder persists once, file remains a loose source and URL remains a web source. Dropping an overlapping root reports the overlap error and creates no duplicate folder.
3. Watch enabled: add/edit/rename/delete nested files and wait for completed scan. Source identity remains stable on content edit; missing is shown only after scan completion. Turn watch off, edit, then Scan now; Verify all detects deliberately changed same-size bytes. An ignored-only or unavailable folder remains visible.
4. Quit the process, edit a watched folder, restart and verify reconciliation without re-adding it. Switch notebook/window and return: coverage/progress continue. Watch-off stays off. No duplicate worker or source appears.
5. Scope picker: whole notebook; folder; source set; individual source; folder+source union; explicitly empty selection. Preview and answer use exactly the selected current membership; empty shows scopeEmpty and creates no citation.
6. Overview: check sample wording includes included files, candidates with published chunks and total files in scope separately. It is identified as an excerpt-based overview, not an exhaustive folder summary. Duplicate relative paths in two folders remain distinct.
7. Preview before send: scope/coverage/languages, relative-path map, evidence full text, rules/instructions, chronological complete history, final question once, and runtime/output options. No absolute local path or secret appears. Edit question/scope/provider/limits: old preview invalidates and must be recalculated. Send an unchanged preview; “Show sent context” matches it.
8. Open citation popover: full saved excerpt, relative path/title and page when present. Core tests separately prove stored revision identity and scalar spans. Edit the file: old answer still shows old saved text and “original changed”. Delete it: saved text remains, Open original is unavailable. Restart: citation remains readable while prior in-memory context preview is unavailable.
9. Settings: inspect LM Studio/custom preset API roots; Refresh models; manual model ID without discovery; unsupported listing (404/405/501) shows unverified wording; bad credentials show error. Save valid runtime/output limits, reject output >= runtime, reset to automatic, restart and verify persistence. No automatic paid generation test.
10. Verify embedding picker excludes Anthropic/OpenWebUI. On a copied legacy settings profile containing either chat-only embedding selection, upgrade converts it once to default local Ollama and shows the one-time notice; dismiss/restart does not repeat conversion/notice. A direct unsupported selection must not silently route at runtime.
11. Re-index: start a build, keep chatting against active evidence, cancel/discard/retry via the actual UI controls, restart during work, and verify progress resumes without clearing the old active index. Chat temporarily pauses new background batches but question embedding proceeds. Failed refresh remains searchable plus refreshError.
12. Repeat folder rules/scope/Overview/preview/citation/Settings surfaces in CS; exact labels match the shared table. Invalid glob/limit leaves Rules open; excluding a file removes it from retrieval immediately while availability remains present. Remove folder from notebook and verify all disk bytes remain.

- [ ] **Step 2 — run existing guards and launch the real app.**

```bash
swift test --filter 'FolderLocalizationTests|ProviderLocalizationTests|ContextPackLocalizationTests'
swift test
swift run AINotebookApp
```

The filter names are the exact WP2/WP6/WP8 planned localization classes; `swift test list` must list all three before accepting the focused run. The full suite remains authoritative. Expected: all discovered tests pass, and Claude observes the checklist in the running app. The app stays open only for manual verification; quit normally afterward. An unchecked manual step is unexecuted, not passed. Checklist authoring itself adds no tests and needs no artificial red code change.

- [ ] **Step 3 — commit the observed record.** Record the full tested commit, exact EN/CS notice key handed off by WP2, failures/retests, and completion date. If Claude has not yet run the app, commit the written checklist with explicit `Execution status: not executed` and keep the release gate open; never certify it for Claude.

```bash
git add docs/releases/0.15.0-macos-verification.md
git commit -m "docs(release): record macOS folder chat verification" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 8: [Win-UI] Write the user's Windows scenario and record execution

**Depends on:** 1 and 6; WP2 Task 11, WP6 Tasks 19/21, WP8 Task 11 merged. **Parallel with:** 2–5 and 7. **Files:** `docs/releases/0.15.0-windows-verification.md` only.

**Interfaces — Consumes:** C# UI signatures listed in the shared UI contract, `SourcesViewModel.AddFolderAsync(string) -> Task`, `SetFolderWatchingAsync(long,bool) -> Task`, `SaveFolderRulesAsync(long,FolderRules) -> Task`, and prepared ChatEngine interfaces in the readiness table. Swift twins are `FolderSourcesModel.add(url:notebookId:) async throws`, runtime `setWatching(folderId:enabled:) async throws`, `FolderRulesSheet` save closure and `ChatEngine.prepare/sendPrepared`. **Produces:** plain user-facing scenario plus actual Windows build/runner/user verification record; no new bindings/localization/API.

Read-only exact surface inventory:

| Files | Current anchor/upstream binding |
|---|---|
| `windows/src/AINotebook.App/Views/SourceListPage.xaml`, `.xaml.cs`; `ViewModels/SourcesViewModel.cs` | XAML `:30`, code-behind `:136,232`; `FolderRows`, row `WatchEnabled` TwoWay, AddFolderAsync and folder actions |
| `Views/FolderRulesDialog.xaml`, `.xaml.cs` | WP6 output; include/ignore/limits/encoding fields to validated FolderRules |
| `Views/ChatPage.xaml`, `.xaml.cs`; `ViewModels/ChatViewModel.cs`, `FolderScopeModel.cs` | XAML `:134,253`, code-behind `:162,169`; WholeNotebookRadio, SelectedItemsRadio, folder/set/source lists, OverviewForNextMessage, PrepareContextCommand |
| `Views/ChatPage.xaml`, `Views/ChatPage.xaml.cs`; `ViewModels/ContextPreviewViewModel.cs` | WP8 inline preview output; IsContextPreviewOpen, ContextPreview.Rows, options/omission presentation |
| `ViewModels/CitationViewModel.cs` | `:16,20`; snapshot text, revision status, OpenCitationOriginalCommand |
| `Views/SettingsDialog.xaml`, `.xaml.cs`; `ViewModels/SettingsViewModel.cs`; `Views/IndexingStatusBadge.xaml`, `.xaml.cs` | Settings XAML `:50,79`; runtime/output drafts, model refresh/manual ID, IndexBuilds/Retry/Discard |

- [ ] **Step 1 — write this mandatory user sequence in plain language.** Include copyable fixture-folder preparation instructions from the six Task 1 asset paths; no technical DI/lease terminology in the user steps:

1. Start the candidate Windows app. Create a notebook and use **Add folder…** to select the sample directory. Wait for six searchable files; open the Czech legacy text and workbook and check readable text/sheet-cell labels.
2. Close the app. Change the English invoice in that folder. Start the app again and reopen the notebook. The same folder returns automatically; its changed file updates without a duplicate source. Show coverage and last complete scan.
3. Select only that folder in chat. Ask the shared Czech comparison question. Open the context preview, confirm cs/sk/en/de evidence labels, then send. Answer has clickable numeric citations; the selected provider/model shown in the app is the one used.
4. Open a citation. Read its saved excerpt, relative path and original. Change/delete its original file, scan, and reopen that citation: saved text still reads and the changed/unavailable message is accurate. Restart once more and confirm the saved citation remains.
5. Switch chat provider using an already authorized local/test configuration, or a user-owned provider explicitly chosen for the test; enter a manual model ID if listing is unavailable. Repeat a question and verify the selected provider/model and configured limits apply. The embedding provider does not change silently when switching chat provider.
6. Repeat in Czech UI, then exercise empty selection, Overview, preview invalidation, rule exclusion, watch toggle, folder drop, and re-index/retry/discard. Check the embedding picker and one-time legacy conversion notice against the EN/CS table. Remove the notebook folder and confirm files remain on disk.

Record Windows edition/build, CPU/RAM, application commit/version, language, provider IDs/types/model names (no keys), exact pass/fail for each step, and links to defects/retests. This is required even when startup smoke passes; the smoke creates no window and cannot certify FolderPicker, drop targets or citation UI.

- [ ] **Step 2 — collect Windows CI and App test evidence.**

```powershell
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.Core.Tests
```

Expected: build success, App tests green including resource/binding tests and six smoke-profile tests; Task 6 executable smoke green or a documented specific runner limitation. The user executes the visible scenario on Windows. A macOS worker writes the checklist and records `Execution status: not executed` until that evidence arrives; it does not claim to have launched WinUI.

- [ ] **Step 3 — commit.** No artificial red test is required for this checklist-only task. Preserve unchecked steps if execution is pending; the WP gate stays open.

```bash
git add docs/releases/0.15.0-windows-verification.md
git commit -m "docs(release): record Windows folder chat acceptance scenario" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 9: [Shared] Publish accurate feature docs and assemble release evidence

**Depends on:** 1–8 merged and actually verified, WP4 production provenance/gate, WP7 plan/results/calibration/default-model decision. **Parallel with:** none within WP9; this task records one integrated candidate. **Files:** README.md, docs/roadmap.md, CHANGELOG.md, docs/releases/0.15.0-release-evidence.md only. NOTICE, tools/lang/ATTRIBUTION.md, resources and WP7 reports are read-only inputs.

**Interfaces — Consumes:** Both platforms' shared fixture outcomes; Swift `AINotebookVersion:String`, C# `AINotebookVersion.Current:string`; current version is still 0.14.0 until Task 10. Shared detector manifest attribution `{sourceIds,licenseIds,attributionPath,attributionSha256,noticePath,noticeSha256}` and raw-count metrics (§7 of lang-detector-v1). WP7 consumes Swift `Retriever.searchEmbedded(snapshot:query:queryVector:fetchK:) async throws -> PinnedRetrievalCandidates` and C# `SearchEmbeddedAsync(ResolvedRetrievalScope,string,float[]?,int,CancellationToken) -> Task<PinnedRetrievalCandidates>`; WP9 reads their measured reports and does not time a fake embedder. **Produces:** factual release documentation and an evidence record with actual numeric results, hashes, commands and links; no new runtime interface on either platform.

- [ ] **Step 1 — enforce the missing-WP7 prerequisite before making release claims.**

```bash
python3 - <<'PY'
from pathlib import Path
plans=list(Path('docs/superpowers/plans').glob('2026-10-09-wp7-*.md'))
assert len(plans)==1, 'WP7 detailed plan must be landed and reviewed before WP9 release evidence'
print(plans[0])
PY
```

Expected at the planning baseline: **FAIL**. At execution after WP7: exactly one existing path is printed. Read that entire plan and its exact report/runner files. Record the actual WP7 commands and artifact paths in the evidence file. This is deliberately a hard prerequisite, not an invented command for a missing runner. Verify that the report measures the new pinned FTS/RRF backend (`fts-or-pinned-rrf-v1`), not WP1's historical `legacy-fts-eval-rrf-v1` baseline or the old hashing-embedder “lexical” mode.

The current contracts freeze detector error ceilings and warm p95, but do not supply a numeric packed-evidence recall acceptance threshold. Claude and the WP7 owner must freeze that target (including denominator and per-language/scope/absence breakdown) before using results to declare success. Record the approved target alongside actual packed recall, never choose a post-hoc threshold merely to pass. There must be a calibrated token estimator artifact (`token-estimate-v2.json` under WP7's final documented path), exact model/tokenizer family coverage and no release use of the development placeholder in contract §12.

- [ ] **Step 2 — write the feature and roadmap changes.** Replace/extend README's Features section with this concrete user-facing substance, adjusted only to the tested UI labels:

```markdown
### Folder chat and multilingual evidence

Add a folder once, watch it for changes, and choose folders, source sets or individual files as the scope of a chat. Folder rules control included file types, ignored paths, extraction limits and Windows-1250 fallback. Coverage shows searchable files separately from pending or failed refreshes.

AI Notebook detects Czech, Slovak, English and German locally. It prepares a context pack with scope information, a relative-path file map and cited excerpts. Overview provides an explicitly sampled view of the folder, and the context preview shows what will be sent. Saved citations retain their text and document revision after restart or changes to the original file.

Provider presets, manual model IDs and per-model context/output limits work on macOS and Windows. Embeddings use embedding-capable providers; changing chat providers does not silently change the embedding provider. Re-indexing builds a replacement index while the active index remains available.
```

Add links to the two verification documents and `docs/eval/README.md`. Explain XLSX sheet/cell output and cached formula/date-format limitations in the supported-format paragraph; no promise to evaluate formulas, perform OCR, or summarize every file exhaustively. Keep UI languages EN/CS (detected document languages are not UI locales).

At README:98 correct the claim that every provider can embed: Anthropic/OpenWebUI are chat-only. At :102–114 update obsolete Windows-only/parity wording only for verified features. At :109 remove unsupported locale-autodetection claims (Windows SettingsService:42 defaults English). At :260 replace stale “11 tables” and fixed localization-key counts with a versioned shared schema/resource description. Preserve the privacy explanation at :118 and the user's explicit choice of local or remote providers.

In `docs/roadmap.md`:

- Update baseline/schema to 0.15.0/v19 and test counts from the final integrated logs, not the planning counts.
- Mark **R-1 done** specifically through independent per-branch fetchK candidate pools and post-diversity/budget topK; link WP5 and the measured WP7 report.
- Keep **D1/contextual enrichment open**, including the one-per-source versus one-per-chunk question. Folder descriptors and context packing do not close D1. Preserve the existing opt-in implementation history without calling it completed strategy work.
- Move the folder-chat release entry to completed with links to detection, generation safety, scope, extraction and context preview evidence.
- Add/retain concrete future items from spec §13: evaluate cs/sk/de stemming only if measured recall warrants it; evaluate int8/sqlite-vec when the recorded 200K memory/performance results warrant it; full map-reduce folder summaries; OCR; XLSX date/formula interpretation; detector retraining/coverage follow-up if reported abstention warrants it. Do not promise a new provider type or an unapproved deadline.

Prepend CHANGELOG with `## [0.15.0] - 2026-10-09` (use the actual release date if execution occurs later), Added/Changed/Fixed bullets for persisted folders/watch/rules, language metadata, scoped full evidence/Overview/preview, immutable citation snapshots, v19 upgrade/generations, strict text decoding and XLSX, provider roots/presets/manual IDs/limits and independent fetchK/topK. Link the actual eval report for the selected default embedder; state that existing indexes are not automatically converted. Do not claim gate success until Step 5.

- [ ] **Step 3 — audit Tatoeba, Unicode and distribution copies without changing hashed inputs.** Read NOTICE and tools/lang/ATTRIBUTION.md from WP4; cross-check the production artifact and manifest. Verify exact per-sentence license identifiers, contributor/sentence/source provenance and Unicode License V3. WP1's original evaluation corpus remains MIT and is not described as Tatoeba. Core resource copies must byte-match their originals in both build outputs. Root NOTICE currently at lines 1–12 lists earlier dependencies; WP4 owns adding the new notices.

Run this read-only check after WP4 has shipped its artifact/manifest:

```bash
python3 - <<'PY'
import hashlib,json
from pathlib import Path
root=Path.cwd()
base=root/'Sources/AINotebookCore/Resources/Language'
artifact_path=base/'lang-detector-v1.json'
manifest=json.loads((base/'lang-detector-v1.manifest.json').read_text())
artifact=json.loads(artifact_path.read_text())
assert hashlib.sha256(artifact_path.read_bytes()).hexdigest()==manifest['artifactSha256']
assert artifact['kind']=='production'
assert artifact['attribution']==manifest['attribution']
a=manifest['attribution']
assert a['sourceIds'] and a['licenseIds']
for path_key,hash_key in [('noticePath','noticeSha256'),('attributionPath','attributionSha256')]:
    path=(root/a[path_key]).resolve()
    assert path.is_relative_to(root.resolve()), 'attribution path escapes repository'
    assert path.is_file(), path
    assert hashlib.sha256(path.read_bytes()).hexdigest()==a[hash_key], path
assert (root/'NOTICE').is_file()
assert (root/'tools/lang/ATTRIBUTION.md').is_file()
assert (base/'UNICODE-LICENSE.txt').is_file()
print('PASS: production artifact and attribution hashes')
PY
```

Expected: exact PASS line. Follow WP4's packaged-resource tests to check bundled copies; a source-tree hash alone does not certify an installer. If NOTICE/attribution correction is needed, fail this task's release prerequisite and return the concrete correction to WP4's owner for atomic hash/resource regeneration. Do not append prose to NOTICE in this documentation commit.

- [ ] **Step 4 — record the privacy allowlist review.** Existing `.github/workflows/core-ci.yml:33–44` allows only `Providers/`, `OllamaClient.swift`, `WebExtractor.swift` for Core URLSession. Repeat that check without modifying the workflow:

```bash
python3 - <<'PY'
from pathlib import Path
swift=Path('Sources/AINotebookCore')
bad=[]
for p in swift.rglob('*.swift'):
    rel=p.relative_to(swift)
    if 'URLSession' in p.read_text() and not (
        rel.parts[0]=='Providers' or str(rel) in {'OllamaClient.swift','WebExtractor.swift'}):
        bad.append(str(p))
assert not bad, bad
win=Path('windows/src/AINotebook.Core')
allowed={'Ollama/OllamaClient.cs','Extractors/WebTextExtractor.cs','UpdateChecker.cs'}
bad=[]
for p in win.rglob('*.cs'):
    rel=p.relative_to(win)
    if any(part in {'bin','obj'} for part in rel.parts): continue
    if any(t in p.read_text() for t in ('HttpClient','HttpRequestMessage','WebRequest','TcpClient','Socket(')):
        if rel.parts[0]!='Providers' and rel.as_posix() not in allowed: bad.append(str(p))
assert not bad,bad
print('PASS: existing network boundaries; no new exception')
PY
```

The Windows footprint is a reviewed audit, not a newly claimed CI job: existing exceptions include UpdateChecker.cs:18,35–40. Fake transports are test files and add no production networking. If a new type only references a networking interface outside these boundaries, inspect the actual code and return the owning change for review; do not add a blanket directory exception.

- [ ] **Step 5 — create the evidence record with real numbers.** Required content, all tied to a full candidate commit and command output:

| Evidence | Required actual recorded fields/criterion |
|---|---|
| Both Core suites | before/after passed/failed/skipped counts; exact commands, toolchain versions, commit; all seven release scenarios and zero skipped contract cases |
| Windows | App build and App test totals, CI run URL, smoke exit/marker, runner image; specific reviewed exception only if runner capability was proven missing |
| Native scenarios | links to both completed verification records with tested commit/date/person; new fixes require rerun of affected steps |
| Eval | report paths and SHA-256; model/provider identity, dimensions, query/doc/chunker formats, corpus hashes; lexical, candidate and packed-evidence recall, citation correctness, scope/absence cases; agreed numeric acceptance target and measured result |
| Detector | production artifact and manifest digests; held-out report `docs/eval/language-detector-v1.md`; acceptedError, csSkConfusion, foreignAcceptance raw numerators/denominators; language/bucket acceptance coverage and disabled buckets |
| Performance, separately macOS/Windows | exact CPU/RAM/OS, selected dims, 200 queries, warm timing after question embedding at 100K; **p95 < 300 ms**, actual p50/p95/p99 and peak/cache memory; 200K characterization, cold/end-to-end and concurrent-ingestion measurements; measured exceptions require named joint signoff |
| Calibration/defaults | final model choice and alternatives' measured tradeoffs from WP7; calibrated estimator version/model-family coverage; existing indexes preserved; no placeholder token estimator used for release |
| Licensing/privacy | attribution hash check and packaged-copy checks, exact accepted license identifiers, allowlist review output, no secret in saved preview/fixture/log |

Detector comparisons use integer cross-products: accepted errors `10000*n <= 200*d`; cs/sk confusion and foreign acceptance `10000*n <= 100*d`; denominators must be positive and WP4 support minima satisfied on held-out test data. Rounded basis points and disabled buckets do not excuse insufficient support. A historical report with a different artifact/corpus/backend/dimensions does not pass the current gate.

No blank metric cells, synthetic timings or unchecked “passed” labels. If any prerequisite is missing, the file explicitly describes the failed gate and Task 10 cannot start. Do not relabel the older W4 48-chunk retrieval results as WP7 numbers.

- [ ] **Step 6 — review and commit.** Run the pre-bump acceptance commands defined in the WP gate below: all non-version criteria must pass, while VERSION and both guarded constants still agree on 0.14.0. Then run `git diff --check`. Inspect relative Markdown links resolve to existing report/docs files, and reread every 0.15.0 feature claim against the recorded tests/manual steps. Documentation-only changes need no invented failing unit test. Preserve all existing code tests.

```bash
git add README.md docs/roadmap.md CHANGELOG.md docs/releases/0.15.0-release-evidence.md
git commit -m "docs(release): document folder chat and record acceptance evidence" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 10: [Shared] Bump all version sources once and hand off the release

**Depends on:** 9 and all pre-bump acceptance criteria passed on the integrated candidate (the three version sources still agree on 0.14.0). **Parallel with:** none. **Files:** Task 10's three version files and evidence record only. Existing version tests are read-only.

**Interfaces — Consumes:** Swift global `public let AINotebookVersion = "0.14.0"` (`AINotebookVersion.swift:4`); C# `public static class AINotebookVersion { public const string Current = "0.14.0"; }` (`AINotebookVersion.cs:7`); repository VERSION line 1. **Produces:** all three report `0.15.0`, with the same public names/signatures. Existing tests read the actual root VERSION (Swift `AINotebookVersionTests.swift:8–22`; C# `AINotebookVersionTests.cs:8–15` and csproj:29–33).

- [ ] **Step 1 — meaningful red version guards.** Change **only VERSION** to `0.15.0` plus LF. Run:

```bash
swift test --filter AINotebookVersionTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~AINotebookVersionTests
```

Expected: equality test fails on each platform (`0.14.0` constant versus `0.15.0` VERSION); semver-shape test remains green. Do not use `--no-build`: Windows must recopy VERSION. Do not commit this intentionally inconsistent state.

- [ ] **Step 2 — update both constants, without changing test expectations.**

```swift
public let AINotebookVersion = "0.15.0"
```

```csharp
public const string Current = "0.15.0";
```

Run the same two filtered commands → **2/2 guards green on each platform**; run both full suites and Windows App build/tests/smoke once on the final version. Record final test totals, version 0.15.0, the tested parent commit and the exact three-file version delta in the evidence record. Supply the resulting commit hash in the post-commit handoff; do not put a commit's own hash into its contents. No version constant elsewhere is independently bumped; release workflows consume VERSION.

- [ ] **Step 3 — commit and check clean state.**

```bash
git diff --check
git add VERSION Sources/AINotebookCore/AINotebookVersion.swift windows/src/AINotebook.Core/AINotebookVersion.cs docs/releases/0.15.0-release-evidence.md
git commit -m "release: prepare AI Notebook 0.15.0" -m "Co-Authored-By: Codex <noreply@openai.com>"
git status --short
git log -1 --format=%B
```

Expected: no uncommitted output, last commit's final line is the co-author trailer. Provide Claude the complete commit list, exact files, before/after Core counts, Windows CI/App/smoke result, manual records, measured gate summary and any joint exceptions. Version bump alone never closes an unmet gate.

- [ ] **Step 4 — prepare a concrete PR handoff; Claude performs remote actions after user approval.** The evidence record includes the proposed title `Release 0.15.0: folder chat and multilingual evidence` and a body explaining persisted folder ingestion, scoped prepared requests/citation snapshots, v19 upgrade, provider behavior, measured default model and validation links. Use the actual record values, not the planning baseline.

Before asking for approval, Claude assembles the final diff, green CI/manual/eval/perf evidence, commit list and PR body. After the user explicitly approves PR creation/publication, Claude pushes the reviewed feature branch and creates the PR to main (write the body to a temporary file; `gh pr create --base main --title 'Release 0.15.0: folder chat and multilingual evidence' --body-file /private/tmp/ainotebook-0.15.0-pr.md`). Record the returned PR URL. Merge and tag need that approval to explicitly cover them as well; PR creation approval alone does not authorize release publication.

After approved merge and required main checks, Claude tags the verified merge commit with `v0.15.0` and pushes that tag. `.github/workflows/macos-release.yml:5` and `windows-release.yml:5` trigger publication on version tags; workers must not run those steps. Do not bake a guessed PR number or feature branch into this plan. No `gh pr merge`, main merge or tag push occurs in a Codex task.

## WP gate

Execute on the integrated release candidate, not independently green branches. Task 9 performs **pre-bump acceptance**: every criterion below except the final target version must pass, and existing guards verify all three version sources agree on 0.14.0. Task 10 then performs the **final post-bump gate** on 0.15.0, rerunning both Core suites, version guards, Windows App build/tests/smoke and generator checks. Evidence for unchanged native/eval/performance inputs remains valid only with the recorded commit/delta rationale. Record exact commands, exit status, test counts and report digests in `docs/releases/0.15.0-release-evidence.md`. The clean-tree check is performed after each task commits its authorized files.

```bash
swift test
dotnet test windows/tests/AINotebook.Core.Tests
python3 -B tools/contracts/gen_fixtures.py --check
python3 -B tools/contracts/gen_provider_fixtures.py --check
python3 -B tools/contracts/gen_storage_fixtures.py --check
python3 -B tools/contracts/gen_retrieval_fixtures.py --check
python3 -B tools/contracts/gen_ingestion_fixtures.py --check
python3 -B tools/contracts/gen_release_fixtures.py --check
python3 -B tools/eval/update_eval_hashes.py --check
python3 -B tools/eval/gen_eval_fixtures.py --check
python3 -B -m unittest discover -s tools/contracts -p 'test_*.py' -v
python3 -B -m unittest discover -s tools/eval -p 'test_eval_*.py' -v
python3 -B -m unittest discover -s tools/unicode/tests -p 'test_*.py' -v
python3 -B -m unittest discover -s tools/lang/tests -p 'test_*.py' -v
swift test --filter LanguageReleaseTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~LanguageReleaseTests
git diff --check
git status --short
```

Expected: every generator exits 0; all suites pass; no skipped release/contract scenarios; whitespace check and working tree clean. Missing upstream scripts/resources fail readiness, not an optional skip. Native filesystem platform tests run on their appropriate CI OS; shared deterministic cases remain mandatory on both Core runtimes.

Unicode regeneration check uses WP4's pinned, already acquired UCD inputs and separate license (actual recipe `tools/unicode/README.md:41`):

```bash
python3 -B tools/unicode/gen_tables.py --ucd-dir /private/tmp/ainotebook-ucd --license-file /private/tmp/ainotebook-ucd/license.txt --check
```

Expected: byte-identical tables and pinned hashes. Missing acquisition files require restoring the recorded WP4 inputs; never substitute the host Unicode version. WP4's full held-out evaluation must have passed for the exact shipped artifact. To independently rerun it using the existing acquired corpus without altering upstream-owned reports:

```bash
mkdir -p /private/tmp/ainotebook-wp9-eval
python3 -B tools/lang/evaluate_detector.py --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json --config tools/lang/training-v1.json --artifact Sources/AINotebookCore/Resources/Language/lang-detector-v1.json --manifest Sources/AINotebookCore/Resources/Language/lang-detector-v1.manifest.json --wp1-documents Tests/fixtures/lang/wp1-documents-v1.json --work-dir /private/tmp/ainotebook-wp9-eval/work --fixture-output /private/tmp/ainotebook-wp9-eval/lang-release-v1.json --metrics-output /private/tmp/ainotebook-wp9-eval/lang-release-v1.metrics.json --report /private/tmp/ainotebook-wp9-eval/language-detector-v1.md --native-parity --gate
```

Expected: gate exit 0 and native parity, raw counts and report match the recorded WP4 gate for the same artifact/corpus. No network acquisition or retraining is hidden in WP9. Production-manifest exporter commit remains the recorded training/export commit, not the later release HEAD.

On Windows:

```powershell
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.Core.Tests -c Release
```

Run the Task 6 smoke step verbatim; require exit 0 plus valid result marker or the specific documented runner exception with completed manual Windows evidence. The CI workflow retains mandatory build and App tests in either case. Both manual checklist records must be completed on the release candidate or on an ancestor whose later changes do not affect those steps, with that reasoning recorded.

Final criteria: real v18 upgrade and all seven integration scenarios pass on both platforms; all malformed citation/glob/API-root/budget/eligibility/jobs/Overview/coverage fixtures remain green; paired prepared transport captures and persisted snapshots agree; no networking allowlist expansion; Tatoeba/Unicode attribution and bundled copies verify; WP7 report and calibrated estimator are present with the chosen default/dimensions; packed-evidence/citation/detector targets pass; actual warm p95 is **strictly below 300 ms at 100K** on both reference platforms, 200K and concurrent ingestion characterized or a named jointly approved exception; all version sources are 0.15.0; complete reviewable PR handoff exists. Missing WP7 results, conversion notice, native verification or approval-dependent publication remains explicitly open, never counted as completed.
