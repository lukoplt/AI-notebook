# AI Notebook — detailní zadání vývoje

*Baseline: **v0.13.0** (code-review fixy na obou platformách), 2026-08-24. Dual-platform: macOS (Swift/SwiftUI, `Sources/`) + Windows (.NET 10 / WinUI 3, `windows/`). Tento dokument je závazné zadání — nahrazuje předchozí rámcový roadmap.*

---

## 0. Kontext a současný stav

Obě platformy sdílejí datový model a RAG pipeline. **Epic M (parita macOS) je hotový a smergovaný** — macOS dohnal Windows na Epicy B–E i C5 persony (release v0.11.0, commit `1a1deef`). Schéma je na obou platformách na **v18**. Zbývá už jen krátký seznam jednotlivých FR (§1) plus testový dluh (§6).

**Testy (baseline v0.13.0):** macOS **357** zelených (`swift test`), Windows Core **273** zelených (`dotnet test tests/AINotebook.Core.Tests`).

> **Poznámka k ověřitelnosti:** `AINotebook.Core` i `AINotebook.Core.Tests` cílí na `net10.0` (ne `-windows`), takže **Windows Core testy jdou spustit i na macOS**. Jen `AINotebook.App`/`AINotebook.App.Tests` cílí na `net10.0-windows10.0.19041.0` a ověří je až Windows CI. Praktický důsledek: veškerá Core logika (storage, RAG, ingesce, provideři) se dá vyvíjet TDD i mimo Windows; XAML/ViewModel vrstva je blind port ověřený CI.

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
| In-app update check (1×/den GitHub Releases, banner, „Check now") | ✅ obě |
| Citace odpovědi: popover (macOS) / panel (Windows) — FR-C4 | ✅ obě |
| **Epic B:** export MD (B1), export ZIP (B2), backup/restore (B3), ⌘/Ctrl+K global search (B4), drag & drop (B5), bulk delete + bulk summarize zdrojů (B6), náhled zdroje (B7), tagy (B8), hledání v poznámkách (B9) | ✅ obě |
| **Epic C:** per-notebook instrukce (C1), source sets (C2), edit + regenerace s volbou modelu (C3) | ✅ obě |
| **Epic E:** folder sync (E1, one-shot na macOS — viz M-1), re-crawl URL (E2), opt-in web search (E3) | ✅ obě |

### 0.2 Zbývající rozdíly mezi platformami

| FR | Funkce | Windows | macOS | Kam patří |
|---|---|---|---|---|
| B1 | Export poznámky → **PDF** | ✅ (`EditorWebView.ExportPdfAsync` → `CoreWebView2.PrintToPdfAsync`) | ❌ (chybí `WKWebView.createPDF`) | **M-2** |
| B6 | Bulk operace **poznámek** (multi-select + delete) | ❌ (`NotesViewModel` nemá bulk) | ✅ (`NotesView.bulkMode`) | **W-6** |
| C5 | Persony — **UI picker** | ❌ (Core hotové: `NotebookStore.Personas`, v18) | ✅ (`ChatView` persona menu) | **W-3** |
| E1 | **Kontinuální** sledování složky | ✅ (`FolderWatchService` + `FileSystemWatcher`) | ❌ (jen one-shot „Sync folder…", `SourceListView.swift:342`) | **M-1** |

### 0.3 Co je nedodělané na obou platformách

| FR | Funkce | Stav | Kam patří |
|---|---|---|---|
| D1 | Contextual chunk enrichment | Core hotové na obou (`ContextualEnricher`, sloupec `source_chunks.context`, v14), ale **nikde se nevolá**: macOS nemá settings toggle ani hook v `IngestionService`; Windows má DI registraci v `App.xaml.cs` a stringy `contextualEnrichmentLabel/Hint`, ale `EnrichSourceAsync` nemá call-site. Funkce je tedy *mrtvá* — zapnout ji má smysl až po měření D2. | **D1-wire** (gated na W-4) |
| D2 | Mini eval sada (recall@8) | `RetrievalEval` harness + testy matematiky hotové na macOS; chybí fixture korpus, runner a zaznamenaný výsledek. | **W-4** |
| D3 | Cross-encoder reranker | Nezapracován záměrně — gate na W-4. | **W-5** (podmíněné) |

### 0.4 Číslování migrací — parita obnovena

| | macOS | Windows |
|---|---|---|
| Feature migrace | v1–v15, v18 | v1–v15, v18 |
| Repair migrace | — | v16 (`requalify_embedding_keys`), v17 (`fix_provider_timestamps`) |

v16/v17 jsou **Windows-only opravy dat**, které na macOS nemají protějšek (macOS ekvivalentní vada nevznikla). Číselná řada feature migrací je identická, což §7.1 vyžaduje. **Nové feature migrace musí pokračovat od v19 na obou platformách současně.**

---

## 1. Zbývající práce — přehled

Rozsah se zúžil z „dva velké epicy" na **šest adresných položek**:

| ID | Práce | Platforma | Priorita |
|---|---|---|---|
| **W-4** | Retrieval eval sada (FR-D2): fixture korpus + runner + zaznamenaný recall@8 | macOS (harness sdílený) | **1 — blokuje W-5 i D1-wire** |
| **W-5** | Reranker (FR-D3) — *podmíněné výsledkem W-4* | obě | 2 (jen při „go") |
| **W-3** | Persony: ViewModel + XAML picker | Windows | 3 |
| **W-6** | Bulk operace poznámek (multi-select + delete) | Windows | 3 |
| **T-1** | Testový dluh Epiců B–E (§6) | Windows (Core spustitelné i na macOS) | 3 |
| **M-1** | FSEvents watcher místo one-shot folder syncu | macOS | 4 |
| **M-2** | Export poznámky do PDF (`WKWebView.createPDF`) | macOS | 5 |
| **D1-wire** | Zapojit `ContextualEnricher` do ingesce + settings toggle | obě | 6 (gated na W-4) |

Detailní specifikace FR zůstávají v Epicích B–E níže a slouží jako závazné zadání.

---

## Epic W / M — zbývající položky

### W-4 Retrieval eval sada (FR-D2) — *blokující*

Fixture korpus (10 dokumentů, 30 dotazů se zlatými chunky) + runner měřící **recall@8**; spouští se lokálně, **ne v CI** (běh proti reálným embeddingům je pomalý a závislý na Ollamě).

**Návrh měření musí odpovědět na otázku, kterou W-5 potřebuje.** Samotné `recall@8` nestačí — reranker nemění *retrieval*, jen *pořadí* uvnitř kandidátní množiny. Proto se měří trojice:

1. `recall@8` — dnešní pipeline (fetch 8 + 8 → RRF → top 8).
2. `recall@8` při širším kandidátním okně (fetch N ≫ 8 → RRF → top 8) — kolik dnešní RRF ztratí *ořezem*.
3. `recall@N` — strop kandidátní množiny; tolik by uměl vytáhnout **dokonalý** reranker.

**Headroom rerankeru = `recall@N` − `recall@8`.** Malý headroom ⇒ reranker nemá co zlepšovat ⇒ **no-go** pro W-5 bez ohledu na to, jak dobrý ten cross-encoder je.

**Gate:** výsledek se zapisuje do `docs/eval/` a cituje se v rozhodnutí o W-5 i D1-wire.

### W-5 Reranker (FR-D3) — *podmíněné W-4*

Lokální cross-encoder top-K → top-8 (ONNX MiniLM na Windows, CoreML na macOS). **Zavést jen pokud W-4 prokáže zisk;** jinak vypustit a poznamenat do CHANGELOG.

### W-3 Persony na Windows (FR-C5)

Core je hotové (`Migrator` v18, `Persona` v `Models/Tag.cs`, `NotebookStore.Personas.cs`, `ChatEngine` přijímá `model` + `instructionsOverride`). Chybí:
- `PersonaViewModel` / rozšíření `ChatViewModel` o kolekci person, aktivní personu a „vytvořit personu z aktuálního nastavení".
- Picker v `ChatPage.xaml` (paritní s macOS `ChatView` menu: „Bez persony" / seznam / „Nová…").
- Aplikace persony = instrukce (override) + source set (scope) + model.
- EN+CZ stringy, aktualizace počtu klíčů v `LocalizedStringsTests`.

### W-6 Bulk operace poznámek na Windows (FR-B6 zbytek)

`NotesViewModel` dostane `IsBulkMode`, `SelectedNoteIds`, `BulkDeleteAsync` s confirm dialogem — paritní se `SourcesViewModel.BulkDeleteAsync` a s macOS `NotesView`.

### M-1 FSEvents watcher (FR-E1 zbytek, macOS)

`LiveSourceSync.syncFolder` je testovaná change-detection logika; App vrstva ji dnes volá jen jednou z „Sync folder…" (`SourceListView.swift:342`). Doplnit `FolderWatcher` postavený na `DispatchSource`/FSEvents, který sync spouští při změně složky (s debounce), drží sledovanou cestu napříč starty a jde vypnout. Paritní s Windows `FolderWatchService`.

### M-2 Export poznámky do PDF (FR-B1 PDF část, macOS)

Tisk z editor `WKWebView` (`createPDF`) vedle stávajícího MD exportu — paritní s Windows `ExportPdfAsync`.

### D1-wire Zapojení contextual enrichment (FR-D1, obě)

Settings toggle (default **off**), jeden LLM průchod na zdroj při ingesci, výsledek do `source_chunks.context`, embeduje se `context + "\n" + text`. **Zapnout až po W-4** — bez měření se default nemění.

---

## Epic B — „Reálný projekt": export, hledání, organizace

**Cíl:** Denní práce na projektu s desítkami zdrojů — dostat data dovnitř rychle, najít cokoli, dostat výstupy ven.

- **FR-B1 Export poznámky** → Markdown (`bodyMd` + přílohy do podsložky) a PDF (tisk z editor WebView). — *MD ✅ obě; PDF ✅ Windows / ❌ macOS (M-2).*
- **FR-B2 Export notebooku** → ZIP: `notes/*.md`, `attachments/`, `sources/`, `manifest.json`. — *✅ obě.*
- **FR-B3 Záloha databáze** + obnovení ze zálohy s confirm dialogem. — *✅ obě (Windows přes SQLite online-backup API, macOS přes GRDB backup).*
- **FR-B4 Globální vyhledávání** (Cmd/Ctrl+K paleta) napříč notebooky. — *✅ obě.*
- **FR-B5 Drag & drop** souborů na Sources + fronta ingesce s progress. — *✅ obě.*
- **FR-B6 Hromadné operace:** multi-select zdrojů i poznámek; bulk delete (confirm), bulk summarize zdrojů. — *Zdroje ✅ obě; poznámky ✅ macOS / ❌ Windows (W-6).*
- **FR-B7 Náhled zdroje:** chunky, metadata, u PDF číslo stránky, „Otevřít originál". — *✅ obě.*
- **FR-B8 Tagy** pro poznámky a zdroje (v12) + filtr. — *✅ obě.*
- **FR-B9 Vyhledávání v poznámkách** (`notes_fts`). — *✅ obě.*

### Akceptační kritéria (výběr)

1. Notebook s 30 zdroji a 50 poznámkami: export ZIP obsahuje vše, manifest validní; PDF poznámky odpovídá obsahu editoru.
2. Cmd/Ctrl+K najde poznámku v jiném notebooku do 100 ms na korpusu 10k chunků a skočí na ni.
3. Přetažení 10 souborů najednou → všechny projdou ingescí se status badge, UI neblokuje.
4. Tag filtr kombinovatelný s textovým hledáním.

---

## Epic C — Kvalita chatu (vzory z Onyx)

- **FR-C1 Per-notebook instrukce** → `SystemPrompt` všech chatů, transformací a follow-upů (v13). — *✅ obě.*
- **FR-C2 Pojmenované sady zdrojů** (`source_sets` + `source_set_members`, v13). — *✅ obě.*
- **FR-C3 Editace odeslané zprávy + regenerace** s volbou *(provider, model)*, badge modelu (`chat_messages.model`, v13). — *✅ obě.*
- **FR-C4 Citační panel / popover.** — *✅ obě.*
- **FR-C5 Persony (presety):** instrukce + sada zdrojů + model; picker v chatu (v18). — *Core ✅ obě; UI ✅ macOS / ❌ Windows (W-3).*

**Akceptační kritéria:** instrukce ovlivní odpověď (prompt-assembly test); sada zdrojů omezí retrieval (unit test filtru); regenerace jiným modelem vytvoří novou odpověď bez ztráty historie; citační panel ukazuje právě zdroje z `citations` dané zprávy; persona aplikuje instrukci + sadu + model na nový chat.

---

## Epic D — Kvalita retrievalu

- **FR-D1 Contextual chunk enrichment:** při ingesci volitelně (settings toggle, default off) vygenerovat 1–2větný kontext dokumentu a předřadit jej textu chunku před embeddingem. Sloupec `source_chunks.context` (v14). Jeden LLM průchod **na zdroj**, ne na chunk. — *Core ✅ obě, nezapojeno (D1-wire).*
- **FR-D2 Mini eval sada:** viz **W-4**. Bez měření nezapínat D1 defaultně. — *Harness ✅ macOS, korpus + běh chybí.*
- **FR-D3 Reranker:** viz **W-5**. Zavést jen pokud D2 prokáže zisk. — *❌ obě.*

---

## Epic E — Živé zdroje a nástroje

- **FR-E1 Sledovaná složka:** porovnat mtime/hash, změněné reindexovat, smazané označit stale (ne mazat). `sources.last_synced_at`, `sources.content_hash` (v15). — *✅ Windows (kontinuální); macOS one-shot (M-1).*
- **FR-E2 Re-crawl URL** — diff hash → reindex. — *✅ obě.*
- **FR-E3 Opt-in web search** v chatu (per-message toggle, default off); výsledky jako **user-message context, ne system prompt**. — *✅ obě.*

---

## 6. Testový dluh Epiců B–E

Implementace B–E přinesla migrace a několik oprav testů, ne plné pokrytí akceptačních kritérií.

**Windows Core (`net10.0` — spustitelné i mimo Windows, žádná výmluva):** chybí testy pro
`NotebookStore.Tags`, `NotebookStore.SourceSets`, `NotebookStore.Personas`, `ExportService`,
`NotebookStore.Search` (global search), `ContextualEnricher`, `FolderWatchService`, `WebSearchAdapter`.
Sada `windows/tests/AINotebook.Core.Tests/` dnes tato témata nepokrývá vůbec. → **T-1**

Cílené případy:

- **B:** ExportService — round-trip ZIP (manifest validní, přílohy i `rawPath` soubory přítomné); PDF export produkuje neprázdný validní soubor; DB backup → restore obnoví identická data; GlobalSearch najde poznámku i zdroj napříč notebooky a vrátí správný skok-cíl; tag filtr + text search kombinace; `notes_fts` relevance.
- **C:** per-notebook instrukce se propíše do `SystemPrompt`; source set omezí retrieval scope; regenerace jiným modelem vytvoří nový `chat_messages` řádek s `model` a nezničí historii; persona CRUD + aplikace.
- **D:** contextual enrichment předřadí kontext před embeddingem a udělá **jeden** LLM průchod na zdroj (ověřit počet volání); eval runner (W-4) vypíše recall@8 nad fixture korpusem.
- **E:** folder watch detekuje změněný/smazaný soubor (mtime/hash) a označí stale, ne smaže; re-crawl reindexuje jen při změně hashe; **web search výsledky jdou do user-message contextu, ne do system promptu** (bezpečnostní regrese test).
- **UI-kompoziční smoke testy:** každý nový tab/dialog instancuje reálnou stránku, ne placeholder.

---

## 7. Průřezové požadavky (platí pro všechny epicy)

1. **Parita platforem.** Každá funkce se implementuje na obou platformách. Čísla **feature** migrací musí být identická (v12 tagy, v13 chat, v14 retrieval, v15 živé zdroje, v18 persony); Windows-only repair migrace (v16, v17) jsou dokumentovaná výjimka. Další feature migrace = **v19 na obou**.
2. **Lokalizace.** Každý nový string EN + CZ; Windows: `StringKey` + oba `Resources.resw` + aktualizovat počet klíčů v `LocalizedStringsTests`; macOS: `Localization.swift`.
3. **Testy.** Core logika unit testy na obou platformách. Windows Core testy jdou spustit i na macOS (`dotnet test tests/AINotebook.Core.Tests`) — používat to. UI-kompoziční smoke testy rozšiřovat s každým epicem. Dluh viz §6.
4. **Bezpečnost.** API klíče jen v OS úložišti; export nikdy neobsahuje klíče ani interní cesty; web fetch/re-crawl/web search drží CSP a sanitizaci a jdou jako **user-message context, ne system prompt**; všechny SQL přes parametrizované dotazy. Windows: **veškerý přístup k `SqliteConnection` serializovaný přes `_gate`** (invariant zavedený v 0.13.0).
5. **CI.** Windows: locked-mode NuGet restore — každá změna závislostí = regenerace `packages.lock.json` pro všechny 4 projekty. Release: bump root `VERSION` + **oba in-code version konstanty** (`AINotebookVersion.swift` + `AINotebookVersion.cs`, guard testy hlídají shodu) + CHANGELOG + tag `v*`.
6. **Local-first slib.** Cloud (provideři, web search) vždy opt-in s privacy gate; výchozí instalace funguje plně offline s Ollamou.

---

## 8. Historie (dokončeno)

| Verze | Obsah |
|---|---|
| win-v0.8.1 / v0.8.2 | **Epic P0** — hotfix Windows UI: 4 taby detailu notebooku, koordinátory, editor end-to-end, model management; Windows launch hotfix. |
| v0.9.0 | **Epic A** — multi-provider AI na obou platformách, per-role volba modelu, Keychain/Credential Manager, embeddingy klíčované `provider:model`. |
| v0.9.1 | Security patch (SQLitePCLRaw 2.1.11 → 3.0.3, HIGH). |
| v0.9.2 | Enforcement privacy consentu + Windows data-integrity opravy (v16, v17). |
| v0.10.0 | In-app update check na obou platformách. |
| **v0.11.0** | **Epic M — parita macOS**: schéma v12–v15 + v18, Epicy B/C/D1-core/E na macOS, persony (C5) včetně UI, `RetrievalEval` harness; Windows W-1 PDF export + W-2 bulk summarize. |
| v0.12.0–v0.12.2 | Windows UI/UX opravy: crash při otevření notebooku, welcome wording, EN default, app ikona, tab spacing, zarovnání instrukcí; GitHub Pages produktový web. |
| **v0.13.0** | Code-review fixy obě platformy: serializace SQLite přístupu přes `_gate`, path traversal v `AttachmentStore`, `Retry-After` na Windows, backup přes SQLite online-backup API, model tag u assistant zpráv, „Regenerate with…" na Windows. |

---

## 9. Pořadí a release plán (dopředu)

| Pořadí | Práce | Cílový release |
|---|---|---|
| 1 | **W-4** eval sada (D2) → rozhodnutí o **W-5** | v0.14.0 |
| 2 | **W-3** persony UI + **W-6** bulk poznámky (Windows) + **T-1** testový dluh | v0.14.0 |
| 3 | **M-1** FSEvents watcher (macOS) | v0.14.0 |
| 4 | **W-5** reranker — *jen při „go" z W-4* | v0.15.0 |
| 5 | **M-2** PDF export macOS + **D1-wire** (gated na W-4) | v0.15.0 |

**Priorita:** W-4 jde první, protože blokuje dvě rozhodnutí (W-5 i D1-wire) — bez čísel se ani jedno nezapíná. Zbytek jsou malé adresné položky, které dotahují paritu (W-3, W-6, M-1) a testové pokrytí (T-1); jdou dodávat po samostatných PR. Každý PR musí držet průřezové požadavky (§7) — zvlášť identická čísla migrací a EN+CZ stringy.
