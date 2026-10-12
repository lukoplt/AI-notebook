# WP2 — Providers / Options Implementation Plan

> Execute one numbered task per worktree. Branch from the commits listed under **Depends on**, implement the red/green steps, and commit only the listed files. Do not invoke installed skills or read `~/.claude/`, `~/.agents/`, `.claude/skills/`, or `agents/`. This document is a plan; the planning commit changes no application code.

**Goal:** Make all five providers obey the API-root and wire-order contracts on both platforms; preserve one provider configuration throughout a chat turn; expose honest connection checks, compatible-provider presets, discovery, manual model IDs, and persisted context/output limits in Settings.

**Architecture:** Pure URL, preset, and limit policy in Core; network requests in provider adapters; immutable, secret-bearing adapters privately retained by a per-turn session. Windows routing moves into Core, with the existing App service reduced to constructor injection and forwarding. Shared fixtures precede platform implementations. WP3 alone owns v19 and its transaction, including one-time legacy-root conversion and the limits table. WP8 consumes WP2's public, credential-free limit metadata and request options.

**Tech Stack:** Swift 6 / XCTest / SwiftUI / GRDB; .NET 10 / xUnit / WinUI 3 / Microsoft.Data.Sqlite; Foundation URL loading and injected HttpClient; Python 3 standard library for fixture generation.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md` §7, §8.1–2, §10, §12. **Master:** `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md`. **Contracts:** `docs/contracts/folder-rag-v1.md` §5, §11, limits DTO at line 44; `docs/contracts/lang-detector-v1.md` (read, no WP2 changes). **Format exemplar:** `docs/superpowers/plans/2026-10-09-wp0-contracts.md`.

## Global Constraints

- Every Core behavior below has Swift and C# tests using `Tests/fixtures/contracts/`. Read with `SharedFixtures.json/data` in Swift and `SharedFixtures.Json` in C#; do not copy fixtures into platform source trees.
- TDD: add the specified failing test, execute its red command, implement, execute green command and the full platform suite. Missing new symbols are an acceptable first red; also preserve behavioral regressions against actual HTTP captures. Never remove an assertion to obtain green.
- WP0's eleven review decisions in the assignment override the older text currently checked out. In particular, consume its corrected invalid-authority API-root cases. WP2 does not edit citations, glob, budget, eligibility, jobs, overview, coverage, Unicode tables, or the WP0 generator. Do not copy outdated WP0 algorithms into WP2.
- The default limits are `RagContractV1.Providers.defaultRuntimeContext = 8192` / `DefaultRuntimeContext = 8192`, output 1024. `context_window` alone is nullable. Never silently increase Ollama runtime to its advertised 32K/128K ceiling.
- Every Windows store connection/command/reader/transaction access, including test access through `store.Connection`, is enclosed in `lock (store.Gate)` or `lock (_gate)`. Never hold a database lock across `await`.
- New networking lives under `Providers/`; existing `OllamaClient.swift` and Windows `Ollama/OllamaClient.cs` remain allowed transport files. No networking in Settings view models, stores, pure policies, or ChatEngine.
- Keep all existing cancellation/stream termination and retry behavior, except that non-retryable configuration/limit/consent errors must stop immediately. No paid generation request during a connection check.
- Privacy remains type-based: all non-Ollama types require acknowledgment even for loopback compatible presets. Presets do not grant consent. Missing/disabled providers and chat-only embedding selections fail before any network call; never silently substitute another provider.
- Secrets stay in existing Keychain/Credential Manager integrations. Neither secrets nor their fingerprints appear in DTO serialization, SQLite, preview, diagnostic descriptions, or logs.
- Windows App is unpackaged: no `Windows.Storage.ApplicationData` or `Package.Current`. Code-behind resolves brushes through `Application.Current.Resources[...]`.
- No shipped migration edits, v20 migration, VERSION changes, package upgrades, or changes outside the task file manifest. WP3 owns migration registration files. WP8 owns later context-pack assembly; WP2 changes only provider capture/options in ChatEngine.
- Initial baseline on this planning branch: **Swift 381 passed, 0 failed; .NET Core 450 passed, 0 failed, 0 skipped**. Task counts will increase; report actual totals rather than assuming they remain equal to this baseline.
- Each commit ends with `Co-Authored-By: Codex <noreply@openai.com>`. Commands below use a second `-m` to create that final paragraph. Commit only the task's explicit paths; leave the worktree clean.

## File Structure

All paths below are repository-relative. `S` means `Sources/AINotebookCore`, `ST` means `Tests/AINotebookCoreTests`, `W` means `windows/src/AINotebook.Core`, and `WT` means `windows/tests/AINotebook.Core.Tests`. These aliases describe file ownership, not directories to create.

| Files | Responsibility / owner |
|---|---|
| `tools/contracts/gen_provider_fixtures.py`, `tools/contracts/test_provider_fixtures.py`; `Tests/fixtures/contracts/provider-{presets,limits,probe,options,routing,systems,store,errors}-v1.json` | New WP2-only fixtures, Task 1 |
| `S/Providers/ProviderAPIRoot.swift`, `S/Providers/ChatRequestOptions.swift`; existing provider wire/adapters, Ollama transport/DTO, `S/ChatEngine.swift` protocol declaration; transport tests | Root/options/wire foundation, Task 2 |
| `W/Providers/ProviderApiRoot.cs`, `W/Providers/ChatRequestOptions.cs`; existing provider wire/adapters and Ollama files; transport tests | Windows foundation, Task 3 |
| `S/Providers/ProviderModelLimits.swift`, `S/Providers/ProviderPresets.swift`, `S/NotebookStore+ProviderModelLimits.swift`; new policy/store/upgrade tests | Swift limits and storage, Task 4 |
| `W/Providers/ProviderModelLimits.cs`, `W/Providers/ProviderPresets.cs`, `W/Storage/NotebookStore.ProviderModelLimits.cs`; new policy/store/upgrade tests | Windows limits and storage, Task 5 |
| `S/Providers/ProviderRouter.swift`, `ProviderSession.swift`, `ProviderDiscovery.swift`; new and existing router tests | Swift discovery, capture, privacy, Task 6 |
| `W/Providers/ProviderRouter.cs`, `ProviderSession.cs`, `ProviderDiscovery.cs`; new Core router tests | Windows Core routing, cache, discovery, privacy, Task 7 |
| `S/ChatEngine.swift`; new turn snapshot tests | Swift retry integration, Task 8, after Task 2 |
| `W/Rag/ChatEngine.cs`; new turn snapshot tests | Windows retry integration, Task 9 |
| `Sources/AINotebookApp/{SettingsView,AddProviderSheet,ProviderErrorText}.swift`, `S/Localization.swift`; localization tests; removal of old router UI wrappers | Swift UI, Task 10 |
| `windows/src/AINotebook.App/Services/ProviderRouter.cs`, Settings/AddProvider view models and dialogs, StringKey, both `.resw` files, App tests | Thin DI and WinUI integration, Task 11 |

### Scheduling and WP3 handoff

```text
WP0 fixes → 1 → 2 ─→ 4 (also WP3 Swift v19) → 6 → 8 → 10
             └→ 3 ─→ 5 (also WP3 C# v19)    → 7 → 9 → 11
                  2/3 publish root helpers → WP3 v19 → 4/5
```

The two platform lanes may run concurrently. Within a lane, the ordering is intentional: Task 2 and Task 8 both own `ChatEngine.swift`; Tasks 6 and 10 both own the Swift router/its existing tests. They must never run concurrently. Task 11 is the only task editing Windows App files. WP3 can prepare all its other schema work while Tasks 2/3 land; WP3's final v19 commit consumes their pure root helper. This makes the implicit WP2↔WP3 integration requirement explicit without two owners editing a migration.

**Exact DDL WP3 must include, identically on both platforms:**

```sql
CREATE TABLE provider_model_limits (
    provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
    model TEXT NOT NULL CHECK(length(trim(model)) > 0),
    context_window INTEGER NULL CHECK(context_window IS NULL OR context_window > 0),
    runtime_context INTEGER NOT NULL CHECK(runtime_context > 0),
    max_output_tokens INTEGER NOT NULL CHECK(max_output_tokens > 0),
    source TEXT NOT NULL CHECK(source IN ('auto', 'user')),
    PRIMARY KEY (provider_id, model),
    CHECK(context_window IS NULL OR runtime_context <= context_window),
    CHECK(max_output_tokens < runtime_context)
);
```

WP3 enumerates `SELECT id, type, base_url FROM providers` **inside v19's existing migration transaction**, materializes rows before updating, calls `ProviderAPIRoot.convertLegacy(type:baseURL:)` / `ProviderApiRoot.ConvertLegacy(type, baseUrl)`, and parameterizes `UPDATE providers SET base_url = ? WHERE id = ?`. Invalid roots remain byte-for-byte unchanged and fail normal provider validation when used; catch only `invalidBaseURL`, never database exceptions. All other columns, especially consent, IDs, timestamps and enabled state, remain unchanged. The v19 migration ledger is the one-time marker: no extra migration or per-read conversion. New saves and edits always use exact roots, including intentionally versionless roots. New installations seed no OpenAI row today; their OpenAI form default comes from ProviderType.

The extra `max_output_tokens < runtime_context` check is a WP2 design decision for Claude/WP3 to review: it rejects an unusable budget at edit time as well as at request time. No changes to the frozen table's column names or `source` values are proposed.

### Shared interfaces (names frozen for these tasks)

The declarations here are the cross-task contract; each task below names which ones it consumes/produces. Preserve the existing no-options chat requirement for unrelated clients and test doubles.

```swift
public enum ProviderEndpoint: String, Sendable { case chat, models, embeddings }
public enum ProviderRequestError: Error, Sendable { case contextTooLong }
public enum ProviderConfigurationError: String, Error, Sendable {
    case invalidBaseURL, unsupportedEndpoint, missingProvider, disabledProvider, invalidLimits
}
public enum ProviderAPIRoot {
    public static func normalize(_ baseURL: String) throws -> String
    public static func convertLegacy(type: ProviderType, baseURL: String) throws -> String
    public static func build(type: ProviderType, baseURL: String, endpoint: ProviderEndpoint) throws -> URL
}
public struct ChatRequestOptions: Equatable, Sendable {
    public let runtimeContext: Int
    public let maxOutputTokens: Int
    public init(runtimeContext: Int, maxOutputTokens: Int)
    public static let defaults: ChatRequestOptions // 8192, 1024
    public func validate() throws
}
// Add this requirement to ChatStreaming; its default implementation calls the old overload.
func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions)
    -> AsyncThrowingStream<String, Error>

public struct ProviderModelLimits: Codable, Equatable, Sendable {
    public let providerId: String
    public let model: String
    public let contextWindow: Int?
    public let runtimeContext: Int
    public let maxOutputTokens: Int
    public let source: String // validated: "auto" or "user"
    public var isAssumed: Bool { get }
    public var options: ChatRequestOptions { get }
    public init(providerId: String, model: String, contextWindow: Int?,
                runtimeContext: Int, maxOutputTokens: Int, source: String)
    public func validate() throws
}
public enum ProviderLimitPolicy {
    public static func automatic(providerId: String, type: ProviderType, model: String,
                                 contextWindow: Int?) throws -> ProviderModelLimits
    public static func contextWindow(fromOllamaShow data: Data) throws -> Int?
}
public struct ProviderPreset: Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let helpKey: String
}
public enum ProviderPresets { public static let all: [ProviderPreset] }
// NotebookStore (@MainActor):
public func providerModelLimits(providerId: String, model: String) throws -> ProviderModelLimits?
public func saveProviderModelLimits(_ limits: ProviderModelLimits) throws
public func deleteProviderModelLimits(providerId: String, model: String) throws

public enum ProviderProbeStatus: String, Sendable { case verified, listingUnsupported, failed }
public struct ProviderProbeResult: Sendable {
    public let status: ProviderProbeStatus
    public let models: [ProviderModelInfo]
    public let errorCode: String? // auth, transport, http, decoding, invalidBaseURL
    public let detail: String? // sanitized; never headers or API keys
    public var generationVerified: Bool { false }
}
public protocol ChatSessionPreparing: Sendable {
    func prepareChat(model: String?) async throws -> ProviderChatSession
}
public struct ProviderChatSession: Sendable {
    public let providerId: String
    public let model: String
    public let storageKey: String // providerId + ":" + raw model, split FIRST colon only
    public let limits: ProviderModelLimits
    public func stream(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error>
    // Private captured adapter; no Codable, no secret/fingerprint property.
}
// ProviderRouter additions:
public func prepareChat(model: String? = nil) async throws -> ProviderChatSession
public func discoverModels(providerId: String) async throws -> [ProviderModelInfo]
public func probe(type: ProviderType, baseURL: String, apiKey: String?) async throws -> ProviderProbeResult
public func resolveLimits(providerId: String, model: String, refresh: Bool = false) async throws -> ProviderModelLimits
```

```csharp
public enum ProviderEndpoint { Chat, Models, Embeddings }
public sealed class ProviderHttpException(int statusCode) : ProviderException($"HTTP {statusCode}.")
{ public int StatusCode { get; } = statusCode; }
public sealed class ProviderContextTooLongException() : ProviderException("Context too long.");
public sealed class ProviderConfigurationException(string code) : Exception(code)
{ public string Code { get; } = code; }
public static class ProviderApiRoot
{
    public static string Normalize(string baseUrl);
    public static string ConvertLegacy(ProviderType type, string baseUrl);
    public static Uri Build(ProviderType type, string baseUrl, ProviderEndpoint endpoint);
}
public sealed record ChatRequestOptions(int RuntimeContext, int MaxOutputTokens)
{
    public static ChatRequestOptions Defaults { get; } // 8192, 1024
    public void Validate();
}
// Add to IChatStreaming as a default interface method forwarding to the old overload:
IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
    ChatRequestOptions options, CancellationToken ct = default);

public sealed record ProviderModelLimits(string ProviderId, string Model, int? ContextWindow,
    int RuntimeContext, int MaxOutputTokens, string Source)
{
    public bool IsAssumed => Source == "auto" && ContextWindow is null;
    public ChatRequestOptions Options => new(RuntimeContext, MaxOutputTokens);
    public void Validate();
}
public static class ProviderLimitPolicy
{
    public static ProviderModelLimits Automatic(string providerId, ProviderType type,
        string model, int? contextWindow);
    public static int? ContextWindowFromOllamaShow(string json);
}
public sealed record ProviderPreset(string Id, string Name, string BaseUrl, string HelpKey);
public static class ProviderPresets { public static IReadOnlyList<ProviderPreset> All { get; } }
// NotebookStore:
public ProviderModelLimits? ProviderModelLimits(string providerId, string model);
public void SaveProviderModelLimits(ProviderModelLimits limits);
public void DeleteProviderModelLimits(string providerId, string model);

public enum ProviderProbeStatus { Verified, ListingUnsupported, Failed }
public sealed record ProviderProbeResult(ProviderProbeStatus Status,
    IReadOnlyList<ProviderModelInfo> Models, string? ErrorCode, string? Detail)
{ public bool GenerationVerified => false; }
public interface IChatSessionPreparing
{ Task<ProviderChatSession> PrepareChatAsync(string? model = null, CancellationToken ct = default); }
public sealed class ProviderChatSession
{
    public string ProviderId { get; }
    public string Model { get; }
    public string StorageKey { get; }
    public ProviderModelLimits Limits { get; }
    public IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default);
    // Private readonly adapter; do not use a positional record exposing its key in ToString().
}
// Namespace: AINotebook.Core.Providers.Routing (avoids collision with the App service).
public sealed class ProviderRouter : IChatStreaming, IEmbeddingProducing, IChatSessionPreparing
{
    public ProviderRouter(NotebookStore store,
        Func<(string ProviderId, string Model)> chatSelection,
        Func<(string ProviderId, string Model)> embeddingSelection,
        Func<string, string?> loadSecret, HttpClient http);
    public Task<ProviderChatSession> PrepareChatAsync(string? model = null, CancellationToken ct = default);
    public Task<IReadOnlyList<ProviderModelInfo>> DiscoverModelsAsync(string providerId, CancellationToken ct = default);
    public Task<ProviderProbeResult> ProbeAsync(ProviderType type, string baseUrl, string? apiKey,
        CancellationToken ct = default);
    public Task<ProviderModelLimits> ResolveLimitsAsync(string providerId, string model,
        bool refresh = false, CancellationToken ct = default);
}
```

## Tasks

### Task 1: [Shared] Freeze executable WP2 behavior fixtures

**Depends on:** WP0 corrected contracts/fixtures. **Parallel with:** no WP2 task; WP1/WP3 may continue in their own files.

**Files:** Create `tools/contracts/gen_provider_fixtures.py`, `tools/contracts/test_provider_fixtures.py`, and the eight `provider-*-v1.json` files in the File Structure table. Do not edit WP0's `tools/contracts/gen_fixtures.py`, `api-root-v1.json`, or `wire-order-v1.json`.

**Interfaces:** Consumes Swift `SharedFixtures.json(_:) throws -> [String: Any]`, C# `SharedFixtures.Json(string) -> JsonElement`. Produces identical `{contract, version:1, cases:[{name,...}]}` documents for both consumers. No production API changes in this task.

- [ ] **Step 1: Write the artifact test first.**

```python
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "Tests/fixtures/contracts"
NAMES = ("presets", "limits", "probe", "options", "routing", "systems", "store", "errors")

class ProviderFixturesTests(unittest.TestCase):
    def test_complete_envelopes(self):
        for name in NAMES:
            data = json.loads((ROOT / f"provider-{name}-v1.json").read_text())
            self.assertEqual(data["contract"], f"provider-{name}")
            self.assertEqual(data["version"], 1)
            names = [case["name"] for case in data["cases"]]
            self.assertTrue(names)
            self.assertEqual(len(names), len(set(names)))

    def test_probe_matrix_and_presets(self):
        probes = json.loads((ROOT / "provider-probe-v1.json").read_text())["cases"]
        self.assertEqual(len(probes), 55)
        self.assertTrue(all(not x["generationVerified"] for x in probes))
        presets = json.loads((ROOT / "provider-presets-v1.json").read_text())["cases"]
        self.assertEqual([x["name"] for x in presets],
                         ["lmstudio", "openrouter", "vllm", "groq", "mistral", "together", "custom"])

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run red:** `python3 tools/contracts/test_provider_fixtures.py` → `FileNotFoundError` for WP2 fixtures.
- [ ] **Step 3: Implement the deterministic generator below.** Its expected values are literal worked cases, not calls into either production implementation. The `--check` mode compares bytes without writing. The WP0 generator continues owning its existing fixtures.

```python
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "Tests/fixtures/contracts"
TYPES = ["ollama", "anthropic", "openai", "openai_compatible", "openwebui"]
presets = [
    ("lmstudio", "LM Studio", "http://localhost:1234/v1", "providerPresetLocalHelp"),
    ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "providerPresetRemoteHelp"),
    ("vllm", "vLLM", "http://localhost:8000/v1", "providerPresetLocalHelp"),
    ("groq", "Groq", "https://api.groq.com/openai/v1", "providerPresetRemoteHelp"),
    ("mistral", "Mistral", "https://api.mistral.ai/v1", "providerPresetRemoteHelp"),
    ("together", "Together", "https://api.together.ai/v1", "providerPresetRemoteHelp"),
    ("custom", "Custom", "", "providerPresetCustomHelp"),
]
files = {"presets": [dict(name=i, label=n, baseURL=u, helpKey=h,
                           type="openai_compatible") for i, n, u, h in presets]}
files["options"] = [dict(name=t, type=t, runtimeContext=4096, maxOutputTokens=333,
    expected={"options": {"num_ctx": 4096, "num_predict": 333}} if t == "ollama"
             else {"max_tokens": 333}) for t in TYPES]
files["limits"] = [
    dict(name="unknown", type="openai_compatible", model="unlisted", window=None,
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
    dict(name="known-openai", type="openai", model="gpt-4o-mini", window=None,
         expected=dict(contextWindow=128000, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="known-snapshot", type="openai", model="gpt-4o-mini-2024-07-18", window=None,
         expected=dict(contextWindow=128000, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="no-prefix-guess", type="openai", model="gpt-4o-mini-custom", window=None,
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
    dict(name="no-compatible-guess", type="openai_compatible", model="gpt-4o-mini", window=None,
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
    dict(name="ollama-large", type="ollama", model="m:tag", window=32768,
         show={"model_info":{"general.architecture":"llama", "llama.context_length":32768}},
         expected=dict(contextWindow=32768, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="ollama-small", type="ollama", model="m", window=4096,
         show={"model_info":{"general.architecture":"llama", "llama.context_length":4096}},
         expected=dict(contextWindow=4096, runtimeContext=4096, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="ollama-tiny", type="ollama", model="m", window=512,
         expected=dict(contextWindow=512, runtimeContext=512, maxOutputTokens=511, source="auto", isAssumed=False)),
    dict(name="ollama-no-metadata", type="ollama", model="m", window=None, show={"model_info":{}},
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
]
for name, window, runtime, output in [
    ("zero-runtime", None, 0, 1), ("zero-output", None, 4096, 0),
    ("no-input-budget", None, 1024, 1024), ("above-window", 4096, 8192, 1024),
    ("negative-window", -1, 8192, 1024)]:
    files["limits"].append(dict(name=name, type="ollama", model="m", window=window,
        user=dict(runtimeContext=runtime, maxOutputTokens=output), expectedError="invalidLimits"))
probe_rows = [
    ("empty", 200, "validEmpty", "verified", None),
    ("one", 200, "validOne", "verified", None),
    ("not-found", 404, "error", "listingUnsupported", None),
    ("method", 405, "error", "listingUnsupported", None),
    ("not-implemented", 501, "error", "listingUnsupported", None),
    ("unauthorized", 401, "error", "failed", "auth"),
    ("forbidden", 403, "error", "failed", "auth"),
    ("rate-limit", 429, "error", "failed", "http"),
    ("server", 500, "error", "failed", "http"),
    ("malformed", 200, "malformed", "failed", "decoding"),
    ("connection", 0, "transport", "failed", "transport"),
]
files["probe"] = [dict(name=f"{t}-{n}", type=t, statusCode=s, response=r,
    expectedStatus=e, errorCode=c, generationVerified=False)
    for t in TYPES for n, s, r, e, c in probe_rows]
files["routing"] = [
    dict(name="capture-and-rotate", operation="snapshot", type="openai_compatible",
         providerId="p", oldRoot="https://old.example/proxy/v1", newRoot="https://new.example/gw/v1",
         oldKey="key-A", newKey="key-B", oldModel="model:old", newModel="model:new",
         oldContext=4096, newContext=8192, oldOutput=333, newOutput=777,
         expectedAttempts=["old", "old", "new"]),
    *[dict(name=f"privacy-{t}-{op}", operation=op, type=t,
           acknowledged=False, expectedError="consentRequired", expectedRequests=0)
      for t in TYPES if t != "ollama" for op in ["chat", "backgroundEmbed"]],
    *[dict(name=f"unsupported-embed-{t}", operation="embed", type=t,
           acknowledged=True, expectedError="unsupportedEndpoint", expectedRequests=0)
      for t in ["anthropic", "openwebui"]],
    dict(name="missing", operation="chat", type="openai", missing=True,
         expectedError="missingProvider", expectedRequests=0),
    dict(name="disabled", operation="chat", type="openai", enabled=False,
         expectedError="disabledProvider", expectedRequests=0),
    dict(name="custom-ollama", operation="ollamaEndpoints", type="ollama",
         root="http://gpu-box:11434/proxy/ollama", paths=["api/chat", "api/embed", "api/tags", "api/show"]),
]
files["systems"] = [dict(name=t, type=t,
    input=[dict(role="system", content="RULES"), dict(role="system", content="I"),
           dict(role="user", content="q1"), dict(role="assistant", content="a1"),
           dict(role="user", content="Q2")],
    expected=dict(system="RULES\n\nI", messages=[dict(role="user", content="q1"),
        dict(role="assistant", content="a1"), dict(role="user", content="Q2")]) if t == "anthropic"
    else dict(messages=[dict(role="system", content="RULES\n\nI"),
        dict(role="user", content="q1"), dict(role="assistant", content="a1"), dict(role="user", content="Q2")]))
    for t in TYPES]
files["store"] = [
    dict(name="user-survives-auto", providerId="p", model="m:tag", contextWindow=32768,
         runtimeContext=4096, maxOutputTokens=333, source="user", autoRuntime=8192,
         expectedRuntime=4096),
    dict(name="provider-isolation", providerIds=["p", "q"], model="m:tag", runtimes=[4096,8192]),
    dict(name="delete-cascades", providerId="p", model="m", expectedRows=0),
    dict(name="reset-auto", providerId="p", model="m", expectedSource="auto", expectedRuntime=8192),
    dict(name="legacy-openai", type="openai", before="https://api.openai.com/", after="https://api.openai.com/v1"),
    dict(name="legacy-versioned", type="openai_compatible", before="https://gw.example/v1/", after="https://gw.example/v1"),
    dict(name="legacy-prefix", type="openai_compatible", before="https://gw.example/proxy", after="https://gw.example/proxy/v1"),
    dict(name="new-versionless", type="openai_compatible", before="https://gw.example/proxy", after="https://gw.example/proxy"),
]
for name, value in [("one", 1), ("zero", 0), ("negative", -1), ("fraction", 1.5),
                    ("boolean", True), ("overflow", 2147483648)]:
    files["limits"].append(dict(name="show-invalid-" + name, type="ollama", model="m", window=None,
        show={"model_info":{"general.architecture":"llama", "llama.context_length":value}},
        expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)))
files["limits"].append(dict(name="show-other-architecture", type="ollama", model="m", window=None,
    show={"model_info":{"general.architecture":"llama", "bert.context_length":32768}},
    expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)))
files["errors"] = [dict(name=f"{t}-{name}", type=t, statusCode=status, body=body, expectedError=error)
    for t in TYPES for name, status, body, error in [
        ("context", 400, {"error":{"code":"context_length_exceeded", "message":"too long"}}, "contextTooLong"),
        ("payload", 413, {"error":"request too large"}, "contextTooLong"),
        ("other-bad-request", 400, {"error":{"code":"invalid_model", "message":"unknown model"}}, "http")]]
files["errors"].append(dict(name="anthropic-prompt-too-long", type="anthropic", statusCode=400,
    body={"error":{"type":"invalid_request_error", "message":"prompt is too long: 9000 tokens"}}, expectedError="contextTooLong"))
parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
for suffix, cases in files.items():
    path = ROOT / f"provider-{suffix}-v1.json"
    blob = (json.dumps(dict(contract=f"provider-{suffix}", version=1, cases=cases),
                       ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if args.check:
        assert path.read_bytes() == blob, f"stale fixture: {path.name}"
    else:
        path.write_bytes(blob)
print("WP2 provider fixtures: 8 files verified" if args.check else "WP2 provider fixtures: 8 files written")
```

The known-model table initially contains **only** the two explicit GPT-4o-mini IDs above, with 128000 ceiling and conservative 8192/1024 runtime/output defaults. Unknown Anthropic/cloud IDs remain honest assumptions; never guess a ceiling from a prefix. This is an extensible capability table, not a claim that every model is catalogued. The ceiling is documented by [OpenAI's model page](https://developers.openai.com/api/docs/models/gpt-4o-mini). Preset roots follow [LM Studio](https://lmstudio.ai/docs/developer/openai-compat), [OpenRouter](https://openrouter.ai/docs/quickstart), [Groq](https://console.groq.com/docs/openai), [Mistral](https://docs.mistral.ai/api), and [Together](https://docs.together.ai/docs/inference/openai-compatibility); vLLM's localhost port is a user-editable default, not discovered configuration.

- [ ] **Step 4: Run green:**

```bash
python3 tools/contracts/gen_provider_fixtures.py
python3 tools/contracts/gen_provider_fixtures.py --check
python3 tools/contracts/test_provider_fixtures.py
python3 tools/contracts/gen_fixtures.py --check
swift test --filter SharedFixturesTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures
swift test
dotnet test windows/tests/AINotebook.Core.Tests
```

Expected: eight provider fixture files verified, Python `Ran 2 tests` / `OK`, WP0 generator check succeeds, envelope tests and both complete suites green. No WP0 fixture bytes change.

- [ ] **Step 5: Commit:**

```bash
git add tools/contracts/gen_provider_fixtures.py tools/contracts/test_provider_fixtures.py Tests/fixtures/contracts/provider-*-v1.json
git commit -m "test(contracts): pin provider options, limits, discovery and routing fixtures" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 2: [Swift] Exact roots and request options at every transport boundary

**Depends on:** Task 1. **Parallel with:** Tasks 3, 5, 7, 9, 11 when their dependencies are satisfied; WP3 work outside its root-conversion integration.

**Files:** Create `S/Providers/ProviderAPIRoot.swift`, `S/Providers/ChatRequestOptions.swift`, `ST/ProviderTransportContractTests.swift`. Modify `S/Providers/{ProviderType,ProviderWire,OpenAIAdapters,AnthropicChatAdapter,OpenWebUIChatAdapter}.swift`, `S/{OllamaClient,OllamaChatTypes,OllamaClient+ChatStreaming,ChatEngine}.swift`, `ST/{ProviderTypeTests,OpenAIAdapterTests,AnthropicAdapterTests,ProviderRouterTests}.swift`. Read-only helpers: `ST/SharedFixtures.swift:16`, `ST/StubURLProtocol.swift:41`, `ST/MockURLProtocol.swift:54` (`bodyData`).

**Grounding:** `ProviderWire.swift:9` only strips slashes; `OpenAIAdapters.swift:21,34,62` appends `/v1`; `ProviderType.swift:21` has the old OpenAI default; `AnthropicChatAdapter.swift:55` hardcodes 8192; `OllamaChatTypes.swift:23` lacks `num_predict`; `OllamaClient+ChatStreaming.swift:18` drops options; `ChatEngine.swift:12` declares the protocol.

**Interfaces:** Produces the Swift root/errors/options declarations above and the default `ChatStreaming` options overload; C# counterparts are produced by Task 3 with identical semantics. Consumes current `ChatTurn(role:content:)`, `OllamaClient(baseURL:session:)`, shared fixture APIs. Also produces `OllamaClient.show(model: String) async throws -> Data`, posting `{"model":model}` to the exact root plus `/api/show`.

- [ ] **Step 1: Add these real adapter tests.** Place the factory and collector in the new test class; use `URLRequest.bodyData` to handle body streams. Reset stubs after every case. Foundation is imported explicitly.

```swift
import Foundation
import XCTest
@testable import AINotebookCore

final class ProviderTransportContractTests: XCTestCase {
    private func adapter(_ type: ProviderType, root: String) -> any ChatStreaming {
        let session = StubURLProtocol.session()
        switch type {
        case .ollama: return OllamaClient(baseURL: URL(string: root)!, session: session)
        case .anthropic: return AnthropicChatAdapter(baseURL: root, apiKey: "k", session: session)
        case .openai, .openaiCompatible: return OpenAIChatAdapter(baseURL: root, apiKey: "k", session: session)
        case .openwebui: return OpenWebUIChatAdapter(baseURL: root, apiKey: "k", session: session)
        }
    }
    private func finish(_ type: ProviderType) {
        let body = type == .ollama
            ? "{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n"
            : type == .anthropic ? "data: {\"type\":\"message_stop\"}\n" : "data: [DONE]\n"
        StubURLProtocol.enqueue(.json(Data(body.utf8)))
    }
    func testAPIRootFixture() throws {
        let rows = try SharedFixtures.json("contracts/api-root-v1.json")["cases"] as! [[String: Any]]
        for row in rows {
            let type = ProviderType(rawValue: row["type"] as! String)!
            let endpoint = ProviderEndpoint(rawValue: row["endpoint"] as! String)!
            do {
                let raw = row["baseURL"] as! String
                let root = row["legacy"] as! Bool
                    ? try ProviderAPIRoot.convertLegacy(type: type, baseURL: raw) : raw
                let url = try ProviderAPIRoot.build(type: type, baseURL: root, endpoint: endpoint)
                XCTAssertEqual(url.absoluteString, row["expectedURL"] as? String, row["name"] as! String)
            } catch let error as ProviderConfigurationError {
                XCTAssertEqual(error.rawValue, row["expectedError"] as? String, row["name"] as! String)
            }
        }
    }
    func testOptionsReachAllAdapters() async throws {
        let rows = try SharedFixtures.json("contracts/provider-options-v1.json")["cases"] as! [[String: Any]]
        for row in rows {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: row["type"] as! String)!
            finish(type)
            let options = ChatRequestOptions(runtimeContext: row["runtimeContext"] as! Int,
                                             maxOutputTokens: row["maxOutputTokens"] as! Int)
            for try await _ in adapter(type, root: "https://unit.example/proxy/v1")
                .stream(model: "m", messages: [.init(role: .user, content: "Q")], options: options) {}
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequest?.bodyData)) as! NSDictionary
            let expected = row["expected"] as! NSDictionary
            if type == .ollama {
                XCTAssertEqual(body["options"] as? NSDictionary, expected["options"] as? NSDictionary)
                XCTAssertNil(body["max_tokens"])
            } else {
                XCTAssertEqual(body["max_tokens"] as? Int, expected["max_tokens"] as? Int)
                XCTAssertNil(body["options"])
                XCTAssertNil(body["num_ctx"])
                XCTAssertNil(body["num_predict"])
            }
        }
        StubURLProtocol.reset()
    }
    func testWireOrderFixtures() async throws {
        let canonical = try SharedFixtures.json("contracts/wire-order-v1.json")["cases"] as! [[String: Any]]
        let systems = try SharedFixtures.json("contracts/provider-systems-v1.json")["cases"] as! [[String: Any]]
        for row in canonical + systems {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: (row["provider"] ?? row["type"]) as! String)!
            var turns: [ChatTurn] = []
            if let input = row["input"] as? [String: Any] {
                turns.append(.init(role: .system, content: input["rulesText"] as! String))
                let instructions = input["userInstructions"] as! String
                if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns.append(.init(role: .system, content: instructions))
                }
                for h in input["history"] as! [[String: String]] {
                    turns.append(.init(role: ChatRole(rawValue: h["role"]!)!, content: h["content"]!))
                }
                turns.append(.init(role: .user, content: input["finalUserContent"] as! String))
            } else {
                turns = (row["input"] as! [[String: String]]).map {
                    .init(role: ChatRole(rawValue: $0["role"]!)!, content: $0["content"]!)
                }
            }
            finish(type)
            for try await _ in adapter(type, root: "https://unit.example/root").stream(model: "m", messages: turns) {}
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequest?.bodyData)) as! [String: Any]
            let projected = body.filter { $0.key == "messages" || $0.key == "system" } as NSDictionary
            XCTAssertEqual(projected, row["expected"] as? NSDictionary, row["name"] as! String)
        }
        StubURLProtocol.reset()
    }
}
```

- [ ] **Step 2: Run red:** `swift test --filter ProviderTransportContractTests` → missing root/options API; after declarations, existing version appending and multi-system wire shapes fail.
- [ ] **Step 3: Implement strict root validation and concrete serialization.** Trim outer whitespace, reject remaining whitespace/control scalars, query/fragment/userinfo/backslash, require http/https and a valid DNS hostname or IP literal. Catch URL parsing failures. Ports must be numeric 1…65535 (explicit empty port invalid); validate the raw authority before a permissive URL parser can repair it. Reject empty labels except an optional terminal DNS dot, malformed IPv6 brackets, percent-encoded authority delimiters, and labels with invalid characters. A valid bracketed IPv6 literal is allowed. Preserve the escaped proxy path and remove only terminal slashes; never resolve a leading-slash relative URL against the origin. Validate before reporting unsupported endpoints.

Implement the endpoint table exactly as contract §5: OpenAI types `chat/completions`, `models`, `embeddings`; Anthropic `v1/messages`, `v1/models`; OpenWebUI `api/chat/completions`, `api/models`; Ollama `api/chat`, `api/tags`, `api/embed`. Unsupported embedding endpoints throw without sending. `convertLegacy` normalizes then appends `/v1` only for the two OpenAI types without an exact terminal `/v1`; runtime `build` never calls it.

Use this concrete URL-building/legacy kernel in `ProviderAPIRoot.swift` after the authority checks above. Validation must finish before these methods return; `normalize` is never bypassed:

```swift
public static func convertLegacy(type: ProviderType, baseURL: String) throws -> String {
    let root = try normalize(baseURL)
    if (type == .openai || type == .openaiCompatible) && !root.hasSuffix("/v1") {
        return root + "/v1"
    }
    return root
}
public static func build(type: ProviderType, baseURL: String, endpoint: ProviderEndpoint) throws -> URL {
    let root = try normalize(baseURL)
    let path: String
    switch (type, endpoint) {
    case (.openai, .chat), (.openaiCompatible, .chat): path = "chat/completions"
    case (.openai, .models), (.openaiCompatible, .models): path = "models"
    case (.openai, .embeddings), (.openaiCompatible, .embeddings): path = "embeddings"
    case (.anthropic, .chat): path = "v1/messages"
    case (.anthropic, .models): path = "v1/models"
    case (.openwebui, .chat): path = "api/chat/completions"
    case (.openwebui, .models): path = "api/models"
    case (.ollama, .chat): path = "api/chat"
    case (.ollama, .models): path = "api/tags"
    case (.ollama, .embeddings): path = "api/embed"
    case (.anthropic, .embeddings), (.openwebui, .embeddings):
        throw ProviderConfigurationError.unsupportedEndpoint
    }
    guard let url = URL(string: root + "/" + path) else {
        throw ProviderConfigurationError.invalidBaseURL
    }
    return url
}
```

The concrete canonical-message kernel in `ProviderWire` is:

```swift
static func canonicalMessages(_ turns: [ChatTurn]) -> [ChatTurn] {
    let systems = turns.filter { $0.role == .system }.map(\.content)
    let rest = turns.filter { $0.role != .system }
    return systems.isEmpty ? rest : [.init(role: .system, content: systems.joined(separator: "\n\n"))] + rest
}
```

Use this from all five adapters before encoding. Extend `OpenAIChatBody` with `let max_tokens: Int`, and encode `OpenAIChatBody(model: model, messages: wire, stream: true, max_tokens: options.maxOutputTokens)`. Anthropic sets `system` from the canonical first system and emits only non-system messages; Ollama maps canonical turns and calls `chat(model: model, messages: wire, options: .init(numCtx: options.runtimeContext, numPredict: options.maxOutputTokens))`.

**Length errors:** Add `ProviderRequestError.contextTooLong` in the new options file, keeping the existing exhaustive ProviderError switches source-compatible. On an unsuccessful chat response, read at most 65536 error bytes, check status 413 or structured `error.code` equal to `context_length_exceeded` / `prompt_too_long`, then throw the typed error. For Anthropic, `error.type=invalid_request_error` with a message starting `prompt is too long` is also recognized. All other 400 responses retain ordinary HTTP errors. Never log error bytes. In streaming code, collect the bounded error bytes before finishing instead of passing an empty body to `ProviderWire.error`; successful streams remain streaming. Apply the same classifier to Ollama chat's existing error body.

Add a `testLengthErrors` loop over `provider-errors-v1.json`, dispatch through the real adapter factory and assert contextTooLong vs ordinary HTTP, exactly one request, no tokens. The shared fixture includes the Anthropic prefix case explicitly. Also assert invalid JSON on a 400 stays an ordinary HTTP error. Task 8 makes the typed length error terminal; Task 10 localizes it.

Add the protocol default in `ChatRequestOptions.swift`:

```swift
public extension ChatStreaming {
    func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions)
        -> AsyncThrowingStream<String, Error> {
        stream(model: model, messages: messages)
    }
}
```

All real adapters implement that overload and make the old overload call it with `.defaults`. Validate `0 < output < runtime` before HTTP. Add `numPredict: Int?` with coding key `num_predict` to `OllamaChatRequest.Options` and pass both limits to `chat(... options:)`. OpenAI-style body gains `max_tokens`; Anthropic replaces its constant with the supplied output. Do not send `num_ctx` to OpenAI/Anthropic/OpenWebUI. Canonicalize all system turns to one `"\n\n"`-joined system text, preserving their order and all non-system message order; Anthropic puts it at top level. Empty/whitespace-only optional instruction sections are omitted by the logical input composer. No final-question duplication.

Route Ollama detect/list/embed/chat/delete/pull and new show through the same normalized stored root; do not invent a fallback localhost URL for invalid configuration. Existing direct Ollama constructors stay source-compatible; validation can occur when making the request so initializers need not become throwing.

- [ ] **Step 4: Add actual-request URL assertions for every successful `api-root-v1` case.** In the same class, dispatch `chat` through `adapter`, `models` through each adapter's existing `listModels` (Ollama `listModels()`), and embeddings through `OpenAIEmbeddingAdapter.embed(model:inputs:)` or `OllamaClient.embed(model:input:)`. Stub bodies respectively with the termination bodies above, `{"data":[]}` / `{"models":[]}`, and `{"data":[{"embedding":[1,0]}]}` / `{"embeddings":[[1,0]]}`. Assert `lastRequest.url.absoluteString == expectedURL`; errors assert **zero** recorded requests. Legacy rows first call `convertLegacy`, exactly once. This complements, rather than replaces, the pure helper test. Assert invalid options make zero requests. Add show test for custom proxy root and raw model tag in POST body.
Put this concrete dispatch test in `ProviderTransportContractTests` (the helper test already checks the invalid/error rows; router tests additionally assert their zero-request behavior):

```swift
func testFixtureURLsAtHTTPBoundary() async throws {
    let rows = try SharedFixtures.json("contracts/api-root-v1.json")["cases"] as! [[String: Any]]
    for c in rows where c["expectedURL"] != nil {
        StubURLProtocol.reset()
        let type = ProviderType(rawValue: c["type"] as! String)!
        let raw = c["baseURL"] as! String
        let root = c["legacy"] as! Bool ? try ProviderAPIRoot.convertLegacy(type: type, baseURL: raw) : raw
        let session = StubURLProtocol.session()
        switch ProviderEndpoint(rawValue: c["endpoint"] as! String)! {
        case .chat:
            finish(type)
            for try await _ in adapter(type, root: root).stream(model: "m", messages: [.init(role: .user, content: "Q")]) {}
        case .models:
            StubURLProtocol.enqueue(.json(Data((type == .ollama ? "{\"models\":[]}" : "{\"data\":[]}").utf8)))
            switch type {
            case .ollama:
                _ = try await OllamaClient(baseURL: URL(string: root)!, session: session).listModels()
            case .anthropic:
                _ = try await AnthropicChatAdapter.listModels(baseURL: root, apiKey: "k", session: session)
            case .openai, .openaiCompatible:
                _ = try await OpenAIChatAdapter.listModels(baseURL: root, apiKey: "k", session: session)
            case .openwebui:
                _ = try await OpenWebUIChatAdapter.listModels(baseURL: root, apiKey: "k", session: session)
            }
        case .embeddings:
            if type == .ollama {
                StubURLProtocol.enqueue(.json(Data("{\"embeddings\":[[1,0]]}".utf8)))
                _ = try await OllamaClient(baseURL: URL(string: root)!, session: session).embed(model: "m", input: ["x"])
            } else {
                StubURLProtocol.enqueue(.json(Data("{\"data\":[{\"embedding\":[1,0]}]}".utf8)))
                _ = try await OpenAIEmbeddingAdapter(baseURL: root, apiKey: "k", session: session).embed(model: "m", inputs: ["x"])
            }
        }
        XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, c["expectedURL"] as? String, c["name"] as! String)
    }
    StubURLProtocol.reset()
}
```

- [ ] **Step 5: Update old test inputs to exact `/v1` roots while preserving their expected `/v1/...` URL assertions** (`OpenAIAdapterTests.swift:50,147,181`). Change the invalid-base expectation from generic `.decoding` to `.invalidBaseURL`. Change the old Anthropic 8192-default assertion (`AnthropicAdapterTests.swift:64`) to 1024 and keep the explicit-333 fixture assertion. `ProviderTypeTests.swift:24` asserts the new default. Update old OpenAI root literals in `ProviderRouterTests.swift:82,201` to `/v1` while preserving URL expectations; Task 6 edits this file only after this commit. These are contract changes, not weakened tests.
- [ ] **Step 6: Run green:** `swift test --filter 'ProviderTransportContractTests|OpenAIAdapterTests|AnthropicAdapterTests|ProviderTypeTests'`, then `swift test` → all pass, all 27-plus corrected API-root cases and 25 wire cases exercised with zero live network.
- [ ] **Step 7: Commit:**

```bash
git add Sources/AINotebookCore/Providers/ProviderAPIRoot.swift Sources/AINotebookCore/Providers/ChatRequestOptions.swift Sources/AINotebookCore/Providers/ProviderType.swift Sources/AINotebookCore/Providers/ProviderWire.swift Sources/AINotebookCore/Providers/OpenAIAdapters.swift Sources/AINotebookCore/Providers/AnthropicChatAdapter.swift Sources/AINotebookCore/Providers/OpenWebUIChatAdapter.swift Sources/AINotebookCore/OllamaClient.swift Sources/AINotebookCore/OllamaChatTypes.swift Sources/AINotebookCore/OllamaClient+ChatStreaming.swift Sources/AINotebookCore/ChatEngine.swift Tests/AINotebookCoreTests/ProviderTransportContractTests.swift Tests/AINotebookCoreTests/ProviderTypeTests.swift Tests/AINotebookCoreTests/OpenAIAdapterTests.swift Tests/AINotebookCoreTests/AnthropicAdapterTests.swift Tests/AINotebookCoreTests/ProviderRouterTests.swift
git commit -m "feat(providers): enforce API roots and wire chat limits on Swift" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 3: [Windows] Exact roots, all-system handling, and options on the wire

**Depends on:** Task 1. **Parallel with:** Tasks 2, 4, 6, 8, 10 when their dependencies are satisfied.

**Files:** Create `W/Providers/{ProviderApiRoot,ChatRequestOptions}.cs`, `WT/Providers/ProviderTransportContractTests.cs`. Modify `W/Providers/{ProviderType,ProviderExceptions,OpenAIChatAdapter,OpenAIEmbeddingAdapter,OpenAIStyleWire,AnthropicChatAdapter,OpenWebUIChatAdapter}.cs`, `W/Ollama/{ChatTurn,OllamaAdapters,OllamaClient,OllamaDtos}.cs`, `WT/Providers/{ProviderTypeTests,OpenAiSseTests,OpenWebUISseTests,AnthropicSseTests}.cs`. Read-only `WT/Helpers/{SharedFixtures,StubHttpMessageHandler}.cs`.

**Grounding:** `OpenAIChatAdapter.cs:13` and `OpenAIEmbeddingAdapter.cs:33` append `/v1`; `OpenAIStyleWire.cs:39` has no limit; `AnthropicChatAdapter.cs:36` consumes only the first system and line 58 hardcodes 8192; `OllamaClient.cs:15` mutates shared BaseAddress and uses relative requests at lines 29,40,56,75,107,113,122; `OllamaDtos.cs:30` lacks NumPredict; `OllamaAdapters.cs:40` sends null options.

**Interfaces:** Produces C# root/options declarations above and `Task<string> OllamaClient.ShowAsync(string model, CancellationToken ct = default)`. Consumes `IChatStreaming`, `IEmbeddingProducing`, `ProviderTypeExtensions.FromStorageString(string)` and shared fixtures. Swift counterparts are Task 2's APIs. Constructors and old no-options stream overloads remain available.

- [ ] **Step 1: Add the capture tests, including this regression that fails against today's code.**

```csharp
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class ProviderTransportContractTests
{
    [Fact]
    public async Task CustomOllamaRootWinsOverSharedClientBaseAddress()
    {
        var stub = new StubHttpMessageHandler().Json("""{"models":[]}""");
        using var http = new HttpClient(stub) { BaseAddress = new Uri("http://127.0.0.1:11434") };
        var client = new OllamaClient(http, new Uri("http://gpu-box:11434/proxy/ollama"));
        await client.ListModelsAsync();
        Assert.Equal("http://gpu-box:11434/proxy/ollama/api/tags", stub.LastRequest!.RequestUri!.AbsoluteUri);
        Assert.Equal("http://127.0.0.1:11434/", http.BaseAddress!.AbsoluteUri);
    }
    [Fact]
    public void ApiRootFixture()
    {
        foreach (var c in SharedFixtures.Json("contracts/api-root-v1.json").GetProperty("cases").EnumerateArray())
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var endpoint = Enum.Parse<ProviderEndpoint>(c.GetProperty("endpoint").GetString()!, true);
            Uri Build()
            {
                var root = c.GetProperty("baseURL").GetString()!;
                if (c.GetProperty("legacy").GetBoolean()) root = ProviderApiRoot.ConvertLegacy(type, root);
                return ProviderApiRoot.Build(type, root, endpoint);
            }
            if (c.TryGetProperty("expectedError", out var error))
                Assert.Equal(error.GetString(), Assert.Throws<ProviderConfigurationException>(() => Build()).Code);
            else Assert.Equal(c.GetProperty("expectedURL").GetString(), Build().AbsoluteUri);
        }
    }
    private static IChatStreaming Adapter(ProviderType type, string root, HttpClient http) => type switch
    {
        ProviderType.Ollama => new OllamaChatAdapter(new OllamaClient(http, new Uri(root))),
        ProviderType.Anthropic => new AnthropicChatAdapter(http, root, "k"),
        ProviderType.OpenWebUI => new OpenWebUIChatAdapter(http, root, "k"),
        _ => new OpenAIChatAdapter(http, root, "k")
    };
    private static string Finish(ProviderType type) => type switch
    {
        ProviderType.Ollama => "{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n",
        ProviderType.Anthropic => "data: {\"type\":\"message_stop\"}\n",
        _ => "data: [DONE]\n"
    };
    [Fact]
    public async Task OptionsReachEveryAdapter()
    {
        foreach (var c in SharedFixtures.Json("contracts/provider-options-v1.json").GetProperty("cases").EnumerateArray())
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var stub = new StubHttpMessageHandler().Json(Finish(type));
            using var http = new HttpClient(stub);
            var options = new ChatRequestOptions(c.GetProperty("runtimeContext").GetInt32(), c.GetProperty("maxOutputTokens").GetInt32());
            await foreach (var _ in Adapter(type, "https://unit.example/proxy/v1", http)
                .StreamAsync("m", [new(ChatRole.User, "Q")], options)) { }
            using var json = JsonDocument.Parse(stub.LastRequestBody!);
            var body = json.RootElement;
            var expected = c.GetProperty("expected");
            if (type == ProviderType.Ollama)
            {
                Assert.True(JsonElement.DeepEquals(expected.GetProperty("options"), body.GetProperty("options")));
                Assert.False(body.TryGetProperty("max_tokens", out _));
            }
            else
            {
                Assert.Equal(expected.GetProperty("max_tokens").GetInt32(), body.GetProperty("max_tokens").GetInt32());
                Assert.False(body.TryGetProperty("options", out _));
                Assert.False(body.TryGetProperty("num_ctx", out _));
                Assert.False(body.TryGetProperty("num_predict", out _));
            }
        }
    }
    [Fact]
    public async Task WireOrderAndMultipleSystems()
    {
        var rows = SharedFixtures.Json("contracts/wire-order-v1.json").GetProperty("cases").EnumerateArray()
            .Concat(SharedFixtures.Json("contracts/provider-systems-v1.json").GetProperty("cases").EnumerateArray());
        foreach (var c in rows)
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty(c.TryGetProperty("provider", out _) ? "provider" : "type").GetString()!);
            var input = c.GetProperty("input");
            var turns = new List<ChatTurn>();
            if (input.ValueKind == JsonValueKind.Array)
                turns.AddRange(input.EnumerateArray().Select(x => new ChatTurn(Enum.Parse<ChatRole>(x.GetProperty("role").GetString()!, true), x.GetProperty("content").GetString()!)));
            else
            {
                turns.Add(new(ChatRole.System, input.GetProperty("rulesText").GetString()!));
                var instructions = input.GetProperty("userInstructions").GetString()!;
                if (!string.IsNullOrWhiteSpace(instructions)) turns.Add(new(ChatRole.System, instructions));
                turns.AddRange(input.GetProperty("history").EnumerateArray().Select(x => new ChatTurn(Enum.Parse<ChatRole>(x.GetProperty("role").GetString()!, true), x.GetProperty("content").GetString()!)));
                turns.Add(new(ChatRole.User, input.GetProperty("finalUserContent").GetString()!));
            }
            var stub = new StubHttpMessageHandler().Json(Finish(type));
            using var http = new HttpClient(stub);
            await foreach (var _ in Adapter(type, "https://unit.example/root", http).StreamAsync("m", turns)) { }
            using var json = JsonDocument.Parse(stub.LastRequestBody!);
            var expected = c.GetProperty("expected");
            Assert.True(JsonElement.DeepEquals(expected.GetProperty("messages"), json.RootElement.GetProperty("messages")), c.GetProperty("name").GetString());
            if (expected.TryGetProperty("system", out var system))
                Assert.Equal(system.GetString(), json.RootElement.GetProperty("system").GetString());
            else Assert.False(json.RootElement.TryGetProperty("system", out _));
        }
    }
}
```

- [ ] **Step 2: Run red:** `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ProviderTransportContractTests` → missing symbols, then custom-root and system-shape failures.
- [ ] **Step 3: Implement.** Use `Uri.TryCreate` plus raw authority checks with exactly Task 2's stated grammar, but do not use `new Uri(base, "/path")` (it discards the proxy prefix). `Normalize` returns the trimmed original prefix, not Uri's rewritten path. `Build` validates before unsupported-endpoint checking and concatenates `root + "/" + endpoint`. Legacy conversion is a separate pure method, never part of normal request dispatch. Set OpenAI default to `/v1`.

Store `_baseUrl` in `OllamaClient`; never assign `HttpClient.BaseAddress`. Build absolute URIs for detect/tags/embed/chat/delete/pull/show, retaining any proxy prefix regardless of the shared client's BaseAddress. `ShowAsync` posts the model and returns validated response bytes as a string. Extend `OllamaChatOptions(double? Temperature = null, int? NumCtx = null, int? NumPredict = null)` with `[JsonPropertyName("num_predict")]`.

Implement these concrete Core kernels:

```csharp
public static string ConvertLegacy(ProviderType type, string baseUrl)
{
    var root = Normalize(baseUrl);
    return (type is ProviderType.OpenAI or ProviderType.OpenAICompatible) && !root.EndsWith("/v1", StringComparison.Ordinal)
        ? root + "/v1" : root;
}
public static Uri Build(ProviderType type, string baseUrl, ProviderEndpoint endpoint)
{
    var root = Normalize(baseUrl);
    var path = (type, endpoint) switch
    {
        (ProviderType.OpenAI or ProviderType.OpenAICompatible, ProviderEndpoint.Chat) => "chat/completions",
        (ProviderType.OpenAI or ProviderType.OpenAICompatible, ProviderEndpoint.Models) => "models",
        (ProviderType.OpenAI or ProviderType.OpenAICompatible, ProviderEndpoint.Embeddings) => "embeddings",
        (ProviderType.Anthropic, ProviderEndpoint.Chat) => "v1/messages",
        (ProviderType.Anthropic, ProviderEndpoint.Models) => "v1/models",
        (ProviderType.OpenWebUI, ProviderEndpoint.Chat) => "api/chat/completions",
        (ProviderType.OpenWebUI, ProviderEndpoint.Models) => "api/models",
        (ProviderType.Ollama, ProviderEndpoint.Chat) => "api/chat",
        (ProviderType.Ollama, ProviderEndpoint.Models) => "api/tags",
        (ProviderType.Ollama, ProviderEndpoint.Embeddings) => "api/embed",
        _ => throw new ProviderConfigurationException("unsupportedEndpoint")
    };
    if (!Uri.TryCreate(root + "/" + path, UriKind.Absolute, out var uri))
        throw new ProviderConfigurationException("invalidBaseURL");
    return uri;
}
// In OpenAIStyleWire:
internal static IReadOnlyList<ChatTurn> CanonicalMessages(IReadOnlyList<ChatTurn> turns)
{
    var system = turns.Where(x => x.Role == ChatRole.System).Select(x => x.Content).ToArray();
    var rest = turns.Where(x => x.Role != ChatRole.System).ToList();
    if (system.Length != 0) rest.Insert(0, new(ChatRole.System, string.Join("\n\n", system)));
    return rest;
}
```

Use `new { model, messages = wire, stream = true, max_tokens = options.MaxOutputTokens }` for OpenAI-style chat, and `new OllamaChatOptions(NumCtx: options.RuntimeContext, NumPredict: options.MaxOutputTokens)` for Ollama. Anthropic uses canonical systems at top level and the supplied output count.

Add typed `ProviderHttpException.StatusCode` and `ProviderContextTooLongException` to `ProviderExceptions.cs`. `ThrowForStatus` maps 401/403 to auth, 429 to the existing rate-limit type, and other errors to typed HTTP status (never parse exception-message strings). Read at most 65536 bytes from unsuccessful chat responses and classify 413, `error.code=context_length_exceeded|prompt_too_long`, or Anthropic `error.type=invalid_request_error` plus message prefix `prompt is too long` as context-too-long. Unknown 400/malformed error bodies stay typed HTTP. Apply the classifier to Ollama's existing error path too. Keep successful streaming incremental. Execute `provider-errors-v1.json` against every real adapter and assert error type plus one request/no tokens.

Make `OpenAIStyleWire.ListModelsAsync` require an array `data` and string IDs; missing/wrong-kind fields throw JsonException instead of returning `[]` or skipping invalid items. `OllamaClient.ListModelsAsync` must reject a null/missing/wrong-kind `models` array and malformed names. This foundation gives Task 7 typed status/schema errors it can classify without changing these files again. Preserve valid empty arrays. Anthropic's catch-all removal stays in Task 7.

Give `IChatStreaming` a default options overload calling the old overload; real adapters implement both, with old→new Defaults. Validate options before dispatch. OpenAI-style serializers emit `max_tokens`; Ollama emits `options.num_ctx` and `options.num_predict`; Anthropic hoists **all** systems in input order and excludes every system from `messages`. Shared non-Anthropic serialization emits exactly one joined system followed by original non-system turns. Existing cancellation tokens reach every send and stream reader.

- [ ] **Step 4: Add actual HTTP dispatch coverage of each successful API-root case**, using the adapter factory above for chat, each adapter's `ListModelsAsync` for discovery, and `OpenAIEmbeddingAdapter.EmbedAsync` / `OllamaClient.EmbedAsync` for supported embeddings. Use `{"data":[]}` for cloud model lists, `{"models":[]}` for Ollama, `{"data":[{"embedding":[1,0]}]}` for OpenAI embeddings and `{"embeddings":[[1,0]]}` for Ollama embeddings; expected URLs come from the fixture, not reconstructed in the test. Invalid roots/unsupported endpoints and invalid options assert zero `stub.AllRequests`. Add ShowAsync body/URL assertion for the custom root. Keep the explicit BaseAddress regression above.
Add this actual-request matrix method to the new test class:

```csharp
[Fact]
public async Task FixtureUrlsAtHttpBoundary()
{
    foreach (var c in SharedFixtures.Json("contracts/api-root-v1.json").GetProperty("cases").EnumerateArray())
    {
        if (!c.TryGetProperty("expectedURL", out var expected)) continue;
        var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
        var root = c.GetProperty("baseURL").GetString()!;
        if (c.GetProperty("legacy").GetBoolean()) root = ProviderApiRoot.ConvertLegacy(type, root);
        var endpoint = Enum.Parse<ProviderEndpoint>(c.GetProperty("endpoint").GetString()!, true);
        var body = endpoint switch
        {
            ProviderEndpoint.Chat => Finish(type),
            ProviderEndpoint.Models => type == ProviderType.Ollama ? "{\"models\":[]}" : "{\"data\":[]}",
            _ => type == ProviderType.Ollama ? "{\"embeddings\":[[1,0]]}" : "{\"data\":[{\"embedding\":[1,0]}]}"
        };
        var stub = new StubHttpMessageHandler().Json(body);
        using var http = new HttpClient(stub) { BaseAddress = new Uri("https://wrong.example/") };
        switch (endpoint)
        {
            case ProviderEndpoint.Chat:
                await foreach (var _ in Adapter(type, root, http).StreamAsync("m", [new(ChatRole.User, "Q")])) { }
                break;
            case ProviderEndpoint.Models:
                switch (type)
                {
                    case ProviderType.Ollama: await new OllamaClient(http, new Uri(root)).ListModelsAsync(); break;
                    case ProviderType.Anthropic: await AnthropicChatAdapter.ListModelsAsync(http, root, "k"); break;
                    case ProviderType.OpenWebUI: await OpenWebUIChatAdapter.ListModelsAsync(http, root, "k"); break;
                    default: await OpenAIChatAdapter.ListModelsAsync(http, root, "k"); break;
                }
                break;
            case ProviderEndpoint.Embeddings:
                if (type == ProviderType.Ollama) await new OllamaClient(http, new Uri(root)).EmbedAsync("m", ["x"]);
                else await new OpenAIEmbeddingAdapter(http, root, "k").EmbedAsync("m", ["x"]);
                break;
        }
        Assert.Single(stub.AllRequests);
        Assert.Equal(expected.GetString(), stub.LastRequest!.RequestUri!.AbsoluteUri);
    }
}
```

- [ ] **Step 5: Update existing OpenAI tests to pass exact `/v1` roots while preserving their URL expectations; change default expectations to contract defaults.** Do not retain assertions that a second system becomes a user. Strengthen generic HTTP tests in OpenAiSseTests/OpenWebUISseTests to assert `ProviderHttpException.StatusCode` rather than only the generic base exception. No App changes are needed because old chat signatures still compile.
- [ ] **Step 6: Run green:** `dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~ProviderTransportContractTests|FullyQualifiedName~OpenAiSseTests|FullyQualifiedName~AnthropicSseTests|FullyQualifiedName~ProviderTypeTests"`, then `dotnet test windows/tests/AINotebook.Core.Tests` → zero failed/skipped contract tests.
- [ ] **Step 7: Commit:**

```bash
git add windows/src/AINotebook.Core/Providers/ProviderApiRoot.cs windows/src/AINotebook.Core/Providers/ChatRequestOptions.cs windows/src/AINotebook.Core/Providers/ProviderType.cs windows/src/AINotebook.Core/Providers/ProviderExceptions.cs windows/src/AINotebook.Core/Providers/OpenAIChatAdapter.cs windows/src/AINotebook.Core/Providers/OpenAIEmbeddingAdapter.cs windows/src/AINotebook.Core/Providers/OpenAIStyleWire.cs windows/src/AINotebook.Core/Providers/AnthropicChatAdapter.cs windows/src/AINotebook.Core/Providers/OpenWebUIChatAdapter.cs windows/src/AINotebook.Core/Ollama/ChatTurn.cs windows/src/AINotebook.Core/Ollama/OllamaAdapters.cs windows/src/AINotebook.Core/Ollama/OllamaClient.cs windows/src/AINotebook.Core/Ollama/OllamaDtos.cs windows/tests/AINotebook.Core.Tests/Providers/ProviderTransportContractTests.cs windows/tests/AINotebook.Core.Tests/Providers/ProviderTypeTests.cs windows/tests/AINotebook.Core.Tests/Providers/OpenAiSseTests.cs windows/tests/AINotebook.Core.Tests/Providers/OpenWebUISseTests.cs windows/tests/AINotebook.Core.Tests/Providers/AnthropicSseTests.cs
git commit -m "feat(win-core): enforce API roots, system order and wire limits" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 4: [Swift] Limits policy, presets, persistence, and one-time conversion integration

**Depends on:** Tasks 1/2 and WP3's Swift v19 commit containing the exact DDL/conversion handoff above. **Parallel with:** Tasks 3, 5, 7, 9, 11. Do not create a temporary production schema while waiting for WP3.

**Files:** Create `S/Providers/{ProviderModelLimits,ProviderPresets}.swift`, `S/NotebookStore+ProviderModelLimits.swift`, `ST/{ProviderLimitPolicyTests,ProviderModelLimitsStoreTests,ProviderRootUpgradeTests}.swift`. Read `S/NotebookStore+Providers.swift:35` for consent-preserving upsert, `S/NotebookStore.swift:115` for database access, `S/MigrationV11.swift:10` and `S/MigrationV18.swift:7` for existing schema/migration history. WP3's migration/registration files are read-only.

**Interfaces:** Produces Swift `ProviderModelLimits`, `ProviderLimitPolicy`, `ProviderPresets`, and the three store signatures in Shared interfaces. Consumes `ChatRequestOptions.validate() throws`, WP3's table, and Task 1 fixtures. C# counterparts have the same fields and SQL semantics in Task 5.

- [ ] **Step 1: Add policy and real-store failing tests.**

```swift
import Foundation
import XCTest
@testable import AINotebookCore

final class ProviderLimitPolicyTests: XCTestCase {
    func testSharedLimits() throws {
        for c in try SharedFixtures.json("contracts/provider-limits-v1.json")["cases"] as! [[String: Any]] {
            let window = c["window"] as? Int
            if let user = c["user"] as? [String: Int] {
                let value = ProviderModelLimits(providerId: "p", model: c["model"] as! String,
                    contextWindow: window, runtimeContext: user["runtimeContext"]!,
                    maxOutputTokens: user["maxOutputTokens"]!, source: "user")
                XCTAssertThrowsError(try value.validate()) {
                    XCTAssertEqual($0 as? ProviderConfigurationError, .invalidLimits)
                }
                continue
            }
            if let show = c["show"] {
                let data = try JSONSerialization.data(withJSONObject: show)
                XCTAssertEqual(try ProviderLimitPolicy.contextWindow(fromOllamaShow: data), window)
            }
            let value = try ProviderLimitPolicy.automatic(providerId: "p",
                type: ProviderType(rawValue: c["type"] as! String)!, model: c["model"] as! String,
                contextWindow: window)
            let e = c["expected"] as! [String: Any]
            XCTAssertEqual(value.contextWindow, e["contextWindow"] as? Int)
            XCTAssertEqual(value.runtimeContext, e["runtimeContext"] as? Int)
            XCTAssertEqual(value.maxOutputTokens, e["maxOutputTokens"] as? Int)
            XCTAssertEqual(value.source, e["source"] as? String)
            XCTAssertEqual(value.isAssumed, e["isAssumed"] as? Bool)
        }
    }
    func testPresets() throws {
        let rows = try SharedFixtures.json("contracts/provider-presets-v1.json")["cases"] as! [[String: String]]
        XCTAssertEqual(ProviderPresets.all.count, rows.count)
        for (preset, row) in zip(ProviderPresets.all, rows) {
            XCTAssertEqual(preset.id, row["name"])
            XCTAssertEqual(preset.baseURL, row["baseURL"])
            XCTAssertEqual(preset.helpKey, row["helpKey"])
        }
    }
}

@MainActor
final class ProviderModelLimitsStoreTests: XCTestCase {
    func testUserOverrideSurvivesAutoRefresh() throws {
        let c = (try SharedFixtures.json("contracts/provider-store-v1.json")["cases"] as! [[String: Any]])
            .first { $0["name"] as? String == "user-survives-auto" }!
        let store = try NotebookStore(path: .inMemory)
        let id = c["providerId"] as! String, model = c["model"] as! String
        try store.saveProvider(.init(id: id, type: .ollama, name: "P", baseURL: "http://localhost:11434"))
        let user = ProviderModelLimits(providerId: id, model: model,
            contextWindow: c["contextWindow"] as? Int, runtimeContext: c["runtimeContext"] as! Int,
            maxOutputTokens: c["maxOutputTokens"] as! Int, source: "user")
        try store.saveProviderModelLimits(user)
        let auto = try ProviderLimitPolicy.automatic(providerId: id, type: .ollama, model: model, contextWindow: 32768)
        try store.saveProviderModelLimits(auto)
        XCTAssertEqual(try store.providerModelLimits(providerId: id, model: model), user)
        try store.deleteProviderModelLimits(providerId: id, model: model)
        try store.saveProviderModelLimits(auto)
        XCTAssertEqual(try store.providerModelLimits(providerId: id, model: model)?.source, "auto")
        try store.deleteProvider(id: id)
        XCTAssertNil(try store.providerModelLimits(providerId: id, model: model))
    }
}
```

- [ ] **Step 2: Run red:** `swift test --filter 'ProviderLimitPolicyTests|ProviderModelLimitsStoreTests'` → missing DTO/policy/store methods. The store test must use the migrated real store, not its own CREATE TABLE.
- [ ] **Step 3: Implement this concrete policy and the fixture's preset literals.**

```swift
public func validate() throws { // ProviderModelLimits
    guard !providerId.isEmpty,
          !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          source == "auto" || source == "user",
          runtimeContext > 0, maxOutputTokens > 0, maxOutputTokens < runtimeContext,
          contextWindow.map({ $0 > 0 && runtimeContext <= $0 }) ?? true else {
        throw ProviderConfigurationError.invalidLimits
    }
}
// ProviderLimitPolicy.automatic:
let known: Int? = type == .openai && ["gpt-4o-mini", "gpt-4o-mini-2024-07-18"].contains(model)
    ? 128_000 : nil
let window = contextWindow ?? known
if let window, window < 2 { throw ProviderConfigurationError.invalidLimits }
let runtime = min(RagContractV1.Providers.defaultRuntimeContext, window ?? Int.max)
let output = min(RagContractV1.Providers.defaultMaxOutputTokens, runtime - 1)
let result = ProviderModelLimits(providerId: providerId, model: model,
    contextWindow: window, runtimeContext: runtime, maxOutputTokens: output, source: "auto")
try result.validate()
return result
```

Parse `/api/show` as a JSON object, read string `model_info.general.architecture`, then **only** that architecture's `<architecture>.context_length`. Missing/invalid metadata yields nil; malformed JSON throws. Reject booleans, fractions, integers below 2 and numbers above Int32.max as metadata; do not infer a ceiling from another architecture's field. `isAssumed` is `source == "auto" && contextWindow == nil`. DTO/init is explicit and public, options derive from its two limits.

Store operations use `runOnDatabase`. Fetch by both ID and exact model; bind nullable window as SQL NULL; validate reads and writes. Use this upsert, preserving user values even if an asynchronous auto refresh races a user save:

```sql
INSERT INTO provider_model_limits(provider_id, model, context_window, runtime_context, max_output_tokens, source)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(provider_id, model) DO UPDATE SET
 context_window=excluded.context_window, runtime_context=excluded.runtime_context,
 max_output_tokens=excluded.max_output_tokens, source=excluded.source
WHERE provider_model_limits.source <> 'user' OR excluded.source = 'user';
```

- [ ] **Step 4: Add fixture-backed isolation/reset/cascade tests** for the other three storage operations, plus invalid-limit insert rejection, missing provider FK rejection, and reopen persistence. Test `provider-isolation` with both IDs and the same raw colon-containing model. Check integer fields, nullable context, source and all constraints through typed reads.
- [ ] **Step 5: Add the one-time-conversion integration tests.** `ProviderRootUpgradeTests` creates a temporary SQLite file via a `DatabaseMigrator` registering existing `registerMigrationV1` through `V15` plus `V18` (the registration list is in `NotebookStore.swift:32`), seeds all `legacy-*` fixture providers using parameterized SQL, closes the queue, then opens `NotebookStore(path: StorePath(fileURL: url))` to execute WP3 v19. Assert each fixture's `after`, unchanged IDs/consent/timestamps/enabled state, and a second reopen with no root change. Save the `new-versionless` case **after** upgrade using `saveProvider`, reopen and assert the exact versionless root survived. Include an invalid legacy root `http://user:secret@host/v1`: the migration preserves it, and request validation rejects it without HTTP. Remove the temporary directory in `defer` after stores/queues leave scope. This test must fail if WP3's conversion hook is absent.
- [ ] **Step 6: Run green:** `swift test --filter 'ProviderLimitPolicyTests|ProviderModelLimitsStoreTests|ProviderRootUpgradeTests'`, then `swift test` → all green, migrations run once, no live provider requests.
- [ ] **Step 7: Commit:**

```bash
git add Sources/AINotebookCore/Providers/ProviderModelLimits.swift Sources/AINotebookCore/Providers/ProviderPresets.swift Sources/AINotebookCore/NotebookStore+ProviderModelLimits.swift Tests/AINotebookCoreTests/ProviderLimitPolicyTests.swift Tests/AINotebookCoreTests/ProviderModelLimitsStoreTests.swift Tests/AINotebookCoreTests/ProviderRootUpgradeTests.swift
git commit -m "feat(core): persist provider model limits and compatible presets" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 5: [Windows] Limits policy, locked store API, and upgrade integration

**Depends on:** Tasks 1/3 and WP3's Windows v19 commit containing the handoff DDL/conversion. **Parallel with:** Tasks 2, 4, 6, 8, 10.

**Files:** Create `W/Providers/{ProviderModelLimits,ProviderPresets}.cs`, `W/Storage/NotebookStore.ProviderModelLimits.cs`, `WT/Providers/ProviderLimitPolicyTests.cs`, `WT/Storage/{ProviderModelLimitsStoreTests,ProviderRootUpgradeTests}.cs`. Read-only `W/Storage/NotebookStore.cs:34`, `NotebookStore.Providers.cs:8`, `Migrator.cs:12,35`, `WT/Storage/MigrationV17Tests.cs:28` (migration bookkeeping pattern, not an excuse to replay v19 on a v19 schema).

**Interfaces:** Produces C# limit/preset/store declarations in Shared interfaces; consumes `ChatRequestOptions`, `ProviderType`, shared fixtures, WP3 v19. Swift signatures are `providerModelLimits(providerId:model:) throws -> ProviderModelLimits?`, `saveProviderModelLimits(_:) throws`, `deleteProviderModelLimits(providerId:model:) throws`.

- [ ] **Step 1: Add these tests.**

```csharp
using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class ProviderLimitPolicyTests
{
    [Fact]
    public void SharedLimits()
    {
        foreach (var c in SharedFixtures.Json("contracts/provider-limits-v1.json").GetProperty("cases").EnumerateArray())
        {
            int? window = c.GetProperty("window").ValueKind == JsonValueKind.Null ? null : c.GetProperty("window").GetInt32();
            var model = c.GetProperty("model").GetString()!;
            if (c.TryGetProperty("user", out var user))
            {
                var value = new ProviderModelLimits("p", model, window, user.GetProperty("runtimeContext").GetInt32(), user.GetProperty("maxOutputTokens").GetInt32(), "user");
                Assert.Equal("invalidLimits", Assert.Throws<ProviderConfigurationException>(value.Validate).Code);
                continue;
            }
            if (c.TryGetProperty("show", out var show))
                Assert.Equal(window, ProviderLimitPolicy.ContextWindowFromOllamaShow(show.GetRawText()));
            var limits = ProviderLimitPolicy.Automatic("p", ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!), model, window);
            var e = c.GetProperty("expected");
            Assert.Equal(e.GetProperty("contextWindow").ValueKind == JsonValueKind.Null ? (int?)null : e.GetProperty("contextWindow").GetInt32(), limits.ContextWindow);
            Assert.Equal(e.GetProperty("runtimeContext").GetInt32(), limits.RuntimeContext);
            Assert.Equal(e.GetProperty("maxOutputTokens").GetInt32(), limits.MaxOutputTokens);
            Assert.Equal(e.GetProperty("source").GetString(), limits.Source);
            Assert.Equal(e.GetProperty("isAssumed").GetBoolean(), limits.IsAssumed);
        }
    }
    [Fact]
    public void Presets()
    {
        var rows = SharedFixtures.Json("contracts/provider-presets-v1.json").GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(rows.Length, ProviderPresets.All.Count);
        for (var i = 0; i < rows.Length; i++)
        {
            Assert.Equal(rows[i].GetProperty("name").GetString(), ProviderPresets.All[i].Id);
            Assert.Equal(rows[i].GetProperty("baseURL").GetString(), ProviderPresets.All[i].BaseUrl);
            Assert.Equal(rows[i].GetProperty("helpKey").GetString(), ProviderPresets.All[i].HelpKey);
        }
    }
}
```

In `ProviderModelLimitsStoreTests.cs` use the same imports, namespace `AINotebook.Core.Tests.Storage`, and this test:

```csharp
public class ProviderModelLimitsStoreTests
{
    [Fact]
    public void UserOverrideSurvivesAutoRefresh()
    {
        var c = SharedFixtures.Json("contracts/provider-store-v1.json").GetProperty("cases")
            .EnumerateArray().Single(x => x.GetProperty("name").GetString() == "user-survives-auto");
        using var store = new NotebookStore(StorePath.InMemory);
        var id = c.GetProperty("providerId").GetString()!;
        var model = c.GetProperty("model").GetString()!;
        store.SaveProvider(new(id, ProviderType.Ollama, "P", "http://localhost:11434", true, true, DateTime.UtcNow));
        var user = new ProviderModelLimits(id, model, c.GetProperty("contextWindow").GetInt32(),
            c.GetProperty("runtimeContext").GetInt32(), c.GetProperty("maxOutputTokens").GetInt32(), "user");
        store.SaveProviderModelLimits(user);
        var automatic = ProviderLimitPolicy.Automatic(id, ProviderType.Ollama, model, 32768);
        store.SaveProviderModelLimits(automatic);
        Assert.Equal(user, store.ProviderModelLimits(id, model));
        store.DeleteProviderModelLimits(id, model);
        store.SaveProviderModelLimits(automatic);
        Assert.Equal("auto", store.ProviderModelLimits(id, model)!.Source);
        store.DeleteProvider(id);
        Assert.Null(store.ProviderModelLimits(id, model));
    }
}
```

- [ ] **Step 2: Run red:** `dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~ProviderLimitPolicyTests|FullyQualifiedName~ProviderModelLimitsStoreTests"` → missing APIs.
- [ ] **Step 3: Implement the literal preset table, DTO and pure policy.** `Validate` rejects blank ID/model, invalid source, non-positive limits/window, output ≥ runtime and runtime > known window. `Automatic` selects a supplied window, otherwise exact `(OpenAI, gpt-4o-mini)` / `(OpenAI, gpt-4o-mini-2024-07-18)` 128000 entries, otherwise null; reject a supplied window below 2 before subtraction; runtime is `Math.Min(8192, window ?? int.MaxValue)`, output `Math.Min(1024, runtime - 1)`, source auto, then Validate. Do not match compatible IDs against the OpenAI table. Show parser uses `JsonDocument`, architecture-specific context field and `TryGetInt32`, positive >1; missing or invalid metadata returns null, malformed JSON throws.

Implement the write method with this complete lock/upsert body:

```csharp
public void SaveProviderModelLimits(ProviderModelLimits limits)
{
    limits.Validate();
    lock (_gate)
    {
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = """
            INSERT INTO provider_model_limits(provider_id, model, context_window, runtime_context, max_output_tokens, source)
            VALUES ($p, $m, $w, $c, $o, $s)
            ON CONFLICT(provider_id, model) DO UPDATE SET
              context_window=excluded.context_window, runtime_context=excluded.runtime_context,
              max_output_tokens=excluded.max_output_tokens, source=excluded.source
            WHERE provider_model_limits.source <> 'user' OR excluded.source = 'user'
            """;
        cmd.Parameters.AddWithValue("$p", limits.ProviderId);
        cmd.Parameters.AddWithValue("$m", limits.Model);
        cmd.Parameters.AddWithValue("$w", (object?)limits.ContextWindow ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$c", limits.RuntimeContext);
        cmd.Parameters.AddWithValue("$o", limits.MaxOutputTokens);
        cmd.Parameters.AddWithValue("$s", limits.Source);
        cmd.ExecuteNonQuery();
    }
}
```

Read selects all six fields with `WHERE provider_id=$p AND model=$m`; use `IsDBNull` before GetInt32, validate the DTO, and dispose the reader before leaving `_gate`. Delete uses those same two bound keys. No schema fallback/creation and no network in this partial.

- [ ] **Step 4: Test every store fixture operation**, including independent providers sharing `m:tag`, cascade, reset, all invalid constraints, and disk reopen. Add `Task.WhenAll` coverage of parallel reads/writes/deletes on different model IDs; verify no connection concurrency exception and valid final rows. The test itself uses typed APIs; any raw SQL assertion locks `store.Gate` for the entire reader lifetime.
- [ ] **Step 5: Exercise actual pre-v19 conversion in `ProviderRootUpgradeTests`.** WP3 must expose a testable migration-to-version entry point `Migrator.Migrate(SqliteConnection conn, int throughVersion)` in its own commit (existing `Migrate(conn)` keeps applying all migrations). Create a temporary file, use a private test gate while opening the connection and calling `Migrator.Migrate(conn, 18)`, seed `legacy-*` fixture rows with parameters, close the connection, then open a normal `NotebookStore(new StorePath(path))`. Assert roots and unchanged identity/consent/time/enabled values; dispose and reopen twice. Save `new-versionless` after v19 and assert it remains versionless after restart. Invalid legacy root is preserved and rejected at dispatch. WP3 owns this additive migration entry point, not this task; it must not edit any shipped migration body. This dependency is part of the WP3 handoff, not a reflection-based test workaround.
- [ ] **Step 6: Run green:** `dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~ProviderLimitPolicyTests|FullyQualifiedName~ProviderModelLimitsStoreTests|FullyQualifiedName~ProviderRootUpgradeTests"`, then `dotnet test windows/tests/AINotebook.Core.Tests` → all pass.
- [ ] **Step 7: Commit:**

```bash
git add windows/src/AINotebook.Core/Providers/ProviderModelLimits.cs windows/src/AINotebook.Core/Providers/ProviderPresets.cs windows/src/AINotebook.Core/Storage/NotebookStore.ProviderModelLimits.cs windows/tests/AINotebook.Core.Tests/Providers/ProviderLimitPolicyTests.cs windows/tests/AINotebook.Core.Tests/Storage/ProviderModelLimitsStoreTests.cs windows/tests/AINotebook.Core.Tests/Storage/ProviderRootUpgradeTests.cs
git commit -m "feat(win-core): add provider limit policy, presets and locked persistence" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 6: [Swift] Honest discovery and immutable provider sessions

**Depends on:** Tasks 2/4. **Parallel with:** Tasks 3, 5, 7, 9, 11. **Files:** Create `S/Providers/{ProviderSession,ProviderDiscovery}.swift`, `ST/ProviderSessionTests.swift`. Modify `S/Providers/ProviderRouter.swift`, `ST/ProviderRouterTests.swift`. Read-only `S/Providers/{ProviderSelection,SecretStore}.swift`, `S/{Embedder,EmbeddingWorker}.swift`, `ST/EmbedderTests.swift`.

**Grounding:** Router lines 91–129 re-read config/key on each chat invocation; lines 137–164 handle composite embedding keys and silently substitute Ollama; lines 173–220 swallow discovery and return binary connection status. `ProviderSelection.swift:17` exposes synchronous selection tuples; `SecretStore.swift:6` exposes synchronous key access. `EmbeddingWorker.swift:18,44` supplies `kick()` and `waitUntilIdle()`.

**Interfaces:** Produces Swift `ProviderChatSession`, `ChatSessionPreparing`, `ProviderProbeResult`, and router's `prepareChat`, `discoverModels`, `probe`, `resolveLimits` signatures above. Introduce `public struct ProviderListingUnsupported: Error, Sendable { public init() {} }`. C# counterpart is `ProviderListingUnsupportedException` in Task 7. Existing `stream`/`embed` signatures continue to work. UI-only `listModels`/`testConnection` wrappers remain temporarily source-compatible until Task 10 deletes them; they must not be used by new code.

- [ ] **Step 1: Add the complete probe-matrix test.**

```swift
import Foundation
import XCTest
@testable import AINotebookCore

@MainActor
final class ProviderSessionTests: XCTestCase {
    func testProbeFixture() async throws {
        let store = try NotebookStore(path: .inMemory)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let router = ProviderRouter(store: store, secrets: InMemorySecretStore(),
            selection: DefaultsProviderSelection(defaults: defaults), session: StubURLProtocol.session())
        for c in try SharedFixtures.json("contracts/provider-probe-v1.json")["cases"] as! [[String: Any]] {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: c["type"] as! String)!
            let response = c["response"] as! String
            if response == "transport" { StubURLProtocol.enqueue(.connectionRefused()) }
            else {
                let body: String
                switch response {
                case "validEmpty": body = type == .ollama ? "{\"models\":[]}" : "{\"data\":[]}"
                case "validOne": body = type == .ollama ? "{\"models\":[{\"name\":\"m:tag\",\"modified_at\":\"\",\"size\":0,\"digest\":\"d\",\"details\":{}}]}" : "{\"data\":[{\"id\":\"m:tag\"}]}"
                case "malformed": body = "{}"
                default: body = "{\"error\":\"denied\"}"
                }
                StubURLProtocol.enqueue(.json(Data(body.utf8), status: c["statusCode"] as! Int))
            }
            let result = try await router.probe(type: type, baseURL: "https://unit.example/root", apiKey: "k")
            XCTAssertEqual(result.status.rawValue, c["expectedStatus"] as? String, c["name"] as! String)
            XCTAssertEqual(result.errorCode, c["errorCode"] as? String)
            XCTAssertFalse(result.generationVerified)
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
            XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        }
        StubURLProtocol.reset()
    }
    func testCapturedAdapterKeepsRootKeyModelAndOptions() async throws {
        let c = (try SharedFixtures.json("contracts/provider-routing-v1.json")["cases"] as! [[String: Any]])
            .first { $0["operation"] as? String == "snapshot" }!
        let store = try NotebookStore(path: .inMemory)
        let secrets = InMemorySecretStore()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("p", forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set(c["oldModel"] as! String, forKey: ProviderSettingsKeys.chatModel)
        var config = ProviderConfig(id: "p", type: .openaiCompatible, name: "P",
            baseURL: c["oldRoot"] as! String, privacyAcknowledged: true)
        try store.saveProvider(config)
        try secrets.save(providerId: "p", secret: c["oldKey"] as! String)
        try store.saveProviderModelLimits(.init(providerId: "p", model: c["oldModel"] as! String,
            contextWindow: nil, runtimeContext: 4096, maxOutputTokens: 333, source: "user"))
        let router = ProviderRouter(store: store, secrets: secrets,
            selection: DefaultsProviderSelection(defaults: defaults), session: StubURLProtocol.session())
        let captured = try await router.prepareChat()
        config.baseURL = c["newRoot"] as! String
        try store.saveProvider(config)
        try secrets.save(providerId: "p", secret: c["newKey"] as! String)
        defaults.set(c["newModel"] as! String, forKey: ProviderSettingsKeys.chatModel)
        try store.saveProviderModelLimits(.init(providerId: "p", model: c["newModel"] as! String,
            contextWindow: nil, runtimeContext: 8192, maxOutputTokens: 777, source: "user"))
        StubURLProtocol.reset()
        let next = try await router.prepareChat()
        for session in [captured, captured, next] {
            StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
            for try await _ in session.stream(messages: [.init(role: .user, content: "Q")]) {}
        }
        let requests = StubURLProtocol.allRequests
        XCTAssertEqual(requests.map { $0.url!.absoluteString },
            [c["oldRoot"] as! String, c["oldRoot"] as! String, c["newRoot"] as! String].map { $0 + "/chat/completions" })
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization")! }, ["Bearer key-A", "Bearer key-A", "Bearer key-B"])
        let bodies = try requests.map { try JSONSerialization.jsonObject(with: XCTUnwrap($0.bodyData)) as! [String: Any] }
        XCTAssertEqual(bodies.map { $0["model"] as! String }, ["model:old", "model:old", "model:new"])
        XCTAssertEqual(bodies.map { $0["max_tokens"] as! Int }, [333, 333, 777])
        XCTAssertEqual(captured.storageKey, "p:model:old")
        XCTAssertEqual(captured.limits.runtimeContext, 4096)
        StubURLProtocol.reset()
    }
}
```

- [ ] **Step 2: Run red:** `swift test --filter ProviderSessionTests` → new APIs missing; no fake success fallback may satisfy the matrix.
- [ ] **Step 3: Implement discovery under `Providers/ProviderDiscovery.swift`.** Strictly decode required `data` / `models` arrays. A valid empty array is success; missing/wrong-kind array or missing string model IDs is decoding failure. Metadata discovery must propagate 401/403, other HTTP errors, network errors and cancellation. Map models-endpoint 404/405/501 only to `ProviderListingUnsupported`. `probe` returns verified only after a successful GET and decode; unsupported is neutral with `generationVerified=false`; auth/transport/http/decoding/invalid-root becomes failed with sanitized detail. Cancellation throws. Do not substitute static model suggestions for an actual supported check. No stream, embeddings, `/show`, or extra probe request is needed to mark a successful listing check.

`prepareChat` captures selection, config value, secret, persisted limits and model in one MainActor turn before its first network suspension; unresolved metadata is fetched using only those captured inputs. A recognized provider-qualified model overrides selection; an unqualified model override uses the current provider and preserves tags like `llama3.2:3b`. Null override uses the selected model. Missing recognized IDs/disabled configs fail. Validate root, then consent, then create the adapter. Resolve missing auto limits against this **captured** config/key: Ollama calls `/api/show`; known table otherwise; unknown defaults are marked assumed. Do not re-fetch config or secret after `/show` returns. `/show` unsupported statuses allow assumed defaults; auth/transport/decoding errors remain visible. User overrides skip automatic metadata calls and always win persistence races. Refresh caches only auto values and re-reads the saved row to return a concurrent user override.

`ProviderChatSession.stream` is simply `capturedAdapter.stream(model: model, messages: messages, options: limits.options)`. The session's public properties exclude base URL/credentials/fingerprint; it is not Codable. The router's existing direct no-options `stream` preserves its legacy behavior: recognized provider-qualified keys override selection, otherwise ignore its stale launch-model argument and call `prepareChat(model:nil)`. The explicit options overload must be implemented (not inherited): capture the same target and apply the supplied options after validating them against the known ceiling, without persisting an override. Internally a `withOptions(_ options: ChatRequestOptions) throws -> ProviderChatSession` copy can do this. Each direct invocation captures a new session; ChatEngine will reuse a session per turn in Task 8. Direct `embed` resolves the requested composite ID/model, validates/consent-checks before dispatch, and throws `unsupportedEndpoint` for chat-only providers instead of redirecting to Ollama. No Swift adapter cache is added.

- [ ] **Step 4: Add routing fixture tests** for missing/disabled provider, raw tags, unsupported embedding, and every privacy row. For `backgroundEmbed`, create a notebook/source/pending chunk as in `EmbedderTests.swift:17`, construct `Embedder(store:client:model:)` with router and composite key, then `EmbeddingWorker(embedder:)`; `await kick()` and `await waitUntilIdle()`. Assert `lastError` represents consentRequired, `StubURLProtocol.allRequests.isEmpty`, and no vector was stored. This must exercise the worker, not only a direct embed call. Seed saved auto/user limits in older unrelated Ollama router tests so their one queued chat response remains a chat response; new explicit metadata tests assert the additional show request. Add consent-after-cache/session test: a previously authorized turn keeps its authorized snapshot, while a **new** turn after DB consent removal fails before HTTP. A captured snapshot never acquires consent it did not have.
- [ ] **Step 5: Test custom Ollama root** against every path in the shared routing case, including `resolveLimits(refresh:true)` for `/api/show`; test unknown metadata assumption, user override skipping show, and auto refresh never overwriting a user row. Replace `ProviderRouterTests.swift:66` missing-provider fallback expectation with missingProvider and zero requests. Preserve the legacy direct-stream selected-model test at line 56. Update the old embedding-fallback test (`ProviderRouterTests.swift:101`) to expect unsupportedEndpoint and zero requests. Keep old UI discovery wrappers only until Task 10; their compatibility tests are explicitly removed/replaced there.
- [ ] **Step 6: Run green:** `swift test --filter 'ProviderSessionTests|ProviderRouterTests'`, then `swift test` → 55 probe rows and all routing rows covered; no live requests.
- [ ] **Step 7: Commit:**

```bash
git add Sources/AINotebookCore/Providers/ProviderSession.swift Sources/AINotebookCore/Providers/ProviderDiscovery.swift Sources/AINotebookCore/Providers/ProviderRouter.swift Tests/AINotebookCoreTests/ProviderSessionTests.swift Tests/AINotebookCoreTests/ProviderRouterTests.swift
git commit -m "feat(providers): capture Swift sessions and report discovery honestly" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 7: [Windows] Move testable routing, discovery, and key-aware cache into Core

**Depends on:** Tasks 3/5. **Parallel with:** Tasks 2, 4, 6, 8, 10. **Files:** Create `W/Providers/{ProviderRouter,ProviderSession,ProviderDiscovery}.cs`, `WT/Providers/ProviderSessionTests.cs`. Modify `W/Providers/AnthropicChatAdapter.cs` (remove list swallowing), `WT/Providers/AnthropicSseTests.cs` (discovery error cases). Task 3 must already be merged because it owns these two files earlier. App router remains read-only until Task 11.

**Grounding:** `windows/src/AINotebook.App/Services/ProviderRouter.cs:45` is the current routing implementation; cache keys at 214/238 use key length, chat/embed/discovery at 224/247/253 share the wrong Ollama instance; lines 210/234 hold current privacy gates. `AnthropicChatAdapter.cs:123` swallows model-list errors. `W/Rag/Embedder.cs:35` pins the composite model key for background storage.

**Interfaces:** Produces `AINotebook.Core.Providers.Routing.ProviderRouter` (nested namespace avoids an ambiguous name in existing App imports), its constructor and methods in Shared interfaces, `ProviderChatSession`, `IChatSessionPreparing`, `ProviderProbeResult`, and `public sealed class ProviderListingUnsupportedException : Exception`. Consumes store APIs, transport adapters, delegates for selection/key, and shared fixtures. Swift counterparts are Task 6's public APIs. App interfaces/settings/key vault do not move into Core.

- [ ] **Step 1: Add the probe fixture test below.**

```csharp
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

using ProviderRouter = AINotebook.Core.Providers.Routing.ProviderRouter;

namespace AINotebook.Core.Tests.Providers;

public class ProviderSessionTests
{
    [Fact]
    public async Task ProbeFixture()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        foreach (var c in SharedFixtures.Json("contracts/provider-probe-v1.json").GetProperty("cases").EnumerateArray())
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var response = c.GetProperty("response").GetString();
            var stub = new StubHttpMessageHandler();
            if (response == "transport") stub.ConnectionRefused();
            else
            {
                var body = response switch
                {
                    "validEmpty" => type == ProviderType.Ollama ? "{\"models\":[]}" : "{\"data\":[]}",
                    "validOne" => type == ProviderType.Ollama ? "{\"models\":[{\"name\":\"m:tag\",\"modified_at\":\"\",\"size\":0,\"digest\":\"d\",\"details\":{}}]}" : "{\"data\":[{\"id\":\"m:tag\"}]}",
                    "malformed" => "{}",
                    _ => "{\"error\":\"denied\"}"
                };
                stub.Json(body, c.GetProperty("statusCode").GetInt32());
            }
            using var http = new HttpClient(stub);
            var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "m"), _ => "k", http);
            var result = await router.ProbeAsync(type, "https://unit.example/root", "k");
            Assert.Equal(Enum.Parse<ProviderProbeStatus>(c.GetProperty("expectedStatus").GetString()!, true), result.Status);
            Assert.Equal(c.GetProperty("errorCode").ValueKind == JsonValueKind.Null ? null : c.GetProperty("errorCode").GetString(), result.ErrorCode);
            Assert.False(result.GenerationVerified);
            Assert.Single(stub.AllRequests);
            Assert.Equal(HttpMethod.Get, stub.LastRequest!.Method);
        }
    }
    [Fact]
    public async Task EqualLengthKeyRotationDoesNotReuseAnOldAdapter()
    {
        var c = SharedFixtures.Json("contracts/provider-routing-v1.json").GetProperty("cases").EnumerateArray()
            .Single(x => x.GetProperty("operation").GetString() == "snapshot");
        using var store = new NotebookStore(StorePath.InMemory);
        var config = new ProviderConfig("p", ProviderType.OpenAICompatible, "P", c.GetProperty("oldRoot").GetString()!, true, true, DateTime.UtcNow);
        store.SaveProvider(config);
        var key = c.GetProperty("oldKey").GetString()!;
        var model = c.GetProperty("oldModel").GetString()!;
        store.SaveProviderModelLimits(new("p", model, null, 4096, 333, "user"));
        var stub = new StubHttpMessageHandler().Json("data: [DONE]\n").Json("data: [DONE]\n");
        using var http = new HttpClient(stub);
        var router = new ProviderRouter(store, () => ("p", model), () => ("p", model), _ => key, http);
        var first = await router.PrepareChatAsync();
        key = c.GetProperty("newKey").GetString()!; // Same length; all other cache inputs unchanged.
        var second = await router.PrepareChatAsync();
        await foreach (var _ in first.StreamAsync([new(ChatRole.User, "Q")])) { }
        await foreach (var _ in second.StreamAsync([new(ChatRole.User, "Q")])) { }
        Assert.Equal(new[] { "key-A", "key-B" }, stub.AllRequests.Select(r => r.Headers.Authorization!.Parameter));
    }
}
```

- [ ] **Step 2: Run red:** `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ProviderSessionTests` → Core router/session missing; equal-length rotation must remain a separate test that changes **only** the key.
- [ ] **Step 3: Implement Core routing with injected dependencies.** Copy behavior deliberately from App, retaining provider-qualified embedding keys and removing implicit fallback. No App namespace reference is allowed. Normalize root once, capture config/selection/key and any saved limits before the first await; resolve missing metadata through a private helper taking those captured values, then freeze final limits in the returned session, validate enabled/existence/consent before adapter lookup. `PrepareChatAsync` returns a private-adapter session; its stream uses stored model/options. Direct no-options StreamAsync preserves the App router convention: a recognized provider-qualified key overrides selection, otherwise use the selected model (the old launch argument is stale). Explicit PrepareChatAsync handles intentional raw overrides. Implement the options StreamAsync overload explicitly: capture target then use internal `ProviderChatSession WithOptions(ChatRequestOptions options)` to validate/apply supplied limits without persistence; never inherit a default that discards options. Capture no mutable settings references in the returned session.

Use a synchronized dictionary keyed by `(providerId, type, normalizedRoot, keyFingerprint)` for adapters. Fingerprint is lowercase hexadecimal SHA-256 of UTF-8 key, with an explicit absent-key sentinel; do not use length, string.GetHashCode or log the digest. Replacing an entry must not mutate/dispose an adapter still used by an in-flight session; it retains the injected HttpClient. Lock only dictionary operations, never network. Same-length replacement, changed root, changed type and key removal each select a new adapter. Limits/model are session values, so changing them never mutates a cached adapter.

Remove Anthropic ListModels catch-all; require a valid `data` array. Ollama discovery must call a client constructed with captured config root and let failures propagate. `ProviderDiscovery` maps 404/405/501 to unsupported, 401/403 to auth, other non-2xx to http, bad successful schemas to decoding, network failures/timeouts to transport; caller cancellation rethrows. Probe reports exactly one successful supported GET check as verified and always `GenerationVerified=false`. Use sanitized local messages/status codes; never echo headers or request secrets. No fallback static list can make a probe successful.

`ResolveLimitsAsync` preserves saved user records, optionally refreshes auto rows, uses only captured config/key for `/api/show`, treats supported metadata as a ceiling, and returns the stored row after conditional auto upsert. Show 404/405/501 permits assumed defaults; other failures propagate. Unsupported embedding types throw only after the existing privacy check, without local fallback.

- [ ] **Step 4: Add fixture-driven tests for all remaining routing rows.** Capture a session, change endpoint/model/key/options, stream twice with the old session and once with the new one; compare URLs, authorization, raw model, runtime metadata and output payload with the shared snapshot case. Test key deletion, missing/disabled config, custom Ollama chat/embed/tags/show roots, and raw `m:tag` IDs. Tests for every privacy row assert no handler invocation; `backgroundEmbed` uses `Embedder.EmbedAllPendingAsync` with pending chunks and checks no stored vectors. Keep no store lock across that await. Add user-auto race test and show metadata/assumption cases. Add direct Anthropic list 401/403/500/malformed/transport tests to ensure the adapter itself no longer swallows errors.
- [ ] **Step 5: Run green:** `dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~ProviderSessionTests|FullyQualifiedName~AnthropicSseTests"`, then `dotnet test windows/tests/AINotebook.Core.Tests` → all green. App still compiles against its original constructor/API until Task 11 swaps to the new Core implementation.
- [ ] **Step 6: Commit:**

```bash
git add windows/src/AINotebook.Core/Providers/ProviderRouter.cs windows/src/AINotebook.Core/Providers/ProviderSession.cs windows/src/AINotebook.Core/Providers/ProviderDiscovery.cs windows/src/AINotebook.Core/Providers/AnthropicChatAdapter.cs windows/tests/AINotebook.Core.Tests/Providers/ProviderSessionTests.cs windows/tests/AINotebook.Core.Tests/Providers/AnthropicSseTests.cs
git commit -m "feat(win-core): move provider routing and immutable sessions into Core" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 8: [Swift] Pin one provider session across retrieval and retries

**Depends on:** Task 6 (and Task 2's protocol edit). **Parallel with:** Tasks 3, 5, 7, 9, 11. **Files:** Modify `S/ChatEngine.swift`; create `ST/ChatEngineProviderSnapshotTests.swift`. Read-only `ST/ChatEngineRetryTests.swift:53`, `S/Retriever.swift`, `S/Providers/ProviderSession.swift`.

**Grounding:** `ChatEngine.swift:59` persists the question before generation, line 135 enters retrieval, line 180 re-enters the router for each retry, line 242 persists the supplied model rather than the resolved one. A router-only capture per stream call does not fix this.

**Interfaces:** Consumes Swift `ChatSessionPreparing.prepareChat(model: String?) async throws -> ProviderChatSession` and `ProviderChatSession.stream(messages:)`; C# twin consumes `IChatSessionPreparing.PrepareChatAsync(string?, CancellationToken)` and session `StreamAsync`. Produces unchanged public `ChatEngine.send` / `regenerate` signatures and new internal pipeline parameters `prepared: ProviderChatSession?`, `fallbackModel: String`. WP8 can later use `prepared.limits`, `providerId`, `model` without credentials.

- [ ] **Step 1: Add this deterministic regression.** The embedding callback changes settings **before the first chat HTTP request**, so the test proves capture precedes retrieval, not merely the retry loop.

```swift
import Foundation
import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineProviderSnapshotTests: XCTestCase {
    final class ChangingEmbedder: EmbeddingProducing, Sendable {
        let change: @MainActor @Sendable () throws -> Void
        init(change: @escaping @MainActor @Sendable () throws -> Void) { self.change = change }
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            try await change()
            return inputs.map { _ in [1, 0] }
        }
    }
    func testCaptureBeforeRetrievalAndReuseOnRetry() async throws {
        let c = (try SharedFixtures.json("contracts/provider-routing-v1.json")["cases"] as! [[String: Any]])
            .first { $0["operation"] as? String == "snapshot" }!
        let oldRoot = c["oldRoot"] as! String, newRoot = c["newRoot"] as! String
        let oldModel = c["oldModel"] as! String, newModel = c["newModel"] as! String
        let oldKey = c["oldKey"] as! String, newKey = c["newKey"] as! String
        let store = try NotebookStore(path: .inMemory)
        let notebook = try store.createNotebook(name: "N")
        let session = try store.createChatSession(notebookId: notebook.id!, title: "T")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("p", forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set(oldModel, forKey: ProviderSettingsKeys.chatModel)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: "p", secret: oldKey)
        try store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P", baseURL: oldRoot, privacyAcknowledged: true))
        try store.saveProviderModelLimits(.init(providerId: "p", model: oldModel, contextWindow: nil,
            runtimeContext: 4096, maxOutputTokens: 333, source: "user"))
        let router = ProviderRouter(store: store, secrets: secrets,
            selection: DefaultsProviderSelection(defaults: defaults), session: StubURLProtocol.session())
        let retriever = Retriever(store: store, client: ChangingEmbedder {
            try store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P", baseURL: newRoot, privacyAcknowledged: true))
            try secrets.save(providerId: "p", secret: newKey)
            defaults.set(newModel, forKey: ProviderSettingsKeys.chatModel)
            try store.saveProviderModelLimits(.init(providerId: "p", model: newModel, contextWindow: nil,
                runtimeContext: 8192, maxOutputTokens: 777, source: "user"))
        }, model: "embedding")
        let engine = ChatEngine(store: store, retriever: retriever, chat: router, chatModel: "stale-launch-model",
            retryAttempts: 1, retryBackoffMillis: 1)
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json(Data(), status: 429))
        StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
        StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
        let first = try await engine.send(sessionId: session.id!, notebookId: notebook.id!, userText: "Q", onToken: { _ in })
        let second = try await engine.send(sessionId: session.id!, notebookId: notebook.id!, userText: "Q2", onToken: { _ in })
        XCTAssertEqual(first.model, "p:" + oldModel)
        XCTAssertEqual(second.model, "p:" + newModel)
        let requests = StubURLProtocol.allRequests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [oldRoot, oldRoot, newRoot].map { $0 + "/chat/completions" })
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization")! }, ["Bearer " + oldKey, "Bearer " + oldKey, "Bearer " + newKey])
        let bodies = try requests.map { try JSONSerialization.jsonObject(with: XCTUnwrap($0.bodyData)) as! [String: Any] }
        XCTAssertEqual(bodies.map { $0["max_tokens"] as! Int }, [333, 333, 777])
        StubURLProtocol.reset()
    }
}
```

- [ ] **Step 2: Run red:** `swift test --filter ChatEngineProviderSnapshotTests` → current engine sends the new endpoint/key and records stale-launch-model; it must not pass by moving the mutation after HTTP.
- [ ] **Step 3: Implement capture at the public turn boundary.** At the start of `send` and `regenerate`, before persistence/history/retrieval awaits, capture `let prepared = try await (chat as? any ChatSessionPreparing)?.prepareChat(model: model)`. For non-router test doubles only, `fallbackModel = model ?? chatModel`. Pass both values to `generateAnswer`. Within the retry loop:

```swift
let stream = prepared?.stream(messages: turns)
    ?? chat.stream(model: fallbackModel, messages: turns, options: .defaults)
for try await token in stream {
    partial += token
    onToken(token)
}
```

Persist `prepared?.storageKey ?? fallbackModel`. Configuration/invalid-limit errors are raised while preparing and never enter retry. Catch `ProviderRequestError.contextTooLong` as terminal in the loop. Respect cancellation immediately (`Task.checkCancellation` before a retry and do not swallow cancellation from sleep). Keep existing auth/refusal/consent non-retry behavior, server Retry-After behavior, and onRetry clearing. Do not change retrieval scope, citations, or prompt assembly in WP2.
- [ ] **Step 4: Add tests for explicit raw model override, qualified provider override, regenerate, and failed preparation making zero retrieval/chat calls.** Reuse the routing fixture's raw colon model names; assert default new turns follow live selection, explicit override survives capture, and existing non-router tests retain engine-default behavior. Verify a caller-cancelled retry never starts another request.
- [ ] **Step 5: Run green:** `swift test --filter 'ChatEngineProviderSnapshotTests|ChatEngineRetryTests|EpicC3RegenerateTests'`, then `swift test` → all pass.
- [ ] **Step 6: Commit:**

```bash
git add Sources/AINotebookCore/ChatEngine.swift Tests/AINotebookCoreTests/ChatEngineProviderSnapshotTests.swift
git commit -m "fix(chat): pin Swift provider configuration through retrieval and retries" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 9: [Windows] Reuse the captured Core provider session for an entire turn

**Depends on:** Task 7. **Parallel with:** Tasks 2, 4, 6, 8, 10. **Files:** Modify `W/Rag/ChatEngine.cs`; create `WT/Rag/ChatEngineProviderSnapshotTests.cs`. Read-only `WT/Rag/ChatEngineModelAndRetryTests.cs:25`, `WT/Helpers/MockEmbeddingClient.cs`, `W/Rag/Retriever.cs`.

**Grounding:** `ChatEngine.cs:43` captures only model; retry dispatch at 87 re-samples App/Core routing; line 134 persists the potentially wrong model. Existing model override tests must continue to pass for non-router clients.

**Interfaces:** Consumes `IChatSessionPreparing.PrepareChatAsync(string? model = null, CancellationToken ct = default)` and `ProviderChatSession.StreamAsync(IReadOnlyList<ChatTurn>, CancellationToken)`; Swift counterpart is Task 8's `prepareChat`/`stream`. Public `SendAsync` arguments stay unchanged. Its method body holds a nullable prepared session and fallback model for the whole retry loop.

- [ ] **Step 1: Add the real-engine regression using a synchronous change callback in the existing MockEmbeddingClient.**

```csharp
using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

using ProviderRouter = AINotebook.Core.Providers.Routing.ProviderRouter;

namespace AINotebook.Core.Tests.Rag;

public class ChatEngineProviderSnapshotTests
{
    [Fact]
    public async Task CapturePrecedesRetrievalAndSurvivesRetry()
    {
        var c = SharedFixtures.Json("contracts/provider-routing-v1.json").GetProperty("cases").EnumerateArray()
            .Single(x => x.GetProperty("operation").GetString() == "snapshot");
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var session = store.CreateChatSession(nb.Id!.Value, "T");
        var root = c.GetProperty("oldRoot").GetString()!;
        var model = c.GetProperty("oldModel").GetString()!;
        var key = c.GetProperty("oldKey").GetString()!;
        store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", root, true, true, DateTime.UtcNow));
        store.SaveProviderModelLimits(new("p", model, null, 4096, 333, "user"));
        var stub = new StubHttpMessageHandler().Json("{}", 429).Json("data: [DONE]\n").Json("data: [DONE]\n");
        using var http = new HttpClient(stub);
        var router = new ProviderRouter(store, () => ("p", model), () => ("p", "embed"), _ => key, http);
        var embedding = new MockEmbeddingClient(_ =>
        {
            root = c.GetProperty("newRoot").GetString()!;
            model = c.GetProperty("newModel").GetString()!;
            key = c.GetProperty("newKey").GetString()!;
            store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", root, true, true, DateTime.UtcNow));
            store.SaveProviderModelLimits(new("p", model, null, 8192, 777, "user"));
            return [1f, 0f];
        });
        var engine = new ChatEngine(store, new Retriever(store, embedding, "embed"), router,
            "stale-launch-model", retryAttempts: 1, retryBackoffMillis: 1);
        var first = await engine.SendAsync(session.Id!.Value, nb.Id.Value, "Q", onToken: _ => { });
        var second = await engine.SendAsync(session.Id.Value, nb.Id.Value, "Q2", onToken: _ => { });
        Assert.Equal("p:model:old", first.Model);
        Assert.Equal("p:model:new", second.Model);
        Assert.Equal(new[] { c.GetProperty("oldRoot").GetString(), c.GetProperty("oldRoot").GetString(), c.GetProperty("newRoot").GetString() }
            .Select(x => x + "/chat/completions"), stub.AllRequests.Select(r => r.RequestUri!.AbsoluteUri));
        Assert.Equal(new[] { "key-A", "key-A", "key-B" }, stub.AllRequests.Select(r => r.Headers.Authorization!.Parameter));
    }
}
```

Extend the local test handler for this class (not the shared helper) to capture `(Uri, Authorization, Body)` strings **inside SendAsync**, because disposed HttpRequestMessage.Content cannot safely be read later. Use a `List<(string Url, string? Key, string Body)>` protected by a local gate. Return first a 429 and then two SSE `[DONE]` bodies. Assert fixture outputs 333,333,777 and model:old,model:old,model:new from those captured bodies as well as the root/key assertions above.

- [ ] **Step 2: Run red:** `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~ChatEngineProviderSnapshotTests` → wrong first endpoint/model metadata with today's engine.
- [ ] **Step 3: Implement at SendAsync entry, before persistence/history/retrieval:**

```csharp
ProviderChatSession? prepared = _chat is IChatSessionPreparing preparing
    ? await preparing.PrepareChatAsync(model, ct) : null;
var fallbackModel = model ?? ChatModel;
// Pass prepared/fallbackModel through the private generation method.
// Inside each retry attempt:
var tokens = prepared is not null
    ? prepared.StreamAsync(turns, ct)
    : _chat.StreamAsync(fallbackModel, turns, ChatRequestOptions.Defaults, ct);
await foreach (var token in tokens.WithCancellation(ct))
{
    partial += token;
    onToken?.Invoke(token);
}
// Assistant model metadata:
var storedModel = prepared?.StorageKey ?? fallbackModel;
```

Keep capture outside retry; treat `ProviderContextTooLongException` as terminal; propagate cancellation; do not alter context assembly/retrieval/citations. A later Task 11 App bridge must implement `IChatSessionPreparing`, otherwise this check would silently use the legacy path. Core currently exposes only `SendAsync`; App regeneration already calls it. No new Core regeneration API is introduced.

- [ ] **Step 4: Add explicit override, cancellation and preparation-failure tests.** Configuration/privacy failures must make zero retrieval and HTTP calls. Keep existing `ChatEngineModelAndRetryTests` unchanged; they exercise the fallback for mock clients. Test both qualified provider model and unqualified Ollama tag.
- [ ] **Step 5: Run green:** `dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~ChatEngineProviderSnapshotTests|FullyQualifiedName~ChatEngineModelAndRetryTests|FullyQualifiedName~ChatEngineTests"`, then `dotnet test windows/tests/AINotebook.Core.Tests` → all green.
- [ ] **Step 6: Commit:**

```bash
git add windows/src/AINotebook.Core/Rag/ChatEngine.cs windows/tests/AINotebook.Core.Tests/Rag/ChatEngineProviderSnapshotTests.cs
git commit -m "fix(win-chat): pin provider sessions across retrieval and retries" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### UI text contract (Tasks 10 and 11)

Swift has **one** localization source containing both English and Czech switches, `Sources/AINotebookCore/Localization.swift:114,377,615`; there are no separate Swift `.strings` files to invent. Windows uses `Services/StringKey.cs`, `Strings/en-US/Resources.resw`, `Strings/cs-CZ/Resources.resw`; `LocalizedStrings.cs:58` maps PascalCase enum names to camelCase resource keys. Both tasks add exactly these keys and translations. Provider brand names are not translated; Custom is.

| Key (Swift / Windows resw) | English | Czech |
|---|---|---|
| `providerPresetLabel` | Preset | Předvolba |
| `providerPresetCustom` | Custom | Vlastní |
| `providerPresetLocalHelp` | Start the local server, then check its API root. An API key is optional. | Spusťte místní server a ověřte kořen API. Klíč API je volitelný. |
| `providerPresetRemoteHelp` | Enter your API key and check the API root. | Zadejte klíč API a ověřte kořen API. |
| `providerPresetCustomHelp` | Enter the exact API root, including any version or proxy path. | Zadejte přesný kořen API včetně verze a cesty proxy. |
| `providerRefreshModels` | Refresh models | Obnovit modely |
| `providerManualModelId` | Model ID | ID modelu |
| `providerApplyModel` | Apply model ID | Použít ID modelu |
| `providerListingVerified` | Model listing verified. Generation has not been tested. | Seznam modelů byl ověřen. Generování nebylo testováno. |
| `providerListingUnsupported` | Model listing is unavailable; generation has not been verified. Enter a model ID manually. | Seznam modelů není dostupný; generování nebylo ověřeno. Zadejte ID modelu ručně. |
| `providerRuntimeContext` | Runtime context | Použitý kontext |
| `providerMaxOutputTokens` | Maximum output tokens | Maximum tokenů odpovědi |
| `providerContextWindow` | Model context limit | Limit kontextu modelu |
| `providerContextUnknown` | Unknown | Neznámý |
| `providerLimitsAssumption` | Application assumption | Předpoklad aplikace |
| `providerLimitsUserOverride` | User override | Uživatelské nastavení |
| `providerLimitsSave` | Save limits | Uložit limity |
| `providerLimitsReset` | Reset to automatic | Obnovit automatické nastavení |
| `providerLimitsInvalid` | Enter positive whole numbers. Output must be smaller than runtime context, which must not exceed the known model limit. | Zadejte kladná celá čísla. Maximum odpovědi musí být menší než použitý kontext, který nesmí překročit známý limit modelu. |
| `providerInvalidRoot` | Enter an HTTP or HTTPS API root without credentials, a query, or a fragment. | Zadejte kořen API HTTP nebo HTTPS bez přihlašovacích údajů, dotazu a fragmentu. |
| `providerContextTooLong` | The provider rejected the request length. Reduce runtime context. | Poskytovatel odmítl délku požadavku. Snižte použitý kontext. |

The known model ceiling is read-only. Runtime/output are editable integer drafts; save uses source=user. Reset explicitly deletes the override and resolves auto again. Unknown ceilings display Unknown; auto unknown runtime additionally displays Application assumption. Do not suggest that verified listing proves generation or embeddings work.

### Task 10: [Swift-UI] Settings presets, discovery, manual selection and limits

**Depends on:** Tasks 6/8. **Parallel with:** Tasks 3, 5, 7, 9, 11. **Files:** Modify `Sources/AINotebookApp/{SettingsView,AddProviderSheet,ProviderErrorText}.swift`, `S/Localization.swift`, `ST/LocalizationTests.swift`, `S/Providers/ProviderRouter.swift`, `ST/ProviderRouterTests.swift`. Create `ST/ProviderLocalizationTests.swift`. No new ViewModel is needed: these SwiftUI views already own `@State` and consume Core policy.

**Grounding:** `SettingsView.swift:17` stores boolean probe status, lines 160–177 already offer chat manual entry, lines 250–265 bind embedding edits immediately, line 368 fixes a small frame, lines 425–449 swallow errors into model/status state. `AddProviderSheet.swift:43,67,136` has editable type/root/key and binary test result. `ProviderErrorText.swift:5` maps existing provider errors. `LocalizationTests.swift:130` contains provider strings.

**Interfaces:** Consumes Swift `ProviderPresets.all`, `ProviderRouter.discoverModels(providerId:) async throws`, `probe(type:baseURL:apiKey:) async throws -> ProviderProbeResult`, `resolveLimits(providerId:model:refresh:)`, and typed store methods. Windows counterparts are `ProviderPresets.All`, `DiscoverModelsAsync`, `ProbeAsync`, `ResolveLimitsAsync`, `SaveProviderModelLimits`; Task 11 binds them. Produces view state/bindings listed below; no Core business-policy duplicate.

- [ ] **Step 1: Add a localization red test before changing strings.**

```swift
import XCTest
@testable import AINotebookCore

final class ProviderLocalizationTests: XCTestCase {
    func testNewProviderTextInBothLanguages() {
        XCTAssertEqual(AppText(language: .english).string(.providerRefreshModels), "Refresh models")
        XCTAssertEqual(AppText(language: .czech).string(.providerRefreshModels), "Obnovit modely")
        XCTAssertEqual(AppText(language: .english).string(.providerLimitsAssumption), "Application assumption")
        XCTAssertEqual(AppText(language: .czech).string(.providerLimitsAssumption), "Předpoklad aplikace")
        XCTAssertEqual(AppText(language: .english).string(.providerContextUnknown), "Unknown")
        XCTAssertEqual(AppText(language: .czech).string(.providerContextUnknown), "Neznámý")
    }
}
```

The concrete localization API is `AppText(language: AppLanguage).string(_ key: AppText.Key) -> String` (`Localization.swift:251,255`). Add exact assertions for every row in the UI text table; existing `LocalizationTests` also enumerates every key in both languages.

- [ ] **Step 2: Run red:** `swift test --filter ProviderLocalizationTests` → missing AppText.Key cases.
- [ ] **Step 3: Implement localized state and bindings.**

| View | Exact state/binding/action |
|---|---|
| `AddProviderSheet` | `@State selectedPresetId = "custom"`; Picker over `ProviderPresets.all` only when type is `.openaiCompatible`; selection sets `baseURL`, optional initial name, and `presetHelpKey`, clears old probe; Custom leaves root editable. Keep API key optional for compatible/OpenWebUI, explicitly validate a key for new OpenAI/Anthropic configurations; preserve a previously stored key while editing. |
| `AddProviderSheet` | `@State probeResult: ProviderProbeResult?`, `@State isTesting`; Test calls `router.probe`; verified green with listing-specific text, unsupported neutral/orange plus manual-ID guidance, failed red with localized/sanitized reason. Editing type/root/key clears result and invalidates an in-flight response. |
| `SettingsView` | Existing `chatModels`/`embeddingModels` remain `[ProviderModelInfo]`; Picker `.tag(model.id)` displays `.label`. Add explicit Refresh button for each picker. Maintain independent loading/error/probe states. Refresh replaces only the options list, never selected provider/model or a manual draft. |
| `SettingsView` | `@State chatModelDraft`, `embeddingModelDraft`; always-visible model-ID TextFields with Apply buttons. Trim only outer whitespace; preserve case, colons, slash names. Empty draft disables Apply. Apply embedding ID invokes the existing re-embed confirmation once, not per keystroke. Preserve existing privacy picker confirmation. |
| `SettingsView` | `@State limits: ProviderModelLimits?`, `runtimeContextDraft`, `maxOutputTokensDraft`, `limitsError`; load for current **chat provider + raw model**. Display ceiling, assumption/user source; integer inputs and Save/Reset actions. Save validates then calls `saveProviderModelLimits` with source user. Reset deletes this pair and calls `resolveLimits(refresh:true)`. Model/provider changes load a different pair. |

Wrap Settings content in scrolling layout so new controls fit. Use an incrementing request revision plus captured provider/model/root for every async refresh/probe/limits action; discard stale results after edits or selection changes. Disable only the action already running, not manual entry after failed listing. Reset/save failure retains drafts and explains why. The `/show` metadata network stays inside router.

Map `ProviderConfigurationError.invalidBaseURL` and invalidLimits to the UI keys; existing auth/network errors remain red. Map `ProviderRequestError.contextTooLong` to `providerContextTooLong`; preserve other 400 errors as ordinary provider failures. Do not print request body/headers/keys in detail text.

- [ ] **Step 4: Remove the temporary swallowing UI wrappers from Swift ProviderRouter.** All view callers now use typed APIs. Replace `ProviderRouterTests.swift:137–190` assertions that swallowed errors/static models or nil success with the probe fixture and explicit `discoverModels` throws assertions. Retain existing list-order/ID assertions for successful responses. There must be no remaining UI call to `listModels(providerId:)` or `testConnection(type:baseURL:apiKey:)` and no Core fallback static list used as a successful check.
- [ ] **Step 5: Run green:** `swift test --filter 'ProviderLocalizationTests|LocalizationTests|ProviderRouterTests|ProviderSessionTests'`, then `swift test` and `swift build` → green; no network code added to the UI.
- [ ] **Step 6: Claude runs the app and records this manual checklist in the review report:**
  - EN and CS show every preset, help text, Refresh, manual-ID, and limit label without clipping; Custom preserves an edited proxy root.
  - Keyless LM Studio/vLLM can be saved, privacy decline sends no chat/background request, and all five provider types retain their existing acknowledgment behavior.
  - Valid empty listing is green with generation-not-tested wording; 404/405/501 is neutral; 401/403/refused connection/malformed reply is red. Editing root/key while a probe is pending cannot show a stale green result.
  - Failed refresh preserves raw selected/manual ID; label differs from ID without changing what is sent. Colon-containing and slash-containing IDs work. Embedding draft prompts only on Apply.
  - Unknown model shows 8192/1024 plus assumption; known/small Ollama ceiling clamps auto runtime; save 4096/333 persists across restart for this pair only; reset restores auto; refresh retains user override; invalid integers/bounds show validation.
  - During a forced retry, edit provider root/key/limits: this turn keeps old settings and next turn uses new settings. Length rejection gives the reduce-context suggestion.
- [ ] **Step 7: Commit after automated tests; Claude's manual app check is a WP gate requirement.**

```bash
git add Sources/AINotebookApp/SettingsView.swift Sources/AINotebookApp/AddProviderSheet.swift Sources/AINotebookApp/ProviderErrorText.swift Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift Tests/AINotebookCoreTests/ProviderLocalizationTests.swift Sources/AINotebookCore/Providers/ProviderRouter.swift Tests/AINotebookCoreTests/ProviderRouterTests.swift
git commit -m "feat(settings): expose Swift provider presets, checks and model limits" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 11: [Win-UI] Thin App routing and Settings parity

**Depends on:** Tasks 7/9. **Parallel with:** Tasks 2, 4, 6, 8, 10. **Files:** Modify `windows/src/AINotebook.App/Services/{ProviderRouter,StringKey}.cs`, `ViewModels/{SettingsViewModel,AddProviderViewModel}.cs`, `Views/{SettingsDialog.xaml,SettingsDialog.xaml.cs,AddProviderDialog.xaml,AddProviderDialog.xaml.cs}`, `Strings/{en-US,cs-CZ}/Resources.resw`; modify `windows/tests/AINotebook.App.Tests/{ProviderRouterOpenWebUITests,ProviderRouterEmbedCompositeKeyTests,AddProviderViewModelOpenWebUITests,LocalizedStringsTests}.cs`; create `windows/tests/AINotebook.App.Tests/ProviderSettingsTests.cs`. `App.xaml.cs:94`, `Services/{ISettingsService,ISecretStore,LocalizedStrings}.cs` are read-only; preserve the existing DI constructor shape.

**Grounding:** `SettingsViewModel.cs:30` stores strings instead of model records, lines 201/229 substitute display names for IDs. `SettingsDialog.xaml:50` contains model controls; `.xaml.cs:103` hides unavailable lists, lines 167/208 contain privacy flows. `AddProviderViewModel.cs:92` disallows keyless compatible providers; `.xaml.cs:116` only understands binary results. `StringKey.cs:49` and both `.resw:491` are the current provider string sections. Existing App router tests assert null-success at `ProviderRouterOpenWebUITests.cs:25`.

**Interfaces:** Consumes all C# Core provider APIs; Swift counterpart bindings/actions are listed in Task 10. Produces a thin App `ProviderRouter : IChatStreaming, IEmbeddingProducing, IChatSessionPreparing` retaining its current `(ISettingsService, NotebookStore, ISecretStore, OllamaClient, HttpClient)` constructor; exact delegate construction must use `settings.SelectedChatProviderId`, `settings.SelectedChatModel`, `settings.SelectedEmbeddingProviderId`, `settings.SelectedEmbeddingModel`, and `secrets.Load(providerId)` from current interfaces. The legacy injected Ollama parameter remains for constructor compatibility but never decides provider routing. New view-model surfaces:

```csharp
// AddProviderViewModel:
public IReadOnlyList<ProviderPreset> Presets { get; }
public string SelectedPresetId { get; set; }
public string PresetHelp { get; }
public ProviderProbeResult? ProbeResult { get; }
// SettingsViewModel:
public ObservableCollection<ProviderModelInfo> ChatModels { get; }
public ObservableCollection<ProviderModelInfo> EmbeddingModels { get; }
public string ChatModelDraft { get; set; }
public string EmbeddingModelDraft { get; set; }
public string RuntimeContextDraft { get; set; }
public string MaxOutputTokensDraft { get; set; }
public ProviderModelLimits? Limits { get; }
public string? LimitsError { get; }
public Task RefreshChatModelsAsync();
public Task RefreshEmbeddingModelsAsync();
public Task LoadLimitsAsync();
public Task SaveLimitsAsync();
public Task ResetLimitsAsync();
```

Keep existing provider/model selection properties and notifications; the new async methods wrap Core calls and surface errors, not HTTP implementations.

- [ ] **Step 1: Write failing App tests before XAML/view-model edits.** Add exact English/Czech expectations for every UI text row to `LocalizedStringsTests`; update its fixed key-count assertion from 239 to 260 (21 new keys), retaining exact EN/CS set equality and non-empty checks. Add a theory over all seven `provider-presets-v1` cases in `ProviderSettingsTests`. The App test project currently has no Core-test reference or fixture link (`AINotebook.App.Tests.csproj:17`); add this exact item and read with `JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "SharedFixtures", "contracts", "provider-presets-v1.json")))`:

```xml
<ItemGroup>
  <None Include="../../../Tests/fixtures/**/*"
        CopyToOutputDirectory="PreserveNewest"
        Link="SharedFixtures/%(RecursiveDir)%(Filename)%(Extension)" />
</ItemGroup>
```

Keep the fixture at repo root; do not reference the Core test assembly.

In the existing `AddProviderViewModelOpenWebUITests` class, whose private `MakeVm()` and fake interfaces already exist at lines 133–162, add this executable fixture test:

```csharp
[Fact]
public void CompatiblePresetsKeepExactRootsAndAllowKeylessLocalServers()
{
    using var fixture = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(
        Path.Combine(AppContext.BaseDirectory, "SharedFixtures", "contracts", "provider-presets-v1.json")));
    foreach (var c in fixture.RootElement.GetProperty("cases").EnumerateArray())
    {
        var vm = MakeVm();
        vm.SelectedType = ProviderType.OpenAICompatible;
        vm.Name = "P";
        vm.SelectedPresetId = c.GetProperty("name").GetString()!;
        Assert.Equal(c.GetProperty("baseURL").GetString(), vm.BaseUrl);
        vm.ApiKey = "";
        if (vm.SelectedPresetId is "lmstudio" or "vllm") Assert.True(vm.CanSave);
        Assert.Null(vm.ProbeResult);
    }
}
```

In `LocalizedStringsTests`, add a real exact-text test (and extend its tuple array with every row from the text table):

```csharp
[Fact]
public void ProviderLimitLabelsAreLocalized()
{
    foreach (var row in new[] {
        ("providerRefreshModels", "Refresh models", "Obnovit modely"),
        ("providerLimitsAssumption", "Application assumption", "Předpoklad aplikace"),
        ("providerContextUnknown", "Unknown", "Neznámý") })
    {
        var en = XDocument.Load("en.resw").Root!.Elements("data")
            .Single(x => (string?)x.Attribute("name") == row.Item1).Element("value")!.Value;
        var cs = XDocument.Load("cs.resw").Root!.Elements("data")
            .Single(x => (string?)x.Attribute("name") == row.Item1).Element("value")!.Value;
        Assert.Equal(row.Item2, en);
        Assert.Equal(row.Item3, cs);
    }
}
```

The concrete view-model tests assert: set type compatible + preset, root/help match fixture; blank compatible key still permits Save; OpenAI/Anthropic blank key does not; selecting `{Id:"vendor/m:tag", DisplayName:"Friendly"}` persists `vendor/m:tag`; failed refresh preserves that ID and a manual draft; applying a blank ID changes nothing; save 4096/333 produces source user; reset produces auto; unsupported probe is never success. Stub the existing router HTTP constructor and secret/settings interfaces; do not call a live service.

Include this direct bridge test in the existing App router test class, using its current in-memory store/settings/secret setup:

```csharp
Assert.IsAssignableFrom<AINotebook.Core.Providers.IChatSessionPreparing>(router);
var prepared = await ((AINotebook.Core.Providers.IChatSessionPreparing)router).PrepareChatAsync();
Assert.Equal(settings.SelectedChatProviderId, prepared.ProviderId);
Assert.Equal(settings.SelectedChatModel, prepared.Model);
```

This catches an App wrapper that forwards StreamAsync but accidentally drops session capture and thereby defeats Task 9.

- [ ] **Step 2: Run red on Windows:** `dotnet test windows/tests/AINotebook.App.Tests -c Release -p:Platform=x64 --filter "FullyQualifiedName~ProviderSettingsTests|FullyQualifiedName~LocalizedStringsTests|FullyQualifiedName~ProviderRouter"` → missing state/strings/capture interface or changed expected behavior. On macOS, record that WinUI build/test execution is deferred to Windows CI; do not fake a green App result.
- [ ] **Step 3: Replace App routing with forwarding only.** The constructor creates one `AINotebook.Core.Providers.Routing.ProviderRouter` with delegates over the current settings and key store. Forward old/no-options and new/options stream, embed, PrepareChatAsync, DiscoverModelsAsync, ProbeAsync, ResolveLimitsAsync. Remove App dictionaries, endpoint selection, HTTP logic, discovery catch-all, and key fingerprints. Do not copy cache behavior into App. Keep the constructor signature so `App.xaml.cs` requires no mutation. Update newly saved OpenAI config roots in `ProviderRouterEmbedCompositeKeyTests.cs:55,113` to exact `/v1` while preserving expected endpoint assertions. Existing App router behavioral tests stay as integration tests but change their assertions to typed probe status and unsupported embedding rejection; Core fixtures already cover the logic.
- [ ] **Step 4: Bind the named controls/actions.**

| File | Exact controls and binding |
|---|---|
| `AddProviderDialog.xaml` | Add `PresetComboBox` (`ItemsSource=ViewModel.Presets`, `DisplayMemberPath=Name`, `SelectedValuePath=Id`, two-way SelectedValue `SelectedPresetId`) and `PresetHelpText`; show only for compatible type. Existing BaseUrl/ApiKey inputs stay editable. |
| `AddProviderDialog.xaml.cs` | On preset/root/key/type change invalidate probe revision. Map verified→InfoBar Success, unsupported→Informational/Warning, failed→Error. Apply listing-specific wording and generation-not-verified text. Preserve the existing privacy dialog. |
| `SettingsDialog.xaml` | Model ComboBoxes use `DisplayMemberPath="Label"`, `SelectedValuePath="Id"`; keep them visible with an empty list. Add `RefreshChatModelsButton`, `RefreshEmbeddingModelsButton`, `ChatModelIdTextBox`, `EmbeddingModelIdTextBox`, and `ApplyChatModelIdButton` / `ApplyEmbeddingModelIdButton`. |
| `SettingsDialog.xaml.cs` | Apply events trim draft, keep exact ID, then use existing selection/privacy/re-embedding confirmation once. Refresh events await corresponding view-model methods. Never convert selected item to its display label. |
| `SettingsDialog.xaml` | Add read-only `ContextWindowText`, `LimitsSourceText`, two-way text fields `RuntimeContextTextBox`, `MaxOutputTokensTextBox`, `SaveLimitsButton`, `ResetLimitsButton`, and `LimitsErrorText`; put extended content inside the existing/new ScrollViewer. |
| `SettingsViewModel` | Load pair-specific limits when provider/model changes; use invariant integer parse with positive bounds; save source user; reset deletes and refreshes auto. Increment a request revision and ignore stale async refresh/limit/probe completions. Preserve manual drafts across failures. |

Add every EN/CS string in the shared text table to both `.resw` files and matching PascalCase `StringKey` members. In code-behind, brushes come from `Application.Current.Resources[...]`. Map `ProviderContextTooLongException` to the reduce-context key. No Windows.Storage/Package APIs and no direct HttpClient usage enter view models.
- [ ] **Step 5: Run Core tests locally:** `dotnet test windows/tests/AINotebook.Core.Tests` → green. On Windows CI:

```bash
dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64
dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64
```

Expected: WinUI XAML/C# build succeeds and all App tests pass, including old router composition tests. Do not claim this from a macOS-only run.
- [ ] **Step 6: Manual Windows checklist for CI/smoke reviewer:** all seven presets, keyless local compatible save, correct model ID despite friendly label, Refresh failure preserves selection, unsupported neutral/auth red/valid-empty green, manual IDs usable without discovery, limits survive restart and isolate providers/models, reset and assumption labels correct in EN/CS, no duplicate privacy dialog per keystroke, no stale asynchronous result, custom Ollama proxy chat/embed/discovery/show, and old-turn/new-turn behavior after settings change. Verify no App router logic remains beyond forwarding.
- [ ] **Step 7: Commit:**

```bash
git add windows/src/AINotebook.App/Services/ProviderRouter.cs windows/src/AINotebook.App/Services/StringKey.cs windows/src/AINotebook.App/ViewModels/SettingsViewModel.cs windows/src/AINotebook.App/ViewModels/AddProviderViewModel.cs windows/src/AINotebook.App/Views/SettingsDialog.xaml windows/src/AINotebook.App/Views/SettingsDialog.xaml.cs windows/src/AINotebook.App/Views/AddProviderDialog.xaml windows/src/AINotebook.App/Views/AddProviderDialog.xaml.cs windows/src/AINotebook.App/Strings/en-US/Resources.resw windows/src/AINotebook.App/Strings/cs-CZ/Resources.resw windows/tests/AINotebook.App.Tests/ProviderRouterOpenWebUITests.cs windows/tests/AINotebook.App.Tests/ProviderRouterEmbedCompositeKeyTests.cs windows/tests/AINotebook.App.Tests/AddProviderViewModelOpenWebUITests.cs windows/tests/AINotebook.App.Tests/LocalizedStringsTests.cs windows/tests/AINotebook.App.Tests/ProviderSettingsTests.cs windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj
git commit -m "feat(win-settings): wire Core routing, presets, discovery and model limits" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## WP gate

Run after both lanes and WP3 v19 are integrated; no separate implementation task may bypass its own green suite while waiting for this gate.

```bash
python3 tools/contracts/gen_fixtures.py --check
python3 tools/contracts/gen_provider_fixtures.py --check
python3 tools/contracts/test_provider_fixtures.py
swift test
dotnet test windows/tests/AINotebook.Core.Tests
swift build
git diff --check
git status --short
```

Run the exact existing privacy-grep allowlist from `.github/workflows/core-ci.yml:38`:

```bash
OFFENDERS=$(grep -rl --include='*.swift' 'URLSession' Sources/AINotebookCore/ | grep -v -e '/OllamaClient.swift$' -e '/WebExtractor.swift$' -e '/Providers/' || true)
if [ -n "$OFFENDERS" ]; then
  echo "$OFFENDERS"
  exit 1
fi
```

Expected: exit 0 and no offender output; do not broaden the allowlist. It must find no new networking outside Providers and existing allowed files. Review the equivalent Windows diff for HttpClient usage outside its existing transport/Providers files. On Windows run the exact App build/test commands in Task 11; retain CI results and Claude's Swift manual-check report.

Acceptance criteria:

- Corrected WP0 API-root fixture passes both pure validation and real HTTP dispatch tests for chat/models/embeddings across all five types. Unsupported endpoints and invalid authority never dispatch. New default OpenAI root is exact `/v1`; real pre-v19 rows convert once; valid new versionless roots survive restart.
- All 20 existing wire-order cases plus five explicit multiple-system cases pass on both adapters. Options are observed on the wire, not only in a mock interface call. Unknown wire knobs are absent.
- 55 probe cases match across platforms, valid empty lists verify listing, unsupported never turns green, errors are visible, and every probe sends only one GET. No generation probe is performed.
- Windows App contains only router DI/forwarding; Core router tests prove custom Ollama roots and key-only equal-length cache invalidation. ChatEngine and App bridge tests prove snapshot capture before retrieval and reuse across retries, with next-turn changes visible.
- Privacy fixtures assert zero requests for chat and real background embedding paths without consent. Missing/disabled/chat-only providers never cause a silent endpoint substitution.
- Limits table/constraints/upsert/reset/isolation/reopen pass against WP3's actual v19 schema. Metadata discovery never raises runtime automatically above 8192; user overrides win refresh races; unknown auto defaults carry an assumption flag available to WP8.
- Both Settings UIs expose presets, refresh, manual IDs, three-state checks, limit editing/reset and the same EN/CS strings; raw model IDs are preserved. Swift manual review and Windows CI/App tests are recorded.
- Both full Core suites have zero failures, no skipped contract tests, no VERSION changes, no uncommitted task changes. Record actual before/after counts per platform in each implementation handoff.

**Claude review decisions:** confirm WP3's DDL plus one-time helper call and Windows `Migrate(conn, throughVersion)` testing seam; approve the stricter output<runtime invariant; confirm the intentionally small exact-ID known-model table and unsupported-list classification (404/405/501); review rejecting chat-only embedding fallback. All other WP0 findings remain binding and are outside this package's edits.
