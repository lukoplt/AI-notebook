using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class RagRuntimeTuningTests
{
    private static IEnumerable<JsonElement> Cases(string kind) =>
        SharedFixtures.Json("contracts/benchmark-run-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("kind").GetString() == kind);

    [Fact]
    public void SharedDecisionParameters()
    {
        int n = 0;
        foreach (var row in Cases("tuning"))
        {
            byte[] bytes = Encoding.UTF8.GetBytes(row.GetProperty("input").GetRawText());
            if (row.TryGetProperty("error", out var error))
            {
                Assert.Equal(error.GetString(), Assert.Throws<RagTuningException>(() => RagRuntimeTuning.DecodeDecision(bytes)).Code);
                n++;
                continue;
            }
            var value = RagRuntimeTuning.DecodeDecision(bytes);
            var expected = row.GetProperty("expected");
            Assert.Equal(expected.GetProperty("fetchK").GetInt32(), value.FetchK);
            Assert.Equal(expected.GetProperty("topK").GetInt32(), value.TopK);
            Assert.Equal(expected.GetProperty("evidenceShareBp").GetInt32(), value.EvidenceShareBp);
            n++;
        }
        Assert.Equal(8, n);
    }

    [Fact]
    public void ConstructorValidatesAndV1EqualsTheFrozenConstants()
    {
        foreach (var (f, t, s) in new[] { (16, 24, 6000), (32, 0, 6000), (1025, 16, 6000), (32, 16, -1), (32, 16, 10001) })
            Assert.Equal("invalidTuning", Assert.Throws<RagTuningException>(() => new RagRuntimeTuning(f, t, s)).Code);
        var constants = SharedFixtures.Json("contracts/constants-v1.json");
        Assert.Equal(constants.GetProperty("retrieval").GetProperty("fetchK").GetInt32(), RagRuntimeTuning.V1.FetchK);
        Assert.Equal(constants.GetProperty("retrieval").GetProperty("topK").GetInt32(), RagRuntimeTuning.V1.TopK);
        Assert.Equal(constants.GetProperty("pack").GetProperty("evidenceShareBp").GetInt32(), RagRuntimeTuning.V1.EvidenceShareBp);
    }

    [Fact]
    public void BundledTuningFollowsTheProductionDecision()
    {
        var decision = EmbeddingDecision.Bundled();
        var bundled = RagRuntimeTuning.Bundled();
        if (decision.Status == "pending") Assert.Equal(RagRuntimeTuning.V1, bundled);
        // Accepted runtime parameters equal constants-v2 when Task 12 ships it, otherwise v1.
        string v2 = SharedFixtures.Path("contracts/constants-v2.json");
        var constants = SharedFixtures.Json(File.Exists(v2) ? "contracts/constants-v2.json" : "contracts/constants-v1.json");
        if (decision.Status == "accepted")
        {
            Assert.Equal(constants.GetProperty("retrieval").GetProperty("fetchK").GetInt32(), bundled.FetchK);
            Assert.Equal(constants.GetProperty("retrieval").GetProperty("topK").GetInt32(), bundled.TopK);
            Assert.Equal(constants.GetProperty("pack").GetProperty("evidenceShareBp").GetInt32(), bundled.EvidenceShareBp);
        }
    }

    [Fact]
    public void TunedShareCannotCreateEvidenceAtZeroCap()
    {
        var input = ContextPackFixtures.Input("basic-cs") with { EvidenceBudgetCap = 0 };
        var request = ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), new RagRuntimeTuning(48, 24, 7000));
        Assert.Empty(request.CitationMap);
        Assert.DoesNotContain(request.Messages.SelectMany(m => m.Sections), s => s.Kind == "evidence");
    }

    [Fact]
    public void SharedTuningBuilds()
    {
        int n = 0;
        foreach (var row in Cases("tuning-build"))
        {
            string name = row.GetProperty("name").GetString()!;
            var i = row.GetProperty("input");
            Assert.Equal(1, i.GetProperty("estimatorVersion").GetInt32());
            var input = ContextPackFixtures.Input(i.GetProperty("packFixture").GetString()!);
            if (i.GetProperty("evidenceBudgetCap").ValueKind != JsonValueKind.Null)
                input = input with { EvidenceBudgetCap = i.GetProperty("evidenceBudgetCap").GetInt32() };
            var t = i.GetProperty("tuning");
            var tuning = new RagRuntimeTuning(t.GetProperty("fetchK").GetInt32(), t.GetProperty("topK").GetInt32(), t.GetProperty("evidenceShareBp").GetInt32());
            var request = ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), tuning);
            var expected = row.GetProperty("expected");
            Assert.True(JsonElement.DeepEquals(expected.GetProperty("prepared"), PreparedContextRequestJson.Element(request)), name);
            Assert.Equal(expected.GetProperty("evidenceSections").GetInt32(), request.Messages.SelectMany(m => m.Sections).Count(s => s.Kind == "evidence"));
            Assert.Equal(expected.GetProperty("citationMap").GetArrayLength(), request.CitationMap.Length);
            n++;
        }
        Assert.Equal(3, n);
        // The two shares are distinct inputs to the same kernel: only the evidence target changes.
        var shares = Cases("tuning-build").Where(r => r.GetProperty("name").GetString()!.StartsWith("tuning-share", StringComparison.Ordinal)).ToArray();
        Assert.Equal(2, shares.Length);
    }

    [Fact]
    public void BudgetRejectsAnInvalidShareAndDefaultsToV1()
    {
        var seed = new PackBudgetInput(8192, 1024, 100, null, 16, [new PackBudgetPassage(1, 10, [])], 0, 0, []);
        Assert.Equal("invalidInput", Assert.Throws<ContextPackException>(() => ContextPackAlgorithms.Budget(seed, 10001)).Code);
        Assert.Equal(JsonSerializer.Serialize(ContextPackAlgorithms.Budget(seed, 6000)), JsonSerializer.Serialize(ContextPackAlgorithms.Budget(seed)));
    }

    private sealed class NoEmbedder : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default) =>
            throw new InvalidOperationException("lexical-only test");
    }

    [Fact]
    public async Task TypedRetrievalResolvesOmittedFetchKOnceFromTheSupplier()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("tuning").Id!.Value;
        for (int i = 0; i < 60; i++)
        {
            long sourceId = store.CreateSource(notebookId, SourceType.Text, "s" + i, null, null).Id!.Value;
            string text = "needle document " + i;
            store.CommitForegroundRevision(sourceId, new RevisionDraft(EvalCorpusHash(text), text, 1, 2), ScalarChunker.Chunk(text), 1, "t" + i);
        }
        int supplied = 0;
        var retriever = new Retriever(store, new NoEmbedder(), () => "m", new VectorMatrixCache(), null, 60,
            () => { supplied++; return 48; });
        using (var pool = await retriever.SearchAsync(notebookId, "needle", new RetrievalScope.All()))
            Assert.Equal(48, pool.Lexical.Count);
        Assert.Equal(1, supplied);
        using (var pool = await retriever.SearchAsync(notebookId, "needle", new RetrievalScope.All(), 7))
            Assert.Equal(7, pool.Lexical.Count);
        Assert.Equal(1, supplied);
        using (var pool = await retriever.SearchAsync(notebookId, "needle", new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long>())))
            Assert.Empty(pool.Fused);
        Assert.Equal(1, supplied);
        await Assert.ThrowsAsync<RetrievalException>(() => retriever.SearchAsync(notebookId, "needle",
            new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long>()), 0));
    }

    private static string EvalCorpusHash(string text) => AINotebook.Core.Eval.EvalCorpus.Sha256(Encoding.UTF8.GetBytes(text));
}
