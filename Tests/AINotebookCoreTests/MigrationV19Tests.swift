import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV19Tests: XCTestCase {
    func testRevisionPagesPreserveEmptyPagesAndRevisionIdentity() throws {
        let store = try V19TestStore.make()
        let notebookID = try XCTUnwrap(store.createNotebook(name: "Pages").id)
        let source = try store.createSource(notebookId: notebookID, type: .pdf,
                                            title: "Pages", uri: nil, rawPath: nil)
        let sourceID = try XCTUnwrap(source.id)
        let first = try store.insertRevision(sourceId: sourceID,
            draft: RevisionDraft(contentHash: "first", canonicalText: "A😀\n\n\n\néZ",
                                 textFormatVersion: 1, chunkerVersion: 2), now: 0)
        XCTAssertEqual(try store.revisionPages(revisionId: first.id), [])
        try store.runOnDatabase { db in
            // Insert in a different order from the immutable page sequence.
            try db.execute(sql: """
                INSERT INTO revision_pages(revision_id,page,char_start,char_end)
                VALUES (?,3,6,9),(?,1,0,2),(?,2,4,4)
                """, arguments: [first.id, first.id, first.id])
        }
        let expected = [PageBoundary(page: 1, start: 0, end: 2),
                        PageBoundary(page: 2, start: 4, end: 4),
                        PageBoundary(page: 3, start: 6, end: 9)]
        XCTAssertEqual(try store.revisionPages(revisionId: first.id), expected)

        let second = try store.insertRevision(sourceId: sourceID,
            draft: RevisionDraft(contentHash: "second", canonicalText: "New",
                                 textFormatVersion: 1, chunkerVersion: 2), now: 1)
        try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES (?,1,0,3)
                """, arguments: [second.id])
            try db.execute(sql: "UPDATE sources SET descriptor='{}' WHERE id=?", arguments: [sourceID])
        }
        XCTAssertEqual(try store.revisionPages(revisionId: first.id), expected)
        XCTAssertEqual(try store.revisionPages(revisionId: second.id), [PageBoundary(page: 1, start: 0, end: 3)])
        XCTAssertEqual(try store.revisionPages(revisionId: Int64.max), [])

        try store.runOnDatabase { db in
            try db.execute(sql: "DELETE FROM source_revisions WHERE id=?", arguments: [first.id])
        }
        XCTAssertEqual(try store.revisionPages(revisionId: first.id), [])
        XCTAssertEqual(try store.revisionPages(revisionId: second.id), [PageBoundary(page: 1, start: 0, end: 3)])
        try store.deleteSource(id: sourceID)
        XCTAssertEqual(try store.revisionPages(revisionId: second.id), [])
    }

    func testRevisionPageSchemaConstraintsAndImmutability() throws {
        let store = try V19TestStore.make()
        let notebookID = try XCTUnwrap(store.createNotebook(name: "Page constraints").id)
        let source = try store.createSource(notebookId: notebookID, type: .pdf,
                                            title: "Pages", uri: nil, rawPath: nil)
        let revision = try store.insertRevision(sourceId: XCTUnwrap(source.id),
            draft: RevisionDraft(contentHash: "pages", canonicalText: "Page",
                                 textFormatVersion: 1, chunkerVersion: 2), now: 0)
        try store.runOnDatabase { db in
            for invalid in [(0, 0, 1), (1, -1, 1), (1, 2, 1)] {
                XCTAssertThrowsError(try db.execute(sql: """
                    INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES (?,?,?,?)
                    """, arguments: [revision.id, invalid.0, invalid.1, invalid.2]))
            }
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES (-1,1,0,1)
                """))
            try db.execute(sql: """
                INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES (?,1,0,4)
                """, arguments: [revision.id])
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES (?,1,4,4)
                """, arguments: [revision.id]))
            for assignment in ["page=2", "char_start=1", "char_end=3", "revision_id=revision_id"] {
                XCTAssertThrowsError(try db.execute(sql: "UPDATE revision_pages SET \(assignment) WHERE revision_id=?",
                                                     arguments: [revision.id])) { error in
                    XCTAssertEqual((error as? DatabaseError)?.message, "immutable revision page")
                }
            }
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertEqual(try store.revisionPages(revisionId: revision.id), [PageBoundary(page: 1, start: 0, end: 4)])
    }

    func testUpgradeDoesNotInventRevisionPages() throws {
        let (store, directory, _) = try V19TestStore.upgradeCopy(configuredKey: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let revisionIDs = try store.runOnDatabase { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM source_revisions ORDER BY id")
        }
        XCTAssertFalse(revisionIDs.isEmpty)
        for revisionID in revisionIDs {
            XCTAssertEqual(try store.revisionPages(revisionId: revisionID), [])
        }
    }

    func testIngestJobOptionsDefaultIsDurableAndNonnullable() throws {
        let store = try V19TestStore.make()
        try store.runOnDatabase { db in
            try db.execute(sql: "INSERT INTO ingest_jobs(kind,target) VALUES ('gc','notebook:1')")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT options_json FROM ingest_jobs"), "{}")
            XCTAssertThrowsError(try db.execute(sql: "UPDATE ingest_jobs SET options_json=NULL"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT options_json FROM ingest_jobs"), "{}")
        }
    }

    func testSharedV18Upgrade() throws {
        let root = try SharedFixtures.json("contracts/storage-v19.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        let fresh = try V19TestStore.make()
        let schemaCase = try XCTUnwrap(cases.first)
        let schemaQueries = try XCTUnwrap(schemaCase["queries"] as? [[String: Any]]).filter {
            let sql = ($0["sql"] as? String ?? "").lowercased()
            return sql.contains("pragma_table_info") || sql.contains("pragma_foreign_key_list")
                || sql.contains("pragma_index_list")
        }
        XCTAssertFalse(schemaQueries.isEmpty)
        try V19TestStore.assertQueries(fresh, queries: schemaQueries)
        let schemaDDL = try XCTUnwrap(root["schemaDDL"] as? String)
        let normalizedDDL = schemaDDL.lowercased().filter { !$0.isWhitespace }
        XCTAssertTrue(normalizedDDL.contains("modeltextnotnullcheck(length(trim(model))>0)"))
        try fresh.runOnDatabase { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            let providerID = try XCTUnwrap(String.fetchOne(db, sql: "SELECT id FROM providers ORDER BY id LIMIT 1"))
            for invalidModel in ["", "   "] {
                XCTAssertThrowsError(try db.execute(sql: """
                    INSERT INTO provider_model_limits(provider_id,model,context_window,runtime_context,max_output_tokens,source)
                    VALUES(?,?,NULL,8192,1024,'auto')
                    """, arguments: [providerID, invalidModel]))
            }
        }
        for c in cases {
            let (store, directory, report) = try V19TestStore.upgradeCopy(configuredKey: c["configuredModelKey"] as? String)
            defer { try? FileManager.default.removeItem(at: directory) }
            let expectedDrops = try XCTUnwrap(c["droppedMalformedByNotebook"] as? [String: Int])
            XCTAssertEqual(report.droppedMalformedByNotebook, Dictionary(uniqueKeysWithValues:
                expectedDrops.map { (Int64($0.key)!, $0.value) }))
            try V19TestStore.assertQueries(store, queries: XCTUnwrap(c["queries"] as? [[String: Any]]))
            try store.runOnDatabase { db in
                XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            }
        }
    }

    func testFTSMirrorsAndImmutability() throws {
        let root = try SharedFixtures.json("contracts/storage-v19.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let fixture = try XCTUnwrap(cases.first { $0["name"] as? String == "configured-a" })
        let (store, directory, _) = try V19TestStore.upgradeCopy(configuredKey: fixture["configuredModelKey"] as? String)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queries = try XCTUnwrap(fixture["queries"] as? [[String: Any]])
        let ftsQueries = queries.filter {
            let name = $0["name"] as? String ?? ""
            return name.hasPrefix("sources_fts-") || name.hasPrefix("chunks_fts-")
        }
        XCTAssertEqual(ftsQueries.count, 6)
        try V19TestStore.assertQueries(store, queries: ftsQueries)

        let notebook = try XCTUnwrap(store.notebooks.first?.id)
        let source = try store.createSource(notebookId: notebook, type: .text,
                                            title: "insertmirror", uri: nil, rawPath: nil)
        let sourceID = try XCTUnwrap(source.id)
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT source_id FROM sources_fts WHERE sources_fts MATCH 'insertmirror'"), [sourceID])
            try db.execute(sql: "UPDATE sources SET title='updatedmirror' WHERE id=?", arguments: [sourceID])
            XCTAssertTrue(try Int64.fetchAll(db, sql: "SELECT source_id FROM sources_fts WHERE sources_fts MATCH 'insertmirror'").isEmpty)
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT source_id FROM sources_fts WHERE sources_fts MATCH 'updatedmirror'"), [sourceID])

            try db.execute(sql: """
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                SELECT id,1,'mirror-hash','chunkmirror',1,2,ingested_at FROM sources WHERE id=?
                """, arguments: [sourceID])
            let revisionID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end)
                VALUES(?,0,'chunkmirror',3,?,0,11)
                """, arguments: [sourceID, revisionID])
            let chunkID = db.lastInsertedRowID
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'chunkmirror'"), [chunkID])

            XCTAssertThrowsError(try db.execute(sql: "UPDATE source_revisions SET canonical_text='changed' WHERE id=?", arguments: [revisionID]))
            XCTAssertThrowsError(try db.execute(sql: "UPDATE source_chunks SET text='changed' WHERE id=?", arguments: [chunkID]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT canonical_text FROM source_revisions WHERE id=?", arguments: [revisionID]), "chunkmirror")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT text FROM source_chunks WHERE id=?", arguments: [chunkID]), "chunkmirror")

            try db.execute(sql: "UPDATE source_chunks SET context='derived context' WHERE id=?", arguments: [chunkID])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT context FROM source_chunks WHERE id=?", arguments: [chunkID]), "derived context")

            // Isolate the FTS UPDATE body from production immutability, then
            // restore both the trigger and original text by rolling back.
            try db.execute(sql: "SAVEPOINT fts_update_mirror")
            do {
                try db.execute(sql: "DROP TRIGGER chunks_immutable")
                try db.execute(sql: "UPDATE source_chunks SET text='changedmirror' WHERE id=?", arguments: [chunkID])
                XCTAssertTrue(try Int64.fetchAll(db, sql: "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'chunkmirror'").isEmpty)
                XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'changedmirror'"), [chunkID])
            } catch {
                try db.execute(sql: "ROLLBACK TO fts_update_mirror")
                try db.execute(sql: "RELEASE fts_update_mirror")
                throw error
            }
            try db.execute(sql: "ROLLBACK TO fts_update_mirror")
            try db.execute(sql: "RELEASE fts_update_mirror")
            XCTAssertThrowsError(try db.execute(sql: "UPDATE source_chunks SET text='still immutable' WHERE id=?", arguments: [chunkID]))
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'chunkmirror'"), [chunkID])
            try db.execute(sql: "DELETE FROM source_chunks WHERE id=?", arguments: [chunkID])
            XCTAssertTrue(try Int64.fetchAll(db, sql: "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'chunkmirror'").isEmpty)
        }
        try store.deleteSource(id: sourceID)
        try store.runOnDatabase { db in
            XCTAssertTrue(try Int64.fetchAll(db, sql: "SELECT source_id FROM sources_fts WHERE sources_fts MATCH 'updatedmirror'").isEmpty)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testUpgradeRollback() throws {
        let root = try SharedFixtures.json("contracts/storage-v19.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let fixture = try XCTUnwrap(cases.first { $0["name"] as? String == "configured-a" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollback.sqlite")
        try FileManager.default.copyItem(at: SharedFixtures.url("storage/v18.sqlite"), to: url)
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        let originalVectors = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT chunk_id,dim,model,hex(embedding) AS bytes FROM chunk_embeddings ORDER BY chunk_id")
        }
        let originalCitations = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id,citations_json FROM messages ORDER BY id")
        }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys=OFF")
            do {
                try db.execute(sql: "UPDATE source_chunks SET source_id=-1 WHERE id=(SELECT min(id) FROM source_chunks)")
            } catch {
                try db.execute(sql: "PRAGMA foreign_keys=ON")
                throw error
            }
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertFalse(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertThrowsError(try queue.write { db in
            _ = try migrateV19(db, configuredEmbeddingModelKey: fixture["configuredModelKey"] as? String)
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES('v19_folder_rag')")
        })
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name IN ('folder_sources','source_revisions','index_generations','chunk_embeddings_v18')"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_table_info('sources') WHERE name='published_revision_id'"), 0)
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT chunk_id,dim,model,hex(embedding) AS bytes FROM chunk_embeddings ORDER BY chunk_id"), originalVectors)
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT id,citations_json FROM messages ORDER BY id"), originalCitations)
        }
    }

    func testReopenAndCitationPersistence() throws {
        let root = try SharedFixtures.json("contracts/storage-v19.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let fixture = try XCTUnwrap(cases.first { $0["name"] as? String == "configured-a" })
        let configuredKey = fixture["configuredModelKey"] as? String
        let (original, directory, _) = try V19TestStore.upgradeCopy(configuredKey: configuredKey)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try original.dbQueue.close()

        let reopened = try V19TestStore.reopen(at: url, configuredKey: configuredKey)
        try V19TestStore.assertQueries(reopened, queries: XCTUnwrap(fixture["queries"] as? [[String: Any]]))
        let legacyMessage = try reopened.runOnDatabase { db in
            try XCTUnwrap(ChatMessage.fetchOne(db, sql: "SELECT * FROM messages ORDER BY id LIMIT 1"))
        }
        let rawLegacy = try reopened.runOnDatabase { db in
            try XCTUnwrap(String.fetchOne(db, sql: "SELECT citations_json FROM messages WHERE id=?", arguments: [legacyMessage.id]))
        }
        XCTAssertEqual(legacyMessage.citations, CitationsCodec.decode(rawLegacy))
        let legacyCitation = try XCTUnwrap(legacyMessage.citations.first)
        let citationsRoot = try SharedFixtures.json("contracts/citations-v2.json")
        let citationCases = try XCTUnwrap(citationsRoot["cases"] as? [[String: Any]])
        let full = try XCTUnwrap(citationCases.first { $0["name"] as? String == "v2-full" })
        let fullStored = try XCTUnwrap(full["stored"] as? String)
        let fixtureCitation = try XCTUnwrap(CitationsCodec.decode(fullStored).first)
        var citation = Citation(marker: fixtureCitation.marker, chunkId: legacyCitation.chunkId,
                                sourceId: legacyCitation.sourceId, snippet: fixtureCitation.snippet)
        citation.folderId = fixtureCitation.folderId
        citation.relPath = fixtureCitation.relPath
        citation.displayName = fixtureCitation.displayName
        citation.revisionId = try reopened.runOnDatabase { db in
            try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=?", arguments: [legacyCitation.sourceId]))
        }
        citation.spans = fixtureCitation.spans
        citation.chunkIds = [legacyCitation.chunkId]
        citation.text = fixtureCitation.text
        let messageID = try reopened.appendAssistantMessage(sessionId: legacyMessage.sessionId,
                                                             content: "Stored citation", citations: [citation])
        try reopened.dbQueue.close()

        let withCitation = try V19TestStore.reopen(at: url, configuredKey: configuredKey)
        XCTAssertEqual(try withCitation.messages(sessionId: legacyMessage.sessionId).first { $0.id == messageID }?.citations, [citation])
        try withCitation.deleteSource(id: legacyCitation.sourceId)
        try withCitation.dbQueue.close()

        let afterDeletion = try V19TestStore.reopen(at: url, configuredKey: configuredKey)
        defer { try? afterDeletion.dbQueue.close() }
        XCTAssertNil(try afterDeletion.source(id: legacyCitation.sourceId))
        let persisted = try XCTUnwrap(afterDeletion.messages(sessionId: legacyMessage.sessionId).first { $0.id == messageID })
        XCTAssertEqual(persisted.citations, [citation])
        XCTAssertEqual(persisted.citations.first?.text, fixtureCitation.text)
        XCTAssertEqual(persisted.citations.first?.spans, fixtureCitation.spans)
        try afterDeletion.runOnDatabase { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT citations_json FROM messages WHERE id=?", arguments: [legacyMessage.id]), rawLegacy)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
