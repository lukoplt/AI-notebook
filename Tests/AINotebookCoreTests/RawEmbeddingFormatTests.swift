import XCTest
@testable import AINotebookCore

private final class RecordingEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var inputs: [String] { lock.withLock { log } }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        lock.withLock { log += inputs }
        return inputs.map { _ in [1, 0, 0, 0] }
    }
}

private struct StillClock: IngestLeaseClock {
    func now() -> Int64 { 2 }
    func wait(until: Int64) async throws { try await Task.sleep(nanoseconds: 1_000_000) }
}

final class RawEmbeddingFormatTests: XCTestCase {
    func testSharedCases() throws {
        let fixture = try SharedFixtures.json("contracts/embedding-raw-format-v2.json")
        XCTAssertEqual(fixture["current"] as? String, RawEmbeddingFormat.current)
        XCTAssertEqual((fixture["headerMaxScalars"] as? NSNumber)?.intValue, RawEmbeddingFormat.headerMaxScalars)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 13)
        for c in cases {
            let model = c["model"] as! String, format = c["format"] as! String, text = c["text"] as! String
            let actual = c["purpose"] as! String == "query"
                ? RawEmbeddingFormat.query(text, model: model, format: format)
                : RawEmbeddingFormat.document((format == "2" ? RawEmbeddingFormat.header(relPath: c["relPath"] as? String,
                                                                                          title: c["title"] as! String) : "") + text,
                                              model: model, format: format)
            XCTAssertEqual(actual, c["expected"] as? String, c["name"] as? String ?? "")
        }
    }

    /// Queries of a format-2 generation carry the query prefix; format 1 stays verbatim.
    func testQuerySessionsFollowTheGenerationFormat() async throws {
        for (format, expected) in [("2", "search_query: Kdy končí smlouva?"), ("1", "Kdy končí smlouva?"), ("legacy", "Kdy končí smlouva?")] {
            let embedder = RecordingEmbedder()
            let session = ProviderEmbeddingSession(client: embedder, model: "nomic-embed-text", storageKey: "local:nomic-embed-text",
                                                   endpointRevision: "e", rawFormat: format)
            _ = try await session.embed(inputs: ["Kdy končí smlouva?"])
            XCTAssertEqual(embedder.inputs, [expected], format)
        }
    }

    /// A format-2 build sends "<document prefix><path line>\n<chunk text>"; format 1 sends the text.
    @MainActor func testFormatTwoBuildSendsPrefixAndPathHeader() async throws {
        for format in ["1", "2"] {
            let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
            let notebookId = try XCTUnwrap(store.createNotebook(name: "f").id)
            try store.runOnDatabase { db in
                try db.execute(sql: """
                    INSERT INTO folder_sources(notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                    VALUES (?,'/r','{}','Archive','[]','[]','{}','2026-10-11')
                    """, arguments: [notebookId])
                let folder = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO sources(notebook_id,type,title,status,ingested_at,folder_id,rel_path)
                    VALUES (?,'text','Nabidka.pdf','ready','2026-10-11 00:00:00.000',?,'Klient/2026/Nabidky/Nabidka.pdf')
                    """, arguments: [notebookId, folder])
                let source = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (?,1,'h','',1,2,'2026-10-11 00:00:00.000')
                    """, arguments: [source])
                let revision = db.lastInsertedRowID
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?", arguments: [revision, revision, source])
                try db.execute(sql: "INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id) VALUES (?,0,'Cena 15 000 Kč',4,?)",
                               arguments: [source, revision])
            }
            let selection = EmbeddingSelection(providerId: "local", endpointRevision: "e", model: "nomic-embed-text:latest",
                modelDigest: nil, dims: 4, normalization: "l2", queryFormatVersion: format, docFormatVersion: format, chunkerVersion: "2")
            let embedder = RecordingEmbedder()
            let jobId = try store.requestEmbeddingBuild(notebookId: notebookId, selection: selection, copyExisting: false, now: 1)
            let job = try XCTUnwrap(store.claimJob(now: 1, leaseToken: "t", id: jobId))
            let coordinator = FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: StillClock(),
                session: { _ in FolderEmbeddingSession(selection: selection, embedder: embedder) },
                selectedSelection: { _ in selection })
            try await coordinator.execute(job: job, fence: JobFence(jobId: jobId, leaseToken: "t"))
            XCTAssertEqual(embedder.inputs, format == "2"
                ? ["search_document: Klient/2026/Nabidky/Nabidka.pdf\nCena 15 000 Kč"] : ["Cena 15 000 Kč"], format)
            XCTAssertEqual(try store.activeGeneration(notebookId: notebookId)?.identity.docFormatVersion, format)

            // §5: with format 2 selected, a complete format-1 index is rebuilt once beside the active one.
            let upgraded = EmbeddingSelection(providerId: "local", endpointRevision: "e", model: "nomic-embed-text:latest",
                modelDigest: nil, dims: 4, normalization: "l2", queryFormatVersion: "2", docFormatVersion: "2", chunkerVersion: "2")
            let next = RecordingEmbedder()
            let upgrader = FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: StillClock(),
                session: { _ in FolderEmbeddingSession(selection: upgraded, embedder: next) },
                selectedSelection: { _ in upgraded })
            let requested = try await upgrader.requestRawFormatUpgrade(notebookId: notebookId)
            XCTAssertEqual(requested, format == "1", "only a format-1 active index is upgraded")
            guard requested else { continue }
            XCTAssertEqual(try store.activeGeneration(notebookId: notebookId)?.identity.docFormatVersion, "1",
                           "the old index keeps serving while the upgrade builds")
            let upgradeJobId = try XCTUnwrap(try store.runOnDatabase {
                try Int64.fetchOne($0, sql: "SELECT max(id) FROM ingest_jobs WHERE kind='embed' AND state='queued'")
            })
            let upgradeJob = try XCTUnwrap(store.claimJob(now: 1, leaseToken: "u", id: upgradeJobId))
            try await upgrader.execute(job: upgradeJob, fence: JobFence(jobId: upgradeJobId, leaseToken: "u"))
            XCTAssertEqual(try store.activeGeneration(notebookId: notebookId)?.identity.docFormatVersion, "2")
            XCTAssertEqual(next.inputs, ["search_document: Klient/2026/Nabidky/Nabidka.pdf\nCena 15 000 Kč"])
            let again = try await upgrader.requestRawFormatUpgrade(notebookId: notebookId)
            XCTAssertFalse(again, "the upgrade happens once")
        }
    }
}
