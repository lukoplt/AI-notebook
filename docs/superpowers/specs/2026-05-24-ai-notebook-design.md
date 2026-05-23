# AI Notebook — Design Spec

**Date:** 2026-05-24
**Status:** Approved (v1 MVP)
**Author:** Lukáš Oplt (with Claude)

## Purpose

Native desktop alternative to Google NotebookLM and the upstream [open-notebook](https://github.com/lfnovo/open-notebook) project, restricted to **Ollama** (local desktop daemon or CLI) as the only AI provider. Target users are **non-technical** — the app must work end-to-end with zero command-line interaction after install.

## Scope

### In scope (v1)

- Multi-notebook organization
- Source ingestion: PDF, plain text / Markdown, web URL, Office (docx / pptx / xlsx)
- Context-aware chat with retrieval-augmented generation (RAG) over sources, with inline citations
- Notes: manual Markdown + "save as note" from chat / transformation result
- Content transformations: prompt templates applied over sources, result saved as note
- Hybrid search (vector ANN + full-text BM25) with citations
- Bilingual UI (English + Czech) with system-locale auto-detect (AIGuard pattern)
- Onboarding wizard: detect Ollama, guide install if missing, auto-pull preset models with progress
- macOS v1 (SwiftUI). Windows (WPF) port post-v1.

### Out of scope (v1)

- Podcast generation (deferred — needs local TTS)
- Audio / video ingestion (deferred — needs whisper STT)
- Cloud LLM providers (OpenAI, Anthropic, Google, etc.) — Ollama only
- REST API for external integration
- Multi-user / sync / sharing
- Mobile (iOS / iPadOS)

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  AINotebookApp  (SwiftUI macOS executable)                 │
│  ├ Onboarding wizard  Sources  Chat  Notes  Transform      │
│  └ Settings  (language, models, opt-ins)                   │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│  AINotebookCore  (Swift Package library)                   │
│  ├ NotebookStore  (GRDB + sqlite-vec + FTS5)               │
│  ├ Ingestion      (PDF / Web / Office / Text → chunks)     │
│  ├ Embedder       (Ollama /api/embed, batched)             │
│  ├ Retriever      (vec ∪ FTS5 → RRF rerank)                │
│  ├ ChatEngine     (Ollama /api/chat streaming)             │
│  ├ Transformer    (prompt template runner)                 │
│  ├ OllamaClient   (detect / install-guide / pull / chat)   │
│  └ Localization   (EN / CS, system-locale detect)          │
└──────────────────────────┬─────────────────────────────────┘
                           │ HTTP localhost:11434
┌──────────────────────────▼─────────────────────────────────┐
│  Ollama daemon  (user-managed, app-guided install)         │
└────────────────────────────────────────────────────────────┘
```

## Modules

| Module | Purpose | Key dependencies |
|---|---|---|
| `NotebookStore` | CRUD for notebooks, sources, chunks, notes, sessions, messages. Owns the single SQLite file. Versioned migrations on launch. | GRDB.swift, sqlite-vec |
| `OllamaClient` | HTTP client to `http://127.0.0.1:11434`. Detect daemon, list local models, stream pull, stream chat, batch embed. | URLSession |
| `Ingestion` | File / URL → cleaned text → chunks (~512 tokens, 64 overlap). | PDFKit, SwiftSoup, ZIPFoundation |
| `Embedder` | Pull chunks needing embedding, batch through Ollama, write vectors. | OllamaClient, NotebookStore |
| `Retriever` | Hybrid query: vector top-K + FTS5 BM25 top-K → Reciprocal Rank Fusion → citations. | NotebookStore |
| `ChatEngine` | Compose system prompt + retrieved context + history, stream tokens to UI, attach citation IDs. | OllamaClient, Retriever, NotebookStore |
| `Transformer` | Run user-defined prompt template over selected source(s). Save result as note linked back to source(s). | OllamaClient, NotebookStore |
| `Localization` | EN + CS strings, locale-detect on first launch, persisted user override (port of AIGuard `Localization.swift`). | — |

Each module ships independently testable (in-memory SQLite for `NotebookStore`, `URLProtocol` stub for `OllamaClient`).

## Data model

Single SQLite file at `~/Library/Application Support/AINotebook/db.sqlite` (sandbox-aware).

```sql
notebooks(
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);

sources(
  id INTEGER PRIMARY KEY,
  notebook_id INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
  type TEXT NOT NULL,             -- 'pdf' | 'text' | 'web' | 'docx' | 'pptx' | 'xlsx'
  title TEXT NOT NULL,
  uri TEXT,                       -- original URL or file path
  raw_path TEXT,                  -- copy in app support dir
  status TEXT NOT NULL,           -- 'pending' | 'chunking' | 'embedding' | 'ready' | 'error'
  error TEXT,
  ingested_at REAL NOT NULL
);

source_chunks(
  id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  ord INTEGER NOT NULL,
  text TEXT NOT NULL,
  token_count INTEGER NOT NULL,
  page_hint INTEGER               -- nullable, for PDF jump-to
);

CREATE VIRTUAL TABLE chunk_vec USING vec0(
  chunk_id INTEGER PRIMARY KEY,
  embedding FLOAT[768]            -- dim from selected embedding model
);

CREATE VIRTUAL TABLE chunks_fts USING fts5(
  text, chunk_id UNINDEXED, tokenize='porter unicode61'
);

CREATE VIRTUAL TABLE sources_fts USING fts5(
  title, source_id UNINDEXED, tokenize='porter unicode61'
);

notes(
  id INTEGER PRIMARY KEY,
  notebook_id INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body_md TEXT NOT NULL,
  origin TEXT NOT NULL,           -- 'manual' | 'chat' | 'transformation'
  origin_ref INTEGER,             -- message_id or transformation_run_id
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);

chat_sessions(
  id INTEGER PRIMARY KEY,
  notebook_id INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  created_at REAL NOT NULL
);

messages(
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL,             -- 'system' | 'user' | 'assistant'
  content TEXT NOT NULL,
  citations_json TEXT,            -- JSON array of {chunk_id, source_id, score}
  created_at REAL NOT NULL
);

transformations(
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  prompt_template TEXT NOT NULL,  -- Mustache-like {{source_text}} placeholder
  scope TEXT NOT NULL,            -- 'source' | 'notebook'
  is_builtin INTEGER NOT NULL
);

transformation_runs(
  id INTEGER PRIMARY KEY,
  transformation_id INTEGER NOT NULL REFERENCES transformations(id),
  source_id INTEGER REFERENCES sources(id) ON DELETE SET NULL,
  result_note_id INTEGER REFERENCES notes(id) ON DELETE SET NULL,
  ran_at REAL NOT NULL
);

app_settings(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

schema_versions(
  version INTEGER PRIMARY KEY,
  applied_at REAL NOT NULL
);
```

### Notable indexes

```sql
CREATE INDEX idx_sources_notebook ON sources(notebook_id);
CREATE INDEX idx_chunks_source ON source_chunks(source_id, ord);
CREATE INDEX idx_notes_notebook ON notes(notebook_id);
CREATE INDEX idx_messages_session ON messages(session_id, created_at);
```

## UX flows

### First launch (onboarding wizard)

1. Welcome + language confirm (auto-detected, switchable).
2. **Detect Ollama** — probe `http://127.0.0.1:11434/api/tags` (timeout 1.5 s).
   - Found → step 4.
   - Not found → open `https://ollama.com/download` in default browser, show polling spinner with "Continue once installed" button + automatic poll every 2 s.
3. **Select models** — chat model default `llama3.2:3b` (small, fast, good enough), embedding model `nomic-embed-text`. Show advanced "change models" link.
4. **Pull models** — stream `/api/pull` progress for both, dual progress bars, total ETA, cancellable.
5. Done → land on empty notebook list.

### Daily use

1. **Create notebook** — sidebar `+` → name → empty notebook opens.
2. **Add source** — drop file onto sources pane, paste URL into URL field, or paste raw text → row appears with `pending` status → background pipeline: chunk → embed → `ready`.
3. **Chat** — type question → retrieval (top-8 chunks via RRF) → streaming reply with inline numbered citations `[1]`, `[2]` → click citation opens source preview at chunk text (PDF page jump if available).
4. **Notes** — write Markdown in note editor, OR "Save as note" from chat message / transformation result.
5. **Transformation** — pick source(s) → pick template (Summary, Key points, Entities, Custom) → run → result saved as note linked to source.
6. **Settings** — language toggle, swap chat / embedding model, manage pulled models (list, pull more, delete).

## Error handling + edge cases

- **Ollama down mid-chat** → 2 reconnect attempts (exponential backoff), then inline error in chat with retry button; user's input preserved as draft.
- **Embedding-model dimension change** (user switches embedding model) → detect at startup, warn user, offer batch re-embed (background, cancellable, persistent).
- **Huge PDF (>100 MB)** → stream chunk-by-chunk, soft warning at 1 000 chunks, hard cap configurable.
- **Web URL fetch failure** → show error, allow retry or "paste raw text" fallback.
- **DB migration** — `schema_versions` table; each migration idempotent; back up file before applying.
- **Cancel in-flight pull / embed / chat** — `Task` cancellation propagates to `URLSession` task.
- **Model not pulled** when first chat → prompt user to pull, do not silently fail.

## Testing strategy

- **Unit** — `NotebookStore` with in-memory SQLite; chunker; retriever ranking; transformation prompt rendering.
- **Integration** — `OllamaClient` stubbed via `URLProtocol`; end-to-end RAG (add source → chunk → embed → query → citations) against the stub.
- **UI** — SwiftUI previews for every screen; minimal XCTest UI test for onboarding wizard.
- **Manual smoke** — live Ollama with real PDF before each release (AIGuard pattern).

## Privacy + security

- All data local (single SQLite file in app support).
- Zero network calls except `localhost:11434` (Ollama) and:
  - GitHub release check (opt-in updater, AIGuard pattern)
  - User-initiated web URL fetch for source ingestion
- CI grep gate to prevent accidental `URLSession` use in `Core` outside `OllamaClient`, mirroring AIGuard pattern.
- Code signing + notarization for DMG release.

## Localization

- EN + CS strings table, ported from AIGuard `Localization.swift`.
- System locale auto-detected on first launch (`Locale.preferredLanguages`).
- User choice persisted in `app_settings`.
- All UI strings, error messages, and transformation templates localized.

## Build + release

- Swift Package containing `AINotebookCore` + `AINotebookApp` executable + `OllamaSetupHelper` helper binary (mirrors AIGuard `AIExposureScanner` + `AIExposureUpdater` split).
- macOS 14+ deployment target.
- Universal binary (arm64 + x86_64) via Swift Package, `sqlite-vec` compiled both arches.
- CI: GitHub Actions, SHA-pinned (AIGuard pattern). Privacy grep gate scoped to `Sources/AINotebookCore` excluding `OllamaClient.swift`.
- Release: signed + notarized DMG, GitHub Releases.

## Milestones

| # | Title | Output |
|---|---|---|
| M0 | Project scaffold | `Package.swift`, app target, CI workflow, EN/CS skeleton, settings shell |
| M1 | Storage layer + notebook CRUD UI | `NotebookStore`, sidebar list, create/rename/delete |
| M2 | Ollama client + onboarding wizard | `OllamaClient`, detection, install-guide, model pull with progress |
| M3 | Ingestion pipeline | text/MD → PDF → web → Office; chunker; source list UI |
| M4 | Embedding + hybrid retriever | `Embedder`, `Retriever`, background indexing UI |
| M5 | Chat engine + citations | `ChatEngine`, streaming UI, inline citations, source preview |
| M6 | Notes + transformations | Notes editor, transformation templates, "save as note" |
| M7 | Polish + release | Full localization sweep, error states, signed DMG |
| M8 | (post-v1) Windows WPF port | Same architecture, separate codebase |

Each milestone receives its own implementation plan via `writing-plans` skill.

## Open questions (resolved during brainstorming)

- ~~Platform~~ — macOS first (SwiftUI), Windows after (WPF). Confirmed.
- ~~MVP scope~~ — notebooks + sources + chat + search + notes + transformations. Confirmed.
- ~~Storage~~ — SQLite + sqlite-vec + FTS5 (assistant's call, non-IT-friendly). Confirmed.
- ~~Ollama UX~~ — detect + guided install + auto-pull. Confirmed.
- ~~Sources~~ — PDF, plain text/Markdown, web URL, Office (docx/pptx/xlsx). Confirmed.
- ~~Localization~~ — EN + CS, locale auto-detect. Confirmed.
