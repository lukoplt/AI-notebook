# AI Notebook M1 — Storage + Notebook CRUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persistent SQLite-backed notebooks with full CRUD in the sidebar UI — create, list, select, rename, delete. The detail pane shows the selected notebook's header and placeholder tabs (Sources / Chat / Notes / Transformations) that later milestones fill in.

**Architecture:** Add [GRDB.swift](https://github.com/groue/GRDB.swift) as the SQLite wrapper. `NotebookStore` owns the database file and exposes synchronous CRUD methods over an `@MainActor`-isolated `DatabaseQueue`. A `MigrationV1` registrar creates the `notebooks` table on first launch (sources / chunks / etc. arrive in later milestones). The DB file lives at `~/Library/Application Support/AINotebook/db.sqlite` in production, or in-memory for tests via an injected `StorePath`. SwiftUI views observe `NotebookStore`'s `@Published` notebook list and call CRUD methods directly — no view-model layer in M1.

**Tech Stack:** Swift 6.0, SwiftUI, GRDB.swift 7.x, SQLite (via GRDB), XCTest.

**Branch:** `m1-storage` (created from `main` at the start).

---

## File Structure

| Path | Purpose |
|---|---|
| `Package.swift` | Modified: add GRDB dependency to AINotebookCore. |
| `Sources/AINotebookCore/StorePath.swift` | Pure value — resolves DB file URL or in-memory marker. Testable. |
| `Sources/AINotebookCore/StoreError.swift` | `enum StoreError: Error` with cases for not-found, invalid-name, schema-mismatch. |
| `Sources/AINotebookCore/Notebook.swift` | `struct Notebook` — id, name, description, createdAt, updatedAt. Codable + GRDB FetchableRecord/PersistableRecord. |
| `Sources/AINotebookCore/MigrationV1.swift` | Function `registerMigrationV1(on: DatabaseMigrator)` — creates `notebooks` table + indexes. |
| `Sources/AINotebookCore/NotebookStore.swift` | `@MainActor` `ObservableObject`. Owns `DatabaseQueue`. CRUD: `listNotebooks()`, `createNotebook(name:description:)`, `renameNotebook(id:newName:)`, `deleteNotebook(id:)`. `@Published var notebooks: [Notebook]`. |
| `Sources/AINotebookCore/Localization.swift` | Modified: add new keys (`renameNotebook`, `deleteNotebook`, `notebookName`, `notebookDescription`, `cancel`, `create`, `save`, `delete`, `confirmDeleteNotebook`, `cannotBeEmpty`, etc.). |
| `Sources/AINotebookApp/AINotebookApp.swift` | Modified: instantiate `NotebookStore`, inject into env alongside `AppSettings`. |
| `Sources/AINotebookApp/ContentView.swift` | Modified: real sidebar selection state, wire `NotebookDetailView`. |
| `Sources/AINotebookApp/SidebarView.swift` | List of notebooks, `+` toolbar to open `NewNotebookSheet`, context menu rename/delete. |
| `Sources/AINotebookApp/NewNotebookSheet.swift` | Sheet form: name + description, validates non-empty name. |
| `Sources/AINotebookApp/RenameNotebookSheet.swift` | Sheet form: rename selected notebook. |
| `Sources/AINotebookApp/NotebookDetailView.swift` | Header (title, description, created date) + tab strip (Sources / Chat / Notes / Transformations) showing "coming soon" placeholders. |
| `Tests/AINotebookCoreTests/StorePathTests.swift` | Tests for `StorePath.production()` URL and in-memory marker. |
| `Tests/AINotebookCoreTests/NotebookStoreTests.swift` | CRUD tests against in-memory DB. |
| `Tests/AINotebookCoreTests/MigrationV1Tests.swift` | Validates schema after migration. |

---

## Task 1: Branch off main

- [ ] **Step 1: Verify clean state**

Run from `/Users/lukasoplt/Documents/AI_Notebook`:
```bash
git status
git log --oneline -1
```
Expected: `nothing to commit, working tree clean`, latest commit is M0 final.

- [ ] **Step 2: Create branch**

Run:
```bash
git checkout -b m1-storage
git status
```
Expected: `On branch m1-storage`, clean.

No commit yet — branch is the artifact.

---

## Task 2: Add GRDB.swift dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Update `Package.swift`**

Replace the entire contents of `/Users/lukasoplt/Documents/AI_Notebook/Package.swift` with:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AINotebook",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AINotebookCore",
            targets: ["AINotebookCore"]
        ),
        .executable(
            name: "AINotebookApp",
            targets: ["AINotebookApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "AINotebookCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "AINotebookApp",
            dependencies: ["AINotebookCore"]
        ),
        .testTarget(
            name: "AINotebookCoreTests",
            dependencies: ["AINotebookCore"]
        )
    ]
)
```

- [ ] **Step 2: Resolve + build**

Run:
```bash
swift package resolve
swift build
```
Expected: GRDB downloads, full build succeeds. The `Package.resolved` lockfile is created.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build(core): add GRDB.swift 7.x dependency"
```

---

## Task 3: `StorePath`

**Files:**
- Create: `Sources/AINotebookCore/StorePath.swift`
- Create: `Tests/AINotebookCoreTests/StorePathTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AINotebookCoreTests/StorePathTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class StorePathTests: XCTestCase {
    func testInMemoryMarker() {
        let path = StorePath.inMemory
        XCTAssertTrue(path.isInMemory)
        XCTAssertNil(path.fileURL)
    }

    func testProductionURLLandsInAppSupportSubdirectory() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let path = try StorePath.production()
        XCTAssertFalse(path.isInMemory)

        let url = try XCTUnwrap(path.fileURL)
        XCTAssertEqual(url.lastPathComponent, "db.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "AINotebook")
        XCTAssertTrue(url.path.hasPrefix(appSupport.path))
    }

    func testProductionCreatesContainerDirectory() throws {
        let path = try StorePath.production()
        let dir = try XCTUnwrap(path.fileURL?.deletingLastPathComponent())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter StorePathTests
```
Expected: FAIL — `StorePath` not defined.

- [ ] **Step 3: Write implementation**

Create `Sources/AINotebookCore/StorePath.swift`:

```swift
import Foundation

/// Where the SQLite database lives. Either an on-disk file URL or an
/// in-memory marker for tests. Pulled out so production code resolves the
/// Application Support path while tests inject a fully in-memory store.
public struct StorePath: Sendable {
    public let fileURL: URL?

    public var isInMemory: Bool { fileURL == nil }

    public static let inMemory = StorePath(fileURL: nil)

    /// Returns `~/Library/Application Support/AINotebook/db.sqlite`,
    /// creating the parent directory on demand.
    public static func production(
        fileManager: FileManager = .default
    ) throws -> StorePath {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let container = appSupport.appendingPathComponent("AINotebook", isDirectory: true)
        try fileManager.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        return StorePath(fileURL: container.appendingPathComponent("db.sqlite"))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter StorePathTests
```
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/StorePath.swift Tests/AINotebookCoreTests/StorePathTests.swift
git commit -m "feat(core): add StorePath (file URL vs in-memory marker)"
```

---

## Task 4: `Notebook` model

**Files:**
- Create: `Sources/AINotebookCore/Notebook.swift`
- Create: `Tests/AINotebookCoreTests/NotebookTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AINotebookCoreTests/NotebookTests.swift`:

```swift
import XCTest
import GRDB
@testable import AINotebookCore

final class NotebookTests: XCTestCase {
    func testInitDefaultsTimestamps() {
        let n = Notebook(name: "Research")
        XCTAssertNil(n.id)
        XCTAssertEqual(n.name, "Research")
        XCTAssertEqual(n.description, "")
        XCTAssertEqual(n.createdAt, n.updatedAt)
        XCTAssertLessThan(abs(n.createdAt.timeIntervalSinceNow), 1.0)
    }

    func testExplicitFields() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let n = Notebook(
            id: 42,
            name: "Lit Review",
            description: "PhD readings",
            createdAt: now,
            updatedAt: now
        )
        XCTAssertEqual(n.id, 42)
        XCTAssertEqual(n.name, "Lit Review")
        XCTAssertEqual(n.description, "PhD readings")
        XCTAssertEqual(n.createdAt, now)
        XCTAssertEqual(n.updatedAt, now)
    }

    func testTableNameIsNotebooks() {
        XCTAssertEqual(Notebook.databaseTableName, "notebooks")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter NotebookTests
```
Expected: FAIL — `Notebook` not defined.

- [ ] **Step 3: Write implementation**

Create `Sources/AINotebookCore/Notebook.swift`:

```swift
import Foundation
import GRDB

public struct Notebook: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var description: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

extension Notebook: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notebooks"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let description = Column(CodingKeys.description)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let updatedAt = Column(CodingKeys.updatedAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter NotebookTests
```
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Notebook.swift Tests/AINotebookCoreTests/NotebookTests.swift
git commit -m "feat(core): add Notebook model with GRDB record conformance"
```

---

## Task 5: `MigrationV1` (schema)

**Files:**
- Create: `Sources/AINotebookCore/MigrationV1.swift`
- Create: `Tests/AINotebookCoreTests/MigrationV1Tests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AINotebookCoreTests/MigrationV1Tests.swift`:

```swift
import XCTest
import GRDB
@testable import AINotebookCore

final class MigrationV1Tests: XCTestCase {
    func testMigrationCreatesNotebooksTable() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let exists = try db.tableExists("notebooks")
            XCTAssertTrue(exists, "notebooks table missing")

            let columns = try db.columns(in: "notebooks").map(\.name).sorted()
            XCTAssertEqual(
                columns,
                ["created_at", "description", "id", "name", "updated_at"]
            )
        }
    }

    func testNameIndexExists() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let indexes = try db.indexes(on: "notebooks").map(\.name)
            XCTAssertTrue(
                indexes.contains("notebooks_name_idx"),
                "expected notebooks_name_idx, got \(indexes)"
            )
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter MigrationV1Tests
```
Expected: FAIL — `registerMigrationV1` not defined.

- [ ] **Step 3: Write implementation**

Create `Sources/AINotebookCore/MigrationV1.swift`:

```swift
import GRDB

/// Schema v1 — adds only the `notebooks` table. Subsequent migrations
/// (v2, v3, …) add sources, chunks, notes, etc.
public func registerMigrationV1(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v1_notebooks") { db in
        try db.create(table: "notebooks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("description", .text).notNull().defaults(to: "")
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(
            index: "notebooks_name_idx",
            on: "notebooks",
            columns: ["name"]
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter MigrationV1Tests
```
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/MigrationV1.swift Tests/AINotebookCoreTests/MigrationV1Tests.swift
git commit -m "feat(core): add v1 schema migration (notebooks table)"
```

---

## Task 6: `StoreError`

**Files:**
- Create: `Sources/AINotebookCore/StoreError.swift`

- [ ] **Step 1: Write file**

Create `Sources/AINotebookCore/StoreError.swift`:

```swift
import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case notebookNotFound(id: Int64)
    case invalidNotebookName(String)
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notebookNotFound(let id):
            "Notebook \(id) not found."
        case .invalidNotebookName(let name):
            "Invalid notebook name: \"\(name)\"."
        }
    }
}
```

(No standalone test — exercised via `NotebookStoreTests` in Task 7.)

- [ ] **Step 2: Build**

```bash
swift build --target AINotebookCore
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookCore/StoreError.swift
git commit -m "feat(core): add StoreError"
```

---

## Task 7: `NotebookStore` (CRUD)

**Files:**
- Create: `Sources/AINotebookCore/NotebookStore.swift`
- Create: `Tests/AINotebookCoreTests/NotebookStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AINotebookCoreTests/NotebookStoreTests.swift`:

```swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class NotebookStoreTests: XCTestCase {
    private func makeStore() throws -> NotebookStore {
        try NotebookStore(path: .inMemory)
    }

    func testListEmptyByDefault() throws {
        let store = try makeStore()
        XCTAssertEqual(store.notebooks, [])
    }

    func testCreateAppendsToList() throws {
        let store = try makeStore()
        let created = try store.createNotebook(name: "Research", description: "Lit review")

        XCTAssertNotNil(created.id)
        XCTAssertEqual(created.name, "Research")
        XCTAssertEqual(created.description, "Lit review")
        XCTAssertEqual(store.notebooks.count, 1)
        XCTAssertEqual(store.notebooks.first?.id, created.id)
    }

    func testCreateTrimsName() throws {
        let store = try makeStore()
        let n = try store.createNotebook(name: "  Spaces  ")
        XCTAssertEqual(n.name, "Spaces")
    }

    func testCreateRejectsEmptyName() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.createNotebook(name: "   ")) { error in
            XCTAssertEqual(error as? StoreError, .invalidNotebookName("   "))
        }
        XCTAssertEqual(store.notebooks, [])
    }

    func testRenameUpdatesNameAndTimestamp() throws {
        let store = try makeStore()
        let n = try store.createNotebook(name: "Old")
        let originalUpdatedAt = n.updatedAt

        // sleep ensures the timestamp comparison is meaningful even on fast machines
        Thread.sleep(forTimeInterval: 0.02)

        let renamed = try store.renameNotebook(id: n.id!, newName: "New")
        XCTAssertEqual(renamed.name, "New")
        XCTAssertGreaterThan(renamed.updatedAt, originalUpdatedAt)
        XCTAssertEqual(store.notebooks.first?.name, "New")
    }

    func testRenameRejectsEmptyName() throws {
        let store = try makeStore()
        let n = try store.createNotebook(name: "Keep")
        XCTAssertThrowsError(try store.renameNotebook(id: n.id!, newName: "")) { error in
            XCTAssertEqual(error as? StoreError, .invalidNotebookName(""))
        }
    }

    func testRenameUnknownIdThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.renameNotebook(id: 999, newName: "x")) { error in
            XCTAssertEqual(error as? StoreError, .notebookNotFound(id: 999))
        }
    }

    func testDeleteRemovesFromList() throws {
        let store = try makeStore()
        let a = try store.createNotebook(name: "A")
        let b = try store.createNotebook(name: "B")
        try store.deleteNotebook(id: a.id!)
        XCTAssertEqual(store.notebooks.map(\.id), [b.id])
    }

    func testDeleteUnknownIdThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.deleteNotebook(id: 7)) { error in
            XCTAssertEqual(error as? StoreError, .notebookNotFound(id: 7))
        }
    }

    func testListSortedByUpdatedAtDescending() throws {
        let store = try makeStore()
        _ = try store.createNotebook(name: "First")
        Thread.sleep(forTimeInterval: 0.02)
        let second = try store.createNotebook(name: "Second")
        Thread.sleep(forTimeInterval: 0.02)
        let third = try store.createNotebook(name: "Third")

        XCTAssertEqual(
            store.notebooks.map(\.name),
            ["Third", "Second", "First"]
        )

        _ = try store.renameNotebook(id: second.id!, newName: "Bumped")
        XCTAssertEqual(
            store.notebooks.map(\.name),
            ["Bumped", "Third", "First"]
        )
        _ = third  // silence unused warning
    }

    func testPersistenceAcrossStoreInstances() throws {
        // Use an on-disk temp file so we can re-open it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainotebook-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("db.sqlite")
        let path = StorePath(fileURL: file)

        do {
            let store = try NotebookStore(path: path)
            _ = try store.createNotebook(name: "Persisted")
        }
        let reopened = try NotebookStore(path: path)
        XCTAssertEqual(reopened.notebooks.map(\.name), ["Persisted"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter NotebookStoreTests
```
Expected: FAIL — `NotebookStore` not defined.

- [ ] **Step 3: Write implementation**

Create `Sources/AINotebookCore/NotebookStore.swift`:

```swift
import Foundation
import GRDB

/// Owns the SQLite database file and exposes synchronous CRUD operations
/// for notebooks. `@Published notebooks` drives the sidebar list — it is
/// refreshed from disk after every mutation.
///
/// `@MainActor` is correct here because GRDB queue reads/writes from this
/// type are short and the SwiftUI views consume the published list on the
/// main thread. Future high-throughput paths (e.g. embedding ingestion in
/// M4) will use GRDB's async APIs from background actors.
@MainActor
public final class NotebookStore: ObservableObject {
    private let dbQueue: DatabaseQueue

    @Published public private(set) var notebooks: [Notebook] = []

    public init(path: StorePath) throws {
        if let url = path.fileURL {
            self.dbQueue = try DatabaseQueue(path: url.path)
        } else {
            self.dbQueue = try DatabaseQueue()
        }
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        try migrator.migrate(dbQueue)
        try refresh()
    }

    public func refresh() throws {
        notebooks = try dbQueue.read { db in
            try Notebook
                .order(Notebook.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public func createNotebook(name: String, description: String = "") throws -> Notebook {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidNotebookName(name)
        }
        let now = Date()
        var notebook = Notebook(
            name: trimmed,
            description: description,
            createdAt: now,
            updatedAt: now
        )
        try dbQueue.write { db in
            try notebook.insert(db)
        }
        try refresh()
        return notebook
    }

    @discardableResult
    public func renameNotebook(id: Int64, newName: String) throws -> Notebook {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidNotebookName(newName)
        }
        let updated = try dbQueue.write { db -> Notebook in
            guard var existing = try Notebook.fetchOne(db, key: id) else {
                throw StoreError.notebookNotFound(id: id)
            }
            existing.name = trimmed
            existing.updatedAt = Date()
            try existing.update(db)
            return existing
        }
        try refresh()
        return updated
    }

    public func deleteNotebook(id: Int64) throws {
        let deleted = try dbQueue.write { db in
            try Notebook.deleteOne(db, key: id)
        }
        guard deleted else {
            throw StoreError.notebookNotFound(id: id)
        }
        try refresh()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter NotebookStoreTests
```
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/NotebookStoreTests.swift
git commit -m "feat(core): add NotebookStore with CRUD + observable list"
```

---

## Task 8: Add localization strings for M1 UI

**Files:**
- Modify: `Sources/AINotebookCore/Localization.swift`
- Modify: `Tests/AINotebookCoreTests/LocalizationTests.swift`

- [ ] **Step 1: Modify `LocalizationTests.swift`**

Open `/Users/lukasoplt/Documents/AI_Notebook/Tests/AINotebookCoreTests/LocalizationTests.swift` and replace the `testKnownStringsExact` method with:

```swift
    func testKnownStringsExact() {
        let en = AppText(language: .english)
        XCTAssertEqual(en.string(.settings), "Settings")
        XCTAssertEqual(en.string(.notebooks), "Notebooks")
        XCTAssertEqual(en.string(.create), "Create")
        XCTAssertEqual(en.string(.cancel), "Cancel")
        XCTAssertEqual(en.string(.delete), "Delete")

        let cs = AppText(language: .czech)
        XCTAssertEqual(cs.string(.settings), "Nastavení")
        XCTAssertEqual(cs.string(.notebooks), "Poznámkové bloky")
        XCTAssertEqual(cs.string(.create), "Vytvořit")
        XCTAssertEqual(cs.string(.cancel), "Zrušit")
        XCTAssertEqual(cs.string(.delete), "Smazat")
    }
```

- [ ] **Step 2: Run failing test**

```bash
swift test --filter LocalizationTests
```
Expected: FAIL — new keys (`create`, `cancel`, `delete`) not defined.

- [ ] **Step 3: Modify `Localization.swift`**

Open `/Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookCore/Localization.swift`. Add the following cases to the `Key` enum (insert after `createNotebook`):

```swift
        case renameNotebook
        case deleteNotebook
        case notebookName
        case notebookDescription
        case cancel
        case create
        case save
        case delete
        case confirmDeleteNotebook
        case cannotBeEmpty
        case comingSoon
        case sourcesTabComingSoon
        case chatTabComingSoon
        case notesTabComingSoon
        case transformationsTabComingSoon
```

Add the corresponding English cases inside `private func english(_:)`:

```swift
        case .renameNotebook:    "Rename notebook"
        case .deleteNotebook:    "Delete notebook"
        case .notebookName:      "Notebook name"
        case .notebookDescription: "Description (optional)"
        case .cancel:            "Cancel"
        case .create:            "Create"
        case .save:              "Save"
        case .delete:            "Delete"
        case .confirmDeleteNotebook: "Delete this notebook? This cannot be undone."
        case .cannotBeEmpty:     "Name cannot be empty."
        case .comingSoon:        "Coming soon"
        case .sourcesTabComingSoon: "Source ingestion arrives in milestone M3."
        case .chatTabComingSoon:    "Chat arrives in milestone M5."
        case .notesTabComingSoon:   "Notes arrive in milestone M6."
        case .transformationsTabComingSoon: "Transformations arrive in milestone M6."
```

Add the Czech equivalents inside `private func czech(_:)`:

```swift
        case .renameNotebook:    "Přejmenovat blok"
        case .deleteNotebook:    "Smazat blok"
        case .notebookName:      "Název bloku"
        case .notebookDescription: "Popis (volitelný)"
        case .cancel:            "Zrušit"
        case .create:            "Vytvořit"
        case .save:              "Uložit"
        case .delete:            "Smazat"
        case .confirmDeleteNotebook: "Opravdu smazat tento blok? Akci nelze vrátit zpět."
        case .cannotBeEmpty:     "Název nesmí být prázdný."
        case .comingSoon:        "Brzy"
        case .sourcesTabComingSoon: "Načítání zdrojů přijde v milníku M3."
        case .chatTabComingSoon:    "Chat přijde v milníku M5."
        case .notesTabComingSoon:   "Poznámky přijdou v milníku M6."
        case .transformationsTabComingSoon: "Transformace přijdou v milníku M6."
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter LocalizationTests
```
Expected: PASS, 4 tests (including the two coverage tests that iterate `AppText.Key.allCases`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): add M1 localization keys (notebook CRUD + tab placeholders)"
```

---

## Task 9: Inject `NotebookStore` into the app

**Files:**
- Modify: `Sources/AINotebookApp/AINotebookApp.swift`

- [ ] **Step 1: Update file**

Replace the entire contents of `Sources/AINotebookApp/AINotebookApp.swift` with:

```swift
import SwiftUI
import AINotebookCore

@main
struct AINotebookAppEntry: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: NotebookStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)

        // Crash fast on storage init failure — at this point the app cannot
        // function. A future task can replace this with a friendly first-run
        // error screen.
        let store: NotebookStore
        do {
            let path = try StorePath.production()
            store = try NotebookStore(path: path)
        } catch {
            fatalError("Failed to open AINotebook database: \(error)")
        }
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                EmptyView()
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: build succeeds. (`ContentView` does not yet read `store` — that's Task 12.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/AINotebookApp.swift
git commit -m "feat(app): inject NotebookStore via environment"
```

---

## Task 10: `NewNotebookSheet`

**Files:**
- Create: `Sources/AINotebookApp/NewNotebookSheet.swift`

- [ ] **Step 1: Write the file**

Create `Sources/AINotebookApp/NewNotebookSheet.swift`:

```swift
import SwiftUI
import AINotebookCore

struct NewNotebookSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var errorMessage: String?

    /// Called with the freshly created notebook so the parent view can
    /// select it.
    var onCreated: (Notebook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.text.string(.createNotebook))
                .font(.title3)
                .bold()

            TextField(settings.text.string(.notebookName), text: $name)
                .textFieldStyle(.roundedBorder)

            TextField(
                settings.text.string(.notebookDescription),
                text: $description,
                axis: .vertical
            )
            .lineLimit(3, reservesSpace: true)
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(settings.text.string(.cancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.text.string(.create)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func submit() {
        do {
            let created = try store.createNotebook(name: name, description: description)
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? settings.text.string(.cannotBeEmpty)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/NewNotebookSheet.swift
git commit -m "feat(app): add NewNotebookSheet"
```

---

## Task 11: `RenameNotebookSheet`

**Files:**
- Create: `Sources/AINotebookApp/RenameNotebookSheet.swift`

- [ ] **Step 1: Write the file**

Create `Sources/AINotebookApp/RenameNotebookSheet.swift`:

```swift
import SwiftUI
import AINotebookCore

struct RenameNotebookSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss

    let notebook: Notebook
    @State private var name: String
    @State private var errorMessage: String?

    init(notebook: Notebook) {
        self.notebook = notebook
        _name = State(initialValue: notebook.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.text.string(.renameNotebook))
                .font(.title3)
                .bold()

            TextField(settings.text.string(.notebookName), text: $name)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(settings.text.string(.cancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.text.string(.save)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || name == notebook.name)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func submit() {
        guard let id = notebook.id else { return }
        do {
            _ = try store.renameNotebook(id: id, newName: name)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? settings.text.string(.cannotBeEmpty)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/RenameNotebookSheet.swift
git commit -m "feat(app): add RenameNotebookSheet"
```

---

## Task 12: `NotebookDetailView` (header + placeholder tabs)

**Files:**
- Create: `Sources/AINotebookApp/NotebookDetailView.swift`

- [ ] **Step 1: Write the file**

Create `Sources/AINotebookApp/NotebookDetailView.swift`:

```swift
import SwiftUI
import AINotebookCore

struct NotebookDetailView: View {
    @EnvironmentObject private var settings: AppSettings

    let notebook: Notebook
    @State private var selectedTab: Tab = .sources

    enum Tab: Hashable {
        case sources, chat, notes, transformations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Picker("", selection: $selectedTab) {
                Text(settings.text.string(.sources)).tag(Tab.sources)
                Text(settings.text.string(.chat)).tag(Tab.chat)
                Text(settings.text.string(.notes)).tag(Tab.notes)
                Text(settings.text.string(.transformations)).tag(Tab.transformations)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            Divider()
                .padding(.top, 12)

            placeholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notebook.name)
                .font(.title)
                .bold()
            if !notebook.description.isEmpty {
                Text(notebook.description)
                    .foregroundStyle(.secondary)
            }
            Text(notebook.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Text(settings.text.string(.comingSoon))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(comingSoonMessage)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comingSoonMessage: String {
        switch selectedTab {
        case .sources:         settings.text.string(.sourcesTabComingSoon)
        case .chat:            settings.text.string(.chatTabComingSoon)
        case .notes:           settings.text.string(.notesTabComingSoon)
        case .transformations: settings.text.string(.transformationsTabComingSoon)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/NotebookDetailView.swift
git commit -m "feat(app): add NotebookDetailView with placeholder tabs"
```

---

## Task 13: `SidebarView`

**Files:**
- Create: `Sources/AINotebookApp/SidebarView.swift`

- [ ] **Step 1: Write the file**

Create `Sources/AINotebookApp/SidebarView.swift`:

```swift
import SwiftUI
import AINotebookCore

struct SidebarView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @Binding var selection: Notebook.ID?

    @State private var showNewSheet = false
    @State private var notebookToRename: Notebook?
    @State private var notebookToDelete: Notebook?
    @State private var deleteError: String?

    var body: some View {
        List(selection: $selection) {
            Section(settings.text.string(.notebooks)) {
                ForEach(store.notebooks) { notebook in
                    NavigationLink(value: notebook.id) {
                        Text(notebook.name)
                    }
                    .contextMenu {
                        Button(settings.text.string(.renameNotebook)) {
                            notebookToRename = notebook
                        }
                        Button(role: .destructive) {
                            notebookToDelete = notebook
                        } label: {
                            Text(settings.text.string(.deleteNotebook))
                        }
                    }
                }
            }
        }
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItem {
                Button {
                    showNewSheet = true
                } label: {
                    Label(settings.text.string(.createNotebook), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewNotebookSheet { created in
                selection = created.id
            }
            .environmentObject(settings)
            .environmentObject(store)
        }
        .sheet(item: $notebookToRename) { notebook in
            RenameNotebookSheet(notebook: notebook)
                .environmentObject(settings)
                .environmentObject(store)
        }
        .alert(
            settings.text.string(.deleteNotebook),
            isPresented: deleteAlertBinding,
            presenting: notebookToDelete
        ) { notebook in
            Button(settings.text.string(.delete), role: .destructive) {
                performDelete(notebook)
            }
            Button(settings.text.string(.cancel), role: .cancel) {
                notebookToDelete = nil
            }
        } message: { _ in
            Text(settings.text.string(.confirmDeleteNotebook))
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { notebookToDelete != nil },
            set: { if !$0 { notebookToDelete = nil } }
        )
    }

    private func performDelete(_ notebook: Notebook) {
        defer { notebookToDelete = nil }
        guard let id = notebook.id else { return }
        do {
            try store.deleteNotebook(id: id)
            if selection == id { selection = nil }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
```

NOTE: `Notebook.id` is `Int64?`. `List` selection requires the optional Int64? as the binding type. Use `Notebook.ID?` which evaluates to `Int64??` — clean this up using a helper if necessary. The implementation above selects on the wrapped value because each `NavigationLink(value: notebook.id)` passes `notebook.id` which is already `Int64?`. SwiftUI's `List(selection:)` with a `@Binding<Notebook.ID?>` (which is `Binding<Int64??>`) is awkward. Simplify by binding selection to `Int64?` directly — fix in Task 14 if needed.

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: build may fail with a selection-type error. If so, change the `selection` binding type from `Notebook.ID?` to `Int64?` and re-build until clean.

If the build still fails, simplify `NavigationLink(value: notebook.id)` to `NavigationLink(value: notebook.id ?? -1)` and select on `Int64`. Document the workaround inline. Report back if neither works.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/SidebarView.swift
git commit -m "feat(app): add SidebarView with CRUD context menu + new-notebook button"
```

---

## Task 14: Wire sidebar + detail in `ContentView`

**Files:**
- Modify: `Sources/AINotebookApp/ContentView.swift`

- [ ] **Step 1: Replace `ContentView.swift`**

Replace the entire contents of `/Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookApp/ContentView.swift` with:

```swift
import SwiftUI
import AINotebookCore

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @State private var selectedNotebookId: Int64?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedNotebookId)
                .environmentObject(settings)
                .environmentObject(store)
        } detail: {
            detail
        }
        .navigationTitle(settings.text.string(.appName))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label(settings.text.string(.settings), systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedNotebookId,
           let notebook = store.notebooks.first(where: { $0.id == id }) {
            NotebookDetailView(notebook: notebook)
                .environmentObject(settings)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(settings.text.string(.noNotebookSelected))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    let settings = AppSettings(
        defaults: UserDefaults(suiteName: "preview-content")!,
        preferredLanguages: ["en-US"]
    )
    return ContentView()
        .environmentObject(settings)
        // NotebookStore cannot easily be constructed in #Preview because the
        // in-memory init can throw — skip the env object; SwiftUI previews
        // for this view need the running app.
}
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: build succeeds. (Preview block may emit a warning about the missing env object but won't break compile.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/ContentView.swift
git commit -m "feat(app): wire sidebar selection to NotebookDetailView"
```

---

## Task 15: Final verification

- [ ] **Step 1: Clean build + full test run**

```bash
swift package clean
swift build
swift test --parallel
```

Expected:
- Build success.
- Test count: M0 baseline 19 + StorePath 3 + Notebook 3 + MigrationV1 2 + NotebookStore 11 + Localization remains 4 = **42 tests**, 0 failures.

- [ ] **Step 2: Smoke test the app**

```bash
swift run AINotebookApp
```

Expected (manual checks):
- Window opens, sidebar shows empty "Notebooks" section + `+` button.
- Click `+` → sheet → name "Test" → Create → row appears in sidebar, selected, detail header shows "Test".
- Right-click row → Rename → change to "Test 2" → Save → sidebar updates, detail header updates.
- Right-click row → Delete → confirm → row disappears, detail returns to "No notebook selected".
- Quit and relaunch app → previously-created notebooks (if any survived) persist (i.e. if Delete was not done they are still there).
- Switch to Czech in Settings → sidebar header reads "Poznámkové bloky", buttons localize.

Stop with Cmd-Q after verifying.

- [ ] **Step 3: Tag the milestone**

```bash
git tag -a m1-storage -m "M1 storage + notebook CRUD complete"
git tag -l
```

- [ ] **Step 4: Merge to main**

```bash
git checkout main
git merge --ff-only m1-storage
git log --oneline | head -5
```

---

## Acceptance criteria (M1 done when ALL true)

- `swift build` succeeds with no warnings related to AINotebook code.
- `swift test --parallel` reports 42 passing tests, 0 failures.
- App can create / list / select / rename / delete notebooks via UI.
- Notebooks persist across app restarts.
- Language switch updates all M1 UI strings (sidebar, sheet labels, buttons, alert text).
- Local git tag `m1-storage` exists; `main` is fast-forwarded.

---

## Notes for the implementer

- **GRDB on macOS:** GRDB 7.x is Swift 6 ready and ships its own `DatabaseQueue`. No SQLite manual link needed.
- **`@MainActor` on `NotebookStore`:** intentional for M1. M4 (embeddings) will introduce a separate background actor for bulk operations; the store itself stays on main.
- **Selection type:** `Notebook.id` is `Int64?`. If the SwiftUI `List(selection:)` machinery objects to `Int64??`, fall back to selecting on `Int64` and treat `-1` as "none". The plan flags this in Task 13 — fix on first build attempt rather than litigating it in advance.
- **No view-model layer in M1.** Views call store methods directly. This keeps M1 small. A view-model layer arrives only if M4/M5 needs it.
