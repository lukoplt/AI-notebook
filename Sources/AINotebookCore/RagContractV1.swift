/// Frozen cross-platform constants (contract v1). Mirrors
/// `Tests/fixtures/contracts/constants-v1.json`; RagContractV1Tests and the
/// Windows twin fail if either side drifts. Integers only — shares are basis
/// points (10_000 bp = 100 %), so budget math is identical on both platforms.
public enum RagContractV1 {
    public enum Scan {
        public static let maxFileBytes: Int64 = 52_428_800
        public static let maxOfficeDecompressedBytes: Int64 = 209_715_200
        public static let maxExtractedChars = 5_000_000
        public static let maxPdfPages = 2_000
        public static let maxChunksPerFile = 5_000
        public static let extractionConcurrency = 2
        public static let periodicReconcileMinutes = 30
        public static let watchDebounceMs = 500
        public static let watchMaxCoalesceMs = 5_000
    }
    public enum Detector {
        public static let maxUnigrams = 256
        public static let maxBigrams = 1_024
        public static let maxTrigrams = 4_096
        public static let orderWeights = [1, 2, 3]
        public static let scoreScale = 1_024
        public static let lengthBucketStarts = [12, 32, 80, 200]
        public static let minLetters = 12
        public static let minWords = 3
        public static let mixedDominanceBp = 7_000
    }
    public enum Retrieval {
        public static let rrfK = 60
        public static let fetchK = 32
        public static let topK = 16
        public static let maxFtsTokens = 32
    }
    public enum Cache {
        public static let globalBudgetBytes: Int64 = 536_870_912
    }
    public enum Pack {
        public static let evidenceShareBp = 6_000
        public static let mapMaxShareBp = 1_500
        public static let noteWebMaxShareBp = 1_500
        public static let tokenEstimateHeadroomBp = 1_500
        public static let diversityPenaltyBp = 9_000
        public static let maxPassages = 40
        public static let neighborRadius = 1
        public static let previewTurnsInMemory = 5
        public static let previewMaxBytes: Int64 = 33_554_432
    }
    public enum Providers {
        public static let defaultRuntimeContext = 8_192
        public static let defaultMaxOutputTokens = 1_024
    }
    public enum Perf {
        public static let warmRetrievalP95Ms = 300
        public static let perfCorpusChunks = [100_000, 200_000]
    }
}
