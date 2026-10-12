import XCTest
import GRDB
@testable import AINotebookCore

@MainActor final class RetrievalScopeSQLTests: XCTestCase {
    func testAllSharedScopesAndRevisionRules() async throws {
        for c in try RetrievalFixtureStore.cases() where c["events"] == nil {
            let store = try RetrievalFixtureStore.make(c["name"] as! String)
            let scope = try JSONDecoder().decode(RetrievalScope.self,
                from: JSONSerialization.data(withJSONObject: c["scope"]!))
            let snapshot = try ScopeResolver.resolve(store: store,
                notebookId: (c["notebookId"] as! NSNumber).int64Value, scope: scope, modelKey: "m")
            if scope.isEmptySelection {
                XCTAssertNil(snapshot)
                XCTAssertEqual(RetrievalFixtureStore.sqlStatementCount(store), 0)
                continue
            }
            let lease = try XCTUnwrap(snapshot)
            let reader = store.makeRetrievalReader()
            let lexical = try await reader.lexical(lease, expression: "\"needle\"", limit: 32)
            var vector: [Int64] = [], after: Int64 = 0
            while true {
                let page = try await reader.vectorPage(lease, afterChunkId: after, limit: 1)
                if page.isEmpty { break }
                after = page.last!.reference.chunkId
                vector.append(contentsOf: page.map { $0.reference.chunkId })
            }
            XCTAssertEqual(lexical.map(\.chunkId).sorted(), (c["publishedChunkIds"] as! [NSNumber]).map(\.int64Value))
            XCTAssertEqual(vector.sorted(), (c["vectorChunkIds"] as! [NSNumber]).map(\.int64Value))
            await lease.close()
        }
    }

    /// The lexical branch ranks a bounded bm25 window before filtering; when the filters leave
    /// fewer than `limit` rows it widens the window, so out-of-scope matches that rank first
    /// can never hide in-scope ones (same rows and order as an unbounded MATCH).
    func testLexicalWindowWidensPastOutOfScopeMatches() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "w").id)
        let outside = RetrievalSQL.lexicalWindow(limit: 4) + 40
        let ids = try store.runOnDatabase { db -> (Int64, [Int64]) in
            var sources: [Int64] = []
            for (index, count) in [outside, 3].enumerated() {
                try db.execute(sql: "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES (?,'text',?,'ready','2026-10-11 00:00:00.000')",
                               arguments: [notebookId, "s\(index)"])
                let source = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (?,1,?,'',1,2,'2026-10-11 00:00:00.000')
                    """, arguments: [source, "h\(source)"])
                let revision = db.lastInsertedRowID
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?", arguments: [revision, revision, source])
                for ord in 0..<count {
                    try db.execute(sql: "INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id) VALUES (?,?,'needle hay stack',3,?)",
                                   arguments: [source, ord, revision])
                }
                sources.append(source)
            }
            let inside = try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks WHERE source_id=? ORDER BY id", arguments: [sources[1]])
            return (sources[1], inside)
        }
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: notebookId,
            scope: .selection(sourceIds: [ids.0], folderIds: []), modelKey: "m"))
        let lexical = try await store.makeRetrievalReader().lexical(snapshot, expression: "\"needle\"", limit: 4)
        XCTAssertEqual(lexical.map(\.chunkId), ids.1)
        await snapshot.close()
    }

    func testOperationBorrowSurvivesOwnerClose() async throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
        let c = (fixture["cases"] as! [[String:Any]]).first { $0["name"] as? String == "gc-pin" }!
        let r = c["reference"] as! [String:NSNumber]
        let ref = ChunkReference(chunkId:r["chunkId"]!.int64Value, sourceId:r["sourceId"]!.int64Value,
            revisionId:r["revisionId"]!.int64Value, ord:r["ord"]!.intValue)
        let store = try RetrievalFixtureStore.make()
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store:store,notebookId:1,scope:.all,modelKey:"m"))
        let operation = try snapshot.acquireOperation()
        await snapshot.close()
        XCTAssertThrowsError(try snapshot.acquireOperation())
        try store.retireGeneration(id:(c["retireGenerationId"] as! NSNumber).int64Value)
        _ = try store.garbageCollect(notebookId:1)
        let rows = try await store.makeRetrievalReader().evidenceRows(operation,references:[ref])
        XCTAssertEqual(rows.map(\.chunkText), [c["expectedText"] as! String])
        await operation.close()
        _ = try store.garbageCollect(notebookId:1)
        let remaining = try store.runOnDatabase { db in
            try Int.fetchOne(db,sql:"SELECT count(*) FROM source_revisions WHERE id=?",arguments:[ref.revisionId])!
        }
        XCTAssertEqual(remaining,0)
    }

    func testRevocationsAndPublication() async throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-scope-v1.json")
        let seed = try XCTUnwrap(fixture["seed"] as? [String: Any])
        let chunks = try XCTUnwrap(seed["chunks"] as? [[String: Any]])
        let sourceByChunk = Dictionary(uniqueKeysWithValues: chunks.map {
            (($0["id"] as! NSNumber).int64Value, ($0["sourceId"] as! NSNumber).int64Value)
        })
        for c in try RetrievalFixtureStore.cases() where c["events"] != nil {
            let name = c["name"] as! String
            let store = try RetrievalFixtureStore.make(name)
            let scope = try JSONDecoder().decode(RetrievalScope.self,
                from: JSONSerialization.data(withJSONObject: c["scope"]!))
            let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store,
                notebookId: (c["notebookId"] as! NSNumber).int64Value, scope: scope, modelKey: "m"))
            let reader = store.makeRetrievalReader()
            let initialSources = Set(snapshot.sources.map(\.sourceId))
            let initialLexical = try await reader.lexical(snapshot, expression: "\"needle\"", limit: 32)
            let initialVectors = try await reader.vectorPage(snapshot, afterChunkId: 0, limit: 32)
            XCTAssertEqual(initialLexical.map(\.chunkId).sorted(), ids(c, "publishedChunkIds"), name)
            XCTAssertEqual(initialVectors.map { $0.reference.chunkId }.sorted(), ids(c, "vectorChunkIds"), name)

            try RetrievalFixtureStore.applyEvent(name, to: store)
            let lexical = try await reader.lexical(snapshot, expression: "\"needle\"", limit: 32)
            let vectors = try await reader.vectorPage(snapshot, afterChunkId: 0, limit: 32)
            let permitted = try await reader.permittedSourceIds(snapshot)
            let metadata = try await reader.metadata(snapshot)
            XCTAssertEqual(lexical.map(\.chunkId).sorted(), ids(c, "afterPublishedChunkIds"), name)
            XCTAssertEqual(vectors.map { $0.reference.chunkId }.sorted(), ids(c, "afterVectorChunkIds"), name)
            XCTAssertTrue(permitted.isSubset(of: initialSources), name)
            var expectedPermitted = initialSources
            for event in c["events"] as! [[String: Any]] {
                if name.hasPrefix("revoke-") {
                    expectedPermitted.remove((event["sourceId"] as! NSNumber).int64Value)
                }
            }
            XCTAssertEqual(permitted, expectedPermitted, name)
            XCTAssertEqual(metadata.map(\.sourceId).sorted(),
                Set(ids(c, "afterPublishedChunkIds").compactMap { sourceByChunk[$0] }).sorted(), name)
            let evidence = try await reader.evidenceRows(snapshot,
                references: initialLexical + initialVectors.map(\.reference))
            XCTAssertEqual(Set(evidence.map { $0.reference.chunkId }),
                Set(ids(c, "afterPublishedChunkIds") + ids(c, "afterVectorChunkIds")), name)
            XCTAssertEqual(snapshot.generation?.id, (c["active"] as? NSNumber)?.int64Value, name)
            if name == "join-membership" {
                let next = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: scope, modelKey: "m"))
                let joined = try await reader.lexical(next, expression: "\"needle\"", limit: 32)
                let joinedSource = ((c["events"] as! [[String: Any]])[0]["sourceId"] as! NSNumber).int64Value
                XCTAssertFalse(initialSources.contains(joinedSource))
                XCTAssertTrue(joined.contains { $0.sourceId == joinedSource })
                await next.close()
            }
            await snapshot.close()
        }
    }

    func testEpochObservesAllMutationTablesAndRollback() async throws {
        let tables = ["notebooks", "sources", "source_chunks", "source_revisions", "chunk_embeddings",
            "index_generations", "index_generation_manifest", "folder_sources", "source_set_members", "source_set_folders"]
        let insertSQL = [
            "notebooks": "INSERT INTO notebooks(id,name,created_at,updated_at) SELECT 1000,name,created_at,updated_at FROM notebooks WHERE id=1",
            "sources": "INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) SELECT 1000,notebook_id,type,title,status,ingested_at FROM sources WHERE id=1",
            "source_chunks": "INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) SELECT 10000,source_id,revision_id,1,text,token_count FROM source_chunks WHERE id=1010",
            "source_revisions": "INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at) SELECT 1000,source_id,3,content_hash,canonical_text,text_format_version,chunker_version,created_at FROM source_revisions WHERE id=101",
            "chunk_embeddings": "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) SELECT 1020,90,embedding FROM chunk_embeddings WHERE chunk_id=1010 AND generation_id=90",
            "index_generations": "INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,dims,normalization,query_format_version,doc_format_version,chunker_version,state,created_at) SELECT 1000,notebook_id,provider_id,endpoint_revision,model,dims,normalization,query_format_version,doc_format_version,chunker_version,'retired',created_at FROM index_generations WHERE id=90",
            "index_generation_manifest": "INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state) SELECT 91,source_id,revision_id,state FROM index_generation_manifest WHERE generation_id=90 AND source_id=4",
            "folder_sources": "INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at) SELECT 1000,notebook_id,root_path || '-copy',path_identity,display_name,include_exts,ignore_globs,limits,created_at FROM folder_sources WHERE id=10",
            "source_set_members": "INSERT INTO source_set_members(set_id,source_id) VALUES(1,4)",
            "source_set_folders": "INSERT INTO source_set_folders(set_id,folder_id) VALUES(1,20)"
        ]
        let updateColumns = ["notebooks": "name", "sources": "title", "chunk_embeddings": "embedding",
            "index_generations": "model", "index_generation_manifest": "state", "folder_sources": "display_name",
            "source_set_members": "set_id", "source_set_folders": "set_id"]
        for table in tables {
            let store = try RetrievalFixtureStore.make()
            try store.runOnDatabase { db in
                try db.execute(sql: "INSERT INTO source_sets(id,notebook_id,name,created_at) SELECT 1,id,name,created_at FROM notebooks WHERE id=1")
                try db.execute(sql: "INSERT INTO source_set_members(set_id,source_id) VALUES(1,1)")
                try db.execute(sql: "INSERT INTO source_set_folders(set_id,folder_id) VALUES(1,10)")
                let durable = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'rag_%'")
                XCTAssertTrue(durable.isEmpty)
                let temporary = try String.fetchAll(db, sql: "SELECT name FROM sqlite_temp_master WHERE type='trigger' AND name LIKE 'rag_%'")
                XCTAssertEqual(Set(temporary), Set(tables.flatMap { table in
                    ["insert", "update", "delete"].map { "rag_\(table)_\($0)" }
                }))
            }
            let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
            let reader = store.makeRetrievalReader()
            // Observe the atomic counter directly so this validates each UDF
            // trigger, independently of the total_changes fallback.
            let beforeInsert = reader.observedEpoch()
            XCTAssertThrowsError(try store.runOnDatabase { db in
                try db.execute(sql: insertSQL[table]!)
                throw ProbeError.rollback
            }) { XCTAssertEqual($0 as? ProbeError, .rollback) }
            XCTAssertGreaterThan(reader.observedEpoch(), beforeInsert, "insert \(table)")
            if let column = updateColumns[table] {
                let beforeUpdate = reader.observedEpoch()
                try store.runOnDatabase { db in try db.execute(sql: "UPDATE \(table) SET \(column)=\(column)") }
                XCTAssertGreaterThan(reader.observedEpoch(), beforeUpdate, "update \(table)")
            }
            let before = try await reader.currentEpoch(snapshot)
            let rowsBefore = try store.runOnDatabase { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")! }
            XCTAssertGreaterThan(rowsBefore, 0, table)
            XCTAssertThrowsError(try store.runOnDatabase { db in
                try db.execute(sql: "DELETE FROM \(table)")
                throw ProbeError.rollback
            }) { XCTAssertEqual($0 as? ProbeError, .rollback) }
            XCTAssertGreaterThan(reader.observedEpoch(), before, "delete \(table)")
            let after = try await reader.currentEpoch(snapshot)
            XCTAssertGreaterThan(after, before, table)
            let rowsAfter = try store.runOnDatabase { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")! }
            XCTAssertEqual(rowsAfter, rowsBefore, table)
            await snapshot.close()
        }
    }

    func testCrossStoreInvalidationAndGC() async throws {
        let c = try gcCase()
        let reference = reference(c["reference"] as! [String: NSNumber])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = StorePath(fileURL: directory.appendingPathComponent("db.sqlite"))
        let first = try RetrievalFixtureStore.make(path: path)
        let second = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
        defer { try? first.dbQueue.close(); try? second.dbQueue.close() }
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: first, notebookId: 1, scope: .all, modelKey: "m"))
        let reader = first.makeRetrievalReader()
        let before = try await reader.currentEpoch(snapshot)
        let dataVersionBefore = try first.runOnDatabase { db in try Int.fetchOne(db, sql: "PRAGMA data_version")! }
        try second.retireGeneration(id: (c["retireGenerationId"] as! NSNumber).int64Value)
        _ = try second.garbageCollect(notebookId: 1)
        let dataVersionAfter = try first.runOnDatabase { db in try Int.fetchOne(db, sql: "PRAGMA data_version")! }
        XCTAssertNotEqual(dataVersionAfter, dataVersionBefore)
        let after = try await reader.currentEpoch(snapshot)
        XCTAssertGreaterThan(after, before)
        let rows = try await reader.evidenceRows(snapshot, references: [reference])
        XCTAssertEqual(rows.map(\.chunkText), [c["expectedText"] as! String])

        // A plain SQLite connection has no TEMP invalidation triggers. The
        // reader must still notice its commit through PRAGMA data_version.
        let external = try DatabaseQueue(path: path.fileURL!.path)
        try await external.write { db in try db.execute(sql: "UPDATE sources SET title=title || ' external' WHERE id=?", arguments: [reference.sourceId]) }
        try external.close()
        let externalEpoch = try await reader.currentEpoch(snapshot)
        XCTAssertGreaterThan(externalEpoch, after)

        // A new store must not inherit a shared epoch that predates an
        // external commit when existing readers have not observed it yet.
        let externalAgain = try DatabaseQueue(path: path.fileURL!.path)
        try await externalAgain.write { db in
            try db.execute(sql: "UPDATE sources SET title=title || ' again' WHERE id=?", arguments: [reference.sourceId])
        }
        try externalAgain.close()
        let third = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
        let thirdScope = try XCTUnwrap(ScopeResolver.resolve(store: third, notebookId: 1, scope: .all, modelKey: "m"))
        let thirdEpoch = third.makeRetrievalReader().observedEpoch()
        XCTAssertGreaterThan(thirdEpoch, externalEpoch)
        await thirdScope.close()
        try third.dbQueue.close()
        await snapshot.close()
        _ = try second.garbageCollect(notebookId: 1)
        try second.runOnDatabase { db in
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_revisions WHERE id=?", arguments: [reference.revisionId]))
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_chunks WHERE id=?", arguments: [reference.chunkId]))
        }
    }

    func testPagedReaderBoundAndInvalidBlobProgress() async throws {
        let c = try gcCase()
        let reference = reference(c["reference"] as! [String: NSNumber])
        let fixture = try SharedFixtures.json("contracts/retrieval-scope-v1.json")
        let seed = fixture["seed"] as! [String: Any]
        let embedding = (seed["embeddings"] as! [[String: Any]]).first {
            ($0["chunkId"] as! NSNumber).int64Value == reference.chunkId
        }!
        let vector = EmbeddingVector(values: (embedding["vector"] as! [NSNumber]).map(\.floatValue)).asData()
        let generation = (embedding["generationId"] as! NSNumber).int64Value
        let store = try RetrievalFixtureStore.make()
        let firstID: Int64 = 10_000
        let validCount = 2_050, invalidCount = 1_024, prefixCount = 1_024
        try store.runOnDatabase { db in
            // Scan begins at firstID, so the entire middle page is invalid.
            let chunk = try db.makeStatement(sql: "INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) VALUES(?,?,?,?,?,4)")
            let insert = try db.makeStatement(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(?,?,?)")
            for index in 0..<(validCount + invalidCount) {
                let id = firstID + Int64(index)
                try chunk.execute(arguments: [id, reference.sourceId, reference.revisionId, index + 1, c["expectedText"] as! String])
                let malformed = (prefixCount..<(prefixCount + invalidCount)).contains(index)
                try insert.execute(arguments: [id, generation, malformed ? Data([0x01]) : vector])
            }
        }
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
        let operation = try snapshot.acquireOperation()
        let reader = store.makeRetrievalReader()
        var cursor = firstID - 1, scanned = 0, invalid = 0, sawInvalidOnly = false
        for _ in 0..<8 {
            let page = try await reader.rawVectorPage(operation, afterChunkId: cursor, rowLimit: 1_024)
            XCTAssertLessThanOrEqual(page.rows.count, 1_024)
            XCTAssertLessThanOrEqual(page.payloadBytes, 8 * 1_024 * 1_024)
            if !page.rows.isEmpty { XCTAssertGreaterThan(page.lastScannedChunkId, cursor) }
            scanned += page.rows.count
            invalid += page.rows.filter { $0.blob == nil }.count
            sawInvalidOnly = sawInvalidOnly || (!page.rows.isEmpty && page.rows.allSatisfy { $0.blob == nil })
            cursor = page.lastScannedChunkId
            if page.exhausted { break }
        }
        XCTAssertTrue(sawInvalidOnly)
        XCTAssertEqual(scanned, validCount + invalidCount)
        XCTAssertEqual(invalid, invalidCount)
        XCTAssertEqual(cursor, firstID + Int64(validCount + invalidCount - 1))
        var valid: [Int64] = []
        cursor = firstID - 1
        for _ in 0..<8 {
            let page = try await reader.vectorPage(snapshot, afterChunkId: cursor, limit: 1_024)
            if page.isEmpty { break }
            valid += page.map { $0.reference.chunkId }
            cursor = page.last!.reference.chunkId
        }
        XCTAssertEqual(valid.count, validCount)
        XCTAssertEqual(valid.last, firstID + Int64(validCount + invalidCount - 1))
        await operation.close()
        await snapshot.close()

        let rankFixture = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        let oversized = try XCTUnwrap((rankFixture["cases"] as? [[String: Any]])?.first {
            $0["name"] as? String == "oversized-generation"
        })
        let oversizedDims = (oversized["dims"] as! NSNumber).intValue
        let oversizedStore = try RetrievalFixtureStore.make()
        try oversizedStore.runOnDatabase { db in
            try db.execute(sql: "UPDATE index_generations SET dims=? WHERE id=?", arguments: [oversizedDims, generation])
        }
        let oversizedScope = try XCTUnwrap(ScopeResolver.resolve(store: oversizedStore, notebookId: 1, scope: .all, modelKey: "m"))
        let oversizedOperation = try oversizedScope.acquireOperation()
        let oversizedReader = oversizedStore.makeRetrievalReader()
        let beforeReads = RetrievalFixtureStore.sqlStatementCount(oversizedStore)
        let oversizedCount = try await oversizedReader.vectorCount(oversizedScope)
        let oversizedPage = try await oversizedReader.rawVectorPage(oversizedOperation, afterChunkId: 0, rowLimit: 1_024)
        let oversizedFacade = try await oversizedReader.vectorPage(oversizedScope, afterChunkId: 0, limit: 1_024)
        XCTAssertEqual(oversizedCount, 0)
        XCTAssertTrue(oversizedPage.rows.isEmpty)
        XCTAssertTrue(oversizedFacade.isEmpty)
        XCTAssertEqual(oversizedPage.payloadBytes, 0)
        XCTAssertEqual(RetrievalFixtureStore.sqlStatementCount(oversizedStore) - beforeReads,
            (oversized["expectedBlobReads"] as! NSNumber).intValue)
        await oversizedOperation.close()
        await oversizedScope.close()

        // Three 4 MiB vectors require two pages even with a 1024-row request.
        // SQLite zeroblob avoids constructing a large test-side float matrix.
        let wideStore = try RetrievalFixtureStore.make()
        let wideDims = (oversizedDims - 1) / 2
        let byteWidth = wideDims * MemoryLayout<Float>.size
        try wideStore.runOnDatabase { db in
            try db.execute(sql: "UPDATE index_generations SET dims=? WHERE id=?", arguments: [wideDims, generation])
            try db.execute(sql: "UPDATE chunk_embeddings SET embedding=zeroblob(?) WHERE generation_id=?", arguments: [byteWidth, generation])
            try db.execute(sql: "INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) VALUES(?,?,?,?,?,4)",
                arguments: [firstID, reference.sourceId, reference.revisionId, 1, c["expectedText"] as! String])
            try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(?,?,zeroblob(?))",
                arguments: [firstID, generation, byteWidth])
        }
        let wideScope = try XCTUnwrap(ScopeResolver.resolve(store: wideStore, notebookId: 1, scope: .all, modelKey: "m"))
        let wideOperation = try wideScope.acquireOperation()
        let wideReader = wideStore.makeRetrievalReader()
        let firstWide = try await wideReader.rawVectorPage(wideOperation, afterChunkId: 0, rowLimit: 1_024)
        XCTAssertEqual(firstWide.rows.count, 2)
        XCTAssertEqual(firstWide.payloadBytes, 8 * 1_024 * 1_024)
        XCTAssertFalse(firstWide.exhausted)
        let lastWide = try await wideReader.rawVectorPage(wideOperation, afterChunkId: firstWide.lastScannedChunkId, rowLimit: 1_024)
        XCTAssertEqual(lastWide.rows.map { $0.reference.chunkId }, [firstID])
        XCTAssertEqual(lastWide.payloadBytes, byteWidth)
        XCTAssertTrue(lastWide.exhausted)
        await wideOperation.close()
        await wideScope.close()
    }

    func testCallbackFailureDoesNotRegisterPin() async throws {
        let c = try gcCase()
        let reference = reference(c["reference"] as! [String: NSNumber])
        let store = try RetrievalFixtureStore.make()
        XCTAssertThrowsError(try store.withQueryPin(notebookId: 1, modelKey: "m") { _, pin -> Void in
            XCTAssertEqual(pin.vectorRevisions[reference.sourceId], reference.revisionId)
            throw ProbeError.callback
        }) { XCTAssertEqual($0 as? ProbeError, .callback) }
        try store.retireGeneration(id: (c["retireGenerationId"] as! NSNumber).int64Value)
        _ = try store.garbageCollect(notebookId: 1)
        try store.runOnDatabase { db in
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_revisions WHERE id=?", arguments: [reference.revisionId]))
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_chunks WHERE id=?", arguments: [reference.chunkId]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT sum(value) FROM json_each(?)", arguments: ["[1,2,3]"]), 6)
        }
    }

    private enum ProbeError: Error, Equatable { case rollback, callback }

    private func ids(_ fixture: [String: Any], _ key: String) -> [Int64] {
        (fixture[key] as! [NSNumber]).map(\.int64Value)
    }

    private func gcCase() throws -> [String: Any] {
        let fixture = try SharedFixtures.json("contracts/retrieval-evidence-v1.json")
        return try XCTUnwrap((fixture["cases"] as? [[String: Any]])?.first { $0["name"] as? String == "gc-pin" })
    }

    private func reference(_ value: [String: NSNumber]) -> ChunkReference {
        ChunkReference(chunkId: value["chunkId"]!.int64Value, sourceId: value["sourceId"]!.int64Value,
            revisionId: value["revisionId"]!.int64Value, ord: value["ord"]!.intValue)
    }
}
