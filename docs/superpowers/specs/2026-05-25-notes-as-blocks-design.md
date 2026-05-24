# Notes as Blocks — Design Spec

**Date:** 2026-05-25
**Status:** Approved — full scope
**Author:** Lukáš Oplt (with Claude)
**Target release:** v0.3.0
**Builds on:** v0.2.0

## Purpose

Promote Notes from a passive note-taking surface into the primary authoring
canvas of the app. A user opens a Notebook, picks (or creates) a Note,
edits it in a true WYSIWYG editor with attachments and inline images, sees
the live chat sidebar on the right that does RAG over **every** source +
note in the notebook (the currently-edited Note included as bonus
context), and gets free version history plus auto-save.

The notebook stays the unit of context: chat scope is per-notebook, RAG
index is per-notebook.

## Scope

### In scope (v0.3.0)

- **Notes auto-indexing** — every saved Note participates in RAG
  retrieval alongside Sources, via a hidden "shadow Source" row.
- **3-column Notes UI** — list / editor / chat sidebar, replacing the
  current 2-column Notes view.
- **Chat sidebar with current-Note bonus context** — same notebook chat
  sessions from M5, but with the currently-open Note injected into the
  system prompt as additional context.
- **WYSIWYG editor** — TipTap (ProseMirror) inside `WKWebView`, with a
  Markdown ↔ HTML bridge. Markdown remains the source of truth in the DB.
- **Attachments + inline images** — drag/drop or paste a file/image into
  the editor; file is stored locally; inline reference rendered in WYSIWYG.
- **Version history** — every save snapshots the previous body; history
  sheet lists revisions; restore creates a fresh snapshot.
- **Auto-save** — 2 s idle debounce + ⌘S explicit. Status indicator
  (Saved / Saving / Unsaved).
- **Citation popover "Open Note"** — when a chat citation resolves to a
  Note's shadow Source, popover gets a button that jumps to that Note.

### Out of scope (deferred)

- Realtime collaboration / multi-user.
- Cross-notebook RAG (per-notebook scope retained).
- Notes as PDF / Word export (Markdown export only).
- Realtime co-edit between desktop and mobile (mobile target not in v1).
- Encrypted attachments.
- OCR over image attachments.

## Architecture

```
Notebook
  ├── Sources (existing: PDF / text / web / Office — immutable)
  ├── Notes (existing → upgraded: WYSIWYG-edited + auto-indexed)
  │     │
  │     ├── (1:1) shadow Source row [type = .note]
  │     │           └── source_chunks → chunk_embeddings → RAG
  │     ├── (1:N) attachments  (files on disk)
  │     └── (1:N) note_versions (history)
  ├── Chat sessions
  └── Transformations

UI: Notes tab now 3-column
┌──────────┬─────────────────────┬──────────────┐
│  Notes   │   WYSIWYG editor    │  Chat panel  │
│  list    │   (TipTap WKWebView)│  (notebook   │
│          │                     │   sessions   │
│  + New   │   Status: Saved     │   + bonus    │
│  trash   │   History button    │   Note ctx)  │
└──────────┴─────────────────────┴──────────────┘
```

### Data flow on Note save

1. WYSIWYG → Markdown via TipTap exporter (in JS, posted back to Swift).
2. `NotebookStore.updateNote(...)` writes the notes row.
3. `NoteIndexer` actor:
   - upserts shadow Source row (`type = .note`, `title = note.title`),
   - re-chunks the new body,
   - calls `replaceChunks`,
   - kicks `EmbeddingWorker`.
4. `NoteVersionRecorder` snapshots the previous body into `note_versions`.
5. Chat sidebar's next `send` uses the latest body via `currentNoteContent`.

### WYSIWYG bridge

- The editor lives in a `WKWebView` loaded from a single static HTML
  bundle file (TipTap + minimum CSS).
- Swift → JS: `webView.evaluateJavaScript("editor.commands.setContent(...)")`
  to load initial Markdown (converted to HTML on the JS side via TipTap's
  `Markdown` extension).
- JS → Swift: a `WKScriptMessageHandler` named `aino` receives messages on
  every change. The JS posts `{ kind: "change", markdown: "..." }`.
- Swift debounces these (2 s) before persisting.
- ⌘S in Swift: send `{ kind: "save" }` via JS → JS responds with current
  Markdown immediately.

### Attachments

- Per-Note folder: `~/Library/Application Support/AINotebook/attachments/<note-uuid>/`.
- Inline images stored as files with original filename; collisions get
  `(2)` suffix.
- Markdown reference uses a custom scheme: `![alt](attachment://<note-uuid>/<filename>)`.
- WKWebView intercepts `attachment://` via a registered `WKURLSchemeHandler`
  and serves bytes from disk.
- On Note delete, the attachments folder is removed.
- Non-image attachments (PDF, txt) appear as inline link chips and open
  with the system handler when clicked.

### Version history

- Schema: `note_versions(id, note_id, title, body_md, saved_at, reason)`.
- `reason` ∈ {`autosave`, `manual`, `restore`}.
- On every successful save, the **previous** body is snapshotted before
  the new body is written. So the history shows the chain of prior
  states.
- Cap at 50 versions per Note (oldest pruned).
- History sheet: list of `saved_at + reason`, click a row → preview pane
  on the right with the snapshot's body; "Restore" button creates a new
  snapshot with the restored body.

## Modules

| Module | Purpose | Touch |
|---|---|---|
| `SourceType.note` | enum case for shadow rows | modify `SourceType.swift` |
| `MigrationV6` | `notes.auto_source_id`, `attachments`, `note_versions` | new |
| `NoteAttachment` | model + record | new |
| `NoteVersion` | model + record | new |
| `NotebookStore+Attachments` | CRUD + disk I/O | new |
| `NotebookStore+NoteVersions` | snapshot, list, restore | new |
| `NoteIndexer` actor | save → shadow Source upsert → re-chunk → kick embedder | new |
| `NoteVersionRecorder` | snapshot previous body on save | new |
| `MarkdownHTMLBridge` | JS bundle + script handlers | new |
| `NoteWYSIWYGEditor` (SwiftUI) | WKWebView wrapper + change pipe + status indicator | new |
| `AttachmentURLSchemeHandler` | serves `attachment://` to WKWebView | new |
| `NotesView` | refactor: 3-column layout with chat sidebar | modify |
| `NoteHistorySheet` | history list + preview + restore | new |
| `ChatEngine.send(...currentNoteContent:)` | extra system-prompt block | modify |
| `CitationPopover` | "Open Note" action when source.type == .note | modify |
| `NoteJumpCoordinator` | observable holding "jump to note id" intent | new |

## Data model additions

```sql
-- MigrationV6
ALTER TABLE notes ADD COLUMN auto_source_id INTEGER
    REFERENCES sources(id) ON DELETE SET NULL;
CREATE INDEX idx_notes_auto_source ON notes(auto_source_id);

CREATE TABLE attachments(
    id           INTEGER PRIMARY KEY,
    note_id      INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    note_uuid    TEXT NOT NULL,        -- stable folder name on disk
    filename     TEXT NOT NULL,
    mime         TEXT NOT NULL,
    byte_size    INTEGER NOT NULL,
    created_at   DATETIME NOT NULL
);
CREATE INDEX idx_attachments_note ON attachments(note_id);

CREATE TABLE note_versions(
    id          INTEGER PRIMARY KEY,
    note_id     INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    body_md     TEXT NOT NULL,
    saved_at    DATETIME NOT NULL,
    reason      TEXT NOT NULL          -- 'autosave' | 'manual' | 'restore'
);
CREATE INDEX idx_note_versions_note ON note_versions(note_id, saved_at);
```

A `note_uuid` column is also added to `notes` (M6 alter) so the
attachments folder name is stable through edits. Generated on Note
create (`UUID().uuidString.lowercased()`).

## UX flows

### Edit + chat
1. Open Notebook → Notes tab → 3-column layout.
2. Pick / create a Note → editor focuses, status = "Saved".
3. Type → status flips to "Unsaved" → after 2 s idle → "Saving…" →
   "Saved" (with timestamp).
4. Right pane: chat sessions sidebar (collapsed?) + active session
   transcript + input. Tokens stream as in M5.
5. Ask a question that references the open Note → chat reply may cite
   the Note's shadow Source.

### Attachments
1. Drag a PNG onto the editor or paste from clipboard.
2. File saved under `<app-support>/AINotebook/attachments/<note-uuid>/`.
3. Editor inserts `![filename](attachment://<note-uuid>/<filename>)`.
4. WYSIWYG renders the image inline via custom URL scheme.
5. Non-image (PDF, txt) → inline link chip; click opens in system app.

### Version history
1. History button in the editor toolbar → sheet opens.
2. Left: list of `<reason> · <saved_at>` rows, newest first.
3. Right: preview pane shows that version's body (read-only WYSIWYG).
4. "Restore this version" → confirmation → saves restored body as a new
   version with `reason = 'restore'`.

## Error handling

- **WKWebView load failure** → editor area shows "Editor failed to load,
  reopen Note" with a retry button.
- **Markdown↔HTML round-trip drift** → diff check after save; if HTML
  exporter loses content vs DB, warn user with toast (rare; TipTap
  Markdown extension is round-trip stable for common content).
- **Attachment file missing on disk** → image renders as a broken-link
  chip with a "remove reference" action.
- **Embed of a Note with empty body** → skip (don't write zero chunks).
- **Save while Note is being edited in WYSIWYG** → the JS save handler
  always responds with the current document snapshot; debounce + ⌘S
  share the same pipe.
- **Restore conflict** (user edits while History is open) → confirmation
  warns "you have unsaved changes — restore anyway?".

## Testing strategy

- Unit: `NoteIndexer` (in-memory store, create Note → assert shadow
  Source exists, chunks present, kick fires).
- Unit: `NoteVersionRecorder` (each save creates one row, cap respected,
  restore creates `reason = 'restore'`).
- Unit: `NotebookStore+Attachments` (create/list/delete, files appear on
  disk, cascade delete removes folder).
- Unit: `ChatEngine.send` accepts `currentNoteContent` and injects it
  into the system prompt.
- Unit: `MarkdownHTMLBridge` smoke — load fixture .md, convert to HTML,
  convert back, equal (within whitespace tolerance).
- Integration: end-to-end — create Note → type → debounce-save → chat
  question → citation resolves to Note.
- UI: SwiftUI previews of 3-column NotesView, history sheet.
- Manual smoke: drag image, restore version, citation jump-to-Note.

## Privacy + security

- All new data local (DB + attachments folder).
- WKWebView served only the bundled static HTML / JS / CSS file + the
  `attachment://` scheme — no remote network from the editor.
- `WKWebView.configuration.preferences.javaScriptEnabled = true` is
  required (TipTap is JS). No other web origins allowed
  (`WKNavigationDelegate` blocks non-bundle / non-`attachment://` loads).
- CI privacy grep gate already exempts `OllamaClient.swift` and
  `WebExtractor.swift` — no new `URLSession` in this milestone.
- Attachment files stay inside the app's Application Support; never
  uploaded.

## Build + release

- New Swift Package resource: `Sources/AINotebookApp/Resources/editor/`
  containing `editor.html`, `editor.js` (TipTap bundle), `editor.css`.
- TipTap pulled in at build time from npm via a one-shot
  `tools/macos/build-editor-bundle.sh` script that runs `esbuild`. The
  resulting bundle is committed to the repo so end users don't need npm
  to build the Swift app.
- macOS 14+ deployment target unchanged.
- DMG size impact: +~250 KB for the editor bundle. Negligible.

## Milestones

The work is decomposed into 4 sequential milestones, each shippable on
its own:

| # | Title | Output |
|---|---|---|
| M7.2 | Notes as RAG + 3-column + chat sidebar | `SourceType.note`, `NoteIndexer`, MigrationV6 partial (auto_source_id + note_uuid), 3-col `NotesView`, chat sidebar reuse, `currentNoteContent` injection, citation "Open Note" action |
| M8   | WYSIWYG editor + auto-save | TipTap bundle, `MarkdownHTMLBridge`, `NoteWYSIWYGEditor`, debounce + ⌘S, status indicator |
| M9   | Attachments + inline images | `attachments` table, on-disk folders, `AttachmentURLSchemeHandler`, paste/drag-drop, broken-link handling |
| M10  | Version history | `note_versions` table, `NoteVersionRecorder`, `NoteHistorySheet`, restore action |

Each milestone gets its own implementation plan via `writing-plans` and
its own tag (`v0.3.0`, `v0.4.0`, `v0.5.0`, `v0.6.0`). All four ship in
one push, but execution is staged so any milestone is itself a
ship-able release if work pauses.

## Open questions (resolved during brainstorming)

- ~~"Blok" semantics~~ — Notebook (no new hierarchy level).
- ~~Sources vs Notes vs new type~~ — extend Notes with auto-embedding.
- ~~Layout~~ — 3-column inside the existing Notes tab.
- ~~Chat scope~~ — per-notebook (M5 behaviour), current Note as bonus
  context.
- ~~WYSIWYG vs Markdown~~ — WYSIWYG editor, Markdown source of truth.
- ~~Attachments storage~~ — files on disk, DB tracks metadata.
- ~~Version history~~ — every save creates a snapshot, cap 50.
- ~~Auto-save~~ — 2 s idle debounce + ⌘S manual.
- ~~Scope split~~ — 4 sub-milestones, all ship in this release cycle.

## Notes for implementers

- **Editor bundle vendoring:** TipTap + ProseMirror + the Markdown
  extension. Use `@tiptap/core`, `@tiptap/starter-kit`, `@tiptap/extension-image`,
  and a Markdown converter such as `tiptap-markdown`. Build once with
  esbuild → ~150 KB minified → commit `editor.js` + `editor.html` so end
  users don't run npm.
- **Markdown round-trip stability:** TipTap's Markdown extension is
  stable for headings, lists, links, code, images. Tables round-trip but
  re-format. For v0.3 we accept minor whitespace drift; a `markdown
  diff` log is shown in debug builds.
- **Embedding hot-path:** auto-save fires the indexer on every save.
  The `EmbeddingWorker.kick()` is debounced internally (M4) so a fast
  typer doesn't spam Ollama.
- **Shadow Source UI invisibility:** `SourceListView` filters
  `type != .note` so users never see the shadow rows in the Sources
  pane. Retriever doesn't filter — Notes show in citation results.
- **Citation "Open Note":** uses a new `NoteJumpCoordinator`
  ObservableObject. The popover sets `coordinator.target = noteId`;
  `NotesView` observes and updates `selection`.
- **WKWebView memory:** the editor instance is per-NotesView, not
  per-Note. Switching Notes calls `editor.commands.setContent(...)`;
  no view reload.
- **Forward compat:** `note_uuid` is generated on Note create (a
  one-shot backfill migration covers existing Notes from v0.2.0).
