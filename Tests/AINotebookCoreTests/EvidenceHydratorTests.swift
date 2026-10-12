import XCTest
import GRDB
@testable import AINotebookCore

@MainActor final class EvidenceHydratorTests: XCTestCase {
    func testScalarEvidenceFixture() throws {
        let f = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
        let canonical = f["canonicalText"] as! String
        var executed = 0
        for c in f["cases"] as! [[String:Any]] where c["row"] != nil {
            let name = c["name"] as! String
            let r = c["row"] as! [String:Any]
            let row = ChunkEvidenceRow(reference: .init(chunkId: 1020, sourceId: 1, revisionId: 102, ord: 0),
                canonicalText: r["canonicalText"] as? String ?? canonical,
                chunkText: r["chunkText"] as! String, charStart: r["start"] as? Int,
                charEnd: r["end"] as? Int, pageHint: r["pageHint"] as? Int,
                chunkerVersion: r["chunkerVersion"] as! Int)
            executed += 1
            if let expectedError = c["expectedError"] as? String {
                XCTAssertThrowsError(try EvidenceHydrator.passage(row, isNeighbour: false), name) {
                    XCTAssertEqual(($0 as? RetrievalError)?.rawValue, expectedError, name)
                }
            } else {
                let evidence = try EvidenceHydrator.passage(row, isNeighbour: false)
                XCTAssertEqual(evidence.text, c["expectedText"] as? String, name)
                XCTAssertEqual(evidence.displaySnippet, c["expectedSnippet"] as? String, name)
                let spans = (c["expectedSpans"] as! [[String: Int]]).map {
                    CitationSpan(start: $0["start"]!, end: $0["end"]!, pageFrom: nil, pageTo: nil)
                }
                XCTAssertEqual(evidence.spans, spans, name)
                XCTAssertFalse(evidence.isNeighbour, name)
            }
        }
        XCTAssertEqual(executed, 5)
    }

    func testPublishedNeighboursRetainTheirOwnRevision() async throws {
        let store = try RetrievalFixtureStore.make()
        try seedEvidenceRevision(store)
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
        let hydrator = EvidenceHydrator(reader: store.makeRetrievalReader())
        for name in ["published-neighbours", "old-vector"] {
            let c = try evidenceCase(name)
            let center = reference(c["reference"] as! [String: NSNumber])
            let passages = try await hydrator.hydrate(snapshot, references: [center],
                                                      neighborRadius: c["radius"] as! Int)
            let neighbours = (c["expectedNeighbours"] as! [[String: NSNumber]]).map(reference)
            XCTAssertEqual(passages.map(Tuple.init), [Tuple(center, false)] + neighbours.map { Tuple($0, true) }, name)
            XCTAssertEqual(passages.map(\.reference), [center] + neighbours, name)
            // Neighbours of an old manifest hit stay on the published revision.
            XCTAssertTrue(passages.dropFirst().allSatisfy { $0.reference.revisionId == 102 }, name)
        }
        let expectedText = try evidenceTexts()
        let both = try await hydrator.hydrate(snapshot, references: [
            .init(chunkId: 1020, sourceId: 1, revisionId: 102, ord: 0),
            .init(chunkId: 1021, sourceId: 1, revisionId: 102, ord: 1)], neighborRadius: 1)
        XCTAssertEqual(both.map(Tuple.init), [Tuple(1020, 102, false), Tuple(1021, 102, false), Tuple(1022, 102, true)])
        XCTAssertEqual(both.map(\.text), [1020, 1021, 1022].map { expectedText[$0]! })
        XCTAssertEqual(both.map(\.spans), [(0, 7), (4, 12), (12, 20)].map {
            [CitationSpan(start: $0.0, end: $0.1, pageFrom: nil, pageTo: nil)]
        })
        let none = try await hydrator.hydrate(snapshot, references: [
            .init(chunkId: 1021, sourceId: 1, revisionId: 102, ord: 1)], neighborRadius: 0)
        XCTAssertEqual(none.map(Tuple.init), [Tuple(1021, 102, false)])
        let legacy = try await hydrator.hydrate(snapshot, references: [
            .init(chunkId: 1010, sourceId: 1, revisionId: 101, ord: 0)], neighborRadius: 0)
        XCTAssertEqual(legacy.map(\.text), ["needle revision 101"])
        XCTAssertEqual(legacy.map(\.spans), [[]])
        await snapshot.close()
    }

    func testWrongRevisionFails() async throws {
        let store = try RetrievalFixtureStore.make()
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
        let hydrator = EvidenceHydrator(reader: store.makeRetrievalReader())
        let c = try evidenceCase("wrong-revision")
        let wrong = reference(c["reference"] as! [String: NSNumber])
        let valid = ChunkReference(chunkId: 4010, sourceId: 4, revisionId: 401, ord: 0)
        do {
            _ = try await hydrator.hydrate(snapshot, references: [valid, wrong])
            XCTFail("Mismatched revision hydrated")
        } catch {
            XCTAssertEqual((error as? RetrievalError)?.rawValue, c["expectedError"] as? String)
        }
        do {
            _ = try await hydrator.hydrate(snapshot, references: [valid], neighborRadius: -1)
            XCTFail("Negative radius hydrated")
        } catch { XCTAssertEqual(error as? RetrievalError, .invalidRadius) }
        let empty = try await hydrator.hydrate(snapshot, references: [])
        XCTAssertTrue(empty.isEmpty)
        await snapshot.close()
        // A closed owner rejects new hydration borrows.
        do {
            _ = try await hydrator.hydrate(snapshot, references: [valid])
            XCTFail("Closed snapshot hydrated")
        } catch { XCTAssertEqual(error as? RetrievalError, .closedSnapshot) }
    }

    func testRevokedSourceReturnsNoEvidence() async throws {
        let store = try RetrievalFixtureStore.make()
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
        let c = try evidenceCase("revoked")
        try store.runOnDatabase { db in
            for event in c["events"] as! [[String: Any]] {
                XCTAssertEqual(event["kind"] as? String, "setAvailability")
                try db.execute(sql: "UPDATE sources SET availability=? WHERE id=?",
                    arguments: [event["value"] as! String, (event["sourceId"] as! NSNumber).int64Value])
            }
        }
        let center = reference(c["reference"] as! [String: NSNumber])
        let passages = try await EvidenceHydrator(reader: store.makeRetrievalReader())
            .hydrate(snapshot, references: [center], neighborRadius: 1)
        XCTAssertEqual(passages.map(Tuple.init), (c["expectedPassages"] as! [[String: NSNumber]]).map { Tuple(reference($0), false) })
        XCTAssertTrue(passages.isEmpty)
        await snapshot.close()
    }

    func testQueryPinProtectsRetiredEvidenceUntilClose() async throws {
        let c = try evidenceCase("gc-pin")
        let ref = reference(c["reference"] as! [String: NSNumber])
        let store = try RetrievalFixtureStore.make()
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
        XCTAssertEqual(snapshot.pin.vectorRevisions[ref.sourceId], ref.revisionId)
        XCTAssertEqual(snapshot.pin.lexicalRevisions[ref.sourceId], int(c, "publishedRevisionId"))
        try store.retireGeneration(id: int(c, "retireGenerationId"))
        _ = try store.garbageCollect(notebookId: 1)
        try assertRetained(store, c, retained: true)
        let passages = try await EvidenceHydrator(reader: store.makeRetrievalReader())
            .hydrate(snapshot, references: [ref], neighborRadius: 0)
        XCTAssertEqual(passages.map(\.text), [c["expectedText"] as! String])
        await snapshot.close()
        _ = try store.garbageCollect(notebookId: 1)
        try assertRetained(store, c, retained: false)
    }

    func testCloseDuringHydrationKeepsOperationBorrow() async throws {
        let c = try evidenceCase("gc-pin")
        let ref = reference(c["reference"] as! [String: NSNumber])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = StorePath(fileURL: directory.appendingPathComponent("db.sqlite"))
        let first = try RetrievalFixtureStore.make(path: path)
        let second = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
        defer { try? first.dbQueue.close(); try? second.dbQueue.close() }
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: first, notebookId: 1, scope: .all, modelKey: "m"))
        let gate = HydrationGate()
        let hydrator = EvidenceHydrator(reader: first.makeRetrievalReader(), afterBorrow: { await gate.pause() })
        let hydration = Task { try await hydrator.hydrate(snapshot, references: [ref], neighborRadius: 1) }
        await gate.waitStarted()
        await snapshot.close()
        try second.retireGeneration(id: int(c, "retireGenerationId"))
        _ = try second.garbageCollect(notebookId: 1)
        try assertRetained(second, c, retained: true)
        await gate.resume()
        let passages = try await hydration.value
        XCTAssertEqual(passages.first?.text, c["expectedText"] as? String)
        XCTAssertEqual(passages.first?.reference, ref)
        _ = try second.garbageCollect(notebookId: 1)
        try assertRetained(second, c, retained: false)
    }

    // MARK: - Helpers

    private struct Tuple: Equatable, CustomStringConvertible {
        let chunkId: Int64, revisionId: Int64, isNeighbour: Bool
        init(_ chunkId: Int64, _ revisionId: Int64, _ isNeighbour: Bool) {
            self.chunkId = chunkId; self.revisionId = revisionId; self.isNeighbour = isNeighbour
        }
        init(_ reference: ChunkReference, _ isNeighbour: Bool) {
            self.init(reference.chunkId, reference.revisionId, isNeighbour)
        }
        init(_ passage: EvidencePassage) { self.init(passage.reference, passage.isNeighbour) }
        var description: String { "(\(chunkId),\(revisionId),\(isNeighbour))" }
    }

    private func evidenceCase(_ name: String) throws -> [String: Any] {
        let fixture = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
        return try XCTUnwrap((fixture["cases"] as? [[String: Any]])?.first { $0["name"] as? String == name }, name)
    }

    private func reference(_ value: [String: NSNumber]) -> ChunkReference {
        ChunkReference(chunkId: value["chunkId"]!.int64Value, sourceId: value["sourceId"]!.int64Value,
            revisionId: value["revisionId"]!.int64Value, ord: value["ord"]!.intValue)
    }

    private func int(_ c: [String: Any], _ key: String) -> Int64 { (c[key] as! NSNumber).int64Value }

    private func evidenceTexts() throws -> [Int64: String] {
        let fixture = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
        let scalars = Array((fixture["canonicalText"] as! String).unicodeScalars)
        var result: [Int64: String] = [:]
        for chunk in fixture["chunks"] as! [[String: Any]] {
            let start = chunk["start"] as! Int, end = chunk["end"] as! Int
            result[(chunk["chunkId"] as! NSNumber).int64Value] = String(String.UnicodeScalarView(scalars[start..<end]))
            XCTAssertEqual(result[(chunk["chunkId"] as! NSNumber).int64Value], chunk["chunkText"] as? String)
        }
        return result
    }

    /// Revisions are immutable, so the shared evidence revision replaces the
    /// scope seed's single-chunk revision 102 in one write before pinning.
    private func seedEvidenceRevision(_ store: NotebookStore) throws {
        let f = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
        let source = int(f, "sourceId"), revision = int(f, "revisionId")
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE sources SET current_revision=NULL,published_revision_id=NULL WHERE id=?", arguments: [source])
            try db.execute(sql: "DELETE FROM source_chunks WHERE revision_id=?", arguments: [revision])
            try db.execute(sql: "DELETE FROM source_revisions WHERE id=?", arguments: [revision])
            try db.execute(sql: """
                INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES(?,?,2,'fixture-evidence',?,2,2,'2026-01-01 00:00:00.000')
                """, arguments: [revision, source, f["canonicalText"] as! String])
            for chunk in f["chunks"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end)
                    VALUES(?,?,?,?,?,4,?,?)
                    """, arguments: [int(chunk, "chunkId"), int(chunk, "sourceId"), int(chunk, "revisionId"),
                                     chunk["ord"] as! Int, chunk["chunkText"] as! String, chunk["start"] as! Int, chunk["end"] as! Int])
            }
            try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                           arguments: [revision, revision, source])
        }
    }

    private func assertRetained(_ store: NotebookStore, _ c: [String: Any], retained: Bool,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        try store.runOnDatabase { db in
            let revisions = try Int64.fetchAll(db, sql: "SELECT id FROM source_revisions WHERE source_id=? ORDER BY id",
                                               arguments: [int(c["reference"] as! [String: Any], "sourceId")])
            let chunks = try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks WHERE source_id=? ORDER BY id",
                                            arguments: [int(c["reference"] as! [String: Any], "sourceId")])
            let expectedRevisions = (c[retained ? "retainedRevisionIds" : "survivingRevisionIds"] as! [NSNumber]).map(\.int64Value)
            let expectedChunks = (c[retained ? "retainedChunkIds" : "survivingChunkIds"] as! [NSNumber]).map(\.int64Value)
            XCTAssertEqual(revisions, expectedRevisions, file: file, line: line)
            XCTAssertEqual(chunks, expectedChunks, file: file, line: line)
            let generation = try Int64.fetchOne(db, sql: "SELECT id FROM index_generations WHERE id=?",
                                                arguments: [int(c, "deletedGenerationId")])
            let vector = try Int64.fetchOne(db, sql: "SELECT chunk_id FROM chunk_embeddings WHERE chunk_id=?",
                                            arguments: [int(c, "deletedVectorChunkId")])
            if retained {
                XCTAssertEqual(generation, int(c, "deletedGenerationId"), file: file, line: line)
                XCTAssertEqual(vector, int(c, "deletedVectorChunkId"), file: file, line: line)
            } else {
                XCTAssertNil(generation, file: file, line: line)
                XCTAssertNil(vector, file: file, line: line)
                XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_revisions WHERE id=?",
                                                arguments: [int(c, "deletedRevisionId")]), file: file, line: line)
                XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_chunks WHERE id=?",
                                                arguments: [int(c, "deletedChunkId")]), file: file, line: line)
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=1"),
                               int(c, "publishedRevisionId"), file: file, line: line)
            }
        }
    }
}

/// Deterministic pause point between the hydration borrow and its first read.
private actor HydrationGate {
    private var started = false
    private var released = false
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        starters.forEach { $0.resume() }; starters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { starters.append($0) }
    }
    func resume() {
        released = true
        waiter?.resume(); waiter = nil
    }
}
