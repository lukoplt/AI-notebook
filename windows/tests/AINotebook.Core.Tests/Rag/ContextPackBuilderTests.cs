using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class ContextPackBuilderTests
{
    [Fact]
    public void OlderVectorHitDoesNotBlockPublishedRevisionNeighbour()
    {
        var input = ContextPackFixtures.Input("basic-cs");
        var older = input.Candidates[0] with { RevisionId = 10, Text = "A", End = 1 };
        var published = older with { ChunkId = 102, RevisionId = 11, Text = "B", RrfMicro = 29_000 };
        var neighbour = published with { ChunkId = 103, Ordinal = 1, Start = 1, End = 2, Text = "C" };
        input = input with { Candidates = [older, published], Neighbours = [neighbour] };

        var request = ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1);

        Assert.Equal("BC", Assert.Single(request.CitationMap, c => c.RevisionId == 11).Text);
        Assert.Contains(new PackItem("neighbour", "103"), request.Included);
        Assert.DoesNotContain(request.Omitted, o => o.Kind == "neighbour" && o.Id == "103");
    }

    /// <summary>The adapter hands the builder a raw descriptor; the renderer is the only escaper.</summary>
    [Fact]
    public void EveryMapDescriptorGolden()
    {
        var rows = ContextPackFixtures.Cases("descriptor");
        Assert.Equal(8, rows.Length);
        foreach (var row in rows)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            string? descriptor = input.TryGetProperty("descriptor", out var d) ? d.GetString() : null;
            var detail = new ContextSourceDetail(1, 1, SourceTypeExtensions.FromRawValue(input.GetProperty("type").GetString()!),
                "t", 1, "a/t.pdf", null, descriptor);
            Assert.True(row.GetProperty("expected").GetString() == ContextPackLabels.Descriptor(detail), name);
        }
        Assert.Equal("", ContextPackLabels.Descriptor(null));
    }

    [Fact]
    public void EveryBuildGolden()
    {
        var rows = ContextPackFixtures.Cases("build");
        Assert.NotEmpty(rows);
        foreach (var row in rows)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input").Deserialize<ContextPackInput>(ContextPackFixtures.Options)!;
            var expected = row.GetProperty("expected");
            if (expected.TryGetProperty("error", out var error))
            {
                Assert.True(Assert.Throws<ContextPackException>(() => ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1)).Code == error.GetString(), name);
                continue;
            }
            var request = ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1);
            EqualJson(expected, PreparedContextRequestJson.Element(request), name);
            EqualJson(row.GetProperty("expectedWire"), ContextPackRendering.WireElement(request, input.Model.ProviderType), name + ".wire");
            byte[] bytes = PreparedContextRequestJson.Encode(request);
            using var encoded = JsonDocument.Parse(bytes);
            EqualJson(expected, encoded.RootElement, name + ".encoded");
            Assert.Equal(bytes, PreparedContextRequestJson.Encode(PreparedContextRequestJson.Decode(bytes)));
            Assert.DoesNotContain("\"isV2\"", Encoding.UTF8.GetString(bytes));
            Assert.DoesNotContain("\"providerType\"", Encoding.UTF8.GetString(bytes));
            long tokens = request.Messages.Sum(m => 4L + m.Sections.Sum(s => (long)s.Tokens));
            Assert.True(tokens <= input.Model.RuntimeContext - input.Model.MaxOutputTokens, name);
            Assert.Equal(Enumerable.Range(1, request.CitationMap.Length), request.CitationMap.Select(c => c.Marker));
            Assert.Single(request.Messages[^1].Sections, s => s.Kind == "question");
            Assert.Equal("question", request.Messages[^1].Sections[^1].Kind);
            foreach (var c in request.CitationMap)
            {
                Assert.Equal(c.ChunkIds[0], c.ChunkId);
                Assert.NotNull(c.Text);
                Assert.Equal(string.Concat(c.Text.EnumerateRunes().Take(240).Select(r => r.ToString())), c.Snippet);
            }
        }
    }

    [Fact]
    public void ScalarOverlapHasOneSnapshotAndNoRepeatedText()
    {
        var request = ContextPackBuilder.Build(ContextPackFixtures.Input("merge-overlap"), new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1);
        var c = Assert.Single(request.CitationMap);
        Assert.Equal("A😀. Bč!", c.Text);
        Assert.Equal(0, Assert.Single(c.Spans).Start);
        Assert.Equal(7, c.Spans[0].End);
        Assert.Equal(new long[] { 101, 102 }, c.ChunkIds);
    }

    [Fact]
    public void RulesAreEnglishAndDataIsOnlyInUser()
    {
        var request = ContextPackBuilder.Build(ContextPackFixtures.Input("external-labelled"), new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1);
        Assert.Equal("system", request.Messages[0].Role);
        Assert.Equal(new[] { "rules", "instructions" }, request.Messages[0].Sections.Select(s => s.Kind));
        Assert.StartsWith("The application has already searched", request.Messages[0].Sections[0].Text);
        Assert.Contains(request.Messages[^1].Sections, s => s.Kind == "note" && s.Text.Contains("NOT CONTENT OF THE SELECTED FOLDER"));
        Assert.Contains(request.Messages[^1].Sections, s => s.Kind == "web" && s.Text.Contains("NOT CONTENT OF THE SELECTED FOLDER"));
    }

    [Fact]
    public void WireOrderSharedCases()
    {
        var template = ContextPackBuilder.Build(ContextPackFixtures.Input("basic-cs"), new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1);
        foreach (var row in SharedFixtures.Json("contracts/wire-order-v1.json").GetProperty("cases").EnumerateArray())
        {
            var input = row.GetProperty("input");
            var sections = new List<PackSection> { new("rules", input.GetProperty("rulesText").GetString()!, 0) };
            string instructions = input.GetProperty("userInstructions").GetString()!;
            if (!string.IsNullOrWhiteSpace(instructions)) sections.Add(new("instructions", instructions, 0));
            var messages = new List<PackMessage> { new("system", sections.ToArray()) };
            messages.AddRange(input.GetProperty("history").EnumerateArray().Select(h => new PackMessage(
                h.GetProperty("role").GetString()!, [new("history", h.GetProperty("content").GetString()!, 0)])));
            messages.Add(new("user", [new("question", input.GetProperty("finalUserContent").GetString()!, 0)]));
            var request = template with { Messages = messages.ToArray(), Options = new(null, null) };
            EqualJson(row.GetProperty("expected"), ContextPackRendering.WireElement(request, row.GetProperty("provider").GetString()!), row.GetProperty("name").GetString()!);
            Assert.Equal(messages.Select(m => m.Role), ContextPackRendering.LogicalTurns(request).Select(m => m.Role.RawValue()));
        }
    }

    [Fact]
    public void CanonicalBytesUseScalarKeyOrderAndOnlyRequiredEscapes()
    {
        const string input = "{\"𐀀\":\"😀/<>é\",\"\":\"\\b\\f\\n\\r\\t\\u0000\\\"\\\\\"}";
        const string expected = "{\"\":\"\\b\\f\\n\\r\\t\\u0000\\\"\\\\\",\"𐀀\":\"😀/<>é\"}";
        using var document = JsonDocument.Parse(input);
        Assert.Equal(Encoding.UTF8.GetBytes(expected), PreparedContextRequestJson.CanonicalBytes(document.RootElement));
        var request = ContextPackBuilder.Build(ContextPackFixtures.Input("basic-cs"), new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1) with
        {
            GenerationId = null,
            SourceRevisions = [new(20, 21), new(10, 11), new(10, 9), new(10, 11)]
        };
        var decoded = PreparedContextRequestJson.Decode(PreparedContextRequestJson.Encode(request));
        Assert.Null(decoded.GenerationId);
        Assert.Equal(new PackSourceRevision[] { new(10, 9), new(10, 11), new(20, 21) }, decoded.SourceRevisions);
        Assert.Equal(JsonValueKind.Null, PreparedContextRequestJson.Element(request).GetProperty("generationId").ValueKind);
    }

    [Fact]
    public void SharedScalarMergeKernels()
    {
        var seed = ContextPackFixtures.Input("basic-cs").Candidates[0];
        foreach (var row in ContextPackFixtures.Cases("merge"))
        {
            string name = row.GetProperty("name").GetString()!;
            var parts = row.GetProperty("input").GetProperty("parts").EnumerateArray()
                .Select((p, i) => seed with { ChunkId = i + 1, Ordinal = i, Start = p.GetProperty("start").GetInt64(),
                    End = p.GetProperty("end").GetInt64(), Text = p.GetProperty("text").GetString()!, TruncationCandidates = [] }).ToArray();
            var expected = row.GetProperty("expected");
            if (expected.TryGetProperty("error", out var error))
            {
                if (error.GetString() == "disjoint") Assert.Equal(parts.Length, ContextPackRendering.Merge(parts).Length);
                else Assert.Equal("invalidInput", Assert.Throws<ContextPackException>(() => ContextPackRendering.Merge(parts)).Code);
            }
            else
            {
                var block = Assert.Single(ContextPackRendering.Merge(parts));
                EqualJson(expected, JsonSerializer.SerializeToElement(new { start = block.Passage.Start, end = block.Passage.End, text = block.Passage.Text }), name);
            }
        }
    }

    [Fact]
    public void InvalidSnapshotBoundariesFailBeforePacking()
    {
        var seed = ContextPackFixtures.Input("basic-cs");
        var p = seed.Candidates[0];
        ContextPackInput[] invalid =
        [
            seed with { Question = "\ud800" },
            seed with { GenerationId = 9_007_199_254_740_992 },
            seed with { Coverage = seed.Coverage with { FilesInScope = 2 } },
            seed with { Candidates = [p with { PageFrom = 5, PageTo = 2 }] },
            seed with { Candidates = [p, p with { Text = "x" }] },
            seed with { Candidates = [p with { TruncationCandidates = [new(1, 1)] }] },
            seed with { OverviewCandidates = [p with { RevisionId = 999 }] },
            seed with { History = [new(1, "q", "a"), new(1, "q2", "a2")] },
            seed with { External = [new("n1", "note", "n", "en"), new("n2", "note", "n", "en")] },
            seed with { SourceRevisions = new Dictionary<string, long> { ["010"] = 11 } }
        ];
        foreach (var input in invalid) Assert.Equal("invalidInput", Assert.Throws<ContextPackException>(() => ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1)).Code);
    }

    [Fact]
    public void SnapshotUsesFullJsonSafeScalarOffsetsAndPinnedEstimator()
    {
        var input = ContextPackFixtures.Input("merge-overlap");
        const long offset = 9_007_199_254_740_980;
        input = input with { Candidates = input.Candidates.Select(p => p with { Start = p.Start + offset, End = p.End + offset }).ToArray() };
        var request = ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1);
        var citation = Assert.Single(request.CitationMap);
        Assert.Equal(offset, Assert.Single(citation.Spans).Start);
        Assert.Equal(offset + 7, citation.Spans[0].End);
        Assert.Equal("A😀. Bč!", citation.Text);
        var versioned = ContextPackBuilder.Build(input, new TestEstimator());
        Assert.Equal(9, versioned.EstimatorVersion);
    }

    [Fact]
    public void MergeDeduplicatesLegacyIdentityAndRejectsConflicts()
    {
        var p = ContextPackFixtures.Input("basic-cs").Candidates[0] with { Start = null, End = null };
        Assert.Single(ContextPackRendering.Merge([p, p]));
        Assert.Equal("invalidInput", Assert.Throws<ContextPackException>(() => ContextPackRendering.Merge([p, p with { Text = "conflict" }])).Code);
    }

    [Fact]
    public void ProductionDefaultIsV2WhileExplicitV1RemainsAvailable()
    {
        var input = ContextPackFixtures.Input("basic-cs");
        var actual = ContextPackBuilder.Build(input);
        var expected = ContextPackBuilder.Build(input, TokenEstimatorV2.Bundled(input.Model.Model), RagRuntimeTuning.Bundled());
        Assert.Equal(PreparedContextRequestJson.Encode(expected), PreparedContextRequestJson.Encode(actual));
        Assert.Equal(2, actual.EstimatorVersion);
        Assert.Equal(1, ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1).EstimatorVersion);
    }

    [Fact]
    public void NegativeEstimatorCostIsInvalid()
    {
        Assert.Equal("invalidInput", Assert.Throws<ContextPackException>(() =>
            ContextPackBuilder.Build(ContextPackFixtures.Input("basic-cs"), new NegativeEstimator())).Code);
    }

    private sealed class NegativeEstimator : IContextTokenEstimator
    {
        public int Version => 1;
        public int Estimate(string text, string language) => -1;
    }

    private sealed class TestEstimator : IContextTokenEstimator
    {
        public int Version => 9;
        public int Estimate(string text, string language) => new PlaceholderTokenEstimatorV1().Estimate(text, language);
    }

    internal static void EqualJson(JsonElement expected, JsonElement actual, string path)
    {
        Assert.True(expected.ValueKind == actual.ValueKind, path + ": kind");
        if (expected.ValueKind == JsonValueKind.Object)
        {
            Assert.True(expected.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(actual.EnumerateObject().Select(p => p.Name).Order()), path + ": fields");
            foreach (var p in expected.EnumerateObject()) EqualJson(p.Value, actual.GetProperty(p.Name), path + "." + p.Name);
        }
        else if (expected.ValueKind == JsonValueKind.Array)
        {
            Assert.True(expected.GetArrayLength() == actual.GetArrayLength(), path + ": count");
            for (int i = 0; i < expected.GetArrayLength(); i++) EqualJson(expected[i], actual[i], path + "[" + i + "]");
        }
        else Assert.True(JsonElement.DeepEquals(expected, actual), path);
    }
}
