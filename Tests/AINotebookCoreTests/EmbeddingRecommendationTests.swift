import XCTest
@testable import AINotebookCore

final class EmbeddingRecommendationTests: XCTestCase {
    private func decode<T: Decodable>(_ value: Any, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch let e as EmbeddingRecommendationError { return e.code }
        catch let e as EmbeddingProfileError { return e.code }
        catch { return "unexpected:\(error)" }
    }

    func testSharedFreshInstallDecisions() throws {
        let rows = try BenchmarkFixture.cases("embedding-default-v1.json", kind: "install")
        XCTAssertEqual(rows.count, 9)
        for row in rows {
            let input = row["input"] as! [String: Any]
            let evidence = try decode(input["evidence"]!, as: EmbeddingInstallEvidence.self)
            let decision = try decode(input["decision"]!, as: EmbeddingDecision.self)
            let actual = try EmbeddingRecommendation.initial(evidence: evidence, decision: decision)
            let expected = row["expected"] as! [String: Any]
            XCTAssertEqual(actual?.profileId, expected["applyProfileId"] as? String, row["name"] as! String)
        }
    }

    func testSharedInvalidDecisions() throws {
        let rows = try BenchmarkFixture.cases("embedding-default-v1.json", kind: "install-invalid")
        XCTAssertEqual(rows.count, 5)
        for row in rows {
            let input = row["input"] as! [String: Any]
            let evidence = try decode(input["evidence"]!, as: EmbeddingInstallEvidence.self)
            let decision = try decode(input["decision"]!, as: EmbeddingDecision.self)
            XCTAssertEqual(code { _ = try EmbeddingRecommendation.initial(evidence: evidence, decision: decision) },
                           row["error"] as? String, row["name"] as! String)
        }
    }

    func testSharedSelectionAndIdentity() throws {
        for row in try BenchmarkFixture.cases("embedding-default-v1.json", kind: "selection") {
            let s = try EmbeddingRecommendation.selection(profileId: row["profileId"] as! String)
            XCTAssertEqual(s, try decode(row["expected"]!, as: EmbeddingModelChoice.self))
        }
        let rows = try BenchmarkFixture.cases("embedding-default-v1.json", kind: "identity")
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            let name = row["name"] as! String
            let selection = try decode(row["selection"]!, as: EmbeddingModelChoice.self)
            let call = {
                try EmbeddingRecommendation.identity(selection: selection, endpointRevision: row["endpointRevision"] as! String,
                                                     modelDigest: row["modelDigest"] as? String,
                                                     chunkerVersion: row["chunkerVersion"] as! String,
                                                     effectiveLimit: row["effectiveLimit"] as? Int)
            }
            if let error = row["error"] as? String {
                XCTAssertEqual(code { _ = try call() }, error, name)
            } else {
                let e = row["expected"] as! [String: Any]
                XCTAssertEqual(try call(), GenerationIdentity(
                    providerId: e["providerId"] as! String, endpointRevision: e["endpointRevision"] as! String,
                    model: e["model"] as! String, modelDigest: e["modelDigest"] as? String, dims: e["dims"] as! Int,
                    normalization: e["normalization"] as! String, queryFormatVersion: e["queryFormatVersion"] as! String,
                    docFormatVersion: e["docFormatVersion"] as! String, chunkerVersion: e["chunkerVersion"] as! String), name)
            }
        }
    }

    func testIdentityIncludesDimensionAndBothFormats() throws {
        let selection = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        let identity = try EmbeddingRecommendation.identity(selection: selection, endpointRevision: "endpoint-v1:test",
                                                            modelDigest: "sha256:test", chunkerVersion: "1")
        XCTAssertEqual(identity.dims, 256)
        XCTAssertEqual(identity.queryFormatVersion, "wp7:nomic-v2-256:query:split1:scalarpool1:prefixl2:ctx512")
        XCTAssertEqual(identity.docFormatVersion, "wp7:nomic-v2-256:document:split1:scalarpool1:prefixl2:ctx512")
        XCTAssertThrowsError(try EmbeddingRecommendation.identity(
            selection: EmbeddingModelChoice(providerId: selection.providerId, model: "other", profileId: selection.profileId),
            endpointRevision: "endpoint-v1:test", modelDigest: nil, chunkerVersion: "1"))
        XCTAssertThrowsError(try EmbeddingRecommendation.selection(profileId: "nomic-embed-text-v2-moe"))
    }

    func testBundledDecisionIsPendingAndPreservesEveryInstall() throws {
        let decision = try EmbeddingDecision.bundled()
        XCTAssertEqual(decision.status, "pending")
        XCTAssertNil(decision.profileId)
        let fresh = EmbeddingInstallEvidence(databaseExists: false, preferencesExist: false, completedOnboarding: false,
                                             explicitSelection: false, convertedChatOnly: false)
        XCTAssertNil(try EmbeddingRecommendation.initial(evidence: fresh, decision: decision))
    }
}
