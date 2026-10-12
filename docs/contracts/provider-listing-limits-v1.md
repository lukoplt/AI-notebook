# Context windows from model listings — normative contract v1

*Status: 2026-10-12. Addendum to the WP2 provider limits (`folder-rag-v1.md` limits DTO, fixture `provider-limits-v1.json`, both unchanged). Fixture: `Tests/fixtures/contracts/provider-listing-limits-v1.json`. Executable reference: `tools/contracts/gen_provider_listing_fixtures.py` (`--check`). Swift `ProviderLimitPolicy.contextWindow(fromModelListing:model:)`, `contextWindow(fromListingItem:)`, `automatic(…, listed:)`, `ProviderDiscovery`, `ProviderRouter`; C# `ProviderLimitPolicy.ContextWindowFromModelListing`, `ContextWindowFromListingItem`, `Automatic(…, listed)`, `ProviderDiscovery`, `ProviderRouter`. No schema change.*

## 1. Why

Only Ollama's `/api/show` fed `provider_model_limits.context_window`. Every OpenWebUI and OpenAI-compatible model was therefore "assumed" at 8 192 tokens — also a 128B model behind OpenWebUI — although many servers advertise the window in the model listing the app already fetches for discovery.

## 2. Parsing (OpenWebUI and OpenAI-compatible only)

The listing body is the discovery response (`GET <root>/api/models` for OpenWebUI, `GET <root>/models` for OpenAI-compatible). The model's item is the first element of the top-level object's `data` array that is an object whose `id` is a string equal to the model ID (exact scalar comparison); no item, no `data` array or a non-object root means unknown. Malformed JSON is an error, which every caller treats as unknown.

The window is the first valid value along these key paths (an invalid value is skipped): `context_length` (OpenRouter, Together), `max_model_len` (vLLM), `max_context_length` (LM Studio), `context_window` (Groq), `max_input_tokens` (LiteLLM), `top_provider.context_length` (OpenRouter), `info.params.num_ctx` (an OpenWebUI model's own parameter), then `openai.context_length`, `openai.max_model_len`, `openai.max_context_length`, `openai.context_window`, `openai.max_input_tokens` (the upstream item OpenWebUI proxies). Valid: a JSON integer (not a boolean, not a fractional or exponent number, not a string) in 2…2³¹−1.

## 3. Limits

`automatic(providerId, type, model, contextWindow, listed)`: when `listed` and the window came from §2 for an OpenWebUI / OpenAI-compatible provider, `runtimeContext = min(window, 32 768)`; otherwise the frozen rule `min(8 192, window)` stands (Ollama's advertised window and the known OpenAI table never raise the runtime). `maxOutputTokens = min(1 024, runtimeContext − 1)`, `source = "auto"`, assumed iff the window is unknown. The 32 768 cap keeps prompts and latency bounded; a user can set any value up to the window in Settings › Models & limits.

## 4. When the listing is read

- **Discovery** (`discoverModels` / `DiscoverModelsAsync`, which Settings runs): `ProviderModelInfo.contextWindow` carries each item's window; every listed model with a window is saved as automatic limits — the conditional upsert never replaces a `user` row, and nothing is saved when the provider's endpoint changed while the request was in flight.
- **Explicit refresh** (`resolveLimits(refresh: true)`, Settings › Models & limits › reset): the listing is read again for that model; any failure other than cancellation leaves the window unknown (assumed 8 192), it never fails the refresh.
- **Chat preparation** never reads the listing (no extra request per turn); it uses the stored row, or the assumed default for a model never discovered.

## 5. UI

When the prepared request's window is unknown, the context preview's warning ("Context size assumed by the app") offers **Set context size**, which opens Settings › Models & limits (macOS: the Settings window at that section; Windows: the Settings page at that section). Opening that section runs discovery, which records any advertised window.
