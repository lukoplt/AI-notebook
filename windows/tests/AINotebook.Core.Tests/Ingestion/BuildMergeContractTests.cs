using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Decodes the job/generation rows shared by <c>ingestion-build-merge-v1</c> and <c>indexing-status-v1</c> §8.</summary>
internal static class BuildMergeFixture
{
    private static string? Str(JsonElement e, string key) => e.GetProperty(key).ValueKind == JsonValueKind.String ? e.GetProperty(key).GetString() : null;

    public static EmbeddingSelection Selection(JsonElement e) => new(e.GetProperty("providerId").GetString()!,
        e.GetProperty("endpointRevision").GetString()!, e.GetProperty("model").GetString()!, Str(e, "modelDigest"),
        e.GetProperty("dims").ValueKind == JsonValueKind.Number ? e.GetProperty("dims").GetInt32() : null,
        e.GetProperty("normalization").GetString()!, e.GetProperty("queryFormatVersion").GetString()!,
        e.GetProperty("docFormatVersion").GetString()!, e.GetProperty("chunkerVersion").GetString()!);

    public static GenerationIdentity Identity(JsonElement e) => IngestionGenerationSQL.Identity(Selection(e), e.GetProperty("dims").GetInt32());

    public static IReadOnlyList<GenerationSnapshot> Generations(JsonElement e) => e.EnumerateArray()
        .Select(g => new GenerationSnapshot(g.GetProperty("id").GetInt64(), g.GetProperty("state").GetString()!, Identity(g.GetProperty("identity"))))
        .ToArray();

    public static EmbedJobSnapshot Job(JsonElement e)
    {
        var options = e.GetProperty("options");
        return new EmbedJobSnapshot(e.GetProperty("id").GetInt64(), e.GetProperty("target").GetString()!, e.GetProperty("state").GetString()!,
            e.GetProperty("attempts").GetInt32(),
            e.GetProperty("nextRetryAt").ValueKind == JsonValueKind.Number ? e.GetProperty("nextRetryAt").GetInt64() : null,
            e.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String ? error.GetString() : null,
            options.ValueKind == JsonValueKind.Null ? null
                : new EmbedJobOptions(Selection(options.GetProperty("selection")), options.GetProperty("copyExisting").GetBoolean()));
    }

    public static IReadOnlyList<EmbedJobSnapshot> Jobs(JsonElement e) => e.EnumerateArray().Select(Job).ToArray();
}

/// <summary>Shared <c>ingestion-build-merge-v1</c> fixture: pure merge decisions.</summary>
public sealed class BuildMergeContractTests
{
    private static IReadOnlyList<JsonElement> Cases(string operation)
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-build-merge-v1.json");
        Assert.Equal("ingestion-build-merge", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        return fixture.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("operation").GetString() == operation).ToArray();
    }

    [Fact]
    public void ResolveMatchesFixture()
    {
        var rows = Cases("resolve");
        Assert.True(rows.Count >= 15);
        foreach (var row in rows)
        {
            var input = row.GetProperty("input");
            var resolved = EmbedJobPlanning.ResolveBuild(BuildMergeFixture.Selection(input.GetProperty("selection")),
                input.GetProperty("copyExisting").GetBoolean(), BuildMergeFixture.Generations(input.GetProperty("generations")));
            var expected = row.GetProperty("expected").GetProperty("generationId");
            Assert.True((expected.ValueKind == JsonValueKind.Null ? null : expected.GetInt64()) == resolved?.Id,
                row.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void SupersedeMatchesFixture()
    {
        var rows = Cases("supersede");
        Assert.True(rows.Count >= 10);
        foreach (var row in rows)
        {
            var input = row.GetProperty("input");
            var ids = EmbedJobPlanning.Superseded(BuildMergeFixture.Identity(input.GetProperty("identity")),
                BuildMergeFixture.Jobs(input.GetProperty("jobs")));
            Assert.True(row.GetProperty("expected").EnumerateArray().Select(v => v.GetInt64()).SequenceEqual(ids),
                row.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void StartupMatchesFixture()
    {
        var rows = Cases("startup");
        Assert.True(rows.Count >= 8);
        foreach (var row in rows)
        {
            var input = row.GetProperty("input");
            var action = EmbedJobPlanning.Startup(BuildMergeFixture.Job(input.GetProperty("job")),
                BuildMergeFixture.Generations(input.GetProperty("generations")), input.GetProperty("needsEmbedding").GetBoolean());
            Assert.True(row.GetProperty("expected").GetString() == action.ToString().ToLowerInvariant(), row.GetProperty("name").GetString());
        }
    }
}
