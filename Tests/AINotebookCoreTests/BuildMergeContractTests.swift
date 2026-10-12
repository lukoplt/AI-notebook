import Foundation
import XCTest
@testable import AINotebookCore

/// Decodes the job/generation rows shared by `ingestion-build-merge-v1` and `indexing-status-v1` §8.
enum BuildMergeFixture {
    static func selection(_ value: Any?) throws -> EmbeddingSelection {
        let row = try XCTUnwrap(value as? [String: Any])
        return EmbeddingSelection(providerId: row["providerId"] as! String, endpointRevision: row["endpointRevision"] as! String,
            model: row["model"] as! String, modelDigest: row["modelDigest"] as? String, dims: (row["dims"] as? NSNumber)?.intValue,
            normalization: row["normalization"] as! String, queryFormatVersion: row["queryFormatVersion"] as! String,
            docFormatVersion: row["docFormatVersion"] as! String, chunkerVersion: row["chunkerVersion"] as! String)
    }

    static func identity(_ value: Any?) throws -> GenerationIdentity {
        try XCTUnwrap(selection(value).identity)
    }

    static func generations(_ value: Any?) throws -> [GenerationSnapshot] {
        try XCTUnwrap(value as? [[String: Any]]).map {
            GenerationSnapshot(id: ($0["id"] as! NSNumber).int64Value, state: $0["state"] as! String, identity: try identity($0["identity"]))
        }
    }

    static func job(_ value: Any?) throws -> EmbedJobSnapshot {
        let row = try XCTUnwrap(value as? [String: Any])
        let options = try (row["options"] as? [String: Any]).map {
            EmbedJobOptions(selection: try selection($0["selection"]), copyExisting: $0["copyExisting"] as! Bool)
        }
        return EmbedJobSnapshot(id: (row["id"] as! NSNumber).int64Value, target: row["target"] as! String,
                                state: row["state"] as! String, attempts: (row["attempts"] as! NSNumber).intValue,
                                nextRetryAt: (row["nextRetryAt"] as? NSNumber)?.int64Value, error: row["error"] as? String,
                                options: options)
    }

    static func jobs(_ value: Any?) throws -> [EmbedJobSnapshot] {
        try XCTUnwrap(value as? [Any]).map(job)
    }
}

/// Shared `ingestion-build-merge-v1` fixture: pure merge decisions.
final class BuildMergeContractTests: XCTestCase {
    private func cases(_ operation: String) throws -> [[String: Any]] {
        let fixture = try SharedFixtures.json("contracts/ingestion-build-merge-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-build-merge")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        return try XCTUnwrap(fixture["cases"] as? [[String: Any]]).filter { $0["operation"] as? String == operation }
    }

    func testResolveMatchesFixture() throws {
        let rows = try cases("resolve")
        XCTAssertGreaterThanOrEqual(rows.count, 15)
        for row in rows {
            let input = try XCTUnwrap(row["input"] as? [String: Any])
            let resolved = EmbedJobPlanning.resolveBuild(selection: try BuildMergeFixture.selection(input["selection"]),
                copyExisting: input["copyExisting"] as! Bool, generations: try BuildMergeFixture.generations(input["generations"]))
            let expected = (row["expected"] as? [String: Any])?["generationId"] as? NSNumber
            XCTAssertEqual(resolved?.id, expected?.int64Value, row["name"] as! String)
        }
    }

    func testSupersedeMatchesFixture() throws {
        let rows = try cases("supersede")
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        for row in rows {
            let input = try XCTUnwrap(row["input"] as? [String: Any])
            let ids = EmbedJobPlanning.superseded(identity: try BuildMergeFixture.identity(input["identity"]),
                                                  jobs: try BuildMergeFixture.jobs(input["jobs"]))
            XCTAssertEqual(ids, try XCTUnwrap(row["expected"] as? [NSNumber]).map(\.int64Value), row["name"] as! String)
        }
    }

    func testStartupMatchesFixture() throws {
        let rows = try cases("startup")
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for row in rows {
            let input = try XCTUnwrap(row["input"] as? [String: Any])
            let action = EmbedJobPlanning.startup(job: try BuildMergeFixture.job(input["job"]),
                                                  generations: try BuildMergeFixture.generations(input["generations"]),
                                                  needsEmbedding: input["needsEmbedding"] as! Bool)
            XCTAssertEqual(action.rawValue, row["expected"] as? String, row["name"] as! String)
        }
    }
}
