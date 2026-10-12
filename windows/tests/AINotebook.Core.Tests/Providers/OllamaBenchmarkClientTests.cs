using System.Net;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Rag;
using Xunit;

using CoreProviderRouter = AINotebook.Core.Providers.Routing.ProviderRouter;

namespace AINotebook.Core.Tests.Providers;

public sealed class OllamaBenchmarkClientTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/embedding-strict-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    /// <summary>Records every request (method, URL, body) and replies from a script; can mutate state after a reply.</summary>
    internal sealed class ScriptHandler : HttpMessageHandler
    {
        public sealed record Sent(string Method, string Url, string? Body);
        public readonly List<Sent> Requests = [];
        private readonly Queue<(int Status, string Body)> _replies = new();
        public Action<int>? AfterReply;

        public ScriptHandler Reply(int status, string body) { _replies.Enqueue((status, body)); return this; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            string? body = request.Content is null ? null : await request.Content.ReadAsStringAsync(ct);
            Requests.Add(new(request.Method.Method, request.RequestUri!.OriginalString, body));
            if (_replies.Count == 0) throw new InvalidOperationException("unscripted request " + request.RequestUri);
            var (status, text) = _replies.Dequeue();
            var response = new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
            AfterReply?.Invoke(Requests.Count);
            return response;
        }
    }

    internal static void AssertRequests(JsonElement expected, IReadOnlyList<ScriptHandler.Sent> actual, string name)
    {
        var rows = expected.EnumerateArray().ToArray();
        Assert.True(rows.Length == actual.Count, $"{name}: {rows.Length} != {actual.Count}");
        for (int i = 0; i < rows.Length; i++)
        {
            Assert.Equal(rows[i].GetProperty("method").GetString(), actual[i].Method);
            Assert.Equal(rows[i].GetProperty("url").GetString(), actual[i].Url);
            var body = rows[i].GetProperty("body");
            if (body.ValueKind == JsonValueKind.Null) Assert.Null(actual[i].Body);
            else
            {
                using var doc = JsonDocument.Parse(actual[i].Body!);
                Assert.True(JsonElement.DeepEquals(body, doc.RootElement), $"{name}: {actual[i].Body}");
            }
        }
    }

    private static string ResponseText(JsonElement response) =>
        response.TryGetProperty("bodyText", out var text) ? text.GetString()! : response.GetProperty("body").GetRawText();

    private static ChatRequestOptions Options(JsonElement o) =>
        new(o.GetProperty("runtimeContext").GetInt32(), o.GetProperty("maxOutputTokens").GetInt32());

    private sealed class FakeTokenizerChannel(JsonElement expectedRequest, JsonElement response) : IOfflineTokenizerChannel
    {
        public int Calls;
        public Task<string> ExchangeAsync(string requestLine, CancellationToken ct)
        {
            Calls++;
            Assert.DoesNotContain('\n', requestLine);
            using var doc = JsonDocument.Parse(requestLine);
            Assert.True(JsonElement.DeepEquals(expectedRequest, doc.RootElement), requestLine);
            return Task.FromResult(response.GetRawText());
        }
    }

    [Fact]
    public async Task SharedWireCases()
    {
        int n = 0;
        foreach (var c in Cases("wire"))
        {
            string name = c.GetProperty("name").GetString()!;
            var call = c.GetProperty("call");
            var expected = c.GetProperty("expected");
            var handler = new ScriptHandler().Reply(c.GetProperty("response").GetProperty("status").GetInt32(), ResponseText(c.GetProperty("response")));
            using var http = new HttpClient(handler);
            var client = new OllamaBenchmarkClient(new Uri(call.GetProperty("root").GetString()!), http);
            string? error = null;
            int? status = null;
            try
            {
                switch (call.GetProperty("method").GetString())
                {
                    case "embed":
                        var r = await client.EmbedAsync(call.GetProperty("model").GetString()!, call.GetProperty("input").GetString()!,
                            call.GetProperty("nativeDims").GetInt32(), call.GetProperty("inputLimit").GetInt32());
                        Assert.Equal(expected.GetProperty("promptTokens").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("promptTokens").GetInt32(), r.PromptTokens);
                        Assert.Equal(expected.GetProperty("totalDurationNs").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("totalDurationNs").GetInt64(), r.TotalDurationNs);
                        Assert.Equal(expected.GetProperty("loadDurationNs").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("loadDurationNs").GetInt64(), r.LoadDurationNs);
                        if (expected.TryGetProperty("vectorMillionths", out var v)) EmbeddingProfileTests.AssertMillionths(v, r.Vector);
                        else
                        {
                            Assert.Equal(expected.GetProperty("vectorLength").GetInt32(), r.Vector.Length);
                            Assert.InRange(Math.Abs(r.Vector[0] - expected.GetProperty("firstComponentMillionths").GetInt64() / 1e6), 0, 1e-6);
                        }
                        break;
                    case "observeRaw":
                    case "observeChat":
                        bool raw = call.GetProperty("method").GetString() == "observeRaw";
                        string model = call.GetProperty("model").GetString()!;
                        var options = Options(call.GetProperty("options"));
                        var obs = raw
                            ? await client.ObserveRawAsync(model, call.GetProperty("text").GetString()!, options)
                            : await client.ObserveChatAsync(model, call.GetProperty("messages").EnumerateArray()
                                .Select(m => new ChatTurn(m.GetProperty("role").GetString() switch
                                {
                                    "system" => ChatRole.System, "user" => ChatRole.User, _ => ChatRole.Assistant,
                                }, m.GetProperty("content").GetString()!)).ToArray(), options);
                        Assert.Equal(expected.GetProperty("text").GetString(), obs.Text);
                        Assert.Equal(expected.GetProperty("promptTokens").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("promptTokens").GetInt32(), obs.PromptTokens);
                        Assert.Equal(expected.GetProperty("outputTokens").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("outputTokens").GetInt32(), obs.OutputTokens);
                        OfflineTokenizerClient? fallback = null;
                        FakeTokenizerChannel? channel = null;
                        if (expected.TryGetProperty("fallbackRequest", out var fr))
                        {
                            channel = new FakeTokenizerChannel(fr, expected.GetProperty("fallbackResponse"));
                            fallback = new OfflineTokenizerClient(channel);
                        }
                        var counted = await ChatTokenCounting.ResolveAsync(obs,
                            raw ? ChatTokenMethods.OllamaRawPrompt : ChatTokenMethods.OllamaChatPrompt,
                            raw ? call.GetProperty("text").GetString()! : "", fallback,
                            fr.ValueKind == JsonValueKind.Object ? fr.GetProperty("tokenizerId").GetString() : null,
                            fr.ValueKind == JsonValueKind.Object ? fr.GetProperty("requestId").GetString()! : name);
                        Assert.Equal(expected.GetProperty("method").GetString(), counted.Method);
                        Assert.Equal(expected.TryGetProperty("observedTokens", out var ot) ? ot.GetInt32() : obs.PromptTokens, counted.Tokens);
                        if (channel is not null)
                        {
                            Assert.Equal(1, channel.Calls);
                            var resp = expected.GetProperty("fallbackResponse");
                            Assert.Equal(resp.GetProperty("revision").GetString(), counted.TokenizerRevision);
                            Assert.Equal(resp.GetProperty("assetsSha256").GetString(), counted.TokenizerAssetsSha256);
                            Assert.Equal(resp.GetProperty("tokenizerId").GetString(), counted.TokenizerId);
                        }
                        else Assert.Null(counted.TokenizerId);
                        break;
                    default: throw new InvalidOperationException(name);
                }
            }
            catch (EmbeddingProfileException e) { error = e.Code; status = e.Status; }
            catch (EmbeddingInputTooLongException) { error = "inputTooLong"; }
            if (expected.TryGetProperty("error", out var want))
            {
                Assert.True(want.GetString() == error, $"{name}: {error}");
                if (expected.TryGetProperty("status", out var s)) Assert.Equal(s.GetInt32(), status);
            }
            else Assert.True(error is null, $"{name}: {error}");
            AssertRequests(JsonDocument.Parse("[" + c.GetProperty("request").GetRawText() + "]").RootElement, handler.Requests, name);
            n++;
        }
        Assert.Equal(19, n);
    }

    private static EmbeddingProviderSnapshot Snapshot(JsonElement p) => new(
        p.GetProperty("id").GetString()!, ProviderTypeExtensions.FromStorageString(p.GetProperty("type").GetString()!),
        p.GetProperty("root").GetString()!, p.GetProperty("enabled").GetBoolean(), p.GetProperty("consented").GetBoolean(),
        p.GetProperty("embeddingCapable").GetBoolean());

    private static ScriptHandler PrepareHandler(JsonElement c)
    {
        var handler = new ScriptHandler().Reply(200, c.GetProperty("tags").GetRawText());
        if (c.TryGetProperty("show", out var show) && show.ValueKind != JsonValueKind.Null) handler.Reply(200, show.GetRawText());
        return handler;
    }

    internal static GenerationIdentity Identity(JsonElement i) => new(
        i.GetProperty("providerId").GetString()!, i.GetProperty("endpointRevision").GetString()!, i.GetProperty("model").GetString()!,
        i.GetProperty("modelDigest").ValueKind == JsonValueKind.Null ? null : i.GetProperty("modelDigest").GetString(),
        i.GetProperty("dims").GetInt32(), i.GetProperty("normalization").GetString()!, i.GetProperty("queryFormatVersion").GetString()!,
        i.GetProperty("docFormatVersion").GetString()!, i.GetProperty("chunkerVersion").GetString()!);

    [Fact]
    public async Task SharedPrepareCasesCaptureIdentityOnce()
    {
        int n = 0;
        foreach (var c in Cases("prepare"))
        {
            string name = c.GetProperty("name").GetString()!;
            var expected = c.GetProperty("expected");
            var handler = PrepareHandler(c);
            using var http = new HttpClient(handler);
            var snapshot = Snapshot(c.GetProperty("provider"));
            var profile = EmbeddingProfiles.Require(c.GetProperty("profileId").GetString()!);
            string? error = null;
            EmbeddingProfileCapture? captured = null;
            try { captured = await EmbeddingProfileCapture.CaptureAsync(snapshot, profile, http); }
            catch (EmbeddingProfileException e) { error = e.Code; }
            Assert.True(expected.GetProperty("error").ValueKind == JsonValueKind.Null ? error is null
                : expected.GetProperty("error").GetString() == error, $"{name}: {error}");
            AssertRequests(expected.GetProperty("requests"), handler.Requests, name);
            Assert.Equal(0, expected.GetProperty("embeddingRequests").GetInt32());
            Assert.DoesNotContain(handler.Requests, r => r.Url.EndsWith("/api/embed", StringComparison.Ordinal));
            if (captured is not null)
            {
                Assert.Equal(Identity(expected.GetProperty("identity")), captured.Identity);
                Assert.Equal(expected.GetProperty("effectiveLimit").GetInt32(), captured.EffectiveLimit);
            }
            n++;
        }
        Assert.Equal(14, n);
    }

    [Fact]
    public async Task RouterPreparesProfilesOnTheCapturedRootDespiteSettingsMutation()
    {
        int n = 0;
        foreach (var c in Cases("prepare"))
        {
            var p = c.GetProperty("provider");
            if (!p.GetProperty("embeddingCapable").GetBoolean()) continue; // modelled by type at router level
            string name = c.GetProperty("name").GetString()!;
            var expected = c.GetProperty("expected");
            using var store = new NotebookStore(StorePath.InMemory);
            var config = new ProviderConfig(p.GetProperty("id").GetString()!, ProviderTypeExtensions.FromStorageString(p.GetProperty("type").GetString()!),
                "P", p.GetProperty("root").GetString()!, p.GetProperty("enabled").GetBoolean(), p.GetProperty("consented").GetBoolean(), DateTime.UtcNow);
            store.SaveProvider(config);
            var handler = PrepareHandler(c);
            foreach (var m in c.GetProperty("mutations").EnumerateArray())
            {
                Assert.Equal("tags", m.GetProperty("after").GetString());
                Assert.Equal("root", m.GetProperty("field").GetString());
                string value = m.GetProperty("value").GetString()!;
                handler.AfterReply = count => { if (count == 1) store.SaveProvider(config with { BaseUrl = value }); };
            }
            using var http = new HttpClient(handler);
            var router = new CoreProviderRouter(store, () => (config.Id, "chat"), () => (config.Id, "embed"), _ => null, http);
            string? error = null;
            PreparedEmbeddingProfile? prepared = null;
            try { prepared = await router.PrepareEmbeddingProfileAsync(config.Id, c.GetProperty("profileId").GetString()!); }
            catch (EmbeddingProfileException e) { error = e.Code; }
            Assert.True(expected.GetProperty("error").ValueKind == JsonValueKind.Null ? error is null
                : expected.GetProperty("error").GetString() == error, $"{name}: {error}");
            AssertRequests(expected.GetProperty("requests"), handler.Requests, name);
            if (prepared is not null)
            {
                var identity = Identity(expected.GetProperty("identity"));
                Assert.Equal(identity, prepared.Identity);
                Assert.Equal(identity, prepared.Session.Identity);
                Assert.Equal(identity.EndpointRevision, prepared.Session.EndpointRevision);
                Assert.Equal(expected.GetProperty("effectiveLimit").GetInt32(), prepared.Session.EffectiveLimit);
                // Every later embed stays on the captured root, with the captured model and limit.
                var profile = EmbeddingProfiles.Require(c.GetProperty("profileId").GetString()!);
                var vector = new float[profile.NativeDims]; vector[0] = 1;
                var reply = JsonSerializer.Serialize(new { embeddings = new[] { vector }, prompt_eval_count = 3 });
                handler.Reply(200, reply).Reply(200, reply);
                var q = await prepared.Session.EmbedAsync(["a"]);
                var d = await prepared.Session.EmbedDocumentsAsync(["b"]);
                Assert.Equal(profile.Dims, Assert.Single(q).Length);
                Assert.Equal(profile.Dims, Assert.Single(d).Length);
                var embeds = handler.Requests.Skip(2).ToArray();
                Assert.Equal(2, embeds.Length);
                string root = p.GetProperty("root").GetString()!;
                Assert.All(embeds, r => Assert.Equal(root + "/api/embed", r.Url));
                using var qb = JsonDocument.Parse(embeds[0].Body!);
                using var db = JsonDocument.Parse(embeds[1].Body!);
                Assert.Equal(profile.Format("a", EmbeddingPurpose.Query), qb.RootElement.GetProperty("input")[0].GetString());
                Assert.Equal(profile.Format("b", EmbeddingPurpose.Document), db.RootElement.GetProperty("input")[0].GetString());
                Assert.Equal(prepared.Session.EffectiveLimit, qb.RootElement.GetProperty("options").GetProperty("num_ctx").GetInt32());
                Assert.Equal(profile.Model, db.RootElement.GetProperty("model").GetString());
            }
            n++;
        }
        Assert.Equal(13, n);
    }

    [Fact]
    public async Task ResumeRereadsOnlyTagsAndParsesTheStoredContext()
    {
        int n = 0;
        foreach (var c in Cases("resume"))
        {
            string name = c.GetProperty("name").GetString()!;
            var expected = c.GetProperty("expected");
            var identity = Identity(c.GetProperty("identity"));
            using var store = new NotebookStore(StorePath.InMemory);
            store.SaveProvider(new ProviderConfig(identity.ProviderId, ProviderType.Ollama, "Ollama", "http://127.0.0.1:11434", true, true, DateTime.UtcNow));
            var handler = new ScriptHandler().Reply(200, c.GetProperty("tags").GetRawText());
            using var http = new HttpClient(handler);
            var router = new CoreProviderRouter(store, () => (identity.ProviderId, "chat"), () => (identity.ProviderId, "embed"), _ => null, http);
            string? error = null;
            ProviderEmbeddingSession? session = null;
            try { session = await router.PrepareEmbeddingAsync(identity); }
            catch (EmbeddingProfileException e) { error = e.Code; }
            Assert.True(expected.GetProperty("error").ValueKind == JsonValueKind.Null ? error is null
                : expected.GetProperty("error").GetString() == error, $"{name}: {error}");
            AssertRequests(expected.GetProperty("requests"), handler.Requests, name);
            if (session is not null)
            {
                Assert.Equal(expected.GetProperty("effectiveLimit").GetInt32(), session.EffectiveLimit);
                Assert.Equal(identity, session.Identity);
                Assert.Null(session.Status);
            }
            n++;
        }
        Assert.Equal(4, n);
    }

    [Fact]
    public async Task UnknownFormatsStillRejectBeforeAnyRequest()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        store.SaveProvider(new ProviderConfig(ProviderConfig.OllamaId, ProviderType.Ollama, "Ollama", "http://127.0.0.1:11434", true, true, DateTime.UtcNow));
        var handler = new ScriptHandler();
        using var http = new HttpClient(handler);
        var router = new CoreProviderRouter(store, () => (ProviderConfig.OllamaId, "chat"), () => (ProviderConfig.OllamaId, "embed"), _ => null, http);
        string endpoint = EmbeddingEndpointRevision.Make(ProviderType.Ollama, "http://127.0.0.1:11434");
        foreach (var format in new[] { "99", "wp7:nomic-v2-128:query:split1:scalarpool1:prefixl2:ctx512" })
        {
            var identity = new GenerationIdentity(ProviderConfig.OllamaId, endpoint, "nomic-embed-text-v2-moe",
                "sha256:" + new string('3', 64), 256, "l2", format, format.Replace(":query:", ":document:"), "2");
            var e = await Assert.ThrowsAsync<RetrievalException>(() => router.PrepareEmbeddingAsync(identity));
            Assert.Equal("unsupportedQueryFormat", e.Code);
        }
        var mismatch = new GenerationIdentity(ProviderConfig.OllamaId, endpoint, "nomic-embed-text-v2-moe",
            "sha256:" + new string('3', 64), 768, "l2", "wp7:nomic-v2-256:query:split1:scalarpool1:prefixl2:ctx512",
            "wp7:nomic-v2-256:document:split1:scalarpool1:prefixl2:ctx512", "2");
        Assert.Equal("profileIdentityMismatch", (await Assert.ThrowsAsync<EmbeddingProfileException>(() => router.PrepareEmbeddingAsync(mismatch))).Code);
        var noDigest = mismatch with { Dims = 256, ModelDigest = null };
        Assert.Equal("embeddingModelChanged", (await Assert.ThrowsAsync<EmbeddingProfileException>(() => router.PrepareEmbeddingAsync(noDigest))).Code);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task CapturedSessionRevalidatesItsDigestBeforePublication()
    {
        var c = Cases("prepare").First(x => x.GetProperty("name").GetString() == "prepare-profile-root-change");
        var handler = PrepareHandler(c);
        using var http = new HttpClient(handler);
        var router = RouterFor(c, http, out _);
        var prepared = await router.PrepareEmbeddingProfileAsync(ProviderConfig.OllamaId, "nomic-v2-256");
        handler.Reply(200, c.GetProperty("tags").GetRawText());
        await prepared.Session.VerifyModelAsync();
        var changed = c.GetProperty("tags").GetRawText().Replace(new string('3', 64), new string('d', 64));
        handler.Reply(200, changed);
        var e = await Assert.ThrowsAsync<EmbeddingProfileException>(() => prepared.Session.VerifyModelAsync());
        Assert.Equal("embeddingModelChanged", e.Code);
        Assert.Equal(4, handler.Requests.Count);
        Assert.All(handler.Requests.Skip(2), r => Assert.Equal("http://127.0.0.1:11434/api/tags", r.Url));
    }

    private static CoreProviderRouter RouterFor(JsonElement c, HttpClient http, out NotebookStore store)
    {
        var p = c.GetProperty("provider");
        store = new NotebookStore(StorePath.InMemory);
        var config = new ProviderConfig(p.GetProperty("id").GetString()!, ProviderType.Ollama, "P", p.GetProperty("root").GetString()!, true, true, DateTime.UtcNow);
        store.SaveProvider(config);
        return new CoreProviderRouter(store, () => (config.Id, "chat"), () => (config.Id, "embed"), _ => null, http);
    }

    [Fact]
    public async Task OfflineTokenizerRejectsMismatchedOrErrorResponses()
    {
        var request = JsonDocument.Parse("""{"requestId":"r","text":"x","tokenizerId":"t"}""").RootElement;
        var wrongId = JsonDocument.Parse("""{"requestId":"other","tokens":1,"tokenizerId":"t","revision":"v","assetsSha256":"%"}""".Replace("%", new string('c', 64))).RootElement;
        var client = new OfflineTokenizerClient(new FakeTokenizerChannel(request, wrongId));
        Assert.Equal("tokenizerUnavailable", (await Assert.ThrowsAsync<EmbeddingProfileException>(() => client.CountDetailedAsync("r", "t", "x"))).Code);
        var unknown = JsonDocument.Parse("""{"requestId":"r","error":"unknownTokenizer"}""").RootElement;
        client = new OfflineTokenizerClient(new FakeTokenizerChannel(request, unknown));
        Assert.Equal("unknownTokenizer", (await Assert.ThrowsAsync<EmbeddingProfileException>(() => client.CountDetailedAsync("r", "t", "x"))).Code);
    }
}
