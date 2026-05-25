# M9: Attachments + Inline Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users paste/drag images and files into the WYSIWYG editor. Attachments live on disk under the per-Note UUID folder. Inline images render in the editor via a custom `attachment://` URL scheme.

**Architecture:** New `attachments` table tracks metadata; bytes live at `~/Library/Application Support/AINotebook/attachments/<note-uuid>/<filename>`. A `WKURLSchemeHandler` registered on the editor's `WKWebView` serves `attachment://` URLs from disk. The TipTap editor gets a paste/drop handler that posts file bytes (base64) to Swift; Swift writes the file, replies with the markdown URL, JS inserts the image/link.

**Tech Stack:** Swift 6, WebKit, the existing TipTap editor bundle.

---

## File Structure

**Create:**
- `Sources/AINotebookCore/MigrationV7.swift` — `attachments` table
- `Sources/AINotebookCore/NoteAttachment.swift` — GRDB record
- `Sources/AINotebookCore/AttachmentStore.swift` — disk I/O + DB CRUD
- `Sources/AINotebookApp/AttachmentURLSchemeHandler.swift` — `WKURLSchemeHandler`
- `Tests/AINotebookCoreTests/MigrationV7Tests.swift`
- `Tests/AINotebookCoreTests/AttachmentStoreTests.swift`

**Modify:**
- `Sources/AINotebookCore/NotebookStore.swift` — register V7 + own `AttachmentStore`
- `Sources/AINotebookCore/NotebookStore+Notes.swift` — `deleteNote` also clears attachments
- `Sources/AINotebookCore/Localization.swift` — 3 new EN/CS keys
- `Sources/AINotebookApp/MarkdownHTMLBridge.swift` — add `.attachmentRequest` message
- `Sources/AINotebookApp/NoteWYSIWYGEditor.swift` — register scheme handler + reply to attachment requests
- `tools/editor/src/editor.ts` — paste/drop file handlers
- `Sources/AINotebookApp/Resources/editor/editor.js` — rebuilt

---

## Task 1: Branch + baseline

```bash
git checkout main
git checkout -b m9-attachments
swift test --parallel 2>&1 | tail -5
```

Expected: 179/179 pass.

---

## Task 2: MigrationV7 — attachments table

**Files:** Create `Sources/AINotebookCore/MigrationV7.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV7Tests.swift`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV7Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV7Tests: XCTestCase {

    func testV7CreatesAttachmentsTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("attachments"), "got: \(names)")
        }
    }

    func testAttachmentCascadesOnNoteDelete() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO attachments(note_id,note_uuid,filename,mime,byte_size,created_at) VALUES (?,?,?,?,?,?)",
                arguments: [n.id!, n.noteUuid, "a.png", "image/png", 123, Date()]
            )
        }
        try store.deleteNote(id: n.id!)
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter MigrationV7Tests 2>&1 | tail -10
```

- [ ] **Step 3: Implement migration**

```swift
// Sources/AINotebookCore/MigrationV7.swift
import GRDB

public func registerMigrationV7(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v7_attachments") { db in
        try db.create(table: "attachments") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("note_id", .integer)
                .notNull()
                .references("notes", onDelete: .cascade)
            t.column("note_uuid",  .text).notNull()
            t.column("filename",   .text).notNull()
            t.column("mime",       .text).notNull()
            t.column("byte_size",  .integer).notNull()
            t.column("created_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_attachments_note",
            on: "attachments",
            columns: ["note_id"]
        )
    }
}
```

- [ ] **Step 4: Register**

In `Sources/AINotebookCore/NotebookStore.swift`, append after `registerMigrationV6(on: &migrator)`:

```swift
        registerMigrationV7(on: &migrator)
```

- [ ] **Step 5: Verify + commit**

```bash
swift test --filter MigrationV7Tests 2>&1 | tail -10
git add Sources/AINotebookCore/MigrationV7.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV7Tests.swift
git commit -m "feat(core): MigrationV7 — attachments table"
```

Expected: 2/2 pass.

---

## Task 3: `NoteAttachment` GRDB record

**Files:** Create `Sources/AINotebookCore/NoteAttachment.swift`.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookCore/NoteAttachment.swift
import Foundation
import GRDB

public struct NoteAttachment: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var noteId: Int64
    public var noteUuid: String
    public var filename: String
    public var mime: String
    public var byteSize: Int64
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        noteId: Int64,
        noteUuid: String,
        filename: String,
        mime: String,
        byteSize: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.noteId = noteId
        self.noteUuid = noteUuid
        self.filename = filename
        self.mime = mime
        self.byteSize = byteSize
        self.createdAt = createdAt
    }
}

extension NoteAttachment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "attachments"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case noteId    = "note_id"
        case noteUuid  = "note_uuid"
        case filename
        case mime
        case byteSize  = "byte_size"
        case createdAt = "created_at"

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
git add Sources/AINotebookCore/NoteAttachment.swift
git commit -m "feat(core): NoteAttachment GRDB record"
```

---

## Task 4: `AttachmentStore` — disk I/O + DB CRUD

**Files:** Create `Sources/AINotebookCore/AttachmentStore.swift`, test `Tests/AINotebookCoreTests/AttachmentStoreTests.swift`.

`AttachmentStore` is independent of `NotebookStore`. The folder root is
configurable so tests use a temp dir; production uses
`~/Library/Application Support/AINotebook/attachments/`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/AttachmentStoreTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class AttachmentStoreTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-att-\(UUID().uuidString)")
    }

    func testSaveWritesFileAndDbRow() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)

        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let att = try atts.save(noteId: n.id!,
                                noteUuid: n.noteUuid,
                                filename: "icon.png",
                                mime: "image/png",
                                bytes: bytes)
        XCTAssertNotNil(att.id)
        let onDisk = root
            .appendingPathComponent(n.noteUuid)
            .appendingPathComponent("icon.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))
        XCTAssertEqual(try Data(contentsOf: onDisk), bytes)
        XCTAssertEqual(try atts.list(noteId: n.id!).count, 1)
    }

    func testCollisionAppendsSuffix() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)
        let a = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "x.png",
                              mime: "image/png", bytes: Data([1]))
        let b = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "x.png",
                              mime: "image/png", bytes: Data([2]))
        XCTAssertEqual(a.filename, "x.png")
        XCTAssertNotEqual(b.filename, "x.png")
        XCTAssertTrue(b.filename.hasPrefix("x ") || b.filename.contains("(2)"),
                     "got: \(b.filename)")
    }

    func testReadReturnsBytes() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)
        _ = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "a.bin",
                          mime: "application/octet-stream", bytes: Data([42, 43, 44]))
        let read = try atts.read(noteUuid: n.noteUuid, filename: "a.bin")
        XCTAssertEqual(read, Data([42, 43, 44]))
    }

    func testDeleteNoteFolderRemovesFiles() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)
        _ = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "a.png",
                          mime: "image/png", bytes: Data([1]))
        try atts.deleteFolder(noteUuid: n.noteUuid)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(n.noteUuid).path
            )
        )
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter AttachmentStoreTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/AttachmentStore.swift
import Foundation
import GRDB

@MainActor
public final class AttachmentStore {

    private let store: NotebookStore
    public let root: URL

    public init(store: NotebookStore, root: URL) {
        self.store = store
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )
        let container = appSupport.appendingPathComponent("AINotebook", isDirectory: true)
        let attachments = container.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        return attachments
    }

    @discardableResult
    public func save(
        noteId: Int64,
        noteUuid: String,
        filename: String,
        mime: String,
        bytes: Data
    ) throws -> NoteAttachment {
        let folder = root.appendingPathComponent(noteUuid, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = uniqueFilename(in: folder, requested: filename)
        let url = folder.appendingPathComponent(resolved)
        try bytes.write(to: url)
        var att = NoteAttachment(
            noteId: noteId,
            noteUuid: noteUuid,
            filename: resolved,
            mime: mime,
            byteSize: Int64(bytes.count)
        )
        try store.runOnDatabase { db in
            try att.insert(db)
        }
        return att
    }

    public func read(noteUuid: String, filename: String) throws -> Data {
        let url = root
            .appendingPathComponent(noteUuid, isDirectory: true)
            .appendingPathComponent(filename)
        return try Data(contentsOf: url)
    }

    public func list(noteId: Int64) throws -> [NoteAttachment] {
        try store.runOnDatabase { db in
            try NoteAttachment
                .filter(NoteAttachment.Columns.noteId.column == noteId)
                .order(NoteAttachment.Columns.createdAt.column.asc)
                .fetchAll(db)
        }
    }

    public func deleteFolder(noteUuid: String) throws {
        let folder = root.appendingPathComponent(noteUuid, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// "x.png" → "x.png" if free, otherwise "x (2).png", "x (3).png", …
    private func uniqueFilename(in folder: URL, requested: String) -> String {
        let stem = (requested as NSString).deletingPathExtension
        let ext = (requested as NSString).pathExtension
        let dotExt = ext.isEmpty ? "" : ".\(ext)"
        var candidate = requested
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(n))\(dotExt)"
            n += 1
            if n > 9_999 { break }
        }
        return candidate
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter AttachmentStoreTests 2>&1 | tail -10
git add Sources/AINotebookCore/AttachmentStore.swift Tests/AINotebookCoreTests/AttachmentStoreTests.swift
git commit -m "feat(core): AttachmentStore — disk + DB CRUD with collision suffix"
```

Expected: 4/4 pass.

---

## Task 5: Cascade-delete folder when Note deleted

**Files:** Modify `Sources/AINotebookCore/NotebookStore+Notes.swift`.

The DB cascade removes rows; we also need to delete the folder. The
store doesn't know about `AttachmentStore` directly, so we expose a hook
analogous to `onNoteSaved`.

- [ ] **Step 1: Add a `onNoteDeleted` hook**

In `Sources/AINotebookCore/NotebookStore.swift`, add inside the class:

```swift
    /// Fires AFTER `deleteNote(...)` removes the row. Carries the deleted
    /// Note's UUID so the app can clean up its attachment folder.
    public var onNoteDeleted: (@Sendable (String) async -> Void)?
```

- [ ] **Step 2: Fire from `deleteNote`**

In `Sources/AINotebookCore/NotebookStore+Notes.swift`, change `deleteNote`:

```swift
    public func deleteNote(id: Int64) throws {
        // Capture uuid first so the hook receives it after the row is gone.
        let uuid: String? = try runOnDatabase { db in
            try String.fetchOne(
                db,
                sql: "SELECT note_uuid FROM notes WHERE id = ?",
                arguments: [id]
            )
        }
        try runOnDatabase { db in
            _ = try Note.deleteOne(db, key: id)
        }
        if let uuid, let hook = onNoteDeleted {
            Task { await hook(uuid) }
        }
    }
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/NotebookStore.swift Sources/AINotebookCore/NotebookStore+Notes.swift
git commit -m "feat(core): NotebookStore.onNoteDeleted hook for attachment folder cleanup"
```

---

## Task 6: 3 EN/CS localization keys

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, modify `Tests/AINotebookCoreTests/LocalizationTests.swift`.

| key | EN | CS |
|---|---|---|
| `attachmentBrokenLink` | "Attachment missing" | "Příloha chybí" |
| `attachmentSaveFailed` | "Couldn't save attachment" | "Nepodařilo se uložit přílohu" |
| `attachmentOpenButton` | "Open" | "Otevřít" |

Test:
```swift
    func testAttachmentOpenButtonBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.attachmentOpenButton), "Open")
        XCTAssertEqual(AppText(language: .czech)  .string(.attachmentOpenButton), "Otevřít")
    }
```

Commit:
```bash
swift test --filter LocalizationTests 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): 3 EN/CS attachment localization keys"
```

---

## Task 7: Extend `MarkdownHTMLBridge` with attachment request message

**Files:** Modify `Sources/AINotebookApp/MarkdownHTMLBridge.swift`.

Add a new `.attachmentRequest(filename:mime:base64:requestId:)` case:

```swift
enum EditorMessage: Equatable {
    case ready
    case change(markdown: String)
    case save(markdown: String)
    case attachmentRequest(requestId: String, filename: String, mime: String, base64: String)
}
```

Extend `decode` to recognise `kind == "attachment"`:

```swift
        case "attachment":
            guard let requestId = dict["requestId"] as? String,
                  let filename = dict["filename"] as? String,
                  let mime = dict["mime"] as? String,
                  let base64 = dict["base64"] as? String else {
                throw EditorMessageDecodeError.invalidPayload
            }
            return .attachmentRequest(requestId: requestId, filename: filename, mime: mime, base64: base64)
```

Build + commit:
```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookApp/MarkdownHTMLBridge.swift
git commit -m "feat(app): MarkdownHTMLBridge handles attachment requests"
```

---

## Task 8: `AttachmentURLSchemeHandler`

**Files:** Create `Sources/AINotebookApp/AttachmentURLSchemeHandler.swift`.

Resolves `attachment://<note-uuid>/<filename>` to bytes on disk via
`AttachmentStore.read(noteUuid:filename:)`.

```swift
// Sources/AINotebookApp/AttachmentURLSchemeHandler.swift
import Foundation
import WebKit
import AINotebookCore

final class AttachmentURLSchemeHandler: NSObject, WKURLSchemeHandler {

    let attachments: AttachmentStore

    init(attachments: AttachmentStore) {
        self.attachments = attachments
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == "attachment",
              let host = url.host, !host.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        // path looks like "/filename.png"
        let filename = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !filename.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        do {
            let bytes = try attachments.read(noteUuid: host, filename: filename)
            let mime = Self.guessMime(forExtension: (filename as NSString).pathExtension)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mime,
                    "Content-Length": "\(bytes.count)"
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(bytes)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // no-op
    }

    private static func guessMime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "pdf":  return "application/pdf"
        case "txt":  return "text/plain"
        case "md":   return "text/markdown"
        default:     return "application/octet-stream"
        }
    }
}
```

Build + commit:
```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookApp/AttachmentURLSchemeHandler.swift
git commit -m "feat(app): AttachmentURLSchemeHandler — serve attachment:// from disk"
```

---

## Task 9: Wire scheme handler + reply to attachment requests in `NoteWYSIWYGEditor`

**Files:** Modify `Sources/AINotebookApp/NoteWYSIWYGEditor.swift`, `Sources/AINotebookApp/AINotebookApp.swift`.

The editor needs:
- the active Note's UUID (to namespace attachments)
- the shared `AttachmentStore`

- [ ] **Step 1: Inject `AttachmentStore` via env**

Create a holder:

```swift
// Append to Sources/AINotebookApp/AINotebookApp.swift (or new file)
@MainActor
final class AttachmentStoreHolder: ObservableObject {
    let store: AttachmentStore
    init(store: AttachmentStore) { self.store = store }
}
```

In `AINotebookAppEntry.init()`, construct + inject:

```swift
let attachments = AttachmentStore(
    store: store,
    root: (try? AttachmentStore.defaultRoot()) ?? FileManager.default.temporaryDirectory
)
_attachmentsHolder = StateObject(wrappedValue: AttachmentStoreHolder(store: attachments))
store.onNoteDeleted = { [attachments] uuid in
    try? attachments.deleteFolder(noteUuid: uuid)
}
```

Add the StateObject declaration alongside other holders + the `.environmentObject(attachmentsHolder)` in the scene body.

- [ ] **Step 2: Pass attachments + currentNote to `NoteWYSIWYGEditor`**

In `Sources/AINotebookApp/NoteWYSIWYGEditor.swift`, extend init:

```swift
let noteUuid: String
let attachments: AttachmentStore?
```

`EditorWebView` likewise. Coordinator gets both as fields.

In `EditorWebView.makeNSView`:

```swift
let config = WKWebViewConfiguration()
if let attachments = attachments {
    config.setURLSchemeHandler(
        AttachmentURLSchemeHandler(attachments: attachments),
        forURLScheme: "attachment"
    )
}
// ... rest unchanged
```

In the coordinator's `didReceive message:`, add the new case:

```swift
case .attachmentRequest(let requestId, let filename, let mime, let base64):
    guard let attachments = attachments,
          let bytes = Data(base64Encoded: base64) else {
        webView?.evaluateJavaScript(
            "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied('\(requestId)')",
            completionHandler: nil
        )
        return
    }
    do {
        let att = try attachments.save(
            noteId: noteId,
            noteUuid: noteUuid,
            filename: filename,
            mime: mime,
            bytes: bytes
        )
        let url = "attachment://\(noteUuid)/\(att.filename)"
        let js = "window.aino && window.aino.attachmentSaved && window.aino.attachmentSaved('\(requestId)', '\(url)', '\(mime)')"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    } catch {
        webView?.evaluateJavaScript(
            "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied('\(requestId)')",
            completionHandler: nil
        )
    }
```

Coordinator's stored fields:
```swift
var attachments: AttachmentStore?
var noteId: Int64 = 0
var noteUuid: String = ""
```

Set in `makeNSView`:
```swift
context.coordinator.attachments = attachments
context.coordinator.noteId = noteId
context.coordinator.noteUuid = noteUuid
```

- [ ] **Step 3: Wire from `NotesView`**

In `Sources/AINotebookApp/NotesView.swift`, pass through:

```swift
@EnvironmentObject private var attachmentsHolder: AttachmentStoreHolder

// in detail:
NoteWYSIWYGEditor(
    title: $draftTitle,
    bodyMd: $draftBody,
    language: settings.language,
    noteId: id,
    noteUuid: notes.first(where: { $0.id == id })?.noteUuid ?? "",
    attachments: attachmentsHolder.store,
    onSave: { _ in Task { @MainActor in await save(id: id) } }
)
```

- [ ] **Step 4: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NoteWYSIWYGEditor.swift Sources/AINotebookApp/AINotebookApp.swift Sources/AINotebookApp/NotesView.swift
git commit -m "feat(app): wire AttachmentStore + URL scheme handler into editor"
```

---

## Task 10: Update editor.ts — paste/drop handlers

**Files:** Modify `tools/editor/src/editor.ts`, rebuild bundle.

- [ ] **Step 1: Extend editor.ts**

Insert after the `editor` construction:

```ts
let pendingRequests = new Map<string, (url: string | null) => void>()

window.aino = {
  ...window.aino!,
  attachmentSaved(requestId: string, url: string, mime: string) {
    const cb = pendingRequests.get(requestId); pendingRequests.delete(requestId)
    if (cb) cb(url)
  },
  attachmentDenied(requestId: string) {
    const cb = pendingRequests.get(requestId); pendingRequests.delete(requestId)
    if (cb) cb(null)
  }
} as any

function uploadFile(file: File): Promise<string | null> {
  return new Promise(resolve => {
    const reader = new FileReader()
    reader.onerror = () => resolve(null)
    reader.onload = () => {
      const base64 = String(reader.result || "").split(",", 2)[1] || ""
      const requestId = Math.random().toString(36).slice(2)
      pendingRequests.set(requestId, resolve)
      postToSwift({
        kind: "attachment",
        requestId,
        filename: file.name || "attachment.bin",
        mime: file.type || "application/octet-stream",
        base64
      })
    }
    reader.readAsDataURL(file)
  })
}

async function insertFile(file: File) {
  const url = await uploadFile(file)
  if (!url) return
  if ((file.type || "").startsWith("image/")) {
    editor.chain().focus().setImage({ src: url, alt: file.name }).run()
  } else {
    editor.chain().focus().insertContent(
      `[${file.name}](${url})`
    ).run()
  }
}

mount.addEventListener("paste", (e) => {
  const items = (e as ClipboardEvent).clipboardData?.items
  if (!items) return
  for (let i = 0; i < items.length; i++) {
    const it = items[i]
    if (it.kind === "file") {
      const f = it.getAsFile()
      if (f) {
        e.preventDefault()
        insertFile(f)
      }
    }
  }
})

mount.addEventListener("drop", (e) => {
  const dt = (e as DragEvent).dataTransfer
  if (!dt || dt.files.length === 0) return
  e.preventDefault()
  for (let i = 0; i < dt.files.length; i++) {
    insertFile(dt.files[i])
  }
})

mount.addEventListener("dragover", (e) => {
  e.preventDefault()
})
```

The `postToSwift` function from the original file is reused.

Update the `window.aino` declaration to include the new methods (the existing declaration may need extending — quickest path is to assign on the existing object via `as any`).

- [ ] **Step 2: Rebuild bundle**

```bash
cd tools/editor
npm run build 2>&1 | tail -5
cd ../..
ls -lh Sources/AINotebookApp/Resources/editor/editor.js
```

- [ ] **Step 3: Commit**

```bash
git add tools/editor/src/editor.ts Sources/AINotebookApp/Resources/editor/editor.js
git commit -m "feat(editor): paste/drop file upload via Swift bridge"
```

---

## Task 11: Final verification + version + tag + merge

- [ ] **Step 1: Clean build + tests**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: ~186 tests pass (179 + MigrationV7(2) + AttachmentStore(4) + Localization(1)).

- [ ] **Step 2: Bump version + CHANGELOG**

```bash
echo "0.5.0" > VERSION
```

Edit `Sources/AINotebookCore/AINotebookVersion.swift` → `"0.5.0"`. Update `Tests/AINotebookCoreTests/AINotebookVersionTests.swift` assertion.

Prepend to `CHANGELOG.md`:

```markdown
## [0.5.0] — 2026-05-25

Attachments + inline images in the WYSIWYG editor.

### Added
- Drag/paste images and files into the editor; they're saved under
  `~/Library/Application Support/AINotebook/attachments/<note-uuid>/`.
- Inline image rendering via the new `attachment://` URL scheme handler.
- Non-image files insert as Markdown links.
- Cascade cleanup: deleting a Note removes both its DB rows and its
  attachments folder.

### Schema
- MigrationV7 adds the `attachments` table.

### Tests
- ~186 unit tests (was 179).
```

Commit:
```bash
git add VERSION CHANGELOG.md Sources/AINotebookCore/AINotebookVersion.swift Tests/AINotebookCoreTests/AINotebookVersionTests.swift
git commit -m "chore: bump version to 0.5.0 + CHANGELOG"
```

- [ ] **Step 3: Merge + tag**

```bash
git checkout main
git merge --ff-only m9-attachments
git tag -a v0.5.0 -m "v0.5.0 — attachments + inline images"
```

- [ ] **Step 4: Re-build DMG**

```bash
./tools/macos/build-app.sh
./tools/macos/build-dmg.sh
ls -lh dist/
```

---

## Acceptance criteria

- `swift test --parallel` ≥ 186 tests pass.
- `MigrationV7` adds `attachments` table with cascade-from-notes.
- `AttachmentStore.save` writes file + DB row, handles filename collisions.
- `AttachmentURLSchemeHandler` returns 200 + bytes for valid URLs.
- Dropping/pasting an image into the editor uploads + inserts as inline image.
- Deleting a Note also removes its on-disk attachment folder.
- Tag `v0.5.0` exists, `main` fast-forwarded.

---

## Notes for the implementer

- **WKWebView scheme handler isolation:** scheme handlers are
  configured per-`WKWebViewConfiguration` and CANNOT be changed after
  the WebView is created. Pattern: create the WebView per Note (we
  already do, since SwiftUI re-creates the `NSViewRepresentable` when
  `noteUuid` changes via the `EditorWebView` init params).
- **Large files:** base64 over the JS bridge is ~4/3× the byte size.
  For v1 we accept this; future work might switch to FormData uploads
  via a local server. Practical cap ~10 MB images.
- **MIME guessing:** intentionally minimal. WebKit usually falls back
  fine on `application/octet-stream` for download-type links.
- **Forward compat for M10:** versions snapshot the `bodyMd` text only.
  Attachments aren't versioned — they live independently and are
  referenced from the Markdown body.
