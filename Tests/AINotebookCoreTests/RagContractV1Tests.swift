import XCTest
@testable import AINotebookCore

/// The in-code constants must equal the frozen shared fixture — the Windows
/// suite runs the same comparison, which is what keeps the platforms equal.
final class RagContractV1Tests: XCTestCase {
    private func section(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try SharedFixtures.json("contracts/constants-v1.json")[name] as? [String: Any])
    }

    func testScan() throws {
        let s = try section("scan")
        XCTAssertEqual(Int64(s["maxFileBytes"] as! Int), RagContractV1.Scan.maxFileBytes)
        XCTAssertEqual(Int64(s["maxOfficeDecompressedBytes"] as! Int), RagContractV1.Scan.maxOfficeDecompressedBytes)
        XCTAssertEqual(s["maxExtractedChars"] as? Int, RagContractV1.Scan.maxExtractedChars)
        XCTAssertEqual(s["maxPdfPages"] as? Int, RagContractV1.Scan.maxPdfPages)
        XCTAssertEqual(s["maxChunksPerFile"] as? Int, RagContractV1.Scan.maxChunksPerFile)
        XCTAssertEqual(s["extractionConcurrency"] as? Int, RagContractV1.Scan.extractionConcurrency)
        XCTAssertEqual(s["periodicReconcileMinutes"] as? Int, RagContractV1.Scan.periodicReconcileMinutes)
        XCTAssertEqual(s["watchDebounceMs"] as? Int, RagContractV1.Scan.watchDebounceMs)
        XCTAssertEqual(s["watchMaxCoalesceMs"] as? Int, RagContractV1.Scan.watchMaxCoalesceMs)
    }

    func testDetector() throws {
        let d = try section("detector")
        XCTAssertEqual(d["maxUnigrams"] as? Int, RagContractV1.Detector.maxUnigrams)
        XCTAssertEqual(d["maxBigrams"] as? Int, RagContractV1.Detector.maxBigrams)
        XCTAssertEqual(d["maxTrigrams"] as? Int, RagContractV1.Detector.maxTrigrams)
        XCTAssertEqual(d["orderWeights"] as? [Int], RagContractV1.Detector.orderWeights)
        XCTAssertEqual(d["scoreScale"] as? Int, RagContractV1.Detector.scoreScale)
        XCTAssertEqual(d["lengthBucketStarts"] as? [Int], RagContractV1.Detector.lengthBucketStarts)
        XCTAssertEqual(d["minLetters"] as? Int, RagContractV1.Detector.minLetters)
        XCTAssertEqual(d["minWords"] as? Int, RagContractV1.Detector.minWords)
        XCTAssertEqual(d["mixedDominanceBp"] as? Int, RagContractV1.Detector.mixedDominanceBp)
    }

    func testRetrievalCacheProvidersPerf() throws {
        let r = try section("retrieval")
        XCTAssertEqual(r["rrfK"] as? Int, RagContractV1.Retrieval.rrfK)
        XCTAssertEqual(r["fetchK"] as? Int, RagContractV1.Retrieval.fetchK)
        XCTAssertEqual(r["topK"] as? Int, RagContractV1.Retrieval.topK)
        XCTAssertEqual(r["maxFtsTokens"] as? Int, RagContractV1.Retrieval.maxFtsTokens)
        XCTAssertEqual(Int64(try section("cache")["globalBudgetBytes"] as! Int), RagContractV1.Cache.globalBudgetBytes)
        XCTAssertEqual(try section("providers")["defaultRuntimeContext"] as? Int, RagContractV1.Providers.defaultRuntimeContext)
        XCTAssertEqual(try section("providers")["defaultMaxOutputTokens"] as? Int, RagContractV1.Providers.defaultMaxOutputTokens)
        let p = try section("perf")
        XCTAssertEqual(p["warmRetrievalP95Ms"] as? Int, RagContractV1.Perf.warmRetrievalP95Ms)
        XCTAssertEqual(p["perfCorpusChunks"] as? [Int], RagContractV1.Perf.perfCorpusChunks)
    }

    func testPack() throws {
        let p = try section("pack")
        XCTAssertEqual(p["evidenceShareBp"] as? Int, RagContractV1.Pack.evidenceShareBp)
        XCTAssertEqual(p["mapMaxShareBp"] as? Int, RagContractV1.Pack.mapMaxShareBp)
        XCTAssertEqual(p["noteWebMaxShareBp"] as? Int, RagContractV1.Pack.noteWebMaxShareBp)
        XCTAssertEqual(p["tokenEstimateHeadroomBp"] as? Int, RagContractV1.Pack.tokenEstimateHeadroomBp)
        XCTAssertEqual(p["diversityPenaltyBp"] as? Int, RagContractV1.Pack.diversityPenaltyBp)
        XCTAssertEqual(p["maxPassages"] as? Int, RagContractV1.Pack.maxPassages)
        XCTAssertEqual(p["neighborRadius"] as? Int, RagContractV1.Pack.neighborRadius)
        XCTAssertEqual(p["previewTurnsInMemory"] as? Int, RagContractV1.Pack.previewTurnsInMemory)
        XCTAssertEqual(Int64(p["previewMaxBytes"] as! Int), RagContractV1.Pack.previewMaxBytes)
    }

    func testRetrievalInvariant() {
        XCTAssertGreaterThanOrEqual(RagContractV1.Retrieval.fetchK, RagContractV1.Retrieval.topK)
        XCTAssertGreaterThan(RagContractV1.Retrieval.topK, 0)
    }
}
