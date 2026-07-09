# OpenWebUI síťový provider — design spec

*Datum: 2026-07-08 · Stav: schváleno uživatelem (brainstorming) · Navazuje na: `docs/roadmap.md` Epic A*

## 1. Cíl

Uživatel může v Nastavení připojit model dostupný v síti přes [OpenWebUI](https://openwebui.com) server (typicky self-hosted na LAN) a používat ho pro chat, transformace, souhrny a follow-upy — na Windows i macOS.

## 2. Schválená rozhodnutí

| Rozhodnutí | Volba |
|---|---|
| Rozsah OpenWebUI | **Jen chat** — embeddings zůstávají lokální (Ollama). Typ `openwebui` má `supportsEmbeddings = false`. |
| macOS rozsah | **Plný Epic A registr providerů** (parita s Windows) + typ `openwebui` navíc. |
| Způsob napojení | **Vlastní provider typ `openwebui`** — správné API cesty, ne recyklace `openai_compatible` (OpenWebUI neservíruje `/v1/*` na rootu) ani Ollama proxy (nevidí agregované modely). |
| Fázování | **Fáze 1: Windows** (registr existuje, malý PR). **Fáze 2: macOS** (celý Epic A + openwebui). Jeden spec, dva implementační plány. |

## 3. OpenWebUI API (ověřeno z oficiálních docs, `open-webui/docs` → `reference/api-endpoints.md`)

- Chat: `POST {base}/api/chat/completions` — OpenAI-kompatibilní tvar (`{model, messages, stream: true}`), streaming = SSE `data:` řádky, konec `data: [DONE]`, token v `choices[0].delta.content`.
- Modely: `GET {base}/api/models` — vrací `{"data": [{"id", "name", ...}]}`; obsahuje **všechny** modely, které instance agreguje (Ollama za ní, cloud backendy, funkce).
- Auth: `Authorization: Bearer <API klíč>` — klíč volitelný (instance může běžet bez auth), pokud je zadán, posílá se vždy.
- Kořenové `/v1/chat/completions` ani `/v1/models` OpenWebUI **nemá** — proto vlastní typ.

## 4. Fáze 1 — Windows (typ `openwebui`)

Registr providerů na Windows je hotový (Epic A implementován); přidává se pouze nový typ. Žádná DB migrace, žádná změna DI, žádná změna engines.

### 4.1 Změny

1. **`windows/src/AINotebook.Core/Providers/ProviderType.cs`**
   - Nová hodnota `OpenWebUI`; `ToStorageString` → `"openwebui"`; `FromStorageString` mapuje `"openwebui"` (pozor: neznámé stringy dnes padají na `OpenAICompatible` — test na správné mapování).
   - `DefaultBaseUrl` → `""` (povinné, uživatel zadá např. `http://192.168.1.50:3000`).
   - `SupportsEmbeddings` → `false` → typ se nenabídne v embedding pickeru.
   - `ProviderConfig.IsCloud` zahrnuje `OpenWebUI` → privacy gate při prvním zapnutí.
2. **`windows/src/AINotebook.Core/Providers/OpenWebUIChatAdapter.cs`** (nový, `sealed`, `IChatStreaming`)
   - ctor `(HttpClient, string baseUrl, string? apiKey)` — vzor `OpenAIChatAdapter`.
   - `StreamAsync`: `POST {base}/api/chat/completions`, SSE parser shodný s OpenAI adaptérem (jen jiná cesta). Bearer hlavička jen když klíč zadán.
   - Chyby: 401 → `ProviderAuthException`, 429 → `ProviderRateLimitException`, jinak `ProviderException`.
   - `static ListModelsAsync`: `GET {base}/api/models` → `ProviderModelInfo(Id: data[].id, DisplayName: data[].name)`.
   - Sdílený SSE parsing s `OpenAIChatAdapter` lze extrahovat do helperu, pokud to vyjde přirozeně; duplikace ~30 řádků je přijatelná.
3. **`windows/src/AINotebook.App/Services/ProviderRouter.cs`** — tři nové switch arms: `GetChatAdapter`, `ListModelsAsync`, `TestConnectionAsync` (test = `GET /api/models` → OK / 401 / síťová chyba). `GetEmbeddingAdapter` arm pro OpenWebUI **záměrně neexistuje**.
4. **UI** — `AddProviderViewModel.AllTypes` + `AddProviderDialog.TypeDisplayName` → „OpenWebUI (network)“. Pole klíče viditelné, volitelné (jako openai_compatible).
5. **Lokalizace** — nové stringy do `Strings/en-US/Resources.resw` + `Strings/cs-CZ/Resources.resw` (+ `StringKey` enum), zachovat paritu klíčů.

### 4.2 Testy (Fáze 1)

- Unit: SSE parser na fixture streamech (`data:` řádky, `[DONE]`, prázdné delty), request body (model/messages/stream), parse `/api/models`, `FromStorageString("openwebui")` roundtrip, router switch arms.
- UI/VM: type picker obsahuje OpenWebUI; embedding provider picker ho neobsahuje.
- CI: locked-mode restore beze změny (žádný nový NuGet balíček).

## 5. Fáze 2 — macOS (Epic A registr + `openwebui`)

Zrcadlí Windows architekturu. Protokoly `ChatStreaming` (`Sources/AINotebookCore/ChatEngine.swift:12`) a `EmbeddingProducing` (`Sources/AINotebookCore/Embedder.swift:5`) existují — engines (`ChatEngine`, `Embedder`, `Retriever`, `TransformationEngine`) se nemění.

### 5.1 Core (`AINotebookCore`)

1. **Migrace v11** — tabulka `providers` dle roadmapy (stejné schéma i číslo migrace jako Windows):
   ```sql
   CREATE TABLE providers (
     id TEXT PRIMARY KEY, type TEXT NOT NULL, name TEXT NOT NULL,
     base_url TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
     privacy_acknowledged INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
   );
   ```
   Seed: řádek `ollama` (well-known id shodné s Windows `00000000-0000-0000-0000-000000000000`, vestavěný, nesmazatelný) s výchozí base URL `http://127.0.0.1:11434` (macOS dnes endpoint nikde neukládá — hardcoded default v `OllamaClient.swift:13`).
2. **`ProviderType` + `ProviderConfig`** — enum `ollama | anthropic | openai | openaiCompatible | openwebui`; `defaultBaseURL`, `supportsEmbeddings` (false pro anthropic a openwebui), `isCloud` (vše kromě ollama).
3. **`SecretStoring` protokol** + `KeychainSecretStore` (`kSecClassGenericPassword`, service `AINotebook`, account = provider id) + `InMemorySecretStore` pro testy. Klíč nikdy v SQLite ani UserDefaults.
4. **Adaptéry** (chování shodné s Windows implementacemi):
   - `AnthropicChatAdapter` — `POST /v1/messages`, top-level `system`, hlavičky `x-api-key` + `anthropic-version: 2023-06-01`, `max_tokens` 8192, SSE (`content_block_delta`/`text_delta`, `message_delta` `stop_reason`, `refusal` handling), `listModels` `GET /v1/models` + hardcoded fallback.
   - `OpenAIChatAdapter` + `OpenAIEmbeddingAdapter` — `/v1/chat/completions`, `/v1/embeddings`, `/v1/models`, Bearer; pokrývá typy `openai` i `openaiCompatible`.
   - `OpenWebUIChatAdapter` — dle §4.1 bod 2 (chat-only).
   - ⚠️ **CI URLSession gate**: dnes smí URLSession importovat jen `OllamaClient.swift`. Gate rozšířit na whitelist `Sources/AINotebookCore/Providers/*.swift` — networking zůstává ohraničený v Core.
5. **`ProviderRouter`** — konformní k `ChatStreaming` + `EmbeddingProducing`, vzor `windows/.../Services/ProviderRouter.cs`: při každém volání čte aktuální *(providerId, model)* z nastavení, factory switch podle typu, cache adaptérů (invalidace při změně type/baseURL/klíče), Keychain load, fallback Ollama při chybějící konfiguraci; `listModels(providerId)`, `testConnection(type:baseURL:key:)`.

### 5.2 App (`AINotebookApp`)

6. **`AppSettings`** — nové UserDefaults klíče `selectedChatProviderId`, `selectedEmbeddingProviderId` (default = ollama id); stávající `selectedChatModel`/`selectedEmbeddingModel` zůstávají.
7. **Kompoziční root** (`AINotebookApp.swift:31-70`) — do engines se místo `OllamaClient` injektuje `ProviderRouter`. `OllamaClient` zůstává pro onboarding a správu modelů (pull/delete/tags — Ollama-specifické; `ModelManagementSheet`, `OnboardingViewModel` beze změny).
8. **`SettingsView`** — sekce „AI provideři“: seznam (název, typ, stav ●/●/šedá, badge výchozího), „Přidat providera“ sheet (typ picker, název, base URL předvyplněná dle typu, `SecureField` klíč, „Test připojení“, Save), editace (klíč „uložen ✓ — změnit“), privacy dialog při prvním enable každého ne-ollama providera, dvouúrovňové pickery chat + embedding (embedding filtruje anthropic a openwebui) + pole „vlastní model ID“ (FR-A3 — kompatibilní servery často `/v1/models` neimplementují).
9. **Embeddings** — přepnutí embedding providera/modelu jde stávajícím re-embed flow (confirm + přepočet); `chunk_embeddings.model` nově plně kvalifikované `"{providerId}:{model}"` (FR-A11, shodné s Windows) včetně migrace stávajících hodnot.
10. **Lokalizace** — nové `AppText.Key` cases + EN/CZ větve (exhaustivní switch vynutí obojí). Dolokalizovat 2 dnes hardcoded stringy v `SettingsView.swift` (caption `:48`, „Done“ `:104`).
11. **Onboarding beze změny** — Ollama-first (FR-A12). Pokud Ollama neběží a je nastaven síťový/cloud chat provider, chat funguje (jen embeddings vyžadují embedding providera).

### 5.3 Testy (Fáze 2)

- Unit: builder request body per provider (umístění system promptu — Anthropic top-level vs. messages role), SSE parsery na fixture streamech (Anthropic eventy, OpenAI/OpenWebUI `data:` + `[DONE]` + refusal), error mapping 401/429/5xx, klíčování `provider:model`, migrace v11 + seed, `InMemorySecretStore`, Keychain klíč není v DB dumpu.
- Integrace: mock lokální HTTP server pro oba tvary API (OpenAI-like, Anthropic).
- Manuální checklist: reálný OpenWebUI server na LAN, LM Studio (openai_compatible), volitelně Anthropic/OpenAI klíč.

## 6. Chybové stavy (obě platformy, FR-A10)

- 401 → „Neplatný API klíč“ (chat error řádek i Test připojení, lokalizovaně).
- 429 → automatický retry s respektováním `retry-after`.
- 5xx → stávající exponenciální backoff (2 pokusy).
- Síťová chyba / timeout (nedosažitelný LAN server) → lokalizovaná hláška, ne pád — stejné chování jako nedostupná Ollama.
- Anthropic `stop_reason: "refusal"` → zobrazit jako odmítnutí, ne prázdnou odpověď.

## 7. Bezpečnost

- API klíče výhradně v OS úložišti: Windows Credential Manager (hotové, `WindowsPasswordVaultSecretStore`), macOS Keychain (nové). V DB jen provider id. Klíč se neloguje, nezobrazuje zpět v UI, neexportuje.
- Privacy gate před prvním zapnutím každého cloud/síťového providera včetně `openwebui` (data jdou po síti, byť na vlastní server). Souhlas per provider (`privacy_acknowledged`).
- Akceptační test: dump `db.sqlite` neobsahuje klíč (obě platformy).

## 8. Akceptační kritéria

1. **F1 (Windows):** uživatel přidá OpenWebUI providera (URL + klíč), „Test“ OK, fetch models zobrazí agregované modely, vybere chat model → chat streamuje s citacemi `[N]`, follow-upy a transformace fungují. Klíč přežije restart a není v DB. CI zelené (locked-mode beze změny).
2. **F2 (macOS):** totéž na macOS; navíc celá roadmap A.4 — Anthropic/OpenAI/LM Studio provideři funkční, re-embed přepínání OpenAI ↔ Ollama bez míchání vektorů, bez nakonfigurovaného cloudu se chování aplikace nemění (žádné nové dialogy), build + testy zelené.
3. Lokalizační parita EN/CZ zachována na obou platformách (paritní testy aktualizovány).
