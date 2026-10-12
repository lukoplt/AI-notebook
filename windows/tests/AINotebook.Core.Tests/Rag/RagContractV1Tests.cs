using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class RagContractV1Tests
{
    private static void AssertSection(string name, object actual)
    {
        var expected = SharedFixtures.Json("contracts/constants-v1.json").GetProperty(name);
        // Comparing the whole object also detects missing or newly added fixture keys.
        Assert.True(JsonElement.DeepEquals(expected, JsonSerializer.SerializeToElement(actual)), name);
    }

    [Fact]
    public void ScanMatchesEveryFixtureKey() => AssertSection("scan", new
    {
        maxFileBytes = RagContractV1.Scan.MaxFileBytes,
        maxOfficeDecompressedBytes = RagContractV1.Scan.MaxOfficeDecompressedBytes,
        maxExtractedChars = RagContractV1.Scan.MaxExtractedChars,
        maxPdfPages = RagContractV1.Scan.MaxPdfPages,
        maxChunksPerFile = RagContractV1.Scan.MaxChunksPerFile,
        extractionConcurrency = RagContractV1.Scan.ExtractionConcurrency,
        periodicReconcileMinutes = RagContractV1.Scan.PeriodicReconcileMinutes,
        watchDebounceMs = RagContractV1.Scan.WatchDebounceMs,
        watchMaxCoalesceMs = RagContractV1.Scan.WatchMaxCoalesceMs,
    });

    [Fact]
    public void DetectorMatchesEveryFixtureKey() => AssertSection("detector", new
    {
        maxUnigrams = RagContractV1.Detector.MaxUnigrams,
        maxBigrams = RagContractV1.Detector.MaxBigrams,
        maxTrigrams = RagContractV1.Detector.MaxTrigrams,
        orderWeights = RagContractV1.Detector.OrderWeights,
        scoreScale = RagContractV1.Detector.ScoreScale,
        lengthBucketStarts = RagContractV1.Detector.LengthBucketStarts,
        minLetters = RagContractV1.Detector.MinLetters,
        minWords = RagContractV1.Detector.MinWords,
        mixedDominanceBp = RagContractV1.Detector.MixedDominanceBp,
    });

    [Fact]
    public void RetrievalMatchesEveryFixtureKey() => AssertSection("retrieval", new
    {
        rrfK = RagContractV1.Retrieval.RrfK,
        fetchK = RagContractV1.Retrieval.FetchK,
        topK = RagContractV1.Retrieval.TopK,
        maxFtsTokens = RagContractV1.Retrieval.MaxFtsTokens,
    });

    [Fact]
    public void CacheMatchesEveryFixtureKey() => AssertSection("cache", new
    {
        globalBudgetBytes = RagContractV1.Cache.GlobalBudgetBytes,
    });

    [Fact]
    public void PackMatchesEveryFixtureKey() => AssertSection("pack", new
    {
        evidenceShareBp = RagContractV1.Pack.EvidenceShareBp,
        mapMaxShareBp = RagContractV1.Pack.MapMaxShareBp,
        noteWebMaxShareBp = RagContractV1.Pack.NoteWebMaxShareBp,
        tokenEstimateHeadroomBp = RagContractV1.Pack.TokenEstimateHeadroomBp,
        diversityPenaltyBp = RagContractV1.Pack.DiversityPenaltyBp,
        maxPassages = RagContractV1.Pack.MaxPassages,
        neighborRadius = RagContractV1.Pack.NeighborRadius,
        previewTurnsInMemory = RagContractV1.Pack.PreviewTurnsInMemory,
        previewMaxBytes = RagContractV1.Pack.PreviewMaxBytes,
    });

    [Fact]
    public void ProvidersMatchesEveryFixtureKey() => AssertSection("providers", new
    {
        defaultRuntimeContext = RagContractV1.Providers.DefaultRuntimeContext,
        defaultMaxOutputTokens = RagContractV1.Providers.DefaultMaxOutputTokens,
    });

    [Fact]
    public void PerfMatchesEveryFixtureKey() => AssertSection("perf", new
    {
        warmRetrievalP95Ms = RagContractV1.Perf.WarmRetrievalP95Ms,
        perfCorpusChunks = RagContractV1.Perf.PerfCorpusChunks,
    });

    [Fact]
    public void RetrievalInvariant()
    {
        Assert.True(RagContractV1.Retrieval.FetchK >= RagContractV1.Retrieval.TopK);
        Assert.True(RagContractV1.Retrieval.TopK > 0);
    }
}
