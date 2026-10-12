# WP0 — Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. C#-side tasks (marked **[Codex]**) run in the Codex worktree per the master plan's collaboration protocol.

**Goal:** Freeze every cross-platform contract the release depends on — constants, algorithms, fixture formats, citation v2 — as normative docs plus shared JSON fixtures, and land the first contract types on both platforms green against those fixtures.

**Architecture:** Shared fixtures live at repo root `Tests/fixtures/contracts/` (outside any SwiftPM target, so Swift reads them via `#filePath`, C# copies them into the test output via a linked `None` item). Normative prose lives in `docs/contracts/`. Code in this WP is limited to: a fixture loader, the `RagContractV1` constants and the citations codec (legacy + v2) — everything else is consumed by later WPs' tests.

**Tech Stack:** Swift 6 XCTest, Foundation `JSONDecoder`; .NET 10 xUnit, `System.Text.Json`.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md` · **Master plan:** `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md`

## Completion record (2026-10-09)

Tasks 1–7 are implemented and committed; the checkboxes below record that completed TDD work. Original Windows and detector branches are already merged (`785c50b`, `087c1bf`). Code examples below preserve the implementation plan; the amended normative contract and committed fixtures govern the final behaviour.

Cross-review fix baseline: `swift test` **381 passed**, `dotnet test windows/tests/AINotebook.Core.Tests` **450 passed**, both with zero skipped. After the allowed-file fixes, the generator check passes and .NET reports **459 passed**; Swift executes **381 tests with two assertion failures** in the shared citation fixture test (negative-double overflow). The additional Swift source fix requires expansion of this task's allowed files, so the overall gate remains pending; no test has been weakened or skipped. These fixes amend unreleased fixtures in place by Claude's binding decision: citations remains v2 and other fixture versions remain v1; no release/version constants change.

The 11 findings have the following contract and reference changes; citation runtime parity still has the additional Swift issue noted above:

1. Validate citation numbers and strings over the whole document before lossy item decoding; overflow/unpaired-surrogate payloads reject valid siblings too, while ordinary invalid items remain lossy. Shared regression cases and C# prevalidation are complete. Unlike the originally reproduced positive overflow, Foundation accepts negative overflow in ignored fields, exposing the pending Swift production fix.
2. Normalize glob separators once with the original anchoring flag; reject slash-only patterns; use pinned Unicode 15.1 simple lowercase.
3. Validate API authorities/ports and catch parser failures; reject userinfo, controls and internal whitespace.
4. Zero evidence target/cap includes no passage and creates no citation.
5. First-passage sentence-prefix candidates carry real costs and scalar ends; debit the chosen prefix, continue packing and redistribute without re-extending it.
6. The map share remains a ceiling during redistribution.
7. Publish fully chunked revisions independently of vector generations; lexical fallback survives no active generation, vector hits retain their own revisions, and GC protects published/pinned revisions.
8. Count attempt starts, stop retries after five, calculate backoff from that count, renew every 60 seconds and fence publication with an unexpired lease token; reference transition fixtures precede WP6 SQL tests.
9. Overview buckets include folder identity with deterministic ties, including permuted duplicate paths; published-chunk candidates and total files are separate counts.
10. Coverage reports searchable corpus separately from disjoint refresh freshness, with doc table cases for an old published revision and failed refresh; WP6 supplies SQL fixtures.
11. SQLite version stays in diagnostics only; FTS still runs real-table assertions; category-stability assertions and pinned glob casing remove host-dependent fixture output.

Remaining integration belongs to Claude: review the fixes and downstream schema consequences, merge this branch, then update the master plan. WP3/WP5 implement the revised publication/retrieval SQL, WP4 bundles `UnicodeTables`, and WP6 adds coverage/concurrency SQL fixtures. FTS remains provisional until WP5.

## Global Constraints

- Parity: both platforms decode the same fixture files and must produce the same results.
- Constants use **integers only** (bytes, counts, basis points `bp` where 10 000 bp = 100 %) so budget math is identical on both platforms.
- Citation JSON keys are camelCase and identical on both platforms (`marker`, `chunkId`, `sourceId`, `snippet`, …).
- Malformed `citations_json` must never throw while loading messages. Before lossy per-item decoding, any number token that cannot parse as a finite double or any string/property name with an unpaired surrogate rejects the whole document, including unknown nested fields. Other bad citation items are skipped individually (§13 of the normative contract).
- Windows store: every `SqliteConnection` access inside `lock (_gate)`.
- Codex: `-c 'model="gpt-6-astra"'`, worktree `../AI_Notebook-codex`, branch `wp0-codex`, only `windows/**`, `docs/contracts/lang-detector-v1.md` and `Tests/fixtures/contracts/lang-*.json`. Task 5 branches from the commit containing Tasks 1–4 (+3b); Task 7 needs only Task 1.
- JSON integer ranges: `marker` 1…2 147 483 647 (Int32), ids and offsets 0…2^53−1 (Int64, JSON-safe). Finite fractional/exponent numbers, out-of-range values or wrong kinds make that **item** invalid; non-finite-double tokens reject the **whole document**. Comparisons of JSON output are **structural**, never byte-wise.

## File Structure

| File | Responsibility |
|---|---|
| `Tests/fixtures/README.md` | Fixture format rules (envelope, canonical JSON, ownership) |
| `Tests/fixtures/contracts/constants-v1.json` | All ⚙ constants, frozen |
| `Tests/fixtures/contracts/citations-v2.json` | Decode/encode cases for `citations_json` |
| `Tests/fixtures/contracts/{api-root,glob,fts-query,budget,diversity,legacy-generation,overview,job-transitions}-v1.json` | Case tables consumed by WP2/3/5/6/8 tests |
| `docs/contracts/folder-rag-v1.md` | Normative algorithms (Claude) |
| `docs/contracts/lang-detector-v1.md` | Normative detector appendix (Codex) |
| `Tests/AINotebookCoreTests/SharedFixtures.swift` | Swift loader for `Tests/fixtures/` |
| `Sources/AINotebookCore/RagContractV1.swift` | Swift constants |
| `Sources/AINotebookCore/CitationsCodec.swift` | Swift legacy+v2 codec; `Citation` gains optional v2 fields |
| `windows/tests/AINotebook.Core.Tests/Helpers/SharedFixtures.cs` | C# loader |
| `windows/src/AINotebook.Core/Rag/RagContractV1.cs` | C# constants |
| `windows/src/AINotebook.Core/Storage/CitationsCodec.cs` | C# codec; `Citation` record gains optional v2 fields |

---

### Task 1: Freeze constants with Codex

**Files:**
- Create: `Tests/fixtures/README.md`
- Create: `Tests/fixtures/contracts/constants-v1.json`

**Interfaces:**
- Produces: `constants-v1.json` keys used verbatim by Task 3 (`RagContractV1`) and every later WP.

- [x] **Step 1: Write the proposal file**

`Tests/fixtures/contracts/constants-v1.json`:

```json
{
  "contract": "constants",
  "version": 1,
  "scan": {
    "maxFileBytes": 52428800,
    "maxOfficeDecompressedBytes": 209715200,
    "maxExtractedChars": 5000000,
    "maxPdfPages": 2000,
    "maxChunksPerFile": 5000,
    "extractionConcurrency": 2,
    "periodicReconcileMinutes": 30,
    "watchDebounceMs": 500,
    "watchMaxCoalesceMs": 5000
  },
  "detector": {
    "maxUnigrams": 256,
    "maxBigrams": 1024,
    "maxTrigrams": 4096,
    "orderWeights": [1, 2, 3],
    "scoreScale": 1024,
    "lengthBucketStarts": [12, 32, 80, 200],
    "minLetters": 12,
    "minWords": 3,
    "mixedDominanceBp": 7000
  },
  "retrieval": {
    "rrfK": 60,
    "fetchK": 32,
    "topK": 16,
    "maxFtsTokens": 32
  },
  "cache": {
    "globalBudgetBytes": 536870912
  },
  "pack": {
    "evidenceShareBp": 6000,
    "mapMaxShareBp": 1500,
    "noteWebMaxShareBp": 1500,
    "tokenEstimateHeadroomBp": 1500,
    "diversityPenaltyBp": 9000,
    "maxPassages": 40,
    "neighborRadius": 1,
    "previewTurnsInMemory": 5,
    "previewMaxBytes": 33554432
  },
  "providers": {
    "defaultRuntimeContext": 8192,
    "defaultMaxOutputTokens": 1024
  },
  "perf": {
    "warmRetrievalP95Ms": 300,
    "perfCorpusChunks": [100000, 200000]
  }
}
```

- [x] **Step 2: Write `Tests/fixtures/README.md`**

```markdown
# Shared fixtures

Consumed by BOTH `swift test` (via `#filePath`, see `Tests/AINotebookCoreTests/SharedFixtures.swift`)
and `dotnet test windows/tests/AINotebook.Core.Tests` (linked into the test output as `SharedFixtures/`).

Every contract fixture is a JSON object with an envelope:

    { "contract": "<name>", "version": <int>, ... , "cases": [ { "name": "<unique>", ... } ] }

`constants-v1.json` has no `cases`. Rules:
- Integers only for anything used in arithmetic (basis points: 10000 bp = 100 %).
- UTF-8, no BOM, LF line endings; strings that test Unicode use literal characters, not escapes, unless the case is about escapes.
- Changing a fixture changes the contract: bump `version` (new file `*-v2.json`), never edit a frozen version.
- Ownership: `lang-*` fixtures = Codex; all others = Claude. Both review.
```

- [x] **Step 3: Confirm with Codex (consult, read-only)**

**Done 2026-10-09** (Codex consult): all values KEEP except `diversityPenaltyBp` 7000→9000 and `previewTurnsInMemory` 20→5; added `scan.watchMaxCoalesceMs` 5000, `pack.previewMaxBytes` 33554432, `providers.defaultMaxOutputTokens` 1024 (already reflected in Step 1 above). Semantics recorded in `folder-rag-v1.md`: `maxExtractedChars` counts Unicode scalars; `globalBudgetBytes` is a ceiling (indexes above it stream); `topK` is an upper bound after selection. **WP0 freezes contract structure and the initial parameter set; WP4/WP7 may jointly supersede tuning values with a versioned `constants-v2.json` before release.**

- [x] **Step 4: Commit**

```bash
git add Tests/fixtures/README.md Tests/fixtures/contracts/constants-v1.json
git commit -m "contracts: freeze RAG constants v1 (joint Claude+Codex)"
```

### Task 2: Shared fixture loader — Swift

**Files:**
- Create: `Tests/AINotebookCoreTests/SharedFixtures.swift`
- Test: `Tests/AINotebookCoreTests/SharedFixturesTests.swift`

**Interfaces:**
- Produces: `SharedFixtures.url(_ relativePath: String) -> URL`, `SharedFixtures.data(_:) throws -> Data`, `SharedFixtures.json(_:) throws -> [String: Any]`, `SharedFixtures.contractFiles() throws -> [URL]`.

- [x] **Step 1: Write the failing test**

```swift
import XCTest

final class SharedFixturesTests: XCTestCase {
    func testConstantsFixtureLoads() throws {
        let obj = try SharedFixtures.json("contracts/constants-v1.json")
        XCTAssertEqual(obj["contract"] as? String, "constants")
        XCTAssertEqual(obj["version"] as? Int, 1)
    }

    /// Every contract fixture must carry the envelope; case names must be unique.
    func testEveryContractFixtureHasEnvelope() throws {
        let files = try SharedFixtures.contractFiles()
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let obj = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                url.lastPathComponent)
            XCTAssertNotNil(obj["contract"] as? String, url.lastPathComponent)
            XCTAssertNotNil(obj["version"] as? Int, url.lastPathComponent)
            if url.lastPathComponent.hasPrefix("constants-") { continue }
            let cases = try XCTUnwrap(obj["cases"] as? [[String: Any]], url.lastPathComponent)
            let names = cases.compactMap { $0["name"] as? String }
            XCTAssertEqual(names.count, cases.count, "every case needs a name: \(url.lastPathComponent)")
            XCTAssertEqual(Set(names).count, names.count, "duplicate case name: \(url.lastPathComponent)")
        }
    }
}
```

- [x] **Step 2: Run to verify it fails**

Run: `swift test --filter SharedFixturesTests`
Expected: FAIL — `cannot find 'SharedFixtures' in scope`.

- [x] **Step 3: Implement**

```swift
import Foundation

/// Repo-root `Tests/fixtures/` — shared with the Windows test suite. Lives
/// outside the SwiftPM test target, so it is located via `#filePath`
/// (same pattern as AINotebookVersionTests).
enum SharedFixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AINotebookCoreTests/
        .deletingLastPathComponent()   // Tests/
        .appendingPathComponent("fixtures", isDirectory: true)

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    static func json(_ relativePath: String) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data(relativePath)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return obj
    }

    static func contractFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: url("contracts"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
```

- [x] **Step 4: Run to verify it passes**

Run: `swift test --filter SharedFixturesTests` → PASS (2 tests).

- [x] **Step 5: Commit**

```bash
git add Tests/AINotebookCoreTests/SharedFixtures.swift Tests/AINotebookCoreTests/SharedFixturesTests.swift
git commit -m "test: shared fixture loader for Swift suite"
```

### Task 3: `RagContractV1` constants — Swift

**Files:**
- Create: `Sources/AINotebookCore/RagContractV1.swift`
- Test: `Tests/AINotebookCoreTests/RagContractV1Tests.swift`

**Interfaces:**
- Consumes: `SharedFixtures.json` (Task 2), `constants-v1.json` (Task 1).
- Produces: `RagContractV1.Scan/Detector/Retrieval/Cache/Pack/Providers/Perf` static `Int`/`Int64`/`[Int]` members named exactly as the JSON keys.

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AINotebookCore

/// The in-code constants must equal the frozen shared fixture — the Windows
/// suite runs the same comparison, which is what keeps the platforms equal.
final class RagContractV1Tests: XCTestCase {
    private func section(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try SharedFixtures.json("contracts/constants-v1.json")[name] as? [String: Any])
    }

    func testScan() throws {
        let s = try section("scan")
        XCTAssertEqual(Int64(s["maxFileBytes"] as! Int), RagContractV1.Scan.maxFileBytes)
        XCTAssertEqual(Int64(s["maxOfficeDecompressedBytes"] as! Int), RagContractV1.Scan.maxOfficeDecompressedBytes)
        XCTAssertEqual(s["maxExtractedChars"] as? Int, RagContractV1.Scan.maxExtractedChars)
        XCTAssertEqual(s["maxPdfPages"] as? Int, RagContractV1.Scan.maxPdfPages)
        XCTAssertEqual(s["maxChunksPerFile"] as? Int, RagContractV1.Scan.maxChunksPerFile)
        XCTAssertEqual(s["extractionConcurrency"] as? Int, RagContractV1.Scan.extractionConcurrency)
        XCTAssertEqual(s["periodicReconcileMinutes"] as? Int, RagContractV1.Scan.periodicReconcileMinutes)
        XCTAssertEqual(s["watchDebounceMs"] as? Int, RagContractV1.Scan.watchDebounceMs)
        XCTAssertEqual(s["watchMaxCoalesceMs"] as? Int, RagContractV1.Scan.watchMaxCoalesceMs)
    }

    func testDetector() throws {
        let d = try section("detector")
        XCTAssertEqual(d["maxUnigrams"] as? Int, RagContractV1.Detector.maxUnigrams)
        XCTAssertEqual(d["maxBigrams"] as? Int, RagContractV1.Detector.maxBigrams)
        XCTAssertEqual(d["maxTrigrams"] as? Int, RagContractV1.Detector.maxTrigrams)
        XCTAssertEqual(d["orderWeights"] as? [Int], RagContractV1.Detector.orderWeights)
        XCTAssertEqual(d["scoreScale"] as? Int, RagContractV1.Detector.scoreScale)
        XCTAssertEqual(d["lengthBucketStarts"] as? [Int], RagContractV1.Detector.lengthBucketStarts)
        XCTAssertEqual(d["minLetters"] as? Int, RagContractV1.Detector.minLetters)
        XCTAssertEqual(d["minWords"] as? Int, RagContractV1.Detector.minWords)
        XCTAssertEqual(d["mixedDominanceBp"] as? Int, RagContractV1.Detector.mixedDominanceBp)
    }

    func testRetrievalCacheProvidersPerf() throws {
        let r = try section("retrieval")
        XCTAssertEqual(r["rrfK"] as? Int, RagContractV1.Retrieval.rrfK)
        XCTAssertEqual(r["fetchK"] as? Int, RagContractV1.Retrieval.fetchK)
        XCTAssertEqual(r["topK"] as? Int, RagContractV1.Retrieval.topK)
        XCTAssertEqual(r["maxFtsTokens"] as? Int, RagContractV1.Retrieval.maxFtsTokens)
        XCTAssertEqual(Int64(try section("cache")["globalBudgetBytes"] as! Int), RagContractV1.Cache.globalBudgetBytes)
        XCTAssertEqual(try section("providers")["defaultRuntimeContext"] as? Int, RagContractV1.Providers.defaultRuntimeContext)
        XCTAssertEqual(try section("providers")["defaultMaxOutputTokens"] as? Int, RagContractV1.Providers.defaultMaxOutputTokens)
        let p = try section("perf")
        XCTAssertEqual(p["warmRetrievalP95Ms"] as? Int, RagContractV1.Perf.warmRetrievalP95Ms)
        XCTAssertEqual(p["perfCorpusChunks"] as? [Int], RagContractV1.Perf.perfCorpusChunks)
    }

    func testPack() throws {
        let p = try section("pack")
        XCTAssertEqual(p["evidenceShareBp"] as? Int, RagContractV1.Pack.evidenceShareBp)
        XCTAssertEqual(p["mapMaxShareBp"] as? Int, RagContractV1.Pack.mapMaxShareBp)
        XCTAssertEqual(p["noteWebMaxShareBp"] as? Int, RagContractV1.Pack.noteWebMaxShareBp)
        XCTAssertEqual(p["tokenEstimateHeadroomBp"] as? Int, RagContractV1.Pack.tokenEstimateHeadroomBp)
        XCTAssertEqual(p["diversityPenaltyBp"] as? Int, RagContractV1.Pack.diversityPenaltyBp)
        XCTAssertEqual(p["maxPassages"] as? Int, RagContractV1.Pack.maxPassages)
        XCTAssertEqual(p["neighborRadius"] as? Int, RagContractV1.Pack.neighborRadius)
        XCTAssertEqual(p["previewTurnsInMemory"] as? Int, RagContractV1.Pack.previewTurnsInMemory)
        XCTAssertEqual(Int64(p["previewMaxBytes"] as! Int), RagContractV1.Pack.previewMaxBytes)
    }

    func testRetrievalInvariant() {
        XCTAssertGreaterThanOrEqual(RagContractV1.Retrieval.fetchK, RagContractV1.Retrieval.topK)
        XCTAssertGreaterThan(RagContractV1.Retrieval.topK, 0)
    }
}
```

- [x] **Step 2: Run to verify it fails**

Run: `swift test --filter RagContractV1Tests` → FAIL, `cannot find 'RagContractV1'`.

- [x] **Step 3: Implement** — values from the confirmed `constants-v1.json` (Codex review 2026-10-09 applied: diversity 9000 bp, 5 preview turns, +previewMaxBytes, +defaultMaxOutputTokens, +watchMaxCoalesceMs). `retrieval.topK` is an **upper bound after selection**, never a count that must fit (at 8192 context ≈ 4 full Czech chunks fit).

```swift
/// Frozen cross-platform constants (contract v1). Mirrors
/// `Tests/fixtures/contracts/constants-v1.json`; RagContractV1Tests and the
/// Windows twin fail if either side drifts. Integers only — shares are basis
/// points (10_000 bp = 100 %), so budget math is identical on both platforms.
public enum RagContractV1 {
    public enum Scan {
        public static let maxFileBytes: Int64 = 52_428_800
        public static let maxOfficeDecompressedBytes: Int64 = 209_715_200
        public static let maxExtractedChars = 5_000_000
        public static let maxPdfPages = 2_000
        public static let maxChunksPerFile = 5_000
        public static let extractionConcurrency = 2
        public static let periodicReconcileMinutes = 30
        public static let watchDebounceMs = 500
        public static let watchMaxCoalesceMs = 5_000
    }
    public enum Detector {
        public static let maxUnigrams = 256
        public static let maxBigrams = 1_024
        public static let maxTrigrams = 4_096
        public static let orderWeights = [1, 2, 3]
        public static let scoreScale = 1_024
        public static let lengthBucketStarts = [12, 32, 80, 200]
        public static let minLetters = 12
        public static let minWords = 3
        public static let mixedDominanceBp = 7_000
    }
    public enum Retrieval {
        public static let rrfK = 60
        public static let fetchK = 32
        public static let topK = 16
        public static let maxFtsTokens = 32
    }
    public enum Cache {
        public static let globalBudgetBytes: Int64 = 536_870_912
    }
    public enum Pack {
        public static let evidenceShareBp = 6_000
        public static let mapMaxShareBp = 1_500
        public static let noteWebMaxShareBp = 1_500
        public static let tokenEstimateHeadroomBp = 1_500
        public static let diversityPenaltyBp = 9_000
        public static let maxPassages = 40
        public static let neighborRadius = 1
        public static let previewTurnsInMemory = 5
        public static let previewMaxBytes: Int64 = 33_554_432
    }
    public enum Providers {
        public static let defaultRuntimeContext = 8_192
        public static let defaultMaxOutputTokens = 1_024
    }
    public enum Perf {
        public static let warmRetrievalP95Ms = 300
        public static let perfCorpusChunks = [100_000, 200_000]
    }
}
```

- [x] **Step 4: Run** `swift test --filter RagContractV1Tests` → PASS (5 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/RagContractV1.swift Tests/AINotebookCoreTests/RagContractV1Tests.swift
git commit -m "feat(core): RagContractV1 constants pinned to shared fixture"
```

### Task 3b: `RetrievalScope` DTO — Swift

**Files:**
- Create: `Tests/fixtures/contracts/scope-v1.json`
- Create: `Sources/AINotebookCore/RetrievalScope.swift`
- Test: `Tests/AINotebookCoreTests/RetrievalScopeTests.swift`

**Interfaces:**
- Produces: `public enum RetrievalScope: Equatable, Hashable, Sendable, Codable { case all; case selection(sourceIds: Set<Int64>, folderIds: Set<Int64>) }`, `var isEmptySelection: Bool`, `static func union(_ scopes: [RetrievalScope]) -> RetrievalScope` (any `.all` → `.all`; else set unions). JSON: `{"kind":"all"}` / `{"kind":"selection","sourceIds":[…],"folderIds":[…]}` (arrays sorted ascending on encode; duplicates tolerated on decode; unknown `kind` → decode error).

- [x] **Step 1: Write the fixture** `scope-v1.json`:

```json
{
  "contract": "scope",
  "version": 1,
  "cases": [
    { "name": "all", "json": {"kind": "all"}, "isEmptySelection": false },
    { "name": "empty-selection", "json": {"kind": "selection", "sourceIds": [], "folderIds": []}, "isEmptySelection": true },
    { "name": "sources-only", "json": {"kind": "selection", "sourceIds": [3, 1], "folderIds": []}, "isEmptySelection": false, "canonical": {"kind": "selection", "sourceIds": [1, 3], "folderIds": []} },
    { "name": "folders-only", "json": {"kind": "selection", "sourceIds": [], "folderIds": [9]}, "isEmptySelection": false },
    { "name": "duplicates-collapse", "json": {"kind": "selection", "sourceIds": [2, 2], "folderIds": [5, 5]}, "isEmptySelection": false, "canonical": {"kind": "selection", "sourceIds": [2], "folderIds": [5]} },
    { "name": "unknown-kind", "json": {"kind": "everything"}, "error": true }
  ],
  "unionCases": [
    { "name": "union-with-all", "inputs": [{"kind": "selection", "sourceIds": [1], "folderIds": []}, {"kind": "all"}], "expected": {"kind": "all"} },
    { "name": "union-of-selections", "inputs": [{"kind": "selection", "sourceIds": [1], "folderIds": [7]}, {"kind": "selection", "sourceIds": [2], "folderIds": [7]}], "expected": {"kind": "selection", "sourceIds": [1, 2], "folderIds": [7]} },
    { "name": "union-empty-list", "inputs": [], "expected": {"kind": "selection", "sourceIds": [], "folderIds": []} }
  ]
}
```

- [x] **Step 2: Write the failing test**

```swift
import XCTest
@testable import AINotebookCore

final class RetrievalScopeTests: XCTestCase {
    private func decode(_ any: Any) throws -> RetrievalScope {
        try JSONDecoder().decode(RetrievalScope.self, from: JSONSerialization.data(withJSONObject: any))
    }
    private func canonicalObject(_ scope: RetrievalScope) throws -> NSDictionary {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(scope)) as? NSDictionary)
    }

    func testSharedCases() throws {
        let file = try SharedFixtures.json("contracts/scope-v1.json")
        for c in try XCTUnwrap(file["cases"] as? [[String: Any]]) {
            let name = c["name"] as! String
            if c["error"] as? Bool == true {
                XCTAssertThrowsError(try decode(c["json"]!), name)
                continue
            }
            let scope = try decode(c["json"]!)
            XCTAssertEqual(scope.isEmptySelection, c["isEmptySelection"] as? Bool, name)
            let expected = (c["canonical"] ?? c["json"]) as! NSDictionary
            XCTAssertEqual(try canonicalObject(scope), expected, name)
        }
        for c in try XCTUnwrap(file["unionCases"] as? [[String: Any]]) {
            let inputs = try (c["inputs"] as! [Any]).map(decode)
            XCTAssertEqual(RetrievalScope.union(inputs), try decode(c["expected"]!), c["name"] as? String ?? "")
        }
    }
}
```

- [x] **Step 3: Run** `swift test --filter RetrievalScopeTests` → FAIL (`RetrievalScope` undefined).

- [x] **Step 4: Implement**

```swift
/// Chat retrieval scope (contract v1, `docs/contracts/folder-rag-v1.md` §1).
/// `.selection` is the union of explicit sources and the *current* members of
/// the listed folders; an empty selection means zero results, never "all".
public enum RetrievalScope: Equatable, Hashable, Sendable, Codable {
    case all
    case selection(sourceIds: Set<Int64>, folderIds: Set<Int64>)

    public var isEmptySelection: Bool {
        if case let .selection(s, f) = self { return s.isEmpty && f.isEmpty }
        return false
    }

    public static func union(_ scopes: [RetrievalScope]) -> RetrievalScope {
        var sources = Set<Int64>(), folders = Set<Int64>()
        for scope in scopes {
            switch scope {
            case .all: return .all
            case let .selection(s, f): sources.formUnion(s); folders.formUnion(f)
            }
        }
        return .selection(sourceIds: sources, folderIds: folders)
    }

    private enum CodingKeys: String, CodingKey { case kind, sourceIds, folderIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "all": self = .all
        case "selection":
            self = .selection(
                sourceIds: Set(try c.decode([Int64].self, forKey: .sourceIds)),
                folderIds: Set(try c.decode([Int64].self, forKey: .folderIds)))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown scope kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try c.encode("all", forKey: .kind)
        case let .selection(s, f):
            try c.encode("selection", forKey: .kind)
            try c.encode(s.sorted(), forKey: .sourceIds)
            try c.encode(f.sorted(), forKey: .folderIds)
        }
    }
}
```

- [x] **Step 5: Run** → PASS. **Step 6: Commit**

```bash
git add Tests/fixtures/contracts/scope-v1.json Sources/AINotebookCore/RetrievalScope.swift Tests/AINotebookCoreTests/RetrievalScopeTests.swift
git commit -m "feat(core): RetrievalScope contract type with shared fixture"
```

### Task 4: Citations codec (legacy + v2) — Swift

**Files:**
- Create: `Tests/fixtures/contracts/citations-v2.json`
- Create: `Sources/AINotebookCore/CitationsCodec.swift`
- Modify: `Sources/AINotebookCore/ChatMessage.swift` (`Citation` gains optional v2 fields; `init(row:)` and `encode(to:)` use the codec)
- Test: `Tests/AINotebookCoreTests/CitationsCodecTests.swift`

**Interfaces:**
- Produces:
  - `public struct CitationSpan: Equatable, Hashable, Codable, Sendable { start: Int; end: Int; pageFrom: Int?; pageTo: Int? }`
  - `Citation` new optional fields (all default `nil`/empty, existing 4-arg init unchanged): `folderId: Int64?`, `relPath: String?`, `displayName: String?`, `revisionId: Int64?`, `spans: [CitationSpan]`, `chunkIds: [Int64]`, `text: String?`; computed `isV2: Bool` (true iff any of these is set/non-empty).
  - `public enum CitationsCodec { static func decode(_ raw: String?) -> [Citation]; static func encode(_ citations: [Citation]) -> String? }`
- Storage rule: `encode` returns `nil` for empty; a **legacy JSON array** when no citation `isV2` (legacy-only payloads remain readable by older versions; v2 payloads require the new reader); otherwise `{"v":2,"items":[…]}`. `chunkId` stays the compatibility anchor: for merged evidence it is the **first** element of the ordered `chunkIds`. Item validity: required keys present with integer/string kinds in range (Global Constraints), every span has `0 ≤ start < end`, `pageFrom ≤ pageTo` when both present. `decode` accepts nil/empty → `[]`, legacy array, v2 object; unknown `v`, malformed JSON or non-array/object → `[]`; whole-document finite-number/string validation runs before individual undecodable items are skipped (normative contract §13).

- [x] **Step 1: Write the fixture** `Tests/fixtures/contracts/citations-v2.json`

```json
{
  "contract": "citations",
  "version": 2,
  "cases": [
    { "name": "null", "stored": null, "expected": [] },
    { "name": "empty-string", "stored": "", "expected": [] },
    { "name": "malformed", "stored": "{not json", "expected": [] },
    { "name": "unknown-version", "stored": "{\"v\":3,\"items\":[{\"marker\":1,\"chunkId\":1,\"sourceId\":1,\"snippet\":\"x\"}]}", "expected": [] },
    { "name": "legacy-array",
      "stored": "[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"Smlouva končí 31. 12.\"}]",
      "expected": [ { "marker": 1, "chunkId": 10, "sourceId": 2, "snippet": "Smlouva končí 31. 12." } ] },
    { "name": "legacy-skips-bad-item",
      "stored": "[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\"},{\"marker\":\"two\"},{\"marker\":3,\"chunkId\":30,\"sourceId\":4,\"snippet\":\"c\"}]",
      "expected": [ { "marker": 1, "chunkId": 10, "sourceId": 2, "snippet": "a" },
                    { "marker": 3, "chunkId": 30, "sourceId": 4, "snippet": "c" } ] },
    { "name": "v2-full",
      "stored": "{\"v\":2,\"items\":[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"Die Kündigung\",\"folderId\":5,\"relPath\":\"verträge/miete.pdf\",\"displayName\":\"miete.pdf\",\"revisionId\":7,\"spans\":[{\"start\":0,\"end\":120,\"pageFrom\":3,\"pageTo\":3}],\"chunkIds\":[10,11],\"text\":\"Die Kündigung erfolgt schriftlich.\"}]}",
      "expected": [ { "marker": 1, "chunkId": 10, "sourceId": 2, "snippet": "Die Kündigung",
                      "folderId": 5, "relPath": "verträge/miete.pdf", "displayName": "miete.pdf", "revisionId": 7,
                      "spans": [ { "start": 0, "end": 120, "pageFrom": 3, "pageTo": 3 } ],
                      "chunkIds": [10, 11], "text": "Die Kündigung erfolgt schriftlich." } ] },
    { "name": "v2-skips-bad-item-and-ignores-unknown-keys",
      "stored": "{\"v\":2,\"items\":[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\",\"future\":true},{\"chunkId\":11}]}",
      "expected": [ { "marker": 1, "chunkId": 10, "sourceId": 2, "snippet": "a" } ] },
    { "name": "null-required-field", "stored": "[{\"marker\":1,\"chunkId\":null,\"sourceId\":2,\"snippet\":\"a\"}]", "expected": [] },
    { "name": "fractional-number", "stored": "[{\"marker\":1.5,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\"}]", "expected": [] },
    { "name": "exponent-number", "stored": "[{\"marker\":1,\"chunkId\":1e3,\"sourceId\":2,\"snippet\":\"a\"}]", "expected": [] },
    { "name": "marker-overflow-int32", "stored": "[{\"marker\":2147483648,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\"}]", "expected": [] },
    { "name": "string-for-number", "stored": "[{\"marker\":\"1\",\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\"}]", "expected": [] },
    { "name": "malformed-optional-invalidates-item", "stored": "{\"v\":2,\"items\":[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\",\"spans\":\"oops\"},{\"marker\":2,\"chunkId\":11,\"sourceId\":2,\"snippet\":\"b\"}]}",
      "expected": [ { "marker": 2, "chunkId": 11, "sourceId": 2, "snippet": "b" } ] },
    { "name": "invalid-span-end-before-start", "stored": "{\"v\":2,\"items\":[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\",\"spans\":[{\"start\":9,\"end\":3}]}]}", "expected": [] },
    { "name": "duplicate-markers-kept-in-order", "stored": "[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"a\"},{\"marker\":1,\"chunkId\":11,\"sourceId\":2,\"snippet\":\"b\"}]",
      "expected": [ { "marker": 1, "chunkId": 10, "sourceId": 2, "snippet": "a" }, { "marker": 1, "chunkId": 11, "sourceId": 2, "snippet": "b" } ] },
    { "name": "top-level-scalar", "stored": "42", "expected": [] },
    { "name": "v2-items-not-array", "stored": "{\"v\":2,\"items\":{}}", "expected": [] }
  ]
}
```

- [x] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import AINotebookCore

final class CitationsCodecTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let stored: String?
        let expected: [Citation]
    }
    private struct File: Decodable { let cases: [Case] }

    func testSharedFixtureCases() throws {
        let file = try JSONDecoder().decode(File.self, from: SharedFixtures.data("contracts/citations-v2.json"))
        XCTAssertGreaterThanOrEqual(file.cases.count, 18)
        for c in file.cases {
            XCTAssertEqual(CitationsCodec.decode(c.stored), c.expected, c.name)
        }
    }

    func testEncodeEmptyIsNil() {
        XCTAssertNil(CitationsCodec.encode([]))
    }

    func testLegacyOnlyCitationsEncodeAsLegacyArray() throws {
        let raw = try XCTUnwrap(CitationsCodec.encode([
            Citation(marker: 1, chunkId: 10, sourceId: 2, snippet: "a")
        ]))
        XCTAssertTrue(raw.hasPrefix("["), raw)
    }

    func testV2RoundTrip() throws {
        var c = Citation(marker: 2, chunkId: 10, sourceId: 2, snippet: "s")
        c.folderId = 5
        c.relPath = "a/b.md"
        c.spans = [CitationSpan(start: 3, end: 9, pageFrom: nil, pageTo: nil)]
        c.chunkIds = [10]
        c.text = "full passage"
        let raw = try XCTUnwrap(CitationsCodec.encode([c]))
        XCTAssertTrue(raw.hasPrefix("{"), raw)
        XCTAssertEqual(CitationsCodec.decode(raw), [c])
    }

    @MainActor
    func testMessageRowWithCorruptCitationsStillLoads() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "N")
        let session = try store.createChatSession(notebookId: nb.id!, title: "S")
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO messages(session_id, role, content, citations_json, created_at)
                VALUES (?, 'assistant', 'hi', '{broken', ?)
                """, arguments: [session.id!, Date()])
        }
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].citations, [])
    }

    @MainActor
    func testMixedValidInvalidItemsRoundTripThroughStore() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "N")
        let session = try store.createChatSession(notebookId: nb.id!, title: "S")
        let raw = #"[{"marker":1,"chunkId":10,"sourceId":2,"snippet":"ok"},{"marker":"x"}]"#
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO messages(session_id, role, content, citations_json, created_at)
                VALUES (?, 'assistant', 'hi', ?, ?)
                """, arguments: [session.id!, raw, Date()])
        }
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs[0].citations, [Citation(marker: 1, chunkId: 10, sourceId: 2, snippet: "ok")])
    }
}
```

(`NotebookStore(path: .inMemory)`, `createNotebook(name:)`, `createChatSession(notebookId:title:)`, `messages(sessionId:)` and the internal `dbQueue` are the existing APIs used by `NotebookStoreChatTests`.)

- [x] **Step 3: Run to verify failure**

Run: `swift test --filter CitationsCodecTests` → FAIL (`CitationsCodec` / `CitationSpan` undefined, `Citation` not `Decodable` with the v2 shape).

- [x] **Step 4: Implement `Citation` v2 fields** in `ChatMessage.swift` — replace the `Citation` struct:

```swift
public struct CitationSpan: Equatable, Hashable, Codable, Sendable {
    public let start: Int
    public let end: Int
    public let pageFrom: Int?
    public let pageTo: Int?

    public init(start: Int, end: Int, pageFrom: Int?, pageTo: Int?) {
        self.start = start
        self.end = end
        self.pageFrom = pageFrom
        self.pageTo = pageTo
    }
}

public struct Citation: Equatable, Hashable, Codable, Sendable {
    public let marker: Int
    public let chunkId: Int64
    public let sourceId: Int64
    public let snippet: String
    // v2 (context pack) — all optional so legacy rows decode unchanged.
    public var folderId: Int64? = nil
    public var relPath: String? = nil
    public var displayName: String? = nil
    public var revisionId: Int64? = nil
    public var spans: [CitationSpan] = []
    public var chunkIds: [Int64] = []
    public var text: String? = nil

    public init(marker: Int, chunkId: Int64, sourceId: Int64, snippet: String) {
        self.marker = marker
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.snippet = snippet
    }

    var isV2: Bool {
        folderId != nil || relPath != nil || displayName != nil || revisionId != nil
            || !spans.isEmpty || !chunkIds.isEmpty || text != nil
    }

    private enum CodingKeys: String, CodingKey {
        case marker, chunkId, sourceId, snippet
        case folderId, relPath, displayName, revisionId, spans, chunkIds, text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        marker = try c.decode(Int.self, forKey: .marker)
        chunkId = try c.decode(Int64.self, forKey: .chunkId)
        sourceId = try c.decode(Int64.self, forKey: .sourceId)
        snippet = try c.decode(String.self, forKey: .snippet)
        folderId = try c.decodeIfPresent(Int64.self, forKey: .folderId)
        relPath = try c.decodeIfPresent(String.self, forKey: .relPath)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        revisionId = try c.decodeIfPresent(Int64.self, forKey: .revisionId)
        spans = try c.decodeIfPresent([CitationSpan].self, forKey: .spans) ?? []
        chunkIds = try c.decodeIfPresent([Int64].self, forKey: .chunkIds) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text)
        guard (1...Int(Int32.max)).contains(marker), chunkId >= 0, sourceId >= 0,
              spans.allSatisfy({ $0.start >= 0 && $0.start < $0.end
                  && ($0.pageFrom == nil || $0.pageTo == nil || $0.pageFrom! <= $0.pageTo!) })
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "citation out of contract range"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(marker, forKey: .marker)
        try c.encode(chunkId, forKey: .chunkId)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(snippet, forKey: .snippet)
        try c.encodeIfPresent(folderId, forKey: .folderId)
        try c.encodeIfPresent(relPath, forKey: .relPath)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(revisionId, forKey: .revisionId)
        if !spans.isEmpty { try c.encode(spans, forKey: .spans) }
        if !chunkIds.isEmpty { try c.encode(chunkIds, forKey: .chunkIds) }
        try c.encodeIfPresent(text, forKey: .text)
    }
}
```

- [x] **Step 5: Implement `CitationsCodec.swift`** — **as built:** `Sources/AINotebookCore/CitationsCodec.swift`. `JSONDecoder` accepted `1e3` as `Int64` (the `exponent-number` case failed), so `decode` reads items with `JSONSerialization` and strict helpers: integers must be non-boolean, non-float `NSNumber`s within range; a present optional field of the wrong kind invalidates the item; **`null` for an optional field counts as absent**; `spans`/`chunkIds` are all-or-nothing per item. `encode` uses `JSONEncoder` with `.sortedKeys` (legacy array vs `{"v":2,"items":[…]}`). The C# twin implements these semantics using `JsonDocument` and `JsonValueKind.Number` + `TryGetInt64` on the raw text, rejecting tokens containing `.`, `e` or `E` for integer fields. Cross-review adds whole-document prevalidation for finite-double numbers and well-formed decoded strings/property names before either platform decodes individual items.

- [x] **Step 6: Wire into `ChatMessage`** — in `init(row:)` replace the `let cits … ` block with:

```swift
        let cits = CitationsCodec.decode(row[Columns.citationsJson.rawValue] as String?)
```

and in `encode(to:)` replace the `citationsJson` assignment with:

```swift
        container[Columns.citationsJson.rawValue] = CitationsCodec.encode(citations)
```

- [x] **Step 7: Run** `swift test --filter CitationsCodecTests` → PASS (6). The `fractional-number`/`exponent-number` cases verify strict integer-token rejection through the implemented `JSONSerialization` helpers; the cross-review cases additionally verify document-wide rejection and preservation of valid siblings for ordinary invalid items. Then full `swift test` → all green (existing citation tests still pass because legacy encoding is unchanged).

- [x] **Step 8: Commit**

```bash
git add Tests/fixtures/contracts/citations-v2.json Sources/AINotebookCore/CitationsCodec.swift Sources/AINotebookCore/ChatMessage.swift Tests/AINotebookCoreTests/CitationsCodecTests.swift
git commit -m "feat(core): citations codec with v2 fields and lossy legacy decoding"
```

### Task 5: [Codex] Windows twins of Tasks 2–4 (incl. 3b)

**Files:**
- Modify: `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj` (link shared fixtures)
- Create: `windows/tests/AINotebook.Core.Tests/Helpers/SharedFixtures.cs`
- Create: `windows/tests/AINotebook.Core.Tests/SharedFixturesTests.cs`
- Create: `windows/src/AINotebook.Core/Rag/RagContractV1.cs`
- Create: `windows/tests/AINotebook.Core.Tests/Rag/RagContractV1Tests.cs`
- Create: `windows/src/AINotebook.Core/Rag/RetrievalScope.cs`
- Create: `windows/tests/AINotebook.Core.Tests/Rag/RetrievalScopeTests.cs`
- Create: `windows/src/AINotebook.Core/Storage/CitationsCodec.cs`
- Modify: `windows/src/AINotebook.Core/Models/Chat.cs` (`Citation` record + `CitationSpan`)
- Modify: `windows/src/AINotebook.Core/Storage/NotebookStore.Chat.cs:12-16,57-60,83-88` (drop private `CitationJson`, use codec)
- Create: `windows/tests/AINotebook.Core.Tests/Storage/CitationsCodecTests.cs`

**Interfaces:**
- Produces: `SharedFixtures.Path(string)`, `SharedFixtures.Json(string) -> JsonElement`, `SharedFixtures.ContractFiles()`; `RagContractV1.Scan.MaxFileBytes` (`long`) etc. — PascalCase of the JSON keys, nested static classes `Scan, Detector, Retrieval, Cache, Pack, Providers, Perf`; `record CitationSpan(int Start, int End, int? PageFrom, int? PageTo)`; `Citation(int Marker, long ChunkId, long SourceId, string Snippet)` + init-only optional `FolderId, RelPath, DisplayName, RevisionId, Spans (IReadOnlyList<CitationSpan>, default empty), ChunkIds (IReadOnlyList<long>, default empty), Text`, `bool IsV2`; `static class CitationsCodec { IReadOnlyList<Citation> Decode(string?); string? Encode(IReadOnlyList<Citation>) }` with the exact semantics of Task 4. `abstract record RetrievalScope` with `sealed record All` and `sealed record Selection(IReadOnlySet<long> SourceIds, IReadOnlySet<long> FolderIds)` (value equality over set contents), `bool IsEmptySelection`, `static RetrievalScope Union(IEnumerable<RetrievalScope>)`, `RetrievalScopeJson.Serialize/Deserialize` with the exact JSON of Task 3b (unknown `kind` → `JsonException`).

- [x] **Step 1: Link shared fixtures** — add to the csproj:

```xml
  <ItemGroup>
    <None Include="..\..\..\Tests\fixtures\**\*">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <Link>SharedFixtures\%(RecursiveDir)%(Filename)%(Extension)</Link>
    </None>
  </ItemGroup>
```

- [x] **Step 2: Write failing tests** — C# ports of `SharedFixturesTests`, `RagContractV1Tests` (one `[Fact]` per section, comparing every key) and `CitationsCodecTests` (theory over `citations-v2.json` cases via `MemberData`; encode-empty-null; legacy-array prefix `[`; v2 round-trip with prefix `{`; corrupt `citations_json` row inserted with raw SQL inside the store loads with empty citations). Equality: compare `Citation` records field-by-field including list contents (records compare lists by reference — use a helper `AssertCitationsEqual`).

- [x] **Step 3: Run** `dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~SharedFixtures|FullyQualifiedName~RagContractV1|FullyQualifiedName~CitationsCodec"` → FAIL (types missing).

- [x] **Step 4: Implement** — `System.Text.Json` with `[JsonPropertyName]` camelCase on a private DTO; prevalidate every number/string/property name in the full document (finite double; no unpaired surrogate) and return `[]` on failure; then lossy item decoding by parsing each array element as `JsonElement` and catching `JsonException`/`InvalidOperationException`/`KeyNotFoundException` per element; required keys `marker, chunkId, sourceId, snippet` must be present with correct JSON kinds; unknown keys ignored; encoding omits null optionals and empty lists, legacy array when no `IsV2`, else `{"v":2,"items":[…]}`. `Decode` never throws.

- [x] **Step 5: Run** the filtered tests → PASS; then full `dotnet test windows/tests/AINotebook.Core.Tests` → green.

- [x] **Step 6: Commit** on `wp0-codex`:

```bash
git add windows/
git commit -m "feat(win-core): shared fixtures, RagContractV1, citations codec v2 (WP0 twin)"
```

### Task 6: Normative contract doc `docs/contracts/folder-rag-v1.md` + case fixtures

**Files:**
- Create: `docs/contracts/folder-rag-v1.md`
- Create: `Tests/fixtures/contracts/api-root-v1.json`, `glob-v1.json`, `fts-query-v1.json`, `budget-v1.json`, `diversity-v1.json`, `legacy-generation-v1.json`, `overview-v1.json`

**Interfaces:**
- Produces: the algorithms and fixture schemas WP2 (api-root), WP3 (legacy-generation), WP5 (fts-query), WP6 (glob), WP8 (budget, diversity, overview) implement. Each fixture's `cases[]` item shape is defined in the doc section of the same name.

- [x] **Step 1: Write the doc** with these normative sections (each: definitions, algorithm in numbered steps or pseudocode with integer arithmetic, edge cases, fixture schema):
  1. **Scope & eligibility** — `RetrievalScope` (Task 3b); eligible chunk predicate: `notebook_id`, selection union, `availability='present'`, `eligible=1`, and branch-specific revision membership: BM25/metadata/neighbours/map/Overview use `sources.published_revision_id`; vectors use the pinned active generation's `done` manifest revision (possibly older). No active generation leaves vector results empty and published lexical results available. Hydrate each hit's own revision; empty selection → `[]` without querying.
  1b. **State-transition tables** (normative tables; job reference transitions included now, SQL/concurrency fixtures authored in the implementing WP, jointly reviewed): scan completion per subtree, eligibility change, `ingest_jobs` starts increment attempts, terminal exhaustion after five starts, retry backoff, 60-second renewal and lease-token fencing, generation build → activation → retire → GC, source-set union, coverage counting. Plus frozen DTO field lists: `provider_model_limits`, `source_revisions`, prepared request, citation map (spec §8.1).
  2. **Coverage categories** — published/searchable corpus count, separate disjoint freshness with error-before-pending-before-current precedence, availability/eligibility categories and their SQL sources (`sources` vs `scan_items`), "at least Y" rule for `partial`; old published revision + failed refresh remains searchable + refreshError.
  3. **Revisions & spans** — scalar offsets `[start,end)`, canonical text assembly for PDF (pages joined with `"\n\n"`, `pageFrom/pageTo` from page boundary table), DOCX/PPTX/XLSX (sheet header line `"## <sheet name>"`), chunker version `2`.
  4. **Index generations** — identity fields, manifest states, activation preconditions, at most one active, immutable revision/chunk-set membership and GC rule. Legacy-generation rule (fixture `legacy-generation-v1.json`: input = list of `{notebookId, modelKey, dims, vectorCount, malformedCount}` + `configuredModelKey`; output per notebook = legacy generation identities created + `activeGeneration` identity or `null`). A legacy generation is created per `(notebookId, modelKey, dims)` with ≥ 1 well-formed vector (malformed = wrong byte length for `dims`, dropped and counted); the one matching `configuredModelKey` becomes active (several dims → larger `vectorCount`, tie → smaller dims). **No configured match → `activeGeneration: null`** (vectors preserved, lexical-only from `published_revision_id` + reindex status); never auto-activate another provider/model (privacy/endpoint). Reference retrieval-rule cases cover no-active-generation lexical fallback; WP3/WP5 add SQL fixtures.
  5. **API root** — rules from spec §7 (fixture `api-root-v1.json`: `{type, baseURL, endpoint ("chat"|"models"|"embeddings"), legacy: bool, expectedURL | expectedError}`; ≥ 25 cases covering all 5 provider types, trailing slash, `/v1` present/absent, proxy prefix, query/fragment rejected, malformed hosts/ports and parsing errors, no userinfo/control characters/internal whitespace, legacy conversion).
  6. **Glob grammar** — spec §4.2 grammar (fixture `glob-v1.json`: `{pattern, path, caseSensitive, matches}`; ≥ 30 cases incl. `*` not crossing `/`, `**` at start/middle/end, `?` on a multi-byte scalar, component-name rule, normalized trailing/repeated separators, slash-only rejection, pinned Unicode 15.1 simple lowercase (dotted I and supplementary-plane letters), rejected syntax `!x`, `[ab]`, `{a,b}` → `expectedError: "unsupportedSyntax"`).
  7. **FTS query tokenization — PROVISIONAL in v1, frozen in WP5.** Proposed rule: split the query with the character classes SQLite `unicode61` uses (no own case-folding — SQLite folds both sides), dedupe first-occurrence, cap `maxFtsTokens`, each token emitted as `"tok"` with `"` doubled, joined `" OR "`; empty → `null`. Fixture `fts-query-v1.json` cases are `{documentText, query, expectedMatchExpr | null, shouldMatchDocument}` so WP5 verifies them against a **real** `fts5(text, tokenize='unicode61 remove_diacritics 2')` table: ≥ 20 cases incl. cs/sk/de diacritics, decomposed vs precomposed accents, `ß` vs `ss` (documented limitation), quotes, `AND/NEAR/*` as plain tokens, 40-token cap, emoji-only → null. Frozen only when these pass on both platforms.
  8. **Token budget** — normative contract §8 as integer steps (`share(x, bp) = x * bp / 10000` floor), zero evidence means no citation, evidence → history → map redistribution with the map share ceiling, `contextTooSmall` condition, oversize-first-passage truncation using actual `{tokens, endScalar}` sentence-prefix candidates; continue packing, allow redistribution without re-extending an included truncated passage (fixture `budget-v1.json`: input token sizes per section + limits → allocations, included passage ids, error).
  9. **Diversity selection** — production code on both platforms uses this integer scoring (no float path left behind). RRF ranks are **1-based** (today `rank + 1`, `Retriever.swift:85`); score in integer micro-units: `rrfMicro = floor(1_000_000 / (rrfK + rank))` summed over branches; `n` counts **selected direct hits** from that source (neighbours and merges don't count); penalty applied as `score * diversityPenaltyBp^n / 10000^n` (computed iteratively with floor each step); greedy, ties by `chunkId` ascending (fixture `diversity-v1.json`: candidates `{chunkId, sourceId, rrfMicro, tokens}` + budget + topK + singleSourceScope → selected ids in order).
  10. **Overview selection** — round-robin across `(folderId, dir)` buckets (null loose group first, folder IDs ascending, directory scalar order), files by `relPath` then `sourceId`, first chunk of published revision, stop at budget; report published-chunk candidates separately from total eligible files in scope (fixture `overview-v1.json`, including permuted duplicate relative paths).
  11. **Wire message order** — logical messages → Anthropic/OpenAI/Ollama payload shape (one system string = rules + `"\n\n"` + user instructions; history chronological; final user message). Fixture `wire-order-v1.json` authored **here** (≥ 6 worked examples incl. multiple system sections, empty user instructions, no history); WP2 executes the adapter tests (today Swift Anthropic joins all system turns, Windows only the first).
  12. **Token estimation (development placeholder, not release-safe)** — `base = ceilDiv(scalarCount, divisor[lang])`, `estimate = ceilDiv(base * (10000 + headroomBp), 10000)`, divisors `en 4, de 3, cs 3, sk 3, und 3`, plus a fixed framing cost per section and per message (numbers frozen in the doc). The estimator version is pinned in each prepared request. WP7 calibrates against measured token counts per model/tokenizer family and ships `token-estimate-v2.json`.

- [x] **Step 2: Write the eight case fixtures** (`api-root, glob, fts-query, budget, diversity, legacy-generation, overview, wire-order`) with the case counts above; every case has a unique `name`. Algorithm fixtures (`budget`, `diversity`, `legacy-generation`, `overview`, `wire-order`) carry **worked examples** the reviewer recomputes by hand in Task 8 — envelope tests alone do not validate results.

- [x] **Step 3: Run envelope tests on both platforms**

Run: `swift test --filter SharedFixturesTests` and `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures`
Expected: PASS (every new file has envelope + unique names).

- [x] **Step 4: Commit**

```bash
git add docs/contracts/folder-rag-v1.md Tests/fixtures/contracts/
git commit -m "contracts: normative folder-rag v1 algorithms and case fixtures"
```

### Task 7: [Codex] Detector normative appendix `docs/contracts/lang-detector-v1.md`

**Files:**
- Create: `docs/contracts/lang-detector-v1.md`
- Create: `Tests/fixtures/contracts/lang-normalize-v1.json` (normalization cases: input → scalar list after NFC/case-fold/NFC/classification, boundary-marked words)

**Interfaces:**
- Consumes: `constants-v1.json` `detector` section.
- Produces: the exact scoring equation, smoothing, union vocabulary and unknown buckets, count semantics, export rounding, negative-number division, tie-break, document window sampling (count, size, positions), input cap, letter/word counting for abstention, artifact JSON schema (`lang-detector-v1.json`) and manifest schema. WP4 implements against it.

- [x] **Step 1: Codex drafts the appendix and fixtures**:
  - `lang-normalize-v1.json` (≥ 25 cases: `ẞ`, `ß`, dotted/dotless I, combining háček vs precomposed `č`, Slovak `ľ ĺ ŕ ô ä`, German umlauts, digits/punctuation as boundaries, mixed scripts). Invalid UTF-16 lives in separate cases with a `utf16Units` array (a Swift `String` cannot carry an unpaired surrogate; JSON parser behaviour must not decide parity).
  - `lang-score-v1.json`: a **tiny synthetic model** (≤ 10 features per order, 2 targets + background) with cases covering feature counts, unknown buckets, integer scores, abstention per bucket and document aggregation (`mixed` only with confident evidence for ≥ 2 languages; shares over all sampled letters incl. unknown windows; else `und`).
  - The appendix pins smoothing, vocabulary construction, export rounding, signed division, background priors, minimum calibration support.
- [x] **Step 2: Claude reviews; Codex fixes findings.**
- [x] **Step 3: Envelope tests green on both platforms** (as Task 6 Step 3).
- [x] **Step 4: Commit** on `wp0-codex`:

```bash
git add docs/contracts/lang-detector-v1.md Tests/fixtures/contracts/lang-normalize-v1.json
git commit -m "contracts: normative language detector appendix v1"
```

### Task 8: Cross-review, merge, gate

- [ ] **Step 1:** Cross-review and the 11 binding decisions are recorded; contract/reference/C# fixes are implemented. Additional shared regression cases expose Swift's acceptance of negative overflow in ignored fields. Completing that runtime fix requires permission to edit the Swift codec, outside the original fix file list.
- [x] **Step 2:** Original WP0 branches merged: Windows twins `785c50b` and detector appendix `087c1bf`. The current cross-review-fix branch still requires Claude's integration after review.
- [ ] **Step 3:** Run both suites:

```bash
swift test
dotnet test windows/tests/AINotebook.Core.Tests
```

Latest result: generator `--check` passes; .NET **459/459 passed**; Swift **381 tests, two assertion failures** in the shared citation fixture test for negative overflow. No skipped contract tests. The gate remains open until the Swift scope extension and fix are completed and both suites pass.
- [x] **Step 4:** Reference hardware + perf protocol (asked of the user at WP0 start) recorded in `docs/contracts/folder-rag-v1.md` §Perf **before** `perf.*` counts as frozen. Review scope = WP0's commits since its recorded start commit `72c96b4`, not all of `main...HEAD`.
- [ ] **Step 5:** Claude integrates the cross-review-fix commit and marks WP0 done in the master plan. The master plan and target branch are outside this fix task's allowed files/actions; no integration is claimed here.

```bash
git add docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md docs/contracts/folder-rag-v1.md
git commit -m "docs: WP0 contracts frozen"
```
