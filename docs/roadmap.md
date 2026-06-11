# AI Notebook — detailní zadání vývoje

*Baseline: v0.8.0 (NotebookLM Stage C), 2026-06-11. Dual-platform: macOS (Swift/SwiftUI, `Sources/`) + Windows (.NET 10 / WinUI 3, `windows/`). Tento dokument je závazné zadání — nahrazuje předchozí rámcový roadmap.*

---

## 0. Kontext a současný stav

Obě platformy sdílejí datový model (11 tabulek, 10 migrací) a RAG pipeline:

| Oblast | Stav |
|---|---|
| Notebooky, poznámky (TipTap WYSIWYG, verze, přílohy) | ✅ obě platformy |
| Zdroje: PDF, TXT, MD, web, DOCX/PPTX/XLSX + auto-indexace poznámek | ✅ obě platformy |
| Hybrid retrieval (cosine + FTS5 BM25 → RRF), source-scoped chat | ✅ obě platformy |
| Chat s citacemi `[N]`, streaming, follow-up chips, per-source souhrny | ✅ obě platformy |
| Transformace (šablony, built-in + vlastní, batch, historie) | ✅ obě platformy |
| Ollama onboarding, správa modelů, EN/CZ lokalizace (155 klíčů) | ✅ obě platformy |
| **Windows: obsah tabů detailu notebooku** | ❌ **placeholder — viz Epic P0** |
| Cloud AI provideři | ❌ chybí — viz Epic A |
| Export/import/záloha, globální hledání, drag & drop, tagy | ❌ chybí — viz Epic B |

### Kritický nález (důvod Epicu P0)

`windows/src/AINotebook.App/Views/NotebookDetailPage.xaml:29-42` obsahuje ve všech čtyřech `PivotItem` pouze placeholder texty „Sources (Plan 3)“ atd. Stránky `SourceListPage`, `ChatPage`, `NotesPage`, `TransformationsPage` jsou kompletně implementované (XAML + ViewModely + testy), ale **nikde v aplikaci se neinstancují** — grep na jejich konstruktory nenajde jediné použití mimo definici. Důsledek: Windows build v0.8.0 zobrazuje v detailu notebooku jen placeholdery; Stage C funkce jsou z UI nedosažitelné. `MainWindow.FindActiveNotesPage` (Ctrl+S, Ctrl+Shift+H) nikdy nic nenajde. CI to nechytilo, protože neexistují UI-kompoziční testy.

---

## Epic P0 — Hotfix Windows UI (release win-v0.8.1)

**Cíl:** Zprovoznit Windows UI tak, aby všechny implementované funkce byly reálně dostupné.

### Požadavky

- **P0-1 Zapojení obsahu tabů.** `NotebookDetailPage` při výběru tabu lazy-vytvoří příslušnou stránku a vloží ji do odpovídajícího hostu (`SourcesHost`/`ChatHost`/`NotesHost`/`TransformationsHost`); placeholder `TextBlock` odstranit. Stránka se vytváří jednou na životnost `NotebookDetailPage` (ne při každém přepnutí), aby chat/editor nepřišly o stav. Konstruktory: `SourceListPage(Notebook)`, ostatní bezparametrické — ověřit a sjednotit předání aktuálního notebooku (ViewModely jej dnes berou z DI/holderů).
- **P0-2 Koordinátory.** Ověřit funkčnost `TabSwitchCoordinator` (transformace → „Open note“ → skok na Notes tab + výběr poznámky přes `NoteJumpCoordinator`) a `NoteEditorCoordinator` (hlídání neuložených změn při přepnutí poznámky/tabů).
- **P0-3 Editor end-to-end.** Po zapojení NotesPage ověřit WebView2 ↔ TipTap bridge: load obsahu, change events, autosave, Ctrl+S, historie (Ctrl+Shift+H), přílohy.
- **P0-4 Model management akce.** Dopojit tlačítka Pull/Delete v `ModelManagementDialog` na `OllamaClient.PullAsync`/`DeleteModelAsync` (Core metody existují), včetně progress UI pro pull a confirm dialogu pro delete.
- **P0-5 UI-kompoziční testy.** Do `AINotebook.App.Tests` přidat testy, které instancují `NotebookDetailPage` a ověří, že po výběru každého tabu host obsahuje očekávaný typ stránky (ne `TextBlock`). Pokud WinUI runtime v testech nelze plně nastartovat, minimálně test factory metody, která taby plní. Cíl: třída chyb „stránka existuje, ale není zapojená“ už neprojde CI.

### Akceptační kritéria

1. Windows build: výběr notebooku → 4 taby zobrazují reálný obsah; zdroj lze přidat, chat odpovídá s citacemi, poznámku lze editovat a uložit, transformaci spustit.
2. Ctrl+S a Ctrl+Shift+H fungují v Notes tabu.
3. Pull i delete modelu funguje z dialogu.
4. Nové UI testy zelené v CI.
5. Release: bump `VERSION` → 0.8.1, tag `win-v0.8.1`.

---

## Epic A — AI provideři: Ollama + cloud (OpenAI/ChatGPT, Anthropic/Claude, OpenAI-kompatibilní)

**Cíl:** Uživatel může vedle lokální Ollamy připojit cloudové AI providery, u každého **explicitně zvolit model**, kterým se zpracovává chat (a kde to dává smysl i embeddings). Local-first zůstává: výchozí chování beze změny, cloud je opt-in.

### A.1 Funkční požadavky

- **FR-A1 Registr providerů.** Typy: `ollama` (vestavěný, vždy přítomný), `anthropic`, `openai`, `openai_compatible` (LM Studio, OpenRouter, vLLM, …). Uživatel může přidat více instancí téhož typu (např. dva OpenAI-kompatibilní endpointy). Provider má: název (uživatelský), typ, base URL, API klíč, stav enabled/disabled.
- **FR-A2 Výchozí base URL** předvyplnit dle typu: Anthropic `https://api.anthropic.com`, OpenAI `https://api.openai.com`, openai_compatible prázdné (povinné), Ollama `http://127.0.0.1:11434` (stávající, editovatelné).
- **FR-A3 Načtení modelů providera** („Fetch models“, vzor Onyx): Ollama `GET /api/tags` (stávající), Anthropic `GET /v1/models`, OpenAI a kompatibilní `GET {base}/v1/models`. Vždy navíc povolit **ruční zadání libovolného model ID** (kompatibilní servery často `/v1/models` neimplementují korektně).
- **FR-A4 Volba modelu.** Globální nastavení = dvojice *(provider, model)* zvlášť pro **chat** a zvlášť pro **embeddings**. UI picker zobrazuje modely seskupené podle providera („Anthropic — claude-sonnet-4-6“). Pod kterým modelem se zpracovává každý požadavek musí být deterministické a viditelné v nastavení.
- **FR-A5 Embeddings omezení.** Anthropic embeddings API nemá — v embedding pickeru se providery typu `anthropic` nenabízejí. Embeddings podporují: `ollama` (`/api/embed`), `openai` a `openai_compatible` (`POST /v1/embeddings`).
- **FR-A6 Streaming chat** u všech providerů, beze změny RAG pipeline: retrieval, skládání kontextu (`SystemPrompt`), citace `[N]`, follow-upy, transformace a souhrny jdou přes stejnou abstrakci — vyměňuje se jen transport.
- **FR-A7 Bezpečné uložení klíčů.** API klíče se ukládají výhradně do OS úložiště: macOS Keychain (`kSecClassGenericPassword`, service `AINotebook`, account = provider id), Windows `Windows.Security.Credentials.PasswordVault` (resource `AINotebook`, userName = provider id). V SQLite je jen reference (provider id). Klíč se nikdy neloguje, neexportuje, nezobrazuje zpět v UI (jen „klíč uložen ✓ / změnit“).
- **FR-A8 Privacy gate.** Při prvním povolení cloud providera zobrazit potvrzovací dialog: obsah poznámek a zdrojů (chunky vybrané retrievalem + dotazy) bude odesílán třetí straně. Souhlas se ukládá per provider. Bez souhlasu provider zůstane disabled.
- **FR-A9 Test připojení.** Tlačítko „Test“ u providera: provede `GET /v1/models` (Ollama `/api/tags`) a zobrazí výsledek (OK / 401 neplatný klíč / síťová chyba). 
- **FR-A10 Chybové stavy v chatu.** Mapování: 401 → „Neplatný API klíč“, 429 → retry s respektováním `retry-after`, 5xx/529 → stávající exponenciální backoff (2 pokusy), Anthropic `stop_reason: "refusal"` → zobrazit jako odmítnutí, ne jako prázdnou odpověď. Chyby se zobrazují stávajícím error řádkem v chatu, lokalizovaně.
- **FR-A11 Změna embedding modelu/providera** prochází stávajícím re-embed flow (confirm + přepočet). Záznamy v `chunk_embeddings.model` nově nesou plně kvalifikovaný identifikátor `"{providerId}:{model}"`, aby kolize mezi stejnojmennými modely různých providerů nevracely špatné vektory.
- **FR-A12 Onboarding beze změny** (Ollama-first). Cloud provideři se přidávají v Settings. Pokud Ollama neběží a uživatel má nakonfigurovaný cloud chat model, app funguje (jen embeddings vyžadují embedding providera).

### A.2 Technický návrh

**Abstrakce (obě platformy).** Windows už má `IChatStreaming` a embedding adaptér (`Core/Ollama/OllamaAdapters.cs`) — zavést totéž jako formální rozhraní:

```
IChatStreaming:   stream(messages: [ChatTurn], system: String, model: String) -> AsyncSequence<String>
IEmbedding:       embed(texts: [String], model: String) -> [[Double]]
IModelCatalog:    listModels() -> [ModelInfo]
```

Na macOS zavést ekvivalentní Swift protokoly (`ChatStreaming`, `EmbeddingProviding`, `ModelCatalog`) a `OllamaClient` pod ně zapojit. `ChatEngine`, `TransformationEngine`, `FollowupSuggester`, `SourceSummarizer`, `Embedder` závisejí jen na rozhraních; konkrétní klient se vybírá podle nastaveného *(provider, model)* přes `ProviderRegistry`.

**Pozor na systémový prompt:** dnešní `SystemPrompt` se u Ollamy posílá jako message s rolí `system`. Anthropic vyžaduje systémový prompt v top-level poli `system` (ne v `messages`). Rozhraní proto předává `system` zvlášť a adaptér si jej zařadí dle API.

**Anthropic adaptér.**
- Endpoint `POST {base}/v1/messages`, hlavičky `x-api-key: <key>`, `anthropic-version: 2023-06-01`, `content-type: application/json`.
- Tělo: `model`, `max_tokens` (default 8192, konstanta v adaptéru), `system`, `messages` (role `user`/`assistant`), `stream: true`.
- Streaming = SSE: číst `content_block_delta` s `delta.type == "text_delta"` → token; `message_delta` nese `stop_reason`; `message_stop` konec. Ošetřit `stop_reason: "refusal"` (FR-A10).
- Discovery: `GET /v1/models` (vrací `id`, `display_name`). Fallback nabídka při nedostupnosti: `claude-opus-4-8` (doporučený default), `claude-sonnet-4-6`, `claude-haiku-4-5`, `claude-fable-5`. **Model ID používat přesně takto — bez datových suffixů.**
- Windows: použít oficiální SDK `dotnet add package Anthropic` (`AnthropicClient`, `Messages.CreateStreaming`, typ `RawMessageStreamEvent` + `TryPickContentBlockDelta`); přidání balíčku = regenerovat NuGet lockfiles (`packages.lock.json`) a ověřit `--locked-mode` v CI. macOS: žádné oficiální Swift SDK — raw HTTP přes `URLSession.bytes(for:)` + řádkový SSE parser (vzor: stávající `OllamaClient` streaming).

**OpenAI / OpenAI-kompatibilní adaptér.**
- Chat: `POST {base}/v1/chat/completions`, hlavička `Authorization: Bearer <key>`, tělo `model`, `messages` (vč. role `system`), `stream: true`. SSE řádky `data: {...}`, token v `choices[0].delta.content`, konec `data: [DONE]`.
- Embeddings: `POST {base}/v1/embeddings`, tělo `model`, `input: [String]` → `data[].embedding`. Doporučený default model `text-embedding-3-small`.
- `openai_compatible` = stejný tvar, jiné base URL; klíč volitelný (LM Studio ho nevyžaduje).
- Implementace na obou platformách raw HTTP (jeden adaptér pro `openai` i `openai_compatible`).

**Úložiště konfigurace.** Migrace **v11** (obě platformy, stejné číslo!):

```sql
CREATE TABLE providers (
  id TEXT PRIMARY KEY,            -- uuid
  type TEXT NOT NULL,             -- ollama|anthropic|openai|openai_compatible
  name TEXT NOT NULL,
  base_url TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  privacy_acknowledged INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
```

Seed: jeden řádek `ollama` z dosavadního nastavení. Nastavení modelů rozšířit na `chat_provider_id` + `chat_model`, `embedding_provider_id` + `embedding_model` (migrace stávajících hodnot na Ollama providera). API klíč v DB **není** (FR-A7) — zavést `ISecretStore` rozhraní (Keychain/PasswordVault implementace + in-memory pro testy).

### A.3 UI specifikace

**Settings → sekce „AI provideři“** (macOS `SettingsView`, Windows `SettingsDialog`):
- Seznam providerů: název, typ, stav (●zelená dosažitelný / ●červená chyba / šedá disabled), výchozí badge u providera použitého pro chat/embeddings.
- „Přidat providera“ → sheet/dialog: typ (picker), název, base URL (předvyplněné), API klíč (`SecureField`/`PasswordBox`), tlačítko „Test připojení“, Save. Editace: stejný formulář, klíč zobrazen jako „uložen ✓ — změnit“.
- **Chat model picker** a **Embedding model picker**: dvouúrovňový výběr (provider → model z `listModels()` + pole „vlastní model ID“). Embedding picker filtruje providery bez embeddings (FR-A5).
- Privacy dialog (FR-A8) při prvním enable cloud providera.
- Všechny nové stringy lokalizovat EN + CZ (macOS `Localization.swift`, Windows `.resw` + `StringKey`; aktualizovat paritní test počtu klíčů).

### A.4 Akceptační kritéria

1. Uživatel přidá Anthropic providera s klíčem, načte modely, vybere `claude-sonnet-4-6` jako chat model → chat streamuje odpovědi s funkčními citacemi, follow-upy a scoped chatem; totéž s OpenAI a LM Studio (openai_compatible).
2. Klíč přežije restart aplikace, v souboru `db.sqlite` se nevyskytuje (ověřit testem: dump DB neobsahuje klíč).
3. Bez nakonfigurovaného cloudu se chování aplikace nijak nemění (Ollama default, žádné nové dialogy).
4. Neplatný klíč → srozumitelná chyba v chatu i v Testu připojení; výpadek sítě → chyba, ne pád; 429 → automatický retry.
5. Přepnutí embedding modelu na OpenAI vyvolá re-embed confirm; po přepnutí retrieval funguje; přepnutí zpět na Ollamu rovněž (vektory se nemíchají — klíčování `provider:model`).
6. Transformace, souhrny zdrojů a follow-upy běží přes zvoleného chat providera.
7. Windows CI: locked-mode restore projde s novým balíčkem; všechny testy zelené. macOS: build + testy zelené.

### A.5 Testy

- Unit: builder request body per provider (system prompt umístění, role mapping, scoping beze změny), SSE parsery na fixture streamech (Anthropic eventy, OpenAI `data:` řádky, `[DONE]`, refusal), error mapping 401/429/5xx, klíčování embeddingů `provider:model`.
- Integrace: mock HTTP server (lokální) pro oba tvary API; `ISecretStore` in-memory.
- Manuální checklist: skutečný Anthropic + OpenAI klíč, LM Studio lokálně.

---

## Epic B — „Reálný projekt“: export, hledání, organizace

**Cíl:** Denní práce na projektu s desítkami zdrojů — dostat data dovnitř rychle, najít cokoli, dostat výstupy ven.

### Požadavky

- **FR-B1 Export poznámky** → Markdown (`bodyMd` + přílohy do podsložky) a PDF (tisk z editor WebView). Menu/kontextová akce v Notes.
- **FR-B2 Export notebooku** → ZIP: `notes/*.md`, `attachments/`, `sources/` (původní soubory z `rawPath`), `manifest.json` (metadata, verze schématu).
- **FR-B3 Záloha databáze** jedním kliknutím (kopie `db.sqlite` + attachments do zvoleného umístění) + obnovení ze zálohy s confirm dialogem.
- **FR-B4 Globální vyhledávání** (Cmd/Ctrl+K paleta): fulltext přes poznámky, zdroje (FTS indexy existují) a názvy chatů, napříč notebooky; výsledky s náhledem; Enter = skok (notebook → tab → položka). Včetně akcí („Nový zápisek“, „Přepnout notebook…“).
- **FR-B5 Drag & drop** souborů na Sources tab (macOS `onDrop`, Windows `DragOver/Drop` na `SourceListPage`) + multi-výběr ve file pickeru; fronta ingesce s progress přehledem.
- **FR-B6 Hromadné operace:** multi-select v seznamu zdrojů a poznámek; bulk delete (confirm), bulk summarize zdrojů.
- **FR-B7 Náhled zdroje:** klik na zdroj otevře detail — extrahovaný text po chuncích, metadata (typ, URI, datum, počet chunků, stav embeddingů), u PDF číslo stránky chunku; akce „Otevřít originál“.
- **FR-B8 Tagy** pro poznámky a zdroje: migrace **v12** (`tags`, `note_tags`, `source_tags`), UI: přiřazení tagů, filtr v seznamech, tag chips. Notebooky zůstávají ploché.
- **FR-B9 Vyhledávání v poznámkách na Windows** (parita s macOS) — search pole nad seznamem poznámek.

### Akceptační kritéria (výběr)

1. Notebook s 30 zdroji a 50 poznámkami: export ZIP obsahuje vše, manifest validní; PDF poznámky odpovídá obsahu editoru.
2. Cmd/Ctrl+K najde poznámku v jiném notebooku do 100 ms na korpusu 10k chunků a skočí na ni.
3. Přetažení 10 souborů najednou → všechny projdou ingescí se status badge, UI neblokuje.
4. Tag filtr kombinovatelný s textovým hledáním.

---

## Epic C — Kvalita chatu (vzory z Onyx)

- **FR-C1 Per-notebook instrukce** (Projects pattern): textové pole v detailu notebooku; obsah se vkládá do `SystemPrompt` všech chatů, transformací notebooku a follow-upů. Migrace **v13**: `notebooks.instructions TEXT`.
- **FR-C2 Pojmenované sady zdrojů** (document sets): uložené scopy — `source_sets(id, notebook_id, name)` + `source_set_members`. Scope popover nabízí sady + ad-hoc výběr (stávající). Migrace v13.
- **FR-C3 Editace odeslané zprávy + regenerace odpovědi.** U poslední výměny: „Upravit“ (přepíše user message, smaže odpověď, znovu odešle) a „Regenerovat“ s volbou *(provider, model)* — návaznost na Epic A; u regenerované zprávy zobrazit badge modelu. `chat_messages` rozšířit o `model TEXT` (v13).
- **FR-C4 Citační panel:** pravý postranní panel (toggle) se zdroji aktuálně vybrané odpovědi — titulek zdroje, snippet, skok na chunk/stránku; nahrazuje-doplňuje inline popover.
- **FR-C5 Persony (presety):** pojmenovaná kombinace instrukce + sada zdrojů + model; picker v chatu. Až po C1+C2; nízká priorita.

**Akceptační kritéria:** instrukce ovlivní odpověď (ověřit promptovým testem); sada zdrojů omezí retrieval (unit test filtru); regenerace jiným modelem vytvoří novou odpověď bez ztráty historie; citační panel ukazuje právě zdroje z `citations` dané zprávy.

---

## Epic D — Kvalita retrievalu

- **FR-D1 Contextual chunk enrichment** (Onyx „contextual RAG“): při ingesci volitelně (settings toggle, default off) vygenerovat 1–2větný kontext dokumentu a předřadit jej textu chunku před embeddingem. Sloupec `source_chunks.context TEXT` (v14). Jeden LLM průchod na zdroj (ne na chunk — kontext per dokument, sdílený).
- **FR-D2 Mini eval sada:** skript + fixture korpus (10 dokumentů, 30 dotazů se zlatými chunky) měřící recall@8 retrievalu; spouštěný lokálně (ne CI). Bez měření nezapínat D1 defaultně.
- **FR-D3 (volitelné, až po D2) Lokální cross-encoder reranker** top-K → top-8 (ONNX MiniLM na Windows, CoreML na macOS). Zavést jen pokud D2 prokáže zisk; jinak vypustit.

---

## Epic E — Živé zdroje a nástroje

- **FR-E1 Sledovaná složka:** zdroj typu „folder watch“ — při startu a periodicky porovnat mtime/hash, změněné soubory reindexovat, smazané označit stale (ne mazat). `sources.last_synced_at`, `sources.content_hash` (v15).
- **FR-E2 Re-crawl URL:** akce „Obnovit“ u web zdrojů + volitelný interval; diff hash → reindex.
- **FR-E3 Opt-in web search tool** v chatu (per-message toggle, default off; provider SearXNG/Brave dle konfigurace) s citacemi webových výsledků vedle lokálních. Respektuje privacy gate jako cloud provideři.

---

## Průřezové požadavky (platí pro všechny epicy)

1. **Parita platforem.** Každá funkce se implementuje na obou platformách v rámci téhož epicu. Čísla migrací schématu musí být identická (v11 provideři, v12 tagy, v13 chat, v14 retrieval, v15 živé zdroje). Před implementací epicu sepsat krátký spec chování + stringy (může být sekce v PR description).
2. **Lokalizace.** Každý nový string EN + CZ; Windows: doplnit `StringKey` + oba `.resw`, aktualizovat paritní test počtu klíčů; macOS: `Localization.swift`. Opravit existující hardcoded „Done“ v `NoteWYSIWYGEditor.swift:80`.
3. **Testy.** Core logika unit testy na obou platformách (vzor: stávající 53 testovacích souborů ve Windows Core.Tests). UI-kompoziční smoke testy (zavádí P0-5) rozšiřovat s každým epicem.
4. **Bezpečnost.** API klíče jen v OS úložišti (FR-A7); export (FR-B1/B2) nikdy neobsahuje klíče ani interní cesty; web fetch/re-crawl drží stávající CSP a sanitizaci; všechny nové SQL přes parametrizované dotazy (žádná interpolace — viz bezpečnostní audit 2026-06-06).
5. **CI.** Windows: locked-mode NuGet restore — každá změna závislostí = regenerace `packages.lock.json` pro všechny 4 projekty. Release: bump root `VERSION` + tag `win-v*`.
6. **Local-first slib.** Cloud (provideři, web search) vždy opt-in s privacy gate; výchozí instalace funguje plně offline s Ollamou.

---

## Pořadí a release plán

| Pořadí | Epic | Release |
|---|---|---|
| 1 | **P0** hotfix Windows UI | win-v0.8.1 |
| 2 | **A** AI provideři (cloud + volba modelu) | v0.9.0 |
| 3 | **B** reálný projekt (export, hledání, DnD, tagy) | v0.10.0 |
| 4 | **C** kvalita chatu | v0.11.0 |
| 5 | **D** kvalita retrievalu | v0.12.0 |
| 6 | **E** živé zdroje + web search | v0.13.0 |

P0 je blokující pro vše ostatní na Windows. Epic A je předřazen B, protože FR-C3 (regenerace jiným modelem) i FR-D1 (enrichment) na něm stavějí a uživatelská priorita je vysoká. Uvnitř epiců lze FR dodávat po menších PR; každý PR musí držet průřezové požadavky.
