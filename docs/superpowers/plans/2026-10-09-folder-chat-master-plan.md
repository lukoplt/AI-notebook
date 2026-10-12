# Folder chat + multilingual RAG + context pack — master plan (WP0–WP9)

> **For agentic workers:** This is the release-level plan. Each WP gets its own detailed TDD plan (`docs/superpowers/plans/2026-10-09-wpN-*.md`) written **when its dependencies are frozen** — WP1–WP9 code depends on names, schemas and constants that WP0 decides, so writing their step-level code now would be guesswork. Execute each detailed plan with superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** One release delivering persisted folder sources, cs/sk/en/de language detection, scoped multilingual RAG with index generations, provider fixes, and a context pack that lets local models answer from retrieved evidence.

**Architecture:** All logic in Core on both platforms (`Sources/AINotebookCore`, `windows/src/AINotebook.Core`), TDD, shared JSON fixtures under `Tests/fixtures/` consumed by both test suites. Native pickers, watchers and UI in the App layers. Claude owns Swift + both UIs + contracts; Codex owns Windows Core + its tests + the detector training script.

**Tech Stack:** Swift 6 / SwiftUI / GRDB (macOS 14+); .NET 10 / WinUI 3 / Microsoft.Data.Sqlite + Dapper (Windows); SQLite FTS5; Ollama + OpenAI/Anthropic/OpenAI-compatible/OpenWebUI providers; Python 3 for `tools/lang/`.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md`

## Global Constraints

- Parity: every Core behaviour exists on both platforms with the same shared fixtures.
- Next schema migration is **v19 on both platforms**; never amend a shipped migration.
- One version bump at the end (WP9): `VERSION` + `Sources/AINotebookCore/AINotebookVersion.swift` + `windows/src/AINotebook.Core/AINotebookVersion.cs` + `CHANGELOG.md` — guard tests fail CI if they diverge.
- Windows store: every `SqliteConnection` access goes through `lock (_gate)`.
- Unpackaged Windows app: no `Windows.Storage.ApplicationData` / `Package.Current`.
- Networking code only in files allowlisted by the privacy-grep job (`.github/workflows/core-ci.yml`: `Providers/`, `OllamaClient.swift`, `WebExtractor.swift`, …); new networking goes under `Providers/`.
- No extraction, embedding or detection inside migrations.
- Empty retrieval selection returns zero results, never the whole notebook.
- WP0 freezes contract structure and the initial parameter set (`Tests/fixtures/contracts/constants-v1.json`); WP4/WP7 may jointly supersede tuning values via a versioned `constants-v2.json` before release.
- Codex runs with `-c 'model="gpt-6-astra"'` in its own git worktree, touching only the paths its tasks list (Windows code, detector appendix/fixtures, `tools/lang/`); merged by Claude after review.

## Collaboration protocol (Claude ↔ Codex)

1. Claude writes the WP's detailed plan; Codex reviews it (consult, read-only) before execution.
2. Codex implements its share in worktree `../AI_Notebook-codex` on branch `wpN-codex` (`codex exec -s workspace-write -C ../AI_Notebook-codex`), with the WP plan's Windows tasks as its prompt. It must run `dotnet test windows/tests/AINotebook.Core.Tests` green before handing back.
3. Claude implements Swift/UI on `feat/folder-chat-multilingual-rag`.
4. Cross-review: Claude reviews Codex's diff, Codex reviews Claude's diff (`codex review` / consult). Findings fixed by the owner.
5. Claude merges `wpN-codex` into the feature branch; both suites green → WP gate passed.

## Work packages

| WP | Depends on | Deliverable (gate) | Owner split | Detailed plan |
|---|---|---|---|---|
| WP0 Contracts | — | `docs/contracts/folder-rag-v1.md`, `docs/contracts/lang-detector-v1.md`, `Tests/fixtures/contracts/*.json`; contract types (constants, `RetrievalScope`, citation v2 codec) on both platforms green against shared fixtures; FTS query section provisional until WP5 | Claude drafts + Swift; Codex detector appendix + C# + review | `2026-10-09-wp0-contracts.md` — **DONE 2026-10-09** (merge `codex/wp0fix`; Swift 381 / .NET 459 green) |
| WP1 Eval assets | WP0 | `eval/multilingual/` corpus + queries + labels; fixture validators both platforms | joint; Codex validators, Claude Swift eval runner | written after WP0 |
| WP2 Providers/options | WP0 | API-root table green; Windows routing in Core; fixes; presets; manual model id; `provider_model_limits` usage; `num_ctx`/output limit on the wire; wire role/order fixtures | Codex C#; Claude Swift + both UIs | after WP0 |
| WP3 Storage v19 | WP0 | v19 migration both platforms; v18 upgrade test; legacy generations; FTS rebuild; citations v2 persistence | each own platform; joint schema review | after WP0 |
| WP4 Language detector | WP0, WP1 | `tools/lang/train_detector.py`, `lang-detector-v1.json` + manifest + attribution; runtimes bit-identical on fixtures | Codex script + C#; Claude Swift | after WP1 |
| WP5 Retrieval | WP2, WP3 | FTS token query, ScopeResolver, fetchK candidate pool, vector cache with mask, heap top-K, full-text hydration, revision GC | both | after WP3 |
| WP6 Folder ingestion | WP3, WP4 | scanner + `scan_items`, reconciliation, `ingest_jobs`, encodings, descriptors, spans, XLSX, generation lifecycle, chat priority; pickers/watchers/UI | both Core; Claude native + UI; Codex Windows FS tests | after WP4 |
| WP7 Benchmark + default model | WP1, WP2, WP5 (+WP6 output) | `docs/eval/README.md` updated with multilingual numbers and the chosen default embedder/dims | joint; Claude Mac, Codex Windows runner | after WP5 |
| WP8 Context pack | WP0 (builder), WP2/5/6 (integration) | `ContextPackBuilder` both platforms green on golden fixtures; chat integration, preview, Overview mode | both builder; Claude integration + UI | builder plan right after WP0 |
| WP9 Integration + release | WP4–WP8 | folder management UI, coverage, re-index UI; upgrade/restart/cancel tests; eval + perf gates; Windows smoke; version bump; CHANGELOG; roadmap | both, cross-review | after WP8 |

**Parallel lanes after WP0:** WP1 ∥ WP2 ∥ WP3 ∥ WP8-builder → WP4 (after WP1) → WP5 (after WP2+WP3) → WP6 (after WP3+WP4) → WP7 → WP8-integration → WP9.

## Release gates (WP9)

- `swift test` and `dotnet test windows/tests/AINotebook.Core.Tests` green; Windows CI (build + App tests + smoke) green; privacy-grep green.
- Real v18 DB upgrades cleanly on both platforms.
- Multilingual eval: packed-evidence recall and detector metrics meet the targets frozen in WP0.
- Performance gate (WP0-frozen) met on reference hardware for both platforms, or a jointly documented exception.
- Manual Windows scenario recorded: add folder → restart/reconcile → chat → citation → switch provider.
