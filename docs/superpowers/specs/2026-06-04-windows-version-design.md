# AI Notebook for Windows — Design Spec

**Date:** 2026-06-04
**Status:** Approved (design); pending implementation plan
**Author:** Lukáš Oplt (with Claude)

## Purpose

Ship a **public Windows release** of AI Notebook with **full feature parity**
to the macOS app (currently v0.7.3), distributed as a downloadable installer.
The existing SwiftUI macOS app stays **untouched** — Windows is a parallel
native track.

This supersedes the original design spec's one-line note that the Windows
port would use WPF (`2026-05-24-ai-notebook-design.md`). After a codebase
feasibility assessment (below), the chosen stack is **.NET 8 + WinUI 3 + C#**.

## Decisions (locked during brainstorming)

1. **Goal:** public Windows release, full feature parity, downloadable installer.
2. **Mac app:** untouched. Windows is a separate native codebase; non-UI logic
   reused conceptually (ported), not via a shared binary.
3. **Stack:** full .NET rewrite — **WinUI 3 + C#** UI, C# core library.
4. **Reuse:** the web `editor.js` (TipTap/ProseMirror) bundle and the SQLite +
   FTS5 schema/migrations are reused directly; all engine algorithms are
   ported 1:1 from `AINotebookCore`.
5. **Distribution:** unsigned **Inno Setup** `.exe` installer via GitHub
   Releases — mirrors the mac app's current ad-hoc/unsigned DMG posture. Zero
   cost; users click through a SmartScreen warning. Authenticode signing is a
   later add (CI hook left in place).

## Feasibility assessment (why this stack)

A full map of the macOS codebase (66-file `AINotebookCore` / 4,110 LOC +
39-file `AINotebookApp` / 3,399 LOC) found:

- **Core logic is ~98% portable Swift**, but the only thing that would make a
  *keep-Swift* strategy worthwhile — recompiling `AINotebookCore` on the Swift
  Windows toolchain — is **entirely hostage to GRDB**, which has no advertised
  Windows support and is used across ~29 files (DatabaseQueue, DatabaseMigrator,
  9 migrations, FTS5 virtual tables + triggers). Unvalidated, high risk.
- Even in the best Swift case, **100% of the ~3,399 LOC UI is a rewrite anyway**
  (SwiftUI / AppKit / WebKit have no Windows equivalents), plus a fragile
  Swift↔native interop boundary for an async/actor API. "Keep Swift" saves
  re-typing the core but not the expensive half of the work.
- The **core algorithms are small and crisply specified** — RRF retrieval
  (~149 LOC), chunker (~69), system-prompt builder (~38), citation parser
  (~24), Ollama NDJSON protocol (~234) — so re-implementing them in C# is
  bounded, mechanical work with **zero toolchain unknowns**, and every Apple
  dependency has a first-class .NET equivalent.
- Two genuinely reusable assets survive intact: **`editor.js`** drops into
  WebView2, and the **SQLite schema/migrations** port directly.

Net: the .NET rewrite trades literal code reuse (which the GRDB risk made
fragile) for a predictable path, native Windows UX, and a clean packaging
story. The cost — core logic maintained in two languages — is accepted.

## Scope

### In scope (v1 — parity with mac v0.7.3)

- Multi-notebook organization.
- Source ingestion: PDF, plain text / Markdown, web URL, Office (docx/pptx/xlsx).
- RAG chat over sources with inline `[N]` citations and citation detail.
- Notes: WYSIWYG Markdown editor + "save as note" from chat / transformation.
- Transformations: prompt templates over a source, result saved as a note;
  batch run, preview, history, open-note.
- Hybrid retrieval: vector cosine + FTS5 BM25 fused via Reciprocal Rank Fusion.
- Bilingual UI (English + Czech), system-locale auto-detect, override in Settings.
- Onboarding wizard: detect Ollama, guide install if missing, auto-pull preset
  models (`llama3.2:3b` + `nomic-embed-text`) with progress.
- Model management (pull / list / delete).
- Note + transformation version history; autosave; attachments in notes.
- Offline-by-policy preserved: only Ollama localhost, user-initiated URL
  fetches, and the optional update check make network calls.

### Out of scope (v1)

- Auto-update (manual download from Releases — matches mac).
- Microsoft Store submission; MSIX packaging; code signing (CI hook only).
- Telemetry; cloud LLM providers; multi-user / sync; mobile.
- Any change to the macOS app beyond the shared `editor.ts` bridge shim (§5).

## Architecture

A new top-level `windows/` directory keeps the mac app untouched while sharing
the repo's `VERSION` file and `editor` web assets.

```
windows/
  AINotebook.sln
  src/
    AINotebook.Core/           # C# class library — ALL logic, no WinUI refs
      Storage/                 # Microsoft.Data.Sqlite + Dapper, Migrator, repositories
      Ollama/                  # OllamaClient (HttpClient, NDJSON streaming)
      Ingestion/               # Pdf (PdfPig), Office (Zip+Xml), Web (AngleSharp), Markdown/Text
      Embedding/               # Embedder + background EmbeddingWorker (Channel<T>)
      Retrieval/               # Chunker, Retriever (cosine + BM25 + RRF)
      Chat/                    # ChatEngine (citation-aware streaming)
      Transformations/         # TransformationEngine + built-in templates
      Models/                  # records / DTOs
      Localization/            # locale detection
    AINotebook.App/            # WinUI 3 (Windows App SDK), MVVM
      Views/                   # XAML pages mirroring SwiftUI views
      ViewModels/              # CommunityToolkit.Mvvm
      Editor/                  # WebView2 host + JS bridge + attachment virtual-host
      Onboarding/
      Strings/                 # en/ + cs/ .resw
      Resources/editor/        # copied at build from ../../../Sources/AINotebookApp/Resources/editor
      App.xaml(.cs)            # DI service graph (mirrors AINotebookApp.swift), MainWindow
  tests/
    AINotebook.Core.Tests/     # xUnit, ports AINotebookCoreTests + Fixtures
  installer/
    installer.iss              # Inno Setup script
  .github/workflows/
    windows-release.yml        # tag v* -> windows-latest -> publish -> Inno -> Release
```

`AINotebook.Core` has **no UI dependency** and is independently testable. The
mac `AINotebookCore` serves as the executable spec; algorithms are ported 1:1.

### Component boundaries

Each unit has one purpose and a defined interface, mirroring the mac
protocol-driven design:

- `ITextExtractor` — `PdfTextExtractor` (PdfPig), `OfficeTextExtractor`
  (Zip+Xml), `WebTextExtractor` (AngleSharp + HttpClient), `PlainTextExtractor`.
  PDF (the one hard blocker) is an isolated swap behind this interface.
- `IChatStreaming` / `IEmbeddingProducing` — implemented by `OllamaClient`.
- `INotebookStore`, `IAppSettings`, `IAutoSaveController` — services raising
  events / `INotifyPropertyChanged`, replacing the mac `ObservableObject`
  stores (logic identical; only the observation mechanism changes).

## Data layer

- **Engine:** `Microsoft.Data.Sqlite` (bundles SQLite with FTS5). Queries via
  **Dapper**; mutations via hand-written SQL in repositories.
- **Location:** `%LOCALAPPDATA%\AINotebook\db.sqlite` (mirrors the mac App
  Support path). Per-platform DB file, identical schema.
- **Migrations:** a `Migrator` runs the **same 9 versioned migrations** as the
  GRDB `DatabaseMigrator`, hand-written as ordered SQL → byte-identical schema
  including FTS5 virtual tables and their sync triggers. Migration version is
  tracked in a `schema_migrations` (or `PRAGMA user_version`) table.
- **Embeddings:** stored as `BLOB` of float32, same layout as mac. Loaded into
  `float[]` for cosine.
- **Repositories** return C# `record` types.

## Core engines (ported 1:1)

| macOS (Swift) | Windows (C#) | Notes |
|---|---|---|
| `OllamaClient` (URLSession NDJSON) | `OllamaClient` (`HttpClient`, line-streamed `IAsyncEnumerable<T>`) | `/api/chat`, `/api/embeddings`, `/api/pull` (progress), `/api/tags` |
| `Chunker` | `Chunker` | deterministic chunking, same params |
| `Retriever` (cosine + BM25 + RRF) | `Retriever` | cosine = plain C# dot/magnitude loop (replaces Accelerate/vDSP) |
| `Embedder` + `EmbeddingWorker` | same | background worker on a `Channel<T>` |
| `ChatEngine` (citation streaming) | `ChatEngine` | `[N]` citation parser ported; streams tokens to UI |
| `TransformationEngine` + templates | same | built-in Summary / Key points / Entities templates |
| `PDFExtractor` (PDFKit) | `PdfTextExtractor` (**PdfPig**) | the only blocker; drop-in behind `ITextExtractor` |
| `OfficeExtractor` (ZIPFoundation + XMLParser) | `OfficeTextExtractor` (`System.IO.Compression` + `System.Xml`) | DOCX/PPTX/XLSX — same OOXML approach |
| `WebExtractor` (SwiftSoup) | `WebTextExtractor` (**AngleSharp**) | HTML → text |
| `IngestionService` | `IngestionService` | extract → chunk → store → enqueue embedding |
| `Cosine` (Accelerate) | inline C# | ~5-line replacement |

## Note editor — WebView2 hosts the existing `editor.js`

The TipTap/ProseMirror editor is reused unchanged at runtime. Only host glue
is reimplemented:

- **Asset hosting:** `CoreWebView2.SetVirtualHostNameToFolderMapping` serves
  `editor.html/css/js` over a virtual host (replaces `Bundle.module.loadFileURL`).
- **JS → C#:** `CoreWebView2.WebMessageReceived` (replaces the `WKScriptMessageHandler`
  named `aino`). Same message protocol: `ready` / `change` / `save` /
  `attachmentRequest` / `attachmentSaved` / `attachmentDenied`.
- **C# → JS:** `ExecuteScriptAsync` (replaces `evaluateJavaScript`).
- **`attachment://`:** WebView2 `AddWebResourceRequestedFilter` +
  `WebResourceRequested`, served from `AttachmentStore` (replaces
  `WKURLSchemeHandler`).

**Shared change (safe for mac):** `editor.ts` currently posts to the WebKit
bridge (`window.webkit.messageHandlers.aino`). Add a small bridge-detection
shim — use `window.chrome.webview` when present (WebView2), else the WebKit
branch — and rebuild `editor.js` via the existing `tools/editor` esbuild
pipeline. The mac app falls through to the WebKit branch, so **its behavior is
unchanged**; one bundle works on both platforms. The Windows build copies the
rebuilt `editor.html/css/js` from `Sources/AINotebookApp/Resources/editor/` at
build time (read-only reuse; no duplicate committed in `windows/`).

## UI (WinUI 3, MVVM)

- **Framework:** WinUI 3 (Windows App SDK), MVVM via **CommunityToolkit.Mvvm**
  (`ObservableObject`, `RelayCommand`). DI via
  `Microsoft.Extensions.DependencyInjection`, service graph built in
  `App.xaml.cs` (mirrors the `AINotebookApp.swift` `init`).
- **Shell:** one `MainWindow`. `NavigationView` sidebar = notebook list
  (new/rename/delete). Content = `TabView` with Sources / Chat / Notes /
  Transformations (mirrors `NotebookDetailView`).
- **View map (SwiftUI → XAML Page + ViewModel):** SourceList + AddSource
  (`FileOpenPicker` for files; URL; text), ChatView (message list, streaming,
  citation `Flyout`), NotesView (3-column: list + WebView2 editor + chat panel;
  unsaved-changes `ContentDialog`; history), Transformations (list, batch,
  preview, history, open-note), Settings (models, language), ModelManagement
  (pull/list/delete), NewNotebook / RenameNotebook dialogs.
- **Platform glue:** `NSWorkspace.open` → `Windows.System.Launcher` /
  `Process.Start`. `Cmd`-shortcuts → `Ctrl` via `KeyboardAccelerator`
  (Ctrl-S save, Ctrl-Shift-H history).
- **Onboarding:** Welcome → DetectOllama → PickModels → PullModels → Done.
  Detects native Windows Ollama (localhost `/api/tags` + process/registry
  check); launches the Ollama download URL if absent; streams `pull` progress.

## Localization

- `.resw` resource files for **English + Czech** under `Strings/en/` and
  `Strings/cs/`.
- Auto-detect initial language from `CultureInfo.CurrentUICulture`
  (mirrors `LocaleDetection`); override persisted in settings; runtime switch
  via a localized-string provider / `ResourceLoader`.

## Error handling

- **Ollama not installed / not running:** routed to onboarding guidance and an
  actionable `InfoBar`; chat/embedding calls fail soft with retry.
- **Ingestion errors:** per-source status (mirrors mac source-status enum);
  one bad source never blocks the notebook.
- **DB migration failure:** fail-safe — abort open with a clear error rather
  than corrupt; never silently drop data.
- **Surfacing:** `InfoBar` for inline/non-blocking, `ContentDialog` for modal
  decisions (e.g. unsaved changes).

## Testing

- **xUnit** project `AINotebook.Core.Tests`, porting `AINotebookCoreTests` and
  its `Fixtures`. Priority coverage: chunker determinism, RRF fusion ordering,
  citation parser, Office (DOCX/PPTX/XLSX) extraction, PDF extraction (PdfPig),
  migration up-to-v9 producing the expected schema, Ollama NDJSON parsing.
- UI verified manually for v1.

## Build & release

- **CI:** `windows/.github/workflows/windows-release.yml` (or a job in the
  existing workflows) triggers on tag `v*`, runs on `windows-latest`:
  `dotnet test` → `dotnet publish -c Release -r win-x64 --self-contained`
  (no .NET runtime or Windows App SDK runtime install required by users) →
  Inno Setup compile → upload `AINotebook-vX.Y.Z-windows-setup.exe` to the
  GitHub Release.
- **Version source:** reads the repo root `VERSION` file — single source of
  truth shared with the mac build.
- **WebView2 runtime:** installer chains the **Evergreen bootstrapper**
  (preinstalled on Windows 11; installed on demand on Windows 10).
- **Minimum OS:** Windows 10 1809+ (Windows App SDK floor).
- **Signing:** unsigned for v1 (SmartScreen warning, matches mac). A
  `SIGN_CERT`-gated Authenticode step is left commented in CI for later.

## Risks & mitigations

- **FTS5 + RRF fidelity:** the retrieval ranking must match mac behavior.
  Mitigation: port the RRF math exactly and add a unit test asserting ranking
  order on a fixed fixture.
- **Editor bridge port:** the `attachment://` + message protocol is the
  highest-effort integration. Mitigation: build a minimal WebView2 + editor.js
  spike early (round-trip one `change`/`save` message + one `attachment://`
  load) before building the full Notes view.
- **WebView2 dependency on Win10:** mitigated by the Evergreen bootstrapper in
  the installer.
- **Double maintenance of core logic:** accepted trade-off. Mitigation: keep
  `AINotebook.Core` algorithmically faithful and test-covered so the two
  implementations can be diffed behaviorally.

## Success criteria

- Fresh Windows 10/11 machine: download installer → install → first-run
  onboarding detects/guides Ollama → pulls models → create notebook → add a
  PDF + a URL + a DOCX source → ask a question → get a streamed answer with
  working `[N]` citations → save a note in the WYSIWYG editor → run a
  transformation → switch UI to Czech. All without a terminal.
- Core unit tests green on `windows-latest` CI.
- Installer artifact attached to the GitHub Release alongside the mac DMG.
