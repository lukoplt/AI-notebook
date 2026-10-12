import XCTest
@testable import AINotebookCore

/// Shared helpers for WP7 benchmark fixture tests (`docs/contracts/benchmark-v1.md`).
enum BenchmarkFixture {
    static func cases(_ file: String, kind: String) throws -> [[String: Any]] {
        let root = try SharedFixtures.json("contracts/" + file)
        return (root["cases"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == kind }
    }

    /// Converts a fixture vector element; nonfinite values are string sentinels.
    static func float(_ value: Any) -> Float {
        switch value {
        case let s as String where s == "NaN": return .nan
        case let s as String where s == "Infinity": return .infinity
        case let s as String where s == "-Infinity": return -.infinity
        case let n as NSNumber: return n.floatValue
        default:
            XCTFail("unexpected vector element \(value)")
            return .nan
        }
    }

    static func vector(_ value: Any?) -> [Float] { (value as? [Any] ?? []).map(float) }

    static func assertMillionths(_ actual: [Float], _ expected: Any?, _ name: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let want = (expected as? [NSNumber] ?? []).map { $0.doubleValue / 1_000_000 }
        XCTAssertEqual(actual.count, want.count, name, file: file, line: line)
        for (a, w) in zip(actual, want) {
            XCTAssertLessThanOrEqual(abs(Double(a) - w), 1e-6, name, file: file, line: line)
        }
    }

    static func errorCode(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch let e as EmbeddingProfileError { return e.code }
        catch { return "unexpected:\(error)" }
    }
}

final class EmbeddingProfileTests: XCTestCase {
    private let file = "embedding-profiles-v1.json"

    func testBundledCatalogEqualsSharedFixtureCatalog() throws {
        let root = try SharedFixtures.json("contracts/" + file)
        let data = try JSONSerialization.data(withJSONObject: root["profiles"] as Any)
        let fixture = try JSONDecoder().decode([EmbeddingProfile].self, from: data)
        let bundled = try EmbeddingProfiles.bundled()
        XCTAssertEqual(bundled, fixture)
        XCTAssertEqual(bundled.map(\.id), ["nomic-v2-256", "nomic-v2-768", "qwen3-06b-256", "qwen3-06b-512",
                                           "qwen3-06b-1024", "bge-m3-1024", "paraphrase-768"])
        XCTAssertEqual(bundled.first { $0.id == "paraphrase-768" }?.ceilingSource, "ollama-512")
    }

    func testSharedFormats() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "format")
        XCTAssertFalse(rows.isEmpty)
        for c in rows {
            let p = try EmbeddingProfiles.require(c["profileId"] as! String)
            let purpose = EmbeddingPurpose(rawValue: c["purpose"] as! String)!
            XCTAssertEqual(p.format(c["text"] as! String, purpose: purpose), c["expected"] as? String, c["name"] as! String)
            XCTAssertEqual(p.formatVersion(purpose), c["formatVersion"] as? String, c["name"] as! String)
        }
    }

    func testSharedFormatVersionsWithEffectiveLimit() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "formatVersion")
        XCTAssertFalse(rows.isEmpty)
        for c in rows {
            let p = try EmbeddingProfiles.require(c["profileId"] as! String)
            let limit = c["effectiveLimit"] as! Int
            XCTAssertEqual(p.formatVersion(.query, effectiveLimit: limit), c["query"] as? String)
            XCTAssertEqual(p.formatVersion(.document, effectiveLimit: limit), c["document"] as? String)
        }
    }

    func testSharedRequireRejectsUnknownIdsAndModelNames() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "require")
        XCTAssertFalse(rows.isEmpty)
        for c in rows {
            let code = BenchmarkFixture.errorCode { _ = try EmbeddingProfiles.require(c["profileId"] as! String) }
            XCTAssertEqual(code, c["error"] as? String, c["name"] as! String)
        }
    }

    func testSharedIdentityAgreement() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "identity")
        XCTAssertFalse(rows.isEmpty)
        for c in rows {
            let p = try EmbeddingProfiles.require(c["profileId"] as! String)
            let code = BenchmarkFixture.errorCode {
                _ = try p.validateIdentity(model: c["model"] as! String, dims: c["dims"] as! Int,
                                           queryFormatVersion: c["queryFormatVersion"] as! String,
                                           docFormatVersion: c["docFormatVersion"] as! String)
            }
            XCTAssertEqual(code, c["error"] as? String, c["name"] as! String)
        }
        let p = try EmbeddingProfiles.require("bge-m3-1024")
        XCTAssertEqual(try p.validateIdentity(model: "bge-m3", dims: 1024,
                                              queryFormatVersion: p.formatVersion(.query, effectiveLimit: 4096),
                                              docFormatVersion: p.formatVersion(.document, effectiveLimit: 4096)), 4096)
    }

    func testSharedProjection() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "project")
        XCTAssertFalse(rows.isEmpty)
        for c in rows {
            let name = c["name"] as! String
            let input = BenchmarkFixture.vector(c["vector"])
            if let error = c["error"] as? String {
                XCTAssertEqual(BenchmarkFixture.errorCode {
                    _ = try EmbeddingInput.project(input, nativeDims: c["nativeDims"] as! Int, dims: c["dims"] as! Int)
                }, error, name)
            } else {
                let out = try EmbeddingInput.project(input, nativeDims: c["nativeDims"] as! Int, dims: c["dims"] as! Int)
                BenchmarkFixture.assertMillionths(out, c["expectedMillionths"], name)
            }
        }
    }

    func testSharedPooling() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "pool")
        XCTAssertFalse(rows.isEmpty)
        for c in rows {
            let name = c["name"] as! String
            let vectors = (c["vectors"] as! [Any]).map { BenchmarkFixture.vector($0) }
            let weights = c["scalarWeights"] as! [Int]
            if let error = c["error"] as? String {
                XCTAssertEqual(BenchmarkFixture.errorCode { _ = try EmbeddingInput.pool(vectors, scalarWeights: weights) },
                               error, name)
            } else {
                BenchmarkFixture.assertMillionths(try EmbeddingInput.pool(vectors, scalarWeights: weights),
                                                  c["expectedMillionths"], name)
            }
        }
    }

    func testSharedBisect() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "bisect")
        XCTAssertFalse(rows.isEmpty)
        for c in rows {
            let name = c["name"] as! String
            let text = c["text"] as! String
            if let error = c["error"] as? String {
                XCTAssertEqual(BenchmarkFixture.errorCode { _ = try EmbeddingInput.bisect(text) }, error, name)
            } else {
                let (a, b) = try EmbeddingInput.bisect(text)
                XCTAssertEqual(a, c["left"] as? String, name)
                XCTAssertEqual(b, c["right"] as? String, name)
                XCTAssertEqual(a + b, text, name)
            }
        }
    }

    func testProjectionAndCompleteScalarSplit() throws {
        let v = try EmbeddingInput.project([3, 4, 12], nativeDims: 3, dims: 2)
        XCTAssertEqual(v[0], 0.6, accuracy: 0.000001)
        XCTAssertEqual(v[1], 0.8, accuracy: 0.000001)
        let (a, b) = try EmbeddingInput.bisect("ab😀cd")
        XCTAssertEqual(a, "ab"); XCTAssertEqual(b, "😀cd")
        XCTAssertThrowsError(try EmbeddingInput.project([0, 0], nativeDims: 2, dims: 2))
    }

    func testCatalogValidationRejectsReducedDimsWithoutMatryoshkaAndDuplicates() throws {
        let good = try EmbeddingProfiles.bundled()
        XCTAssertNoThrow(try EmbeddingProfiles.validate(good))
        var rows = good
        rows[5] = EmbeddingProfile(id: "bge-m3-1024", model: "bge-m3", tokenizerId: "BAAI/bge-m3", queryPrefix: "",
                                   documentPrefix: "", nativeDims: 1024, dims: 512, maxInputTokens: 8192,
                                   matryoshka: false, ceilingSource: "model-card")
        XCTAssertEqual(BenchmarkFixture.errorCode { try EmbeddingProfiles.validate(rows) }, "invalidProfile")
        XCTAssertEqual(BenchmarkFixture.errorCode { try EmbeddingProfiles.validate(good + [good[0]]) }, "invalidProfile")
        XCTAssertEqual(BenchmarkFixture.errorCode { try EmbeddingProfiles.validate(Array(good.dropLast())) }, "invalidProfile")
    }
}
