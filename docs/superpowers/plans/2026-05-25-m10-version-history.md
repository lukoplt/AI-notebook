# M10: Note Version History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every save snapshots the previous Note body into `note_versions`. UI: a "History" button opens a sheet listing prior revisions with a read-only preview pane and a "Restore" action.

**Architecture:** New `note_versions` table + `NoteVersion` GRDB record. `NotebookStore.updateNote` snapshots the existing body BEFORE writing the new one. Cap at 50 versions per Note (oldest pruned on insert). UI is a single SwiftUI sheet `NoteHistorySheet` triggered from a button in the WYSIWYG editor toolbar.

**Tech Stack:** Swift 6, GRDB, SwiftUI.

---

## File Structure

**Create:**
- `Sources/AINotebookCore/MigrationV8.swift`
- `Sources/AINotebookCore/NoteVersion.swift`
- `Sources/AINotebookCore/NotebookStore+NoteVersions.swift`
- `Sources/AINotebookApp/NoteHistorySheet.swift`
- `Tests/AINotebookCoreTests/MigrationV8Tests.swift`
- `Tests/AINotebookCoreTests/NoteVersionStoreTests.swift`

**Modify:**
- `Sources/AINotebookCore/NotebookStore.swift` — register V8
- `Sources/AINotebookCore/NotebookStore+Notes.swift` — snapshot in `updateNote` BEFORE write
- `Sources/AINotebookCore/Localization.swift` — 6 EN/CS keys
- `Sources/AINotebookApp/NoteWYSIWYGEditor.swift` — History button in status row
- `Sources/AINotebookApp/NotesView.swift` — present `NoteHistorySheet`

---

## Task 1: Branch + baseline

```bash
git checkout main
git checkout -b m10-version-history
swift test --parallel 2>&1 | tail -5
```

Expected: 186/186 pass.

---

## Task 2: MigrationV8 — `note_versions` table

**Files:** Create `Sources/AINotebookCore/MigrationV8.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV8Tests.swift`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV8Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV8Tests: XCTestCase {

    func testV8CreatesNoteVersionsTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("note_versions"), "got: \(names)")
        }
    }

    func testNoteVersionsCascadeOnNoteDelete() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO note_versions(note_id,title,body_md,saved_at,reason) VALUES (?,?,?,?,?)",
                arguments: [n.id!, "T", "old", Date(), "autosave"]
            )
        }
        try store.deleteNote(id: n.id!)
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM note_versions") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter MigrationV8Tests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/MigrationV8.swift
import GRDB

public func registerMigrationV8(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v8_note_versions") { db in
        try db.create(table: "note_versions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("note_id", .integer)
                .notNull()
                .references("notes", onDelete: .cascade)
            t.column("title",    .text).notNull()
            t.column("body_md",  .text).notNull()
            t.column("saved_at", .datetime).notNull()
            t.column("reason",   .text).notNull()
        }
        try db.create(
            index: "idx_note_versions_note",
            on: "note_versions",
            columns: ["note_id", "saved_at"]
        )
    }
}
```

In `Sources/AINotebookCore/NotebookStore.swift`, append after `registerMigrationV7(on: &migrator)`:

```swift
        registerMigrationV8(on: &migrator)
```

- [ ] **Step 4: Verify + commit**

```bash
swift test --filter MigrationV8Tests 2>&1 | tail -10
git add Sources/AINotebookCore/MigrationV8.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV8Tests.swift
git commit -m "feat(core): MigrationV8 — note_versions table"
```

---

## Task 3: `NoteVersion` GRDB record

**Files:** Create `Sources/AINotebookCore/NoteVersion.swift`.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookCore/NoteVersion.swift
import Foundation
import GRDB

public enum NoteVersionReason: String, Codable, Sendable, CaseIterable {
    case autosave
    case manual
    case restore
}

public struct NoteVersion: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var noteId: Int64
    public var title: String
    public var bodyMd: String
    public var savedAt: Date
    public var reason: NoteVersionReason

    public init(
        id: Int64? = nil,
        noteId: Int64,
        title: String,
        bodyMd: String,
        savedAt: Date = Date(),
        reason: NoteVersionReason
    ) {
        self.id = id
        self.noteId = noteId
        self.title = title
        self.bodyMd = bodyMd
        self.savedAt = savedAt
        self.reason = reason
    }
}

extension NoteVersion: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note_versions"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case noteId  = "note_id"
        case title
        case bodyMd  = "body_md"
        case savedAt = "saved_at"
        case reason

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/NoteVersion.swift
git commit -m "feat(core): NoteVersion GRDB record"
```

---

## Task 4: Snapshot in `updateNote` + CRUD + 50-row cap

**Files:** Create `Sources/AINotebookCore/NotebookStore+NoteVersions.swift`, modify `Sources/AINotebookCore/NotebookStore+Notes.swift`, test `Tests/AINotebookCoreTests/NoteVersionStoreTests.swift`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/NoteVersionStoreTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NoteVersionStoreTests: XCTestCase {

    func testUpdateSnapshotsPreviousBody() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        try store.updateNote(id: n.id!, title: "T", bodyMd: "v2")
        let versions = try store.noteVersions(noteId: n.id!)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].bodyMd, "v1")
        XCTAssertEqual(versions[0].reason, .autosave)
    }

    func testManualSnapshot() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        try store.snapshotNoteVersion(noteId: n.id!, reason: .manual)
        let versions = try store.noteVersions(noteId: n.id!)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].bodyMd, "v1")
        XCTAssertEqual(versions[0].reason, .manual)
    }

    func testRestoreCreatesNewSnapshotAndOverwritesBody() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        try store.updateNote(id: n.id!, title: "T", bodyMd: "v2")
        let versions = try store.noteVersions(noteId: n.id!)
        let v1 = try XCTUnwrap(versions.first)
        try store.restoreNoteVersion(versionId: v1.id!)
        let reloaded = try XCTUnwrap(try store.note(id: n.id!))
        XCTAssertEqual(reloaded.bodyMd, "v1")
        let all = try store.noteVersions(noteId: n.id!)
        XCTAssertGreaterThanOrEqual(all.count, 2)
        XCTAssertEqual(all.last?.reason, .autosave) // snapshot of v2 before restore wrote v1 back via updateNote
    }

    func testFiftyRowCapPrunesOldest() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v0")
        for i in 1...60 {
            try store.updateNote(id: n.id!, title: "T", bodyMd: "v\(i)")
        }
        let versions = try store.noteVersions(noteId: n.id!)
        XCTAssertLessThanOrEqual(versions.count, 50)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter NoteVersionStoreTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement extension**

```swift
// Sources/AINotebookCore/NotebookStore+NoteVersions.swift
import Foundation
import GRDB

extension NotebookStore {

    /// Cap per Note. Older snapshots beyond this are pruned.
    public static let noteVersionCap: Int = 50

    public func noteVersions(noteId: Int64) throws -> [NoteVersion] {
        try runOnDatabase { db in
            try NoteVersion
                .filter(NoteVersion.Columns.noteId.column == noteId)
                .order(NoteVersion.Columns.savedAt.column.asc)
                .fetchAll(db)
        }
    }

    /// Snapshot the Note's current body+title with the given reason.
    /// Returns the inserted version.
    @discardableResult
    public func snapshotNoteVersion(noteId: Int64, reason: NoteVersionReason) throws -> NoteVersion? {
        guard let note = try note(id: noteId) else { return nil }
        var version = NoteVersion(
            noteId: noteId,
            title: note.title,
            bodyMd: note.bodyMd,
            savedAt: Date(),
            reason: reason
        )
        try runOnDatabase { db in
            try version.insert(db)
            try Self.pruneIfNeeded(db: db, noteId: noteId)
        }
        return version
    }

    public func restoreNoteVersion(versionId: Int64) throws {
        try runOnDatabase { db in
            guard let v = try NoteVersion.fetchOne(db, key: versionId) else { return }
            // Snapshot whatever's currently in notes for that id with reason = restore.
            if let current = try Note.fetchOne(db, key: v.noteId) {
                var restore = NoteVersion(
                    noteId: v.noteId,
                    title: current.title,
                    bodyMd: current.bodyMd,
                    savedAt: Date(),
                    reason: .restore
                )
                try restore.insert(db)
                try Self.pruneIfNeeded(db: db, noteId: v.noteId)
            }
            try db.execute(
                sql: "UPDATE notes SET title = ?, body_md = ?, updated_at = ? WHERE id = ?",
                arguments: [v.title, v.bodyMd, Date(), v.noteId]
            )
        }
        // Fire the regular save hook so RAG re-indexes the restored body.
        if let hook = onNoteSaved {
            let nid: Int64 = try runOnDatabase { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT note_id FROM note_versions WHERE id = ?",
                    arguments: [versionId]
                ) ?? 0
            }
            if nid != 0 { Task { await hook(nid) } }
        }
    }

    static func pruneIfNeeded(db: Database, noteId: Int64) throws {
        let total: Int = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM note_versions WHERE note_id = ?",
            arguments: [noteId]
        ) ?? 0
        let cap = NotebookStore.noteVersionCap
        if total > cap {
            try db.execute(
                sql: """
                DELETE FROM note_versions
                WHERE id IN (
                  SELECT id FROM note_versions
                  WHERE note_id = ?
                  ORDER BY saved_at ASC
                  LIMIT ?
                )
                """,
                arguments: [noteId, total - cap]
            )
        }
    }
}
```

- [ ] **Step 4: Snapshot in `updateNote` BEFORE write**

In `Sources/AINotebookCore/NotebookStore+Notes.swift`, modify `updateNote`:

```swift
    public func updateNote(id: Int64, title: String, bodyMd: String) throws {
        // Snapshot previous body BEFORE overwriting.
        try? snapshotNoteVersion(noteId: id, reason: .autosave)

        try runOnDatabase { db in
            guard var n = try Note.fetchOne(db, key: id) else { return }
            n.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            n.bodyMd = bodyMd
            n.updatedAt = Date()
            try n.update(db)
        }
        if let hook = onNoteSaved {
            Task { await hook(id) }
        }
    }
```

- [ ] **Step 5: Verify + commit**

```bash
swift test --filter NoteVersionStoreTests 2>&1 | tail -10
git add Sources/AINotebookCore/NotebookStore+NoteVersions.swift Sources/AINotebookCore/NotebookStore+Notes.swift Tests/AINotebookCoreTests/NoteVersionStoreTests.swift
git commit -m "feat(core): note version history — snapshot on update + restore + 50-row cap"
```

Expected: 4/4 pass.

---

## Task 5: 6 EN/CS localization keys

| key | EN | CS |
|---|---|---|
| `historyButton` | "History" | "Historie" |
| `historySheetTitle` | "Version history" | "Historie verzí" |
| `historyEmpty` | "No earlier versions yet." | "Žádné dřívější verze." |
| `historyRestoreButton` | "Restore this version" | "Obnovit tuto verzi" |
| `historyReasonAutosave` | "Auto-save" | "Auto-uložení" |
| `historyReasonRestore` | "Restored" | "Obnoveno" |

Add to `Sources/AINotebookCore/Localization.swift`, append test:

```swift
    func testHistoryRestoreButtonBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.historyRestoreButton), "Restore this version")
        XCTAssertEqual(AppText(language: .czech)  .string(.historyRestoreButton), "Obnovit tuto verzi")
    }
```

Commit:
```bash
swift test --filter LocalizationTests 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): 6 EN/CS history sheet localization keys"
```

---

## Task 6: `NoteHistorySheet`

**Files:** Create `Sources/AINotebookApp/NoteHistorySheet.swift`.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/NoteHistorySheet.swift
import SwiftUI
import AINotebookCore

struct NoteHistorySheet: View {

    let noteId: Int64

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Binding var isPresented: Bool

    @State private var versions: [NoteVersion] = []
    @State private var selection: Int64?
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.historySheetTitle)).font(.title2).bold()
            HSplitView {
                list.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 360)
            HStack {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 460)
        .task(id: noteId) { await reload() }
    }

    @ViewBuilder
    private var list: some View {
        if versions.isEmpty {
            VStack {
                Spacer()
                Text(t.string(.historyEmpty)).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            // Newest first
            List(selection: $selection) {
                ForEach(versions.reversed()) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reasonLabel(v.reason)).font(.headline)
                        Text(v.savedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(v.id ?? -1)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let id = selection, let v = versions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(v.title).font(.title3).bold()
                ScrollView {
                    Text(v.bodyMd)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(t.string(.historyRestoreButton)) {
                        Task { await restore(versionId: id) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            VStack {
                Spacer()
                Text(t.string(.historyEmpty)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func reasonLabel(_ r: NoteVersionReason) -> String {
        switch r {
        case .autosave: return t.string(.historyReasonAutosave)
        case .manual:   return t.string(.editorStatusSaved)
        case .restore:  return t.string(.historyReasonRestore)
        }
    }

    @MainActor
    private func reload() async {
        do {
            versions = try store.noteVersions(noteId: noteId)
            if selection == nil { selection = versions.last?.id }
        } catch { errorMessage = String(describing: error) }
    }

    private func restore(versionId: Int64) async {
        do {
            try store.restoreNoteVersion(versionId: versionId)
            isPresented = false
        } catch { errorMessage = String(describing: error) }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NoteHistorySheet.swift
git commit -m "feat(app): NoteHistorySheet (list + preview + restore)"
```

---

## Task 7: Wire History button into `NoteWYSIWYGEditor` + present from `NotesView`

**Files:** Modify `Sources/AINotebookApp/NoteWYSIWYGEditor.swift`, modify `Sources/AINotebookApp/NotesView.swift`.

- [ ] **Step 1: Add a History button**

In `Sources/AINotebookApp/NoteWYSIWYGEditor.swift`, extend init with an optional close-over to open the history sheet:

```swift
let onShowHistory: (() -> Void)?
```

Default to `nil` so existing callers compile. Add init param `onShowHistory: (() -> Void)? = nil`.

In the bottom HStack (status + Save), add:

```swift
if let onShowHistory {
    Button(t.string(.historyButton)) { onShowHistory() }
        .keyboardShortcut("h", modifiers: [.command, .shift])
}
```

(Place between `Spacer()` and the existing Save button.)

- [ ] **Step 2: Present from `NotesView`**

In `Sources/AINotebookApp/NotesView.swift`:

1. Add state:
```swift
@State private var historyNoteId: Int64?
```

2. Pass `onShowHistory` to editor:
```swift
NoteWYSIWYGEditor(
    title: $draftTitle,
    bodyMd: $draftBody,
    language: settings.language,
    noteId: id,
    noteUuid: notes.first(where: { $0.id == id })?.noteUuid ?? "",
    attachments: attachmentsHolder.store,
    onShowHistory: { historyNoteId = id },
    onSave: { _ in Task { @MainActor in await save(id: id) } }
)
```

3. Add `.sheet`:
```swift
.sheet(
    item: Binding(
        get: { historyNoteId.map { NoteIdBox(id: $0) } },
        set: { historyNoteId = $0?.id }
    ),
    onDismiss: { Task { await reload() } }
) { box in
    NoteHistorySheet(
        noteId: box.id,
        isPresented: Binding(
            get: { historyNoteId != nil },
            set: { if !$0 { historyNoteId = nil } }
        )
    )
}
```

Add at file scope:
```swift
private struct NoteIdBox: Identifiable, Hashable {
    let id: Int64
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NoteWYSIWYGEditor.swift Sources/AINotebookApp/NotesView.swift
git commit -m "feat(app): History button + NoteHistorySheet presentation"
```

---

## Task 8: Final verification + version + tag + merge

- [ ] **Step 1: Clean build + tests**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: ~192 tests pass (186 + MigrationV8(2) + NoteVersionStore(4) + Localization(1)).

- [ ] **Step 2: Bump version + CHANGELOG**

```bash
echo "0.6.0" > VERSION
```

Edit `Sources/AINotebookCore/AINotebookVersion.swift` → `"0.6.0"`. Update `Tests/AINotebookCoreTests/AINotebookVersionTests.swift`.

Prepend to `CHANGELOG.md`:

```markdown
## [0.6.0] — 2026-05-25

Version history for Notes.

### Added
- Every save snapshots the previous Note body into `note_versions`.
- History button in the WYSIWYG editor (⌘⇧H) opens a sheet listing
  prior revisions with timestamps and a read-only preview.
- "Restore this version" re-writes the Note body and snapshots the
  superseded content as a `restore`-tagged revision.
- 50-version cap per Note; oldest snapshots pruned automatically.

### Schema
- MigrationV8 adds the `note_versions` table.

### Tests
- ~192 unit tests (was 186).
```

Commit:
```bash
git add VERSION CHANGELOG.md Sources/AINotebookCore/AINotebookVersion.swift Tests/AINotebookCoreTests/AINotebookVersionTests.swift
git commit -m "chore: bump version to 0.6.0 + CHANGELOG"
```

- [ ] **Step 3: Merge + tag**

```bash
git checkout main
git merge --ff-only m10-version-history
git tag -a v0.6.0 -m "v0.6.0 — note version history"
```

- [ ] **Step 4: Re-build DMG**

```bash
./tools/macos/build-app.sh
./tools/macos/build-dmg.sh
ls -lh dist/
```

---

## Acceptance criteria

- `swift test --parallel` ≥ 192 tests pass.
- `updateNote` snapshots the previous body BEFORE overwriting.
- `restoreNoteVersion` writes the historical body back and records a
  `restore`-tagged snapshot of the superseded content.
- 50-version cap prunes oldest entries.
- History button opens `NoteHistorySheet`, "Restore" swaps the body
  and dismisses.
- Tag `v0.6.0` exists, `main` fast-forwarded.

---

## Notes for the implementer

- **Snapshot timing:** snapshot fires inside `updateNote` BEFORE the
  `Note.update(db)`. We accept the snapshot reflecting the state of
  the Note moments before save — typically identical to what the user
  sees. Race conditions don't matter (single-user).
- **Restore + RAG:** `restoreNoteVersion` triggers `onNoteSaved`, so
  the existing `NoteIndexer` re-embeds the restored body.
- **Attachments + versions:** attachments are referenced from the
  Markdown body; restoring an old body that referenced an attachment
  the user has since deleted will produce a broken-image chip. v1
  accepts this trade-off (no attachment GC across versions).
- **UI snapshot of "manual"**: only used internally if a future
  toolbar gets an explicit "Snapshot now" button. Reusing
  `editorStatusSaved` ("Saved") label is fine for v1.
