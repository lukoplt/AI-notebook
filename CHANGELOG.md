# Changelog

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
