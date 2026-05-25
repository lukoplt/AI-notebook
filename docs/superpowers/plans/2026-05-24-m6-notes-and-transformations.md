# M6: Notes + Transformations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two remaining notebook tabs from the design spec: a Markdown notes editor (manual + AI-generated) and a transformations panel that runs prompt templates over sources and saves results as notes.

**Architecture:** A new `MigrationV5` adds `notes`, `transformations`, and `transformation_runs` tables (final schema from the design spec). Three new `NotebookStore` extensions expose CRUD. A `TransformationEngine` actor (parallel to `ChatEngine`) runs a template's prompt over a source's chunks via `OllamaClient`, awaits the full reply (non-streaming for v1), and persists it as a note linked to the source. Three built-in transformations (Summary, Key points, Entities) get seeded on first launch. SwiftUI gets a `NotesView` (sidebar of note titles + Markdown editor on the right) and a `TransformationsView` (template picker + source picker + run button + result preview that can save-as-note).

**Tech Stack:** Swift 6, GRDB (existing), `OllamaClient.chat` non-streaming wrapper (existing M2/M5), SwiftUI's `TextEditor` + monospaced Markdown rendering.

---

## File Structure

**Create:**
- `Sources/AINotebookCore/MigrationV5.swift` — notes, transformations, transformation_runs tables
- `Sources/AINotebookCore/Note.swift` — model + GRDB record + NoteOrigin enum
- `Sources/AINotebookCore/Transformation.swift` — model + GRDB record + TransformationScope enum
- `Sources/AINotebookCore/TransformationRun.swift` — model + GRDB record (history of runs)
- `Sources/AINotebookCore/NotebookStore+Notes.swift` — note CRUD
- `Sources/AINotebookCore/NotebookStore+Transformations.swift` — transformation CRUD + runs
- `Sources/AINotebookCore/BuiltinTransformations.swift` — seed Summary/Key points/Entities on first launch
- `Sources/AINotebookCore/TransformationEngine.swift` — actor: template + source(s) → note
- `Sources/AINotebookApp/TransformationEngineHolder.swift`
- `Sources/AINotebookApp/NotesView.swift`
- `Sources/AINotebookApp/NoteEditor.swift`
- `Sources/AINotebookApp/TransformationsView.swift`
- `Tests/AINotebookCoreTests/MigrationV5Tests.swift`
- `Tests/AINotebookCoreTests/NotebookStoreNotesTests.swift`
- `Tests/AINotebookCoreTests/NotebookStoreTransformationsTests.swift`
- `Tests/AINotebookCoreTests/BuiltinTransformationsTests.swift`
- `Tests/AINotebookCoreTests/TransformationEngineTests.swift`

**Modify:**
- `Sources/AINotebookCore/NotebookStore.swift` — register `MigrationV5`, seed built-ins after migration
- `Sources/AINotebookCore/Localization.swift` — add 15 EN/CS keys for notes + transformation UI
- `Sources/AINotebookApp/AINotebookApp.swift` — construct + inject `TransformationEngineHolder`
- `Sources/AINotebookApp/NotebookDetailView.swift` — swap `.notes` and `.transformations` placeholders

---

## Task 1: Branch + baseline

- [ ] **Step 1**

```bash
git checkout main
git checkout -b m6-notes-transformations
swift test --parallel 2>&1 | tail -5
```

Expected: 131/131 pass.

---

## Task 2: `MigrationV5` — notes, transformations, transformation_runs

**Files:** Create `Sources/AINotebookCore/MigrationV5.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV5Tests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV5Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV5Tests: XCTestCase {

    func testV5CreatesAllTables() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("notes"))
            XCTAssertTrue(names.contains("transformations"))
            XCTAssertTrue(names.contains("transformation_runs"))
        }
    }

    func testNotesCascadeFromNotebook() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO notes(notebook_id,title,body_md,origin,created_at,updated_at)
                VALUES (?,?,?,?,?,?)
                """,
                arguments: [nb.id!, "t", "body", "manual", Date(), Date()]
            )
        }
        try store.deleteNotebook(id: nb.id!)
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func testTransformationRunsHaveNullableSourceAndNoteRefs() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "src", uri: nil, rawPath: nil
        )
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO transformations(name,prompt_template,scope,is_builtin) VALUES (?,?,?,?)",
                arguments: ["t", "p", "source", 1]
            )
            let tid = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO transformation_runs(transformation_id,source_id,result_note_id,ran_at) VALUES (?,?,?,?)",
                arguments: [tid, s.id!, nil, Date()]
            )
        }
        // Delete the source: run row should survive with source_id = NULL.
        try store.deleteSource(id: s.id!)
        let runRow: Row? = try store.runOnDatabase { db in
            try Row.fetchOne(db, sql: "SELECT source_id FROM transformation_runs LIMIT 1")
        }
        XCTAssertNotNil(runRow)
        XCTAssertTrue(runRow!["source_id"] == nil)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter MigrationV5Tests 2>&1 | tail -10
```

- [ ] **Step 3: Implement migration**

```swift
// Sources/AINotebookCore/MigrationV5.swift
import GRDB

public func registerMigrationV5(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v5_notes_and_transformations") { db in
        try db.create(table: "notes") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("notebook_id", .integer)
                .notNull()
                .references("notebooks", onDelete: .cascade)
            t.column("title",       .text).notNull()
            t.column("body_md",     .text).notNull()
            t.column("origin",      .text).notNull()    // 'manual' | 'chat' | 'transformation'
            t.column("origin_ref",  .integer)
            t.column("created_at",  .datetime).notNull()
            t.column("updated_at",  .datetime).notNull()
        }
        try db.create(
            index: "idx_notes_notebook",
            on: "notes",
            columns: ["notebook_id", "updated_at"]
        )

        try db.create(table: "transformations") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name",            .text).notNull()
            t.column("prompt_template", .text).notNull()
            t.column("scope",           .text).notNull()    // 'source' | 'notebook'
            t.column("is_builtin",      .integer).notNull().defaults(to: 0)
        }
        try db.create(
            index: "idx_transformations_name",
            on: "transformations",
            columns: ["name"]
        )

        try db.create(table: "transformation_runs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("transformation_id", .integer)
                .notNull()
                .references("transformations", onDelete: .cascade)
            t.column("source_id", .integer)
                .references("sources", onDelete: .setNull)
            t.column("result_note_id", .integer)
                .references("notes", onDelete: .setNull)
            t.column("ran_at", .datetime).notNull()
        }
    }
}
```

- [ ] **Step 4: Register V5 in `NotebookStore.init`**

Append after `registerMigrationV4(on: &migrator)`:

```swift
        registerMigrationV5(on: &migrator)
```

- [ ] **Step 5: Verify pass + commit**

```bash
swift test --filter MigrationV5Tests 2>&1 | tail -10
git add Sources/AINotebookCore/MigrationV5.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV5Tests.swift
git commit -m "feat(core): MigrationV5 — notes + transformations + runs"
```

Expected: 3/3 pass.

---

## Task 3: `Note` model + record

**Files:** Create `Sources/AINotebookCore/Note.swift`. No standalone test — covered by Task 5.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookCore/Note.swift
import Foundation
import GRDB

public enum NoteOrigin: String, Codable, Sendable, CaseIterable {
    case manual
    case chat
    case transformation
}

public struct Note: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var notebookId: Int64
    public var title: String
    public var bodyMd: String
    public var origin: NoteOrigin
    public var originRef: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        notebookId: Int64,
        title: String,
        bodyMd: String,
        origin: NoteOrigin = .manual,
        originRef: Int64? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.notebookId = notebookId
        self.title = title
        self.bodyMd = bodyMd
        self.origin = origin
        self.originRef = originRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

extension Note: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notes"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case notebookId = "notebook_id"
        case title
        case bodyMd    = "body_md"
        case origin
        case originRef = "origin_ref"
        case createdAt = "created_at"
        case updatedAt = "updated_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookCore/Note.swift
git commit -m "feat(core): Note model + GRDB record"
```

---

## Task 4: `Transformation` + `TransformationRun` models

**Files:** Create `Sources/AINotebookCore/Transformation.swift`, `Sources/AINotebookCore/TransformationRun.swift`. No standalone test — covered by Task 6.

- [ ] **Step 1: Implement `Transformation.swift`**

```swift
// Sources/AINotebookCore/Transformation.swift
import Foundation
import GRDB

public enum TransformationScope: String, Codable, Sendable, CaseIterable {
    case source
    case notebook
}

public struct Transformation: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var promptTemplate: String
    public var scope: TransformationScope
    public var isBuiltin: Bool

    public init(
        id: Int64? = nil,
        name: String,
        promptTemplate: String,
        scope: TransformationScope = .source,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.promptTemplate = promptTemplate
        self.scope = scope
        self.isBuiltin = isBuiltin
    }
}

extension Transformation: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transformations"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case name
        case promptTemplate = "prompt_template"
        case scope
        case isBuiltin      = "is_builtin"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 2: Implement `TransformationRun.swift`**

```swift
// Sources/AINotebookCore/TransformationRun.swift
import Foundation
import GRDB

public struct TransformationRun: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var transformationId: Int64
    public var sourceId: Int64?
    public var resultNoteId: Int64?
    public var ranAt: Date

    public init(
        id: Int64? = nil,
        transformationId: Int64,
        sourceId: Int64? = nil,
        resultNoteId: Int64? = nil,
        ranAt: Date = Date()
    ) {
        self.id = id
        self.transformationId = transformationId
        self.sourceId = sourceId
        self.resultNoteId = resultNoteId
        self.ranAt = ranAt
    }
}

extension TransformationRun: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transformation_runs"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case transformationId = "transformation_id"
        case sourceId         = "source_id"
        case resultNoteId     = "result_note_id"
        case ranAt            = "ran_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookCore/Transformation.swift Sources/AINotebookCore/TransformationRun.swift
git commit -m "feat(core): Transformation + TransformationRun records"
```

---

## Task 5: `NotebookStore+Notes` — note CRUD

**Files:** Create `Sources/AINotebookCore/NotebookStore+Notes.swift`, test `Tests/AINotebookCoreTests/NotebookStoreNotesTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/NotebookStoreNotesTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreNotesTests: XCTestCase {

    func testCreateAndListNotes() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n1 = try store.createNote(
            notebookId: nb.id!, title: "First", bodyMd: "Hello"
        )
        _ = try store.createNote(
            notebookId: nb.id!, title: "Second", bodyMd: "World"
        )
        let list = try store.notes(notebookId: nb.id!)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.title)), ["First", "Second"])
        XCTAssertEqual(n1.origin, .manual)
    }

    func testUpdateNoteBumpsUpdatedAt() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        let originalUpdated = n.updatedAt
        Thread.sleep(forTimeInterval: 0.01)
        try store.updateNote(id: n.id!, title: "T2", bodyMd: "v2")
        let reloaded = try XCTUnwrap(store.note(id: n.id!))
        XCTAssertEqual(reloaded.title, "T2")
        XCTAssertEqual(reloaded.bodyMd, "v2")
        XCTAssertGreaterThan(reloaded.updatedAt, originalUpdated)
    }

    func testDeleteNote() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.deleteNote(id: n.id!)
        XCTAssertNil(try store.note(id: n.id!))
    }

    func testCreateNoteWithTransformationOriginPreservesRef() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!,
            title: "T",
            bodyMd: "x",
            origin: .transformation,
            originRef: 999
        )
        XCTAssertEqual(n.origin, .transformation)
        XCTAssertEqual(n.originRef, 999)
        let reloaded = try XCTUnwrap(store.note(id: n.id!))
        XCTAssertEqual(reloaded.originRef, 999)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter NotebookStoreNotesTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/NotebookStore+Notes.swift
import Foundation
import GRDB

extension NotebookStore {

    @discardableResult
    public func createNote(
        notebookId: Int64,
        title: String,
        bodyMd: String,
        origin: NoteOrigin = .manual,
        originRef: Int64? = nil
    ) throws -> Note {
        let now = Date()
        var note = Note(
            notebookId: notebookId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyMd: bodyMd,
            origin: origin,
            originRef: originRef,
            createdAt: now,
            updatedAt: now
        )
        try runOnDatabase { db in
            try note.insert(db)
        }
        return note
    }

    public func notes(notebookId: Int64) throws -> [Note] {
        try runOnDatabase { db in
            try Note
                .filter(Note.Columns.notebookId.column == notebookId)
                .order(Note.Columns.updatedAt.column.desc)
                .fetchAll(db)
        }
    }

    public func note(id: Int64) throws -> Note? {
        try runOnDatabase { db in
            try Note.fetchOne(db, key: id)
        }
    }

    public func updateNote(id: Int64, title: String, bodyMd: String) throws {
        try runOnDatabase { db in
            guard var n = try Note.fetchOne(db, key: id) else { return }
            n.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            n.bodyMd = bodyMd
            n.updatedAt = Date()
            try n.update(db)
        }
    }

    public func deleteNote(id: Int64) throws {
        try runOnDatabase { db in
            _ = try Note.deleteOne(db, key: id)
        }
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter NotebookStoreNotesTests 2>&1 | tail -10
git add Sources/AINotebookCore/NotebookStore+Notes.swift Tests/AINotebookCoreTests/NotebookStoreNotesTests.swift
git commit -m "feat(core): notes CRUD on NotebookStore (create/update/delete/list)"
```

Expected: 4/4 pass.

---

## Task 6: `NotebookStore+Transformations` — CRUD + runs

**Files:** Create `Sources/AINotebookCore/NotebookStore+Transformations.swift`, test `Tests/AINotebookCoreTests/NotebookStoreTransformationsTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/NotebookStoreTransformationsTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreTransformationsTests: XCTestCase {

    func testCreateAndListTransformations() throws {
        let store = try NotebookStore(path: .inMemory)
        _ = try store.createTransformation(
            name: "Summary", promptTemplate: "Summarize:\n{{source_text}}", scope: .source, isBuiltin: true
        )
        _ = try store.createTransformation(
            name: "Custom",  promptTemplate: "Do X", scope: .source, isBuiltin: false
        )
        let all = try store.transformations()
        XCTAssertEqual(all.count, 2)
    }

    func testUpdateAndDeleteCustomTransformation() throws {
        let store = try NotebookStore(path: .inMemory)
        let t = try store.createTransformation(
            name: "C", promptTemplate: "old", scope: .source, isBuiltin: false
        )
        try store.updateTransformation(id: t.id!, name: "C2", promptTemplate: "new")
        let reloaded = try XCTUnwrap(store.transformations().first { $0.id == t.id })
        XCTAssertEqual(reloaded.name, "C2")
        XCTAssertEqual(reloaded.promptTemplate, "new")
        try store.deleteTransformation(id: t.id!)
        XCTAssertEqual(try store.transformations().count, 0)
    }

    func testRecordRunCreatesRow() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s  = try store.createSource(notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil)
        let t  = try store.createTransformation(name: "T", promptTemplate: "p", scope: .source, isBuiltin: false)
        let n  = try store.createNote(notebookId: nb.id!, title: "T result", bodyMd: "x")
        let run = try store.recordTransformationRun(
            transformationId: t.id!, sourceId: s.id!, resultNoteId: n.id!
        )
        XCTAssertNotNil(run.id)
        let runs = try store.transformationRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].resultNoteId, n.id)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter NotebookStoreTransformationsTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/NotebookStore+Transformations.swift
import Foundation
import GRDB

extension NotebookStore {

    @discardableResult
    public func createTransformation(
        name: String,
        promptTemplate: String,
        scope: TransformationScope,
        isBuiltin: Bool = false
    ) throws -> Transformation {
        var t = Transformation(
            name: name,
            promptTemplate: promptTemplate,
            scope: scope,
            isBuiltin: isBuiltin
        )
        try runOnDatabase { db in
            try t.insert(db)
        }
        return t
    }

    public func transformations() throws -> [Transformation] {
        try runOnDatabase { db in
            try Transformation
                .order(
                    Transformation.Columns.isBuiltin.column.desc,
                    Transformation.Columns.name.column.asc
                )
                .fetchAll(db)
        }
    }

    public func updateTransformation(
        id: Int64,
        name: String,
        promptTemplate: String
    ) throws {
        try runOnDatabase { db in
            guard var t = try Transformation.fetchOne(db, key: id) else { return }
            t.name = name
            t.promptTemplate = promptTemplate
            try t.update(db)
        }
    }

    public func deleteTransformation(id: Int64) throws {
        try runOnDatabase { db in
            _ = try Transformation.deleteOne(db, key: id)
        }
    }

    @discardableResult
    public func recordTransformationRun(
        transformationId: Int64,
        sourceId: Int64?,
        resultNoteId: Int64?
    ) throws -> TransformationRun {
        var run = TransformationRun(
            transformationId: transformationId,
            sourceId: sourceId,
            resultNoteId: resultNoteId
        )
        try runOnDatabase { db in
            try run.insert(db)
        }
        return run
    }

    public func transformationRuns() throws -> [TransformationRun] {
        try runOnDatabase { db in
            try TransformationRun
                .order(TransformationRun.Columns.ranAt.column.desc)
                .fetchAll(db)
        }
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter NotebookStoreTransformationsTests 2>&1 | tail -10
git add Sources/AINotebookCore/NotebookStore+Transformations.swift Tests/AINotebookCoreTests/NotebookStoreTransformationsTests.swift
git commit -m "feat(core): transformations CRUD + runs"
```

Expected: 3/3 pass.

---

## Task 7: `BuiltinTransformations` — seed on first launch

**Files:** Create `Sources/AINotebookCore/BuiltinTransformations.swift`, modify `Sources/AINotebookCore/NotebookStore.swift` (call after migrations), test `Tests/AINotebookCoreTests/BuiltinTransformationsTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/BuiltinTransformationsTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class BuiltinTransformationsTests: XCTestCase {

    func testFreshDatabaseGetsBuiltinsSeeded() throws {
        let store = try NotebookStore(path: .inMemory)
        let all = try store.transformations()
        let builtinNames = Set(all.filter(\.isBuiltin).map(\.name))
        XCTAssertEqual(builtinNames, ["Summary", "Key points", "Entities"])
    }

    func testReopeningDatabaseDoesNotDuplicateBuiltins() throws {
        // Use a file-based DB to simulate reopen.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try NotebookStore(path: .file(url))
        }
        do {
            let store2 = try NotebookStore(path: .file(url))
            let builtins = try store2.transformations().filter(\.isBuiltin)
            XCTAssertEqual(builtins.count, 3, "should not re-seed on second open")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter BuiltinTransformationsTests 2>&1 | tail -10
```

If `StorePath.file(url)` doesn't exist as a constructor — `StorePath` likely has `case inMemory / case production(URL)` or similar. Use whatever the existing API supports to point at a temp file. If you must, write a one-line internal helper:
```swift
// Inside the test:
let path = try StorePath.production() // returns production URL
// Or fall back to: skip the reopen test if API doesn't support custom path,
// noting the limitation in the report.
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/BuiltinTransformations.swift
import Foundation
import GRDB

enum BuiltinTransformations {

    static let summary = Transformation(
        name: "Summary",
        promptTemplate: """
        Summarize the following source text in 3-5 short bullet points. Keep
        names, numbers, and dates exact. Output Markdown bullets only — no
        preamble.

        SOURCE TEXT:
        {{source_text}}
        """,
        scope: .source,
        isBuiltin: true
    )

    static let keyPoints = Transformation(
        name: "Key points",
        promptTemplate: """
        Extract the 5-10 most important key points from the following source
        text. Output as a Markdown numbered list. Each item should be one
        sentence, concrete, and self-contained.

        SOURCE TEXT:
        {{source_text}}
        """,
        scope: .source,
        isBuiltin: true
    )

    static let entities = Transformation(
        name: "Entities",
        promptTemplate: """
        Extract people, organizations, places, and dates from the following
        source text. Output as Markdown sections (## People, ## Organizations,
        ## Places, ## Dates) with bullet points under each. Include only
        entities literally present in the text.

        SOURCE TEXT:
        {{source_text}}
        """,
        scope: .source,
        isBuiltin: true
    )

    static let all: [Transformation] = [summary, keyPoints, entities]

    /// Idempotent: only inserts each builtin if a row with that name +
    /// `is_builtin = 1` doesn't already exist.
    static func seedIfNeeded(_ db: Database) throws {
        for t in all {
            let exists: Bool = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM transformations WHERE name = ? AND is_builtin = 1",
                arguments: [t.name]
            ) ?? false
            if !exists {
                var copy = t
                try copy.insert(db)
            }
        }
    }
}
```

- [ ] **Step 4: Call from `NotebookStore.init` after migrations succeed**

In `Sources/AINotebookCore/NotebookStore.swift`, after `try migrator.migrate(dbQueue)` and BEFORE `try refresh()`:

```swift
        try dbQueue.write { db in
            try BuiltinTransformations.seedIfNeeded(db)
        }
```

- [ ] **Step 5: Verify pass + commit**

```bash
swift test --filter BuiltinTransformationsTests 2>&1 | tail -10
git add Sources/AINotebookCore/BuiltinTransformations.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/BuiltinTransformationsTests.swift
git commit -m "feat(core): seed built-in transformations (Summary/Key points/Entities)"
```

If the reopen test is skipped due to `StorePath` limits, note that in the commit body and mention it as DONE_WITH_CONCERNS.

---

## Task 8: `TransformationEngine` — run template + persist note

The engine reuses the existing `ChatStreaming` protocol (already conformed to by `OllamaClient` in M5). It sends a single user message containing the rendered prompt and collects all tokens into a single string (no streaming UI for v1; user sees a spinner then the result).

**Files:** Create `Sources/AINotebookCore/TransformationEngine.swift`, test `Tests/AINotebookCoreTests/TransformationEngineTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/TransformationEngineTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationEngineTests: XCTestCase {

    final class MockChatClient: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            let toks = tokens
            return AsyncThrowingStream { c in
                Task {
                    for t in toks { c.yield(t) }
                    c.finish()
                }
            }
        }
    }

    func testRunsTemplateOverSourceAndSavesAsNote() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "Doc", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "Alpha facts.", tokenCount: 2),
                ChunkDraft(text: "Beta facts.",  tokenCount: 2)
            ]
        )
        let template = try store.createTransformation(
            name: "Sum", promptTemplate: "TEMPLATE:\n{{source_text}}",
            scope: .source, isBuiltin: false
        )

        let chat = MockChatClient(tokens: ["- Alpha\n", "- Beta\n"])
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")

        let note = try await engine.run(transformationId: template.id!, sourceId: s.id!)

        XCTAssertEqual(note.origin, .transformation)
        XCTAssertEqual(note.bodyMd, "- Alpha\n- Beta\n")
        XCTAssertTrue(note.title.contains("Sum"))
        XCTAssertEqual(note.notebookId, nb.id!)

        let runs = try store.transformationRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].sourceId, s.id!)
        XCTAssertEqual(runs[0].resultNoteId, note.id)

        // Template was rendered with both chunks joined.
        XCTAssertEqual(chat.captured.count, 1)
        let userTurn = chat.captured[0].last!
        XCTAssertEqual(userTurn.role, .user)
        XCTAssertTrue(userTurn.content.contains("Alpha facts"))
        XCTAssertTrue(userTurn.content.contains("Beta facts"))
        XCTAssertTrue(userTurn.content.contains("TEMPLATE:"))
    }

    func testRejectsMissingSource() async throws {
        let store = try NotebookStore(path: .inMemory)
        let _ = try store.createNotebook(name: "NB")
        let template = try store.createTransformation(
            name: "T", promptTemplate: "{{source_text}}", scope: .source, isBuiltin: false
        )
        let chat = MockChatClient(tokens: [])
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")
        do {
            _ = try await engine.run(transformationId: template.id!, sourceId: 999)
            XCTFail("expected throw")
        } catch TransformationEngine.RunError.sourceNotFound {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter TransformationEngineTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/TransformationEngine.swift
import Foundation

public actor TransformationEngine {
    public enum RunError: Error, Equatable {
        case sourceNotFound(Int64)
        case transformationNotFound(Int64)
        case noChunks(Int64)
    }

    private let store: NotebookStore
    private let chat: ChatStreaming
    public let chatModel: String

    public init(store: NotebookStore, chat: ChatStreaming, chatModel: String) {
        self.store = store
        self.chat = chat
        self.chatModel = chatModel
    }

    /// Run a transformation over a single source, persist the result as a
    /// note, record the run, and return the note.
    @discardableResult
    public func run(transformationId: Int64, sourceId: Int64) async throws -> Note {
        let storeRef = store

        // 1) Fetch transformation, source, chunks on the main actor.
        let prep: (Transformation, Source, [SourceChunk]) =
            try await MainActor.run {
                guard let t = try storeRef.transformations().first(where: { $0.id == transformationId }) else {
                    throw RunError.transformationNotFound(transformationId)
                }
                guard let s = try storeRef.source(id: sourceId) else {
                    throw RunError.sourceNotFound(sourceId)
                }
                let cs = try storeRef.chunks(sourceId: sourceId)
                return (t, s, cs)
            }
        let (transformation, source, chunks) = prep
        guard !chunks.isEmpty else { throw RunError.noChunks(sourceId) }

        // 2) Render template.
        let sourceText = chunks.map(\.text).joined(separator: "\n\n")
        let rendered = transformation.promptTemplate
            .replacingOccurrences(of: "{{source_text}}", with: sourceText)

        // 3) Call the model and collect all tokens.
        let turns: [ChatTurn] = [
            ChatTurn(role: .user, content: rendered)
        ]
        var assembled = ""
        for try await token in chat.stream(model: chatModel, messages: turns) {
            assembled += token
        }

        // 4) Persist as a note + record the run.
        let noteTitle = "\(transformation.name) — \(source.title)"
        let note = try await MainActor.run {
            let created = try storeRef.createNote(
                notebookId: source.notebookId,
                title: noteTitle,
                bodyMd: assembled,
                origin: .transformation,
                originRef: transformation.id
            )
            _ = try storeRef.recordTransformationRun(
                transformationId: transformation.id!,
                sourceId: source.id!,
                resultNoteId: created.id
            )
            return created
        }
        return note
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter TransformationEngineTests 2>&1 | tail -10
git add Sources/AINotebookCore/TransformationEngine.swift Tests/AINotebookCoreTests/TransformationEngineTests.swift
git commit -m "feat(core): TransformationEngine — run template, save as note"
```

Expected: 2/2 pass.

---

## Task 9: 15 EN/CS localization keys for notes + transformations UI

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, append test in `Tests/AINotebookCoreTests/LocalizationTests.swift`

- [ ] **Step 1: Add keys**

| key | EN | CS |
|---|---|---|
| `notesSectionTitle` | "Notes" | "Poznámky" |
| `notesEmptyState` | "No notes yet. Create one or save from chat." | "Zatím žádné poznámky. Vytvořte ji nebo uložte z chatu." |
| `notesNewButton` | "New note" | "Nová poznámka" |
| `noteUntitled` | "Untitled" | "Bez názvu" |
| `noteTitlePlaceholder` | "Title" | "Název" |
| `noteBodyPlaceholder` | "Write Markdown here…" | "Zde pište Markdown…" |
| `noteOriginManual` | "Manual" | "Ruční" |
| `noteOriginChat` | "From chat" | "Z chatu" |
| `noteOriginTransformation` | "From transformation" | "Z transformace" |
| `transformationsSectionTitle` | "Transformations" | "Transformace" |
| `transformationPickerLabel` | "Transformation" | "Transformace" |
| `transformationSourcePickerLabel` | "Source" | "Zdroj" |
| `transformationRunButton` | "Run" | "Spustit" |
| `transformationResultTitle` | "Result" | "Výsledek" |
| `transformationRunningStatus` | "Running…" | "Probíhá…" |

- [ ] **Step 2: Add smoke test**

```swift
    func testNotesNewButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.notesNewButton), "New note")
        XCTAssertEqual(AppText(language: .czech)  .string(.notesNewButton), "Nová poznámka")
    }

    func testTransformationRunButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.transformationRunButton), "Run")
        XCTAssertEqual(AppText(language: .czech)  .string(.transformationRunButton), "Spustit")
    }
```

- [ ] **Step 3: Build + test + commit**

```bash
swift test --filter LocalizationTests 2>&1 | tail -10
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): 15 EN/CS notes + transformations localization keys"
```

---

## Task 10: `TransformationEngineHolder` + wire into app

**Files:** Create `Sources/AINotebookApp/TransformationEngineHolder.swift`, modify `Sources/AINotebookApp/AINotebookApp.swift`

- [ ] **Step 1: Implement holder**

```swift
// Sources/AINotebookApp/TransformationEngineHolder.swift
import SwiftUI
import AINotebookCore

@MainActor
final class TransformationEngineHolder: ObservableObject {
    let engine: TransformationEngine
    init(engine: TransformationEngine) { self.engine = engine }
}
```

- [ ] **Step 2: Construct + inject in `AINotebookAppEntry`**

1. Add field next to other holders:
   ```swift
   @StateObject private var transformationHolder: TransformationEngineHolder
   ```
2. In `init()`, after `engine` (the chat engine) is built and `client` exists:
   ```swift
   let txEngine = TransformationEngine(
       store: store, chat: client, chatModel: settings.selectedChatModel
   )
   _transformationHolder = StateObject(wrappedValue: TransformationEngineHolder(engine: txEngine))
   ```
3. Inject `.environmentObject(transformationHolder)`.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/TransformationEngineHolder.swift Sources/AINotebookApp/AINotebookApp.swift
git commit -m "feat(app): wire TransformationEngine into app entry"
```

---

## Task 11: `NoteEditor` view

**File:** Create `Sources/AINotebookApp/NoteEditor.swift`

```swift
// Sources/AINotebookApp/NoteEditor.swift
import SwiftUI
import AINotebookCore

struct NoteEditor: View {
    @Binding var title: String
    @Binding var bodyMd: String
    let language: AppLanguage
    let onSave: () -> Void

    private var t: AppText { AppText(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(t.string(.noteTitlePlaceholder), text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            TextEditor(text: $bodyMd)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if bodyMd.isEmpty {
                        Text(t.string(.noteBodyPlaceholder))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button("Save") { onSave() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }
}
```

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NoteEditor.swift
git commit -m "feat(app): NoteEditor (title + Markdown body)"
```

---

## Task 12: `NotesView`

**Files:** Create `Sources/AINotebookApp/NotesView.swift`, modify `Sources/AINotebookApp/NotebookDetailView.swift`

- [ ] **Step 1: Implement `NotesView.swift`**

```swift
// Sources/AINotebookApp/NotesView.swift
import SwiftUI
import AINotebookCore

struct NotesView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @State private var notes: [Note] = []
    @State private var selection: Int64?
    @State private var draftTitle: String = ""
    @State private var draftBody:  String = ""
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: notebook.id) { await reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.string(.notesSectionTitle))
                    .font(.title3).bold()
                Spacer()
                Button(t.string(.notesNewButton)) {
                    Task { await createBlank() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            if notes.isEmpty {
                Text(t.string(.notesEmptyState))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 24)
            } else {
                List(selection: $selection) {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title.isEmpty ? t.string(.noteUntitled) : note.title)
                                .font(.headline)
                            Text(originLabel(note.origin))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(note.id ?? -1)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, newId in
                    if let id = newId, let n = notes.first(where: { $0.id == id }) {
                        draftTitle = n.title
                        draftBody  = n.bodyMd
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, notes.contains(where: { $0.id == id }) {
            NoteEditor(
                title: $draftTitle,
                bodyMd: $draftBody,
                language: settings.language,
                onSave: { Task { await save(id: id) } }
            )
            .padding(16)
        } else {
            VStack {
                Spacer()
                Text(t.string(.notesEmptyState))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func originLabel(_ o: NoteOrigin) -> String {
        switch o {
        case .manual:         return t.string(.noteOriginManual)
        case .chat:           return t.string(.noteOriginChat)
        case .transformation: return t.string(.noteOriginTransformation)
        }
    }

    @MainActor
    private func reload() async {
        do {
            notes = try store.notes(notebookId: notebook.id!)
            if selection == nil { selection = notes.first?.id }
            if let id = selection, let n = notes.first(where: { $0.id == id }) {
                draftTitle = n.title
                draftBody  = n.bodyMd
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func createBlank() async {
        do {
            let n = try store.createNote(
                notebookId: notebook.id!,
                title: t.string(.noteUntitled),
                bodyMd: ""
            )
            await reload()
            selection = n.id
            draftTitle = n.title
            draftBody = ""
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func save(id: Int64) async {
        do {
            try store.updateNote(id: id, title: draftTitle, bodyMd: draftBody)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Swap `.notes` in `NotebookDetailView`**

In the `Group { switch selectedTab }`, add a `.notes` case before the `.transformations` placeholder:

```swift
case .sources:
    SourceListView(notebook: notebook)
case .chat:
    ChatView(notebook: notebook)
case .notes:
    NotesView(notebook: notebook)
case .transformations:
    placeholder
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NotesView.swift Sources/AINotebookApp/NotebookDetailView.swift
git commit -m "feat(app): NotesView with sidebar + editor"
```

---

## Task 13: `TransformationsView`

**Files:** Create `Sources/AINotebookApp/TransformationsView.swift`, modify `Sources/AINotebookApp/NotebookDetailView.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/TransformationsView.swift
import SwiftUI
import AINotebookCore

struct TransformationsView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var transformationHolder: TransformationEngineHolder

    @State private var transformations: [Transformation] = []
    @State private var sources: [Source] = []
    @State private var selectedTransformationId: Int64?
    @State private var selectedSourceId: Int64?
    @State private var resultBody: String = ""
    @State private var resultNoteId: Int64?
    @State private var running = false
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t.string(.transformationsSectionTitle))
                .font(.title2).bold()

            HStack {
                pickerColumn(title: t.string(.transformationPickerLabel)) {
                    Picker("", selection: $selectedTransformationId) {
                        ForEach(transformations) { tx in
                            Text(tx.name).tag(tx.id as Int64?)
                        }
                    }
                    .labelsHidden()
                }
                pickerColumn(title: t.string(.transformationSourcePickerLabel)) {
                    Picker("", selection: $selectedSourceId) {
                        ForEach(sources) { s in
                            Text(s.title).tag(s.id as Int64?)
                        }
                    }
                    .labelsHidden()
                }
                Spacer()
                Button(t.string(.transformationRunButton)) {
                    Task { await run() }
                }
                .disabled(running
                          || selectedTransformationId == nil
                          || selectedSourceId == nil)
            }

            if running {
                ProgressView(t.string(.transformationRunningStatus))
            }

            if !resultBody.isEmpty {
                Text(t.string(.transformationResultTitle)).font(.headline)
                ScrollView {
                    Text(resultBody)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .task(id: notebook.id) { await reload() }
    }

    @ViewBuilder
    private func pickerColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    @MainActor
    private func reload() async {
        do {
            transformations = try store.transformations()
            sources = try store.sources(notebookId: notebook.id!)
            if selectedTransformationId == nil { selectedTransformationId = transformations.first?.id }
            if selectedSourceId == nil          { selectedSourceId         = sources.first?.id }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func run() async {
        guard let tid = selectedTransformationId, let sid = selectedSourceId else { return }
        running = true
        errorMessage = nil
        resultBody = ""
        resultNoteId = nil
        defer { running = false }
        do {
            let note = try await transformationHolder.engine.run(
                transformationId: tid, sourceId: sid
            )
            resultBody = note.bodyMd
            resultNoteId = note.id
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Swap `.transformations` in `NotebookDetailView`**

```swift
case .transformations:
    TransformationsView(notebook: notebook)
```

`placeholder` is no longer reachable — keep the closure for compile, or remove the `comingSoonMessage` switch arms that are now dead. Apply the smallest change that compiles.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/TransformationsView.swift Sources/AINotebookApp/NotebookDetailView.swift
git commit -m "feat(app): TransformationsView wired into transformations tab"
```

---

## Task 14: Final verification + tag + merge

- [ ] **Step 1: Clean build + parallel tests**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: build ok; **~146 tests** pass (131 M5 baseline + MigrationV5(3) + Notes(4) + Transformations(3) + Builtins(2) + TransformationEngine(2) + Localization(2) ≈ 147).

- [ ] **Step 2: Smoke test**

```bash
swift run AINotebookApp
```

Requires Ollama running. Manual checks:
- Open a notebook with a few ingested sources.
- Notes tab: click "New note", type Markdown, ⌘S → reappears in list.
- Transformations tab: pick "Summary" + a source → "Run" → result appears + a new note exists in Notes tab.
- Quit/relaunch → notes persist, builtin transformations still present (not duplicated).

- [ ] **Step 3: Tag + merge**

```bash
git tag -a m6-notes-tx-tag -m "M6 notes + transformations complete"
git checkout main
git merge --ff-only m6-notes-transformations
git log --oneline | head -18
```

---

## Acceptance criteria (M6 done when ALL true)

- `swift build` succeeds; `swift test --parallel` ~147 tests, 0 failures.
- `MigrationV5` adds `notes`, `transformations`, `transformation_runs` with correct cascade/setNull behaviour.
- Built-in transformations seed on first launch and do not duplicate on reopen.
- `TransformationEngine.run` renders `{{source_text}}`, calls the chat client, persists a note + a run row.
- Notes tab: create/edit/save manual notes; AI-generated notes appear automatically.
- Transformations tab: select template + source, run, see result; result is also a note in Notes tab.
- 15 new EN/CS strings render in both languages.
- Local git tag `m6-notes-tx-tag` exists; `main` is fast-forwarded.

---

## Notes for the implementer

- **Builtin re-seed safety:** `seedIfNeeded` checks by `name + is_builtin = 1` so a user-created transformation named "Summary" is NOT treated as the builtin.
- **`{{source_text}}` only:** v1 supports a single placeholder. M7 may add `{{source_title}}`, `{{notebook_name}}`, etc.
- **No streaming UI for transformations:** v1 collects all tokens, then renders. Adds latency on long sources but keeps the implementation small.
- **Save-as-note from chat (deferred):** the design spec includes "Save as note" from a chat message. Implement in M7 polish; the schema is already in place (`origin: .chat`, `originRef: messageId`).
- **Notebook-scope transformations:** `scope: .notebook` is in the model but `TransformationEngine.run` only handles single-source. Notebook scope can land in M7 if user-tested demand exists.
