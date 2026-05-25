# M11: Transformations UX Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Transformations tab around the actual mental model — pick an AI template, run it on a source / notebook / all sources, see the result, jump to the saved Note. Adds descriptions, prompt preview, history sheet, batch apply, Czech-localized built-ins, and an "Open note" CTA after each run.

**Architecture:** Schema gets a `transformations.description` column (MigrationV9). `TransformationEngine` gains a `runOnAllSources(...)` batch overload. A new `TabSwitchCoordinator` observable lets the toast / history rows switch `NotebookDetailView.selectedTab` to `.notes` and publish the target note id through the existing `NoteJumpCoordinator`. `BuiltinTransformations` becomes language-aware (`seedIfNeeded(_:language:)`) and ships descriptions plus a fourth template "Action items". The view is renamed in the UI but keeps the `TransformationsView` Swift type for stability.

**Tech Stack:** Swift 6, SwiftUI, GRDB (existing), `TransformationEngine` from M6/M7.1, `NoteJumpCoordinator` from M7.2.

---

## File Structure

**Create:**
- `Sources/AINotebookCore/MigrationV9.swift` — add `transformations.description`
- `Sources/AINotebookApp/TabSwitchCoordinator.swift` — observable for tab + note jump
- `Sources/AINotebookApp/TransformationPromptPreviewSheet.swift` — renders the interpolated prompt
- `Sources/AINotebookApp/TransformationHistorySheet.swift` — lists runs with jump-to-note
- `Tests/AINotebookCoreTests/MigrationV9Tests.swift`
- `Tests/AINotebookCoreTests/BuiltinTransformationsLocalizedTests.swift`
- `Tests/AINotebookCoreTests/TransformationBatchTests.swift`
- `Tests/AINotebookCoreTests/TabSwitchCoordinatorTests.swift`

**Modify:**
- `Sources/AINotebookCore/NotebookStore.swift` — register V9; pass language to `BuiltinTransformations.seedIfNeeded`; expose `AppSettings` initial language to seed
- `Sources/AINotebookCore/Transformation.swift` — add `description: String`
- `Sources/AINotebookCore/NotebookStore+Transformations.swift` — extend `createTransformation` + `updateTransformation` with `description`
- `Sources/AINotebookCore/BuiltinTransformations.swift` — descriptions, "Action items", language-aware seed
- `Sources/AINotebookCore/Localization.swift` — ~12 new EN/CS keys
- `Sources/AINotebookCore/TransformationEngine.swift` — `runOnAllSources(transformationId:notebookId:)` batch overload
- `Sources/AINotebookApp/AINotebookApp.swift` — construct + inject `TabSwitchCoordinator`; pass language to `NotebookStore` init for seeding
- `Sources/AINotebookApp/NotebookDetailView.swift` — observe `TabSwitchCoordinator` and flip `selectedTab`
- `Sources/AINotebookApp/TransformationsView.swift` — full rewrite (rename label, description, scope picker with "All sources", prompt preview button, batch run, result toast with "Open note", History entry point)
- `Sources/AINotebookApp/TransformationEditorSheet.swift` — accept + edit description field
- `Tests/AINotebookCoreTests/LocalizationTests.swift` — bilingual smoke for one new key

---

## Task 1: Branch + baseline

```bash
git checkout main
git checkout -b m11-transformations-ux
swift test --parallel 2>&1 | tail -5
```

Expected: 193/193 pass.

---

## Task 2: MigrationV9 — `transformations.description`

**Files:** Create `Sources/AINotebookCore/MigrationV9.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV9Tests.swift`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV9Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV9Tests: XCTestCase {

    func testV9AddsDescriptionColumn() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let cols: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('transformations')")
            let names = cols.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("description"), "got: \(names)")
        }
    }

    func testExistingRowsGetEmptyStringDefault() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO transformations(name,prompt_template,scope,is_builtin) VALUES (?,?,?,?)",
                arguments: ["Plain", "x", "source", 0]
            )
            let desc: String? = try String.fetchOne(
                db,
                sql: "SELECT description FROM transformations WHERE name = ?",
                arguments: ["Plain"]
            )
            XCTAssertEqual(desc, "")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter MigrationV9Tests 2>&1 | tail -10
```

- [ ] **Step 3: Implement migration**

```swift
// Sources/AINotebookCore/MigrationV9.swift
import GRDB

public func registerMigrationV9(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v9_transformations_description") { db in
        try db.alter(table: "transformations") { t in
            t.add(column: "description", .text).notNull().defaults(to: "")
        }
    }
}
```

- [ ] **Step 4: Register V9**

In `Sources/AINotebookCore/NotebookStore.swift`, append after `registerMigrationV8(on: &migrator)`:

```swift
        registerMigrationV9(on: &migrator)
```

- [ ] **Step 5: Verify + commit**

```bash
swift test --filter MigrationV9Tests 2>&1 | tail -10
git add Sources/AINotebookCore/MigrationV9.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV9Tests.swift
git commit -m "feat(core): MigrationV9 — transformations.description column"
```

Expected: 2/2 pass.

---

## Task 3: Extend `Transformation` model + store APIs

**Files:** Modify `Sources/AINotebookCore/Transformation.swift`, `Sources/AINotebookCore/NotebookStore+Transformations.swift`.

- [ ] **Step 1: Add `description` to the struct**

In `Sources/AINotebookCore/Transformation.swift`:

1. Add stored property:
```swift
public var description: String
```
2. Update init (place AFTER `isBuiltin`, default `""`):
```swift
public init(
    id: Int64? = nil,
    name: String,
    promptTemplate: String,
    scope: TransformationScope = .source,
    isBuiltin: Bool = false,
    description: String = ""
) {
    self.id = id
    self.name = name
    self.promptTemplate = promptTemplate
    self.scope = scope
    self.isBuiltin = isBuiltin
    self.description = description
}
```
3. Add `Columns` case:
```swift
case description
```

- [ ] **Step 2: Extend store CRUD**

In `Sources/AINotebookCore/NotebookStore+Transformations.swift`:

Change `createTransformation` signature to accept description:

```swift
@discardableResult
public func createTransformation(
    name: String,
    promptTemplate: String,
    scope: TransformationScope,
    isBuiltin: Bool = false,
    description: String = ""
) throws -> Transformation {
    var t = Transformation(
        name: name,
        promptTemplate: promptTemplate,
        scope: scope,
        isBuiltin: isBuiltin,
        description: description
    )
    try runOnDatabase { db in
        try t.insert(db)
    }
    return t
}
```

Change `updateTransformation` to also accept description:

```swift
public func updateTransformation(
    id: Int64,
    name: String,
    promptTemplate: String,
    description: String = ""
) throws {
    try runOnDatabase { db in
        guard var t = try Transformation.fetchOne(db, key: id) else { return }
        t.name = name
        t.promptTemplate = promptTemplate
        t.description = description
        try t.update(db)
    }
}
```

Existing callers that pass 3 args (`id`, `name`, `promptTemplate`) keep
working via the default; the editor sheet (Task 8) will pass the new
4th arg.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookCore/Transformation.swift Sources/AINotebookCore/NotebookStore+Transformations.swift
git commit -m "feat(core): Transformation.description + store CRUD"
```

---

## Task 4: Locale-aware `BuiltinTransformations` + "Action items"

**Files:** Modify `Sources/AINotebookCore/BuiltinTransformations.swift`, `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/BuiltinTransformationsLocalizedTests.swift`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/BuiltinTransformationsLocalizedTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class BuiltinTransformationsLocalizedTests: XCTestCase {

    func testEnglishSeedNames() throws {
        let store = try NotebookStore(path: .inMemory, language: .english)
        let names = Set(try store.transformations().filter(\.isBuiltin).map(\.name))
        XCTAssertEqual(names, ["Summary", "Key points", "Entities", "Action items"])
    }

    func testCzechSeedNames() throws {
        let store = try NotebookStore(path: .inMemory, language: .czech)
        let names = Set(try store.transformations().filter(\.isBuiltin).map(\.name))
        XCTAssertEqual(names, ["Souhrn", "Klíčové body", "Entity", "Úkoly"])
    }

    func testBuiltinsHaveDescriptions() throws {
        let store = try NotebookStore(path: .inMemory, language: .english)
        for t in try store.transformations().filter(\.isBuiltin) {
            XCTAssertFalse(t.description.isEmpty, "\(t.name) missing description")
        }
    }

    func testReseedSkipsExistingBuiltins() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-builtin-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try NotebookStore(path: StorePath(fileURL: url), language: .english)
        }
        do {
            let s2 = try NotebookStore(path: StorePath(fileURL: url), language: .english)
            let builtins = try s2.transformations().filter(\.isBuiltin)
            XCTAssertEqual(builtins.count, 4, "should not re-seed")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter BuiltinTransformationsLocalizedTests 2>&1 | tail -10
```

- [ ] **Step 3: Rewrite `BuiltinTransformations`**

Replace `Sources/AINotebookCore/BuiltinTransformations.swift`:

```swift
import Foundation
import GRDB

enum BuiltinTransformations {

    struct Spec {
        let name: String
        let description: String
        let prompt: String
    }

    static let english: [Spec] = [
        Spec(
            name: "Summary",
            description: "3–5 bullet summary of a source.",
            prompt: """
            Summarize the following source text in 3-5 short bullet points. Keep
            names, numbers, and dates exact. Output Markdown bullets only — no
            preamble.

            SOURCE TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Key points",
            description: "5–10 most important takeaways.",
            prompt: """
            Extract the 5-10 most important key points from the following source
            text. Output as a Markdown numbered list. Each item should be one
            sentence, concrete, and self-contained.

            SOURCE TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Entities",
            description: "People, organizations, places, dates.",
            prompt: """
            Extract people, organizations, places, and dates from the following
            source text. Output as Markdown sections (## People, ## Organizations,
            ## Places, ## Dates) with bullet points under each. Include only
            entities literally present in the text.

            SOURCE TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Action items",
            description: "Concrete next-step actions found in the text.",
            prompt: """
            List every action item or next-step task mentioned in the following
            source text. Output as a Markdown checklist (- [ ]). One item per
            line. Include only actions literally present in the text.

            SOURCE TEXT:
            {{source_text}}
            """
        )
    ]

    static let czech: [Spec] = [
        Spec(
            name: "Souhrn",
            description: "Shrnutí zdroje do 3–5 odrážek.",
            prompt: """
            Shrň následující zdrojový text do 3–5 krátkých odrážek. Zachovej přesně
            jména, čísla a data. Výstup pouze jako odrážky v Markdownu — bez úvodu.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Klíčové body",
            description: "5–10 nejdůležitějších bodů.",
            prompt: """
            Extrahuj 5–10 nejdůležitějších klíčových bodů z následujícího zdrojového
            textu. Výstup jako Markdown číslovaný seznam. Každý bod jednou větou,
            konkrétně a sám o sobě srozumitelný.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Entity",
            description: "Lidé, organizace, místa, data.",
            prompt: """
            Extrahuj osoby, organizace, místa a data z následujícího zdrojového textu.
            Výstup jako Markdown sekce (## Osoby, ## Organizace, ## Místa, ## Data)
            s odrážkami pod každou. Zahrň pouze entity doslova přítomné v textu.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Úkoly",
            description: "Konkrétní úkoly nebo akce zmíněné v textu.",
            prompt: """
            Vypiš všechny úkoly nebo další kroky uvedené v následujícím zdrojovém
            textu. Výstup jako Markdown checklist (- [ ]). Jeden úkol na řádek.
            Zahrň pouze úkoly doslova přítomné v textu.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        )
    ]

    static func seedIfNeeded(_ db: Database, language: AppLanguage) throws {
        let specs = (language == .czech) ? czech : english
        for s in specs {
            let exists: Bool = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM transformations WHERE name = ? AND is_builtin = 1",
                arguments: [s.name]
            ) ?? false
            if !exists {
                var copy = Transformation(
                    name: s.name,
                    promptTemplate: s.prompt,
                    scope: .source,
                    isBuiltin: true,
                    description: s.description
                )
                try copy.insert(db)
            } else {
                // Back-fill description if it was empty (pre-M11 row).
                try db.execute(
                    sql: """
                    UPDATE transformations
                       SET description = ?
                     WHERE name = ? AND is_builtin = 1 AND (description IS NULL OR description = '')
                    """,
                    arguments: [s.description, s.name]
                )
            }
        }
    }
}
```

- [ ] **Step 4: Extend `NotebookStore.init` with `language:`**

In `Sources/AINotebookCore/NotebookStore.swift`, update the initializer:

```swift
public init(path: StorePath, language: AppLanguage = .english) throws {
    if let url = path.fileURL {
        self.dbQueue = try DatabaseQueue(path: url.path)
    } else {
        self.dbQueue = try DatabaseQueue()
    }
    var migrator = DatabaseMigrator()
    registerMigrationV1(on: &migrator)
    registerMigrationV2(on: &migrator)
    registerMigrationV3(on: &migrator)
    registerMigrationV4(on: &migrator)
    registerMigrationV5(on: &migrator)
    registerMigrationV6(on: &migrator)
    registerMigrationV7(on: &migrator)
    registerMigrationV8(on: &migrator)
    registerMigrationV9(on: &migrator)
    try migrator.migrate(dbQueue)
    try dbQueue.write { db in
        try BuiltinTransformations.seedIfNeeded(db, language: language)
    }
    try refresh()
}
```

Old call sites (`NotebookStore(path: .inMemory)`) keep working — the
default is English.

- [ ] **Step 5: Verify + commit**

```bash
swift test --filter BuiltinTransformationsLocalizedTests 2>&1 | tail -10
swift test --parallel 2>&1 | tail -5
git add Sources/AINotebookCore/BuiltinTransformations.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/BuiltinTransformationsLocalizedTests.swift
git commit -m "feat(core): localized built-in transformations + Action items + description seed"
```

Expected: 4/4 new tests pass; previous test count holds (existing
`BuiltinTransformationsTests` and `NotebookStoreTransformationsTests`
still expect the 3 English names — fix in next step).

- [ ] **Step 6: Update pre-M11 tests that count built-ins**

The existing `BuiltinTransformationsTests` (M6) asserts the exact set
of three English names. Update its assertions to the new four-name
set:

In `Tests/AINotebookCoreTests/BuiltinTransformationsTests.swift`:

```swift
    func testFreshDatabaseGetsBuiltinsSeeded() throws {
        let store = try NotebookStore(path: .inMemory)
        let all = try store.transformations()
        let builtinNames = Set(all.filter(\.isBuiltin).map(\.name))
        XCTAssertEqual(builtinNames, ["Summary", "Key points", "Entities", "Action items"])
    }

    func testReopeningDatabaseDoesNotDuplicateBuiltins() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try NotebookStore(path: StorePath(fileURL: url)) }
        do {
            let store2 = try NotebookStore(path: StorePath(fileURL: url))
            let builtins = try store2.transformations().filter(\.isBuiltin)
            XCTAssertEqual(builtins.count, 4)
        }
    }
```

Run:

```bash
swift test --parallel 2>&1 | tail -5
git add Tests/AINotebookCoreTests/BuiltinTransformationsTests.swift
git commit -m "test(core): update built-in count to 4 with Action items"
```

---

## Task 5: `TransformationEngine.runOnAllSources(...)`

**Files:** Modify `Sources/AINotebookCore/TransformationEngine.swift`, test `Tests/AINotebookCoreTests/TransformationBatchTests.swift`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/TransformationBatchTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationBatchTests: XCTestCase {

    final class MockChat: ChatStreaming, @unchecked Sendable {
        var calls = 0
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            calls += 1
            return AsyncThrowingStream { c in
                Task { c.yield("ok\(self.calls)"); c.finish() }
            }
        }
    }

    func testRunsTemplateOnEverySourceProducingOneNoteEach() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createSource(notebookId: nb.id!, type: .text, title: "A", uri: nil, rawPath: nil)
        let s2 = try store.createSource(notebookId: nb.id!, type: .text, title: "B", uri: nil, rawPath: nil)
        let s3 = try store.createSource(notebookId: nb.id!, type: .text, title: "C", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: s1.id!, chunks: [ChunkDraft(text: "a", tokenCount: 1)])
        try store.replaceChunks(sourceId: s2.id!, chunks: [ChunkDraft(text: "b", tokenCount: 1)])
        try store.replaceChunks(sourceId: s3.id!, chunks: [ChunkDraft(text: "c", tokenCount: 1)])
        let t = try store.createTransformation(
            name: "Sum", promptTemplate: "X:\n{{source_text}}", scope: .source, isBuiltin: false
        )
        let chat = MockChat()
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")

        let notes = try await engine.runOnAllSources(
            transformationId: t.id!, notebookId: nb.id!
        ) { _, _ in }

        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(chat.calls, 3)
        let allNotes = try store.notes(notebookId: nb.id!)
        XCTAssertEqual(allNotes.filter { $0.origin == .transformation }.count, 3)
    }

    func testEmptyNotebookReturnsEmptyArray() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let t = try store.createTransformation(
            name: "Sum", promptTemplate: "{{source_text}}", scope: .source, isBuiltin: false
        )
        let chat = MockChat()
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")
        let notes = try await engine.runOnAllSources(
            transformationId: t.id!, notebookId: nb.id!
        ) { _, _ in }
        XCTAssertEqual(notes.count, 0)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter TransformationBatchTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement batch method**

Append to `Sources/AINotebookCore/TransformationEngine.swift` inside
the actor body:

```swift
    /// Fan a source-scope template across every source in the notebook.
    /// Reports `(completed, total)` via the optional progress callback.
    /// Returns the resulting Notes in source-order.
    @discardableResult
    public func runOnAllSources(
        transformationId: Int64,
        notebookId: Int64,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [Note] {
        let storeRef = store
        let sources: [Source] = try await MainActor.run {
            try storeRef.sources(notebookId: notebookId)
        }
        let total = sources.count
        var results: [Note] = []
        for (idx, s) in sources.enumerated() {
            let note = try await run(transformationId: transformationId, sourceId: s.id!)
            results.append(note)
            onProgress(idx + 1, total)
        }
        return results
    }
```

(Uses the existing `run(transformationId:sourceId:)` per source — that
method already streams + persists each result.)

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter TransformationBatchTests 2>&1 | tail -10
git add Sources/AINotebookCore/TransformationEngine.swift Tests/AINotebookCoreTests/TransformationBatchTests.swift
git commit -m "feat(core): TransformationEngine.runOnAllSources batch"
```

Expected: 2/2 pass.

---

## Task 6: 12 EN/CS localization keys

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, modify `Tests/AINotebookCoreTests/LocalizationTests.swift`.

- [ ] **Step 1: Add keys**

| key | EN | CS |
|---|---|---|
| `aiToolsSectionTitle` | "AI tools" | "AI nástroje" |
| `aiToolsEmptyTitle` | "What are AI tools?" | "Co jsou AI nástroje?" |
| `aiToolsEmptyBody` | "Pick a template, pick a source, click Run. The output is saved as a new note in this notebook." | "Vyber šablonu, vyber zdroj, klikni Spustit. Výstup se uloží jako nová poznámka v tomto notebooku." |
| `aiToolsScopeAllSources` | "All sources" | "Všechny zdroje" |
| `aiToolsScopeHint` | "Source = one item · Notebook = combined · All sources = one note per source" | "Zdroj = jedna položka · Notebook = vše dohromady · Všechny zdroje = poznámka na každý zdroj" |
| `aiToolsPreviewButton` | "Preview prompt" | "Náhled promptu" |
| `aiToolsHistoryButton` | "History" | "Historie" |
| `aiToolsResultSavedFormat` | "Saved as note: %@" | "Uloženo jako poznámka: %@" |
| `aiToolsOpenNoteButton` | "Open note" | "Otevřít poznámku" |
| `aiToolsRunningFormat` | "Running %d / %d…" | "Probíhá %d / %d…" |
| `aiToolsBatchSavedFormat` | "Saved %d notes" | "Uloženo %d poznámek" |
| `aiToolsPromptPreviewTitle` | "Prompt preview" | "Náhled promptu" |
| `aiToolsHistoryEmpty` | "No runs yet." | "Zatím žádné spuštění." |
| `aiToolsHistoryTitle` | "Run history" | "Historie spuštění" |
| `aiToolsDescriptionPlaceholder` | "Short description (shown under the template name)" | "Krátký popis (zobrazí se pod názvem šablony)" |

(15 keys total — bumps the prior 12 estimate; spec stays accurate.)

Wire each through `AppText.Key` + EN dict + CS dict.

- [ ] **Step 2: Bilingual smoke test**

Append to `Tests/AINotebookCoreTests/LocalizationTests.swift`:

```swift
    func testAiToolsSectionTitleBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.aiToolsSectionTitle), "AI tools")
        XCTAssertEqual(AppText(language: .czech)  .string(.aiToolsSectionTitle), "AI nástroje")
    }
```

- [ ] **Step 3: Build + test + commit**

```bash
swift test --filter LocalizationTests 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): 15 EN/CS AI-tools localization keys"
```

---

## Task 7: `TabSwitchCoordinator` + wire

**Files:** Create `Sources/AINotebookApp/TabSwitchCoordinator.swift`, modify `Sources/AINotebookApp/AINotebookApp.swift`, modify `Sources/AINotebookApp/NotebookDetailView.swift`, test `Tests/AINotebookCoreTests/TabSwitchCoordinatorTests.swift`.

- [ ] **Step 1: Failing test**

```swift
// Tests/AINotebookCoreTests/TabSwitchCoordinatorTests.swift
import XCTest
@testable import AINotebookApp

@MainActor
final class TabSwitchCoordinatorTests: XCTestCase {

    func testRequestSetsTarget() {
        let c = TabSwitchCoordinator()
        XCTAssertNil(c.target)
        c.request(.notes)
        XCTAssertEqual(c.target, .notes)
    }

    func testClearResetsTarget() {
        let c = TabSwitchCoordinator()
        c.request(.notes)
        c.clear()
        XCTAssertNil(c.target)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter TabSwitchCoordinatorTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookApp/TabSwitchCoordinator.swift
import SwiftUI
import Combine

@MainActor
final class TabSwitchCoordinator: ObservableObject {
    /// Mirrors `NotebookDetailView.Tab`. Re-declared here to avoid
    /// importing NotebookDetailView into Core tests.
    public enum Tab: Hashable, Sendable {
        case sources, chat, notes, transformations
    }

    @Published public var target: Tab?

    public init() {}

    public func request(_ tab: Tab) { target = tab }
    public func clear() { target = nil }
}
```

- [ ] **Step 4: Inject in app entry**

In `Sources/AINotebookApp/AINotebookApp.swift`:

1. Add field next to other `@StateObject`s:
```swift
@StateObject private var tabSwitch = TabSwitchCoordinator()
```
2. Inject in scene body alongside `noteJump`:
```swift
.environmentObject(tabSwitch)
```

- [ ] **Step 5: Observe in `NotebookDetailView`**

In `Sources/AINotebookApp/NotebookDetailView.swift`:

1. Add env object:
```swift
@EnvironmentObject private var tabSwitch: TabSwitchCoordinator
```
2. Map the coordinator's target enum to the existing local Tab enum:
```swift
private func mapTab(_ t: TabSwitchCoordinator.Tab) -> Tab {
    switch t {
    case .sources:         return .sources
    case .chat:            return .chat
    case .notes:           return .notes
    case .transformations: return .transformations
    }
}
```
3. Observe and update `selectedTab` (add modifier to the `Group { switch … }` at the bottom of the body, OR to the root `VStack`):
```swift
.onReceive(tabSwitch.$target.compactMap { $0 }) { t in
    selectedTab = mapTab(t)
    tabSwitch.clear()
}
```

- [ ] **Step 6: Verify + commit**

```bash
swift test --filter TabSwitchCoordinatorTests 2>&1 | tail -10
swift build 2>&1 | tail -5
git add Sources/AINotebookApp/TabSwitchCoordinator.swift Sources/AINotebookApp/AINotebookApp.swift Sources/AINotebookApp/NotebookDetailView.swift Tests/AINotebookCoreTests/TabSwitchCoordinatorTests.swift
git commit -m "feat(app): TabSwitchCoordinator + NotebookDetailView wiring"
```

Expected: 2/2 pass.

---

## Task 8: `TransformationEditorSheet` accepts description

**Files:** Modify `Sources/AINotebookApp/TransformationEditorSheet.swift`.

- [ ] **Step 1: Add description draft**

In the editor sheet, add:

```swift
@State private var draftDescription: String = ""
```

After the name TextField in `editor`, add:

```swift
TextField(t.string(.aiToolsDescriptionPlaceholder), text: $draftDescription)
    .textFieldStyle(.roundedBorder)
```

In the `reload` and `onChange(of: selection)` handlers, set
`draftDescription = tx.description`.

In `save()`, call `updateTransformation` with the new 4th arg:

```swift
try store.updateTransformation(
    id: id,
    name: draftName,
    promptTemplate: draftTemplate,
    description: draftDescription
)
try store.updateTransformationScope(id: id, scope: draftScope)
```

In `createBlank()`, supply an empty description (already the default).

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookApp/TransformationEditorSheet.swift
git commit -m "feat(app): TransformationEditorSheet edits description"
```

---

## Task 9: `TransformationPromptPreviewSheet`

**Files:** Create `Sources/AINotebookApp/TransformationPromptPreviewSheet.swift`.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/TransformationPromptPreviewSheet.swift
import SwiftUI
import AINotebookCore

struct TransformationPromptPreviewSheet: View {

    let transformation: Transformation
    let source: Source?
    @Binding var isPresented: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @State private var rendered: String = ""
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.aiToolsPromptPreviewTitle)).font(.title2).bold()
            Text(transformation.name).font(.headline)
            if !transformation.description.isEmpty {
                Text(transformation.description)
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(rendered.isEmpty ? transformation.promptTemplate : rendered)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 360)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .task { await render() }
    }

    @MainActor
    private func render() async {
        guard let source = source else {
            rendered = transformation.promptTemplate
            return
        }
        do {
            let chunks = try store.chunks(sourceId: source.id!)
            let sourceText = chunks.map(\.text).joined(separator: "\n\n")
            rendered = transformation.promptTemplate
                .replacingOccurrences(of: "{{source_text}}", with: sourceText)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookApp/TransformationPromptPreviewSheet.swift
git commit -m "feat(app): TransformationPromptPreviewSheet"
```

---

## Task 10: `TransformationHistorySheet`

**Files:** Create `Sources/AINotebookApp/TransformationHistorySheet.swift`.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/TransformationHistorySheet.swift
import SwiftUI
import AINotebookCore

struct TransformationHistorySheet: View {

    let notebook: Notebook
    @Binding var isPresented: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var noteJump: NoteJumpCoordinator
    @EnvironmentObject private var tabSwitch: TabSwitchCoordinator

    @State private var rows: [Row] = []
    @State private var errorMessage: String?

    struct Row: Identifiable, Hashable {
        let id: Int64
        let templateName: String
        let sourceTitle: String
        let noteId: Int64?
        let noteTitle: String
        let ranAt: Date
    }

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.aiToolsHistoryTitle)).font(.title2).bold()
            if rows.isEmpty {
                VStack {
                    Spacer()
                    Text(t.string(.aiToolsHistoryEmpty)).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                List {
                    ForEach(rows) { r in
                        Button {
                            jump(to: r)
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.templateName).font(.headline)
                                    Text(r.sourceTitle).font(.callout).foregroundStyle(.secondary)
                                    Text(r.ranAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if r.noteId == nil {
                                    Text("(deleted)").font(.caption).foregroundStyle(.red)
                                } else {
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(r.noteId == nil)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 360)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .task(id: notebook.id) { await reload() }
    }

    @MainActor
    private func reload() async {
        do {
            let runs = try store.transformationRuns()
            let transformations = try store.transformations()
            let txByID = Dictionary(uniqueKeysWithValues: transformations.compactMap { tx -> (Int64, Transformation)? in
                tx.id.map { ($0, tx) }
            })
            let notes = try store.notes(notebookId: notebook.id!)
            let notesByID = Dictionary(uniqueKeysWithValues: notes.compactMap { n -> (Int64, Note)? in
                n.id.map { ($0, n) }
            })
            let sources = try store.sourcesIncludingShadow(notebookId: notebook.id!)
            let sourcesByID = Dictionary(uniqueKeysWithValues: sources.compactMap { s -> (Int64, Source)? in
                s.id.map { ($0, s) }
            })

            rows = runs.compactMap { run in
                guard let runId = run.id else { return nil }
                // Filter by notebook via the result note OR the source.
                let note: Note? = run.resultNoteId.flatMap { notesByID[$0] }
                let source: Source? = run.sourceId.flatMap { sourcesByID[$0] }
                let belongsToNotebook = (note?.notebookId == notebook.id) ||
                    (source?.notebookId == notebook.id)
                guard belongsToNotebook else { return nil }
                let txName = run.transformationId.flatMap { txByID[$0]?.name }
                    ?? "(unknown)"
                let srcTitle = source?.title
                    ?? (run.sourceId == nil ? "(notebook scope)" : "(deleted)")
                return Row(
                    id: runId,
                    templateName: txName,
                    sourceTitle: srcTitle,
                    noteId: note?.id,
                    noteTitle: note?.title ?? "(deleted)",
                    ranAt: run.ranAt
                )
            }
            .sorted { $0.ranAt > $1.ranAt }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func jump(to row: Row) {
        guard let nid = row.noteId else { return }
        isPresented = false
        tabSwitch.request(.notes)
        // small delay lets the tab switch happen before the note jump
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            noteJump.request(noteId: nid)
        }
    }
}
```

Note: this view assumes `Transformation.id`, `TransformationRun.id`,
etc. are accessible. The closure-keyed dictionaries swallow nil ids
(none in practice but Swift requires the cast).

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/TransformationHistorySheet.swift
git commit -m "feat(app): TransformationHistorySheet — jump back to saved notes"
```

---

## Task 11: Rewrite `TransformationsView`

**Files:** Modify `Sources/AINotebookApp/TransformationsView.swift`.

Full replacement that ties everything together: rename label, show
description, scope picker with "All sources", prompt preview button,
batch run with progress, result toast with "Open note", History entry
point.

- [ ] **Step 1: Replace file contents**

```swift
// Sources/AINotebookApp/TransformationsView.swift
import SwiftUI
import AINotebookCore

struct TransformationsView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var transformationHolder: TransformationEngineHolder
    @EnvironmentObject private var noteJump: NoteJumpCoordinator
    @EnvironmentObject private var tabSwitch: TabSwitchCoordinator

    enum BatchScope: Hashable {
        case source, notebook, allSources
    }

    @State private var transformations: [Transformation] = []
    @State private var sources: [Source] = []
    @State private var selectedTransformationId: Int64?
    @State private var selectedSourceId: Int64?
    @State private var scope: BatchScope = .source
    @State private var resultBody: String = ""
    @State private var resultNoteId: Int64?
    @State private var batchCompleted: Int = 0
    @State private var batchTotal: Int = 0
    @State private var batchSavedCount: Int? = nil
    @State private var running = false
    @State private var errorMessage: String?
    @State private var showingEditor = false
    @State private var showingPreview = false
    @State private var showingHistory = false

    private var t: AppText { settings.text }

    private var selectedTransformation: Transformation? {
        guard let id = selectedTransformationId else { return nil }
        return transformations.first(where: { $0.id == id })
    }

    private var selectedSource: Source? {
        guard let id = selectedSourceId else { return nil }
        return sources.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            templateRow
            scopeRow
            Divider()
            content
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .task(id: notebook.id) { await reload() }
        .sheet(isPresented: $showingEditor, onDismiss: { Task { await reload() } }) {
            TransformationEditorSheet(isPresented: $showingEditor, onChange: { Task { await reload() } })
        }
        .sheet(isPresented: $showingPreview) {
            if let tx = selectedTransformation {
                TransformationPromptPreviewSheet(
                    transformation: tx,
                    source: scope == .source ? selectedSource : nil,
                    isPresented: $showingPreview
                )
            }
        }
        .sheet(isPresented: $showingHistory) {
            TransformationHistorySheet(notebook: notebook, isPresented: $showingHistory)
        }
    }

    private var header: some View {
        HStack {
            Text(t.string(.aiToolsSectionTitle)).font(.title2).bold()
            Spacer()
            Button(t.string(.aiToolsHistoryButton)) { showingHistory = true }
            Button(t.string(.transformationEditButton)) { showingEditor = true }
        }
    }

    private var templateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t.string(.transformationPickerLabel)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingPreview = true
                } label: {
                    Label(t.string(.aiToolsPreviewButton), systemImage: "eye")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(selectedTransformation == nil)
            }
            Picker("", selection: $selectedTransformationId) {
                ForEach(transformations) { tx in
                    Text(tx.name).tag(tx.id as Int64?)
                }
            }
            .labelsHidden()
            if let tx = selectedTransformation, !tx.description.isEmpty {
                Text(tx.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedTransformationId) { _, _ in
            if let tx = selectedTransformation {
                scope = (tx.scope == .notebook) ? .notebook : .source
            }
        }
    }

    private var scopeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $scope) {
                Text("Source").tag(BatchScope.source)
                Text("Notebook").tag(BatchScope.notebook)
                Text(t.string(.aiToolsScopeAllSources)).tag(BatchScope.allSources)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text(t.string(.aiToolsScopeHint))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack {
                if scope == .source {
                    Picker(t.string(.transformationSourcePickerLabel), selection: $selectedSourceId) {
                        ForEach(sources) { s in
                            Text(s.title).tag(s.id as Int64?)
                        }
                    }
                    .frame(maxWidth: 360)
                }
                Spacer()
                Button(t.string(.transformationRunButton)) {
                    Task { await run() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(running
                          || selectedTransformationId == nil
                          || (scope == .source && selectedSourceId == nil)
                          || (scope == .allSources && sources.isEmpty))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if running {
            if batchTotal > 0 {
                ProgressView(
                    String(format: t.string(.aiToolsRunningFormat), batchCompleted, batchTotal),
                    value: Double(batchCompleted),
                    total: Double(batchTotal)
                )
            } else {
                ProgressView(t.string(.transformationRunningStatus))
            }
            if !resultBody.isEmpty {
                ScrollView {
                    Text(resultBody)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            }
        } else if let savedCount = batchSavedCount, savedCount > 1 {
            batchSavedToast(count: savedCount)
        } else if let nid = resultNoteId {
            singleSavedSection(noteId: nid)
        } else {
            emptyExplainer
        }
    }

    private var emptyExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.string(.aiToolsEmptyTitle)).font(.headline)
                    Text(t.string(.aiToolsEmptyBody))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func singleSavedSection(noteId: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let title = (try? store.note(id: noteId))?.title ?? ""
                Text(String(format: t.string(.aiToolsResultSavedFormat), title))
                    .font(.callout)
                Spacer()
                Button(t.string(.aiToolsOpenNoteButton)) {
                    tabSwitch.request(.notes)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        noteJump.request(noteId: noteId)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Text(t.string(.transformationResultTitle)).font(.headline)
            ScrollView {
                Text(resultBody)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func batchSavedToast(count: Int) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(String(format: t.string(.aiToolsBatchSavedFormat), count))
                .font(.headline)
            Spacer()
            Button(t.string(.aiToolsOpenNoteButton)) {
                tabSwitch.request(.notes)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @MainActor
    private func reload() async {
        do {
            transformations = try store.transformations()
            sources = try store.sources(notebookId: notebook.id!)
            if selectedTransformationId == nil { selectedTransformationId = transformations.first?.id }
            if selectedSourceId == nil          { selectedSourceId         = sources.first?.id }
            if let tx = selectedTransformation, tx.scope == .notebook { scope = .notebook }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func run() async {
        guard let tid = selectedTransformationId else { return }
        running = true; errorMessage = nil
        resultBody = ""; resultNoteId = nil
        batchSavedCount = nil; batchCompleted = 0; batchTotal = 0
        defer { running = false }

        do {
            switch scope {
            case .source:
                guard let sid = selectedSourceId else { return }
                let note = try await transformationHolder.engine.run(
                    transformationId: tid, sourceId: sid
                ) { token in
                    Task { @MainActor in resultBody += token }
                }
                resultNoteId = note.id
            case .notebook:
                let note = try await transformationHolder.engine.runNotebookScope(
                    transformationId: tid, notebookId: notebook.id!
                ) { token in
                    Task { @MainActor in resultBody += token }
                }
                resultNoteId = note.id
            case .allSources:
                batchTotal = sources.count
                let notes = try await transformationHolder.engine.runOnAllSources(
                    transformationId: tid, notebookId: notebook.id!
                ) { done, total in
                    Task { @MainActor in
                        batchCompleted = done
                        batchTotal = total
                    }
                }
                batchSavedCount = notes.count
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/TransformationsView.swift
git commit -m "feat(app): TransformationsView rewrite — AI tools, batch, preview, history, Open note"
```

---

## Task 12: Final verification + version + tag + merge

- [ ] **Step 1: Clean build + tests**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: ≥ 203 tests pass (193 + MigrationV9(2) + BuiltinLocalized(4) + Batch(2) + TabSwitch(2) + Localization(1)).

- [ ] **Step 2: Smoke**

```bash
swift run AINotebookApp
```

With Ollama running:
- Open a notebook with at least one source.
- Switch to AI tools tab (renamed from "Transformations").
- See empty explainer.
- Pick "Summary", description appears under name.
- Click eye → prompt preview opens with interpolated text.
- Click Run → streamed result + "Saved as note: Summary — X" + [Open note].
- Click "Open note" → jumps to Notes tab + selects the new note.
- Switch back to AI tools → click History → list of runs → click row → jumps back.
- Pick scope "All sources" with 2+ sources → Run → progress bar → "Saved 2 notes" → [Open note] switches to Notes tab.

- [ ] **Step 3: Bump version + CHANGELOG**

```bash
echo "0.7.0" > VERSION
```

Edit `Sources/AINotebookCore/AINotebookVersion.swift` → `"0.7.0"`. Update `Tests/AINotebookCoreTests/AINotebookVersionTests.swift` assertion to `"0.7.0"`.

Prepend to `CHANGELOG.md`:

```markdown
## [0.7.0] — 2026-05-25

Transformations tab rebuilt as "AI tools" — more intuitive, with
descriptions, prompt preview, history, batch apply, and explicit
"Open note" CTAs.

### Added
- Built-in template `Action items` (Markdown checklist of next-step
  actions found in the source).
- Locale-aware built-in seeding: Czech notebooks ship with
  `Souhrn / Klíčové body / Entity / Úkoly` named built-ins.
- `transformations.description` column populated for built-ins and
  editable for custom templates.
- Prompt preview sheet (eye icon) renders the actual prompt with
  source text interpolated.
- History sheet lists past runs and jumps back to the saved note.
- "All sources" scope batches a source-template across every source,
  with progress reporting and a "Saved N notes" summary.
- `TabSwitchCoordinator` lets in-app actions switch tabs + jump.

### Changed
- UI label "Transformace" / "Transformations" renamed to "AI nástroje"
  / "AI tools".
- After each run, a green "Saved as note: …" badge with an "Open
  note" button replaces the prior silent save.

### Schema
- MigrationV9 adds `transformations.description` (default `''`).

### Tests
- ≥ 203 unit tests (was 193).
```

Commit:
```bash
git add VERSION CHANGELOG.md Sources/AINotebookCore/AINotebookVersion.swift Tests/AINotebookCoreTests/AINotebookVersionTests.swift
git commit -m "chore: bump version to 0.7.0 + CHANGELOG"
```

- [ ] **Step 4: Merge + tag**

```bash
git checkout main
git merge --ff-only m11-transformations-ux
git tag -a v0.7.0 -m "v0.7.0 — AI tools UX overhaul"
git log --oneline | head -12
```

- [ ] **Step 5: Re-build DMG**

```bash
./tools/macos/build-app.sh
./tools/macos/build-dmg.sh
ls -lh dist/
```

---

## Acceptance criteria

- `swift test --parallel` ≥ 203 tests pass.
- Tab label reads "AI nástroje" (CS) / "AI tools" (EN).
- 4 built-ins exist with non-empty descriptions in both locales.
- `runOnAllSources` produces N notes for N sources.
- Empty state explains what AI tools do.
- Prompt preview shows rendered template.
- History sheet jumps back to a saved note via TabSwitchCoordinator + NoteJumpCoordinator.
- "Open note" after a single run lands on the new note in the Notes tab.
- Tag `v0.7.0` exists, `main` fast-forwarded.

---

## Notes for the implementer

- **Migration order:** V9 must come AFTER V5 (which originally
  creates the `transformations` table). The append in Task 2 places
  V9 after V8 — fine because all V*-after-V5 only add unrelated
  tables/columns.
- **Backfill safety:** Built-ins created BEFORE M11 (existing v0.6.0
  databases) have empty descriptions. `BuiltinTransformations.seedIfNeeded`
  back-fills them via the `UPDATE … WHERE description IS NULL OR ''`
  branch — idempotent.
- **TabSwitch timing:** The 50 ms `Task.sleep` between
  `tabSwitch.request(.notes)` and `noteJump.request(noteId:)` exists
  so the NotesView has time to mount and `notes` is populated before
  the jump arrives. Without it, the jump can land before `reload()`
  finishes and silently drops.
- **Batch error surface:** if a single source fails mid-batch, the
  for-loop in `runOnAllSources` rethrows immediately. v0.7 accepts
  partial saves (notes already created remain). Future improvement:
  collect per-source results + display in the toast.
- **AppLanguage import in Core:** `NotebookStore.init(path:language:)`
  needs `AppLanguage` — that type is in Core already (M0). No new
  cross-module dependency.
- **`TransformationsView` Swift type renamed in UI only:** users see
  "AI tools" but the file + struct stays `TransformationsView` for
  diff hygiene. Same trick applied to the `transformations` SQL
  table.
