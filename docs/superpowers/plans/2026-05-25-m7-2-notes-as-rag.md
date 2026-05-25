# M7.2: Notes as RAG + 3-Column + Chat Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote Notes into the RAG index (via a hidden "shadow Source" row per Note), refactor the Notes tab into a 3-column layout (list / editor / chat sidebar), and let the chat engine inject the currently-open Note as bonus context.

**Architecture:** Add `SourceType.note` so the existing Embedder / Retriever pipeline picks Notes up for free. Each Note gets a 1:1 shadow Source row (`auto_source_id` FK on `notes`). A new `NoteIndexer` actor handles the save → upsert → re-chunk → kick-embedder pipeline. `ChatEngine.send` takes an optional `currentNoteContent` parameter and weaves it into the system prompt. UI moves Notes to a 3-pane SwiftUI layout and reuses the existing chat surface in the right pane.

**Tech Stack:** Swift 6, GRDB (existing), SwiftUI, Ollama (existing).

---

## File Structure

**Create:**
- `Sources/AINotebookCore/MigrationV6.swift` — adds `notes.auto_source_id`, `notes.note_uuid`, backfills uuids
- `Sources/AINotebookCore/NoteIndexer.swift` — actor; save → shadow Source upsert → re-chunk → kick worker
- `Sources/AINotebookApp/NoteJumpCoordinator.swift` — ObservableObject for citation "Open Note" jumps
- `Sources/AINotebookApp/NotesChatPanel.swift` — extracted chat surface usable inside the 3-col NotesView
- `Tests/AINotebookCoreTests/MigrationV6Tests.swift`
- `Tests/AINotebookCoreTests/NoteIndexerTests.swift`
- `Tests/AINotebookCoreTests/ChatEngineCurrentNoteContextTests.swift`

**Modify:**
- `Sources/AINotebookCore/SourceType.swift` — add `.note` case
- `Sources/AINotebookCore/Note.swift` — add `autoSourceId: Int64?` and `noteUuid: String` columns
- `Sources/AINotebookCore/NotebookStore.swift` — register `MigrationV6`
- `Sources/AINotebookCore/NotebookStore+Notes.swift` — `createNote` generates uuid; `updateNote`/`deleteNote` invoke indexer hook
- `Sources/AINotebookCore/NotebookStore+Sources.swift` — `sources(notebookId:)` excludes `.note` rows (UI-facing); new internal `sourcesIncludingShadow(...)` for full list
- `Sources/AINotebookCore/ChatEngine.swift` — `send(...currentNoteContent: String?)` overload
- `Sources/AINotebookCore/SystemPrompt.swift` — render an extra "CURRENTLY OPEN NOTE" block when supplied
- `Sources/AINotebookCore/Localization.swift` — 4 new EN/CS keys
- `Sources/AINotebookApp/AINotebookApp.swift` — inject `NoteIndexer` + `NoteJumpCoordinator`
- `Sources/AINotebookApp/NotesView.swift` — refactor to 3-column layout, observe coordinator
- `Sources/AINotebookApp/ChatView.swift` — split out `NotesChatPanel` view, keep ChatView as wrapper for the existing Chat tab
- `Sources/AINotebookApp/CitationPopover.swift` — "Open Note" button when source.type == .note
- `Tests/AINotebookCoreTests/LocalizationTests.swift` — bilingual smoke for one new key

---

## Task 1: Branch + baseline

**Files:** branch.

- [ ] **Step 1: Branch**

```bash
git checkout main
git checkout -b m7-2-notes-as-rag
swift test --parallel 2>&1 | tail -5
```

Expected: 159/159 pass.

---

## Task 2: `SourceType.note` enum case

**Files:** Modify `Sources/AINotebookCore/SourceType.swift`, modify `Tests/AINotebookCoreTests/SourceTypeTests.swift`

- [ ] **Step 1: Write failing test**

Append to `Tests/AINotebookCoreTests/SourceTypeTests.swift`:

```swift
    func testNoteRawValueIsStable() {
        XCTAssertEqual(SourceType.note.rawValue, "note")
    }

    func testDetectReturnsNilForNoteExtension() {
        // The .note type is never user-selected — it represents a shadow
        // row backing a Note. Filename detection should not pick it up.
        XCTAssertNil(SourceType.detect(filename: "scratch.note"))
    }

    func testAllCasesContainsNote() {
        XCTAssertTrue(SourceType.allCases.contains(.note))
    }
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter SourceTypeTests 2>&1 | tail -10
```

Expected: fail (`type 'SourceType' has no member 'note'`).

- [ ] **Step 3: Add the case**

In `Sources/AINotebookCore/SourceType.swift`, add `case note` at the end of the enum (so existing raw values stay stable):

```swift
public enum SourceType: String, Codable, CaseIterable, Sendable {
    case pdf
    case text
    case markdown
    case web
    case docx
    case pptx
    case xlsx
    case note   // shadow source backing a user Note for RAG indexing
    // ... existing `detect` method unchanged
}
```

Do not touch `detect(filename:)` — `.note` must NOT be reachable from filename detection.

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter SourceTypeTests 2>&1 | tail -10
git add Sources/AINotebookCore/SourceType.swift Tests/AINotebookCoreTests/SourceTypeTests.swift
git commit -m "feat(core): SourceType.note for Note shadow rows"
```

Expected: 6/6 pass.

---

## Task 3: `MigrationV6` — `notes.auto_source_id` + `notes.note_uuid`

**Files:** Create `Sources/AINotebookCore/MigrationV6.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV6Tests.swift`.

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV6Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV6Tests: XCTestCase {

    func testV6AddsColumnsToNotes() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let columns: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('notes')")
            let names = columns.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("auto_source_id"), "got: \(names)")
            XCTAssertTrue(names.contains("note_uuid"),      "got: \(names)")
        }
    }

    func testCreatedNoteGetsUuid() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        XCTAssertFalse(n.noteUuid.isEmpty)
        // Looks like a UUID — 8-4-4-4-12 hex
        XCTAssertTrue(n.noteUuid.contains("-"))
        XCTAssertEqual(n.noteUuid.count, 36)
    }

    func testAutoSourceIdStartsNil() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        XCTAssertNil(n.autoSourceId)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter MigrationV6Tests 2>&1 | tail -10
```

Expected: fail (`type 'Note' has no member 'noteUuid'`).

- [ ] **Step 3: Implement migration**

```swift
// Sources/AINotebookCore/MigrationV6.swift
import Foundation
import GRDB

public func registerMigrationV6(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v6_notes_auto_source_and_uuid") { db in
        try db.alter(table: "notes") { t in
            t.add(column: "auto_source_id", .integer)
                .references("sources", onDelete: .setNull)
            t.add(column: "note_uuid", .text)
        }
        try db.create(
            index: "idx_notes_auto_source",
            on: "notes",
            columns: ["auto_source_id"]
        )

        // Backfill UUIDs for any existing Notes (carried over from v0.2.0).
        let ids: [Int64] = try Int64.fetchAll(db, sql: "SELECT id FROM notes WHERE note_uuid IS NULL")
        for id in ids {
            try db.execute(
                sql: "UPDATE notes SET note_uuid = ? WHERE id = ?",
                arguments: [UUID().uuidString.lowercased(), id]
            )
        }
    }
}
```

- [ ] **Step 4: Register V6 in `NotebookStore.init`**

In `Sources/AINotebookCore/NotebookStore.swift`, append after `registerMigrationV5(on: &migrator)`:

```swift
        registerMigrationV6(on: &migrator)
```

- [ ] **Step 5: Extend `Note` model**

In `Sources/AINotebookCore/Note.swift`:

1. Add the two new stored properties:
```swift
public var autoSourceId: Int64?
public var noteUuid: String
```
2. Update `init` to take + default them:
```swift
public init(
    id: Int64? = nil,
    notebookId: Int64,
    title: String,
    bodyMd: String,
    origin: NoteOrigin = .manual,
    originRef: Int64? = nil,
    autoSourceId: Int64? = nil,
    noteUuid: String = UUID().uuidString.lowercased(),
    createdAt: Date = Date(),
    updatedAt: Date? = nil
) {
    self.id = id
    self.notebookId = notebookId
    self.title = title
    self.bodyMd = bodyMd
    self.origin = origin
    self.originRef = originRef
    self.autoSourceId = autoSourceId
    self.noteUuid = noteUuid
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
}
```
3. Add the two new cases to `Columns`:
```swift
case autoSourceId = "auto_source_id"
case noteUuid     = "note_uuid"
```

- [ ] **Step 6: Update `createNote` to write the uuid**

In `Sources/AINotebookCore/NotebookStore+Notes.swift`, ensure `createNote` writes the uuid (the GRDB `convertToSnakeCase` strategy will pick it up automatically from the model field; no change needed if the model defaults the uuid in `init`). Verify by running the test in Step 7.

- [ ] **Step 7: Verify pass + commit**

```bash
swift test --filter MigrationV6Tests 2>&1 | tail -10
swift test --parallel 2>&1 | tail -5
git add Sources/AINotebookCore/MigrationV6.swift Sources/AINotebookCore/Note.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV6Tests.swift
git commit -m "feat(core): MigrationV6 — notes.auto_source_id + note_uuid + backfill"
```

Expected: 3/3 new tests pass; existing 159 still pass.

---

## Task 4: `NotebookStore+Sources.sources(notebookId:)` excludes shadow rows

**Files:** Modify `Sources/AINotebookCore/NotebookStore+Sources.swift`, modify `Tests/AINotebookCoreTests/NotebookStoreSourcesTests.swift`.

- [ ] **Step 1: Add a test that proves a `.note` shadow row is filtered out of the user-facing list**

Append to `Tests/AINotebookCoreTests/NotebookStoreSourcesTests.swift`:

```swift
    func testSourcesExcludesNoteShadowRows() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        _ = try store.createSource(
            notebookId: nb.id!, type: .text, title: "Real",
            uri: nil, rawPath: nil
        )
        _ = try store.createSource(
            notebookId: nb.id!, type: .note, title: "Shadow",
            uri: nil, rawPath: nil
        )
        let visible = try store.sources(notebookId: nb.id!)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.title, "Real")

        let all = try store.sourcesIncludingShadow(notebookId: nb.id!)
        XCTAssertEqual(all.count, 2)
    }
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter NotebookStoreSourcesTests 2>&1 | tail -10
```

Expected: fail (missing `sourcesIncludingShadow`, or shadow row visible).

- [ ] **Step 3: Implement the filter + the internal alternative**

In `Sources/AINotebookCore/NotebookStore+Sources.swift`, replace `sources(notebookId:)` with:

```swift
    public func sources(notebookId: Int64) throws -> [Source] {
        try runOnDatabase { db in
            try Source
                .filter(Source.Columns.notebookId.column == notebookId)
                .filter(Source.Columns.type.column != SourceType.note.rawValue)
                .order(Source.Columns.ingestedAt.column.desc)
                .fetchAll(db)
        }
    }

    /// Includes shadow Note rows. Used by Retriever / Embedder paths that
    /// must see Notes for RAG.
    public func sourcesIncludingShadow(notebookId: Int64) throws -> [Source] {
        try runOnDatabase { db in
            try Source
                .filter(Source.Columns.notebookId.column == notebookId)
                .order(Source.Columns.ingestedAt.column.desc)
                .fetchAll(db)
        }
    }
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter NotebookStoreSourcesTests 2>&1 | tail -10
git add Sources/AINotebookCore/NotebookStore+Sources.swift Tests/AINotebookCoreTests/NotebookStoreSourcesTests.swift
git commit -m "feat(core): exclude .note shadow rows from sources(notebookId:)"
```

Expected: all NotebookStoreSourcesTests pass.

---

## Task 5: `NoteIndexer` actor

**Files:** Create `Sources/AINotebookCore/NoteIndexer.swift`, test `Tests/AINotebookCoreTests/NoteIndexerTests.swift`.

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/NoteIndexerTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NoteIndexerTests: XCTestCase {

    func testIndexCreatesShadowSourceAndChunks() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "Recipe", bodyMd: "Mix flour and water."
        )

        let indexer = NoteIndexer(store: store)
        try await indexer.index(noteId: n.id!)

        // Reload note to get auto_source_id
        let reloaded = try XCTUnwrap(try store.note(id: n.id!))
        let sourceId = try XCTUnwrap(reloaded.autoSourceId)

        // Shadow source exists and is type .note
        let shadow = try XCTUnwrap(try store.source(id: sourceId))
        XCTAssertEqual(shadow.type, .note)
        XCTAssertEqual(shadow.notebookId, nb.id!)
        XCTAssertEqual(shadow.title, "Recipe")
        XCTAssertEqual(shadow.status, .ready)

        // Chunks were written
        let chunks = try store.chunks(sourceId: sourceId)
        XCTAssertGreaterThan(chunks.count, 0)
        XCTAssertTrue(chunks.first?.text.contains("flour") == true)
    }

    func testReindexReplacesChunks() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "T", bodyMd: "original"
        )
        let indexer = NoteIndexer(store: store)
        try await indexer.index(noteId: n.id!)

        try store.updateNote(id: n.id!, title: "T", bodyMd: "rewritten body completely")
        try await indexer.index(noteId: n.id!)

        let sourceId = try XCTUnwrap(try store.note(id: n.id!)?.autoSourceId)
        let chunks = try store.chunks(sourceId: sourceId)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("rewritten"))
        XCTAssertFalse(chunks[0].text.contains("original"))
    }

    func testEmptyBodyClearsChunksButKeepsShadow() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "T", bodyMd: "first content"
        )
        let indexer = NoteIndexer(store: store)
        try await indexer.index(noteId: n.id!)

        try store.updateNote(id: n.id!, title: "T", bodyMd: "")
        try await indexer.index(noteId: n.id!)

        let sourceId = try XCTUnwrap(try store.note(id: n.id!)?.autoSourceId)
        XCTAssertNotNil(try store.source(id: sourceId)) // shadow remains
        XCTAssertEqual(try store.chunks(sourceId: sourceId).count, 0)
    }

    func testKickHookFiresAfterIndex() async throws {
        final class CapturingKick: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func bump() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "T", bodyMd: "x"
        )
        let kick = CapturingKick()
        let indexer = NoteIndexer(store: store, onChunksWritten: { kick.bump() })
        try await indexer.index(noteId: n.id!)
        XCTAssertEqual(kick.value, 1)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter NoteIndexerTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/NoteIndexer.swift
import Foundation

/// Bridges a saved Note into the RAG index by maintaining a 1:1 shadow
/// Source row. Idempotent: re-indexing the same Note replaces its chunks.
public actor NoteIndexer {

    public enum IndexError: Error, Equatable {
        case noteNotFound(Int64)
    }

    private let store: NotebookStore
    private let onChunksWritten: (@Sendable () async -> Void)?

    public init(
        store: NotebookStore,
        onChunksWritten: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.onChunksWritten = onChunksWritten
    }

    public func index(noteId: Int64) async throws {
        let storeRef = store

        // 1) Load the Note + ensure a shadow Source exists.
        let prep: (Note, Int64) = try await MainActor.run {
            guard let note = try storeRef.note(id: noteId) else {
                throw IndexError.noteNotFound(noteId)
            }
            let sourceId: Int64
            if let existing = note.autoSourceId,
               try storeRef.source(id: existing) != nil {
                // keep existing shadow, but sync title
                var s = try storeRef.source(id: existing)!
                if s.title != note.title {
                    s.title = note.title
                    try storeRef.runOnDatabase { db in try s.update(db) }
                }
                sourceId = existing
            } else {
                let created = try storeRef.createSource(
                    notebookId: note.notebookId,
                    type: .note,
                    title: note.title,
                    uri: nil,
                    rawPath: nil
                )
                sourceId = created.id!
                try storeRef.linkNoteToShadowSource(noteId: noteId, sourceId: sourceId)
            }
            return (note, sourceId)
        }
        let (note, sourceId) = prep

        // 2) Chunk + replace, even if body is empty (writes 0 chunks).
        let drafts: [ChunkDraft] = note.bodyMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : Chunker.chunk(note.bodyMd)

        try await MainActor.run {
            try storeRef.replaceChunks(sourceId: sourceId, chunks: drafts)
            try storeRef.updateSourceStatus(id: sourceId, status: .ready, error: nil)
        }

        await onChunksWritten?()
    }
}
```

- [ ] **Step 4: Add `linkNoteToShadowSource` to the store**

In `Sources/AINotebookCore/NotebookStore+Notes.swift`, append:

```swift
    /// Internal: store the FK from Note → shadow Source after the indexer
    /// creates the row. Idempotent.
    public func linkNoteToShadowSource(noteId: Int64, sourceId: Int64) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE notes SET auto_source_id = ? WHERE id = ?",
                arguments: [sourceId, noteId]
            )
        }
    }
```

- [ ] **Step 5: Verify pass + commit**

```bash
swift test --filter NoteIndexerTests 2>&1 | tail -10
git add Sources/AINotebookCore/NoteIndexer.swift Sources/AINotebookCore/NotebookStore+Notes.swift Tests/AINotebookCoreTests/NoteIndexerTests.swift
git commit -m "feat(core): NoteIndexer actor + shadow Source link"
```

Expected: 4/4 pass.

---

## Task 6: Wire `NoteIndexer` into `NotebookStore` mutations

The store doesn't own the indexer (avoiding a circular dep). The
**app layer** wires the kick. To make the contract explicit, expose a
hook on the store similar to `IngestionService.onChunksWritten`.

**Files:** Modify `Sources/AINotebookCore/NotebookStore.swift`, `Sources/AINotebookCore/NotebookStore+Notes.swift`, test `Tests/AINotebookCoreTests/NoteIndexerHookTests.swift`.

- [ ] **Step 1: Add a `onNoteSaved` hook to `NotebookStore`**

In `Sources/AINotebookCore/NotebookStore.swift`, inside the class:

```swift
    /// Set by the app layer (typically after `NoteIndexer` is wired). Fires
    /// on every `createNote` / `updateNote` with the affected note id.
    public var onNoteSaved: (@Sendable (Int64) async -> Void)?
```

Mark `NotebookStore` `@unchecked Sendable` if it isn't already — the
class is `@MainActor` already (M1), so the hook just needs to be
called from main-actor contexts.

- [ ] **Step 2: Fire the hook from `createNote` + `updateNote`**

In `Sources/AINotebookCore/NotebookStore+Notes.swift`:

After the existing `createNote(...)` body builds `note` and inserts it:

```swift
        if let id = note.id, let hook = onNoteSaved {
            Task { await hook(id) }
        }
```

After `updateNote(...)` runs the update:

```swift
        if let hook = onNoteSaved {
            Task { await hook(id) }
        }
```

(Cannot use `await` directly because callers are non-async — `Task {}` is fine; the indexer is idempotent.)

- [ ] **Step 3: Write the hook test**

```swift
// Tests/AINotebookCoreTests/NoteIndexerHookTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NoteIndexerHookTests: XCTestCase {

    func testHookFiresOnCreateAndUpdate() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var ids: [Int64] = []
            func record(_ id: Int64) {
                lock.lock(); defer { lock.unlock() }
                ids.append(id)
            }
            var snapshot: [Int64] {
                lock.lock(); defer { lock.unlock() }
                return ids
            }
        }
        let counter = Counter()
        store.onNoteSaved = { id in counter.record(id) }

        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.updateNote(id: n.id!, title: "T2", bodyMd: "y")

        // Give the Task { ... } detached calls time to fire.
        try await Task.sleep(nanoseconds: 50_000_000)

        let recorded = counter.snapshot
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.first, n.id)
        XCTAssertEqual(recorded.last,  n.id)
    }
}
```

- [ ] **Step 4: Verify + commit**

```bash
swift test --filter NoteIndexerHookTests 2>&1 | tail -10
git add Sources/AINotebookCore/NotebookStore.swift Sources/AINotebookCore/NotebookStore+Notes.swift Tests/AINotebookCoreTests/NoteIndexerHookTests.swift
git commit -m "feat(core): NotebookStore.onNoteSaved hook for indexer wiring"
```

---

## Task 7: `ChatEngine.send(...currentNoteContent:)` + `SystemPrompt` injection

**Files:** Modify `Sources/AINotebookCore/SystemPrompt.swift`, modify `Sources/AINotebookCore/ChatEngine.swift`, test `Tests/AINotebookCoreTests/ChatEngineCurrentNoteContextTests.swift`.

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/ChatEngineCurrentNoteContextTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineCurrentNoteContextTests: XCTestCase {

    final class CapturingChat: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            return AsyncThrowingStream { c in
                Task { c.yield("ok"); c.finish() }
            }
        }
    }
    final class StaticEmbedder: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in [1, 0] }
        }
    }

    func testCurrentNoteContextAppearsInSystemPrompt() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = CapturingChat()
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat, chatModel: "m")

        _ = try await engine.send(
            sessionId: session.id!,
            notebookId: nb.id!,
            userText: "what?",
            currentNoteContent: "Ingredient list: flour 500g, water 300g."
        ) { _ in }

        let systemTurn = try XCTUnwrap(chat.captured.first?.first)
        XCTAssertEqual(systemTurn.role, .system)
        XCTAssertTrue(systemTurn.content.contains("CURRENTLY OPEN NOTE"))
        XCTAssertTrue(systemTurn.content.contains("flour 500g"))
    }

    func testNilCurrentNoteContextLeavesPromptUnchanged() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = CapturingChat()
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat, chatModel: "m")

        _ = try await engine.send(
            sessionId: session.id!,
            notebookId: nb.id!,
            userText: "what?"
        ) { _ in }

        let systemTurn = try XCTUnwrap(chat.captured.first?.first)
        XCTAssertFalse(systemTurn.content.contains("CURRENTLY OPEN NOTE"))
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter ChatEngineCurrentNoteContextTests 2>&1 | tail -10
```

Expected: fail (unknown `currentNoteContent` param).

- [ ] **Step 3: Extend `SystemPrompt`**

In `Sources/AINotebookCore/SystemPrompt.swift`, change the signature + body:

```swift
public enum SystemPrompt {

    public static func compose(
        hits: [RetrievalHit],
        currentNoteContent: String? = nil
    ) -> String {
        let header = """
        You are a helpful assistant answering questions about the user's notebook.
        Use ONLY the provided CONTEXT to answer. If the answer isn't in the
        context, say so plainly. When you use a fact from a context block,
        cite it inline as [N] where N is the block number. Multiple citations
        may appear in a single sentence: [1][3].
        """

        var sections: [String] = [header]

        if hits.isEmpty {
            sections.append("CONTEXT:\n(none)")
        } else {
            let blocks = hits.enumerated().map { (i, hit) in
                "[\(i + 1)] \(hit.snippet)"
            }.joined(separator: "\n")
            sections.append("CONTEXT:\n" + blocks)
        }

        if let note = currentNoteContent,
           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(
                "CURRENTLY OPEN NOTE (additional context — user may be asking about this):\n"
                + note
            )
        }

        return sections.joined(separator: "\n\n")
    }
}
```

- [ ] **Step 4: Extend `ChatEngine.send`**

In `Sources/AINotebookCore/ChatEngine.swift`, change `send`'s signature:

```swift
@discardableResult
public func send(
    sessionId: Int64,
    notebookId: Int64,
    userText: String,
    currentNoteContent: String? = nil,
    onToken: @escaping @Sendable (String) -> Void
) async throws -> ChatMessage {
    // ... existing body up to systemContent
    let systemContent = SystemPrompt.compose(hits: hits, currentNoteContent: currentNoteContent)
    // ... rest unchanged
}
```

(Default `nil` keeps the M5 / M7.1 callers source-compatible.)

- [ ] **Step 5: Verify pass + commit**

```bash
swift test --filter ChatEngineCurrentNoteContextTests 2>&1 | tail -10
swift test --filter SystemPromptTests 2>&1 | tail -10
git add Sources/AINotebookCore/SystemPrompt.swift Sources/AINotebookCore/ChatEngine.swift Tests/AINotebookCoreTests/ChatEngineCurrentNoteContextTests.swift
git commit -m "feat(core): ChatEngine + SystemPrompt accept currentNoteContent"
```

Existing `SystemPromptTests` should continue to pass — only a new arg was added with a default.

---

## Task 8: 4 EN/CS localization keys

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, modify `Tests/AINotebookCoreTests/LocalizationTests.swift`.

- [ ] **Step 1: Add keys**

| key | EN | CS |
|---|---|---|
| `openNoteFromCitation` | "Open note" | "Otevřít poznámku" |
| `notesChatPanelTitle` | "Chat" | "Chat" |
| `notesChatPanelEmpty` | "Start a question about this notebook…" | "Zeptej se na něco z tohoto notebooku…" |
| `notesChatCurrentNoteHint` | "Including the open note as bonus context" | "Aktuální poznámka přidána jako kontext" |

Wire each through `AppText.Key` enum + EN + CS dicts.

- [ ] **Step 2: Add bilingual smoke test**

Append to `Tests/AINotebookCoreTests/LocalizationTests.swift`:

```swift
    func testOpenNoteFromCitationBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.openNoteFromCitation), "Open note")
        XCTAssertEqual(AppText(language: .czech)  .string(.openNoteFromCitation), "Otevřít poznámku")
    }
```

- [ ] **Step 3: Build + test + commit**

```bash
swift test --filter LocalizationTests 2>&1 | tail -10
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): 4 EN/CS localization keys for notes RAG + chat panel"
```

---

## Task 9: `NoteJumpCoordinator` ObservableObject

**Files:** Create `Sources/AINotebookApp/NoteJumpCoordinator.swift`.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/NoteJumpCoordinator.swift
import SwiftUI
import Combine

/// App-layer event bus. Citation popovers publish a "jump to note" intent;
/// NotesView listens and updates its selection.
@MainActor
final class NoteJumpCoordinator: ObservableObject {
    @Published var target: Int64?

    func request(noteId: Int64) {
        target = noteId
    }

    func clear() {
        target = nil
    }
}
```

- [ ] **Step 2: Inject in `AINotebookAppEntry`**

In `Sources/AINotebookApp/AINotebookApp.swift`, add next to other `@StateObject`s:

```swift
@StateObject private var noteJump = NoteJumpCoordinator()
```

Inject via `.environmentObject(noteJump)` next to the other env objects in the scene body.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NoteJumpCoordinator.swift Sources/AINotebookApp/AINotebookApp.swift
git commit -m "feat(app): NoteJumpCoordinator for citation → note jumps"
```

---

## Task 10: Wire `NoteIndexer` into the running app

The store fires `onNoteSaved` (Task 6); the app constructs the `NoteIndexer` and attaches the hook.

**Files:** Modify `Sources/AINotebookApp/AINotebookApp.swift`.

- [ ] **Step 1: Construct + attach in `init()`**

After the existing `store` + `embedder` + `worker` construction in
`Sources/AINotebookApp/AINotebookApp.swift`, add:

```swift
let indexer = NoteIndexer(store: store, onChunksWritten: { [worker] in
    await worker.kick()
})
store.onNoteSaved = { [indexer] noteId in
    do { try await indexer.index(noteId: noteId) }
    catch { print("NoteIndexer error: \(error)") }
}
```

The indexer is a leaf actor — no holder needed; the closure keeps it
alive via `store.onNoteSaved`.

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/AINotebookApp.swift
git commit -m "feat(app): wire NoteIndexer to NotebookStore.onNoteSaved"
```

---

## Task 11: Extract `NotesChatPanel` from `ChatView`

The chat surface (sessions sidebar + messages + input) currently lives
inside `ChatView`. We need to reuse the **right two panes** (messages +
input) inside the new 3-column NotesView. Extract.

**Files:** Create `Sources/AINotebookApp/NotesChatPanel.swift`, modify `Sources/AINotebookApp/ChatView.swift`.

- [ ] **Step 1: Create `NotesChatPanel.swift`**

```swift
// Sources/AINotebookApp/NotesChatPanel.swift
import SwiftUI
import AINotebookCore

/// Chat surface tailored for the Notes 3-column layout. No sessions
/// sidebar — uses the most-recent session for the notebook (creates one
/// if none) and supplies the currently-open Note as bonus context.
struct NotesChatPanel: View {
    let notebook: Notebook
    let currentNote: Note?

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder

    @State private var sessionId: Int64?
    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streamingDraft: String = ""
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var popoverCitation: Citation?
    @State private var popoverSourceTitle: String = ""
    @State private var popoverPageHint: Int?
    @State private var popoverPDFURL: URL?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .padding(12)
        .task(id: notebook.id) { await ensureSession() }
        .popover(item: $popoverCitation) { c in
            CitationPopover(
                citation: c,
                sourceTitle: popoverSourceTitle,
                pageHint: popoverPageHint,
                pdfFileURL: popoverPDFURL
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.string(.notesChatPanelTitle)).font(.headline)
            if currentNote != nil {
                Text(t.string(.notesChatCurrentNoteHint))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var messagesList: some View {
        if messages.isEmpty && streamingDraft.isEmpty {
            VStack {
                Spacer()
                Text(t.string(.notesChatPanelEmpty))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { m in
                        MessageBubble(
                            message: m,
                            language: settings.language,
                            onCitationTapped: { c in showCitation(c) },
                            onSaveAsNote: { Task { await saveAsNote(m) } }
                        )
                    }
                    if !streamingDraft.isEmpty {
                        MessageBubble(
                            message: ChatMessage(
                                sessionId: sessionId ?? 0,
                                role: .assistant,
                                content: streamingDraft
                            ),
                            language: settings.language,
                            onCitationTapped: { _ in },
                            onSaveAsNote: nil
                        )
                    }
                    if let errorMessage {
                        Text(t.string(.chatErrorPrefix) + errorMessage)
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(t.string(.chatInputPlaceholder), text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(sending)
            Button(t.string(.chatSendButton)) {
                Task { await send() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 6)
    }

    @MainActor
    private func ensureSession() async {
        do {
            let existing = try store.chatSessions(notebookId: notebook.id!)
            if let s = existing.first {
                sessionId = s.id
            } else {
                sessionId = try store.createChatSession(
                    notebookId: notebook.id!,
                    title: t.string(.chatNewSessionTitle)
                ).id
            }
            await reloadMessages()
        } catch { errorMessage = String(describing: error) }
    }

    @MainActor
    private func reloadMessages() async {
        guard let sid = sessionId else { return }
        do { messages = try store.messages(sessionId: sid) }
        catch { errorMessage = String(describing: error) }
    }

    private func send() async {
        guard let sid = sessionId else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        sending = true
        errorMessage = nil
        streamingDraft = ""
        defer { sending = false; streamingDraft = "" }
        let noteCtx = currentNote?.bodyMd
        do {
            _ = try await chatHolder.engine.send(
                sessionId: sid,
                notebookId: notebook.id!,
                userText: text,
                currentNoteContent: noteCtx
            ) { token in
                Task { @MainActor in streamingDraft += token }
            }
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
            await reloadMessages()
        }
    }

    @MainActor
    private func saveAsNote(_ msg: ChatMessage) async {
        do {
            _ = try store.createNote(
                notebookId: notebook.id!,
                title: "Chat reply — \(msg.createdAt.formatted(date: .abbreviated, time: .shortened))",
                bodyMd: msg.content,
                origin: .chat,
                originRef: msg.id
            )
        } catch { errorMessage = String(describing: error) }
    }

    private func showCitation(_ c: Citation) {
        Task { @MainActor in
            let source = try? store.source(id: c.sourceId)
            let chunks = (try? store.chunks(sourceId: c.sourceId)) ?? []
            let hint = chunks.first(where: { $0.id == c.chunkId })?.pageHint
            let isPDF = (source?.type == .pdf)
            let url: URL? = (isPDF && (source?.rawPath != nil))
                ? URL(fileURLWithPath: source!.rawPath!)
                : nil
            popoverSourceTitle = source?.title ?? ""
            popoverPageHint = hint
            popoverPDFURL = url
            popoverCitation = c
        }
    }
}
```

- [ ] **Step 2: Leave `ChatView` alone**

The existing `ChatView` keeps its sessions sidebar — it's still the
Chat tab content. `NotesChatPanel` is the simpler sibling used inside
NotesView only. No changes needed to `ChatView.swift`.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NotesChatPanel.swift
git commit -m "feat(app): NotesChatPanel — reusable chat surface for Notes 3-col"
```

---

## Task 12: Refactor `NotesView` to 3-column

The current `NotesView` is 2-column (sidebar + editor). Add the chat
panel on the right and observe `NoteJumpCoordinator`.

**Files:** Modify `Sources/AINotebookApp/NotesView.swift`.

- [ ] **Step 1: Add the chat pane + coordinator observation**

Replace the body in `Sources/AINotebookApp/NotesView.swift` so it
becomes 3-column (`HSplitView` of list / editor / chat):

```swift
import SwiftUI
import AINotebookCore

struct NotesView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var noteJump: NoteJumpCoordinator

    @State private var notes: [Note] = []
    @State private var selection: Int64?
    @State private var draftTitle: String = ""
    @State private var draftBody:  String = ""
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    private var currentNote: Note? {
        guard let id = selection else { return nil }
        return notes.first(where: { $0.id == id })
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            NotesChatPanel(notebook: notebook, currentNote: currentNote)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
        }
        .task(id: notebook.id) { await reload() }
        .onReceive(noteJump.$target.compactMap { $0 }) { id in
            // Only jump if the target note belongs to this notebook.
            if notes.contains(where: { $0.id == id }) {
                selection = id
                noteJump.clear()
            }
        }
    }

    // list, detail, originLabel, reload, createBlank, save: unchanged from M6
    // (re-paste them verbatim; do NOT delete them)
    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.string(.notesSectionTitle)).font(.title3).bold()
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
                Text(t.string(.notesEmptyState)).foregroundStyle(.secondary)
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
        } catch { errorMessage = String(describing: error) }
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
        } catch { errorMessage = String(describing: error) }
    }

    private func save(id: Int64) async {
        do {
            try store.updateNote(id: id, title: draftTitle, bodyMd: draftBody)
            await reload()
        } catch { errorMessage = String(describing: error) }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NotesView.swift
git commit -m "feat(app): 3-column NotesView (list | editor | chat panel)"
```

---

## Task 13: `CitationPopover` "Open Note" action

When the citation's source is a Note shadow, surface a button that
publishes the jump via `NoteJumpCoordinator`.

**Files:** Modify `Sources/AINotebookApp/CitationPopover.swift`, modify `Sources/AINotebookApp/NotesChatPanel.swift` (and `ChatView.swift` if it builds CitationPopover too).

- [ ] **Step 1: Add the note jump param to `CitationPopover`**

Replace the init in `Sources/AINotebookApp/CitationPopover.swift`:

```swift
import SwiftUI
import AppKit
import AINotebookCore

struct CitationPopover: View {

    let citation: Citation
    let sourceTitle: String
    let pageHint: Int?
    let pdfFileURL: URL?
    let noteIdToOpen: Int64?   // nil if this citation isn't a Note shadow

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var noteJump: NoteJumpCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.opening")
                Text(sourceTitle).font(.headline)
                Spacer()
                if let page = pageHint, let url = pdfFileURL {
                    Button("Open page \(page)") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                if let nid = noteIdToOpen {
                    Button(settings.text.string(.openNoteFromCitation)) {
                        noteJump.request(noteId: nid)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Divider()
            ScrollView {
                Text(citation.snippet)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 400)
    }
}
```

- [ ] **Step 2: Resolve `noteIdToOpen` in both callers**

In `Sources/AINotebookApp/NotesChatPanel.swift` (and `Sources/AINotebookApp/ChatView.swift` if it constructs `CitationPopover` directly), update `showCitation` to also fetch the Note id when `source.type == .note`:

```swift
@State private var popoverNoteId: Int64?

private func showCitation(_ c: Citation) {
    Task { @MainActor in
        let source = try? store.source(id: c.sourceId)
        let chunks = (try? store.chunks(sourceId: c.sourceId)) ?? []
        let hint = chunks.first(where: { $0.id == c.chunkId })?.pageHint
        let isPDF = (source?.type == .pdf)
        let url: URL? = (isPDF && (source?.rawPath != nil))
            ? URL(fileURLWithPath: source!.rawPath!)
            : nil
        var noteId: Int64? = nil
        if source?.type == .note {
            // Find the Note whose auto_source_id matches this shadow source.
            let allNotes = (try? store.notes(notebookId: source!.notebookId)) ?? []
            noteId = allNotes.first(where: { $0.autoSourceId == source!.id })?.id
        }
        popoverSourceTitle = source?.title ?? ""
        popoverPageHint = hint
        popoverPDFURL = url
        popoverNoteId = noteId
        popoverCitation = c
    }
}
```

And update the `.popover` content:

```swift
.popover(item: $popoverCitation) { c in
    CitationPopover(
        citation: c,
        sourceTitle: popoverSourceTitle,
        pageHint: popoverPageHint,
        pdfFileURL: popoverPDFURL,
        noteIdToOpen: popoverNoteId
    )
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/CitationPopover.swift Sources/AINotebookApp/NotesChatPanel.swift Sources/AINotebookApp/ChatView.swift
git commit -m "feat(app): citation popover surfaces 'Open note' for Note shadows"
```

---

## Task 14: Final verification + version + merge

- [ ] **Step 1: Clean build + parallel tests**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: ≈ 170 tests pass (159 baseline + MigrationV6(3) + NoteIndexer(4) + NoteIndexerHook(1) + ChatEngineCurrentNoteContext(2) + Localization(1) + SourceType(3)).

- [ ] **Step 2: Manual smoke**

```bash
swift run AINotebookApp
```

With Ollama running:
- Create a notebook → Notes tab → 3-column layout visible.
- Create a Note, type "I prefer to travel by train.", ⌘S.
- In chat panel (right): ask "How do I prefer to travel?". Streamed
  reply cites the Note `[1]` and the popover offers "Open note".
- Click "Open note" → selection in the list jumps to that Note.

- [ ] **Step 3: Bump version + CHANGELOG**

```bash
echo "0.3.0" > VERSION
```

Edit `Sources/AINotebookCore/AINotebookVersion.swift` → `"0.3.0"`.

Prepend to `CHANGELOG.md`:

```markdown
## [0.3.0] — 2026-05-25

Notes graduate from passive note-taking to the primary authoring canvas.

### Added
- Notes auto-indexing: every Note participates in RAG retrieval via a
  hidden shadow Source row.
- Three-column Notes tab: list / editor / chat sidebar.
- Chat sidebar injects the currently-open Note as bonus context.
- Citation popover "Open note" action jumps to the cited Note.

### Schema
- MigrationV6 adds `notes.auto_source_id` + `notes.note_uuid`; existing
  Notes get a backfilled UUID on first launch.

### Tests
- ~170 unit tests (was 159).
```

Commit:
```bash
git add VERSION CHANGELOG.md Sources/AINotebookCore/AINotebookVersion.swift
git commit -m "chore: bump version to 0.3.0 + CHANGELOG"
```

- [ ] **Step 4: Merge to main + tag**

```bash
git checkout main
git merge --ff-only m7-2-notes-as-rag
git tag -a v0.3.0 -m "v0.3.0 — Notes as RAG + 3-column + chat sidebar"
git log --oneline | head -16
```

- [ ] **Step 5: Re-build DMG**

```bash
./tools/macos/build-app.sh
./tools/macos/build-dmg.sh
ls -lh dist/
```

Expected: `dist/AINotebook-v0.3.0-macos.dmg` exists.

---

## Acceptance criteria (M7.2 done when ALL true)

- `swift test --parallel` ≈ 170 tests, 0 failures.
- `SourceType.note` exists and isn't reachable via `detect(filename:)`.
- `MigrationV6` adds `notes.auto_source_id` + `notes.note_uuid`;
  pre-existing Notes get UUIDs backfilled.
- `NotebookStore.sources(notebookId:)` excludes `.note` rows;
  `sourcesIncludingShadow(notebookId:)` includes them.
- `NoteIndexer.index(noteId:)` creates a shadow Source on first call,
  reuses it on subsequent calls, and replaces chunks each time.
- `NotebookStore.onNoteSaved` fires on `createNote` and `updateNote`.
- `ChatEngine.send(...currentNoteContent:)` injects a "CURRENTLY OPEN
  NOTE" section into the system prompt when non-nil.
- NotesView shows 3 columns: list | editor | chat panel.
- Clicking "Open note" on a citation popover navigates to that Note.
- DMG `AINotebook-v0.3.0-macos.dmg` builds clean.
- Local git tag `v0.3.0` exists; `main` fast-forwarded.

---

## Notes for the implementer

- **`NotebookStore.onNoteSaved` runs as `Task { ... }`:** it's
  fire-and-forget. Errors from `NoteIndexer.index(...)` are swallowed
  in the app-layer wiring (printed). For v0.3 that's acceptable; future
  iterations can surface them via the existing `IndexingStatusBadge`.
- **Shadow source visibility:** the Retriever joins `chunk_embeddings`
  to `sources` already (M4), so `.note` rows are naturally included.
  No Retriever change is needed.
- **Chat sidebar vs Chat tab:** the existing `ChatView` (M5) stays
  unchanged for the Chat tab — it keeps the multi-session sidebar.
  `NotesChatPanel` is a slimmer sibling that hides session management
  and always picks the latest session for the notebook.
- **`onNoteSaved` ordering vs. `Task {}`:** if a user types fast and
  multiple `updateNote` calls land back-to-back, the `Task { }` calls
  fire in submission order. `NoteIndexer` is an actor — concurrent
  `index(noteId:)` calls serialise on its actor queue. Idempotent
  re-indexing means the final body wins.
- **Citation snippet for Notes:** uses the existing `Retriever` snippet
  pipeline (first 240 chars of the chunk text). Nothing Note-specific.
- **Forward compat for M8/M9/M10:** Task 5 (`NoteIndexer`) is the only
  module that touches the embedding path. M8 (WYSIWYG) will keep
  `Note.bodyMd` as the source of truth, so the indexer keeps working
  unchanged. M9 (attachments) adds a separate `attachments` table —
  the indexer ignores attachments (they're not text). M10 (versions)
  adds a separate `note_versions` table and snapshots happen in a
  `NoteVersionRecorder` hooked into `updateNote` BEFORE the body is
  overwritten.
