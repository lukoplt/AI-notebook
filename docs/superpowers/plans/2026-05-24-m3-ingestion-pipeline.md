# M3: Ingestion Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the source-ingestion pipeline — text/Markdown, PDF, web URL, Office (docx / pptx / xlsx) — that converts a file or URL into normalized text, splits it into ~512-token chunks, persists everything to SQLite, and exposes the source list + add-source UI inside the notebook detail view.

**Architecture:** A pure `Chunker` (token-approximating splitter, 512 / 64 overlap), a `TextExtractor` protocol with four concrete implementations (`PlainTextExtractor`, `PDFExtractor`, `WebExtractor`, `OfficeExtractor`), and an `IngestionService` actor that orchestrates extract → chunk → persist with status transitions (`pending` → `chunking` → `ready` | `error`). Source storage extends `NotebookStore` via a new `NotebookStore+Sources.swift` file; schema additions land as `MigrationV2`. The SwiftUI side adds an `AddSourceSheet` (file picker + URL + raw text) and a `SourceListView` replacing the placeholder in `NotebookDetailView`.

**Tech Stack:** Swift 6, GRDB (existing), PDFKit (system), SwiftSoup (new dep, MIT) for HTML cleanup, ZIPFoundation (new dep, MIT) for Office archives, Foundation `XMLParser` for Office XML, `URLSession` for web fetch (CI privacy gate exemption mirrors `OllamaClient.swift`).

---

## File Structure

**Create:**
- `Sources/AINotebookCore/SourceType.swift` — enum (`pdf` / `text` / `markdown` / `web` / `docx` / `pptx` / `xlsx`)
- `Sources/AINotebookCore/SourceStatus.swift` — enum (`pending` / `chunking` / `ready` / `error`)
- `Sources/AINotebookCore/Source.swift` — `Source` model + GRDB record
- `Sources/AINotebookCore/SourceChunk.swift` — `SourceChunk` model + GRDB record
- `Sources/AINotebookCore/MigrationV2.swift` — adds `sources`, `source_chunks`, `sources_fts`, `chunks_fts` tables + indexes
- `Sources/AINotebookCore/Chunker.swift` — pure splitter: `func chunk(_ text: String) -> [ChunkDraft]`
- `Sources/AINotebookCore/TextExtractor.swift` — `protocol TextExtractor`, `ExtractedText` struct, `ExtractorError` enum
- `Sources/AINotebookCore/PlainTextExtractor.swift` — txt + md
- `Sources/AINotebookCore/PDFExtractor.swift` — PDFKit
- `Sources/AINotebookCore/WebExtractor.swift` — URLSession + SwiftSoup
- `Sources/AINotebookCore/OfficeExtractor.swift` — docx / pptx / xlsx via ZIPFoundation + XMLParser
- `Sources/AINotebookCore/NotebookStore+Sources.swift` — source CRUD extension
- `Sources/AINotebookCore/IngestionService.swift` — actor orchestrating extract → chunk → persist
- `Sources/AINotebookApp/AddSourceSheet.swift`
- `Sources/AINotebookApp/SourceListView.swift`
- `Tests/AINotebookCoreTests/ChunkerTests.swift`
- `Tests/AINotebookCoreTests/MigrationV2Tests.swift`
- `Tests/AINotebookCoreTests/NotebookStoreSourcesTests.swift`
- `Tests/AINotebookCoreTests/PlainTextExtractorTests.swift`
- `Tests/AINotebookCoreTests/PDFExtractorTests.swift`
- `Tests/AINotebookCoreTests/WebExtractorTests.swift`
- `Tests/AINotebookCoreTests/OfficeExtractorTests.swift`
- `Tests/AINotebookCoreTests/IngestionServiceTests.swift`
- `Tests/AINotebookCoreTests/Fixtures/sample.pdf`
- `Tests/AINotebookCoreTests/Fixtures/sample.docx`
- `Tests/AINotebookCoreTests/Fixtures/sample.pptx`
- `Tests/AINotebookCoreTests/Fixtures/sample.xlsx`
- `Tests/AINotebookCoreTests/Fixtures/sample.html`

**Modify:**
- `Package.swift` — add SwiftSoup + ZIPFoundation deps; add `resources: [.copy("Fixtures")]` to test target
- `Sources/AINotebookCore/NotebookStore.swift` — register V2 migration
- `Sources/AINotebookCore/Localization.swift` — add source-UI strings (EN + CS)
- `Sources/AINotebookApp/NotebookDetailView.swift` — replace placeholder with `SourceListView`
- `Sources/AINotebookApp/ContentView.swift` — inject `IngestionService`
- `Sources/AINotebookApp/AINotebookApp.swift` — construct `IngestionService` alongside `NotebookStore`
- `.github/workflows/core-ci.yml` — extend URLSession privacy grep exemption to `WebExtractor.swift`

---

## Task 1: Branch + dependency additions

**Files:** branch + `Package.swift`

- [ ] **Step 1: Branch off main**

```bash
git checkout main
git pull --ff-only || true
git checkout -b m3-ingestion
```

- [ ] **Step 2: Add SwiftSoup + ZIPFoundation dependencies**

Edit `Package.swift` so the `dependencies` and `targets` arrays read:

```swift
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "AINotebookCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .executableTarget(
            name: "AINotebookApp",
            dependencies: ["AINotebookCore"]
        ),
        .testTarget(
            name: "AINotebookCoreTests",
            dependencies: ["AINotebookCore"],
            resources: [.copy("Fixtures")]
        )
    ]
```

- [ ] **Step 3: Resolve + verify build**

```bash
swift package resolve
swift build
```

Expected: build succeeds. SwiftSoup + ZIPFoundation pulled.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add SwiftSoup + ZIPFoundation for M3 ingestion"
```

---

## Task 2: `SourceType` enum

**Files:** Create `Sources/AINotebookCore/SourceType.swift`, test `Tests/AINotebookCoreTests/SourceTypeTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/SourceTypeTests.swift
import XCTest
@testable import AINotebookCore

final class SourceTypeTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(SourceType.pdf.rawValue, "pdf")
        XCTAssertEqual(SourceType.text.rawValue, "text")
        XCTAssertEqual(SourceType.markdown.rawValue, "markdown")
        XCTAssertEqual(SourceType.web.rawValue, "web")
        XCTAssertEqual(SourceType.docx.rawValue, "docx")
        XCTAssertEqual(SourceType.pptx.rawValue, "pptx")
        XCTAssertEqual(SourceType.xlsx.rawValue, "xlsx")
    }

    func testDetectFromFilenameMatchesExtension() {
        XCTAssertEqual(SourceType.detect(filename: "doc.pdf"), .pdf)
        XCTAssertEqual(SourceType.detect(filename: "Notes.MD"), .markdown)
        XCTAssertEqual(SourceType.detect(filename: "plain.txt"), .text)
        XCTAssertEqual(SourceType.detect(filename: "deck.pptx"), .pptx)
        XCTAssertEqual(SourceType.detect(filename: "sheet.xlsx"), .xlsx)
        XCTAssertEqual(SourceType.detect(filename: "memo.docx"), .docx)
    }

    func testDetectReturnsNilForUnknown() {
        XCTAssertNil(SourceType.detect(filename: "image.png"))
        XCTAssertNil(SourceType.detect(filename: "noextension"))
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter SourceTypeTests 2>&1 | tail -10
```

Expected: fail (`cannot find 'SourceType' in scope`).

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/SourceType.swift
import Foundation

public enum SourceType: String, Codable, CaseIterable, Sendable {
    case pdf
    case text
    case markdown
    case web
    case docx
    case pptx
    case xlsx

    /// Best-effort detection from a filename. Returns nil for unknown extensions.
    public static func detect(filename: String) -> SourceType? {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":            return .pdf
        case "txt":            return .text
        case "md", "markdown": return .markdown
        case "docx":           return .docx
        case "pptx":           return .pptx
        case "xlsx":           return .xlsx
        default:               return nil
        }
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter SourceTypeTests 2>&1 | tail -10
```

Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/SourceType.swift Tests/AINotebookCoreTests/SourceTypeTests.swift
git commit -m "feat(core): add SourceType enum with filename detection"
```

---

## Task 3: `SourceStatus` enum

**Files:** Create `Sources/AINotebookCore/SourceStatus.swift`, test `Tests/AINotebookCoreTests/SourceStatusTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/SourceStatusTests.swift
import XCTest
@testable import AINotebookCore

final class SourceStatusTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(SourceStatus.pending.rawValue, "pending")
        XCTAssertEqual(SourceStatus.chunking.rawValue, "chunking")
        XCTAssertEqual(SourceStatus.ready.rawValue, "ready")
        XCTAssertEqual(SourceStatus.error.rawValue, "error")
    }

    func testIsTerminal() {
        XCTAssertFalse(SourceStatus.pending.isTerminal)
        XCTAssertFalse(SourceStatus.chunking.isTerminal)
        XCTAssertTrue(SourceStatus.ready.isTerminal)
        XCTAssertTrue(SourceStatus.error.isTerminal)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter SourceStatusTests 2>&1 | tail -10
```

Expected: fail.

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/SourceStatus.swift
import Foundation

public enum SourceStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case chunking
    case ready
    case error

    public var isTerminal: Bool {
        switch self {
        case .pending, .chunking: return false
        case .ready, .error:      return true
        }
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter SourceStatusTests 2>&1 | tail -10
```

Expected: 2/2 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/SourceStatus.swift Tests/AINotebookCoreTests/SourceStatusTests.swift
git commit -m "feat(core): add SourceStatus enum"
```

---

## Task 4: `Source` and `SourceChunk` GRDB models

**Files:** Create `Sources/AINotebookCore/Source.swift`, `Sources/AINotebookCore/SourceChunk.swift`. No standalone test file — covered by the migration / store tests in Tasks 5 + 7.

- [ ] **Step 1: Implement `Source.swift`**

```swift
// Sources/AINotebookCore/Source.swift
import Foundation
import GRDB

public struct Source: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var notebookId: Int64
    public var type: SourceType
    public var title: String
    public var uri: String?
    public var rawPath: String?
    public var status: SourceStatus
    public var error: String?
    public var ingestedAt: Date

    public init(
        id: Int64? = nil,
        notebookId: Int64,
        type: SourceType,
        title: String,
        uri: String? = nil,
        rawPath: String? = nil,
        status: SourceStatus = .pending,
        error: String? = nil,
        ingestedAt: Date = Date()
    ) {
        self.id = id
        self.notebookId = notebookId
        self.type = type
        self.title = title
        self.uri = uri
        self.rawPath = rawPath
        self.status = status
        self.error = error
        self.ingestedAt = ingestedAt
    }
}

extension Source: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sources"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case notebookId  = "notebook_id"
        case type
        case title
        case uri
        case rawPath     = "raw_path"
        case status
        case error
        case ingestedAt  = "ingested_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 2: Implement `SourceChunk.swift`**

```swift
// Sources/AINotebookCore/SourceChunk.swift
import Foundation
import GRDB

public struct SourceChunk: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var sourceId: Int64
    public var ord: Int
    public var text: String
    public var tokenCount: Int
    public var pageHint: Int?

    public init(
        id: Int64? = nil,
        sourceId: Int64,
        ord: Int,
        text: String,
        tokenCount: Int,
        pageHint: Int? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.ord = ord
        self.text = text
        self.tokenCount = tokenCount
        self.pageHint = pageHint
    }
}

extension SourceChunk: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "source_chunks"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case sourceId   = "source_id"
        case ord
        case text
        case tokenCount = "token_count"
        case pageHint   = "page_hint"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookCore/Source.swift Sources/AINotebookCore/SourceChunk.swift
git commit -m "feat(core): add Source + SourceChunk GRDB records"
```

---

## Task 5: `MigrationV2` — sources, chunks, FTS

**Files:** Create `Sources/AINotebookCore/MigrationV2.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV2Tests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV2Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

final class MigrationV2Tests: XCTestCase {
    func testV2CreatesAllExpectedTables() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table','index') ORDER BY name"
            )
            XCTAssertTrue(names.contains("sources"),       "sources missing")
            XCTAssertTrue(names.contains("source_chunks"), "source_chunks missing")
            XCTAssertTrue(names.contains("sources_fts"),   "sources_fts missing")
            XCTAssertTrue(names.contains("chunks_fts"),    "chunks_fts missing")
            XCTAssertTrue(names.contains("idx_sources_notebook"), "idx_sources_notebook missing")
            XCTAssertTrue(names.contains("idx_chunks_source"),    "idx_chunks_source missing")
        }
    }

    func testSourcesFtsKeepsInSyncWithSources() throws {
        let store = try NotebookStore(path: .inMemory)
        let notebook = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO sources(notebook_id,type,title,status,ingested_at)
                VALUES (?,?,?,?,?)
                """,
                arguments: [notebook.id!, "text", "Hello world", "ready", Date()]
            )
            let hits: Int = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sources_fts WHERE sources_fts MATCH 'hello'"
            ) ?? -1
            XCTAssertEqual(hits, 1)
        }
    }
}
```

- [ ] **Step 2: Add a test affordance to `NotebookStore`**

Append to `Sources/AINotebookCore/NotebookStore.swift` (inside the class):

```swift
    /// Test affordance: run a closure on the underlying DB. Production callers
    /// must use the typed CRUD methods.
    public func runOnDatabase<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
```

- [ ] **Step 3: Verify fail**

```bash
swift test --filter MigrationV2Tests 2>&1 | tail -10
```

Expected: fail (`sources missing`).

- [ ] **Step 4: Implement `MigrationV2.swift`**

```swift
// Sources/AINotebookCore/MigrationV2.swift
import GRDB

/// Schema v2 — adds sources, source_chunks, FTS5 mirrors, and triggers
/// keeping the FTS tables in sync with their parents.
public func registerMigrationV2(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v2_sources_and_chunks") { db in
        try db.create(table: "sources") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("notebook_id", .integer)
                .notNull()
                .references("notebooks", onDelete: .cascade)
            t.column("type",        .text).notNull()
            t.column("title",       .text).notNull()
            t.column("uri",         .text)
            t.column("raw_path",    .text)
            t.column("status",      .text).notNull()
            t.column("error",       .text)
            t.column("ingested_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_sources_notebook",
            on: "sources",
            columns: ["notebook_id"]
        )

        try db.create(table: "source_chunks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("source_id", .integer)
                .notNull()
                .references("sources", onDelete: .cascade)
            t.column("ord",         .integer).notNull()
            t.column("text",        .text).notNull()
            t.column("token_count", .integer).notNull()
            t.column("page_hint",   .integer)
        }
        try db.create(
            index: "idx_chunks_source",
            on: "source_chunks",
            columns: ["source_id", "ord"]
        )

        try db.execute(sql: """
            CREATE VIRTUAL TABLE sources_fts USING fts5(
                title,
                source_id UNINDEXED,
                tokenize = 'porter unicode61'
            )
            """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE chunks_fts USING fts5(
                text,
                chunk_id UNINDEXED,
                tokenize = 'porter unicode61'
            )
            """)

        // Keep sources_fts in sync with sources (title only — v1 has no body
        // column on the sources row itself).
        try db.execute(sql: """
            CREATE TRIGGER sources_ai AFTER INSERT ON sources BEGIN
              INSERT INTO sources_fts(rowid, title, source_id)
              VALUES (new.id, new.title, new.id);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER sources_ad AFTER DELETE ON sources BEGIN
              DELETE FROM sources_fts WHERE rowid = old.id;
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER sources_au AFTER UPDATE ON sources BEGIN
              UPDATE sources_fts SET title = new.title WHERE rowid = old.id;
            END;
            """)

        // Keep chunks_fts in sync with source_chunks.
        try db.execute(sql: """
            CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
              INSERT INTO chunks_fts(rowid, text, chunk_id)
              VALUES (new.id, new.text, new.id);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER chunks_ad AFTER DELETE ON source_chunks BEGIN
              DELETE FROM chunks_fts WHERE rowid = old.id;
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER chunks_au AFTER UPDATE ON source_chunks BEGIN
              UPDATE chunks_fts SET text = new.text WHERE rowid = old.id;
            END;
            """)
    }
}
```

- [ ] **Step 5: Register V2 in `NotebookStore.init`**

In `Sources/AINotebookCore/NotebookStore.swift`, change the init body so the migrator block reads:

```swift
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        registerMigrationV2(on: &migrator)
        try migrator.migrate(dbQueue)
        try refresh()
```

- [ ] **Step 6: Verify pass**

```bash
swift test --filter MigrationV2Tests 2>&1 | tail -10
```

Expected: 2/2 pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/AINotebookCore/MigrationV2.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV2Tests.swift
git commit -m "feat(core): add MigrationV2 — sources, chunks, FTS5 mirrors"
```

---

## Task 6: Extend `StoreError` for source-side failures

**Files:** Modify `Sources/AINotebookCore/StoreError.swift`

- [ ] **Step 1: Read existing enum**

```bash
cat Sources/AINotebookCore/StoreError.swift
```

- [ ] **Step 2: Add cases (append to the enum body and the `errorDescription` switch)**

Add these cases to the `StoreError` enum:

```swift
    case sourceNotFound(Int64)
    case invalidSourceTitle(String)
```

And add the matching arms to the localized-description switch:

```swift
        case .sourceNotFound(let id):
            return "Source #\(id) not found."
        case .invalidSourceTitle(let title):
            return "Invalid source title: \"\(title)\"."
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookCore/StoreError.swift
git commit -m "feat(core): add sourceNotFound + invalidSourceTitle to StoreError"
```

---

## Task 7: `NotebookStore+Sources` — source CRUD

**Files:** Create `Sources/AINotebookCore/NotebookStore+Sources.swift`, test `Tests/AINotebookCoreTests/NotebookStoreSourcesTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/NotebookStoreSourcesTests.swift
import XCTest
@testable import AINotebookCore

final class NotebookStoreSourcesTests: XCTestCase {
    func testCreateAndFetchSources() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let s1 = try store.createSource(
            notebookId: nb.id!,
            type: .text,
            title: "Alpha",
            uri: nil,
            rawPath: nil
        )
        let s2 = try store.createSource(
            notebookId: nb.id!,
            type: .pdf,
            title: "Beta",
            uri: nil,
            rawPath: "/tmp/beta.pdf"
        )

        let list = try store.sources(notebookId: nb.id!)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.title)), ["Alpha", "Beta"])
        XCTAssertEqual(s1.status, .pending)
        XCTAssertEqual(s2.status, .pending)
    }

    func testUpdateStatusPersists() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.updateSourceStatus(id: s.id!, status: .ready, error: nil)
        let reloaded = try XCTUnwrap(store.source(id: s.id!))
        XCTAssertEqual(reloaded.status, .ready)
        XCTAssertNil(reloaded.error)
    }

    func testUpdateStatusErrorPersists() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.updateSourceStatus(id: s.id!, status: .error, error: "boom")
        let reloaded = try XCTUnwrap(store.source(id: s.id!))
        XCTAssertEqual(reloaded.status, .error)
        XCTAssertEqual(reloaded.error, "boom")
    }

    func testReplaceChunksClearsPreviousAndInserts() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "one",   tokenCount: 1, pageHint: nil),
                ChunkDraft(text: "two",   tokenCount: 1, pageHint: nil),
                ChunkDraft(text: "three", tokenCount: 1, pageHint: nil)
            ]
        )
        let first = try store.chunks(sourceId: s.id!)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.map(\.ord), [0, 1, 2])
        XCTAssertEqual(first.map(\.text), ["one", "two", "three"])

        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "only", tokenCount: 1, pageHint: nil)]
        )
        let second = try store.chunks(sourceId: s.id!)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].text, "only")
    }

    func testDeleteSourceCascadesChunks() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "x", tokenCount: 1, pageHint: nil)]
        )
        try store.deleteSource(id: s.id!)
        XCTAssertNil(try store.source(id: s.id!))
        XCTAssertEqual(try store.chunks(sourceId: s.id!).count, 0)
    }

    func testCreateRejectsEmptyTitle() {
        do {
            let store = try NotebookStore(path: .inMemory)
            let nb = try store.createNotebook(name: "NB")
            _ = try store.createSource(
                notebookId: nb.id!, type: .text, title: "   ", uri: nil, rawPath: nil
            )
            XCTFail("expected throw")
        } catch StoreError.invalidSourceTitle {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Add `ChunkDraft` value type to `Source.swift`**

Append to `Sources/AINotebookCore/Source.swift`:

```swift
/// In-memory chunk produced by the chunker, not yet persisted.
public struct ChunkDraft: Equatable, Hashable, Sendable {
    public var text: String
    public var tokenCount: Int
    public var pageHint: Int?

    public init(text: String, tokenCount: Int, pageHint: Int? = nil) {
        self.text = text
        self.tokenCount = tokenCount
        self.pageHint = pageHint
    }
}
```

- [ ] **Step 3: Verify fail**

```bash
swift test --filter NotebookStoreSourcesTests 2>&1 | tail -10
```

Expected: fail (missing `createSource`).

- [ ] **Step 4: Implement extension**

```swift
// Sources/AINotebookCore/NotebookStore+Sources.swift
import Foundation
import GRDB

extension NotebookStore {

    @discardableResult
    public func createSource(
        notebookId: Int64,
        type: SourceType,
        title: String,
        uri: String?,
        rawPath: String?
    ) throws -> Source {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidSourceTitle(title)
        }
        var source = Source(
            notebookId: notebookId,
            type: type,
            title: trimmed,
            uri: uri,
            rawPath: rawPath,
            status: .pending,
            error: nil,
            ingestedAt: Date()
        )
        try runOnDatabase { db in
            try source.insert(db)
        }
        return source
    }

    public func sources(notebookId: Int64) throws -> [Source] {
        try runOnDatabase { db in
            try Source
                .filter(Source.Columns.notebookId.column == notebookId)
                .order(Source.Columns.ingestedAt.column.desc)
                .fetchAll(db)
        }
    }

    public func source(id: Int64) throws -> Source? {
        try runOnDatabase { db in
            try Source.fetchOne(db, key: id)
        }
    }

    public func updateSourceStatus(
        id: Int64,
        status: SourceStatus,
        error: String?
    ) throws {
        try runOnDatabase { db in
            guard var s = try Source.fetchOne(db, key: id) else {
                throw StoreError.sourceNotFound(id)
            }
            s.status = status
            s.error  = error
            try s.update(db)
        }
    }

    public func deleteSource(id: Int64) throws {
        try runOnDatabase { db in
            let removed = try Source.deleteOne(db, key: id)
            guard removed else { throw StoreError.sourceNotFound(id) }
        }
    }

    public func replaceChunks(
        sourceId: Int64,
        chunks: [ChunkDraft]
    ) throws {
        try runOnDatabase { db in
            try SourceChunk
                .filter(SourceChunk.Columns.sourceId.column == sourceId)
                .deleteAll(db)
            for (ord, draft) in chunks.enumerated() {
                var row = SourceChunk(
                    sourceId: sourceId,
                    ord: ord,
                    text: draft.text,
                    tokenCount: draft.tokenCount,
                    pageHint: draft.pageHint
                )
                try row.insert(db)
            }
        }
    }

    public func chunks(sourceId: Int64) throws -> [SourceChunk] {
        try runOnDatabase { db in
            try SourceChunk
                .filter(SourceChunk.Columns.sourceId.column == sourceId)
                .order(SourceChunk.Columns.ord.column.asc)
                .fetchAll(db)
        }
    }
}
```

- [ ] **Step 5: Verify pass**

```bash
swift test --filter NotebookStoreSourcesTests 2>&1 | tail -10
```

Expected: 6/6 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/NotebookStore+Sources.swift Sources/AINotebookCore/Source.swift Tests/AINotebookCoreTests/NotebookStoreSourcesTests.swift
git commit -m "feat(core): source CRUD on NotebookStore (create/list/status/delete/chunks)"
```

---

## Task 8: `Chunker` — fixed-token splitter

Approximation: 1 token ≈ 4 characters (industry-standard rough estimate, accurate enough for sizing chunks). Target window 512 tokens (~2 048 chars), overlap 64 tokens (~256 chars). Split on whitespace boundaries to avoid mid-word breaks.

**Files:** Create `Sources/AINotebookCore/Chunker.swift`, test `Tests/AINotebookCoreTests/ChunkerTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/ChunkerTests.swift
import XCTest
@testable import AINotebookCore

final class ChunkerTests: XCTestCase {
    func testShortTextProducesSingleChunk() {
        let drafts = Chunker.chunk("Hello world.")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "Hello world.")
        XCTAssertGreaterThan(drafts[0].tokenCount, 0)
    }

    func testEmptyOrWhitespaceProducesNoChunks() {
        XCTAssertTrue(Chunker.chunk("").isEmpty)
        XCTAssertTrue(Chunker.chunk("   \n\t ").isEmpty)
    }

    func testLongTextSplitsIntoMultipleChunks() {
        let para = String(repeating: "word ", count: 2000)  // ~10 000 chars
        let drafts = Chunker.chunk(para)
        XCTAssertGreaterThan(drafts.count, 1)
        // Every chunk under the hard cap (2 048 chars + a small slack for
        // not breaking mid-word).
        for d in drafts {
            XCTAssertLessThanOrEqual(d.text.count, 2 100, "chunk too big: \(d.text.count)")
        }
    }

    func testChunksOverlap() {
        let para = String(repeating: "word ", count: 2000)
        let drafts = Chunker.chunk(para)
        guard drafts.count >= 2 else { return XCTFail("need at least 2 chunks") }
        // Last 200 chars of chunk N appear at the start of chunk N+1
        // (because of the 256-char overlap window — allow some boundary slack).
        let tail = String(drafts[0].text.suffix(200))
        XCTAssertTrue(
            drafts[1].text.contains(tail.prefix(100)),
            "expected overlap between consecutive chunks"
        )
    }

    func testWindowAndOverlapAreOverridable() {
        let drafts = Chunker.chunk(
            String(repeating: "a ", count: 500),
            windowChars: 200,
            overlapChars: 50
        )
        XCTAssertGreaterThan(drafts.count, 3)
        for d in drafts {
            XCTAssertLessThanOrEqual(d.text.count, 220)
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter ChunkerTests 2>&1 | tail -10
```

Expected: fail (`Chunker` undefined).

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/Chunker.swift
import Foundation

/// Pure, deterministic text splitter. Produces overlapping windows of
/// approximately `windowChars` characters (≈ `windowChars / 4` tokens).
/// Always breaks on whitespace boundaries so words are never split.
public enum Chunker {

    /// Defaults: 512-token window, 64-token overlap, with the 1 token ≈ 4 char
    /// rule of thumb used industry-wide for sizing prompts.
    public static func chunk(
        _ raw: String,
        windowChars: Int = 2048,
        overlapChars: Int = 256
    ) -> [ChunkDraft] {
        precondition(windowChars > overlapChars, "overlap must be smaller than window")
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        if cleaned.count <= windowChars {
            return [ChunkDraft(text: cleaned, tokenCount: estimateTokens(cleaned))]
        }

        var drafts: [ChunkDraft] = []
        let chars = Array(cleaned)
        var start = 0
        while start < chars.count {
            var end = min(start + windowChars, chars.count)
            // Avoid splitting mid-word: scan backwards to the previous
            // whitespace, but only up to 200 chars to bound the search.
            if end < chars.count {
                var probe = end
                let floor = max(end - 200, start + 1)
                while probe > floor, !chars[probe - 1].isWhitespace {
                    probe -= 1
                }
                if probe > floor { end = probe }
            }
            let slice = String(chars[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty {
                drafts.append(ChunkDraft(text: slice, tokenCount: estimateTokens(slice)))
            }
            if end >= chars.count { break }
            start = max(end - overlapChars, start + 1)
        }
        return drafts
    }

    /// 1 token ≈ 4 chars, with a minimum of 1.
    public static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter ChunkerTests 2>&1 | tail -10
```

Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Chunker.swift Tests/AINotebookCoreTests/ChunkerTests.swift
git commit -m "feat(core): add Chunker (512-token window, 64-token overlap)"
```

---

## Task 9: `TextExtractor` protocol + `PlainTextExtractor`

**Files:** Create `Sources/AINotebookCore/TextExtractor.swift`, `Sources/AINotebookCore/PlainTextExtractor.swift`, test `Tests/AINotebookCoreTests/PlainTextExtractorTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/PlainTextExtractorTests.swift
import XCTest
@testable import AINotebookCore

final class PlainTextExtractorTests: XCTestCase {

    func testExtractsUtf8Plaintext() async throws {
        let url = try writeTempFile(name: "memo.txt", bytes: Data("Hello, world.".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let extracted = try await PlainTextExtractor().extract(from: url, kind: .text)
        XCTAssertEqual(extracted.text, "Hello, world.")
        XCTAssertEqual(extracted.title, "memo")
    }

    func testStripsMarkdownLeadingHashes() async throws {
        let md = "# Title\n\nSome **bold** body."
        let url = try writeTempFile(name: "doc.md", bytes: Data(md.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let extracted = try await PlainTextExtractor().extract(from: url, kind: .markdown)
        // Title is the first Markdown heading.
        XCTAssertEqual(extracted.title, "Title")
        // Markdown body retained (we do NOT lose content — we just expose
        // the raw text).
        XCTAssertTrue(extracted.text.contains("Some **bold** body."))
    }

    func testEmptyFileThrows() async throws {
        let url = try writeTempFile(name: "empty.txt", bytes: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await PlainTextExtractor().extract(from: url, kind: .text)
            XCTFail("expected throw")
        } catch ExtractorError.emptyContent {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    private func writeTempFile(name: String, bytes: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-notebook-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter PlainTextExtractorTests 2>&1 | tail -10
```

Expected: fail.

- [ ] **Step 3: Implement `TextExtractor.swift`**

```swift
// Sources/AINotebookCore/TextExtractor.swift
import Foundation

public struct ExtractedText: Equatable, Sendable {
    public var title: String
    public var text: String
    /// Optional per-chunk page hints, indexed identically to chunks produced
    /// downstream. `nil` when the extractor cannot determine page boundaries
    /// (txt / md / web / Office text streams).
    public var pageHints: [Int]?

    public init(title: String, text: String, pageHints: [Int]? = nil) {
        self.title = title
        self.text = text
        self.pageHints = pageHints
    }
}

public enum ExtractorError: Error, Equatable {
    case fileNotReadable(URL)
    case unsupportedEncoding(URL)
    case emptyContent
    case pdfOpenFailed(URL)
    case officeArchiveCorrupt(URL)
    case webFetchFailed(URL, status: Int)
    case webResponseNotHTML(URL, mime: String?)
}

public protocol TextExtractor: Sendable {
    /// Extract normalized text. `kind` is the caller's best guess at the
    /// source type (the extractor may double-check it).
    func extract(from url: URL, kind: SourceType) async throws -> ExtractedText
}
```

- [ ] **Step 4: Implement `PlainTextExtractor.swift`**

```swift
// Sources/AINotebookCore/PlainTextExtractor.swift
import Foundation

public struct PlainTextExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        guard let data = try? Data(contentsOf: url) else {
            throw ExtractorError.fileNotReadable(url)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExtractorError.unsupportedEncoding(url)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let title: String
        if kind == .markdown, let h1 = Self.firstMarkdownHeading(text) {
            title = h1
        } else {
            title = url.deletingPathExtension().lastPathComponent
        }
        return ExtractedText(title: title, text: trimmed)
    }

    private static func firstMarkdownHeading(_ raw: String) -> String? {
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
```

- [ ] **Step 5: Verify pass**

```bash
swift test --filter PlainTextExtractorTests 2>&1 | tail -10
```

Expected: 3/3 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/TextExtractor.swift Sources/AINotebookCore/PlainTextExtractor.swift Tests/AINotebookCoreTests/PlainTextExtractorTests.swift
git commit -m "feat(core): TextExtractor protocol + PlainTextExtractor (txt/md)"
```

---

## Task 10: `PDFExtractor` (PDFKit)

**Files:** Create `Sources/AINotebookCore/PDFExtractor.swift`, fixture `Tests/AINotebookCoreTests/Fixtures/sample.pdf`, test `Tests/AINotebookCoreTests/PDFExtractorTests.swift`

- [ ] **Step 1: Generate the fixture PDF deterministically**

Use macOS `cupsfilter` or a tiny Swift one-liner to produce a known 2-page PDF. The fastest reproducible approach: render with `PDFDocument` from text.

Run:

```bash
mkdir -p Tests/AINotebookCoreTests/Fixtures
cat > /tmp/make-sample-pdf.swift <<'SWIFT'
import AppKit
import PDFKit
let pages = ["First page text.\nLine two.", "Second page text."]
let doc = PDFDocument()
for (i, body) in pages.enumerated() {
    let attr = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    let page = PDFPage(image: NSImage(size: NSSize(width: 612, height: 792)))!
    let mutable = NSMutableAttributedString(attributedString: attr)
    page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
    page.setString(mutable.string, for: .body)  // PDFPage has no setString; we use a workaround:
    doc.insert(page, at: i)
}
doc.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
# That sketch fails because PDFPage has no public string setter. Use the
# more reliable approach: render NSAttributedString to PDF via NSPrintOperation.
cat > /tmp/make-sample-pdf.swift <<'SWIFT'
import AppKit
let pages = ["First page text. Line two.", "Second page text."]
let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
view.string = pages.joined(separator: "\n\u{0C}\n")  // \u{0C} = form-feed
let data = view.dataWithPDF(inside: view.bounds)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swift /tmp/make-sample-pdf.swift Tests/AINotebookCoreTests/Fixtures/sample.pdf
ls -la Tests/AINotebookCoreTests/Fixtures/sample.pdf
```

If the script fails (some macOS versions), create the fixture by hand: open TextEdit, type "First page text. Line two.\n\nSecond page text.", `File → Export as PDF`, save to `Tests/AINotebookCoreTests/Fixtures/sample.pdf`.

Sanity-check:

```bash
file Tests/AINotebookCoreTests/Fixtures/sample.pdf
```

Expected: `PDF document, version 1.x`.

- [ ] **Step 2: Write failing test**

```swift
// Tests/AINotebookCoreTests/PDFExtractorTests.swift
import XCTest
@testable import AINotebookCore

final class PDFExtractorTests: XCTestCase {
    func testExtractsTextFromMultiPagePDF() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "pdf")
        )
        let extracted = try await PDFExtractor().extract(from: url, kind: .pdf)
        XCTAssertTrue(extracted.text.contains("First page text"))
        XCTAssertTrue(extracted.text.contains("Second page text"))
        XCTAssertEqual(extracted.title, "sample")
    }

    func testThrowsOnNonPDF() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notpdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await PDFExtractor().extract(from: url, kind: .pdf)
            XCTFail("expected throw")
        } catch ExtractorError.pdfOpenFailed {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 3: Verify fail**

```bash
swift test --filter PDFExtractorTests 2>&1 | tail -10
```

Expected: fail.

- [ ] **Step 4: Implement**

```swift
// Sources/AINotebookCore/PDFExtractor.swift
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

public struct PDFExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        guard let doc = PDFDocument(url: url) else {
            throw ExtractorError.pdfOpenFailed(url)
        }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i), let s = p.string {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            }
        }
        let joined = parts.joined(separator: "\n\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return ExtractedText(title: title, text: trimmed)
    }
}
```

- [ ] **Step 5: Verify pass**

```bash
swift test --filter PDFExtractorTests 2>&1 | tail -10
```

Expected: 2/2 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/PDFExtractor.swift Tests/AINotebookCoreTests/PDFExtractorTests.swift Tests/AINotebookCoreTests/Fixtures/sample.pdf
git commit -m "feat(core): PDFExtractor via PDFKit"
```

---

## Task 11: `WebExtractor` (URLSession + SwiftSoup) + CI privacy gate

**Files:** Create `Sources/AINotebookCore/WebExtractor.swift`, fixture `Tests/AINotebookCoreTests/Fixtures/sample.html`, test `Tests/AINotebookCoreTests/WebExtractorTests.swift`, modify `.github/workflows/core-ci.yml`

- [ ] **Step 1: Add the fixture**

```bash
cat > Tests/AINotebookCoreTests/Fixtures/sample.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>Sample Article</title></head>
<body>
  <nav>Site nav (should be stripped)</nav>
  <article>
    <h1>Sample Article</h1>
    <p>This is the main article body. It has <a href="#">a link</a> inside it.</p>
    <p>Another paragraph.</p>
    <script>console.log("never extract me")</script>
  </article>
  <footer>Copyright (should be stripped)</footer>
</body>
</html>
HTML
```

- [ ] **Step 2: Write failing test**

```swift
// Tests/AINotebookCoreTests/WebExtractorTests.swift
import XCTest
@testable import AINotebookCore

final class WebExtractorTests: XCTestCase {

    func testExtractsArticleBodyAndTitleFromHTML() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "html")
        )
        let html = try String(contentsOf: url, encoding: .utf8)
        let extracted = try WebExtractor.parseHTML(html, sourceURL: URL(string: "https://example.com/a")!)
        XCTAssertEqual(extracted.title, "Sample Article")
        XCTAssertTrue(extracted.text.contains("main article body"))
        XCTAssertTrue(extracted.text.contains("Another paragraph"))
        XCTAssertFalse(extracted.text.contains("never extract me"))
        XCTAssertFalse(extracted.text.contains("Site nav"))
        XCTAssertFalse(extracted.text.contains("Copyright"))
    }

    func testParseHTMLThrowsOnEmptyBody() {
        let html = "<html><head><title>T</title></head><body></body></html>"
        do {
            _ = try WebExtractor.parseHTML(html, sourceURL: URL(string: "https://example.com")!)
            XCTFail("expected throw")
        } catch ExtractorError.emptyContent {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 3: Verify fail**

```bash
swift test --filter WebExtractorTests 2>&1 | tail -10
```

Expected: fail.

- [ ] **Step 4: Implement**

```swift
// Sources/AINotebookCore/WebExtractor.swift
import Foundation
import SwiftSoup

public struct WebExtractor: TextExtractor {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ExtractorError.webFetchFailed(url, status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExtractorError.webFetchFailed(url, status: http.statusCode)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")
        guard (mime ?? "").lowercased().contains("text/html") else {
            throw ExtractorError.webResponseNotHTML(url, mime: mime)
        }
        let html = String(decoding: data, as: UTF8.self)
        return try Self.parseHTML(html, sourceURL: url)
    }

    /// Pure HTML → ExtractedText. Tested independently so we don't need a
    /// network stub in unit tests.
    static func parseHTML(_ html: String, sourceURL: URL) throws -> ExtractedText {
        let doc = try SwiftSoup.parse(html)
        // Remove non-content elements before reading the body.
        for tag in ["script", "style", "nav", "footer", "aside", "header", "noscript", "form"] {
            for el in try doc.select(tag).array() {
                try el.remove()
            }
        }
        // Prefer <article> when present, otherwise <main>, otherwise <body>.
        let root: Element
        if let art = try doc.select("article").first() {
            root = art
        } else if let main = try doc.select("main").first() {
            root = main
        } else if let body = doc.body() {
            root = body
        } else {
            throw ExtractorError.emptyContent
        }
        let text = try root.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let docTitle = (try? doc.title()) ?? ""
        let title = docTitle.isEmpty ? (sourceURL.host ?? "Web source") : docTitle
        return ExtractedText(title: title, text: text)
    }
}
```

- [ ] **Step 5: Update CI privacy gate**

In `.github/workflows/core-ci.yml`, find the `URLSession` grep step. Currently it excludes `OllamaClient.swift`. Extend the exclusion to also allow `WebExtractor.swift`. Concretely, change the grep invocation to look like:

```yaml
        run: |
          set -e
          BAD=$(grep -rn 'URLSession' Sources/AINotebookCore \
              --exclude='OllamaClient.swift' \
              --exclude='WebExtractor.swift' || true)
          if [ -n "$BAD" ]; then
            echo "Unexpected URLSession usage in AINotebookCore:"
            echo "$BAD"
            exit 1
          fi
```

(Use the exact `grep` invocation that already exists in the workflow; just add `--exclude='WebExtractor.swift'` to the existing line.)

- [ ] **Step 6: Run grep locally to confirm**

```bash
grep -rn 'URLSession' Sources/AINotebookCore \
    --exclude='OllamaClient.swift' \
    --exclude='WebExtractor.swift'
```

Expected: no output (exit code 1 from `grep` is normal — "no matches" means we pass).

- [ ] **Step 7: Verify pass**

```bash
swift test --filter WebExtractorTests 2>&1 | tail -10
```

Expected: 2/2 pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/AINotebookCore/WebExtractor.swift Tests/AINotebookCoreTests/WebExtractorTests.swift Tests/AINotebookCoreTests/Fixtures/sample.html .github/workflows/core-ci.yml
git commit -m "feat(core): WebExtractor (URLSession + SwiftSoup) + CI gate exemption"
```

---

## Task 12: `OfficeExtractor` (docx / pptx / xlsx)

Docx, pptx, and xlsx are all ZIP archives with XML payloads. We extract the relevant XML and pull the visible text via `XMLParser`. No third-party Office library — Foundation + ZIPFoundation is enough.

**Files:** Create `Sources/AINotebookCore/OfficeExtractor.swift`, three fixtures, test `Tests/AINotebookCoreTests/OfficeExtractorTests.swift`

- [ ] **Step 1: Generate fixtures**

The simplest reliable path: open Pages / Numbers / Keynote (or LibreOffice) and create one-paragraph documents containing the marker text `M3 OFFICE TEST DOCUMENT BODY`, then export as docx / pptx / xlsx. Save to:

```
Tests/AINotebookCoreTests/Fixtures/sample.docx
Tests/AINotebookCoreTests/Fixtures/sample.pptx
Tests/AINotebookCoreTests/Fixtures/sample.xlsx
```

Sanity-check:

```bash
unzip -l Tests/AINotebookCoreTests/Fixtures/sample.docx | head -5
unzip -l Tests/AINotebookCoreTests/Fixtures/sample.pptx | head -5
unzip -l Tests/AINotebookCoreTests/Fixtures/sample.xlsx | head -5
```

Expected: each lists `word/document.xml`, `ppt/slides/slide1.xml`, or `xl/sharedStrings.xml` respectively.

- [ ] **Step 2: Write failing test**

```swift
// Tests/AINotebookCoreTests/OfficeExtractorTests.swift
import XCTest
@testable import AINotebookCore

final class OfficeExtractorTests: XCTestCase {

    private let marker = "M3 OFFICE TEST DOCUMENT BODY"

    func testExtractsDocxBodyText() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "docx"))
        let extracted = try await OfficeExtractor().extract(from: url, kind: .docx)
        XCTAssertTrue(extracted.text.contains(marker), "got: \(extracted.text)")
        XCTAssertFalse(extracted.text.isEmpty)
    }

    func testExtractsPptxSlideText() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "pptx"))
        let extracted = try await OfficeExtractor().extract(from: url, kind: .pptx)
        XCTAssertTrue(extracted.text.contains(marker))
    }

    func testExtractsXlsxSharedStrings() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "xlsx"))
        let extracted = try await OfficeExtractor().extract(from: url, kind: .xlsx)
        XCTAssertTrue(extracted.text.contains(marker))
    }

    func testCorruptArchiveThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake.docx")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await OfficeExtractor().extract(from: url, kind: .docx)
            XCTFail("expected throw")
        } catch ExtractorError.officeArchiveCorrupt {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 3: Verify fail**

```bash
swift test --filter OfficeExtractorTests 2>&1 | tail -10
```

Expected: fail.

- [ ] **Step 4: Implement**

```swift
// Sources/AINotebookCore/OfficeExtractor.swift
import Foundation
import ZIPFoundation

public struct OfficeExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ExtractorError.officeArchiveCorrupt(url)
        }
        let xmlPaths: [String]
        switch kind {
        case .docx: xmlPaths = ["word/document.xml"]
        case .pptx: xmlPaths = try Self.slidePaths(in: archive)
        case .xlsx: xmlPaths = ["xl/sharedStrings.xml"]
        default:
            throw ExtractorError.officeArchiveCorrupt(url)
        }

        var collected: [String] = []
        for path in xmlPaths {
            guard let entry = archive[path] else { continue }
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            let text = Self.parseXMLTextNodes(bytes)
            if !text.isEmpty { collected.append(text) }
        }
        let joined = collected.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let title = url.deletingPathExtension().lastPathComponent
        return ExtractedText(title: title, text: joined)
    }

    /// pptx stores each slide as `ppt/slides/slideN.xml`. Enumerate them.
    private static func slidePaths(in archive: Archive) throws -> [String] {
        var paths: [String] = []
        for entry in archive {
            let p = entry.path
            if p.hasPrefix("ppt/slides/slide"), p.hasSuffix(".xml") {
                paths.append(p)
            }
        }
        return paths.sorted()
    }

    /// XMLParser-driven plain-text extraction. Collects all character data,
    /// joined by spaces.
    static func parseXMLTextNodes(_ data: Data) -> String {
        let parser = XMLParser(data: data)
        let collector = TextCollector()
        parser.delegate = collector
        parser.parse()
        return collector.text
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TextCollector: NSObject, XMLParserDelegate {
    var text: [String] = []

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { text.append(t) }
    }
}
```

- [ ] **Step 5: Verify pass**

```bash
swift test --filter OfficeExtractorTests 2>&1 | tail -10
```

Expected: 4/4 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/OfficeExtractor.swift Tests/AINotebookCoreTests/OfficeExtractorTests.swift Tests/AINotebookCoreTests/Fixtures/sample.docx Tests/AINotebookCoreTests/Fixtures/sample.pptx Tests/AINotebookCoreTests/Fixtures/sample.xlsx
git commit -m "feat(core): OfficeExtractor (docx/pptx/xlsx via ZIPFoundation + XMLParser)"
```

---

## Task 13: `IngestionService` orchestrator

**Files:** Create `Sources/AINotebookCore/IngestionService.swift`, test `Tests/AINotebookCoreTests/IngestionServiceTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/IngestionServiceTests.swift
import XCTest
@testable import AINotebookCore

final class IngestionServiceTests: XCTestCase {

    func testIngestPlainTextEndToEnd() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("memo.txt")
        try "Hello world. Second sentence.".write(to: file, atomically: true, encoding: .utf8)

        let service = IngestionService(store: store)
        let source = try await service.ingestFile(file, into: nb.id!)

        // Refresh status from disk
        let reloaded = try XCTUnwrap(try store.source(id: source.id!))
        XCTAssertEqual(reloaded.status, .ready)
        XCTAssertEqual(reloaded.type, .text)
        XCTAssertEqual(reloaded.title, "memo")

        let chunks = try store.chunks(sourceId: source.id!)
        XCTAssertGreaterThan(chunks.count, 0)
        XCTAssertEqual(chunks.first?.ord, 0)
    }

    func testIngestRawTextCreatesPersistedSource() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let service = IngestionService(store: store)
        let source = try await service.ingestRawText(
            title: "My note",
            text: String(repeating: "lorem ipsum ", count: 500),
            into: nb.id!
        )
        XCTAssertEqual(source.status, .ready)
        XCTAssertEqual(source.type, .text)
        let chunks = try store.chunks(sourceId: source.id!)
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testIngestUnknownExtensionLeavesSourceInErrorStatus() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mystery.bin")
        try Data([0x01, 0x02, 0x03]).write(to: file)

        let service = IngestionService(store: store)
        do {
            _ = try await service.ingestFile(file, into: nb.id!)
            XCTFail("expected throw for unsupported extension")
        } catch IngestionService.IngestionError.unsupportedExtension {
            // ok — no source row should have been created
            XCTAssertEqual(try store.sources(notebookId: nb.id!).count, 0)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter IngestionServiceTests 2>&1 | tail -10
```

Expected: fail.

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/IngestionService.swift
import Foundation

/// Orchestrates: type-detect → text-extract → chunk → persist, updating
/// the source's status row at every stage. Mutating store calls are
/// serialised through the store's `@MainActor`; the heavy extraction work
/// runs off-actor.
public final class IngestionService: Sendable {
    public enum IngestionError: Error, Equatable {
        case unsupportedExtension(String)
    }

    private let store: NotebookStore
    private let plain:  TextExtractor
    private let pdf:    TextExtractor
    private let web:    TextExtractor
    private let office: TextExtractor

    public init(
        store: NotebookStore,
        plain:  TextExtractor = PlainTextExtractor(),
        pdf:    TextExtractor = PDFExtractor(),
        web:    TextExtractor = WebExtractor(),
        office: TextExtractor = OfficeExtractor()
    ) {
        self.store = store
        self.plain = plain
        self.pdf = pdf
        self.web = web
        self.office = office
    }

    @discardableResult
    public func ingestFile(_ url: URL, into notebookId: Int64) async throws -> Source {
        guard let kind = SourceType.detect(filename: url.lastPathComponent) else {
            throw IngestionError.unsupportedExtension(url.pathExtension)
        }
        let title = url.deletingPathExtension().lastPathComponent
        let source = try await MainActor.run {
            try store.createSource(
                notebookId: notebookId,
                type: kind,
                title: title,
                uri: nil,
                rawPath: url.path
            )
        }
        return try await runPipeline(for: source) { [self] in
            switch kind {
            case .pdf:                                  return try await pdf.extract(from: url, kind: kind)
            case .text, .markdown:                      return try await plain.extract(from: url, kind: kind)
            case .docx, .pptx, .xlsx:                   return try await office.extract(from: url, kind: kind)
            case .web:                                  return try await web.extract(from: url, kind: kind)
            }
        }
    }

    @discardableResult
    public func ingestRawText(title: String, text: String, into notebookId: Int64) async throws -> Source {
        let source = try await MainActor.run {
            try store.createSource(
                notebookId: notebookId,
                type: .text,
                title: title,
                uri: nil,
                rawPath: nil
            )
        }
        return try await runPipeline(for: source) {
            ExtractedText(title: title, text: text)
        }
    }

    @discardableResult
    public func ingestURL(_ url: URL, into notebookId: Int64) async throws -> Source {
        let source = try await MainActor.run {
            try store.createSource(
                notebookId: notebookId,
                type: .web,
                title: url.host ?? url.absoluteString,
                uri: url.absoluteString,
                rawPath: nil
            )
        }
        return try await runPipeline(for: source) { [self] in
            try await web.extract(from: url, kind: .web)
        }
    }

    private func runPipeline(
        for sourceIn: Source,
        extract: () async throws -> ExtractedText
    ) async throws -> Source {
        var source = sourceIn
        do {
            try await MainActor.run {
                try store.updateSourceStatus(id: source.id!, status: .chunking, error: nil)
            }
            let extracted = try await extract()
            let chunks = Chunker.chunk(extracted.text)
            try await MainActor.run {
                try store.replaceChunks(sourceId: source.id!, chunks: chunks)
                try store.updateSourceStatus(id: source.id!, status: .ready, error: nil)
            }
            source.status = .ready
            return source
        } catch {
            let message = String(describing: error)
            try? await MainActor.run {
                try store.updateSourceStatus(id: source.id!, status: .error, error: message)
            }
            throw error
        }
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter IngestionServiceTests 2>&1 | tail -10
```

Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/IngestionService.swift Tests/AINotebookCoreTests/IngestionServiceTests.swift
git commit -m "feat(core): IngestionService — extract → chunk → persist with status"
```

---

## Task 14: Localization keys for source UI

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, modify `Tests/AINotebookCoreTests/LocalizationTests.swift`

- [ ] **Step 1: Read current strings file**

```bash
sed -n '1,40p' Sources/AINotebookCore/Localization.swift
```

- [ ] **Step 2: Add the new keys (mirror existing `AppText` shape)**

For every new key, add the English value, then the matching Czech value. The keys to add — with their bilingual values — are:

| key | EN | CS |
|---|---|---|
| `sourcesSectionTitle` | "Sources" | "Zdroje" |
| `addSourceButton` | "Add source" | "Přidat zdroj" |
| `addSourceSheetTitle` | "Add a source" | "Přidat zdroj" |
| `addSourceFromFile` | "From file…" | "Ze souboru…" |
| `addSourceFromURL` | "From URL" | "Z URL adresy" |
| `addSourceFromText` | "Paste text" | "Vložit text" |
| `addSourceURLPlaceholder` | "https://example.com/article" | "https://example.com/clanek" |
| `addSourceTitlePlaceholder` | "Title" | "Název" |
| `addSourceTextPlaceholder` | "Paste content here" | "Vložte obsah sem" |
| `addSourceConfirm` | "Add" | "Přidat" |
| `cancelButton` | "Cancel" | "Zrušit" |
| `sourceStatusPending` | "Pending" | "Čeká" |
| `sourceStatusChunking` | "Processing" | "Zpracovává se" |
| `sourceStatusReady` | "Ready" | "Hotovo" |
| `sourceStatusError` | "Error" | "Chyba" |
| `noSourcesEmptyState` | "No sources yet. Add one to get started." | "Zatím žádné zdroje. Přidejte první, abyste mohli začít." |
| `deleteSourceConfirm` | "Delete this source?" | "Smazat tento zdroj?" |
| `deleteButton` | "Delete" | "Smazat" |

(Note: `cancelButton` and `deleteButton` may already exist — if so, skip them and do not duplicate.)

Add each key to the `AppText` struct definition AND to both the English and Czech tables. Follow the exact pattern that's already in the file for `checkForUpdates`-style keys.

- [ ] **Step 3: Add tests for two representative keys (one new addition + the bilingual flip)**

Append to `Tests/AINotebookCoreTests/LocalizationTests.swift`:

```swift
    func testAddSourceButtonIsBilingual() {
        XCTAssertEqual(AppText.localized(.addSourceButton, language: .english), "Add source")
        XCTAssertEqual(AppText.localized(.addSourceButton, language: .czech),   "Přidat zdroj")
    }

    func testSourceStatusReadyIsBilingual() {
        XCTAssertEqual(AppText.localized(.sourceStatusReady, language: .english), "Ready")
        XCTAssertEqual(AppText.localized(.sourceStatusReady, language: .czech),   "Hotovo")
    }
```

(If the existing localization API is shaped differently — e.g. instance method on a `Localization` type — match that shape; the keys + values are what matter.)

- [ ] **Step 4: Verify pass**

```bash
swift test --filter LocalizationTests 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): add 18 EN/CS localization keys for source UI"
```

---

## Task 15: `AddSourceSheet` UI

**Files:** Create `Sources/AINotebookApp/AddSourceSheet.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/AddSourceSheet.swift
import SwiftUI
import AINotebookCore
import UniformTypeIdentifiers

struct AddSourceSheet: View {

    enum Tab: Hashable { case file, url, text }

    let notebookId: Int64
    let language: AppLanguage
    let ingestion: IngestionService
    @Binding var isPresented: Bool

    @State private var tab: Tab = .file
    @State private var urlString = ""
    @State private var rawTitle = ""
    @State private var rawText  = ""
    @State private var fileURL: URL?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppText.localized(.addSourceSheetTitle, language: language))
                .font(.title2).bold()

            Picker("", selection: $tab) {
                Text(AppText.localized(.addSourceFromFile, language: language)).tag(Tab.file)
                Text(AppText.localized(.addSourceFromURL,  language: language)).tag(Tab.url)
                Text(AppText.localized(.addSourceFromText, language: language)).tag(Tab.text)
            }
            .pickerStyle(.segmented)

            Group {
                switch tab {
                case .file:
                    fileSection
                case .url:
                    urlSection
                case .text:
                    textSection
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(AppText.localized(.cancelButton, language: language)) {
                    isPresented = false
                }
                .disabled(working)

                Button(AppText.localized(.addSourceConfirm, language: language)) {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || !canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }

    private var canSubmit: Bool {
        switch tab {
        case .file: return fileURL != nil
        case .url:  return URL(string: urlString)?.scheme?.hasPrefix("http") == true
        case .text: return !rawTitle.trimmingCharacters(in: .whitespaces).isEmpty
                       && !rawText .trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Choose file…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.pdf, .plainText, UTType("net.daringfireball.markdown") ?? .plainText,
                                             UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
                                             UTType("org.openxmlformats.presentationml.presentation") ?? .data,
                                             UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { fileURL = panel.url }
            }
            if let fileURL {
                Text(fileURL.lastPathComponent).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var urlSection: some View {
        TextField(
            AppText.localized(.addSourceURLPlaceholder, language: language),
            text: $urlString
        )
        .textFieldStyle(.roundedBorder)
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                AppText.localized(.addSourceTitlePlaceholder, language: language),
                text: $rawTitle
            )
            .textFieldStyle(.roundedBorder)

            TextEditor(text: $rawText)
                .frame(minHeight: 120)
                .border(.secondary.opacity(0.3))
        }
    }

    @MainActor
    private func submit() async {
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            switch tab {
            case .file:
                guard let url = fileURL else { return }
                _ = try await ingestion.ingestFile(url, into: notebookId)
            case .url:
                guard let url = URL(string: urlString) else { return }
                _ = try await ingestion.ingestURL(url, into: notebookId)
            case .text:
                _ = try await ingestion.ingestRawText(
                    title: rawTitle,
                    text: rawText,
                    into: notebookId
                )
            }
            isPresented = false
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/AddSourceSheet.swift
git commit -m "feat(app): AddSourceSheet (file / URL / paste-text tabs)"
```

---

## Task 16: `SourceListView` + wire into `NotebookDetailView`

**Files:** Create `Sources/AINotebookApp/SourceListView.swift`, modify `Sources/AINotebookApp/NotebookDetailView.swift`, modify `Sources/AINotebookApp/AINotebookApp.swift`, modify `Sources/AINotebookApp/ContentView.swift`

- [ ] **Step 1: Wrap `IngestionService` for environment injection**

Create `Sources/AINotebookApp/IngestionServiceHolder.swift`:

```swift
// Sources/AINotebookApp/IngestionServiceHolder.swift
import SwiftUI
import AINotebookCore

@MainActor
final class IngestionServiceHolder: ObservableObject {
    let service: IngestionService
    init(service: IngestionService) { self.service = service }
}
```

- [ ] **Step 2: Construct + inject in the app entry**

In `Sources/AINotebookApp/AINotebookApp.swift`, alongside the existing `NotebookStore` construction, add:

```swift
@StateObject private var ingestionHolder: IngestionServiceHolder
```

and in `init()`:

```swift
let store = try! NotebookStore(path: .production)
_storeHolder = StateObject(wrappedValue: NotebookStoreHolder(store: store))
_ingestionHolder = StateObject(wrappedValue: IngestionServiceHolder(service: IngestionService(store: store)))
```

(Use the existing `NotebookStoreHolder` name — if it differs in the codebase, match the actual name. The point is: build the `IngestionService` from the same `NotebookStore` instance.)

In the scene body, inject the holder alongside the existing store:

```swift
.environmentObject(storeHolder)
.environmentObject(ingestionHolder)
```

- [ ] **Step 3: Implement `SourceListView`**

```swift
// Sources/AINotebookApp/SourceListView.swift
import SwiftUI
import AINotebookCore

struct SourceListView: View {
    let notebook: Notebook
    let language: AppLanguage

    @EnvironmentObject private var storeHolder: NotebookStoreHolder
    @EnvironmentObject private var ingestionHolder: IngestionServiceHolder

    @State private var sources: [Source] = []
    @State private var showingAdd = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(AppText.localized(.sourcesSectionTitle, language: language))
                    .font(.title2).bold()
                Spacer()
                Button(AppText.localized(.addSourceButton, language: language)) {
                    showingAdd = true
                }
            }

            if sources.isEmpty {
                Text(AppText.localized(.noSourcesEmptyState, language: language))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                List {
                    ForEach(sources) { source in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(source.title).font(.headline)
                                Text(statusText(source.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                delete(source)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .task(id: notebook.id) { await reload() }
        .sheet(isPresented: $showingAdd, onDismiss: { Task { await reload() } }) {
            AddSourceSheet(
                notebookId: notebook.id!,
                language: language,
                ingestion: ingestionHolder.service,
                isPresented: $showingAdd
            )
        }
    }

    private func statusText(_ status: SourceStatus) -> String {
        switch status {
        case .pending:  return AppText.localized(.sourceStatusPending,  language: language)
        case .chunking: return AppText.localized(.sourceStatusChunking, language: language)
        case .ready:    return AppText.localized(.sourceStatusReady,    language: language)
        case .error:    return AppText.localized(.sourceStatusError,    language: language)
        }
    }

    private func reload() async {
        do {
            sources = try storeHolder.store.sources(notebookId: notebook.id!)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func delete(_ source: Source) {
        do {
            try storeHolder.store.deleteSource(id: source.id!)
            Task { await reload() }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
```

- [ ] **Step 4: Replace the placeholder body in `NotebookDetailView`**

Open `Sources/AINotebookApp/NotebookDetailView.swift`. Replace the existing placeholder body (the one that currently shows the notebook title and a "to be filled in" stub) with a `SourceListView`:

```swift
var body: some View {
    SourceListView(notebook: notebook, language: language)
}
```

(If the existing view exposes other props like an `onRename` button bar, keep those — wrap `SourceListView` in a `VStack` with the existing toolbar above it.)

- [ ] **Step 5: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: success. If `NotebookStoreHolder` is named differently, fix the references and rebuild.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookApp/SourceListView.swift Sources/AINotebookApp/IngestionServiceHolder.swift Sources/AINotebookApp/NotebookDetailView.swift Sources/AINotebookApp/AINotebookApp.swift
git commit -m "feat(app): SourceListView + IngestionService injection"
```

---

## Task 17: Final verification + tag + merge

- [ ] **Step 1: Clean build + full test run**

```bash
swift package clean
swift build
swift test --parallel
```

Expected:
- Build success.
- All tests pass. Approximate count: M0+M1+M2 (61) + SourceType(3) + SourceStatus(2) + MigrationV2(2) + NotebookStoreSources(6) + Chunker(5) + PlainTextExtractor(3) + PDFExtractor(2) + WebExtractor(2) + OfficeExtractor(4) + IngestionService(3) + Localization additions(2) ≈ **95 tests**.

- [ ] **Step 2: Smoke test the app — main path**

```bash
swift run AINotebookApp
```

Manually verify:
- Create a notebook.
- Open it → see empty-sources state with the localized message.
- Add a source from "Paste text" → row appears, status flips to "Ready".
- Add a `.txt` file from disk → row appears, status flips to "Ready".
- Add a known good `https://...` article URL → row appears, status flips to "Ready". (If Ollama isn't running this still works — the URL fetch doesn't go through Ollama.)
- Delete a source → row disappears.
- Switch language CS↔EN → all source UI strings flip.

- [ ] **Step 3: Tag**

```bash
git tag -a m3-ingestion -m "M3 ingestion pipeline complete"
```

- [ ] **Step 4: Merge to main**

```bash
git checkout main
git merge --ff-only m3-ingestion
git log --oneline | head -12
```

---

## Acceptance criteria (M3 done when ALL true)

- `swift build` succeeds.
- `swift test --parallel` reports ~95 tests passing, 0 failures.
- `SourceType.detect` correctly identifies all six file extensions; raw text + URL ingestion paths both work.
- `MigrationV2` adds `sources`, `source_chunks`, `sources_fts`, `chunks_fts` plus indexes; FTS triggers keep the mirror tables in sync.
- `IngestionService.ingestFile / ingestRawText / ingestURL` move a source through `pending → chunking → ready` (or `error`) with chunks persisted.
- `Chunker` produces overlapping windows under the 2 048-char cap, never splitting a word.
- `AddSourceSheet` + `SourceListView` work end-to-end in the running app; all 18 new strings render in both languages.
- CI privacy grep allows `URLSession` only in `OllamaClient.swift` and `WebExtractor.swift`.
- Local git tag `m3-ingestion` exists; `main` is fast-forwarded.

---

## Notes for the implementer

- **Office fixtures:** If the test machine lacks Pages/Numbers/Keynote, install LibreOffice and create the three Office files there. The marker string `M3 OFFICE TEST DOCUMENT BODY` is what the test grep expects — keep it literal.
- **PDF fixture:** PDFKit will accept any well-formed PDF. The minimum is a text-bearing two-page document containing "First page text" and "Second page text" as visible glyphs.
- **ZIPFoundation API:** `Archive.init(url:accessMode:)` returns `nil` (no throw) on a corrupt archive — that's why the implementation maps `nil` to `ExtractorError.officeArchiveCorrupt`. If the dependency version differs and the initializer throws instead, wrap in `do/catch` and map the thrown error the same way.
- **MainActor.run vs await store.method:** `NotebookStore` is `@MainActor`-isolated. Calls from the `IngestionService` (non-isolated) must hop to the main actor — `MainActor.run { try store.... }` is the idiomatic way to do this from an async context.
- **SwiftSoup version pin:** 2.7.0 is the last release tested against Swift 6 at the time of writing. If a newer release ships, bump and re-run the test suite.
- **Background pipelines (M4 boomerang):** This plan runs ingestion synchronously on the calling task — fine for v1 single-user. M4 (embedding) will likely move the orchestrator to a background actor so the user can keep typing while large PDFs ingest.
