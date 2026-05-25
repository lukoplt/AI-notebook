# M8: WYSIWYG Editor + Auto-Save Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain `TextEditor` Markdown surface in the Notes pane with a WYSIWYG editor (TipTap inside `WKWebView`). Markdown remains the source of truth on disk; the editor round-trips Markdown ↔ HTML transparently. Save fires on ⌘S and after a 2 s idle debounce, with a Saved / Saving / Unsaved status indicator.

**Architecture:** Vendor a self-contained TipTap + ProseMirror bundle (built once via esbuild, committed to the repo) as a static SPM resource. A SwiftUI `NoteWYSIWYGEditor` wraps a `WKWebView` (via `NSViewRepresentable`), loads the bundled HTML, and exchanges messages with the JS side over a `WKScriptMessageHandler` named `aino`. Change events from JS feed an `AutoSaveController` that debounces 2 s before calling the existing `NotesView.save(id:)` pipeline.

**Tech Stack:** Swift 6, SwiftUI, WebKit (`WKWebView`), JavaScript bundle (TipTap + tiptap-markdown).

---

## File Structure

**Create:**
- `tools/editor/package.json` — npm manifest pinning TipTap deps
- `tools/editor/src/editor.ts` — TipTap setup + JS↔Swift bridge
- `tools/editor/build.mjs` — esbuild script that emits a single self-contained `editor.js`
- `tools/editor/README.md` — short note: when/how to rebuild the bundle
- `Sources/AINotebookApp/Resources/editor/editor.html` — host page that loads `editor.js`
- `Sources/AINotebookApp/Resources/editor/editor.js` — built bundle (committed)
- `Sources/AINotebookApp/Resources/editor/editor.css` — minimal editor styling
- `Sources/AINotebookApp/MarkdownHTMLBridge.swift` — `WKScriptMessageHandler` + payload structs
- `Sources/AINotebookApp/AutoSaveController.swift` — 2 s debounce + ⌘S trigger + status enum
- `Sources/AINotebookApp/NoteWYSIWYGEditor.swift` — `NSViewRepresentable` wrapping `WKWebView` + status bar
- `Tests/AINotebookCoreTests/AutoSaveControllerTests.swift`

**Modify:**
- `Package.swift` — register `Sources/AINotebookApp/Resources/editor` as a `.copy` resource of the executable target
- `Sources/AINotebookCore/Localization.swift` — 5 new EN/CS keys for status + retry
- `Sources/AINotebookApp/NotesView.swift` — swap `NoteEditor` for `NoteWYSIWYGEditor`
- `Sources/AINotebookApp/NoteEditor.swift` — retained as a fallback view; `NoteWYSIWYGEditor` is preferred but `NoteEditor` is kept for the History sheet (M10).

---

## Task 1: Branch + baseline

```bash
git checkout main
git checkout -b m8-wysiwyg-editor
swift test --parallel 2>&1 | tail -5
```

Expected: 174/174 pass.

---

## Task 2: Bundle TipTap into `editor.js`

Requires `node` + `npm` on the build machine. End users do not — the
output `editor.js` is committed.

**Files:** Create `tools/editor/package.json`, `tools/editor/src/editor.ts`, `tools/editor/build.mjs`, `tools/editor/README.md`, `Sources/AINotebookApp/Resources/editor/editor.{html,css,js}`.

- [ ] **Step 1: Create `tools/editor/package.json`**

```json
{
  "name": "ai-notebook-editor",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "build": "node build.mjs"
  },
  "devDependencies": {
    "esbuild": "^0.24.0",
    "typescript": "^5.5.0"
  },
  "dependencies": {
    "@tiptap/core": "^2.10.0",
    "@tiptap/pm": "^2.10.0",
    "@tiptap/starter-kit": "^2.10.0",
    "@tiptap/extension-image": "^2.10.0",
    "tiptap-markdown": "^0.8.10"
  }
}
```

- [ ] **Step 2: Create `tools/editor/src/editor.ts`**

```ts
import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Image from "@tiptap/extension-image"
import { Markdown } from "tiptap-markdown"

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        aino?: { postMessage: (m: unknown) => void }
      }
    }
    aino?: {
      setContent: (md: string) => void
      requestSave: () => void
    }
  }
}

function postToSwift(payload: unknown) {
  window.webkit?.messageHandlers?.aino?.postMessage(payload)
}

const mount = document.getElementById("editor") as HTMLElement
const editor = new Editor({
  element: mount,
  extensions: [
    StarterKit,
    Image.configure({ inline: false, allowBase64: false }),
    Markdown.configure({ html: false, tightLists: true, linkify: true })
  ],
  content: "",
  onUpdate({ editor }) {
    const md = (editor.storage as any).markdown.getMarkdown() as string
    postToSwift({ kind: "change", markdown: md })
  }
})

window.aino = {
  setContent(md: string) {
    editor.commands.setContent(md, false)
  },
  requestSave() {
    const md = (editor.storage as any).markdown.getMarkdown() as string
    postToSwift({ kind: "save", markdown: md })
  }
}

postToSwift({ kind: "ready" })
```

- [ ] **Step 3: Create `tools/editor/build.mjs`**

```js
import { build } from "esbuild"

await build({
  entryPoints: ["src/editor.ts"],
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari16"],
  outfile: "../../Sources/AINotebookApp/Resources/editor/editor.js",
  loader: { ".ts": "ts" },
  logLevel: "info"
})
```

- [ ] **Step 4: Build the bundle**

```bash
mkdir -p Sources/AINotebookApp/Resources/editor
cd tools/editor
npm install
npm run build
cd ../..
ls -lh Sources/AINotebookApp/Resources/editor/editor.js
```

Expected: `editor.js` ~150-250 KB.

- [ ] **Step 5: Write `editor.html` + `editor.css`**

```html
<!-- Sources/AINotebookApp/Resources/editor/editor.html -->
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <link rel="stylesheet" href="editor.css" />
    <title>Editor</title>
  </head>
  <body>
    <div id="editor"></div>
    <script src="editor.js"></script>
  </body>
</html>
```

```css
/* Sources/AINotebookApp/Resources/editor/editor.css */
:root {
  color-scheme: light dark;
  --editor-fg: #1c1c1e;
  --editor-bg: transparent;
}
@media (prefers-color-scheme: dark) {
  :root { --editor-fg: #f2f2f7; }
}
html, body { height: 100%; margin: 0; padding: 0; background: var(--editor-bg); }
body {
  font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  color: var(--editor-fg);
}
#editor { padding: 16px; min-height: 100vh; }
#editor .ProseMirror {
  outline: none;
  min-height: 100vh;
  caret-color: var(--editor-fg);
}
#editor h1 { font-size: 1.6em; margin: 0.5em 0 0.4em; }
#editor h2 { font-size: 1.35em; margin: 0.5em 0 0.4em; }
#editor h3 { font-size: 1.15em; margin: 0.5em 0 0.4em; }
#editor p  { margin: 0.4em 0; }
#editor pre {
  background: rgba(127,127,127,0.12);
  padding: 8px 10px;
  border-radius: 6px;
  overflow-x: auto;
  font: 12.5px/1.45 ui-monospace, "SF Mono", Menlo, monospace;
}
#editor code { font: inherit; }
#editor img { max-width: 100%; border-radius: 4px; }
#editor blockquote {
  border-left: 3px solid rgba(127,127,127,0.4);
  margin: 0.5em 0; padding-left: 0.8em; color: rgba(127,127,127,0.95);
}
```

- [ ] **Step 6: Write `tools/editor/README.md`**

```markdown
# Editor bundle

The compiled WYSIWYG editor is committed to the repo at
`../../Sources/AINotebookApp/Resources/editor/editor.js` so end users
building the Swift Package don't need npm.

When you change `src/editor.ts` or bump deps:

```bash
cd tools/editor
npm install
npm run build
```

Commit the resulting `editor.js`.
```

- [ ] **Step 7: Commit**

```bash
git add tools/editor Sources/AINotebookApp/Resources/editor
git commit -m "build(editor): vendor TipTap WYSIWYG bundle"
```

---

## Task 3: Add the editor bundle as a SPM resource

**Files:** Modify `Package.swift`.

- [ ] **Step 1: Add `resources:` to the executable target**

In `Package.swift`, change the `.executableTarget(name: "AINotebookApp", ...)` declaration to:

```swift
.executableTarget(
    name: "AINotebookApp",
    dependencies: ["AINotebookCore"],
    resources: [
        .copy("Resources/editor")
    ]
)
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | tail -10
```

Expected: clean. SwiftPM picks up the resource folder.

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: expose editor bundle as AINotebookApp SPM resource"
```

---

## Task 4: `MarkdownHTMLBridge` — Swift ↔ JS message types

**Files:** Create `Sources/AINotebookApp/MarkdownHTMLBridge.swift`.

The JS side posts JSON to `webkit.messageHandlers.aino`. Swift decodes
each payload into a Swift enum.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/MarkdownHTMLBridge.swift
import Foundation
import WebKit

enum EditorMessage: Equatable {
    case ready
    case change(markdown: String)
    case save(markdown: String)
}

enum EditorMessageDecodeError: Error, Equatable {
    case invalidPayload
    case unknownKind(String)
    case missingMarkdown
}

/// Decodes a `WKScriptMessage` body into a typed `EditorMessage`.
/// Pure function — testable without spinning up a WKWebView.
enum MarkdownHTMLBridge {
    static func decode(_ body: Any) throws -> EditorMessage {
        guard let dict = body as? [String: Any],
              let kind = dict["kind"] as? String else {
            throw EditorMessageDecodeError.invalidPayload
        }
        switch kind {
        case "ready":
            return .ready
        case "change":
            guard let md = dict["markdown"] as? String else {
                throw EditorMessageDecodeError.missingMarkdown
            }
            return .change(markdown: md)
        case "save":
            guard let md = dict["markdown"] as? String else {
                throw EditorMessageDecodeError.missingMarkdown
            }
            return .save(markdown: md)
        default:
            throw EditorMessageDecodeError.unknownKind(kind)
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookApp/MarkdownHTMLBridge.swift
git commit -m "feat(app): MarkdownHTMLBridge — typed editor messages"
```

---

## Task 5: `AutoSaveController` — debounced save state machine

**Files:** Create `Sources/AINotebookApp/AutoSaveController.swift`, test `Tests/AINotebookCoreTests/AutoSaveControllerTests.swift`.

The controller exposes a `status` enum, a `noteDidChange(_ markdown:)`
sink, a `manualSave()` trigger, and calls back a `save` closure with
the latest body once the debounce expires.

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/AutoSaveControllerTests.swift
import XCTest
@testable import AINotebookApp

@MainActor
final class AutoSaveControllerTests: XCTestCase {

    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var saves: [String] = []
        func record(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            saves.append(s)
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return saves
        }
    }

    func testDebouncedSaveFiresAfterIdle() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 50) { body in
            counter.record(body)
        }
        controller.noteDidChange("v1")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.snapshot, ["v1"])
        XCTAssertEqual(controller.status, .saved)
    }

    func testMultipleQuickChangesCollapseToOneSave() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 50) { body in
            counter.record(body)
        }
        controller.noteDidChange("a")
        controller.noteDidChange("ab")
        controller.noteDidChange("abc")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.snapshot, ["abc"])
    }

    func testManualSaveBypassesDebounce() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 5_000) { body in
            counter.record(body)
        }
        controller.noteDidChange("draft")
        controller.manualSave()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.snapshot, ["draft"])
    }

    func testStatusTransitions() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 30) { body in
            counter.record(body)
        }
        XCTAssertEqual(controller.status, .saved)
        controller.noteDidChange("x")
        XCTAssertEqual(controller.status, .unsaved)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.status, .saved)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter AutoSaveControllerTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookApp/AutoSaveController.swift
import Foundation

@MainActor
public final class AutoSaveController: ObservableObject {
    public enum Status: Equatable, Sendable {
        case saved
        case unsaved
        case saving
        case error(String)
    }

    @Published public private(set) var status: Status = .saved

    private let debounceMillis: Int
    private let save: @Sendable (String) -> Void
    private var pendingBody: String?
    private var debounceTask: Task<Void, Never>?

    public init(
        debounceMillis: Int = 2_000,
        save: @escaping @Sendable (String) -> Void
    ) {
        self.debounceMillis = debounceMillis
        self.save = save
    }

    public func noteDidChange(_ markdown: String) {
        pendingBody = markdown
        status = .unsaved
        debounceTask?.cancel()
        let delay = UInt64(debounceMillis) * 1_000_000
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await self?.flush()
        }
    }

    public func manualSave() {
        debounceTask?.cancel()
        Task { [weak self] in await self?.flush() }
    }

    private func flush() async {
        guard let body = pendingBody else { return }
        status = .saving
        save(body)
        pendingBody = nil
        status = .saved
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter AutoSaveControllerTests 2>&1 | tail -10
git add Sources/AINotebookApp/AutoSaveController.swift Tests/AINotebookCoreTests/AutoSaveControllerTests.swift
git commit -m "feat(app): AutoSaveController with debounce + manual save"
```

Expected: 4/4 pass.

---

## Task 6: 5 EN/CS localization keys

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, modify `Tests/AINotebookCoreTests/LocalizationTests.swift`.

- [ ] **Step 1: Add keys**

| key | EN | CS |
|---|---|---|
| `editorStatusSaved` | "Saved" | "Uloženo" |
| `editorStatusSaving` | "Saving…" | "Ukládám…" |
| `editorStatusUnsaved` | "Unsaved changes" | "Neuložené změny" |
| `editorStatusError` | "Save failed" | "Uložení selhalo" |
| `editorFailedToLoad` | "Editor failed to load. Reopen the note." | "Editor se nepodařilo načíst. Otevřete poznámku znovu." |

- [ ] **Step 2: Add test**

```swift
    func testEditorStatusSavedIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.editorStatusSaved), "Saved")
        XCTAssertEqual(AppText(language: .czech)  .string(.editorStatusSaved), "Uloženo")
    }
```

- [ ] **Step 3: Verify + commit**

```bash
swift test --filter LocalizationTests 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): 5 EN/CS editor status localization keys"
```

---

## Task 7: `NoteWYSIWYGEditor` SwiftUI view

**Files:** Create `Sources/AINotebookApp/NoteWYSIWYGEditor.swift`.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/NoteWYSIWYGEditor.swift
import SwiftUI
import WebKit
import AINotebookCore

struct NoteWYSIWYGEditor: View {

    @Binding var title: String
    @Binding var bodyMd: String
    let language: AppLanguage
    let onSave: (String) -> Void

    @StateObject private var autoSave: AutoSaveController
    @State private var loadFailed = false

    private var t: AppText { AppText(language: language) }

    init(
        title: Binding<String>,
        bodyMd: Binding<String>,
        language: AppLanguage,
        onSave: @escaping (String) -> Void
    ) {
        self._title = title
        self._bodyMd = bodyMd
        self.language = language
        self.onSave = onSave
        // Capture onSave once; AutoSaveController will pass back the latest body.
        let saveBox: @Sendable (String) -> Void = { body in onSave(body) }
        self._autoSave = StateObject(wrappedValue: AutoSaveController(save: saveBox))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(t.string(.noteTitlePlaceholder), text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            if loadFailed {
                VStack {
                    Spacer()
                    Text(t.string(.editorFailedToLoad)).foregroundStyle(.red)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EditorWebView(
                    initialMarkdown: bodyMd,
                    onChange: { md in
                        bodyMd = md
                        autoSave.noteDidChange(md)
                    },
                    onLoadFailed: { loadFailed = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                statusLabel
                Spacer()
                Button("Save") { autoSave.manualSave() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch autoSave.status {
        case .saved:
            Label(t.string(.editorStatusSaved), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .saving:
            Label(t.string(.editorStatusSaving), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .unsaved:
            Label(t.string(.editorStatusUnsaved), systemImage: "pencil.circle")
                .font(.caption).foregroundStyle(.orange)
        case .error(let msg):
            Label("\(AppText(language: language).string(.editorStatusError)) — \(msg)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

private struct EditorWebView: NSViewRepresentable {
    let initialMarkdown: String
    let onChange: (String) -> Void
    let onLoadFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onLoadFailed: onLoadFailed)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "aino")
        config.userContentController = userController
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        guard let folder = Bundle.module.url(forResource: "editor", withExtension: nil),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("editor.html").path) else {
            DispatchQueue.main.async { onLoadFailed() }
            return webView
        }
        let html = folder.appendingPathComponent("editor.html")
        webView.loadFileURL(html, allowingReadAccessTo: folder)
        context.coordinator.webView = webView
        context.coordinator.initialMarkdown = initialMarkdown
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onChange = onChange
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onChange: (String) -> Void
        var onLoadFailed: () -> Void
        var initialMarkdown: String = ""

        init(onChange: @escaping (String) -> Void,
             onLoadFailed: @escaping () -> Void) {
            self.onChange = onChange
            self.onLoadFailed = onLoadFailed
        }

        func userContentController(_ uc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            do {
                let m = try MarkdownHTMLBridge.decode(message.body)
                switch m {
                case .ready:
                    let escaped = initialMarkdown
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "`",  with: "\\`")
                        .replacingOccurrences(of: "$",  with: "\\$")
                    let js = "window.aino && window.aino.setContent(`\(escaped)`)"
                    webView?.evaluateJavaScript(js, completionHandler: nil)
                case .change(let md):
                    onChange(md)
                case .save(let md):
                    onChange(md)
                }
            } catch {
                // Unknown payloads ignored in v1.
            }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            onLoadFailed()
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            onLoadFailed()
        }

        // Allow only the bundled file:// origin.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.scheme == "file" {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

If `Bundle.module` complains because the executable target doesn't auto-synthesize it for some toolchains, add `process` resources in `Package.swift` (already done) and rebuild.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookApp/NoteWYSIWYGEditor.swift
git commit -m "feat(app): NoteWYSIWYGEditor — WKWebView + AutoSave + status bar"
```

---

## Task 8: Wire `NoteWYSIWYGEditor` into `NotesView`

**Files:** Modify `Sources/AINotebookApp/NotesView.swift`.

- [ ] **Step 1: Replace `NoteEditor` usage with `NoteWYSIWYGEditor`**

In `Sources/AINotebookApp/NotesView.swift`, change the `detail` view body:

```swift
@ViewBuilder
private var detail: some View {
    if let id = selection, notes.contains(where: { $0.id == id }) {
        NoteWYSIWYGEditor(
            title: $draftTitle,
            bodyMd: $draftBody,
            language: settings.language,
            onSave: { latest in
                draftBody = latest
                Task { await save(id: id) }
            }
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
```

`NoteEditor` (the M6 plain TextEditor) is kept on disk — M10 will reuse
it as the read-only history-version preview pane.

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/NotesView.swift
git commit -m "feat(app): NotesView uses NoteWYSIWYGEditor"
```

---

## Task 9: Final verification + version + tag + merge

- [ ] **Step 1: Clean build + tests**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: build clean; ~180 tests (174 + AutoSaveController(4) + Localization(1)) pass.

- [ ] **Step 2: Smoke**

```bash
swift run AINotebookApp
```

With Ollama running:
- Open a notebook → Notes tab.
- Create a Note → WYSIWYG editor mounts within ~500 ms.
- Type "## Heading\n\nA paragraph." → status flips Unsaved → after 2 s → Saved.
- ⌘S → status flips Saving → Saved immediately.
- Re-open the Note → content survives, Markdown body in DB looks correct.

- [ ] **Step 3: Bump version + CHANGELOG**

```bash
echo "0.4.0" > VERSION
```

Edit `Sources/AINotebookCore/AINotebookVersion.swift` → `"0.4.0"`. Update `Tests/AINotebookCoreTests/AINotebookVersionTests.swift` assertion to `"0.4.0"`.

Prepend to `CHANGELOG.md`:

```markdown
## [0.4.0] — 2026-05-25

WYSIWYG Markdown editor lands in the Notes pane.

### Added
- TipTap-based WYSIWYG editor inside a WKWebView, replacing the plain
  TextEditor for Note bodies.
- Auto-save: 2 s idle debounce + ⌘S explicit save.
- Saved / Saving / Unsaved / Save failed status indicator.
- Markdown remains the source of truth on disk; the editor round-trips
  Markdown ↔ HTML via tiptap-markdown.

### Build
- `tools/editor/` ships TipTap source + esbuild script; `editor.js`
  bundle is committed so end users don't need npm.
- New SPM resource: `Sources/AINotebookApp/Resources/editor/`.

### Tests
- ~180 unit tests (was 174).
```

Commit:
```bash
git add VERSION CHANGELOG.md Sources/AINotebookCore/AINotebookVersion.swift Tests/AINotebookCoreTests/AINotebookVersionTests.swift
git commit -m "chore: bump version to 0.4.0 + CHANGELOG"
```

- [ ] **Step 4: Merge to main + tag**

```bash
git checkout main
git merge --ff-only m8-wysiwyg-editor
git tag -a v0.4.0 -m "v0.4.0 — WYSIWYG editor + auto-save"
git log --oneline | head -12
```

- [ ] **Step 5: Re-build DMG**

```bash
./tools/macos/build-app.sh
./tools/macos/build-dmg.sh
ls -lh dist/
```

Expected: `dist/AINotebook-v0.4.0-macos.dmg` exists.

---

## Acceptance criteria (M8 done when ALL true)

- `swift test --parallel` ~180 tests, 0 failures.
- `tools/editor/` builds a bundled `editor.js` via `npm run build`.
- `Sources/AINotebookApp/Resources/editor/` is shipped as an SPM resource.
- `MarkdownHTMLBridge.decode(_:)` round-trips `ready` / `change` / `save`
  payloads.
- `AutoSaveController` fires once after the debounce, collapses multiple
  rapid changes into a single save, and `manualSave()` bypasses the
  debounce.
- `NoteWYSIWYGEditor` mounts a `WKWebView` loaded from the bundled
  HTML, surfaces save status, and pipes JS change events back into the
  Note body binding.
- `NotesView`'s editor pane uses `NoteWYSIWYGEditor`.
- Local git tag `v0.4.0` exists; `main` fast-forwarded.

---

## Notes for the implementer

- **No node/npm at runtime:** end users never run npm. The bundle is
  committed. CI rebuilds aren't part of M8; the macOS-release.yml job
  works as-is because it consumes the committed `editor.js`.
- **WKWebView Sendable:** SwiftUI's `NSViewRepresentable` coordinator
  doesn't need Sendable conformance. Swift 6 strict will warn about
  `WKScriptMessage.body` being `Any`; the `MarkdownHTMLBridge.decode`
  pure function isolates the unsafe boundary.
- **Initial content escaping:** when sending the initial Markdown back
  to JS via `evaluateJavaScript`, we wrap it in JS template literals
  and escape ``\``, `` ` ``, and `$`. For most Notes this is enough; M9
  attachment paste flows reuse the same path.
- **Round-trip fidelity:** `tiptap-markdown` is round-trip stable for
  paragraphs, headings, bold/italic, lists, code, quotes, links,
  images. Tables and HTML embeds may re-format on save. Acceptable for
  v0.4; document in CHANGELOG known limitations after smoke.
- **Forward compat for M9 / M10:**
  - M9 will register a `WKURLSchemeHandler` for `attachment://` on the
    same `WKWebViewConfiguration` and add a paste/drop handler in
    `editor.ts`.
  - M10 will hook the `save` closure in `NotesView.detail` to also
    snapshot to `note_versions` before persisting the new body.
