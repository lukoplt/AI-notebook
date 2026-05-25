# M11: Transformations UX Overhaul — Design Spec

**Date:** 2026-05-25
**Status:** Approved
**Author:** Lukáš Oplt (with Claude)
**Target release:** v0.7.0
**Builds on:** v0.6.0

## Purpose

The current Transformations tab works but is opaque: users see three
pickers and a Run button with no explanation of what a transformation
is, what built-in templates do, where results go, or how to re-find
them. Rename and rebuild the tab around the actual mental model: "AI
tools that turn a source (or whole notebook) into a saved note."

## Scope

### In scope (v0.7.0)

- **Rename** UI label "Transformace" → "AI nástroje" (CS) / "AI tools" (EN).
- **Description column** on `Transformation` model + visible
  one-line description under each template name.
- **Empty state with explainer** when no template has been run yet,
  describing what AI tools do.
- **Run result toast** with explicit "Open note" CTA that jumps to
  the saved Note (uses existing `NoteJumpCoordinator` + a new
  tab-switch coordinator).
- **Tooltips / hints** under Scope picker explaining Source vs
  Notebook behaviour.
- **Prompt preview sheet** — eye icon next to template picker shows
  the rendered prompt with `{{source_text}}` interpolated.
- **History sheet** — list of `transformation_runs` for the current
  notebook, click row → opens the result note.
- **Czech-translated built-in prompts** — locale-aware seed of
  Summary / Key points / Entities + a fourth built-in
  "Action items".
- **Batch apply** — "Run on all sources" checkbox that fans out a
  source-scope template across every notebook source.
- **Built-in description seeding** — built-ins ship with descriptions
  populated.

### Out of scope (deferred)

- Custom template marketplace / import-export.
- Per-run cost reporting.
- Cancellable runs (current engine reads stream to completion).
- Multi-template pipelines (run A, feed into B).

## Architecture

```
Transformations tab ("AI tools")
  ┌─────────────────────────────────────────────────────────┐
  │ Header: "AI nástroje"  [History]  [Edit templates]     │
  ├─────────────────────────────────────────────────────────┤
  │ Template:  [▼ Summary]  👁(preview)                     │
  │ Description: "3–5 bullet summary of a source."          │
  ├─────────────────────────────────────────────────────────┤
  │ Scope:  [Source • Notebook • All sources]  (segmented)  │
  │ Source: [▼ My PDF]  (disabled for Notebook/All)         │
  │                                            [Run]        │
  ├─────────────────────────────────────────────────────────┤
  │ Empty state with explainer OR running progress OR       │
  │ Result body (streamed) + "✓ Saved as note 'X'  [Open]" │
  └─────────────────────────────────────────────────────────┘
```

A new `TabSwitchCoordinator` (`ObservableObject`) lets the "Open note"
button switch the NotebookDetailView's `selectedTab` from
`.transformations` to `.notes`, then publish the target note id via
the existing `NoteJumpCoordinator`.

## Modules

| Module | Purpose | Touch |
|---|---|---|
| `MigrationV9` | `transformations.description` column + backfill for builtins | new |
| `Transformation` | add `description: String` | modify |
| `NotebookStore+Transformations` | `createTransformation(... description:)` + `updateTransformation(... description:)` | modify |
| `BuiltinTransformations` | descriptions + a new "Action items" template; locale-aware seeding (`seedIfNeeded(_:language:)`) | modify |
| `TabSwitchCoordinator` | App-layer observable: `target: NotebookDetailView.Tab?` | new |
| `TransformationsView` | full rewrite: explainer, description display, prompt preview, batch picker, toast, History entry point | rewrite |
| `TransformationPromptPreviewSheet` | sheet showing rendered prompt | new |
| `TransformationHistorySheet` | sheet listing runs with jump-to-note | new |
| `TransformationEditorSheet` | accept description field | modify |
| `Localization` | ~12 new EN/CS keys | modify |
| `NotebookDetailView` | wire `TabSwitchCoordinator` to mutate `selectedTab` | modify |
| `AINotebookApp` | inject `TabSwitchCoordinator` | modify |

## Data model change

```sql
-- MigrationV9
ALTER TABLE transformations ADD COLUMN description TEXT NOT NULL DEFAULT '';
```

Built-in seed runs after migration; rows whose `name` matches a
built-in get their description populated if currently empty.

The `transformation_runs` table from M6 stays unchanged — already
carries `transformation_id`, `source_id`, `result_note_id`, `ran_at`.

## UX flows

### First-time empty state

User opens the tab. No runs yet → centred panel:

> **AI nástroje**
> Vyber šablonu, vyber zdroj, klikni Spustit. Výsledek se uloží jako
> nová poznámka v notebooku.
>
> [Try "Summary" on the first source ▷]

### Running a template

1. Pick template → description appears underneath name.
2. (Optional) Click 👁 → sheet shows rendered prompt with current
   source text interpolated.
3. Scope: Source / Notebook / All sources (segmented).
4. Pick source (or disabled for non-source scope).
5. Run → streamed result fills lower pane.
6. On finish → green toast: "Uloženo jako poznámku 'Summary — My
   PDF'  [Otevřít poznámku]".
7. Click "Otevřít poznámku" → switches to Notes tab, selects the new
   Note, scrolls into view.

### History

1. Click "History" in header → sheet opens.
2. List of runs (newest first), grouped by template name. Each row:
   timestamp, source name (or "(notebook scope)"), result note title.
3. Click row → close sheet + switch to Notes tab + select that note.

### Batch — "All sources"

1. Scope = "All sources" → Source picker hides.
2. Run → engine iterates each notebook source in order, producing one
   Note per source. Progress: "Running 3/12…".
3. On finish → toast: "Uloženo 12 poznámek  [Open Notes]".

## Built-in templates (final list with descriptions)

| Name (EN) | Name (CS) | Description (EN) | Description (CS) |
|---|---|---|---|
| Summary | Souhrn | "3–5 bullet summary of a source." | "Shrnutí zdroje do 3–5 odrážek." |
| Key points | Klíčové body | "5–10 most important takeaways." | "5–10 nejdůležitějších bodů." |
| Entities | Entity | "People, organizations, places, dates." | "Lidé, organizace, místa, data." |
| Action items | Úkoly | "Concrete next-step actions found in the text." | "Konkrétní úkoly nebo akce zmíněné v textu." |

Czech-language Notebooks get the CS-named built-ins. Switching app
language post-creation does **not** rename existing built-in rows;
new built-in rows are added with the active language's names. This
matches the M2 onboarding model-pull behaviour (set-once at seed time).

## Error handling

- **Batch with no sources** → disabled Run button + hint "Add a
  source first".
- **Batch partial failure** → individual source errors logged in a
  collapsible row in the toast; successful notes already saved.
- **Migration on existing DB** → `ALTER TABLE … DEFAULT ''` is safe;
  seeding then populates built-in descriptions.
- **History sheet jump to deleted note** → row shows "(deleted)" and
  is not clickable.

## Testing strategy

- Unit: `MigrationV9` (column exists, defaults to empty string).
- Unit: `BuiltinTransformations.seedIfNeeded(db: language:)` —
  English seeds English-named rows; Czech seeds Czech-named rows;
  re-running is idempotent.
- Unit: `NotebookStore+Transformations` — description round-trips
  through `create` / `update` / `fetch`.
- Unit: Engine batch — `runOnAllSources(transformationId:notebookId:)`
  returns count of notes created.
- UI: tab switch via `TabSwitchCoordinator` flips
  `NotebookDetailView.selectedTab`.

## Privacy + security

No new I/O surfaces. All work stays local. Built-in prompts unchanged
in content — only display name + description gets a Czech variant.

## Build + release

No new SPM resources or build steps. Migration runs on launch.
DMG size unchanged.

## Milestones

Single milestone (M11) — one plan, one PR, one tag. Tagged
**v0.7.0**.

## Open questions (resolved during brainstorming)

- ~~Rename label~~ — confirmed "AI nástroje" / "AI tools".
- ~~Result location explicit~~ — toast + History sheet, confirmed.
- ~~Czech prompts~~ — locale-aware seed at first launch; existing
  rows untouched on language change.
- ~~Batch~~ — segmented control "Source / Notebook / All sources",
  confirmed.
