# Changelog

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
