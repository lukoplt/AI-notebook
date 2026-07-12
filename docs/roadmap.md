# AI Notebook — detailní zadání vývoje

*Baseline: v0.10.0 (in-app update check), 2026-07-12. Dual-platform: macOS (Swift/SwiftUI, `Sources/`) + Windows (.NET 10 / WinUI 3, `windows/`). Tento dokument je závazné zadání — nahrazuje předchozí rámcový roadmap.*

---

## 0. Kontext a současný stav

Obě platformy sdílejí datový model a RAG pipeline. Od baseline v0.8.0 se dokončil hotfix Windows UI (P0), multi-provider AI (Epic A) a in-app update check — **na obou platformách**. Epicy B–E se ale implementovaly **jen na Windows**; macOS je za Windows 6 verzí schématu (v11 vs v17) a postrádá export/zálohy, hledání, tagy, source sets, pokročilý chat, kontextové obohacení a živé zdroje.

### 0.1 Co je hotové na obou platformách

| Oblast | Stav |
|---|---|
| Notebooky, poznámky (TipTap WYSIWYG, verze, přílohy) | ✅ obě |
| Zdroje: PDF, TXT, MD, web, DOCX/PPTX/XLSX + auto-indexace poznámek | ✅ obě |
| Hybrid retrieval (cosine + FTS5 BM25 → RRF), source-scoped chat | ✅ obě |
| Chat s citacemi `[N]`, streaming, follow-up chips, per-source souhrny | ✅ obě |
| Transformace (šablony, built-in + vlastní, batch, historie) | ✅ obě |
| Ollama onboarding, správa modelů, EN/CZ lokalizace | ✅ obě |
| **AI provideři: Ollama + Anthropic + OpenAI + OpenAI-kompatibilní + OpenWebUI** (Epic A) | ✅ obě |
| Bezpečné uložení klíčů (Keychain / Credential Manager), privacy gate + enforcement | ✅ obě |
| Windows detail notebooku (4 taby reálně zapojené, ex-Epic P0) | ✅ Windows |
| In-app update check (1×/den GitHub Releases, banner, „Check now") | ✅ obě |
| Citace odpovědi: popover (macOS) / panel (Windows) — FR-C4 | ✅ obě |

### 0.2 Co je hotové jen na Windows (parita macOS chybí)

| FR | Funkce | Windows | macOS |
|---|---|---|---|
| B1 | Export poznámky → Markdown | ✅ (`ExportService.ExportNoteMarkdown`) | ❌ |
| B1 | Export poznámky → **PDF** | ❌ (jen MD) | ❌ |
| B2 | Export notebooku → ZIP | ✅ (`ExportService.ExportNotebookZip`) | ❌ |
| B3 | Záloha / obnovení databáze | ✅ (`NotebookStore.BackupTo`, `NotebookDetailPage`) | ❌ |
| B4 | Globální hledání (Ctrl+K paleta) | ✅ (`GlobalSearchViewModel`, `GlobalSearchDialog`) | ❌ |
| B5 | Drag & drop souborů na Sources | ✅ (`SourceListPage` `AllowDrop`/`OnDrop`) | ❌ |
| B6 | Bulk delete zdrojů | ✅ (`SourcesViewModel.BulkDeleteAsync`) | ❌ |
| B6 | Bulk **summarize** zdrojů + bulk operace **poznámek** | ❌ | ❌ |
| B7 | Náhled zdroje (chunky + metadata) | ✅ (`SourcePreviewViewModel`/`Dialog`) | ❌ |
| B8 | Tagy (`tags`/`note_tags`/`source_tags`) + UI | ✅ (v12, `NotebookStore.Tags`) | ❌ |
| B9 | Hledání v poznámkách (`notes_fts`) | ✅ (`NotebookStore.Search.SearchNotes`) | ❌ |
| C1 | Per-notebook instrukce (`notebooks.instructions`) | ✅ (v13) | ❌ |
| C2 | Pojmenované sady zdrojů (`source_sets`) | ✅ (v13, `NotebookStore.SourceSets`) | ❌ |
| C3 | Editace zprávy + regenerace s volbou modelu (`chat_messages.model`) | ✅ (`ChatViewModel.RegenerateAsync`) | ❌ |
| C5 | Persony / presety | ❌ | ❌ |
| D1 | Contextual chunk enrichment (`source_chunks.context`) | ✅ (v14, `ContextualEnricher`) | ❌ |
| D2 | Mini eval sada (recall@8) | ❌ | ❌ |
| D3 | Cross-encoder reranker | ❌ | ❌ |
| E1 | Sledovaná složka (`last_synced_at`, `content_hash`) | ✅ (v15, `FolderWatchService`) | ❌ |
| E2 | Re-crawl URL | ✅ (`SourcesViewModel.RefreshUrlAsync`) | ❌ |
| E3 | Opt-in web search v chatu | ✅ (`WebSearchAdapter`) | ❌ |

### 0.3 Číslování migrací — porušená parita

Průřezový požadavek žádá identická čísla migrací na obou platformách. **Aktuálně porušeno:** macOS = v11 (`MigrationV11.swift`, provideři), Windows = v17 (`Migrator.cs`). Windows-only migrace v12–v15 (tagy+notes FTS, instrukce+source sets, chunk context, live sources) jsou přesně schéma pod B8/C1/C2/D1/E1, které macOS nemá. Dohnání macOS na v15 (min.) je jádro Epicu M níže; v16/v17 jsou Windows repair migrace bez macOS protějšku (macOS ekvivalentní opravy neproběhly).

---

## 1. Zbývající práce — přehled

> **Stav implementace (2026-07-12):** macOS **Core vrstva** parity je hotová a otestovaná — schéma dotaženo na **v15** (migrace V12–V15), a Core API pro Epicy B/C/D1/E ported z Windows:
> - **B:** tagy (`NotebookStore+Tags`), note/global FTS search (`NotebookStore+Search`), export MD/ZIP + `sources.json` (`ExportService`), DB backup/restore (`NotebookStore+Backup`, in-place přes GRDB backup — bez relaunche).
> - **C:** per-notebook instrukce + `SystemPrompt` injekce, source sets (`NotebookStore+SourceSets`), edit/regenerate zpráv + `messages.model` sloupec.
> - **D1:** `source_chunks.context` + `ContextualEnricher` + `SourceChunk.embeddingText`.
> - **E:** live-source sync (`last_synced_at`/`content_hash` + `updateSourceSyncInfo`), `WebSearch`/`DuckDuckGoWebSearch` + `WebSearchContext` (výsledky jako user-message context, ne system prompt).
> - **D2:** `RetrievalEval` recall@k harness (Core + testy) — gate pro D3.
> - Testy: **346 macOS testů zelených** (+35). Modely `Notebook`/`ChatMessage`/`Source`/`SourceChunk` rozšířeny bez regrese.
>
> **Zbývá:** macOS **UI wiring** (SwiftUI — Task 5: drag&drop, bulk select, náhled zdroje, tag UI, ⌘K paleta, source-set scope, instrukce, regenerate, export/backup menu, web search toggle); **Epic W** Windows-only kód (PDF export, bulk summarize/notes — nelze ověřit build na macOS/darwin); **C5 persony** (nová migrace v16+ na obou platformách, nejnižší priorita); **D3 reranker** (podmíněný reálným během D2). FSEvents folder-watch smyčka je App-layer (Core sync API hotové).


Dvě hlavní osy plus dvě podpůrné:

- **Epic M — parita macOS** (největší kus): implementovat na macOS vše z 0.2, co Windows už má (B1-MD, B2, B3, B4, B5, B6-delete, B7, B8, B9, C1, C2, C3, D1, E1, E2, E3). Migrace macOS v12–v15.
- **Epic W — dokončení Windows zbytku**: PDF export (B1), bulk summarize + bulk poznámky (B6), persony (C5), eval sada (D2), a podle výsledku eval případný reranker (D3).
- **Testy Epiců B–E**: velká Windows implementace přinesla hlavně migrace a pár oprav testů, ne plné pokrytí akceptačních kritérií — doplnit cílené testy (viz §6).
- **Průřezové požadavky** (§7) platí beze změny.

Detailní specifikace jednotlivých FR zůstávají v Epicích B–E níže a slouží jako **zadání implementace pro obě osy** (macOS parita i Windows dokončení). U každého FR je uveden aktuální stav.

---

## Epic M — Parita macOS (Epicy B–E)

**Cíl:** Dostat macOS na funkční úroveň Windows. Každý níže uvedený „✅ Windows / ❌ macOS" FR implementovat na macOS podle jeho specifikace v Epicích B–E, se stejným chováním, stejnými čísly migrací a EN+CZ lokalizací.

### Rozsah a pořadí (macOS)

1. **Schéma napřed.** macOS migrace `MigrationV12`…`MigrationV15` se stejnými DDL jako Windows `Migrator.cs` V12–V15 (tagy+notes FTS, instrukce+source sets, chunk context, live sources). Ověřit, že seed a existující data přežijí (vzor: Windows repair migrace, ale bez jejich Windows-specifických oprav timestampů).
2. **Epic B (macOS):** ExportService ekvivalent (MD + ZIP + manifest), DB backup/restore, globální hledání (`⌘K` paleta přes SwiftUI `.searchable`/vlastní overlay), drag & drop (`dropDestination`/`NSItemProvider`) na Sources, bulk delete zdrojů, náhled zdroje, tagy + filtr, hledání v poznámkách přes `notes_fts`.
3. **Epic C (macOS):** per-notebook instrukce do `SystemPrompt`, source sets ve scope popoveru, editace + regenerace odpovědi s volbou *(provider, model)* (návaznost na hotový Epic A), badge modelu u regenerované zprávy.
4. **Epic D1 (macOS):** contextual enrichment jako opt-in toggle (default off), jeden LLM průchod na zdroj, sloupec `source_chunks.context`.
5. **Epic E (macOS):** sledovaná složka (mtime/hash porovnání při startu + periodicky), re-crawl URL, opt-in web search tool (respektuje privacy gate; výsledky jako user-message context, ne system prompt — parita s Windows bezpečnostním vzorem).

### Akceptační kritéria (Epic M)

1. macOS schéma na v15; migrace idempotentní, existující DB projde upgrade bez ztráty dat.
2. Každý FR z tabulky 0.2 se stavem „✅ Windows" funguje i na macOS se shodným chováním a lokalizací (EN+CZ).
3. Nové stringy v `Localization.swift`; paritní test počtu klíčů aktualizován na obou platformách.
4. macOS build + testy zelené; nové Core i UI testy pro portované funkce (viz §6).

---

## Epic W — Dokončení Windows zbytku

**Cíl:** Doimplementovat na Windows FR, které tam dosud chybí (a chybí i na macOS — tedy dělat rovnou na obou, kde to jde jedním spec).

- **W-1 Export poznámky do PDF (FR-B1 PDF část).** Tisk z editor WebView2 do PDF (`CoreWebView2.PrintToPdfAsync`) — přidat vedle stávajícího MD exportu v `ExportService`/Notes akci. macOS ekvivalent: tisk z WKWebView (`createPDF`/`NSPrintOperation`).
- **W-2 Bulk summarize zdrojů + bulk operace poznámek (FR-B6 zbytek).** Windows už má `IsBulkMode`/`BulkDeleteAsync` pro zdroje; doplnit bulk **summarize** (dávkové `SummarizeAsync` s progress) a **multi-select v poznámkách** (bulk delete). macOS řeší Epic M zároveň.
- **W-3 Persony / presety (FR-C5).** Pojmenovaná kombinace instrukce + sada zdrojů + model; picker v chatu. Navazuje na C1+C2+C3 (Windows hotové). Nízká priorita — až po M a W-1/W-2.
- **W-4 Retrieval eval sada (FR-D2).** Skript + fixture korpus (10 dokumentů, 30 dotazů se zlatými chunky) měřící recall@8; spouštěný lokálně (ne CI). **Blokuje rozhodnutí o D3.**
- **W-5 (podmíněné) Reranker (FR-D3).** Lokální cross-encoder top-K → top-8 (ONNX MiniLM na Windows, CoreML na macOS). **Zavést jen pokud W-4 prokáže zisk;** jinak vypustit a poznamenat do CHANGELOG.

### Akceptační kritéria (Epic W)

1. PDF export vytvoří validní PDF odpovídající obsahu editoru (obě platformy).
2. Bulk summarize projde N zdrojů s progress a bez blokace UI; bulk delete poznámek s confirm.
3. Persona picker aplikuje instrukci + sadu + model na nový chat.
4. Eval skript vypíše recall@8 nad fixture korpusem; výsledek zapsán a použit jako gate pro D3.

---

## Epic B — „Reálný projekt": export, hledání, organizace *(spec pro M + W)*

**Cíl:** Denní práce na projektu s desítkami zdrojů — dostat data dovnitř rychle, najít cokoli, dostat výstupy ven.

### Požadavky

- **FR-B1 Export poznámky** → Markdown (`bodyMd` + přílohy do podsložky) a PDF (tisk z editor WebView). Menu/kontextová akce v Notes. — *Stav: MD ✅ Windows / ❌ macOS; PDF ❌ obě (viz W-1).*
- **FR-B2 Export notebooku** → ZIP: `notes/*.md`, `attachments/`, `sources/` (původní soubory z `rawPath`), `manifest.json` (metadata, verze schématu). — *✅ Windows / ❌ macOS.*
- **FR-B3 Záloha databáze** jedním kliknutím (kopie `db.sqlite` + attachments do zvoleného umístění) + obnovení ze zálohy s confirm dialogem. — *✅ Windows / ❌ macOS.*
- **FR-B4 Globální vyhledávání** (Cmd/Ctrl+K paleta): fulltext přes poznámky, zdroje (FTS indexy existují) a názvy chatů, napříč notebooky; výsledky s náhledem; Enter = skok (notebook → tab → položka). Včetně akcí („Nový zápisek", „Přepnout notebook…"). — *✅ Windows / ❌ macOS.*
- **FR-B5 Drag & drop** souborů na Sources tab (macOS `onDrop`, Windows `DragOver/Drop` na `SourceListPage`) + multi-výběr ve file pickeru; fronta ingesce s progress přehledem. — *✅ Windows / ❌ macOS.*
- **FR-B6 Hromadné operace:** multi-select v seznamu zdrojů a poznámek; bulk delete (confirm), bulk summarize zdrojů. — *Delete zdrojů ✅ Windows / ❌ macOS; bulk summarize + bulk poznámky ❌ obě (viz W-2).*
- **FR-B7 Náhled zdroje:** klik na zdroj otevře detail — extrahovaný text po chuncích, metadata (typ, URI, datum, počet chunků, stav embeddingů), u PDF číslo stránky chunku; akce „Otevřít originál". — *✅ Windows / ❌ macOS.*
- **FR-B8 Tagy** pro poznámky a zdroje: migrace **v12** (`tags`, `note_tags`, `source_tags`), UI: přiřazení tagů, filtr v seznamech, tag chips. Notebooky zůstávají ploché. — *✅ Windows (v12) / ❌ macOS.*
- **FR-B9 Vyhledávání v poznámkách** (parita) — search pole nad seznamem poznámek. — *✅ Windows / ❌ macOS.*

### Akceptační kritéria (výběr)

1. Notebook s 30 zdroji a 50 poznámkami: export ZIP obsahuje vše, manifest validní; PDF poznámky odpovídá obsahu editoru.
2. Cmd/Ctrl+K najde poznámku v jiném notebooku do 100 ms na korpusu 10k chunků a skočí na ni.
3. Přetažení 10 souborů najednou → všechny projdou ingescí se status badge, UI neblokuje.
4. Tag filtr kombinovatelný s textovým hledáním.

---

## Epic C — Kvalita chatu (vzory z Onyx) *(spec pro M + W)*

- **FR-C1 Per-notebook instrukce** (Projects pattern): textové pole v detailu notebooku; obsah se vkládá do `SystemPrompt` všech chatů, transformací notebooku a follow-upů. Migrace **v13**: `notebooks.instructions TEXT`. — *✅ Windows (v13) / ❌ macOS.*
- **FR-C2 Pojmenované sady zdrojů** (document sets): uložené scopy — `source_sets(id, notebook_id, name)` + `source_set_members`. Scope popover nabízí sady + ad-hoc výběr (stávající). Migrace v13. — *✅ Windows / ❌ macOS.*
- **FR-C3 Editace odeslané zprávy + regenerace odpovědi.** U poslední výměny: „Upravit" (přepíše user message, smaže odpověď, znovu odešle) a „Regenerovat" s volbou *(provider, model)* — návaznost na Epic A; u regenerované zprávy zobrazit badge modelu. `chat_messages` rozšířit o `model TEXT` (v13). — *✅ Windows / ❌ macOS.*
- **FR-C4 Citační panel:** zdroje aktuálně vybrané odpovědi — titulek zdroje, snippet, skok na chunk/stránku. — *✅ obě (macOS popover `CitationPopover`, Windows panel `CitationViewModel`).*
- **FR-C5 Persony (presety):** pojmenovaná kombinace instrukce + sada zdrojů + model; picker v chatu. Až po C1+C2; nízká priorita. — *❌ obě (viz W-3).*

**Akceptační kritéria:** instrukce ovlivní odpověď (ověřit promptovým testem); sada zdrojů omezí retrieval (unit test filtru); regenerace jiným modelem vytvoří novou odpověď bez ztráty historie; citační panel/popover ukazuje právě zdroje z `citations` dané zprávy.

---

## Epic D — Kvalita retrievalu *(spec pro M + W)*

- **FR-D1 Contextual chunk enrichment** (Onyx „contextual RAG"): při ingesci volitelně (settings toggle, default off) vygenerovat 1–2větný kontext dokumentu a předřadit jej textu chunku před embeddingem. Sloupec `source_chunks.context TEXT` (v14). Jeden LLM průchod na zdroj (ne na chunk — kontext per dokument, sdílený). — *✅ Windows (v14, `ContextualEnricher`) / ❌ macOS.*
- **FR-D2 Mini eval sada:** skript + fixture korpus (10 dokumentů, 30 dotazů se zlatými chunky) měřící recall@8 retrievalu; spouštěný lokálně (ne CI). Bez měření nezapínat D1 defaultně. — *❌ obě (viz W-4).*
- **FR-D3 (volitelné, až po D2) Lokální cross-encoder reranker** top-K → top-8 (ONNX MiniLM na Windows, CoreML na macOS). Zavést jen pokud D2 prokáže zisk; jinak vypustit. — *❌ obě (viz W-5, podmíněné W-4).*

---

## Epic E — Živé zdroje a nástroje *(spec pro M)*

- **FR-E1 Sledovaná složka:** zdroj typu „folder watch" — při startu a periodicky porovnat mtime/hash, změněné soubory reindexovat, smazané označit stale (ne mazat). `sources.last_synced_at`, `sources.content_hash` (v15). — *✅ Windows (v15, `FolderWatchService`) / ❌ macOS.*
- **FR-E2 Re-crawl URL:** akce „Obnovit" u web zdrojů + volitelný interval; diff hash → reindex. — *✅ Windows (`RefreshUrlAsync`) / ❌ macOS.*
- **FR-E3 Opt-in web search tool** v chatu (per-message toggle, default off; provider SearXNG/Brave dle konfigurace) s citacemi webových výsledků vedle lokálních. Respektuje privacy gate jako cloud provideři; výsledky jako user-message context (ne system prompt). — *✅ Windows (`WebSearchAdapter`) / ❌ macOS.*

---

## 6. Testy Epiců B–E (dluh)

Windows implementace B–E přinesla migrace (v12–v15) a několik oprav testů, ne plné pokrytí akceptačních kritérií. Doplnit cíleně:

- **B (obě platformy):** ExportService — round-trip ZIP (manifest validní, přílohy i `rawPath` soubory přítomné); PDF export produkuje neprázdný validní soubor; DB backup → restore obnoví identická data (hash porovnání); GlobalSearch najde poznámku i zdroj napříč notebooky a vrátí správný skok-cíl; tag filtr + text search kombinace; `notes_fts` search relevance.
- **C:** per-notebook instrukce se propíše do `SystemPrompt` (prompt-assembly test); source set omezí retrieval scope (filtr unit test); regenerace jiným modelem vytvoří nový `chat_messages` řádek s `model` a nezničí historii; citace panelu odpovídají `citations` zprávy.
- **D:** contextual enrichment předřadí kontext před embeddingem (jeden LLM průchod na zdroj, ne na chunk — ověřit počet volání); eval skript (W-4) vypíše recall@8 nad fixture korpusem.
- **E:** folder watch detekuje změněný/smazaný soubor (mtime/hash) a označí stale ne mazáním; re-crawl diff hash → reindex jen při změně; web search výsledky jdou do user-message contextu, ne do system promptu (bezpečnostní regrese test).
- **UI-kompoziční smoke testy** (vzor ex-P0): každý nový tab/dialog instancuje reálnou stránku, ne placeholder.

---

## 7. Průřezové požadavky (platí pro všechny epicy)

1. **Parita platforem.** Každá funkce se implementuje na obou platformách. Čísla migrací schématu musí být identická (v12 tagy, v13 chat, v14 retrieval, v15 živé zdroje). **Aktuálně porušeno** — macOS na v11, Windows na v17; Epic M to napravuje dohnáním macOS na v15. Před implementací epicu sepsat krátký spec chování + stringy (může být sekce v PR description).
2. **Lokalizace.** Každý nový string EN + CZ; Windows: doplnit `StringKey` + oba `.resw`, aktualizovat paritní test počtu klíčů; macOS: `Localization.swift`.
3. **Testy.** Core logika unit testy na obou platformách. UI-kompoziční smoke testy rozšiřovat s každým epicem. Dluh pokrytí B–E viz §6.
4. **Bezpečnost.** API klíče jen v OS úložišti (FR-A7, hotové); export (FR-B1/B2) nikdy neobsahuje klíče ani interní cesty; web fetch/re-crawl/web search drží stávající CSP a sanitizaci a jdou jako user-message context, ne system prompt; všechny nové SQL přes parametrizované dotazy (žádná interpolace — viz bezpečnostní audit 2026-06-06).
5. **CI.** Windows: locked-mode NuGet restore — každá změna závislostí = regenerace `packages.lock.json` pro všechny 4 projekty. Release: bump root `VERSION` + **oba in-code version konstanty** (`AINotebookVersion.swift` + `AINotebookVersion.cs`, guard testy hlídají shodu s `VERSION`) + CHANGELOG + tag `v*`.
6. **Local-first slib.** Cloud (provideři, web search) vždy opt-in s privacy gate; výchozí instalace funguje plně offline s Ollamou.

---

## 8. Historie (dokončeno)

| Verze | Obsah |
|---|---|
| win-v0.8.1 / v0.8.2 | **Epic P0** — hotfix Windows UI: 4 taby detailu notebooku reálně zapojené, koordinátory, editor end-to-end, model management; + Windows launch hotfix (unpackaged settings, x64 `.pri`, pinned NuGet). |
| v0.9.0 | **Epic A** — multi-provider AI na obou platformách (Ollama + Anthropic + OpenAI + OpenAI-kompatibilní + OpenWebUI), per-role volba modelu, test připojení, Keychain/Credential Manager, embeddingy klíčované `provider:model`. |
| v0.9.1 | Security patch (Windows: SQLitePCLRaw 2.1.11 → 3.0.3, HIGH). |
| v0.9.2 | Enforcement privacy consentu na obou platformách + Windows data-integrity opravy (requalify embedding keys v16, provider timestamps v17). |
| v0.10.0 | In-app update check na obou platformách (1×/den GitHub Releases, dismissible banner, „Check for updates now"; jen check+notify, žádný auto-download). |

---

## 9. Pořadí a release plán (dopředu)

| Pořadí | Práce | Cílový release |
|---|---|---|
| 1 | **W-1** PDF export (B1) + **W-2** bulk summarize / bulk poznámky (B6) — dokončení Windows, kde macOS zatím nesahá | v0.11.0 |
| 2 | **Epic M** parita macOS — schéma v12–v15 + Epic B na macOS | v0.12.0 (macOS-heavy) |
| 3 | **Epic M** — Epic C + D1 na macOS | v0.13.0 |
| 4 | **Epic M** — Epic E na macOS | v0.14.0 |
| 5 | **W-4** eval sada (D2) → rozhodnutí o **W-5** rerankeru (D3) na obou | v0.15.0 |
| 6 | **W-3** persony (C5) na obou | v0.16.0 |

**Priorita:** dokončit rozjeté Windows funkce (W-1/W-2) je levné a hned viditelné, proto první. Epic M (parita macOS) je největší kus a bude trvat několik verzí — schéma napřed, pak B → C/D1 → E. Eval sada (W-4) předchází rerankeru (W-5): bez měření recall@8 se D3 nezapíná. Persony (C5) jsou nízká priorita, až úplně nakonec. Uvnitř epiců lze FR dodávat po menších PR; každý PR musí držet průřezové požadavky (§7) — zvlášť identická čísla migrací.
