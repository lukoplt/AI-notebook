# UI Redesign (Codex style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild both apps' UI as a chat-first, Codex-style workspace (sidebar notebooks→chats, centered conversation with a composer card, right panel Sources/Notes/Context/Citations, full Settings) without changing Core behaviour.

**Architecture:** Shared design tokens and a shared `MarkdownLite` parser live in versioned fixtures and are implemented identically on both platforms; each platform then gets a new shell, chat surface, right panel, document view and settings built from small focused components. Existing view models/Core services are reused; macOS `ChatView` state moves into a testable `ChatViewModel` first.

**Tech Stack:** SwiftUI (macOS 14+, `NavigationSplitView`, `.inspector`, `Settings` scene), WinUI 3 / WASDK 1.8 (.NET 10), Python 3 fixture generators, XCTest / xUnit.

**Spec:** `docs/superpowers/specs/2026-10-10-ui-redesign-codex-style-design.md`

## Global Constraints

- Core behaviour unchanged (only additions: `MarkdownLite`, token parity tests). All existing Core tests stay green.
- Parity: same IA, same strings (EN + CS), same tokens on both platforms.
- Tokens exactly as spec §3; no hard-coded colours in views (use tokens); icons SF Symbols / `Segoe Fluent Icons` only.
- Windows: every `SqliteConnection` access inside `lock (_gate)`; unpackaged app (no `Windows.Storage.ApplicationData` / `Package.Current`); code-behind resources via `Application.Current.Resources[...]`.
- Windows resource keys: new keys inserted BEFORE `providerPresetLabel` in both `.resw` (Swift `ProviderLocalizationTests` relies on it); keep `LocalizedStringsTests` key count exact; every key also in `StringKey.cs`.
- macOS strings: new `AppText.Key` cases with EN + CS in `Sources/AINotebookCore/Localization.swift`; `LocalizationTests` must pass.
- Windows App can't build on macOS: keep XAML careful, verify view models with App.Tests (compiled in a net10.0 scratch harness if needed), mark XAML as CI-unverified.
- No push / PR / tag. Commit per task; trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Gates per task: `swift test`, `swift build --product AINotebookApp`, `dotnet test windows/tests/AINotebook.Core.Tests`, all generator `--check` (`tools/contracts/gen_*.py`, `tools/eval/gen_eval_fixtures.py`).

## File Structure (new)

| Path | Responsibility |
|---|---|
| `docs/design/tokens-v1.md` | human-readable tokens + icon map (spec §3) |
| `Tests/fixtures/contracts/ui-tokens-v1.json` | machine tokens (colours light/dark, type ramp, spacing, radii, sizes) |
| `Tests/fixtures/contracts/markdown-lite-v1.json` + `tools/contracts/gen_markdown_fixtures.py` | Markdown cases + reference parser |
| `Sources/AINotebookCore/MarkdownLite.swift`, `windows/src/AINotebook.Core/Text/MarkdownLite.cs` | parser → `[MarkdownBlock]` |
| `Sources/AINotebookApp/Design/*` | `DesignTokens`, `ChipButton`, `IconButton`, `ComposerView`, `SidebarRow`, `PanelSegmentedControl`, `MarkdownView`, `HoverActions` |
| `Sources/AINotebookApp/Shell/*` | `AppShellView` (3-col split), `SidebarView` (rewrite), `TopBar`, `RightPanelView`, `EmptyStates` |
| `Sources/AINotebookApp/Chat/*` | `ChatViewModel` (from ChatView state), `ChatThreadView`, `MessageRow`, `ComposerChips`, `ScopePopover`, `PersonaMenu`, `ModelMenu` |
| `Sources/AINotebookApp/Panels/*` | `SourcesPanel`, `NotesPanel`, `ContextPanel`, `CitationsPanel` |
| `Sources/AINotebookApp/Document/NoteDocumentView.swift` | note editor in main area + PDF export |
| `Sources/AINotebookApp/Settings/*` | `SettingsWindowView` + section views (General, Providers, ModelsLimits, Indexing, Tools, About) |
| `windows/src/AINotebook.App/Styles/Tokens.xaml`, `Styles/Controls.xaml` | tokens + control styles |
| `windows/src/AINotebook.App/Shell/*` | `ShellPage` rewrite (sidebar groups / main Frame / right panel), `TopBar` |
| `windows/src/AINotebook.App/Chat/*`, `Panels/*`, `Document/*`, `Settings/*` | mirrors of the macOS structure |

## Tasks

### Phase A — foundations (A1 first, then A2 ∥ A3)

### Task A1: [Shared] Tokens + MarkdownLite fixtures and reference

**Files:** Create `docs/design/tokens-v1.md`, `Tests/fixtures/contracts/ui-tokens-v1.json`, `tools/contracts/gen_markdown_fixtures.py`, `tools/contracts/test_markdown_fixtures.py`, `Tests/fixtures/contracts/markdown-lite-v1.json`.

**Interfaces — Produces:**
- `ui-tokens-v1.json`: `{"contract":"ui-tokens","version":1,"colors":{"bg":{"light":"#FFFFFF","dark":"#1E1E1E"}, …all 14 tokens from spec §3…},"type":{"title":{"size":20,"line":28,"weight":"semibold"},"headline":{…15/22 semibold},"body":{"size":14,"line":22,"lineWindows":20},"message":{15/24},"caption":{12/16},"mono":{13/20}},"spacing":[4,8,12,16,24,32],"radius":{"sm":6,"md":10,"lg":16,"pill":999},"size":{"sidebarRow":30,"topBar":44,"hitMin":28,"primaryHitMin":32,"conversationMax":760,"sidebarMin":240,"sidebarMax":300,"panelMin":320,"panelMax":420}}` (envelope test: no `cases`, like constants-v1).
- Markdown block model (JSON = what both platforms must produce): `[{ "type":"paragraph"|"heading"|"list"|"quote"|"code"|"rule", "level"?:1-3, "ordered"?:bool, "items"?:[[inline…]] (nested lists as item {"inlines":[…],"children":[items]}), "inlines"?:[{"t":"text","v":"…"}|{"t":"strong","c":[…]}|{"t":"em","c":[…]}|{"t":"code","v":"…"}|{"t":"link","href":"…","c":[…]}|{"t":"cite","n":12}], "text"?: "…code…" }]`.
- Rules (normative, in the generator docstring + tokens doc): line-based block parse; `#`,`##`,`###` + space → heading; `- `/`* `/`+ ` → bullet, `\d+. ` → ordered; 2–3 leading spaces → nested (max 2 levels); `> ` → quote (inline content); ```` ``` ```` fences (unterminated fence = code to end); `---`/`***` alone → rule; blank line separates paragraphs; consecutive non-blank lines join with a single space. Inline: `**x**` strong, `*x*`/`_x_` em (no intraword `_`), `` `x` `` code (no nesting), `[text](url)` link only if url scheme ∈ {http, https, mailto} else literal text, `[N]` (1–3 digits, not followed by `(`) → cite; unterminated markers render literally; no HTML (`<b>` stays text); tables → paragraphs.
- ≥ 45 cases incl. CZ/SK diacritics, streaming prefixes (same text truncated at 10 points must never throw and must equal parse of that prefix), `[12]` vs `[12](https://x)`, `javascript:` link → text, nested list, unterminated `**` and fence.

- [ ] Write `tools/contracts/test_markdown_fixtures.py` (unittest: envelope, unique names, generator `--check`, reference parser determinism) → run → FAIL (missing generator).
- [ ] Implement reference parser + case table in `gen_markdown_fixtures.py` (`--check` mode like the other generators) → run tests → PASS.
- [ ] Write tokens JSON + `docs/design/tokens-v1.md` (values verbatim from spec §3, plus icon map: newChat `square.and.pencil`/E70F… list every icon used by later tasks with SF Symbol + Fluent glyph).
- [ ] `swift test --filter SharedFixturesTests` and `dotnet test … --filter SharedFixtures` (envelope) → PASS. Commit.

### Task A2: [Swift] `MarkdownLite` + `DesignTokens` parity
**Files:** Create `Sources/AINotebookCore/MarkdownLite.swift`, `Tests/AINotebookCoreTests/MarkdownLiteTests.swift`, `Sources/AINotebookApp/Design/DesignTokens.swift`, `Tests/AINotebookCoreTests/UITokensTests.swift` (tokens values duplicated as a Core `UITokensV1` enum in `Sources/AINotebookCore/UITokensV1.swift`, which `DesignTokens` maps to SwiftUI `Color`/`Font`, so the parity test runs in Core).
**Produces:** `public enum MarkdownBlock: Equatable`, `public indirect enum MarkdownInline: Equatable`, `public enum MarkdownLite { static func parse(_ text: String) -> [MarkdownBlock] }`; `public enum UITokensV1` (hex strings per token light/dark, sizes); `DesignTokens.color(.text1)`, `.font(.message)`, `.radius(.lg)`, `.spacing(n)`.
- [ ] Failing tests: every `markdown-lite-v1.json` case (decode expected JSON into the enums), every token value vs `ui-tokens-v1.json` → FAIL. Implement → PASS. Commit.

### Task A3: [Windows] `MarkdownLite` + tokens parity
**Files:** Create `windows/src/AINotebook.Core/Text/MarkdownLite.cs`, `windows/src/AINotebook.Core/Text/UITokensV1.cs`, tests `windows/tests/AINotebook.Core.Tests/Text/MarkdownLiteTests.cs`, `UITokensTests.cs`; create `windows/src/AINotebook.App/Styles/Tokens.xaml` (ThemeDictionaries Light/Dark with `SolidColorBrush` per token, `x:Double`/`CornerRadius`/`Thickness` resources) and merge it in `App.xaml`.
**Produces:** `MarkdownLite.Parse(string) -> IReadOnlyList<MarkdownBlock>` (records mirroring Swift), `UITokensV1` constants; XAML keys `Bg`, `BgSidebar`, `Surface1`, `Surface2`, `Border`, `Text1`, `Text2`, `Text3`, `Accent`, `OnAccent`, `Focus`, `Success`, `Warning`, `Danger` (+`Brush` suffix), `RadiusSm/Md/Lg/Pill`, `Space4…Space32`.
- [ ] Failing tests (all fixture cases; tokens parity incl. a test that parses `Tokens.xaml` as XML and compares brush colours to `ui-tokens-v1.json`) → FAIL → implement → PASS. Commit.

### Phase B — macOS (B1 → B2 → B3 → {B4, B5, B6, B7} → B8)

### Task B1: [Swift] Extract `ChatViewModel` (no visual change)
**Files:** Create `Sources/AINotebookApp/Chat/ChatViewModel.swift` (`@MainActor @Observable final class`), move logic from `ChatView.swift` (session list/CRUD, persona/scope state, prepare/preview cache with `draftGeneration`/`prepareTask`, send/regenerate/edit, follow-ups, error mapping via `providerErrorText`); `ChatView.swift` becomes a thin view over it. Tests: `Tests/AINotebookCoreTests` cannot import App — move pure state logic that needs tests into Core `Sources/AINotebookCore/ChatSessionState.swift` (session ordering, stale-preview key rules) with `ChatSessionStateTests.swift`.
**Acceptance:** app behaviour identical (manual: send, regenerate, edit, preview, scope, persona); all tests green; `ChatView.swift` < 300 lines.
- [ ] Tests for extracted Core state first → implement → refactor view → build + tests. Commit.

### Task B2: [Swift] Design components
**Files:** `Sources/AINotebookApp/Design/{ChipButton,IconButton,ComposerView,SidebarRow,PanelSegmentedControl,MarkdownView,HoverActions,EmptyStateView}.swift`.
**Produces:** `ChipButton(title:systemImage:action:)` (pill, surface-2, caption); `IconButton(systemImage:label:action:)` (28pt, hover bg surface-2, accessibility label required); `ComposerView(text:Binding<String>, placeholder:, isSending:, leading: some View, trailing: some View, onSubmit:)` (card radius lg, 1–8 lines, Enter submits, Shift+Enter newline, focus shadow); `SidebarRow(title:systemImage:isSelected:trailing:)`; `PanelSegmentedControl(selection:items:)`; `MarkdownView(blocks:[MarkdownBlock], onCite:(Int)->Void)` (renders all block types with tokens; `cite` as inline pill button); `HoverActions` (row of IconButtons shown on hover, always visible for VoiceOver); `EmptyStateView(title:subtitle:actions:)`.
**Acceptance:** `#Preview`s for each in light/dark; build green.

### Task B3: [Swift] Shell: sidebar, top bar, inspector panel, navigation state
**Files:** Create `Shell/AppShellView.swift`, `Shell/SidebarView.swift` (replaces root `SidebarView.swift` — delete old), `Shell/TopBar.swift`, `Shell/RightPanelView.swift` (hosts segments; content views come from B5 — use placeholders `Text` only until B5 lands in the same lane order), `Shell/NavigationState.swift` (`@Observable`: `selection: .chat(notebookId, sessionId) | .note(notebookId, noteId) | .newChat(notebookId?) | .settings`, `rightPanel: Segment?`). Modify `ContentView.swift` (use `AppShellView`; remove tab picker), `AINotebookApp.swift` (add `Settings` scene placeholder → B7; ⌘N new chat, ⌘K search, ⌘[ back, ⌘0 toggle panel). Delete `NotebookDetailView.swift` after its menu actions move into the sidebar notebook context menu (Instructions popover, Export ZIP, Backup/Restore, Rename, Delete). Map `TabSwitchCoordinator` requests: `.sources` → panel Zdroje, `.notes` → panel Poznámky, `.chat` → current thread, `.transformations` → open "+ Spustit nástroj" sheet.
**Acceptance (manual):** sidebar shows notebooks as collapsible groups with ≤8 chats + "Show more"; new chat; rename/delete chat; notebook menu actions all work; update indicator at sidebar bottom replaces `UpdateBanner`; global search still jumps to notes/sources.

### Task B4: [Swift] Chat thread + composer
**Files:** `Chat/ChatThreadView.swift`, `Chat/MessageRow.swift`, `Chat/ComposerChips.swift`, `Chat/ScopePopover.swift` (from ChatView scope UI), `Chat/PersonaMenu.swift`, `Chat/ModelMenu.swift`, `Chat/NewChatEmptyState.swift`; delete `MessageBubble.swift`, slim `ChatView.swift` into `ChatThreadView`.
**Acceptance:** spec §2.2 exactly: user block right / assistant markdown no bubble / cite pills open Citations panel on that citation / hover actions (copy, regenerate menu incl. "with provider…", save as note, sent context → Context panel) / edit last user message / streaming / error row with retry (localized) / follow-up chips / composer "+" menu items (file, folder, URL, web search toggle (only if enabled in settings), overview toggle, run tool ▸, new note) / scope, persona (hidden if none), model chips / preview eye → Context panel / send ↑ / new-chat empty state with notebook picker.

### Task B5: [Swift] Right panel segments
**Files:** `Panels/SourcesPanel.swift` (rework of `SourceListView.swift` into compact panel; keep `FolderSourcesModel`, `AddSourceSheet`, `SourcePreviewSheet`, `FolderRulesSheet`; folder row = icon, name, one summary line, `…` menu; bulk + tag filter in panel `…` menu; drag&drop on panel), `Panels/NotesPanel.swift` (list from `NotesView.swift` list column + search + tags + new; click → `.note` selection), `Panels/ContextPanel.swift` (wraps `ContextPreviewPanel` restyled; draft vs sent), `Panels/CitationsPanel.swift` (from `CitationPopover`, list of current answer citations, focused one scrolled to). Delete `CitationPopover.swift` usage from chat.
**Acceptance:** all Sources features from today reachable (add file/folder/URL/text, scan, verify, rules, watch, remove, bulk, tags, preview, re-crawl, grouping/paging); notes search + tags on mac (new parity); citations "Open original" containment messages unchanged.

### Task B6: [Swift] Note document view + PDF export
**Files:** `Document/NoteDocumentView.swift` (from `NoteWYSIWYGEditor` + top bar title/status/History/Export), keep `EditorWebView`; PDF export via `WKWebView.createPDF` → save panel (roadmap M-2); right-panel segment "Chat k poznámce" (hosts `NotesChatPanel`) visible only in document mode. Delete `NotesView.swift` three-column layout and unused `NoteEditor.swift`.
**Acceptance:** open/edit/save/autosave/history/export MD/export PDF; unsaved-changes guard when navigating away; notes chat works.

### Task B7: [Swift] Settings window + tools
**Files:** `Settings/SettingsWindowView.swift` + `Settings/{GeneralSection,ProvidersSection,ModelsLimitsSection,IndexingSection,ToolsSection,AboutSection}.swift` split from `SettingsView.swift` (677 lines; delete it), `AINotebookApp.swift` `Settings { SettingsWindowView() }` + sidebar Settings opens it (`openSettings`). `ToolsSection` hosts `TransformationEditorSheet` content inline. "+ › Spustit nástroj" → `RunToolSheet.swift` (from `TransformationsView.swift`: template, scope, source; result saved as note; open it) ; history → `NotesPanel` "Historie nástrojů" (reuse `TransformationHistorySheet`). Delete `TransformationsView.swift`.
**Acceptance:** every setting from today present (language, providers CRUD + privacy gate, chat model + discovery + manual id, limits, embedding + reindex progress Retry/Discard + dual-space note + conversion notice, web search, auto-update + check now, version, credits); transformations: run, edit templates, history, prompt preview.

### Task B8: [Swift] Onboarding restyle, l10n cleanup, literals
**Files:** `Onboarding/*` restyled with tokens (centered card 520, monochrome primary); `Localization.swift` new keys (EN/CS) for every new string from B3–B7; remove dead keys; fix literals (AddSourceSheet:79, SourcePreviewSheet:81-89, ChatView:805, NotesChatPanel:180, CitationPopover "s."). Update `LocalizationTests` expectations.
**Acceptance:** no user-visible English in CS mode; tests green.

### Phase W — Windows (W1 → W2 → {W3…W7} → W8), mirrors Phase B

### Task W1: [Windows] Styles + Mica + shell
**Files:** `Styles/Controls.xaml` (ChipButton, IconButton, Composer, SidebarItem, PanelSegment styles using Tokens.xaml; every icon-only control sets AutomationProperties.Name), `MainWindow.xaml(.cs)` (MicaBackdrop; remove MenuBar → move Save/History to document top bar shortcuts), `Shell/ShellPage.xaml(.cs)` rewrite (sidebar: New chat, Search → `GlobalSearchDialog` (wire Ctrl+K), notebooks as expandable groups with chats via `TreeView` or grouped `ListView`, + New notebook, Settings, update indicator; main `Frame`; right panel column with resize + segments), `Shell/NavigationState.cs` (same states as Swift B3), delete `NotebookDetailPage` after moving its notebook actions into the notebook context menu (Instructions dialog, Export ZIP, Backup/Restore, Rename, Delete).
**Acceptance:** same as B3; App.Tests: replace `NotebookTabCompositionTests` with `ShellNavigationTests` over `NavigationState` + TabSwitchCoordinator mapping.

### Task W2: [Windows] Chat thread + composer
**Files:** `Chat/ChatThreadPage.xaml(.cs)` (replaces `ChatPage`), `Controls/MessageRow.xaml(.cs)` (replaces `MessageBubble`; markdown via `RichTextBlock` built from `MarkdownLite` blocks in a `MarkdownRenderer.cs`), composer with chips + "+" `MenuFlyout`, scope/persona/model flyouts, hover actions, new-chat empty state. Keep `ChatViewModel` API; add what the composer needs. Update `FolderScopeBindingTests` XAML greps to the new file and element names (keep same bindings semantics: WholeNotebook/SelectedItems radios, Folder/Set/Source lists, apply set).
**Acceptance:** same as B4.

### Task W3: [Windows] Right panel segments
**Files:** `Panels/SourcesPanel.xaml(.cs)` (from `SourceListPage`, compact rows, `…` menus; keep `SourcesViewModel` + row template selector), `Panels/NotesPanel.xaml(.cs)`, `Panels/ContextPanel.xaml(.cs)`, `Panels/CitationsPanel.xaml(.cs)`. Update `FolderSourcesTests` (fix the already-stale `FolderRows` assertion to `Rows`, new file paths, handler names).
**Acceptance:** same as B5.

### Task W4: [Windows] Note document + settings page + tools
**Files:** `Document/NoteDocumentPage.xaml(.cs)` (EditorWebView + top bar Save/History/Export MD/PDF; Ctrl+S, Ctrl+Shift+H), `Settings/SettingsPage.xaml(.cs)` with `NavigationView`-free left section list (General, Providers, ModelsLimits, Indexing, Tools, About) replacing `SettingsDialog` (keep `SettingsViewModel`; move `IndexBuilds` block and keep names asserted by `FolderScopeBindingTests.SettingsBindsIndexBuilds…`, updating its path), `Tools/RunToolDialog` from `TransformationsPage`, history from Notes panel. Delete `TransformationsPage`, `SettingsDialog`, `NotesPage` three-column layout.
**Acceptance:** same as B6 + B7.

### Task W5: [Windows] Onboarding restyle, l10n, literals, hard-coded colours
**Files:** onboarding steps restyled with tokens (remove `FromArgb` green), all new keys in both `.resw` before `providerPresetLabel` + `StringKey.cs`, remove dead keys, fix literals (MainWindow.xaml.cs:26, EditorWebView.xaml:34, TransformationsPage.xaml:44-45), replace every `Foreground="Red"` with `DangerBrush`. Update `LocalizedStringsTests` count.
**Acceptance:** no hard-coded colours (`grep -R "FromArgb\|Foreground=\"Red\"" windows/src/AINotebook.App` empty), tests green.

### Phase C — finish

### Task C1: [Shared] Parity + checklist
- [ ] Script `tools/ui/check_strings_parity.py`: every Swift `AppText.Key` that the App uses has a Windows resw key with the same EN/CS value (mapping table for renamed keys) → run → fix gaps.
- [ ] Update `docs/release/0.15.0-checklist.md` with the redesign checklist (both platforms): every row of spec §2.7 + §2.2 composer items + panels + settings sections + document mode + empty states + dark mode + keyboard shortcuts.
- [ ] Commit.

## Execution order

A1 → (A2 ∥ A3) → (Swift lane B1→B8 ∥ Windows lane W1→W5) → C1. Lanes run as parallel subagents in separate worktrees; Claude merges each lane into `feat/ui-redesign` after review and full gates.
