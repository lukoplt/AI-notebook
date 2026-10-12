using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Shared <c>indexing-status-v1</c> fixture: pure derivation and availability mapping.</summary>
public sealed class IndexingStatusContractTests
{
    private static IReadOnlyList<JsonElement> Cases(string operation)
    {
        var fixture = SharedFixtures.Json("contracts/indexing-status-v1.json");
        Assert.Equal("indexing-status", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        return fixture.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("operation").GetString() == operation).ToArray();
    }

    private static string? Str(JsonElement e, string key) => e.GetProperty(key).ValueKind == JsonValueKind.String ? e.GetProperty(key).GetString() : null;
    private static int? Int(JsonElement e, string key) => e.GetProperty(key).ValueKind == JsonValueKind.Number ? e.GetProperty(key).GetInt32() : null;
    private static long? Long(JsonElement e, string key) => e.GetProperty(key).ValueKind == JsonValueKind.Number ? e.GetProperty(key).GetInt64() : null;

    private static IndexingInputs Inputs(JsonElement row)
    {
        var job = row.GetProperty("embedJob");
        return new IndexingInputs
        {
            Now = row.GetProperty("now").GetInt64(),
            RuntimeError = Str(row, "runtimeError"),
            EmbeddingAvailability = Enum.Parse<EmbeddingAvailability>(row.GetProperty("embeddingAvailability").GetString()!, ignoreCase: true),
            Folders = row.GetProperty("folders").EnumerateArray().Select(f => new IndexingFolderInput(f.GetProperty("folderId").GetInt64(),
                f.GetProperty("scanState").GetString()!, Str(f, "lastScanError"), Int(f, "filesSeen"))).ToArray(),
            ScanJobsPending = row.GetProperty("scanJobsPending").GetInt32(),
            ExtractQueued = row.GetProperty("extractQueued").GetInt32(),
            ExtractRunning = row.GetProperty("extractRunning").GetInt32(),
            SourcesTotal = row.GetProperty("sourcesTotal").GetInt32(),
            SourcesReady = row.GetProperty("sourcesReady").GetInt32(),
            SourcesError = row.GetProperty("sourcesError").GetInt32(),
            NeedsEmbedding = row.GetProperty("needsEmbedding").GetBoolean(),
            EmbedJob = job.ValueKind == JsonValueKind.Null ? null : new IndexingEmbedJobInput(job.GetProperty("state").GetString()!,
                job.GetProperty("attempts").GetInt32(), Long(job, "nextRetryAt"), Str(job, "errorCode"), job.GetProperty("bootstrap").GetBoolean()),
            EmbedChunksDone = row.GetProperty("embedChunksDone").GetInt32(),
            EmbedChunksTotal = row.GetProperty("embedChunksTotal").GetInt32(),
            MemoryPressure = Enum.Parse<MemoryPressureLevel>(row.GetProperty("memoryPressure").GetString()!, ignoreCase: true)
        };
    }

    /// <summary>Canonical projection (contract §3).</summary>
    internal static JsonObject Project(IndexingStatus status) => new()
    {
        ["phase"] = IndexingStatusDerivation.ContractName(status.Phase),
        ["filesSeen"] = status.FilesSeen,
        ["done"] = status.Done,
        ["total"] = status.Total,
        ["preparing"] = status.Preparing,
        ["retry"] = status.Retry is { } r
            ? new JsonObject { ["code"] = r.Code, ["retryAt"] = r.RetryAt, ["attempt"] = r.Attempt, ["retryInSeconds"] = r.RetryInSeconds }
            : null,
        ["blockedReason"] = status.BlockedReason is { } reason ? IndexingStatusDerivation.ContractName(reason) : null,
        ["errorCode"] = status.ErrorCode,
        ["memoryPressure"] = status.MemoryPressure is { } pressure ? MemoryPressureLevels.ContractName(pressure) : null,
        ["sourceErrors"] = status.SourceErrors,
        ["scanWarnings"] = new JsonArray(status.ScanWarnings.Select(w =>
            (JsonNode)new JsonObject { ["folderId"] = w.FolderId, ["state"] = w.State, ["error"] = w.Error }).ToArray()),
        ["scanInProgress"] = status.ScanInProgress,
        ["isActive"] = status.IsActive
    };

    [Fact]
    public void DerivationMatchesFixture()
    {
        var rows = Cases("derive");
        Assert.True(rows.Count >= 40);
        foreach (var row in rows)
        {
            string name = row.GetProperty("name").GetString()!;
            var actual = Project(IndexingStatusDerivation.Derive(Inputs(row.GetProperty("input"))));
            var expected = JsonNode.Parse(row.GetProperty("expected").GetRawText());
            Assert.True(JsonNode.DeepEquals(expected, actual), $"{name}: expected {expected!.ToJsonString()} got {actual.ToJsonString()}");
        }
    }

    [Fact]
    public void AvailabilityMatchesFixture()
    {
        var rows = Cases("availability");
        Assert.True(rows.Count >= 10);
        foreach (var row in rows)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            bool supports = input.GetProperty("supportsEmbeddings").GetBoolean(), cloud = input.GetProperty("cloud").GetBoolean();
            var type = !supports ? ProviderType.Anthropic : cloud ? ProviderType.OpenAICompatible : ProviderType.Ollama;
            var config = new ProviderConfig("p", type, "P", cloud ? "https://e.example/v1" : "http://127.0.0.1:11434",
                input.GetProperty("enabled").GetBoolean(), input.GetProperty("privacyAcknowledged").GetBoolean(), DateTime.UnixEpoch);
            Assert.Equal(supports, config.Type.SupportsEmbeddings());
            Assert.Equal(cloud, config.IsCloud);
            int loads = 0;
            bool fails = input.GetProperty("keyLoadFails").GetBoolean();
            var (availability, _) = FolderEmbeddingSession.Availability(input.GetProperty("configured").GetBoolean() ? config : null,
                input.GetProperty("model").GetString(), () =>
                {
                    loads++;
                    if (fails) throw new InvalidOperationException("credential store down");
                    return cloud ? "k" : null;
                });
            Assert.True(row.GetProperty("expected").GetString() == IndexingStatusDerivation.ContractName(availability), name);
            if (availability is not EmbeddingAvailability.Ready and not EmbeddingAvailability.CredentialUnavailable)
                Assert.True(loads == 0, $"{name}: the key is loaded only after every cheaper check");
        }
    }

    /// <summary>Addendum §8: the embed job behind <c>embedJob</c> and the generation behind the chunk counts.</summary>
    [Fact]
    public void EmbedJobSelectionMatchesFixture()
    {
        var rows = Cases("embedJob");
        Assert.True(rows.Count >= 15);
        foreach (var row in rows)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            var selected = EmbedJobPlanning.StatusJob(BuildMergeFixture.Jobs(input.GetProperty("jobs")),
                BuildMergeFixture.Generations(input.GetProperty("generations")));
            var actual = new JsonObject
            {
                ["embedJob"] = selected is null ? null : new JsonObject
                {
                    ["state"] = selected.Job.State,
                    ["attempts"] = selected.Job.Attempts,
                    ["nextRetryAt"] = selected.Job.NextRetryAt,
                    ["errorCode"] = selected.Job.Error,
                    ["bootstrap"] = selected.Bootstrap
                },
                ["progressGenerationId"] = selected?.ProgressGenerationId
            };
            var expected = JsonNode.Parse(row.GetProperty("expected").GetRawText());
            Assert.True(JsonNode.DeepEquals(expected, actual), $"{name}: expected {expected!.ToJsonString()} got {actual.ToJsonString()}");
        }
    }

    [Fact]
    public void ResolveCapturesSessionOnlyWhenReady()
    {
        using var http = new HttpClient();
        var local = new ProviderConfig("ollama", ProviderType.Ollama, "Ollama", "http://127.0.0.1:11434", true, false, DateTime.UnixEpoch);
        var ready = FolderEmbeddingSession.Resolve(local, "nomic-embed-text", () => null, http);
        Assert.Equal(EmbeddingAvailability.Ready, ready.Availability);
        Assert.Equal("nomic-embed-text", ready.Session!.Selection.Model);
        var missing = FolderEmbeddingSession.Resolve(null, "m", () => null, http);
        Assert.Equal(EmbeddingAvailability.NoProvider, missing.Availability);
        Assert.Null(missing.Session);
        var malformed = new ProviderConfig("bad", ProviderType.OpenAICompatible, "Bad", "not a url", true, true, DateTime.UnixEpoch);
        Assert.Equal(EmbeddingAvailability.NoProvider, FolderEmbeddingSession.Resolve(malformed, "m", () => "k", http).Availability);
        Assert.Throws<ArgumentException>(() => EmbeddingSessionResolution.Unavailable(EmbeddingAvailability.Ready));
    }
}
