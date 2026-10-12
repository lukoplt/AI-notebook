namespace AINotebook.Core.Rag;

/// <summary>
/// Frozen cross-platform constants from Tests/fixtures/contracts/constants-v1.json.
/// Integers only; shares are basis points (10,000 bp = 100%).
/// </summary>
public static class RagContractV1
{
    public static class Scan
    {
        public const long MaxFileBytes = 52_428_800;
        public const long MaxOfficeDecompressedBytes = 209_715_200;
        public const int MaxExtractedChars = 5_000_000;
        public const int MaxPdfPages = 2_000;
        public const int MaxChunksPerFile = 5_000;
        public const int ExtractionConcurrency = 2;
        public const int PeriodicReconcileMinutes = 30;
        public const int WatchDebounceMs = 500;
        public const int WatchMaxCoalesceMs = 5_000;
    }

    public static class Detector
    {
        public const int MaxUnigrams = 256;
        public const int MaxBigrams = 1_024;
        public const int MaxTrigrams = 4_096;
        public static IReadOnlyList<int> OrderWeights { get; } = Array.AsReadOnly<int>([1, 2, 3]);
        public const int ScoreScale = 1_024;
        public static IReadOnlyList<int> LengthBucketStarts { get; } = Array.AsReadOnly<int>([12, 32, 80, 200]);
        public const int MinLetters = 12;
        public const int MinWords = 3;
        public const int MixedDominanceBp = 7_000;
    }

    public static class Retrieval
    {
        public const int RrfK = 60;
        public const int FetchK = 32;
        public const int TopK = 16;
        public const int MaxFtsTokens = 32;
    }

    public static class Cache
    {
        public const long GlobalBudgetBytes = 536_870_912;
    }

    public static class Pack
    {
        public const int EvidenceShareBp = 6_000;
        public const int MapMaxShareBp = 1_500;
        public const int NoteWebMaxShareBp = 1_500;
        public const int TokenEstimateHeadroomBp = 1_500;
        public const int DiversityPenaltyBp = 9_000;
        public const int MaxPassages = 40;
        public const int NeighborRadius = 1;
        public const int PreviewTurnsInMemory = 5;
        public const long PreviewMaxBytes = 33_554_432;
    }

    public static class Providers
    {
        public const int DefaultRuntimeContext = 8_192;
        public const int DefaultMaxOutputTokens = 1_024;
    }

    public static class Perf
    {
        public const int WarmRetrievalP95Ms = 300;
        public static IReadOnlyList<int> PerfCorpusChunks { get; } = Array.AsReadOnly<int>([100_000, 200_000]);
    }
}
