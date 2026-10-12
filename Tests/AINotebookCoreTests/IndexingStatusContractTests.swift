import Foundation
import XCTest
@testable import AINotebookCore

/// Shared `indexing-status-v1` fixture: pure derivation and availability mapping.
final class IndexingStatusContractTests: XCTestCase {
    private func cases(_ operation: String) throws -> [[String: Any]] {
        let fixture = try SharedFixtures.json("contracts/indexing-status-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "indexing-status")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        return try XCTUnwrap(fixture["cases"] as? [[String: Any]]).filter { $0["operation"] as? String == operation }
    }

    private func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private func string(_ value: Any?) -> String? { value as? String }
    private func null(_ value: Any?) -> Any { value ?? NSNull() }

    private func inputs(_ row: [String: Any]) throws -> IndexingInputs {
        let folders = try XCTUnwrap(row["folders"] as? [[String: Any]]).map {
            IndexingFolderInput(folderId: int64($0["folderId"])!, scanState: $0["scanState"] as! String,
                                lastScanError: string($0["lastScanError"]), filesSeen: int($0["filesSeen"]))
        }
        let job = (row["embedJob"] as? [String: Any]).map {
            IndexingEmbedJobInput(state: $0["state"] as! String, attempts: int($0["attempts"])!,
                                  nextRetryAt: int64($0["nextRetryAt"]), errorCode: string($0["errorCode"]),
                                  bootstrap: $0["bootstrap"] as! Bool)
        }
        return IndexingInputs(now: int64(row["now"])!, runtimeError: string(row["runtimeError"]),
            embeddingAvailability: try XCTUnwrap(EmbeddingAvailability(rawValue: row["embeddingAvailability"] as! String)),
            folders: folders, scanJobsPending: int(row["scanJobsPending"])!, extractQueued: int(row["extractQueued"])!,
            extractRunning: int(row["extractRunning"])!, sourcesTotal: int(row["sourcesTotal"])!,
            sourcesReady: int(row["sourcesReady"])!, sourcesError: int(row["sourcesError"])!,
            needsEmbedding: row["needsEmbedding"] as! Bool, embedJob: job,
            embedChunksDone: int(row["embedChunksDone"])!, embedChunksTotal: int(row["embedChunksTotal"])!,
            memoryPressure: try XCTUnwrap(MemoryPressureLevel(rawValue: row["memoryPressure"] as! String)))
    }

    /// Canonical projection (contract §3).
    static func project(_ status: IndexingStatus) -> [String: Any] {
        var out: [String: Any] = ["phase": status.phase.name, "filesSeen": NSNull(), "done": NSNull(), "total": NSNull(),
                                  "preparing": false, "retry": NSNull(), "blockedReason": NSNull(), "errorCode": NSNull(),
                                  "memoryPressure": status.memoryPressure?.rawValue ?? NSNull(),
                                  "scanInProgress": status.scanInProgress,
                                  "sourceErrors": status.sourceErrors, "isActive": status.isActive,
                                  "scanWarnings": status.scanWarnings.map {
                                      ["folderId": $0.folderId, "state": $0.state, "error": $0.error ?? NSNull()] as [String: Any]
                                  }]
        if status.scanInProgress { out["filesSeen"] = status.scanFilesSeen ?? NSNull() }
        switch status.phase {
        case .scanning(let seen): out["filesSeen"] = seen ?? NSNull()
            XCTAssertEqual(seen, status.scanFilesSeen)
        case .extracting(let done, let total): out["done"] = done; out["total"] = total
        case .embedding(let done, let total, let preparing):
            out["done"] = done ?? NSNull(); out["total"] = total ?? NSNull(); out["preparing"] = preparing
        case .retrying(let retry):
            out["retry"] = ["code": retry.code, "retryAt": retry.retryAt, "attempt": retry.attempt,
                            "retryInSeconds": retry.retryInSeconds] as [String: Any]
        case .blocked(let reason):
            out["blockedReason"] = reason.name; out["errorCode"] = reason.errorCode ?? NSNull()
        case .ready, .lexicalOnly, .empty: break
        }
        return out
    }

    func testDerivationMatchesFixture() throws {
        let rows = try cases("derive")
        XCTAssertGreaterThanOrEqual(rows.count, 40)
        for row in rows {
            let name = row["name"] as! String
            let status = IndexingStatus.derive(try inputs(try XCTUnwrap(row["input"] as? [String: Any])))
            XCTAssertEqual(NSDictionary(dictionary: Self.project(status)),
                           NSDictionary(dictionary: try XCTUnwrap(row["expected"] as? [String: Any])), name)
        }
    }

    func testAvailabilityMatchesFixture() throws {
        let rows = try cases("availability")
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        struct KeyFailure: Error {}
        for row in rows {
            let name = row["name"] as! String
            let input = try XCTUnwrap(row["input"] as? [String: Any])
            let supports = input["supportsEmbeddings"] as! Bool, cloud = input["cloud"] as! Bool
            let type: ProviderType = !supports ? .anthropic : (cloud ? .openaiCompatible : .ollama)
            XCTAssertEqual(type.supportsEmbeddings, supports, name)
            XCTAssertEqual(type.isCloud, cloud, name)
            var config = ProviderConfig(id: "p", type: type, name: "P",
                                        baseURL: cloud ? "https://e.example/v1" : "http://127.0.0.1:11434",
                                        privacyAcknowledged: input["privacyAcknowledged"] as! Bool)
            config.enabled = input["enabled"] as! Bool
            var loads = 0
            let fails = input["keyLoadFails"] as! Bool
            let (availability, _) = FolderEmbeddingSession.availability(
                config: (input["configured"] as! Bool) ? config : nil, model: input["model"] as! String,
                loadKey: { loads += 1; if fails { throw KeyFailure() }; return cloud ? "k" : nil })
            XCTAssertEqual(availability.rawValue, row["expected"] as? String, name)
            if availability != .ready && availability != .credentialUnavailable {
                XCTAssertEqual(loads, 0, "\(name): the key is loaded only after every cheaper check")
            }
        }
    }

    /// Addendum §8: the embed job behind `embedJob` and the generation behind the chunk counts.
    func testEmbedJobSelectionMatchesFixture() throws {
        let rows = try cases("embedJob")
        XCTAssertGreaterThanOrEqual(rows.count, 15)
        for row in rows {
            let name = row["name"] as! String
            let input = try XCTUnwrap(row["input"] as? [String: Any])
            let selected = EmbedJobPlanning.statusJob(jobs: try BuildMergeFixture.jobs(input["jobs"]),
                                                      generations: try BuildMergeFixture.generations(input["generations"]))
            let job: Any = selected.map {
                ["state": $0.job.state, "attempts": $0.job.attempts, "nextRetryAt": null($0.job.nextRetryAt),
                 "errorCode": null($0.job.error), "bootstrap": $0.bootstrap] as [String: Any]
            } ?? NSNull()
            let actual: [String: Any] = ["embedJob": job, "progressGenerationId": null(selected?.progressGenerationId)]
            XCTAssertEqual(NSDictionary(dictionary: actual),
                           NSDictionary(dictionary: try XCTUnwrap(row["expected"] as? [String: Any])), name)
        }
    }

    func testResolveCapturesSessionOnlyWhenReady() throws {
        let local = ProviderConfig(id: "ollama", type: .ollama, name: "Ollama", baseURL: "http://127.0.0.1:11434")
        let ready = FolderEmbeddingSession.resolve(config: local, model: "nomic-embed-text", loadKey: { nil })
        XCTAssertEqual(ready.availability, .ready)
        XCTAssertEqual(ready.session?.selection.model, "nomic-embed-text")
        let missing = FolderEmbeddingSession.resolve(config: nil, model: "m", loadKey: { nil })
        XCTAssertEqual(missing.availability, .noProvider)
        XCTAssertNil(missing.session)
        let malformed = ProviderConfig(id: "bad", type: .openaiCompatible, name: "Bad", baseURL: "not a url", privacyAcknowledged: true)
        XCTAssertEqual(FolderEmbeddingSession.resolve(config: malformed, model: "m", loadKey: { "k" }).availability, .noProvider)
    }
}
