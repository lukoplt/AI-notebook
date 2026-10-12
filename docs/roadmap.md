# AI Notebook — detailní zadání vývoje

*Baseline: **v0.15.0** (připravené lokálně na větvi `feat/folder-chat-multilingual-rag` → `claude/wp9`, 2026-10-09, zatím nevydané). Schéma **v19** na obou platformách. Dual-platform: macOS (Swift/SwiftUI, `Sources/`) + Windows (.NET 10 / WinUI 3, `windows/`). Tento dokument je závazné zadání — nahrazuje předchozí rámcový roadmap.*

---

## 0. Kontext a současný stav

Obě platformy sdílejí datový model a RAG pipeline. **Folder chat s vícejazyčnou evidencí (WP0–WP9, spec `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md`) je hotový na obou platformách** a míří do v0.15.0: perzistentní složky (watch, pravidla, cp1250, XLSX), lokální detekce cs/sk/en/de, verzované revize dokumentů a embedding generace (v19), context pack s náhledem, Overview a citace se snapshotem textu a revize. Schéma je na obou platformách **v19**. Zbývají položky v §1, odložené WP7 měření (§1.1) a otevřené rozhodnutí D1 (§0.3).

**UI redesign ve stylu Codexu (větev `feat/ui-redesign`, spec `docs/superpowers/specs/2026-10-10-ui-redesign-codex-style-design.md`) je také hotový na obou platformách a jde do v0.15.0:** sidebar notebooků a chatů, pravý panel (Sources/Notes/Context/Citations), composer s + menu a chipy, přejmenování chatu, Stop během streamování a dokumentový pohled poznámky s Markdown/PDF exportem — tím se uzavřelo i **M-2** (PDF export na macOS). Ruční checklist: §9 v [`docs/release/0.15.0-checklist.md`](release/0.15.0-checklist.md).

**Testy (2026-10-09, větev `claude/wp9`):** macOS **822** zelených (`swift test`), Windows Core **1057** zelených (`dotnet test windows/tests/AINotebook.Core.Tests`). Obě sady obsahují cross-WP integrační testy WP9 (upgrade v18 → v19 → složka → chat → citace → restart; sdílená fixture `Tests/fixtures/contracts/release-integration-v1.json`). Windows App vrstva (včetně nového `--startup-smoke` kroku v CI) **zatím neprošla Windows CI** — viz [`docs/release/0.15.0-checklist.md`](release/0.15.0-checklist.md).

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
| **Epic E:** kontinuální sledování složky (E1 — `FolderWatchService` / `FolderWatcher`), re-crawl URL (E2), opt-in web search (E3) | ✅ obě |
| **Folder chat (WP0–WP9):** perzistentní složky + pravidla + durable ingesce (v19), detekce cs/sk/en/de, typed scope (složky/sady/soubory/prázdný výběr), context pack + náhled + Overview, citace v2 se snapshotem, provider presety / ruční model ID / limity, re-index vedle aktivního indexu | ✅ obě (Windows App čeká na CI) |

### 0.2 Zbývající rozdíly mezi platformami

| FR | Funkce | Windows | macOS | Kam patří |
|---|---|---|---|---|
| B1 | Export poznámky → **PDF** | ✅ (`EditorWebView.ExportPdfAsync` → `CoreWebView2.PrintToPdfAsync`) | ✅ (`NoteDocumentView.exportPDF` → `WKWebView.createPDF`, UI redesign B6) | **M-2** ✅ hotovo (v0.15.0) |

Zbylé tři rozdíly z předchozí verze tohoto dokumentu jsou vyřešené: Windows dostal
persona picker (W-3) i bulk delete poznámek (W-6), macOS dostal kontinuální
sledování složky přes FSEvents (M-1) a s UI redesignem (v0.15.0) i PDF export poznámky (M-2).
**Funkční nerovnost mezi platformami teď žádná nezbývá.**

### 0.3 Co je nedodělané na obou platformách

| FR | Funkce | Stav | Kam patří |
|---|---|---|---|
| D1 | Contextual chunk enrichment — **stále otevřené** (folder deskriptory ani context pack D1 neuzavírají) | Core hotové na obou (`ContextualEnricher`, sloupec `source_chunks.context`, v14), ale **nikde se nevolá**: macOS nemá settings toggle ani hook v `IngestionService`; Windows má DI registraci v `App.xaml.cs` a stringy, ale `EnrichSourceAsync` nemá call-site. | **D1-wire** |
| D1 | **Rozpor se specifikací: počet LLM volání** | FR-D1 říká „jeden LLM průchod **na zdroj** (ne na chunk — kontext per dokument, sdílený)". Obě implementace ale volají model **jednou na každý chunk** (`ContextualEnricher.EnrichSourceAsync` iteruje `foreach chunk`). U zdroje s 50 chunky to je 50 volání místo 1. Testy tento počet záměrně **neověřují**, aby současné chování nezabetonovaly (`ContextualEnricherTests`). | **rozhodnutí** |
| D2 | Mini eval sada (recall@8) | ✅ **hotovo** — fixture korpus `eval/`, runner `swift run ainotebook-eval`, výsledky a rozhodnutí v [`docs/eval/README.md`](eval/README.md). |  |
| D3 | Cross-encoder reranker | ❌ **NO-GO** na základě D2 — viz W-5 níže. |  |

### 0.4 Číslování migrací — parita obnovena

| | macOS | Windows |
|---|---|---|
| Feature migrace | v1–v15, v18, v19 | v1–v15, v18, v19 |
| Repair migrace | — | v16 (`requalify_embedding_keys`), v17 (`fix_provider_timestamps`) |

v16/v17 jsou **Windows-only opravy dat**, které na macOS nemají protějšek (macOS ekvivalentní vada nevznikla). Číselná řada feature migrací je identická, což §7.1 vyžaduje. v19 (`v19_folder_rag`) přidala složky, revize, joby a generace na obou platformách. **Další feature migrace = v20 na obou platformách současně.**

---

## 1. Zbývající práce — přehled

| ID | Práce | Platforma | Priorita |
|---|---|---|---|
| **WP7-HW** | Hardwarové měření embedding profilů a kalibrace tokenů, rozhodnutí o výchozím modelu (§1.1) | obě | **1** |
| **D1-wire** | Zapojit `ContextualEnricher` do ingesce + settings toggle — **až po rozhodnutí o počtu volání (§0.3)** | obě | 2 |

Hotovo v tomto kole (v0.15.0): **R-1** (nezávislé `fetchK`/`topK`, viz níže), celý folder chat WP0–WP9 a
**UI redesign** ve stylu Codexu na obou platformách (spec `docs/superpowers/specs/2026-10-10-ui-redesign-codex-style-design.md`,
ruční checklist §9 v [`docs/release/0.15.0-checklist.md`](release/0.15.0-checklist.md)), jehož součástí je **M-2** (PDF export na macOS).
Dříve (v0.14.0): **W-4** (eval sada), **W-5** (NO-GO), **W-3**, **W-6**, **T-1**, **M-1**.

### 1.1 Odloženo z WP7 do dalšího releasu

Uživatel 2026-10-09 rozhodl, že hardwarové měření (WP7 Task 12) se v0.15.0 **nedělá**. Proto:

- Výchozí embedding model zůstává **`nomic-embed-text`**; `Sources/AINotebookCore/Resources/Benchmark/embedding-decision-v1.json` zůstává `status: "pending"` a runtime proto používá zmrazené hodnoty v1 (`fetchK` 32, `topK` 16, podíl evidence 6000 bp). `token-estimate-v2.json` je také `pending` — kalibrovaný odhad tokenů zatím neexistuje.
- Benchmark CLI (macOS `ainotebook-eval --benchmark/--calibrate`, Windows `windows/tools/AINotebook.Eval`) a profile drain jsou v kódu, ale **spí** — nic je v aplikaci nespouští.
- Odložené úkoly: **Task 12** (měření + rozhodnutí), **Task 13** (macOS UI: uložený profil a doporučení), **Task 14** (Windows: fresh default, doporučení, recovery), **Task 17/18** (kalibrovaný estimátor ve frozen chat turnu, Swift/Windows). `tools/benchmark/verify_reports.py` vzniká až v Task 12.

**Jak měření spustit později** (plný postup v `docs/superpowers/plans/2026-10-09-wp7-benchmark.md`, Task 12). Na obou strojích stejný commit, Release build, napájení ze sítě, aplikace zavřená:

```bash
ollama pull nomic-embed-text-v2-moe
ollama pull qwen3-embedding:0.6b
ollama pull bge-m3
ollama pull paraphrase-multilingual
ollama pull llama3.2:3b          # výchozí chat model — jen pro kalibraci promptu, není kandidát
```

macOS:

```bash
swift build -c release --product ainotebook-eval
benchmarkOllamaPid=$(ps -axo pid=,command= | awk '$2 ~ /(^|\/)ollama$/ && $3 == "serve" { print $1 }')
.build/release/ainotebook-eval --calibrate --root eval/multilingual --host http://127.0.0.1:11434 --chat-model llama3.2:3b --embedding-counts all --json docs/eval/wp7/macos-calibration.json --out docs/eval/wp7/macos-calibration.md
.build/release/ainotebook-eval --benchmark --mode live --root eval/multilingual --profiles all --host http://127.0.0.1:11434 --chat-model llama3.2:3b --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --chunks 100000,200000 --queries 200 --warmup 20 --concurrent both --fetch-k 32 --top-k 16 --evidence-share-bp 6000 --runtime-context 8192 --max-output 1024 --seed 17 --ollama-pid "$benchmarkOllamaPid" --json docs/eval/wp7/macos-benchmark.json --out docs/eval/wp7/macos-benchmark.md
```

Windows (PowerShell, kořen repozitáře):

```powershell
dotnet build windows/tools/AINotebook.Eval/AINotebook.Eval.csproj -c Release
dotnet run --no-build -c Release --project windows/tools/AINotebook.Eval -- --calibrate --root eval/multilingual --host http://127.0.0.1:11434 --chat-model llama3.2:3b --embedding-counts all --json docs/eval/wp7/windows-calibration.json --out docs/eval/wp7/windows-calibration.md
$ollamaRoots = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "ollama.exe" -and $_.CommandLine -match '(?:^|\s)serve(?:\s|$)' })
$benchmarkOllamaPid = $ollamaRoots[0].ProcessId
dotnet run --no-build -c Release --project windows/tools/AINotebook.Eval -- --benchmark --mode live --root eval/multilingual --profiles all --host http://127.0.0.1:11434 --chat-model llama3.2:3b --calibration Sources/AINotebookCore/Resources/Benchmark/token-estimate-v2.json --chunks 100000,200000 --queries 200 --warmup 20 --concurrent both --fetch-k 32 --top-k 16 --evidence-share-bp 6000 --runtime-context 8192 --max-output 1024 --seed 17 --ollama-pid $benchmarkOllamaPid --json docs/eval/wp7/windows-benchmark.json --out docs/eval/wp7/windows-benchmark.md
```

Kalibrace se nejdřív importuje do `tools/contracts/gen_benchmark_fixtures.py` (`--calibration … --windows-calibration …`), teprve pak běží benchmark nad vygenerovaným `token-estimate-v2.json`. Gate: warm p95 **< 300 ms** při 100K chunků na obou referenčních strojích; rozhodnutí zapisuje Task 12 Step 5–6.

### 1.2 Budoucí položky (ze spec §13, jen pokud měření ukáže přínos)

- Stemming cs/sk/de — jen pokud eval ukáže ztrátu recallu.
- int8 vektory / sqlite-vec — podle naměřené paměti a výkonu při 200K chunků (WP7).
- Plný map-reduce souhrn složky (dnešní Overview je vzorkovaný výběr výňatků), OCR, interpretace datumových formátů a vzorců v XLSX.
- Přetrénování / rozšíření detektoru jazyka podle naměřené abstence. Zjištění z WP9: česká faktura `eval/multilingual/documents/cs/customer/finance/2026/10/invoice.md` má na úrovni dokumentu štítek `und` (podíl cs 6680 bp < 7000 bp), přestože passage label je `cs` a jiný jazyk nedostane žádný podíl. Held-out report: `docs/eval/language-detector-v1.md` (brána prošla, 40/44 WP1 dokumentů správně, 4 → `und`).

Detailní specifikace FR zůstávají v Epicích B–E níže a slouží jako závazné zadání.

---

## R-1 Oddělit fetchK od topK — ✅ hotovo (v0.15.0)

Hotovo přes WP5/WP8: každá větev retrievalu (lexikální FTS i vektorová nad pinned generací) vybírá vlastní kandidátní pool o velikosti `fetchK` (32), integer RRF fúzuje celé sjednocení a teprve context pack po diverzitě a rozpočtu bere `topK` (16) pasáží. Hodnoty čte `RagRuntimeTuning` z `embedding-decision-v1.json` (dokud je `pending`, platí v1). Znovuměření s reálným embedderem je součástí odloženého WP7 Task 12 (§1.1).

*Původní zadání:*

`Retriever.search(topK:)` používá jedno číslo jak pro velikost kandidátního okna, tak
pro počet vrácených výsledků. Eval (W-4) ukázal, že **retrieval není úzké hrdlo — je jím ořez**:
při okně přes celý korpus dosáhne recall 1.000, ale `recall@8` zůstává 0.633, protože
11 z 30 zlatých chunků skončí na pozicích 9–27.

- `recall@8` = 0.633, `recall@16` = 0.867, `recall@24` = 0.933 (NaturalLanguage embedder).
- Zvednout cut je **zdarma** (jen prompt tokeny) a získá většinu toho, co by přinesl reranker.
- Rozdělení `fetchK`/`topK` je zároveň jediný seam, na který by šel reranker někdy pověsit.

**Akceptační kritérium:** `Retriever.search` přijímá `fetchK` nezávisle na `topK`,
default zachovává dnešní chování, a eval se znovu spustí s `--embedder ollama`.

## Epic W / M — zbývající položky

### W-4 Retrieval eval sada (FR-D2) — ✅ hotovo

Fixture korpus `eval/corpus` (12 dokumentů, 48 chunků produkčním chunkerem) + `eval/queries.json`
(30 dotazů; zlatý chunk se určuje citací fráze, ne indexem, takže fixture přežije rechunking)
+ runner `swift run ainotebook-eval` se třemi embeddery (`lexical` offline floor,
`nl` offline sémantický, `ollama` reálný). Nikdy neběží v CI.

`RetrievalEval.run` dostal parametr `fetchK` — samotné `recall@8` na otázku o rerankeru
odpovědět nejde, protože reranker jen přeskládá kandidátní okno a nikdy nevytáhne chunk,
který se nenačetl. Produkční chování se nemění (`fetchK` defaultuje na `k`).

**Výsledky a plné zdůvodnění: [`docs/eval/README.md`](eval/README.md).**

### W-5 Reranker (FR-D3) — ❌ NO-GO

Reranker má reálnou práci (0.30–0.37 recallu leží v pouhém přeskládání), ale jeho hodnota
není „víc recallu" — je to *recall širokého cutu za cenu kontextu úzkého*. A `recall@16` = 0.867
je k dispozici zdarma. K tomu produkce nemá seam `fetchK`/`topK`, na který by se dal pověsit,
a jakmile ten seam vznikne (R-1), levná varianta je změna konfigurace.

Místo W-5 tedy: **R-1**, pak znovuměření s `--embedder ollama`. Cross-encoder se otevře
znovu jen tehdy, když se po zvednutí cutu ukáže jako úzké hrdlo kontextové okno.

### W-3 Persony na Windows (FR-C5) — ✅ hotovo

`ChatViewModel` má `Personas`, `ActivePersona` a příkazy Apply/Clear/Create; `ChatPage.xaml`
má `DropDownButton` s flyoutem „Žádná / uložené persony / nová". `SendCoreAsync` předává
personě model a instrukce, přičemž explicitní `modelOverride` z regenerate-with má přednost
a prázdné instrukce propadnou na notebookové (FR-C1). +5 EN/CZ klíčů (239, bylo 234).

### W-6 Bulk operace poznámek na Windows (FR-B6 zbytek) — ✅ hotovo

`NotesViewModel` má `IsBulkMode`, výběrovou množinu plněnou stránkou a `BulkDeleteAsync`
s confirm dialogem. `NotesPage` přepíná `ListView` mezi `Single` a `Multiple`; v bulk režimu
zaškrtávání neotevírá poznámky (jinak by na každý klik naskočil unsaved-changes gate).

### M-1 FSEvents watcher (FR-E1 zbytek, macOS) — ✅ hotovo

`FolderWatcher` (Core, testovatelný — 8 testů) obaluje FSEvents stream s debounce;
`FolderWatchController` (App) ho drží přes SwiftUI redrawy a zahazuje sync, pokud už jeden běží.
Tlačítko teď přepíná stav a při zapnutí jednou hned syncuje. Sledování je in-memory
per-session, stejně jako na Windows.

Dvě chyby, které odhalily testy: `kFSEventStreamCreateFlagIgnoreSelf` potlačoval všechny
události způsobené vlastním procesem, a watch se registroval na nerozřešené cestě
(FSEvents doručuje kanonické cesty, takže složka přes symlink nikdy neodpovídala vlastním událostem).

### M-2 Export poznámky do PDF (FR-B1 PDF část, macOS) — ✅ hotovo (v0.15.0)

Tisk z editor `WKWebView` (`createPDF`) vedle stávajícího MD exportu — paritní s Windows `ExportPdfAsync`.
Dodáno s UI redesignem (B6): dokumentový pohled poznámky (`NoteDocumentView.exportPDF`) nabízí Markdown i PDF export.

### D1-wire Zapojení contextual enrichment (FR-D1, obě)

Settings toggle (default **off**), jeden LLM průchod na zdroj při ingesci, výsledek do `source_chunks.context`, embeduje se `context + "\n" + text`. **Zapnout až po W-4** — bez měření se default nemění.

---

## Epic B — „Reálný projekt": export, hledání, organizace

**Cíl:** Denní práce na projektu s desítkami zdrojů — dostat data dovnitř rychle, najít cokoli, dostat výstupy ven.

- **FR-B1 Export poznámky** → Markdown (`bodyMd` + přílohy do podsložky) a PDF (tisk z editor WebView). — *MD ✅ obě; PDF ✅ obě (macOS od v0.15.0, M-2).*
- **FR-B2 Export notebooku** → ZIP: `notes/*.md`, `attachments/`, `sources/`, `manifest.json`. — *✅ obě.*
- **FR-B3 Záloha databáze** + obnovení ze zálohy s confirm dialogem. — *✅ obě (Windows přes SQLite online-backup API, macOS přes GRDB backup).*
- **FR-B4 Globální vyhledávání** (Cmd/Ctrl+K paleta) napříč notebooky. — *✅ obě.*
- **FR-B5 Drag & drop** souborů na Sources + fronta ingesce s progress. — *✅ obě.*
- **FR-B6 Hromadné operace:** multi-select zdrojů i poznámek; bulk delete (confirm), bulk summarize zdrojů. — *✅ obě.*
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
- **FR-C5 Persony (presety):** instrukce + sada zdrojů + model; picker v chatu (v18). — *✅ obě.*

**Akceptační kritéria:** instrukce ovlivní odpověď (prompt-assembly test); sada zdrojů omezí retrieval (unit test filtru); regenerace jiným modelem vytvoří novou odpověď bez ztráty historie; citační panel ukazuje právě zdroje z `citations` dané zprávy; persona aplikuje instrukci + sadu + model na nový chat.

---

## Epic D — Kvalita retrievalu

- **FR-D1 Contextual chunk enrichment:** při ingesci volitelně (settings toggle, default off) vygenerovat 1–2větný kontext dokumentu a předřadit jej textu chunku před embeddingem. Sloupec `source_chunks.context` (v14). Jeden LLM průchod **na zdroj**, ne na chunk. — *Core ✅ obě, nezapojeno (D1-wire); implementace volá model na chunk — rozpor viz §0.3.*
- **FR-D2 Mini eval sada:** viz **W-4**. — *✅ hotovo; výsledky v [`docs/eval/README.md`](eval/README.md).*
- **FR-D3 Reranker:** viz **W-5**. — *❌ **NO-GO** na základě D2; místo něj **R-1**.*

---

## Epic E — Živé zdroje a nástroje

- **FR-E1 Sledovaná složka:** porovnat mtime/hash, změněné reindexovat, smazané označit stale (ne mazat). `sources.last_synced_at`, `sources.content_hash` (v15). — *✅ obě, kontinuální (`FolderWatchService` / `FolderWatcher`).*
- **FR-E2 Re-crawl URL** — diff hash → reindex. — *✅ obě.*
- **FR-E3 Opt-in web search** v chatu (per-message toggle, default off); výsledky jako **user-message context, ne system prompt**. — *✅ obě.*

---

## 6. Testový dluh Epiců B–E — ✅ splaceno

Windows Core mělo pro osm subsystémů **nula testů**. Doplněno (273 → 336):

| Soubor | Pokrývá |
|---|---|
| `Storage/NotebookStoreTagsTests.cs` | FR-B8 — reuse tagu, replace-not-append u `SetNoteTags`, cascade při mazání tagu i poznámky |
| `Storage/NotebookStoreSourceSetsTests.cs` | FR-C2 — scope na notebook, replace členů, cascade při mazání zdroje |
| `Storage/NotebookStorePersonasTests.cs` | FR-C5 — round-trip všech polí, nullable source set/model, cascade s notebookem |
| `Storage/NotebookStoreSearchTests.cs` | FR-B9 + FR-B4 — snippet, scope, reindex po editaci, odolnost proti rozbitým FTS dotazům |
| `Rag/ExportServiceTests.cs` | FR-B1/B2 + bezpečnost — zip-slip, únik cest, izolace notebooku |
| `Rag/ContextualEnricherTests.cs` | FR-D1 — co se ukládá, co se posílá, prázdný zdroj, cancellation |
| `Ingestion/FolderWatchServiceTests.cs` | FR-E1 — lifecycle + reálné souborové události (polling, ne sleep) |
| `Providers/WebSearchAdapterTests.cs` | FR-E3 — mapování DDG odpovědi + **bezpečnostní regrese: výsledky jdou do user turnu, ne do system promptu** |

**Dvě reálné vady nalezené při psaní testů (obě v `ExportService`, obě opravené):**

1. Sanitace názvu souboru se spoléhala jen na `Path.GetInvalidFileNameChars()`, což je
   platform-dependent — na Unixu obsahuje jen `\0` a `/`, takže zpětná lomítka v názvu
   poznámky přežila do jména zip entry, kterou Windows extractor přečte jako traversal.
   Obě lomítka se teď odmítají explicitně. (Swift `ExportService` to dělal správně už dřív.)
2. Poznámky se stejným názvem kolidovaly — dvě entry se stejným jménem, extractor si nechá
   poslední, takže **export tiše ztratil poznámku**. Doplněna de-duplikace podle vzoru z `ExportService.swift`.

**macOS zbytek:** `FolderWatcherTests` (8 testů) + `RetrievalEvalFetchWindowTests` (2 testy).

**Co zůstává nepokryté:** `AINotebook.App.Tests` cílí na `net10.0-windows`, takže ViewModel
a XAML vrstva (persona picker, bulk poznámky) je ověřená až Windows CI, ne lokálně.

## 7. Průřezové požadavky (platí pro všechny epicy)

1. **Parita platforem.** Každá funkce se implementuje na obou platformách. Čísla **feature** migrací musí být identická (v12 tagy, v13 chat, v14 retrieval, v15 živé zdroje, v18 persony); Windows-only repair migrace (v16, v17) jsou dokumentovaná výjimka. v19 = folder RAG; další feature migrace = **v20 na obou**.
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
| v0.14.0 | W-4 eval harness, W-5 NO-GO, persony a bulk poznámky na Windows, FSEvents watcher na macOS. |
| **v0.15.0** *(připraveno, nevydáno)* | **Folder chat + vícejazyčná evidence (WP0–WP9)**: v19, perzistentní složky, detekce cs/sk/en/de, context pack + náhled + Overview, citace v2, provider presety/limity, R-1. **UI redesign** ve stylu Codexu na obou platformách (sidebar notebooků a chatů, pravý panel, composer s + menu a chipy, přejmenování chatu, Stop, dokumentový pohled poznámky s PDF exportem i na macOS = M-2). WP7 hardwarové měření odloženo. |

---

## 9. Pořadí a release plán (dopředu)

| Pořadí | Práce | Cílový release |
|---|---|---|
| 1 | Folder chat WP0–WP9 + R-1 + UI redesign (vč. M-2) (po zelené Windows CI a ručních checklistech) | **v0.15.0** |
| 2 | **WP7-HW** měření + rozhodnutí o výchozím embedderu, Tasks 12/13/14/17/18 (§1.1) | v0.16.0 |
| 3 | Rozhodnout **počet LLM volání u D1** (§0.3), pak **D1-wire** | v0.16.0 |

**Priorita:** WP7-HW je teď nejvýš — bez něj zůstává výchozí `nomic-embed-text` a odhad
tokenů nekalibrovaný. D1-wire je zablokovaný otázkou z §0.3 — zapojit enrichment, který
dělá 50 LLM volání na dokument místo jednoho, by byl drahý omyl.

Každý PR musí držet průřezové požadavky (§7) — zvlášť identická čísla migrací
(další feature migrace = **v20 na obou**) a EN+CZ stringy.
