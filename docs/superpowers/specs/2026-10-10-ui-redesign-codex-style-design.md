# UI/UX redesign ve stylu Codex app — design spec

*Datum: 2026-10-10 · Stav: schváleno uživatelem (chat-first IA, Codex vizuál, obě platformy, součást nevydané 0.15.0) · Větev: `feat/ui-redesign` (z `feat/folder-chat-multilingual-rag` @ 4b4d7ba)*

## 1. Cíl

Jednoduchá a intuitivní aplikace, vizuálně co nejblíž desktopové Codex app: chat na prvním místě, klidný monochromatický vzhled, minimum ovládacích prvků na očích, pokročilé věci schované v menu a panelech. Platí pro macOS (SwiftUI) i Windows (WinUI 3) se stejnou informační architekturou a stejnými texty. **Core logika se nemění** — mění se jen App vrstva (plus malý Markdown parser v Core).

## 2. Informační architektura

```
┌──────────────┬────────────────────────────────────────┬───────────────┐
│ Sidebar      │ Top bar: název vlákna · notebook  [⊞]  │ Pravý panel   │
│ [+ Nový chat]│────────────────────────────────────────│ (volitelný)   │
│ 🔍 Hledat ⌘K │                                        │ Zdroje |      │
│              │      konverzace (max 760 pt)           │ Poznámky |    │
│ ▾ Notebook A │                                        │ Kontext |     │
│    Chat 1    │                                        │ Citace        │
│    Chat 2    │   ┌──────────────────────────────┐     │               │
│ ▸ Notebook B │   │ composer                     │     │               │
│              │   │ + · rozsah · persona · model ↑│     │               │
│ ⚙ Nastavení  │   └──────────────────────────────┘     │               │
└──────────────┴────────────────────────────────────────┴───────────────┘
```

### 2.1 Sidebar (šířka 240–300, pevné pozadí, na Windows Mica)
- Nahoře: **„Nový chat“** (⌘N / Ctrl+N) a pole **Hledat** (otevře existující globální paletu, ⌘K / Ctrl+K; na Windows se tím zapojí dosud nepoužitý `GlobalSearchDialog`).
- Seznam **notebooků jako sbalitelné skupiny** (jako projekty v Codexu). Pod notebookem jeho **chaty** (chat sessions) od nejnovějšího, max 8 + „Zobrazit další“. Aktivní vlákno zvýrazněné.
- Kontextové menu notebooku: Nový chat, Instrukce…, Export ZIP, Záloha / Obnova DB, Přejmenovat, Smazat. Kontextové menu chatu: Přejmenovat, Smazat.
- „+ Nový notebook“ na konci seznamu (malý text-button).
- Dole: **Nastavení** (ikona ozubeného kola + text) a nenápadný indikátor aktualizace (tečka + „Aktualizace k dispozici“), který nahrazuje dnešní banner/InfoBar.

### 2.2 Hlavní plocha
- **Top bar** (výška 44): název vlákna (editovatelný dvojklikem), drobný štítek notebooku, vpravo přepínač pravého panelu a menu „…“ (Smazat chat, Odeslaný kontext).
- **Konverzace** ve sloupci max 760 pt, vycentrovaná:
  - Zprávy uživatele: zarovnané vpravo, blok `surface-2`, radius 16, padding 10×14, max 80 % šířky.
  - Odpovědi asistenta: **bez bubliny**, plný sloupec, renderovaný **Markdown** (§5). Citace `[N]` jako malé zaoblené čipy v textu; klik otevře pravý panel Citace na dané citaci (na obou platformách stejně — sjednocuje dnešní popover vs. panel).
  - Pod odpovědí při hoveru řádek ikon: Kopírovat, Regenerovat (menu „s modelem…“), Uložit jako poznámku, Odeslaný kontext. U poslední zprávy uživatele ikona Upravit.
  - Streamovaná odpověď stejně bez bubliny; chyba jako tlumený řádek s ikonou varování a tlačítkem Zkusit znovu (žádný červený výpis výjimky).
  - Návrhy navazujících otázek jako čipy nad composerem.
- **Composer** (karta radius 16, 1px hrana, stín jen ve stavu focus): víceřádkové pole (1–8 řádků), placeholder „Zeptej se na cokoliv v notebooku…“. Spodní řádek:
  - **„+“ menu**: Přidat soubor…, Přidat složku…, Přidat URL…, —, Web search (zaškrtávací), Režim Přehled (zaškrtávací), —, Spustit nástroj ▸ (transformace), Nová poznámka.
  - **Čip rozsahu** („Celý notebook“ / název složky / „Výběr (3)“) → popover s dnešním výběrem rozsahu.
  - **Čip persony** (skrytý, pokud žádná persona neexistuje; jinak „Bez persony“ / název) → menu.
  - **Čip modelu** („Ollama · llama3.1“) → menu modelů s „Regenerovat s…“ logikou a odkazem do Nastavení.
  - Vpravo ikona **náhledu kontextu** (oko) a kruhové tlačítko **Odeslat** (↑, monochromatické; ⌘↩ / Ctrl+Enter, Enter = odeslat, Shift+Enter = nový řádek).
- **Prázdný stav nového chatu**: uprostřed nadpis „Na čem pracujeme?“, pod ním výběr notebooku (menu: notebooky · „Nový notebook“ · „Otevřít složku jako notebook“), composer a tři tiché akce: Přidat složku · Přidat soubor · Nová poznámka.
- **Prázdný stav aplikace** (žádný notebook): „Začni přidáním složky nebo vytvořením notebooku“ + dvě tlačítka.

### 2.3 Pravý panel (šířka 320–420, sbalitelný, stav pamatovaný)
Segmentované záložky nahoře:
1. **Zdroje** — dnešní obsah Sources (složky jako sbalitelné stromy se seskupenými soubory, volné zdroje), ale zhuštěně: řádek složky = ikona, název, jeden souhrnný stav („1 204 souborů · 3 chyby“), menu „…“ (Skenovat, Ověřit vše, Pravidla…, Sledovat ✓, Odebrat). Detailní počty v tooltipu / v náhledu složky. Nahoře „+“ (soubor/složka/URL/text) a indikátor indexace. Hromadný režim a tagy zůstávají v menu „…“ panelu.
2. **Poznámky** — seznam poznámek (hledání, tagy), „+ Nová“; klik otevře poznámku v hlavní ploše (§2.4). Historie transformací je dostupná odsud („Historie nástrojů“).
3. **Kontext** — náhled připraveného / odeslaného kontextu (dnešní ContextPreviewPanel / ContextPreviewViewModel), čitelně: sekce jako sbalitelné bloky, tokeny jako drobné šedé čísla.
4. **Citace** — citace aktuální odpovědi: titulek, cesta, strana, snapshot textu, „Otevřít originál“ / „Otevřít poznámku“, stav (změněno / nedostupné).

### 2.4 Dokument (poznámka)
Otevřená poznámka nahradí obsah hlavní plochy: top bar s názvem (editovatelný), stav ukládání, tlačítka Historie a Export (MD/PDF), editor TipTap na střed (max 760). Notes-chat panel zůstává jako záložka pravého panelu „Chat k poznámce“ jen v dokumentovém režimu (dnešní `NotesChatPanel`). Návrat do chatu: klik na vlákno v sidebaru nebo ⌘[ / Alt+←.

### 2.5 Nastavení (celé okno / celá plocha, ne dialog)
Levá navigace sekcí: **Obecné** (jazyk, web search, aktualizace), **Provideři** (seznam + Přidat), **Modely a limity** (chat model, discovery, ruční ID, limity), **Indexace** (embedding, re-index, průběh), **Nástroje** (editor šablon transformací), **O aplikaci** (verze, licence, NOTICE). Obsah sekce vpravo, max šířka 640. Na macOS vlastní `Settings` scéna (⌘,) i položka v sidebaru; na Windows stránka v hlavní ploše (zpět šipkou).

### 2.6 Onboarding
Stejný tok kroků, nový vzhled: vycentrovaná karta max 520, monochromatické primární tlačítko, stejné tokeny. Žádné změny logiky.

### 2.7 Co mizí / kam se přesouvá
| Dnes | Nově |
|---|---|
| Záložky Sources/Chat/Notes/Transformations (+ Settings na Windows) | Chat v hlavní ploše, Zdroje/Poznámky v pravém panelu, nástroje v „+“ |
| Seznam chat sessions uvnitř ChatView | Chaty v sidebaru pod notebookem |
| Hlavička notebooku (název, popis, instrukce, export) | Kontextové menu notebooku v sidebaru + Instrukce jako popover/sheet |
| Toolbar s 8 ovládacími prvky v chatu | Composer čipy + „+“ menu + hover akce |
| Update banner / InfoBar | Indikátor dole v sidebaru |
| Settings sheet/dialog | Settings okno/plocha se sekcemi |
| Transformations záložka | „+ › Spustit nástroj“ → výsledek jako poznámka; editor šablon v Nastavení › Nástroje a historie v Poznámkách |

`TabSwitchCoordinator` / `NoteJumpCoordinator` (Core) zůstávají; jejich cíle se mapují na nové cíle (Sources → pravý panel Zdroje, Notes → otevřít poznámku, Chat → vlákno).

## 3. Vizuální systém (sdílené tokeny)

Definované jednou jako tabulka v `docs/design/tokens-v1.md` + strojově v `Tests/fixtures/contracts/ui-tokens-v1.json`; implementace `DesignTokens.swift` (App) a `Styles/Tokens.xaml` (Windows ResourceDictionary). Test na obou platformách ověří, že hodnoty v kódu = fixture.

**Barvy (light / dark):**
| Token | Light | Dark | Použití |
|---|---|---|---|
| `bg` | #FFFFFF | #1E1E1E | hlavní plocha |
| `bg-sidebar` | #F7F7F8 | #181818 | sidebar (Windows: Mica fallback) |
| `surface-1` | #FFFFFF | #252525 | karty, composer, pravý panel |
| `surface-2` | #F2F2F3 | #2E2E2E | zpráva uživatele, hover, čipy |
| `border` | #E5E5E7 | #3A3A3A | 1px hrany |
| `text-1` | #0D0D0D | #ECECEC | primární text |
| `text-2` | #5D5D63 | #A7A7AD | sekundární |
| `text-3` | #8E8E93 | #6E6E73 | terciární, metadata |
| `accent` | #0D0D0D | #ECECEC | primární tlačítka (monochrom) |
| `on-accent` | #FFFFFF | #0D0D0D | text na primárním tlačítku |
| `focus` | #2F6FEB | #4C8DFF | focus ring 2px, odkazy |
| `success` | #1F8A4C | #3FB96E | |
| `warning` | #B26A00 | #E0A33A | |
| `danger` | #C42B1C | #FF6B5E | |

**Typografie** (systémová: SF Pro na macOS, Segoe UI Variable na Windows): `title` 20/28 semibold · `headline` 15/22 semibold · `body` 14/22 (Windows 14/20) · `message` 15/24 (odpovědi) · `caption` 12/16 · `mono` 13/20 (SF Mono / Cascadia Mono).

**Rozměry:** mřížka 4; spacing 4/8/12/16/24/32; radius `sm` 6 (tlačítka, pole), `md` 10 (karty, panely), `lg` 16 (composer, zpráva uživatele), `pill` 999 (čipy); výška řádku sidebaru 30; top bar 44; hit target ≥ 28 pt (desktop), primární ≥ 32.

**Ikony:** SF Symbols (macOS) / Segoe Fluent Icons (Windows), lineární, 16 pt v řádcích, 18 v top baru. Mapovací tabulka ikon v `docs/design/tokens-v1.md`.

**Pohyb:** jen krátké přechody 120–180 ms (panel, hover akce); respektovat Reduce Motion.

**Přístupnost:** kontrast WCAG 2.2 AA (tokeny výše splňují ≥ 4.5:1 pro `text-1`/`text-2` na `bg`), všechny ikonové prvky mají accessibility label/AutomationProperties.Name, ovladatelné klávesnicí, viditelný focus ring.

## 4. Technická realizace

- **macOS:** `NavigationSplitView` se 3 sloupci (sidebar / detail / inspector přes `.inspector` na macOS 14+). Nové komponenty v `Sources/AINotebookApp/Design/` (tokens, ChipButton, IconButton, ComposerView, SidebarSectionRow, PanelSegment). `ChatView` (829 ř.) rozdělit: `ChatThreadView`, `ComposerView`, `MessageRow`, `ChatViewModel` (`@Observable`) — logika přípravy/odesílání přesunutá z `@State` do view modelu beze změny chování. Settings jako `Settings` scéna + `SettingsWindowView` se sekcemi.
- **Windows:** `NavigationView` nahradit vlastním shellem (`Grid`: sidebar `ListView` se skupinami / hlavní `Frame` / pravý panel `SplitView` nebo sloupec s `GridSplitter`-like resize), Mica (`MicaBackdrop`) na okně, `Styles/Tokens.xaml` + `Styles/Controls.xaml` (ChipButton, IconButton, Composer styly). Ikony výhradně `Segoe Fluent Icons`. Žádné hard-coded barvy (dnešní `Foreground="Red"` a ARGB v MessageBubble → tokeny).
- **Lokalizace:** nové klíče EN/CS na obou platformách; zrušené klíče odstranit; Windows klíče vkládat před `providerPresetLabel` (Swift test); aktualizovat počty v `LocalizedStringsTests`. Odstranit nelokalizované literály (seznam v průzkumu: AddSourceSheet:79, SourcePreviewSheet:81-89, ChatView:805, NotesChatPanel:180, CitationPopover „s.“, MainWindow.xaml.cs:26, EditorWebView.xaml:34, TransformationsPage.xaml:44-45).
- **Parita:** sjednotit citace (panel), náhled kontextu (panel), web toggle (na obou podle nastavení), globální hledání (Windows zapojit), tagy (zdroje i poznámky na obou), PDF export poznámky (macOS doplnit přes `WKWebView.createPDF`, roadmap M-2 — v rozsahu, protože export patří do nového dokumentového top baru).

## 5. Markdown odpovědí (Core, obě platformy)

Malý deterministický parser `MarkdownLite` v Core (Swift + C#) → seznam bloků: odstavec, nadpis (1–3), seznam (odrážky/číslovaný, 2 úrovně), citace `>`, blok kódu ``` (jazyk ignorován), oddělovač; inline: **tučně**, *kurzíva*, `kód`, odkaz `[text](url)` (jen http/https/mailto), citační značka `[N]` jako speciální inline. Žádné HTML, žádné tabulky (render jako prostý text), bezpečné vůči neukončeným značkám během streamování. Sdílené fixtures `Tests/fixtures/contracts/markdown-lite-v1.json` (≥ 40 případů vč. CZ/SK diakritiky, streamování po tokenech, neukončené `**`, `[12]` vs odkaz). Render: macOS `Text` + `AttributedString` po blocích, Windows `RichTextBlock`.

## 6. Testy

- Core: MarkdownLite (obě platformy, sdílené fixtures), tokens parita (obě).
- Swift: view-model testy pro nový `ChatViewModel` (příprava/odeslání/regenerace/stale preview) — převzít existující chování z ChatView, žádná regrese.
- Windows App.Tests: aktualizovat XAML-grep testy (`FolderScopeBindingTests`, `FolderSourcesTests` — už dnes neplatný, `NotebookTabCompositionTests`) na nové soubory/struktury; přidat test, že shell obsahuje sidebar + panel záložky; lokalizační počty.
- Ruční checklist v `docs/release/0.15.0-checklist.md` doplnit o redesign (obě platformy).

## 7. Mimo rozsah

Nové funkce mimo přesun stávajících; změny Core chování; screenshoty webu/README (samostatný úkol po ověření UI); vlastní ikona aplikace; animované přechody nad rámec §3; tabulky v Markdownu.

## 8. Rizika

1. Windows UI nelze na macOS sestavit — CI až po schválení pushe; omezit riziko malými, pečlivými XAML změnami a App.Tests nad view modely.
2. Rozpad `ChatView` (32 `@State`) — přesun do view modelu s testy dřív, než se mění vzhled.
3. Ztráta funkcí při přesunu do menu — tabulka §2.7 je závazná; checklist ověří každou položku.
