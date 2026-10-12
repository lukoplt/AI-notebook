# UI tokens v1

Single source of truth for the Codex-style redesign (spec
`docs/superpowers/specs/2026-10-10-ui-redesign-codex-style-design.md` §3, §5).
Machine copy: `Tests/fixtures/contracts/ui-tokens-v1.json` (contract `ui-tokens`,
version 1, no `cases`). Implementations, each guarded by a parity test against the
fixture:

| Platform | Values | Use in views | Parity test |
|---|---|---|---|
| macOS | `Sources/AINotebookCore/UITokensV1.swift` | `Sources/AINotebookApp/Design/DesignTokens.swift` (`DesignTokens.color(.text1)`, `.font(.message)`, `.radius(.lg)`, `.spacing(16)`, `.icon(.newChat)`) | `Tests/AINotebookCoreTests/UITokensTests.swift` |
| Windows | `windows/src/AINotebook.Core/Text/UITokensV1.cs` | `windows/src/AINotebook.App/Styles/Tokens.xaml` (`{ThemeResource Text1Brush}`, `{StaticResource RadiusLg}`, `{StaticResource IconNewChat}`) | `windows/tests/AINotebook.Core.Tests/Text/UITokensTests.cs` (also parses `Tokens.xaml`) |

Rules: views never hard-code a colour, font size, radius or spacing — they use a
token. Changing a value = new contract version (`ui-tokens-v2.json`), never an
edit of v1.

## Colours (light / dark)

| Token | Swift case | XAML key | Light | Dark | Use |
|---|---|---|---|---|---|
| `bg` | `.bg` | `Bg` / `BgBrush` | #FFFFFF | #1E1E1E | main area |
| `bg-sidebar` | `.bgSidebar` | `BgSidebar` / `BgSidebarBrush` | #F7F7F8 | #181818 | sidebar (Windows: Mica fallback) |
| `surface-1` | `.surface1` | `Surface1` / `Surface1Brush` | #FFFFFF | #252525 | cards, composer, right panel |
| `surface-2` | `.surface2` | `Surface2` / `Surface2Brush` | #F2F2F3 | #2E2E2E | user message, hover, chips |
| `border` | `.border` | `Border` / `BorderBrush` | #E5E5E7 | #3A3A3A | 1px edges |
| `text-1` | `.text1` | `Text1` / `Text1Brush` | #0D0D0D | #ECECEC | primary text |
| `text-2` | `.text2` | `Text2` / `Text2Brush` | #5D5D63 | #A7A7AD | secondary |
| `text-3` | `.text3` | `Text3` / `Text3Brush` | #8E8E93 | #6E6E73 | tertiary, metadata |
| `accent` | `.accent` | `Accent` / `AccentBrush` | #0D0D0D | #ECECEC | primary buttons (monochrome) |
| `on-accent` | `.onAccent` | `OnAccent` / `OnAccentBrush` | #FFFFFF | #0D0D0D | text on primary button |
| `focus` | `.focus` | `Focus` / `FocusBrush` | #2F6FEB | #4C8DFF | 2px focus ring, links |
| `success` | `.success` | `Success` / `SuccessBrush` | #1F8A4C | #3FB96E | success state |
| `warning` | `.warning` | `Warning` / `WarningBrush` | #B26A00 | #E0A33A | warning state |
| `danger` | `.danger` | `Danger` / `DangerBrush` | #C42B1C | #FF6B5E | errors, destructive |

Windows: `Tokens.xaml` holds a `ThemeDictionaries` entry for `Light` and `Dark`
(plus `Default` = Dark, the WinUI convention) with a `Color` (`Text1`) and a
`SolidColorBrush` (`Text1Brush`) per token; reference brushes with
`{ThemeResource …}` so they follow the theme. Contrast: `text-1` and `text-2` on
`bg` are ≥ 4.5:1 (WCAG 2.2 AA) in both themes.

## Typography

System fonts only: SF Pro / SF Mono on macOS; Segoe UI Variable / Cascadia Mono on
Windows (icons: Segoe Fluent Icons).

| Style | Size | Line height | Weight | Use |
|---|---|---|---|---|
| `title` | 20 | 28 | semibold | empty-state headings, settings section titles |
| `headline` | 15 | 22 | semibold | top-bar title, panel headers |
| `body` | 14 | 22 (Windows 20) | regular | UI text, sidebar rows, user messages |
| `message` | 15 | 24 | regular | assistant answers (Markdown) |
| `caption` | 12 | 16 | regular | chips, metadata, token counts |
| `mono` | 13 | 20 | regular | code spans and code blocks |

XAML keys: `FontSizeTitle` … `FontSizeMono` (`x:Double`), `LineHeightTitle` …
(`x:Double`; `LineHeightBody` = 20 on Windows).

## Spacing, radius, sizes, motion

- Spacing (4 pt grid): 4, 8, 12, 16, 24, 32 — XAML `Space4` … `Space32` (`x:Double`)
  and `Pad4` … `Pad32` (`Thickness`, uniform).
- Radius: `sm` 6 (buttons, fields), `md` 10 (cards, panels), `lg` 16 (composer,
  user message), `pill` 999 (chips) — XAML `RadiusSm/Md/Lg/Pill` (`CornerRadius`).
- Sizes (pt / epx; XAML key `Size` + PascalCase name, `x:Double`):

| Name | Value | Meaning |
|---|---|---|
| `sidebarRow` | 30 | sidebar row height |
| `topBar` | 44 | top bar height |
| `hitMin` | 28 | minimum hit target |
| `primaryHitMin` | 32 | primary button hit target |
| `conversationMax` | 760 | conversation column max width |
| `sidebarMin` | 240 | sidebar min width |
| `sidebarMax` | 300 | sidebar max width |
| `panelMin` | 320 | right panel min width |
| `panelMax` | 420 | right panel max width |
| `iconRow` | 16 | icon size in rows |
| `iconTopBar` | 18 | icon size in the top bar |
| `userMessagePadV` | 10 | user message vertical padding |
| `userMessagePadH` | 14 | user message horizontal padding |
| `userMessageMaxPercent` | 80 | user message max width, % of column |
| `composerMinLines` | 1 | composer min lines |
| `composerMaxLines` | 8 | composer max lines before scrolling |
| `settingsContentMax` | 640 | settings content max width |
| `onboardingCardMax` | 520 | onboarding card max width |
| `focusRing` | 2 | focus ring width |
| `borderWidth` | 1 | hairline border width |
| `sidebarChatsVisible` | 8 | chats shown per notebook before "Show more" |

- Motion: short transitions only, `fastMs` 120 (hover actions) and `slowMs` 180
  (panel); disabled when Reduce Motion / animations are off.
- Elevation: none at rest; the composer shows a soft shadow only while focused.

## Accessibility

Every icon-only control has an accessibility label (`accessibilityLabel` /
`AutomationProperties.Name`); everything is keyboard reachable; focus ring =
`focus` colour, `focusRing` width.

## Icon map

SF Symbols on macOS, Segoe Fluent Icons code points on Windows (XAML key
`Icon` + PascalCase name, an `x:String` holding the glyph). Linear style, 16 pt
in rows, 18 pt in the top bar. Later tasks use only names from this table; add a
row (and bump the contract) rather than inlining a new symbol.

| Name | SF Symbol | Fluent | Used by |
|---|---|---|---|
| `newChat` | `square.and.pencil` | `E70F` | sidebar: New chat |
| `search` | `magnifyingglass` | `E721` | sidebar: Search / palette |
| `settings` | `gearshape` | `E713` | sidebar footer, settings General |
| `notebook` | `book.closed` | `E8F1` | sidebar notebook group |
| `chat` | `bubble.left` | `E8BD` | sidebar chat row |
| `chevronDown` | `chevron.down` | `E70D` | expanded group, Show more |
| `chevronRight` | `chevron.right` | `E76C` | collapsed group, submenu |
| `back` | `chevron.left` | `E72B` | document/settings back |
| `add` | `plus` | `E710` | + New notebook, composer +, panel + |
| `more` | `ellipsis` | `E712` | … menus |
| `togglePanel` | `sidebar.right` | `E8A0` | top bar: right panel |
| `updateDot` | `circle.fill` | `EA3B` | sidebar update indicator |
| `send` | `arrow.up` | `E74A` | composer send |
| `stop` | `stop.fill` | `E71A` | composer stop streaming |
| `previewContext` | `eye` | `E890` | composer context preview |
| `scope` | `scope` | `E8B7` | composer scope chip |
| `persona` | `theatermasks` | `E77B` | composer persona chip |
| `model` | `cpu` | `E950` | composer model chip |
| `copy` | `doc.on.doc` | `E8C8` | message hover: copy |
| `regenerate` | `arrow.clockwise` | `E72C` | message hover: regenerate, retry |
| `saveAsNote` | `square.and.arrow.down` | `E74E` | message hover: save as note |
| `sentContext` | `doc.text.magnifyingglass` | `E8A5` | message hover / top bar: sent context |
| `edit` | `pencil` | `E70F` | edit last user message, rename |
| `warning` | `exclamationmark.triangle` | `E7BA` | error row, stale citation |
| `addFile` | `doc.badge.plus` | `E8E5` | + menu: add file |
| `addFolder` | `folder.badge.plus` | `E8F4` | + menu: add folder, open folder as notebook |
| `addUrl` | `link` | `E71B` | + menu: add URL |
| `addText` | `text.alignleft` | `E8E4` | sources +: add text |
| `webSearch` | `globe` | `E774` | + menu: web search toggle |
| `overview` | `list.bullet.rectangle` | `E8FD` | + menu: overview mode |
| `runTool` | `wand.and.stars` | `E945` | + menu: run tool, settings Tools |
| `note` | `note.text` | `E7C3` | notes panel rows, new note |
| `folder` | `folder` | `E8B7` | sources: folder row |
| `file` | `doc` | `E8A5` | sources: file row |
| `scan` | `arrow.triangle.2.circlepath` | `E895` | folder …: scan, indexing indicator |
| `verify` | `checkmark.seal` | `E73E` | folder …: verify all |
| `rules` | `line.3.horizontal.decrease.circle` | `E71C` | folder …: rules |
| `watch` | `binoculars` | `E7B3` | folder …: watch toggle |
| `delete` | `trash` | `E74D` | remove / delete |
| `tag` | `tag` | `E8EC` | tags filter |
| `bulkSelect` | `checklist` | `E762` | panel …: bulk mode |
| `history` | `clock.arrow.circlepath` | `E81C` | document History, tool history |
| `export` | `square.and.arrow.up` | `EDE1` | document Export MD/PDF, notebook Export ZIP |
| `instructions` | `text.badge.star` | `E734` | notebook menu: Instructions |
| `backup` | `archivebox` | `E896` | notebook menu: Backup DB |
| `restore` | `arrow.uturn.backward` | `E7A7` | notebook menu: Restore DB |
| `openOriginal` | `arrow.up.forward.square` | `E8A7` | citations: open original / note |
| `citation` | `quote.opening` | `E9D2` | citations panel header |
| `info` | `info.circle` | `E946` | settings About, tooltips |
| `error` | `xmark.octagon` | `E783` | save error |
| `success` | `checkmark.circle` | `E73E` | success state |
| `close` | `xmark` | `E711` | close / dismiss |
| `providers` | `cloud` | `E753` | settings: Providers |
| `modelsLimits` | `slider.horizontal.3` | `E9E9` | settings: Models & limits |
| `indexing` | `square.stack.3d.up` | `E81E` | settings: Indexing |

## MarkdownLite v1 (assistant answers)

Contract `markdown-lite` v1: `Tests/fixtures/contracts/markdown-lite-v1.json`,
generated by the reference parser `tools/contracts/gen_markdown_fixtures.py`
(`--check` verifies it; `tools/contracts/test_markdown_fixtures.py` holds
hand-worked expectations). Implementations: `Sources/AINotebookCore/MarkdownLite.swift`
and `windows/src/AINotebook.Core/Text/MarkdownLite.cs`; both must reproduce every
case. The normative rules are the generator's module docstring; summary:

- Blocks, line based: `#`/`##`/`###` + space → heading; `- `/`* `/`+ ` → bullet,
  `N. ` → ordered (`start` = first number); ≥ 2 spaces (tab = 4) of indent while a
  list is open → second level (deeper flattens); `> ` → quote (inline content);
  ```` ``` ```` fence, info string ignored, unterminated = code to the end;
  `---` / `***` / `___` alone → rule; blank line ends paragraphs (a list survives
  a blank line when the next line is an item); consecutive lines join with one
  space; a plain line right after an item continues that item; `|` lines → one
  paragraph each, separator rows dropped (no tables).
- Inlines: `**strong**`, `*em*` / `_em_` (no intraword `_`), `` `code` ``
  (backtick runs, no nesting), `[text](url)` only for http/https/mailto (else
  the source stays literal text), `[N]` (1–3 digits, no leading 0, not followed
  by `(`) → citation, `\` escapes ASCII punctuation. Unterminated markers stay
  literal, so every streaming prefix parses. No HTML.
- Only space and tab count as whitespace; a "word char" is anything that is not
  whitespace or ASCII punctuation — no host Unicode tables are consulted.

JSON shape: blocks `paragraph`/`heading`/`quote` `{inlines}` (heading + `level`),
`code` `{text}`, `rule`, `list` `{ordered, start?, items}`; item `{inlines,
sublist?}`; sublist `{ordered, start?, items}`. Inlines `text{v}`, `strong{c}`,
`em{c}`, `code{v}`, `link{href, c}`, `cite{n}`.
