# OpenWebUI Provider (Windows, Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated `openwebui` provider type to the existing Windows provider registry so a user can chat through any model served by an OpenWebUI server on the network.

**Architecture:** The Windows app already routes all chat/embedding traffic through `ProviderRouter` (the single `IChatStreaming`/`IEmbeddingProducing` implementation) with per-type adapters in `AINotebook.Core/Providers/`. This plan adds one enum value, one sealed adapter (`OpenWebUIChatAdapter` — same SSE wire format as OpenAI but rooted at `/api` instead of `/v1`), three router switch arms, and two UI list entries. Chat-only: `SupportsEmbeddings() == false` keeps OpenWebUI out of the embedding model picker via the existing guard in `SettingsViewModel.RefreshEmbeddingModelsAsync`.

**Tech Stack:** .NET 10, C# (file-scoped namespaces, sealed classes, records), xUnit, System.Text.Json, WinUI 3 (App layer), CommunityToolkit.Mvvm.

**Spec:** `docs/superpowers/specs/2026-07-08-openwebui-network-provider-design.md` §4.

## Global Constraints

- Dev box is **macOS**: `AINotebook.Core` + `AINotebook.Core.Tests` target `net10.0` and build/run locally with `dotnet` 10.0.103. `AINotebook.App` + `AINotebook.App.Tests` target `net10.0-windows10.0.19041.0` and **only build on Windows CI** (`.github/workflows/windows-ci.yml`). App-layer tasks are verified by pushing the branch and watching CI.
- **No new NuGet packages.** CI restores with locked mode; new packages would require regenerating all four `packages.lock.json` files. This plan adds none.
- Forbidden APIs (unpackaged app): `Windows.Storage.ApplicationData`, `Package.Current`, `ApplicationLanguages.PrimaryLanguageOverride`. This plan touches none of them.
- **No new localization strings.** Provider type display names are hardcoded in `AddProviderDialog.TypeDisplayName` (existing pattern); EN/CZ resw parity is untouched.
- OpenWebUI wire facts (verified against official docs `open-webui/docs` → `reference/api-endpoints.md`): chat `POST {base}/api/chat/completions` (OpenAI-shape SSE), models `GET {base}/api/models` returning `{"data":[{"id","name",...}]}`, auth `Authorization: Bearer <key>` — key optional (instance may run with auth disabled). OpenWebUI does **not** serve root `/v1/*`.
- Storage string for the new type is exactly `"openwebui"`; unknown strings must keep falling back to `OpenAICompatible`.
- Commits: conventional prefixes (`feat:`, `test:`, `docs:`), trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Work on branch `feat/openwebui-provider-win` cut from `main`.

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/lukasoplt/Documents/AI_Notebook
git checkout -b feat/openwebui-provider-win main
```

---

### Task 1: `ProviderType.OpenWebUI` enum value + extensions

**Files:**
- Modify: `windows/src/AINotebook.Core/Providers/ProviderType.cs`
- Modify: `windows/src/AINotebook.Core/Providers/ProviderConfig.cs:16-18`
- Test: `windows/tests/AINotebook.Core.Tests/Providers/ProviderTypeTests.cs` (new — no ProviderType tests exist yet)

**Interfaces:**
- Consumes: nothing.
- Produces: `ProviderType.OpenWebUI` enum member; `ToStorageString()` → `"openwebui"`; `FromStorageString("openwebui")` → `OpenWebUI`; `DefaultBaseUrl()` → `""`; `SupportsEmbeddings()` → `false`; `ProviderConfig.IsCloud` → `true` for OpenWebUI. Tasks 2–4 rely on all of these.

- [ ] **Step 1: Write the failing tests**

Create `windows/tests/AINotebook.Core.Tests/Providers/ProviderTypeTests.cs`:

```csharp
using AINotebook.Core.Providers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class ProviderTypeTests
{
    [Fact]
    public void OpenWebUI_storage_string_roundtrips()
    {
        Assert.Equal("openwebui", ProviderType.OpenWebUI.ToStorageString());
        Assert.Equal(ProviderType.OpenWebUI, ProviderTypeExtensions.FromStorageString("openwebui"));
    }

    [Fact]
    public void Unknown_storage_string_still_falls_back_to_OpenAICompatible()
    {
        Assert.Equal(ProviderType.OpenAICompatible, ProviderTypeExtensions.FromStorageString("something_else"));
    }

    [Fact]
    public void OpenWebUI_has_empty_default_base_url()
    {
        Assert.Equal("", ProviderType.OpenWebUI.DefaultBaseUrl());
    }

    [Fact]
    public void OpenWebUI_does_not_support_embeddings()
    {
        Assert.False(ProviderType.OpenWebUI.SupportsEmbeddings());
    }

    [Fact]
    public void OpenWebUI_config_counts_as_cloud()
    {
        var cfg = new ProviderConfig(
            "some-id", ProviderType.OpenWebUI, "LAN server",
            "http://192.168.1.50:3000", true, false, DateTime.UtcNow);
        Assert.True(cfg.IsCloud);
    }

    // Regression net: the four existing types keep their storage behavior.
    [Theory]
    [InlineData(ProviderType.Ollama, "ollama")]
    [InlineData(ProviderType.Anthropic, "anthropic")]
    [InlineData(ProviderType.OpenAI, "openai")]
    [InlineData(ProviderType.OpenAICompatible, "openai_compatible")]
    public void Existing_types_roundtrip(ProviderType t, string s)
    {
        Assert.Equal(s, t.ToStorageString());
        Assert.Equal(t, ProviderTypeExtensions.FromStorageString(s));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter ProviderTypeTests`
Expected: FAIL — compile error `'ProviderType' does not contain a definition for 'OpenWebUI'`.

- [ ] **Step 3: Implement**

In `windows/src/AINotebook.Core/Providers/ProviderType.cs`, make these five edits:

```csharp
public enum ProviderType { Ollama, Anthropic, OpenAI, OpenAICompatible, OpenWebUI }
```

In `ToStorageString`, before the `_ =>` arm:

```csharp
        ProviderType.OpenWebUI => "openwebui",
```

In `FromStorageString`, before the `_ =>` arm (the `_ => ProviderType.OpenAICompatible` fallback stays last):

```csharp
        "openwebui" => ProviderType.OpenWebUI,
```

In `DefaultBaseUrl`, before the `_ =>` arm (explicit even though `_ => ""` would cover it):

```csharp
        ProviderType.OpenWebUI => "",
```

Replace `SupportsEmbeddings`:

```csharp
    // OpenWebUI has no OpenAI-compatible embeddings endpoint — chat only.
    public static bool SupportsEmbeddings(this ProviderType t) =>
        t != ProviderType.Anthropic && t != ProviderType.OpenWebUI;
```

In `windows/src/AINotebook.Core/Providers/ProviderConfig.cs`, extend `IsCloud` (a network server still means content leaves this machine — privacy gate applies):

```csharp
    public bool IsCloud => Type == ProviderType.Anthropic
                        || Type == ProviderType.OpenAI
                        || Type == ProviderType.OpenAICompatible
                        || Type == ProviderType.OpenWebUI;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter ProviderTypeTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Run the full Core suite (an enum member was added — make sure nothing else breaks)**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add windows/src/AINotebook.Core/Providers/ProviderType.cs \
        windows/src/AINotebook.Core/Providers/ProviderConfig.cs \
        windows/tests/AINotebook.Core.Tests/Providers/ProviderTypeTests.cs
git commit -m "feat(win): add openwebui provider type (chat-only, cloud-gated)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `OpenWebUIChatAdapter` (SSE streaming + model listing)

**Files:**
- Create: `windows/src/AINotebook.Core/Providers/OpenWebUIChatAdapter.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Providers/OpenWebUISseTests.cs`

**Interfaces:**
- Consumes: `IChatStreaming`, `ChatTurn`, `ChatRole` (`AINotebook.Core/Ollama/ChatTurn.cs`, `Models/Chat.cs`); `ProviderException`/`ProviderAuthException`/`ProviderRateLimitException` (`Providers/ProviderExceptions.cs`); `ProviderModelInfo` (`Providers/ProviderConfig.cs`).
- Produces (Task 3 relies on these exact signatures):
  - `public OpenWebUIChatAdapter(HttpClient http, string baseUrl, string? apiKey = null)` implementing `IChatStreaming`.
  - `public static Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(HttpClient http, string baseUrl, string? apiKey, CancellationToken ct = default)` — **throws `ProviderAuthException` on 401** (unlike `OpenAIChatAdapter.ListModelsAsync`, which swallows it; the throw is what lets Test connection report "invalid key").

- [ ] **Step 1: Write the failing tests**

Create `windows/tests/AINotebook.Core.Tests/Providers/OpenWebUISseTests.cs` (modeled on `OpenAiSseTests.cs`; the capturing handler additionally records the request URI and headers):

```csharp
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class OpenWebUISseTests
{
    private static HttpClient MakeClient(string body, HttpStatusCode status = HttpStatusCode.OK)
        => new(new StubHandler(status, body));

    private static string SseBody(params string[] jsonLines) =>
        string.Join("\n", jsonLines.Select(j => $"data: {j}")) + "\n";

    // ── Streaming ────────────────────────────────────────────────────────────

    [Fact]
    public async Task Streams_delta_content_tokens()
    {
        var sse = SseBody(
            """{"choices":[{"delta":{"content":"Hello"},"index":0}]}""",
            """{"choices":[{"delta":{"content":", LAN"},"index":0}]}""",
            "[DONE]");
        var adapter = new OpenWebUIChatAdapter(MakeClient(sse), "http://192.168.1.50:3000", "sk-key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("llama3.2", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);
        Assert.Equal(["Hello", ", LAN"], tokens);
    }

    [Fact]
    public async Task Posts_to_api_chat_completions_not_v1()
    {
        Uri? uri = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (u, _, _) => uri = u);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000/", "k");
        await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        Assert.Equal("http://host:3000/api/chat/completions", uri!.ToString());
    }

    [Fact]
    public async Task Request_body_carries_model_messages_and_stream_flag()
    {
        string? body = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (_, b, _) => body = b);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000", "k");
        var turns = new[]
        {
            new ChatTurn(ChatRole.System, "Be concise."),
            new ChatTurn(ChatRole.User, "Hello")
        };
        await foreach (var _ in adapter.StreamAsync("llama3.2", turns)) { }
        Assert.NotNull(body);
        Assert.Contains("\"model\":\"llama3.2\"", body!);
        Assert.Contains("\"role\":\"system\"", body!);
        Assert.Contains("\"stream\":true", body!);
    }

    [Fact]
    public async Task Sends_bearer_header_when_key_present()
    {
        HttpRequestHeaders? headers = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (_, _, h) => headers = h);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000", "sk-abc");
        await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        Assert.Equal("Bearer", headers!.Authorization!.Scheme);
        Assert.Equal("sk-abc", headers.Authorization.Parameter);
    }

    [Fact]
    public async Task Omits_auth_header_when_key_missing()
    {
        HttpRequestHeaders? headers = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (_, _, h) => headers = h);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000", null);
        await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        Assert.Null(headers!.Authorization);
    }

    [Fact]
    public async Task Stops_on_DONE_sentinel()
    {
        var sse =
            """data: {"choices":[{"delta":{"content":"A"},"index":0}]}""" + "\n" +
            "data: [DONE]\n" +
            """data: {"choices":[{"delta":{"content":"SHOULD_NOT_APPEAR"},"index":0}]}""" + "\n";
        var adapter = new OpenWebUIChatAdapter(MakeClient(sse), "http://host:3000", "k");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);
        Assert.Equal(["A"], tokens);
    }

    [Fact]
    public async Task Skips_malformed_json_lines()
    {
        var sse =
            "data: not-json\n" +
            """data: {"choices":[{"delta":{"content":"ok"},"index":0}]}""" + "\n" +
            "data: [DONE]\n";
        var adapter = new OpenWebUIChatAdapter(MakeClient(sse), "http://host:3000", "k");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);
        Assert.Equal(["ok"], tokens);
    }

    [Fact]
    public async Task Throws_ProviderAuthException_on_401()
    {
        var adapter = new OpenWebUIChatAdapter(MakeClient("", HttpStatusCode.Unauthorized),
            "http://host:3000", "bad-key");
        await Assert.ThrowsAsync<ProviderAuthException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    [Fact]
    public async Task Throws_ProviderRateLimitException_on_429()
    {
        var adapter = new OpenWebUIChatAdapter(MakeClient("", (HttpStatusCode)429),
            "http://host:3000", "k");
        await Assert.ThrowsAsync<ProviderRateLimitException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    // ── Model listing ────────────────────────────────────────────────────────

    [Fact]
    public async Task Lists_models_from_api_models_with_display_names()
    {
        Uri? uri = null;
        var handler = new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"id":"gpt-4o","name":"GPT-4o (cloud)"},{"id":"llama3.2","name":"Llama 3.2"}]}""",
            (u, _, _) => uri = u);
        var models = await OpenWebUIChatAdapter.ListModelsAsync(
            new HttpClient(handler), "http://host:3000/", "k");
        Assert.Equal("http://host:3000/api/models", uri!.ToString());
        Assert.Equal(2, models.Count);
        Assert.Contains(models, m => m.Id == "llama3.2" && m.DisplayName == "Llama 3.2");
        Assert.Contains(models, m => m.Id == "gpt-4o" && m.DisplayName == "GPT-4o (cloud)");
    }

    [Fact]
    public async Task ListModels_throws_auth_exception_on_401()
    {
        await Assert.ThrowsAsync<ProviderAuthException>(() =>
            OpenWebUIChatAdapter.ListModelsAsync(
                MakeClient("", HttpStatusCode.Unauthorized), "http://host:3000", "bad"));
    }

    [Fact]
    public async Task ListModels_returns_empty_on_server_error()
    {
        var models = await OpenWebUIChatAdapter.ListModelsAsync(
            MakeClient("", HttpStatusCode.InternalServerError), "http://host:3000", "k");
        Assert.Empty(models);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var resp = new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "text/event-stream")
            };
            return Task.FromResult(resp);
        }
    }

    private sealed class CapturingHandler(
        HttpStatusCode status, string body,
        Action<Uri?, string, HttpRequestHeaders> capture) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var content = request.Content is not null ? await request.Content.ReadAsStringAsync(ct) : "";
            capture(request.RequestUri, content, request.Headers);
            return new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "text/event-stream")
            };
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter OpenWebUISseTests`
Expected: FAIL — compile error `The type or namespace name 'OpenWebUIChatAdapter' could not be found`.

- [ ] **Step 3: Implement the adapter**

Create `windows/src/AINotebook.Core/Providers/OpenWebUIChatAdapter.cs`:

```csharp
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// OpenWebUI streaming chat adapter. OpenWebUI aggregates models (local Ollama,
/// cloud backends, functions) behind an OpenAI-shaped API rooted at /api, NOT /v1:
/// POST {base}/api/chat/completions, GET {base}/api/models.
/// Bearer key optional — instances may run with auth disabled.
/// Chat-only: OpenWebUI exposes no OpenAI-compatible embeddings endpoint.
/// </summary>
public sealed class OpenWebUIChatAdapter : IChatStreaming
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string? _apiKey;

    public OpenWebUIChatAdapter(HttpClient http, string baseUrl, string? apiKey = null)
    {
        _http = http;
        _baseUrl = baseUrl.TrimEnd('/');
        _apiKey = apiKey;
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var wireMessages = messages.Select(m => new
        {
            role = m.Role switch
            {
                ChatRole.System => "system",
                ChatRole.Assistant => "assistant",
                _ => "user"
            },
            content = m.Content
        }).ToList();

        var body = new { model, messages = wireMessages, stream = true };
        var json = JsonSerializer.Serialize(body);

        using var req = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl}/api/chat/completions")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrEmpty(_apiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);

        if (resp.StatusCode == HttpStatusCode.Unauthorized)
            throw new ProviderAuthException("Invalid API key (401).");
        if (resp.StatusCode == (HttpStatusCode)429)
            throw new ProviderRateLimitException("Rate limit exceeded (429).");
        if (!resp.IsSuccessStatusCode)
            throw new ProviderException($"HTTP {(int)resp.StatusCode}.");

        using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);

        string? line;
        while ((line = await reader.ReadLineAsync(ct)) is not null)
        {
            if (!line.StartsWith("data: ", StringComparison.Ordinal)) continue;
            var data = line["data: ".Length..].Trim();
            if (data == "[DONE]") yield break;

            JsonElement root;
            try { root = JsonSerializer.Deserialize<JsonElement>(data); }
            catch { continue; }

            if (!root.TryGetProperty("choices", out var choices)) continue;
            foreach (var choice in choices.EnumerateArray())
            {
                if (!choice.TryGetProperty("delta", out var delta)) continue;
                if (delta.TryGetProperty("content", out var content))
                {
                    var token = content.GetString();
                    if (!string.IsNullOrEmpty(token)) yield return token;
                }
            }
        }
    }

    /// <summary>
    /// GET {base}/api/models → {"data":[{"id","name",...}]}. Includes every model the
    /// key's user can access. Throws ProviderAuthException on 401 so Test connection
    /// can report an invalid key; other failures return an empty list.
    /// </summary>
    public static async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, string? apiKey, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl.TrimEnd('/')}/api/models");
            if (!string.IsNullOrEmpty(apiKey))
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            using var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == HttpStatusCode.Unauthorized)
                throw new ProviderAuthException("Invalid API key (401).");
            if (!resp.IsSuccessStatusCode) return [];
            var json = await resp.Content.ReadAsStringAsync(ct);
            var root = JsonSerializer.Deserialize<JsonElement>(json);
            if (!root.TryGetProperty("data", out var data)) return [];
            var result = new List<ProviderModelInfo>();
            foreach (var item in data.EnumerateArray())
            {
                var id = item.TryGetProperty("id", out var idp) ? idp.GetString() : null;
                if (id is null) continue;
                var name = item.TryGetProperty("name", out var np) ? np.GetString() : null;
                result.Add(new ProviderModelInfo(id, name));
            }
            return result.OrderBy(m => m.Label, StringComparer.OrdinalIgnoreCase).ToList();
        }
        catch (ProviderAuthException) { throw; }
        catch { return []; }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter OpenWebUISseTests`
Expected: PASS (12 tests).

- [ ] **Step 5: Run the full Core suite**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add windows/src/AINotebook.Core/Providers/OpenWebUIChatAdapter.cs \
        windows/tests/AINotebook.Core.Tests/Providers/OpenWebUISseTests.cs
git commit -m "feat(win): OpenWebUI chat adapter (SSE at /api/chat/completions, models at /api/models)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `ProviderRouter` switch arms + router tests

**Files:**
- Modify: `windows/src/AINotebook.App/Services/ProviderRouter.cs` (three switch expressions: `ListModelsAsync` ~line 80, `TestConnectionAsync` ~line 95, `GetChatAdapter` ~line 119)
- Test: `windows/tests/AINotebook.App.Tests/ProviderRouterOpenWebUITests.cs` (new)

**Interfaces:**
- Consumes: `OpenWebUIChatAdapter` (Task 2), `ProviderType.OpenWebUI` (Task 1), existing `ISettingsService`, `ISecretStore`, `NotebookStore`, `OllamaClient`.
- Produces: router dispatches chat streaming, model listing, and connection tests to the OpenWebUI adapter when `cfg.Type == ProviderType.OpenWebUI`. `GetEmbeddingAdapter` is deliberately untouched: `SupportsEmbeddings() == false` prevents OpenWebUI from being used for embeddings (same treatment as Anthropic).

**Note:** this project targets `net10.0-windows...` — it does not build on the macOS dev box. Write the code and the test, commit, and verify on CI in Task 5.

- [ ] **Step 1: Add the three switch arms**

In `ListModelsAsync`, inside the `cfg.Type switch`, before `_ => []`:

```csharp
            ProviderType.OpenWebUI => await OpenWebUIChatAdapter.ListModelsAsync(_http, cfg.BaseUrl, key, ct),
```

In `TestConnectionAsync`, inside the `type switch`, before the `_ =>` arm:

```csharp
                ProviderType.OpenWebUI => await OpenWebUIChatAdapter.ListModelsAsync(_http, baseUrl, apiKey, ct),
```

In `GetChatAdapter`, inside the `cfg.Type switch`, before the `_ =>` arm:

```csharp
            ProviderType.OpenWebUI => new OpenWebUIChatAdapter(_http, cfg.BaseUrl, key),
```

- [ ] **Step 2: Write the router tests**

Create `windows/tests/AINotebook.App.Tests/ProviderRouterOpenWebUITests.cs`:

```csharp
using System.ComponentModel;
using System.Net;
using System.Text;
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

public class ProviderRouterOpenWebUITests
{
    [Fact]
    public async Task TestConnection_openwebui_hits_api_models_and_succeeds()
    {
        Uri? uri = null;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"id":"llama3.2","name":"Llama 3.2"}]}""",
            u => uri = u));
        using var store = new NotebookStore(StorePath.InMemory);
        var router = MakeRouter(store, http);

        var error = await router.TestConnectionAsync(ProviderType.OpenWebUI, "http://host:3000", "sk-k");

        Assert.Null(error);
        Assert.Equal("http://host:3000/api/models", uri!.ToString());
    }

    [Fact]
    public async Task TestConnection_openwebui_reports_error_on_401()
    {
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.Unauthorized, "", _ => { }));
        using var store = new NotebookStore(StorePath.InMemory);
        var router = MakeRouter(store, http);

        var error = await router.TestConnectionAsync(ProviderType.OpenWebUI, "http://host:3000", "bad");

        Assert.NotNull(error);
    }

    [Fact]
    public async Task Chat_routes_to_openwebui_adapter_for_selected_provider()
    {
        Uri? uri = null;
        var sse = "data: {\"choices\":[{\"delta\":{\"content\":\"tok\"},\"index\":0}]}\n" +
                  "data: [DONE]\n";
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK, sse, u => uri = u));

        using var store = new NotebookStore(StorePath.InMemory);
        var cfg = new ProviderConfig(
            "11111111-1111-1111-1111-111111111111", ProviderType.OpenWebUI,
            "LAN", "http://host:3000", true, true, DateTime.UtcNow);
        store.SaveProvider(cfg);

        var settings = new FakeSettings
        {
            SelectedChatProviderId = cfg.Id,
            SelectedChatModel = "llama3.2"
        };
        var router = MakeRouter(store, http, settings);

        var tokens = new List<string>();
        await foreach (var t in router.StreamAsync("ignored", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["tok"], tokens);
        Assert.Equal("http://host:3000/api/chat/completions", uri!.ToString());
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static ProviderRouter MakeRouter(
        NotebookStore store, HttpClient http, ISettingsService? settings = null)
        => new(settings ?? new FakeSettings(), store, new FakeSecrets(),
               new OllamaClient(), http);

    private sealed class FakeSettings : ISettingsService
    {
        public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }
        public AppLanguage Language { get; set; } = AppLanguage.English;
        public bool HasCompletedOnboarding { get; set; } = true;
        public string SelectedChatModel { get; set; } = "llama3.2:3b";
        public string SelectedEmbeddingModel { get; set; } = "nomic-embed-text";
        public string SelectedChatProviderId { get; set; } = ProviderConfig.OllamaId;
        public string SelectedEmbeddingProviderId { get; set; } = ProviderConfig.OllamaId;
    }

    private sealed class FakeSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _map = new();
        public void Save(string providerId, string secret) => _map[providerId] = secret;
        public string? Load(string providerId) => _map.TryGetValue(providerId, out var s) ? s : null;
        public void Delete(string providerId) => _map.Remove(providerId);
    }

    private sealed class CapturingHandler(
        HttpStatusCode status, string body, Action<Uri?> capture) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            capture(request.RequestUri);
            var resp = new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "text/event-stream")
            };
            return Task.FromResult(resp);
        }
    }
}
```

Adjustment rules if reality differs (the implementer cannot compile this locally):
- If `AppLanguage.English` is not the member name, mirror whatever `windows/tests/AINotebook.App.Tests/SettingsServiceTests.cs` uses.
- If `ISecretStore` method signatures differ, mirror `windows/src/AINotebook.App/Services/ISecretStore.cs` exactly.
- If `NotebookStore` is not `IDisposable`, drop the `using`.
- If `StorePath.InMemory` needs different usage, copy the pattern from `windows/tests/AINotebook.App.Tests/NotebookTabCompositionTests.cs:31`.

- [ ] **Step 3: Commit**

```bash
git add windows/src/AINotebook.App/Services/ProviderRouter.cs \
        windows/tests/AINotebook.App.Tests/ProviderRouterOpenWebUITests.cs
git commit -m "feat(win): route chat, model listing and connection test to OpenWebUI adapter

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Add-provider UI — type list, display name, keyless save

**Files:**
- Modify: `windows/src/AINotebook.App/ViewModels/AddProviderViewModel.cs:50-51` (`AllTypes`) and `:84-88` (`CanSave`)
- Modify: `windows/src/AINotebook.App/Views/AddProviderDialog.xaml.cs:68-74` (`TypeDisplayName`)
- Test: `windows/tests/AINotebook.App.Tests/AddProviderViewModelOpenWebUITests.cs` (new)

**Interfaces:**
- Consumes: `ProviderType.OpenWebUI` (Task 1), `ProviderRouter` (Task 3 — the VM ctor requires one).
- Produces: user-visible "OpenWebUI (network)" entry in the Add provider dialog; a new OpenWebUI provider can be saved **without** an API key (spec: key optional — instances can run with auth disabled). Privacy gate fires automatically: `AddProviderDialog.OnClosing` shows `PrivacyGateDialog` for every non-Ollama new provider, no change needed.

- [ ] **Step 1: Extend `AllTypes`**

In `AddProviderViewModel.cs`:

```csharp
    // Types the user can pick in add-mode (all types; Ollama only for custom base URL override)
    public static ProviderType[] AllTypes { get; } =
        [ProviderType.Ollama, ProviderType.Anthropic, ProviderType.OpenAI,
         ProviderType.OpenAICompatible, ProviderType.OpenWebUI];
```

- [ ] **Step 2: Relax `CanSave` for keyless OpenWebUI**

Replace the `CanSave` property in `AddProviderViewModel.cs`:

```csharp
    public bool CanSave =>
        !string.IsNullOrWhiteSpace(Name) &&
        !string.IsNullOrWhiteSpace(BaseUrl) &&
        // Cloud providers require a key for new entries (edit can keep existing).
        // OpenWebUI is exempt: instances may run with auth disabled.
        (SelectedType == ProviderType.Ollama || SelectedType == ProviderType.OpenWebUI
            || EditingId != null || !string.IsNullOrWhiteSpace(ApiKey));
```

- [ ] **Step 3: Add the display name**

In `AddProviderDialog.xaml.cs`, `TypeDisplayName`:

```csharp
    private static string TypeDisplayName(ProviderType t) => t switch
    {
        ProviderType.Anthropic => "Anthropic (Claude)",
        ProviderType.OpenAI => "OpenAI (ChatGPT)",
        ProviderType.OpenAICompatible => "OpenAI-compatible",
        ProviderType.OpenWebUI => "OpenWebUI (network)",
        _ => "Ollama (local)"
    };
```

(Display names are intentionally hardcoded here — existing pattern, no resw change. The providers list in `SettingsDialog.xaml:35` binds `{Binding Type}` and will render the enum name `OpenWebUI`, which is acceptable.)

- [ ] **Step 4: Write the VM tests**

Create `windows/tests/AINotebook.App.Tests/AddProviderViewModelOpenWebUITests.cs`:

```csharp
using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

public class AddProviderViewModelOpenWebUITests
{
    [Fact]
    public void AllTypes_offers_openwebui()
    {
        Assert.Contains(ProviderType.OpenWebUI, AddProviderViewModel.AllTypes);
    }

    [Fact]
    public void CanSave_allows_new_openwebui_without_api_key()
    {
        var vm = MakeVm();
        vm.SelectedType = ProviderType.OpenWebUI;
        vm.Name = "LAN server";
        vm.BaseUrl = "http://192.168.1.50:3000";
        vm.ApiKey = "";
        Assert.True(vm.CanSave);
    }

    [Fact]
    public void CanSave_still_requires_key_for_new_openai()
    {
        var vm = MakeVm();
        vm.SelectedType = ProviderType.OpenAI;
        vm.Name = "OpenAI";
        vm.BaseUrl = "https://api.openai.com";
        vm.ApiKey = "";
        Assert.False(vm.CanSave);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static AddProviderViewModel MakeVm()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var router = new ProviderRouter(new FakeSettings(), store, new FakeSecrets(),
            new AINotebook.Core.Ollama.OllamaClient(), new HttpClient());
        return new AddProviderViewModel(router, store, new FakeSecrets());
    }

    private sealed class FakeSettings : ISettingsService
    {
        public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }
        public AppLanguage Language { get; set; } = AppLanguage.English;
        public bool HasCompletedOnboarding { get; set; } = true;
        public string SelectedChatModel { get; set; } = "llama3.2:3b";
        public string SelectedEmbeddingModel { get; set; } = "nomic-embed-text";
        public string SelectedChatProviderId { get; set; } = ProviderConfig.OllamaId;
        public string SelectedEmbeddingProviderId { get; set; } = ProviderConfig.OllamaId;
    }

    private sealed class FakeSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _map = new();
        public void Save(string providerId, string secret) => _map[providerId] = secret;
        public string? Load(string providerId) => _map.TryGetValue(providerId, out var s) ? s : null;
        public void Delete(string providerId) => _map.Remove(providerId);
    }
}
```

Same adjustment rules as Task 3 apply (mirror real signatures if they differ; this file cannot be compiled on the macOS dev box).

Known accepted behavior (do NOT "fix" in this task): `SaveConfirmedAsync` only calls `_secrets.Save` and `_store.AcknowledgePrivacy` when `ApiKey` is non-empty. A keyless OpenWebUI save therefore leaves `privacy_acknowledged = 0` in the DB even though the gate dialog was shown. Nothing reads that flag today (write-only), so this is harmless; same pre-existing behavior as a hypothetical keyless `openai_compatible`.

- [ ] **Step 5: Commit**

```bash
git add windows/src/AINotebook.App/ViewModels/AddProviderViewModel.cs \
        windows/src/AINotebook.App/Views/AddProviderDialog.xaml.cs \
        windows/tests/AINotebook.App.Tests/AddProviderViewModelOpenWebUITests.cs
git commit -m "feat(win): OpenWebUI entry in add-provider dialog, keyless save allowed

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: CI verification + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (new Unreleased section at top, matching existing entry style)

- [ ] **Step 1: Push the branch and watch CI**

```bash
git push -u origin feat/openwebui-provider-win
gh run watch $(gh run list --branch feat/openwebui-provider-win --workflow windows-ci.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Expected: `windows-ci` green — locked-mode restore, Core tests (incl. ProviderTypeTests + OpenWebUISseTests), App tests x64 (incl. ProviderRouterOpenWebUITests + AddProviderViewModelOpenWebUITests). Also confirm `core-ci` (macOS) is unaffected — this branch touches only `windows/`.

- [ ] **Step 2: Fix any CI failures**

App-layer test files were written blind (no local Windows build). If compilation fails, apply the adjustment rules in Tasks 3–4 (mirror the real signatures), commit as `fix(win): ...`, push, re-watch.

- [ ] **Step 3: Add CHANGELOG entry**

Add at the top of `CHANGELOG.md`, following the existing format of prior entries (check the v0.8.2 entry for the exact heading style):

```markdown
## [Unreleased]

### Added
- **Windows: OpenWebUI network provider.** New provider type in Settings → AI providers:
  connect to an OpenWebUI server on your network (base URL + optional API key), fetch its
  aggregated model list, and use any of its models for chat, transformations, and summaries.
  Chat-only by design — embeddings stay local (Ollama). API key is stored in Windows
  Credential Manager, never in the database.
```

- [ ] **Step 4: Commit and push**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for Windows OpenWebUI provider

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 5: Manual acceptance check (user, real hardware)**

On a Windows machine with an OpenWebUI server reachable on the network: add provider (type OpenWebUI, URL, key) → Test shows success → privacy gate appears on save → chat model picker lists the server's models → chat streams answers with `[N]` citations → restart app, key survives, `%APPDATA%\AINotebook\settings.json` and `db.sqlite` contain no key. Report results before merging to `main`.

---

## Out of scope (Phase 2 — separate plan)

macOS Epic A provider registry + `openwebui` type (spec §5). Merge/release decisions (VERSION bump, tag) happen after the user's manual acceptance check.
