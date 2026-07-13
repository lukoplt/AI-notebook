# Changelog

## [0.11.0] — 2026-07-13

macOS reaches feature parity with Windows (Epics B–E), plus personas on
both platforms.

### Added
- macOS: export a note to Markdown, a notebook to a ZIP (with a
  `sources.json` manifest), and back up / restore the whole database.
- macOS: a ⌘K "search everything" palette across all notebooks' notes and
  source titles, with jump-to navigation.
- macOS: drag & drop files onto Sources, bulk select / delete / summarize
  sources, bulk delete notes, a source preview sheet (chunks + metadata),
  and tags with a per-source filter.
- macOS: per-notebook chat instructions (now injected into the system
  prompt), named source sets in the chat scope, edit / regenerate the last
  answer with a choice of model, and a contextual-enrichment column.
- macOS: live sources — sync a folder (ingest new, re-ingest changed, skip
  unchanged by content hash) and re-crawl a URL source; opt-in web search
  in chat (results injected as user-message context, never the system
  prompt).
- Both platforms: personas (C5) — a named preset of instructions + source
  set + model, selectable in chat (schema v18).
- Windows: export a note to PDF and bulk-summarize selected sources.
- A retrieval-evaluation harness (recall@k) for measuring retrieval
  quality locally.

### Fixed
- macOS: `ProviderRouter` now honors an explicitly provider-qualified chat
  model (regenerate-with-model previously only tagged the message).

### Schema
- Migrations v12–v15 ported to macOS (tags + notes FTS, instructions +
  source sets, chunk context, live sources); v18 (personas) on both
  platforms.

## [0.10.0] — 2026-07-10

In-app update notifications.

### Added
- Both platforms: in-app update check — once a day (toggleable in Settings)
  the app asks GitHub Releases whether a newer version exists and shows a
  dismissible banner with a Download button; a "Check for updates now"
  button lives in Settings. Check + notify only, no auto-download.

### Fixed
- The in-app version constants were stale (0.7.3); they now match the repo
  VERSION file and a guard test on each platform fails CI on any future drift.

## [0.9.2] — 2026-07-10

Privacy-consent enforcement + Windows data-integrity fixes.

### Added
- Both platforms: the per-provider privacy consent (recorded when you enable
  a cloud/network provider) is now enforced — chat and embedding requests to
  a provider without recorded consent are refused with a clear localized
  error, and selecting such a provider in Settings re-shows the consent
  dialog (accept proceeds, decline reverts). Changing an existing provider's
  type to a different cloud service asks for consent again on both platforms.

### Fixed
- Windows: editing a provider (rename, URL, key rotation) no longer silently
  resets its recorded privacy consent.
- Windows: the "indexing" badge no longer shows pending chunks forever — it
  now checks embeddings under the correct provider-qualified key.
- Windows: embeddings created before the provider registry (v0.8.0 era) are
  requalified by a new migration and are visible to retrieval again.
- Windows: switching the embedding model mid-indexing can no longer store
  vectors under a stale key (router now honors the exact requested key).
- Windows: the built-in Ollama provider row was unreadable on every database
  (seed wrote second-precision timestamps, reader required milliseconds) —
  fixed seed, repair migration, and tolerant date parsing.
- Windows: "Test connection" for OpenAI / OpenAI-compatible providers no
  longer reports success when the server is unreachable or the key invalid.
- Both platforms: adapters share one SSE wire implementation per platform
  (parser divergence class eliminated).

## [0.9.1] — 2026-07-10

Security patch release for the Windows build.

### Fixed
- Windows: bumped SQLitePCLRaw 2.1.11 → 3.0.3 (GHSA-2m69-gcr7-jv3q, HIGH) —
  the bundled native SQLite is replaced with SQLite 3.50.4 via
  SourceGear.sqlite3. No 2.x patch exists; Microsoft.Data.Sqlite unchanged.

## [0.9.0] — 2026-07-09

Multi-provider AI on both platforms: the macOS app gains the full provider
registry, and both apps can now chat through an OpenWebUI server on the
network.

### Added
- macOS: full AI provider registry — connect Anthropic (Claude), OpenAI
  (ChatGPT), any OpenAI-compatible server (LM Studio, OpenRouter, vLLM), or
  an OpenWebUI server on your network, alongside local Ollama. Per-role
  provider + model selection for chat and embeddings, connection test,
  privacy consent gate, and API keys stored in the macOS Keychain — never in
  the database. Embedding vectors are now keyed by provider + model, and
  provider/model switches apply immediately (no relaunch).
- Windows: OpenWebUI network provider. New provider type in Settings → AI
  providers: connect to an OpenWebUI server on your network (base URL +
  optional API key), fetch its aggregated model list, and use any of its
  models for chat, transformations, and summaries. Chat-only by design —
  embeddings stay local (Ollama). The API key is stored in Windows
  Credential Manager, never in the database.

## [0.8.2] — 2026-07-06

Windows launch hotfix. The v0.8.1 Windows build installed but exited
silently on every launch; this release makes the app actually start.

### Fixed
- Windows: settings storage no longer uses `ApplicationData.Current`
  (requires MSIX package identity, which the unpackaged app does not have);
  settings now live in `%APPDATA%\AINotebook\settings.json`.
- Windows: the release publish now runs with `-p:Platform=x64`, so the
  WinUI `.pri` resource files ship with the installer (without them the
  app cannot resolve any XAML resource).
- Windows: shipped NuGet packages are pinned to exact versions — floating
  ranges resolved differently across restore contexts and deployed
  `Microsoft.Data.Sqlite` 9.0.16 next to a `Core.dll` built against 9.0.17.
- Windows: language switching no longer sets
  `ApplicationLanguages.PrimaryLanguageOverride` (packaged-only API); the
  resource-context qualifier already handles it.
- Windows: registered the missing `OnboardingViewModel` DI service the
  first screen resolves.

### Added
- Windows: startup crashes are logged to `%TEMP%\ainotebook-crash.log`
  so silent failures are diagnosable.
- Windows release CI: post-publish guard that fails the build if
  `AINotebook.App.exe`, `AINotebook.App.pri`, `Microsoft.ui.xaml.dll`, or
  `e_sqlite3.dll` are missing from the payload.

## [0.8.1] — 2026-06-29

First public release. Open-source on GitHub, cross-platform (macOS +
Windows), with a green Windows CI build.

### Added
- Author footer ("Made with <3 by Lukáš Oplt") in Settings on both platforms.
- Public README with screenshots, a privacy section, and per-platform
  install + first-launch ("unknown publisher") guidance.

### Fixed
- Windows App build (Windows CI is green again): removed stale `SaveCommand`
  references in `AddProviderViewModel`, a duplicate `StringKey` enum member,
  non-nullable `Tag`/`SourceSet` `Id` misuse, a static-member instance access,
  a `GlobalSearchDialog` `x:DataType` namespace, and a duplicate localization
  key; updated test fakes for the multi-provider `ISettingsService`.
- Security: web search results are injected as user-message context instead
  of the system prompt, reducing prompt-injection surface.

## [0.7.3] — 2026-05-25

Notes editor: per-note isolation + unsaved-changes guard.

### Fixed
- Switching between Notes now reloads the editor with the target
  note's content. `NoteWYSIWYGEditor` is keyed by `.id(noteId)` so
  SwiftUI recreates the WebView and AutoSaveController per note,
  preventing the prior body from bleeding into the next selection.
- If the active note has unsaved edits, switching to another note
  presents an alert with three options: **Save** (flush
  AutoSaveController, then switch), **Discard** (switch without
  saving), **Cancel** (stay on the current note). The "+" New note
  button and citation jumps go through the same intercept.

### Added
- `NoteEditorCoordinator` (App-level) — lets `NotesView` observe
  the editor's dirty state and trigger a flush from outside.
- 4 new EN/CS localization keys for the unsaved-changes alert
  (`unsavedChangesTitle`, `unsavedChangesMessage`, `unsavedSaveButton`,
  `unsavedDiscardButton`).

## [0.7.2] — 2026-05-25

NotesView 3-column layout fills the window correctly.

### Fixed
- `NotesView` HSplitView + all three panes (`list`, `detail`,
  `NotesChatPanel`) now have explicit `.frame(maxHeight: .infinity)`
  so the layout stretches to the full notebook detail area.
- `NoteWYSIWYGEditor` body's outer VStack expands to fill the
  detail pane — the WKWebView no longer collapses to its intrinsic
  height.
- Notes list empty state and detail empty state redesigned as
  centred call-to-action panels with icons and prominent buttons,
  matching the Sources empty-state pattern.

## [0.7.1] — 2026-05-25

UI layout fixes — tab content panes now fill the full window.

### Fixed
- `TransformationsView` ("AI tools") now expands to fill the whole
  detail area instead of collapsing to its intrinsic size.
- `SourceListView` likewise fills the available space; the empty
  state was redesigned as a centred call-to-action with a "tray"
  icon, headline message, and prominent "Add source" button.
- `ChatView.chatSurface` and `NotesChatPanel` body now have explicit
  `.frame(maxWidth: .infinity, maxHeight: .infinity)` on their
  outer VStack and inner `messagesList`, so the messages scroll and
  input bar dock to the bottom correctly in both chat surfaces.
- Streaming result pane in AI tools uses a dedicated
  `runningSection` view with `Spacer()` so the progress bar sits at
  the top while the area below stays reserved for content.

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
- 204 unit tests (was 193).

## [0.6.0] — 2026-05-25

Version history for Notes — final milestone of the v0.3-v0.6 "Notes as
Blocks" release cycle.

### Added
- Every save snapshots the previous Note body into `note_versions`.
- History button in the WYSIWYG editor (⇧⌘H) opens a sheet listing
  prior revisions with timestamps and a read-only preview.
- "Restore this version" rewrites the Note body and snapshots the
  superseded content as a `restore`-tagged revision.
- 50-version cap per Note; oldest snapshots pruned automatically.

### Schema
- MigrationV8 adds the `note_versions` table.

### Tests
- 193 unit tests (was 186).

## [0.5.0] — 2026-05-25

Attachments + inline images land in the WYSIWYG editor.

### Added
- Drag/paste images and files into the editor; saved under
  `~/Library/Application Support/AINotebook/attachments/<note-uuid>/`.
- Inline image rendering via the new `attachment://` URL scheme handler
  (`WKURLSchemeHandler`).
- Non-image files insert as Markdown links inline.
- Cascade cleanup: deleting a Note removes both its DB rows and its
  attachments folder.
- Filename collision handling: duplicates get ` (2)`, ` (3)` suffixes.

### Schema
- MigrationV7 adds the `attachments` table (note_id FK, cascade).

### Tests
- 186 unit tests (was 179).

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
- 179 unit tests (was 174).

## [0.3.0] — 2026-05-25

Notes graduate from passive note-taking to the primary authoring canvas
of the app.

### Added
- Notes auto-indexing: every Note participates in RAG retrieval via a
  hidden shadow Source row (`SourceType.note`, `NoteIndexer` actor).
- Three-column Notes tab: list / editor / chat sidebar.
- Chat sidebar injects the currently-open Note as bonus context (new
  `currentNoteContent` parameter on `ChatEngine.send`).
- Citation popover "Open note" action jumps to the cited Note.
- `NoteJumpCoordinator` observable for citation → note navigation.

### Schema
- MigrationV6 adds `notes.auto_source_id` + `notes.note_uuid`; pre-existing
  Notes get a backfilled UUID on first launch.
- `NotebookStore.sources(notebookId:)` excludes `.note` shadow rows from
  the user-facing Sources pane; `sourcesIncludingShadow(...)` exposes
  the full list for internal use.

### Tests
- ~170 unit tests (was 159).

## [0.2.0] — 2026-05-25

Deferred polish — closes all in-scope v1 gaps from M5/M6/M7.

### Added
- "Save as note" button on assistant chat messages.
- Notebook-scope transformations (run a template over every source).
- Custom transformation editor (create/edit/delete user templates).
- Multi-session chat per notebook (sidebar with new/delete).
- Model management sheet in Settings (list/pull/delete via Ollama API).
- Chat & embedding model pickers in Settings.
- PDF citation popover surfaces the source page and opens in Preview.
- Re-embed-all action in Settings (delete vectors + drain worker).
- Streaming UI for transformation runs (live token render).

### Changed
- `ChatEngine` retries failed streams (exponential backoff, 2 attempts).
- `build-app.sh` excludes `*Tests.bundle` artefacts from the release `.app`.
- PDF chunks now carry `page_hint` per page via `Chunker.chunkPaged`.

### Tests
- 159 unit tests (was 147 in v0.1.0).

## [0.1.0] — 2026-05-24

First public release. Native macOS desktop app cloning the open-notebook
research workflow, with Ollama (local) as the only AI provider.

### Features
- Multi-notebook organisation
- Source ingestion: PDF, plain text, Markdown, web URL, Office (docx / pptx / xlsx)
- Background chunking + embedding via Ollama `nomic-embed-text`
- Hybrid retrieval (vector cosine + FTS5 BM25 → Reciprocal Rank Fusion)
- RAG chat with streaming tokens and clickable inline `[N]` citations
- Markdown notes editor (manual + AI-generated from chat / transformations)
- Built-in transformation templates: Summary, Key points, Entities
- First-launch onboarding wizard: detect Ollama, guide install, auto-pull
  preset models (`llama3.2:3b`, `nomic-embed-text`)
- Bilingual UI (English + Czech) with system-locale auto-detect

### Architecture
- Swift Package — `AINotebookCore` library + `AINotebookApp` executable
- Single SQLite file at `~/Library/Application Support/AINotebook/db.sqlite`
- 147 unit tests covering migrations, storage, ingestion, embedding,
  retrieval, chat engine, and transformations
