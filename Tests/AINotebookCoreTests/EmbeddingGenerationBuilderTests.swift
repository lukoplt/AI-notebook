import CryptoKit
import GRDB
import XCTest
@testable import AINotebookCore

@MainActor final class EmbeddingGenerationBuilderTests: XCTestCase {
    private func identity(_ object: Any?) -> GenerationIdentity {
        let o = object as! [String: Any]
        return GenerationIdentity(providerId: o["providerId"] as! String, endpointRevision: o["endpointRevision"] as! String,
                                  model: o["model"] as! String, modelDigest: o["modelDigest"] as? String,
                                  dims: o["dims"] as! Int, normalization: o["normalization"] as! String,
                                  queryFormatVersion: o["queryFormatVersion"] as! String,
                                  docFormatVersion: o["docFormatVersion"] as! String,
                                  chunkerVersion: o["chunkerVersion"] as! String)
    }

    @discardableResult
    private func publish(_ store: NotebookStore, sourceId: Int64, text: String, now: Int64 = 0) throws -> SourceRevision {
        try store.commitForegroundRevision(sourceId: sourceId, draft: draft(text), chunks: ScalarChunker.chunk(text),
                                           now: now, leaseToken: "fixture-extract-\(now)")
    }

    private func draft(_ text: String) -> RevisionDraft {
        RevisionDraft(contentHash: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                      canonicalText: text, textFormatVersion: 1, chunkerVersion: 2)
    }

    private func read<T>(_ store: NotebookStore, _ body: (Database) throws -> T) throws -> T {
        try store.dbQueue.read(body)
    }

    private func code(_ error: any Error) -> String {
        if let e = error as? EmbeddingGenerationError { return e.code }
        if error is CancellationError { return "cancelled" }
        return "unexpected:\(error)"
    }

    func testStagingDoesNotActivateAndFailurePreservesActive() async throws {
        let store = try NotebookStore(path: .inMemory)
        let notebookId = try XCTUnwrap(try store.createNotebook(name: "benchmark").id)
        let sourceId = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "one",
                                                            uri: nil, rawPath: nil).id)
        try publish(store, sourceId: sourceId, text: "needle")
        let identity = GenerationIdentity(providerId: "fixture", endpointRevision: "fixture", model: "m",
                                          modelDigest: nil, dims: 2, normalization: "l2", queryFormatVersion: "1",
                                          docFormatVersion: "1", chunkerVersion: "2")
        let first = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                               now: { 1 }, embedDocuments: { inputs in
            XCTAssertEqual(inputs, ["needle"]); return [[1, 0]]
        })
        XCTAssertNil(try store.activeGeneration(notebookId: notebookId))
        XCTAssertEqual(try store.manifest(generationId: first.id).map(\.state), ["done"])
        try store.activateGeneration(id: first.id, now: 2)
        do {
            _ = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                           now: { 3 }, embedDocuments: { _ in throw CancellationError() })
            XCTFail("cancelled stage returned")
        } catch is CancellationError {}
        XCTAssertEqual(try store.activeGeneration(notebookId: notebookId)?.id, first.id)
        XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["needle"])
    }

    func testSharedStageCases() async throws {
        let rows = try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "stage")
        XCTAssertEqual(rows.count, 7)
        for c in rows {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let requested = identity(c["identity"])
            let store = try NotebookStore(path: .inMemory)
            let notebookId = try XCTUnwrap(try store.createNotebook(name: name).id)
            var ids: [Int: Int64] = [:]
            for s in c["sources"] as! [[String: Any]] {
                let fixtureId = s["sourceId"] as! Int
                let id = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "s\(fixtureId)",
                                                              uri: nil, rawPath: nil).id)
                ids[fixtureId] = id
            }
            let fixtureIdOf = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
            // Active generation over the published v1 corpus.
            for s in c["sources"] as! [[String: Any]] {
                try publish(store, sourceId: ids[s["sourceId"] as! Int]!, text: s["text"] as! String)
            }
            let before = c["activeBefore"] as! [String: Any]
            let active = try await EmbeddingGenerationBuilder.stage(
                store: store, notebookId: notebookId, identity: identity(before["identity"]), now: { 1 },
                embedDocuments: { inputs in inputs.map { _ in [1, 0] } })
            try store.activateGeneration(id: active.id, now: 1)
            for s in c["sources"] as! [[String: Any]] where s["currentRevision"] as? Int == 2 {
                _ = try store.insertRevision(sourceId: ids[s["sourceId"] as! Int]!, draft: draft("refreshed"), now: 2)
            }
            let publishedBefore = try ids.values.map { try store.source(id: $0)?.publishedRevisionId }

            var script = c["embedScript"] as! [[String: Any]]
            let events = c["events"] as! [[String: Any]]
            let sessionIdentity = events.first { $0["kind"] as? String == "sessionIdentity" }.map { identity($0["identity"]) }
            var requests = 0
            var thrown: (any Error)?
            do {
                _ = try await EmbeddingGenerationBuilder.stage(
                    store: store, notebookId: notebookId, identity: requested, sessionIdentity: sessionIdentity,
                    now: { 5 }, embedDocuments: { inputs in
                        requests += 1
                        let step = script.removeFirst()
                        XCTAssertEqual(inputs, step["inputs"] as? [String], name)
                        for e in events where e["kind"] as? String == "publishRevision" && e["afterRequest"] as? Int == requests {
                            try self.publish(store, sourceId: ids[e["sourceId"] as! Int]!, text: e["text"] as! String, now: 3)
                        }
                        if step["outcome"] as? String == "cancel" { throw CancellationError() }
                        return (step["vectors"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
                    })
            } catch { thrown = error }
            XCTAssertEqual(thrown.map(code), expected["error"] as? String, name)
            XCTAssertEqual(requests, expected["embeddingRequests"] as? Int, name)
            XCTAssertTrue(script.isEmpty, name)
            XCTAssertEqual(try store.activeGeneration(notebookId: notebookId)?.id,
                           (expected["activeAfter"] as? Int).map { _ in active.id }, name)
            let staged = try read(store) { db in
                try Row.fetchAll(db, sql: "SELECT id,state FROM index_generations WHERE notebook_id=? AND id<>?",
                                 arguments: [notebookId, active.id]).map { (id: $0["id"] as Int64, state: $0["state"] as String) }
            }
            XCTAssertLessThanOrEqual(staged.count, 1, name)
            XCTAssertEqual(staged.first?.state, expected["stagedState"] as? String, name)
            let vectors = try staged.first.map { g in
                try read(store) { try Int.fetchOne($0, sql: "SELECT count(*) FROM chunk_embeddings WHERE generation_id=?",
                                                         arguments: [g.id]) ?? 0 }
            } ?? 0
            XCTAssertEqual(vectors, expected["vectorsWritten"] as? Int, name)
            if let manifest = expected["manifest"] as? [[String: Any]], let g = staged.first {
                let actual = try store.manifest(generationId: g.id).map { ["sourceId": fixtureIdOf[$0.sourceId]!, "state": $0.state] as NSDictionary }
                XCTAssertEqual(actual, manifest.map { $0 as NSDictionary }, name)
            }
            let publishedAfter = try ids.values.map { try store.source(id: $0)?.publishedRevisionId }
            XCTAssertEqual(publishedBefore == publishedAfter, expected["publishedRevisionsUnchanged"] as? Bool, name)
        }
    }

    func testReuseActiveCopiesUnchangedSourcesOnly() async throws {
        let store = try NotebookStore(path: .inMemory)
        let notebookId = try XCTUnwrap(try store.createNotebook(name: "reuse").id)
        let a = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "a", uri: nil, rawPath: nil).id)
        let b = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "b", uri: nil, rawPath: nil).id)
        try publish(store, sourceId: a, text: "alpha")
        try publish(store, sourceId: b, text: "beta")
        let identity = GenerationIdentity(providerId: "fixture", endpointRevision: "fixture", model: "m", modelDigest: nil,
                                          dims: 2, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1",
                                          chunkerVersion: "2")
        let first = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                               now: { 1 }, embedDocuments: { _ in [[0.6, 0.8]] })
        try store.activateGeneration(id: first.id, now: 1)
        try publish(store, sourceId: b, text: "beta two", now: 2)
        var seen: [String] = []
        let second = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                                now: { 3 }, embedDocuments: { seen += $0; return [[1, 0]] },
                                                                reuseActive: true)
        XCTAssertEqual(seen, ["beta two"])
        let bytes = try read(store) { db in
            try Data.fetchOne(db, sql: """
                SELECT e.embedding FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id
                WHERE e.generation_id=? AND c.source_id=?
                """, arguments: [second.id, a])
        }
        XCTAssertEqual(bytes, EmbeddingVector(values: [0.6, 0.8]).asData())
        XCTAssertEqual(try store.manifest(generationId: second.id).map(\.state), ["done", "done"])

        let other = GenerationIdentity(providerId: "fixture", endpointRevision: "fixture", model: "m", modelDigest: nil,
                                       dims: 3, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1",
                                       chunkerVersion: "2")
        var all: [String] = []
        _ = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: other,
                                                       now: { 4 }, embedDocuments: { all += $0; return [[1, 0, 0]] },
                                                       reuseActive: true)
        XCTAssertEqual(all.sorted(), ["alpha", "beta two"])
    }

    func testNamedProfileIdentityStagesThroughCapturedSessionOnly() async throws {
        let store = try NotebookStore(path: .inMemory)
        let notebookId = try XCTUnwrap(try store.createNotebook(name: "profile").id)
        let sourceId = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "a", uri: nil,
                                                            rawPath: nil).id)
        try publish(store, sourceId: sourceId, text: "Záruka")
        let profile = try EmbeddingProfiles.require("nomic-v2-256")
        let identity = GenerationIdentity(
            providerId: ProviderConfig.ollamaId,
            endpointRevision: EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: "http://127.0.0.1:11434"),
            model: profile.model, modelDigest: "sha256:" + String(repeating: "3", count: 64), dims: 256,
            normalization: "l2", queryFormatVersion: profile.formatVersion(.query, effectiveLimit: 512),
            docFormatVersion: profile.formatVersion(.document, effectiveLimit: 512), chunkerVersion: "2")
        var requests = 0
        for session in [nil, GenerationIdentity(providerId: identity.providerId, endpointRevision: identity.endpointRevision,
                                                model: identity.model, modelDigest: "sha256:" + String(repeating: "4", count: 64),
                                                dims: 256, normalization: "l2",
                                                queryFormatVersion: identity.queryFormatVersion,
                                                docFormatVersion: identity.docFormatVersion, chunkerVersion: "2")] {
            do {
                _ = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                               sessionIdentity: session, now: { 1 },
                                                               embedDocuments: { _ in requests += 1; return [] })
                XCTFail("mismatched session staged")
            } catch { XCTAssertEqual(code(error), "profileIdentityMismatch") }
        }
        XCTAssertEqual(requests, 0)
        XCTAssertNil(try read(store) { try Int.fetchOne($0, sql: "SELECT id FROM index_generations") })
        var unit = [Float](repeating: 0, count: 256); unit[0] = 1
        let staged = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                                sessionIdentity: identity, now: { 1 },
                                                                embedDocuments: { _ in [unit] })
        XCTAssertEqual(try store.generation(id: staged.id)?.identity, identity)
        XCTAssertEqual(try store.manifest(generationId: staged.id).map(\.state), ["done"])
    }
}

@MainActor final class EmbeddingGenerationPublishTests: XCTestCase {
    override func tearDown() {
        BenchmarkURLProtocol.reset()
        super.tearDown()
    }

    func testSharedPublishRevalidatesDigestBeforeActivation() async throws {
        let rows = try BenchmarkFixture.cases("embedding-strict-v1.json", kind: "publish")
        XCTAssertEqual(rows.count, 2)
        for c in rows {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let o = c["identity"] as! [String: Any]
            let identity = GenerationIdentity(
                providerId: o["providerId"] as! String, endpointRevision: o["endpointRevision"] as! String,
                model: o["model"] as! String, modelDigest: o["modelDigest"] as? String, dims: o["dims"] as! Int,
                normalization: o["normalization"] as! String, queryFormatVersion: o["queryFormatVersion"] as! String,
                docFormatVersion: o["docFormatVersion"] as! String, chunkerVersion: o["chunkerVersion"] as! String)
            let store = try NotebookStore(path: .inMemory)
            let notebookId = try XCTUnwrap(try store.createNotebook(name: name).id)
            let sourceId = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "a",
                                                                uri: nil, rawPath: nil).id)
            _ = try store.commitForegroundRevision(
                sourceId: sourceId, draft: RevisionDraft(contentHash: "h", canonicalText: "needle", textFormatVersion: 1,
                                                         chunkerVersion: 2),
                chunks: ScalarChunker.chunk("needle"), now: 0, leaseToken: "fixture")
            var unit = [Float](repeating: 0, count: 256); unit[0] = 1
            let old = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                                 sessionIdentity: identity, now: { 1 },
                                                                 embedDocuments: { _ in [unit] })
            try store.activateGeneration(id: old.id, now: 1)
            let staged = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId, identity: identity,
                                                                    sessionIdentity: identity, now: { 2 },
                                                                    embedDocuments: { _ in [unit] })
            let tags = jsonData(c["tags"]!)
            BenchmarkURLProtocol.install { _ in (200, tags) }
            let client = OllamaBenchmarkClient(baseURL: URL(string: "http://127.0.0.1:11434")!,
                                               session: BenchmarkURLProtocol.session())
            do {
                try await EmbeddingGenerationBuilder.publish(store: store, generation: staged, client: client, now: { 3 })
                XCTAssertNil(expected["error"] as? String, name)
            } catch { XCTAssertEqual(benchmarkErrorCode(error), expected["error"] as? String, name) }
            let active = try store.activeGeneration(notebookId: notebookId)?.id
            XCTAssertEqual(active == staged.id, expected["activated"] as? Bool, name)
            XCTAssertEqual(active == old.id, expected["activeGenerationUnchanged"] as? Bool, name)
            XCTAssertEqual(BenchmarkURLProtocol.requests.map { $0.url!.path }, ["/api/tags"], name)
        }
    }
}
