import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private actor GenerationActivationBarrier {
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        await withCheckedContinuation { continuation in
            arrivals.append(continuation)
            if arrivals.count == 2 {
                for arrival in arrivals { arrival.resume() }
                arrivals.removeAll()
            }
        }
    }
}

@MainActor
final class GenerationStoreTests: XCTestCase {
    func testSingleActiveAndPinnedRetirement() throws {
        let c = try fixture("single-active")
        let store = try seeded(c)
        let pin = try store.pinQuery(notebookId: 1, modelKey: "m")
        defer { store.releaseQuery(pin) }
        XCTAssertThrowsError(try store.activateGeneration(id: 2, now: 0))
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        for event in events {
            switch event["op"] as? String {
            case "storeEmbedding":
                try store.storeGenerationEmbedding(generationId: number(event, "generationId"), chunkId: number(event, "chunkId"),
                    vector: EmbeddingVector(values: XCTUnwrap(event["vector"] as? [NSNumber]).map(\.floatValue)))
            case "setManifest":
                try store.setManifest(generationId: number(event, "generationId"), entries: XCTUnwrap(event["entries"] as? [[String: Any]]).map(entry))
            case "activate": try store.activateGeneration(id: number(event, "generationId"), now: number(event, "at"))
            default: XCTFail("Unknown initial generation event")
            }
        }
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, try number(expected, "activeId"))
        XCTAssertEqual(try store.generation(id: 1)?.state, expected["previousState"] as? String)
        XCTAssertEqual(try store.generation(id: 2)?.state, expected["newState"] as? String)
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM index_generations WHERE state='active'"), expected["activeCount"] as? Int)
        }
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNotNil(try store.generation(id: 1))
        XCTAssertEqual(try store.pinnedEmbeddings(pin).count, 1)
        store.releaseQuery(pin)
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNil(try store.generation(id: 1))
        XCTAssertNotNil(try store.revision(id: 101))
        try run(fixture("retire"))
        try run(fixture("pin-retains-retired"))
        try run(fixture("release-then-gc"))
    }

    func testActivationPreconditions() throws {
        for name in ["pending-blocks", "missing-vector-blocks", "wrong-dim-blocks", "cross-notebook-blocks", "excluded-requires-reason", "vector-normalization"] {
            try run(fixture(name))
        }
        let store = try seeded(fixture("single-active"))
        let root = try SharedFixtures.json("contracts/storage-generations-v1.json")
        let value = try identity(XCTUnwrap(root["identity"] as? [String: Any]))
        let generation = try store.createGeneration(notebookId: 1, identity: value, now: 0)
        XCTAssertEqual(generation.identity, value)
        XCTAssertEqual(generation.state, "building")
        XCTAssertEqual(generation.createdAt, 0)
        XCTAssertNil(generation.activatedAt)
        XCTAssertEqual(try store.manifest(generationId: generation.id), try store.manifest(generationId: 2))
        let activeBefore = try XCTUnwrap(store.activeGeneration(notebookId: 1))
        let manifestBefore = try store.manifest(generationId: activeBefore.id)
        XCTAssertThrowsError(try store.setManifest(generationId: activeBefore.id, entries: manifestBefore))
        XCTAssertThrowsError(try store.storeGenerationEmbedding(generationId: activeBefore.id, chunkId: 1001, vector: EmbeddingVector(values: [0, 1])))
        XCTAssertThrowsError(try store.activateGeneration(id: activeBefore.id, now: 1))
        XCTAssertEqual(try store.activeGeneration(notebookId: 1), activeBefore)
        XCTAssertEqual(try store.manifest(generationId: activeBefore.id), manifestBefore)
        let mismatching = try store.pinQuery(notebookId: 1, modelKey: "unindexed-model")
        defer { store.releaseQuery(mismatching) }
        XCTAssertNil(mismatching.generationId)
        XCTAssertTrue(mismatching.vectorRevisions.isEmpty)
        XCTAssertEqual(mismatching.lexicalRevisions, [1: 101])
        XCTAssertTrue(try store.pinnedEmbeddings(mismatching).isEmpty)
        // Availability is evaluated again when hydrating an already registered pin.
        let activePin = try store.pinQuery(notebookId: 1, modelKey: value.modelKey)
        defer { store.releaseQuery(activePin) }
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET availability='unavailable' WHERE id=1") }
        XCTAssertTrue(try store.pinnedEmbeddings(activePin).isEmpty)
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET availability='present',eligible=0 WHERE id=1") }
        XCTAssertTrue(try store.pinnedEmbeddings(activePin).isEmpty)
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET eligible=1 WHERE id=1") }
        XCTAssertEqual(try store.pinnedEmbeddings(activePin).map(\.chunkId), [1001])
        try store.runOnDatabase { db in
            try GenerationSQL.copyUnchangedVectors(db, from: activeBefore.id, to: generation.id, excludingChunkId: nil)
        }
        let jobID = try store.enqueueJob(IngestJobDraft(kind: "embed", target: "generation:\(generation.id)", targetRevision: nil), now: 0)
        _ = try XCTUnwrap(store.claimJob(now: 0, leaseToken: "generation-owner", id: jobID))
        XCTAssertThrowsError(try store.runOnDatabase { db in
            try GenerationSQL.activate(db, id: generation.id, fence: JobFence(jobId: jobID, leaseToken: "stale-generation-owner"), now: 1)
        }) {
            XCTAssertEqual($0 as? StorageV19Error, .staleLease)
        }
        XCTAssertEqual(try store.activeGeneration(notebookId: 1), activeBefore)
        XCTAssertEqual(try store.job(id: jobID)?.state, "running")
        try store.runOnDatabase { db in
            try GenerationSQL.activate(db, id: generation.id, fence: JobFence(jobId: jobID, leaseToken: "generation-owner"), now: 1)
        }
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, generation.id)
        XCTAssertEqual(try store.job(id: jobID)?.state, "done")

        let cross = try fixture("cross-notebook-blocks")
        let batchStore = try seeded(cross)
        let excluded = try fixture("excluded-requires-reason")
        let validEvent = try XCTUnwrap((excluded["events"] as? [[String: Any]])?.first {
            ($0["entries"] as? [[String: Any]])?.first?["reason"] as? String == "extract-error"
        })
        let wrongEvent = try XCTUnwrap((cross["events"] as? [[String: Any]])?.first)
        let validEntries = try XCTUnwrap(validEvent["entries"] as? [[String: Any]]).map(entry)
        let invalidEntries = try XCTUnwrap(wrongEvent["entries"] as? [[String: Any]]).map(entry)
        let originalManifest = try batchStore.manifest(generationId: 2)
        XCTAssertThrowsError(try batchStore.setManifest(generationId: 2, entries: validEntries + invalidEntries)) {
            XCTAssertEqual(($0 as? StorageV19Error)?.code, cross["expectedError"] as? String)
        }
        XCTAssertEqual(try batchStore.manifest(generationId: 2), originalManifest)
    }

    func testRevisionChangesRequireReconcile() throws {
        try run(fixture("changed-current-blocks"))
        try run(fixture("new-source-blocks"))
    }

    func testTwoActivationsLeaveOneActive() async throws {
        let c = try fixture("single-active")
        let (store, directory) = try seededFile(c)
        defer { try? FileManager.default.removeItem(at: directory) }
        let predecessor = try XCTUnwrap(store.generation(id: 1))
        let third = try store.createGeneration(notebookId: 1, identity: predecessor.identity, now: 0)
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        let embeddingEvent = try XCTUnwrap(events.first { $0["op"] as? String == "storeEmbedding" })
        let manifestEvent = try XCTUnwrap(events.first { $0["op"] as? String == "setManifest" })
        let activation = try XCTUnwrap(events.first { $0["op"] as? String == "activate" })
        let successor = try number(activation, "generationId")
        for id in [successor, third.id] {
            try store.storeGenerationEmbedding(generationId: id, chunkId: number(embeddingEvent, "chunkId"), vector: vector(XCTUnwrap(embeddingEvent["vector"] as? [Any])))
            try store.setManifest(generationId: id, entries: XCTUnwrap(manifestEvent["entries"] as? [[String: Any]]).map(entry))
        }
        try store.dbQueue.close()
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let first = try DatabaseQueue(path: directory.appendingPathComponent("db.sqlite").path, configuration: configuration)
        let second = try DatabaseQueue(path: directory.appendingPathComponent("db.sqlite").path, configuration: configuration)
        defer { try? first.close(); try? second.close() }
        let barrier = GenerationActivationBarrier()
        let at = try number(activation, "at")
        let a = Task.detached {
            await barrier.arrive()
            try await first.write { db in try GenerationSQL.activate(db, id: successor, fence: nil, now: at) }
        }
        let b = Task.detached {
            await barrier.arrive()
            try await second.write { db in try GenerationSQL.activate(db, id: third.id, fence: nil, now: at) }
        }
        try await a.value
        try await b.value
        let states = try await first.read { db -> [Int64: String] in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id,state FROM index_generations ORDER BY id").map { ($0["id"], $0["state"]) })
        }
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        XCTAssertEqual(states.values.filter { $0 == "active" }.count, expected["activeCount"] as? Int)
        XCTAssertEqual(states[predecessor.id], expected["previousState"] as? String)
        XCTAssertEqual(Set([try XCTUnwrap(states[successor]), try XCTUnwrap(states[third.id])]), ["active", "retired"])
    }

    func testGCProtectedSets() throws {
        for name in ["published-lexical-retained", "building-retained", "cancelled-job-reference"] { try run(fixture(name)) }
        let c = try fixture("cancelled-job-reference")
        let retained = try XCTUnwrap(fixture("building-retained")["expected"] as? [String: Any])
        let removed = try XCTUnwrap(c["expected"] as? [String: Any])
        let jobs = try SharedFixtures.json("contracts/storage-jobs-revisions-v1.json")
        let timeline = try XCTUnwrap((jobs["cases"] as? [[String: Any]])?.first { $0["name"] as? String == "lease-timeline" })
        let timelineExpected = try XCTUnwrap(timeline["expected"] as? [String: Any])
        let snapshots = try XCTUnwrap(timelineExpected["snapshots"] as? [[String: Any]])
        let lease = try number(snapshots[0], "leaseUntil")
        let retry = try number(snapshots[2], "nextRetryAt")
        for state in ["queued", "running", "paused", "retryable-failed", "done", "failed"] {
            let store = try seeded(c)
            let protects = ["queued", "running", "paused", "retryable-failed"].contains(state)
            try store.runOnDatabase { db in
                try db.execute(sql: "UPDATE ingest_jobs SET state=?,lease_until=?,lease_token=?,next_retry_at=? WHERE id=1",
                    arguments: [state == "retryable-failed" ? "failed" : state,
                                state == "running" ? lease : nil, state == "running" ? "live-worker" : nil,
                                state == "retryable-failed" ? retry : nil])
            }
            try store.retireGeneration(id: 1)
            let result = try store.garbageCollect(notebookId: 1)
            try assertGC(result, expected: XCTUnwrap((protects ? retained : removed)["gc"] as? [String: Any]))
            try store.runOnDatabase { db in
                XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT id FROM source_revisions ORDER BY id"), try ids(protects ? retained : removed, "revisionIds"), state)
                XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks ORDER BY id"), try ids(protects ? retained : removed, "chunkIds"), state)
            }
        }
        // A current revision is retained even when publication points elsewhere.
        let currentStore = try seeded(c)
        try currentStore.runOnDatabase { db in
            try db.execute(sql: "DELETE FROM ingest_jobs")
            try db.execute(sql: "UPDATE sources SET current_revision=101 WHERE id=1")
        }
        try currentStore.retireGeneration(id: 1)
        try assertGC(currentStore.garbageCollect(notebookId: 1), expected: XCTUnwrap(retained["gc"] as? [String: Any]))
        XCTAssertNotNil(try currentStore.revision(id: 101))

        // A lexical-only pin protects an older revision without retaining a vector generation.
        let lexicalStore = try seeded(c)
        try lexicalStore.runOnDatabase { db in
            try db.execute(sql: "DELETE FROM ingest_jobs")
            try db.execute(sql: "UPDATE sources SET published_revision_id=101 WHERE id=1")
        }
        let pin = try lexicalStore.pinQuery(notebookId: 1, modelKey: "unindexed-model")
        defer { lexicalStore.releaseQuery(pin) }
        XCTAssertNil(pin.generationId)
        XCTAssertEqual(pin.lexicalRevisions, [1: 101])
        try lexicalStore.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET published_revision_id=102 WHERE id=1") }
        try lexicalStore.retireGeneration(id: 1)
        try assertGC(lexicalStore.garbageCollect(notebookId: 1), expected: XCTUnwrap(retained["gc"] as? [String: Any]))
        XCTAssertNotNil(try lexicalStore.revision(id: 101))
        lexicalStore.releaseQuery(pin)
        _ = try lexicalStore.garbageCollect(notebookId: 1)
        XCTAssertNil(try lexicalStore.revision(id: 101))
        XCTAssertNotNil(try lexicalStore.revision(id: 102))
    }

    func testPinAcrossSecondStoreGC() throws {
        let c = try fixture("pin-cross-store")
        let interleavings = try XCTUnwrap(c["interleavings"] as? [[String]])
        XCTAssertEqual(interleavings.count, 2)
        for order in interleavings {
            let (a, directory) = try seededFile(c)
            let b = try V19TestStore.reopen(at: directory.appendingPathComponent("db.sqlite"), configuredKey: nil)
            defer {
                try? a.dbQueue.close(); try? b.dbQueue.close()
                try? FileManager.default.removeItem(at: directory)
            }
            // MainActor holds registry coordination across each synchronous pin/GC operation.
            // Exercise both possible lock acquisition orders across independent connections.
            if order.first == "storeB.gc.registryLock" { _ = try b.garbageCollect(notebookId: 1) }
            else { XCTAssertEqual(order.first, "storeA.pin.registryLock") }
            try run(c, initialStore: a, otherStore: b)
        }
    }

    func testLegacyIncompleteAndSuccessorCopy() throws {
        let c = try fixture("legacy-partial-preserved")
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["op"] as? String }, ["upgrade", "inspectSource"])
        let (store, directory, _) = try V19TestStore.upgradeCopy(configuredKey: c["configuredModelKey"] as? String)
        defer { try? store.dbQueue.close(); try? FileManager.default.removeItem(at: directory) }
        let sourceID = try number(c, "sourceId")
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        try V19TestStore.assertQueries(store, queries: [
            ["sql": "SELECT e.chunk_id,g.model,g.dims,hex(e.embedding) FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id JOIN index_generations g ON g.id=e.generation_id WHERE c.source_id=\(sourceID) ORDER BY g.model,g.dims,e.chunk_id", "rows": try XCTUnwrap(expected["vectors"])],
            ["sql": "SELECT g.model,g.dims,m.state,m.reason FROM index_generation_manifest m JOIN index_generations g ON g.id=m.generation_id WHERE m.source_id=\(sourceID) ORDER BY g.model,g.dims", "rows": try XCTUnwrap(expected["manifestRows"])]
        ])
        let pin = try store.pinQuery(notebookId: 1, modelKey: XCTUnwrap(c["configuredModelKey"] as? String))
        defer { store.releaseQuery(pin) }
        XCTAssertNil(pin.vectorRevisions[sourceID])
        XCTAssertFalse(try store.pinnedEmbeddings(pin).contains { $0.sourceId == sourceID })
        try run(fixture("copy-successor"))
    }

    private func run(_ c: [String: Any], initialStore: NotebookStore? = nil, otherStore: NotebookStore? = nil) throws {
        let primary = try initialStore ?? seeded(c)
        var pins: [String: QueryPin] = [:]
        defer { for pin in pins.values { primary.releaseQuery(pin) } }
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        var lastGC: GarbageCollectionResult?
        var lastVectors: [StoredEmbedding] = []
        var errorCodes: [Any] = []
        var released = false
        for event in events {
            let store = event["store"] as? String == "B" ? try XCTUnwrap(otherStore) : primary
            let expectedError = event["expectedError"] as? String ?? (events.count == 1 ? c["expectedError"] as? String : nil)
            func perform() throws {
                switch try XCTUnwrap(event["op"] as? String) {
                case "storeEmbedding":
                    try store.storeGenerationEmbedding(generationId: number(event, "generationId"), chunkId: number(event, "chunkId"), vector: vector(XCTUnwrap(event["vector"] as? [Any])))
                case "setManifest":
                    try store.setManifest(generationId: number(event, "generationId"), entries: XCTUnwrap(event["entries"] as? [[String: Any]]).map(entry))
                case "activate": try store.activateGeneration(id: number(event, "generationId"), now: number(event, "at"))
                case "retire": try store.retireGeneration(id: number(event, "generationId"))
                case "reconcile": try store.reconcileManifest(generationId: number(event, "generationId"))
                case "executeSql":
                    try store.runOnDatabase { db in for sql in try XCTUnwrap(event["sql"] as? [String]) { try db.execute(sql: sql) } }
                case "commitForegroundRevision":
                    _ = try store.commitForegroundRevision(sourceId: number(event, "sourceId"), draft: draft(XCTUnwrap(event["draft"] as? [String: Any])),
                        chunks: XCTUnwrap(event["chunks"] as? [[String: Any]]).map(chunk), now: number(event, "at"), leaseToken: XCTUnwrap(event["token"] as? String))
                case "pinQuery":
                    pins[try XCTUnwrap(event["saveAs"] as? String)] = try store.pinQuery(notebookId: number(event, "notebookId"), modelKey: XCTUnwrap(event["modelKey"] as? String))
                case "releaseQuery":
                    let pin = try XCTUnwrap(pins[XCTUnwrap(event["pin"] as? String)])
                    store.releaseQuery(pin); store.releaseQuery(pin)
                    released = true
                case "garbageCollect":
                    lastGC = try store.garbageCollect(notebookId: number(event, "notebookId"))
                    if let ids = expected[released ? "generationIdsAfterRelease" : "generationIdsWhilePinned"] as? [NSNumber] {
                        try store.runOnDatabase { db in XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT id FROM index_generations ORDER BY id"), ids.map(\.int64Value)) }
                    }
                case "pinnedEmbeddings":
                    lastVectors = try store.pinnedEmbeddings(XCTUnwrap(pins[XCTUnwrap(event["pin"] as? String)]))
                case "copyUnchangedVectors":
                    try store.runOnDatabase { db in
                        try GenerationSQL.copyUnchangedVectors(db, from: number(event, "fromGenerationId"), to: number(event, "toGenerationId"),
                            excludingChunkId: (event["excludingChunkId"] as? NSNumber)?.int64Value)
                    }
                case "inspect":
                    let id = try number(event, "generationId")
                    XCTAssertEqual(try store.manifest(generationId: id).first?.state, expected["initialManifestState"] as? String)
                    try store.runOnDatabase { db in
                        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT hex(embedding) FROM chunk_embeddings WHERE generation_id=?", arguments: [id]), expected["initialVectorHex"] as? String)
                    }
                case "inspectEvidence":
                    try store.runOnDatabase { db in
                        let rows = try Int64.fetchAll(db, sql: """
                            SELECT e.chunk_id FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id
                            JOIN index_generation_manifest m ON m.generation_id=e.generation_id AND m.source_id=c.source_id AND m.revision_id=c.revision_id
                            WHERE e.generation_id=? AND m.state='done' ORDER BY e.chunk_id
                            """, arguments: [try number(event, "generationId")])
                        XCTAssertEqual(rows, try ids(expected, "buildingEvidenceChunkIds"))
                    }
                default: XCTFail("Unhandled generation event")
                }
            }
            if let expectedError {
                let active = try primary.activeGeneration(notebookId: 1)
                XCTAssertThrowsError(try perform()) {
                    XCTAssertEqual(($0 as? StorageV19Error)?.code, expectedError)
                }
                XCTAssertEqual(try primary.activeGeneration(notebookId: 1), active)
                errorCodes.append(expectedError)
            } else {
                try perform()
                if event.keys.contains("expectedError") { errorCodes.append(NSNull()) }
            }
        }
        if expected.keys.contains("activeId") {
            XCTAssertEqual(try primary.activeGeneration(notebookId: 1)?.id, (expected["activeId"] as? NSNumber)?.int64Value)
        }
        if let value = expected["state"] as? String { XCTAssertEqual(try primary.generation(id: 1)?.state, value) }
        if let value = expected["previousState"] as? String { XCTAssertEqual(try primary.generation(id: 1)?.state, value) }
        if let value = expected["newState"] as? String { XCTAssertEqual(try primary.generation(id: 2)?.state, value) }
        if let rows = expected["manifestAfterReconcile"] as? [[String: Any]] { XCTAssertEqual(try primary.manifest(generationId: 2), try rows.map(entry)) }
        if let state = expected["manifestState"] as? String { XCTAssertEqual(try primary.manifest(generationId: 2).first?.state, state) }
        if let reason = expected["reason"] as? String { XCTAssertEqual(try primary.manifest(generationId: 2).first?.reason, reason) }
        if let errors = expected["errors"] as? [Any] { XCTAssertEqual(errorCodes as NSArray, errors as NSArray) }
        if let counts = expected["gc"] as? [String: Any] { try assertGC(XCTUnwrap(lastGC), expected: counts) }
        if let chunkIDs = expected["pinnedChunkIds"] as? [NSNumber] { XCTAssertEqual(lastVectors.map(\.chunkId), chunkIDs.map(\.int64Value)) }
        if let revisionIDs = expected["pinnedRevisionIds"] as? [NSNumber] {
            XCTAssertEqual(try XCTUnwrap(pins["oldPin"]).vectorRevisions.values.sorted(), revisionIDs.map(\.int64Value))
        }
        if let hex = expected["oldVectorHex"] as? String { XCTAssertEqual(lastVectors.first.map { hexString($0.vector.asData()) }, hex) }
        try primary.runOnDatabase { db in
            for (key, table) in ["generationIds": "index_generations", "revisionIds": "source_revisions", "chunkIds": "source_chunks", "jobIds": "ingest_jobs"] {
                if expected[key] != nil { XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY id"), try ids(expected, key), key) }
            }
            let counts = ["activeCount": "SELECT count(*) FROM index_generations WHERE state='active'",
                          "vectorCount": "SELECT count(*) FROM chunk_embeddings WHERE generation_id=2",
                          "manifestRowCount": "SELECT count(*) FROM index_generation_manifest WHERE generation_id=2"]
            for (key, sql) in counts { if let value = expected[key] as? Int { XCTAssertEqual(try Int.fetchOne(db, sql: sql), value, key) } }
            for (key, column) in ["currentRevision": "current_revision", "publishedRevisionId": "published_revision_id"] {
                if let value = expected[key] as? NSNumber { XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT \(column) FROM sources WHERE id=1"), value.int64Value) }
            }
            if let hex = expected["embeddingHex"] as? String {
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT hex(embedding) FROM chunk_embeddings WHERE generation_id=2"), hex)
            }
            if expected["retainedCopiedChunkIds"] != nil {
                XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT chunk_id FROM chunk_embeddings WHERE generation_id=2 ORDER BY chunk_id"), try ids(expected, "retainedCopiedChunkIds"))
            }
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    private func assertGC(_ actual: GarbageCollectionResult, expected: [String: Any]) throws {
        XCTAssertEqual(actual.generations, expected["generations"] as? Int)
        XCTAssertEqual(actual.revisions, expected["revisions"] as? Int)
        XCTAssertEqual(actual.chunks, expected["chunks"] as? Int)
        XCTAssertEqual(actual.vectors, expected["vectors"] as? Int)
    }

    private func identity(_ value: [String: Any]) throws -> GenerationIdentity {
        GenerationIdentity(providerId: try XCTUnwrap(value["providerId"] as? String), endpointRevision: try XCTUnwrap(value["endpointRevision"] as? String),
            model: try XCTUnwrap(value["model"] as? String), modelDigest: value["modelDigest"] as? String, dims: try XCTUnwrap(value["dims"] as? Int),
            normalization: try XCTUnwrap(value["normalization"] as? String), queryFormatVersion: try XCTUnwrap(value["queryFormatVersion"] as? String),
            docFormatVersion: try XCTUnwrap(value["docFormatVersion"] as? String), chunkerVersion: try XCTUnwrap(value["chunkerVersion"] as? String))
    }

    private func vector(_ values: [Any]) throws -> EmbeddingVector {
        EmbeddingVector(values: try values.map {
            if let number = $0 as? NSNumber { return number.floatValue }
            switch try XCTUnwrap($0 as? String) {
            case "NaN": return Float.nan
            case "Infinity": return Float.infinity
            default: throw StorageV19Error.invalidValue
            }
        })
    }

    private func hexString(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    private func ids(_ value: [String: Any], _ key: String) throws -> [Int64] { try XCTUnwrap(value[key] as? [NSNumber]).map(\.int64Value) }

    private func draft(_ value: [String: Any]) throws -> RevisionDraft {
        RevisionDraft(contentHash: try XCTUnwrap(value["contentHash"] as? String), canonicalText: try XCTUnwrap(value["canonicalText"] as? String),
                      textFormatVersion: try XCTUnwrap(value["textFormatVersion"] as? Int), chunkerVersion: try XCTUnwrap(value["chunkerVersion"] as? Int))
    }

    private func chunk(_ value: [String: Any]) throws -> RevisionChunkDraft {
        RevisionChunkDraft(text: try XCTUnwrap(value["text"] as? String), tokenCount: try XCTUnwrap(value["tokenCount"] as? Int), pageHint: value["pageHint"] as? Int,
            charStart: value["charStart"] as? Int, charEnd: value["charEnd"] as? Int, lang: value["lang"] as? String, langInherited: try XCTUnwrap(value["langInherited"] as? Bool))
    }

    private func seededFile(_ c: [String: Any]) throws -> (NotebookStore, URL) {
        let store = try seeded(c)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let url = directory.appendingPathComponent("db.sqlite")
            let queue = try DatabaseQueue(path: url.path)
            try store.dbQueue.backup(to: queue)
            try queue.close(); try store.dbQueue.close()
            return (try V19TestStore.reopen(at: url, configuredKey: nil), directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let root = try SharedFixtures.json("contracts/storage-generations-v1.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let names: Set<String> = ["pending-blocks", "changed-current-blocks", "new-source-blocks", "missing-vector-blocks", "wrong-dim-blocks",
            "cross-notebook-blocks", "excluded-requires-reason", "single-active", "retire", "pin-retains-retired", "release-then-gc",
            "published-lexical-retained", "building-retained", "cancelled-job-reference", "legacy-partial-preserved", "copy-successor",
            "vector-normalization", "pin-cross-store"]
        XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), names)
        XCTAssertTrue(cases.allSatisfy { $0["operation"] as? String == "generation" })
        return try XCTUnwrap(cases.first { $0["name"] as? String == name }, name)
    }

    private func seeded(_ c: [String: Any]) throws -> NotebookStore {
        let store = try V19TestStore.make()
        try store.runOnDatabase { db in
            for sql in try XCTUnwrap(c["setupSql"] as? [String]) { try db.execute(sql: sql) }
        }
        return store
    }

    private func number(_ value: [String: Any], _ key: String) throws -> Int64 {
        try XCTUnwrap(value[key] as? NSNumber, key).int64Value
    }

    private func entry(_ value: [String: Any]) throws -> ManifestEntry {
        ManifestEntry(sourceId: try number(value, "sourceId"), revisionId: try number(value, "revisionId"),
                      state: try XCTUnwrap(value["state"] as? String), reason: value["reason"] as? String)
    }
}
