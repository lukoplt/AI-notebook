import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private actor EvalQueryEmbedder: EmbeddingProducing {
    private(set) var calls = 0
    let vectors: [[Float]]
    init(_ vectors: [[Float]] = [[1, 0]]) { self.vectors = vectors }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls += 1
        return vectors
    }
}

// Shared by the retrieval and metric dispatchers, including mixed-kind subcases.
enum EvalRetrievalFixtures {
    static func cases() throws -> [[String: Any]] {
        let roots = try XCTUnwrap(SharedFixtures.json("contracts/eval-retrieval-v1.json")["cases"] as? [[String: Any]])
        XCTAssertEqual(roots.count, 12)
        func flatten(_ rows: [[String: Any]]) -> [[String: Any]] {
            rows.flatMap { [$0] + flatten($0["subcases"] as? [[String: Any]] ?? []) }
        }
        let all = flatten(roots)
        XCTAssertEqual(all.count, 28)
        XCTAssertEqual(Set(all.compactMap { $0["name"] as? String }).count, all.count)
        XCTAssertTrue(all.allSatisfy { ["retrieval", "metrics"].contains($0["kind"] as? String ?? "") })
        return all
    }

    static func vector(_ values: [Any]) -> [Float] {
        values.map { ($0 as? String) == "nan" ? .nan : ($0 as! NSNumber).floatValue }
    }
}

@MainActor
final class EvalRetrievalTests: XCTestCase {
    func testFetchKRetainsFullUnionAndLexicalMakesNoEmbeddingCall() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "Eval branches").id!
        let src = try store.createSource(notebookId: nb, type: .text, title: "doc", uri: nil, rawPath: nil).id!
        try store.replaceChunks(sourceId: src, chunks: [ChunkDraft(text: "fox on shelf", tokenCount: 3),
                                                       ChunkDraft(text: "vector target", tokenCount: 2)])
        let chunks = try store.chunks(sourceId: src)
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: EmbeddingVector(values: [0, 1]))
        try store.storeEmbedding(chunkId: chunks[1].id!, model: "m", vector: EmbeddingVector(values: [1, 0]))
        let client = EvalQueryEmbedder()
        let r = Retriever(store: store, client: client, model: "m")
        let hits = try await r.candidates(notebookId: nb, query: "fox", fetchK: 1)
        XCTAssertEqual(hits.lexical.map(\.chunkId), [chunks[0].id!])
        XCTAssertEqual(hits.vector.map(\.chunkId), [chunks[1].id!])
        XCTAssertEqual(hits.fused.map(\.chunkId), chunks.map { $0.id! })
        let before = await client.calls
        let lexical = try await r.candidates(notebookId: nb, query: "fox", fetchK: 1, includeVectors: false)
        XCTAssertTrue(lexical.vector.isEmpty)
        XCTAssertEqual(lexical.fused.count, 1)
        let empty = try await r.candidates(notebookId: nb, query: "fox", sourceIds: [])
        XCTAssertTrue(empty.fused.isEmpty)
        let after = await client.calls
        XCTAssertEqual(before, after)
    }

    func testSharedRetrievalCases() async throws {
        let cases = try EvalRetrievalFixtures.cases().filter { $0["kind"] as? String == "retrieval" }
        XCTAssertEqual(cases.count, 18)
        for c in cases { try await check(c) }
    }

    private func check(_ c: [String: Any]) async throws {
        let name = c["name"] as! String
        let input = c["input"] as! [String: Any], expected = c["expected"] as! [String: Any]
        let docs = input["documents"] as! [[String: Any]]
        let store = try NotebookStore(path: .inMemory)
        var notebooks: [Int: Int64] = [:], sources: [Int: Int64] = [:]
        var identities: [Int64: [String: Any]] = [:], vectors: [Int64: [Float]] = [:]
        for d in docs {
            let notebook = d["notebook_id"] as! Int
            if notebooks[notebook] == nil { notebooks[notebook] = try store.createNotebook(name: "eval").id! }
            let source = try store.createSource(notebookId: notebooks[notebook]!, type: .text,
                title: d["document_id"] as! String, uri: nil, rawPath: nil).id!
            sources[d["source_id"] as! Int] = source
            let chunks = d["chunks"] as! [[String: Any]]
            try store.replaceChunks(sourceId: source, chunks: chunks.map { ChunkDraft(text: $0["text"] as! String, tokenCount: 3) })
            for (ordinal, chunk) in try store.chunks(sourceId: source).enumerated() {
                identities[chunk.id!] = ["document_id": d["document_id"]!, "ordinal": ordinal]
                vectors[chunk.id!] = EvalRetrievalFixtures.vector(chunks[ordinal]["vector"] as! [Any])
            }
        }
        // WP3 disallows mixed dimensions at activation. Seed a valid generation,
        // then inject fixture bytes to exercise corruption diagnostics, not building work.
        for id in vectors.keys.sorted() {
            try store.storeEmbedding(chunkId: id, model: "m", vector: EmbeddingVector(values: [1, 0]))
        }
        for (id, values) in vectors {
            try store.runOnDatabase { db in
                try db.execute(sql: "UPDATE chunk_embeddings SET embedding=? WHERE chunk_id=?",
                    arguments: [EmbeddingVector(values: values).asData(), id])
            }
        }
        let scope = input["scope"] as! [String: Any]
        let selected: Set<Int64>?
        if scope["kind"] as? String == "all" { selected = nil }
        else {
            let sourceIds = scope["sourceIds"] as! [Int], folders = scope["folderIds"] as! [Int]
            selected = Set(docs.filter { sourceIds.contains($0["source_id"] as! Int)
                || ($0["folder_id"] as? Int).map(folders.contains) == true }.map { sources[$0["source_id"] as! Int]! })
        }
        let outputs = (input["query_vectors"] as? [[Any]]) ?? [input["query_vector"] as! [Any]]
        let client = EvalQueryEmbedder(outputs.map(EvalRetrievalFixtures.vector))
        let retriever = Retriever(store: store, client: client, model: "m", rrfK: input["rrf_k"] as! Int)
        do {
            let hits = try await retriever.candidates(notebookId: notebooks[input["notebook_id"] as! Int]!,
                query: input["query"] as! String, fetchK: input["fetch_k"] as! Int,
                sourceIds: selected, includeVectors: input["include_vectors"] as! Bool)
            XCTAssertNil(expected["error"], name)
            for (key, branch) in [("lexical", hits.lexical), ("vector", hits.vector), ("fused", hits.fused)] {
                XCTAssertEqual(branch.map { identities[$0.chunkId]! } as NSArray, expected[key] as? NSArray, name + ": " + key)
            }
        } catch {
            XCTAssertEqual((error as? EvalFailure)?.code, expected["error"] as? String, name)
            XCTAssertNotNil(expected["error"], name)
        }
        let calls = await client.calls
        XCTAssertEqual(calls, expected["embedding_calls"] as? Int, name)
    }

    func testNoActiveGenerationUsesPublishedLexicalWithoutEmbedding() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "no active generation").id!
        let src = try store.createSource(notebookId: nb, type: .text, title: "doc", uri: nil, rawPath: nil).id!
        try store.replaceChunks(sourceId: src, chunks: [ChunkDraft(text: "fox", tokenCount: 1), ChunkDraft(text: "target", tokenCount: 1)])
        let chunks = try store.chunks(sourceId: src)
        // Incomplete building vectors are intentionally invisible to retrieval.
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: EmbeddingVector(values: [1, 0]))
        let client = EvalQueryEmbedder()
        let hits = try await Retriever(store: store, client: client, model: "m").candidates(notebookId: nb, query: "fox")
        XCTAssertEqual(hits.lexical.map(\.chunkId), [chunks[0].id!])
        XCTAssertTrue(hits.vector.isEmpty)
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testMalformedVectorOutsideSelectedScopeDoesNotFailRetrieval() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "scoped corruption").id!
        let selected = try store.createSource(notebookId: nb, type: .text, title: "selected", uri: nil, rawPath: nil).id!
        let excluded = try store.createSource(notebookId: nb, type: .text, title: "excluded", uri: nil, rawPath: nil).id!
        for source in [selected, excluded] {
            try store.replaceChunks(sourceId: source, chunks: [ChunkDraft(text: "fox", tokenCount: 1)])
        }
        let selectedChunk = try XCTUnwrap(store.chunks(sourceId: selected).first?.id)
        let excludedChunk = try XCTUnwrap(store.chunks(sourceId: excluded).first?.id)
        for chunk in [selectedChunk, excludedChunk] {
            try store.storeEmbedding(chunkId: chunk, model: "m", vector: EmbeddingVector(values: [1, 0]))
        }
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE chunk_embeddings SET embedding=? WHERE chunk_id=?",
                arguments: [EmbeddingVector(values: [1, 0, 0]).asData(), excludedChunk])
        }
        let client = EvalQueryEmbedder()
        let hits = try await Retriever(store: store, client: client, model: "m").candidates(
            notebookId: nb, query: "fox", fetchK: 1, sourceIds: [selected])
        XCTAssertEqual(hits.lexical.map(\.chunkId), [selectedChunk])
        XCTAssertEqual(hits.vector.map(\.chunkId), [selectedChunk])
        XCTAssertEqual(hits.fused.map(\.chunkId), [selectedChunk])
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testGenerationActivationDuringEmbeddingRetainsPinnedRevisionAndModel() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "pinned diagnostics").id!
        let source = try store.createSource(notebookId: nb, type: .text, title: "doc", uri: nil, rawPath: nil).id!
        try store.replaceChunks(sourceId: source, chunks: [ChunkDraft(text: "fox old revision", tokenCount: 3)])
        let oldChunk = try XCTUnwrap(store.chunks(sourceId: source).first?.id)
        try store.storeEmbedding(chunkId: oldChunk, model: "original", vector: EmbeddingVector(values: [1, 0]))
        let client = EvalGenerationChangingEmbedder {
            try await MainActor.run {
                try store.replaceChunks(sourceId: source, chunks: [ChunkDraft(text: "fox replacement revision", tokenCount: 3)])
                let replacement = try XCTUnwrap(store.chunks(sourceId: source).first?.id)
                try store.storeEmbedding(chunkId: replacement, model: "replacement", vector: EmbeddingVector(values: [0, 1]))
                // A registered query pin must retain both its retired generation
                // and its own revision even when collection runs before its reply.
                _ = try store.garbageCollect(notebookId: nb)
            }
        }
        let hits = try await Retriever(store: store, client: client, model: "original").candidates(
            notebookId: nb, query: "fox", fetchK: 1)
        let replacement = try XCTUnwrap(store.chunks(sourceId: source).first?.id)
        XCTAssertNotEqual(replacement, oldChunk)
        XCTAssertEqual(hits.lexical.map(\.chunkId), [oldChunk])
        XCTAssertEqual(hits.vector.map(\.chunkId), [oldChunk])
        XCTAssertEqual(hits.fused.map(\.chunkId), [oldChunk])
        XCTAssertEqual(hits.lexical.first?.snippet, "fox old revision")
        let models = await client.models
        XCTAssertEqual(models, ["original"])
        let replacementPin = try store.pinQuery(notebookId: nb, modelKey: "replacement")
        XCTAssertNotNil(replacementPin.generationId)
        XCTAssertEqual(try store.pinnedEmbeddings(replacementPin).map(\.chunkId), [replacement])
        store.releaseQuery(replacementPin)
        // Once candidates returns, its pin must no longer retain the old chunk.
        let collected = try store.garbageCollect(notebookId: nb)
        XCTAssertEqual(collected.chunks, 1)
    }

    func testDifferentActiveModelUsesLexicalWithoutEmbedding() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "different active model").id!
        let source = try store.createSource(notebookId: nb, type: .text, title: "doc", uri: nil, rawPath: nil).id!
        try store.replaceChunks(sourceId: source, chunks: [ChunkDraft(text: "fox", tokenCount: 1)])
        let chunk = try XCTUnwrap(store.chunks(sourceId: source).first?.id)
        try store.storeEmbedding(chunkId: chunk, model: "active", vector: EmbeddingVector(values: [1, 0]))
        let client = EvalQueryEmbedder()
        let hits = try await Retriever(store: store, client: client, model: "requested").candidates(
            notebookId: nb, query: "fox", fetchK: 1)
        XCTAssertEqual(hits.lexical.map(\.chunkId), [chunk])
        XCTAssertTrue(hits.vector.isEmpty)
        XCTAssertEqual(hits.fused.map(\.chunkId), [chunk])
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }
}

private actor EvalGenerationChangingEmbedder: EmbeddingProducing {
    private(set) var models: [String] = []
    let beforeReply: @Sendable () async throws -> Void

    init(beforeReply: @escaping @Sendable () async throws -> Void) {
        self.beforeReply = beforeReply
    }

    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        models.append(model)
        try await beforeReply()
        return inputs.map { _ in [1, 0] }
    }
}
