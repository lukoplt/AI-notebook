import XCTest
@testable import AINotebookCore

@MainActor
final class EmbedderModelKeyTests: XCTestCase {

    final class RecordingClient: EmbeddingProducing, @unchecked Sendable {
        var models: [String] = []
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            models.append(model)
            return inputs.map { _ in [1, 0] }
        }
    }

    /// Mutable key box standing in for a live settings read.
    final class KeyBox: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    /// NotebookStore has no notebooks() list API — return the id directly.
    /// Adjustment: `replaceChunks(sourceId:chunks:)` takes `[ChunkDraft]`, not
    /// `[SourceChunk]` — mirrors the fixture in EmbedderTests.swift exactly.
    private func makeStoreWithOneChunk() throws -> (store: NotebookStore, notebookId: Int64) {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let source = try store.createSource(
            notebookId: nb.id!, type: .text, title: "T", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: source.id!, chunks: [
            ChunkDraft(text: "hello world", tokenCount: 2)
        ])
        return (store, nb.id!)
    }

    func testEmbedderUsesLiveModelKeyPerDrain() async throws {
        let (store, _) = try makeStoreWithOneChunk()
        let client = RecordingClient()
        let box = KeyBox("prov-A:model-1")
        let embedder = Embedder(store: store, client: client, modelKey: { box.value })

        _ = try await embedder.embedAllPending()
        XCTAssertEqual(client.models, ["prov-A:model-1"])

        // Switch the selection; the SAME embedder instance must pick it up.
        box.value = "prov-B:model-2"
        _ = try await embedder.embedAllPending()   // chunk has no row for the new key yet
        XCTAssertEqual(client.models, ["prov-A:model-1", "prov-B:model-2"])
    }

    func testConvenienceInitKeepsFixedModel() async throws {
        let (store, _) = try makeStoreWithOneChunk()
        let client = RecordingClient()
        let embedder = Embedder(store: store, client: client, model: "fixed-key")
        _ = try await embedder.embedAllPending()
        XCTAssertEqual(client.models, ["fixed-key"])
    }

    func testRetrieverUsesLiveModelKey() async throws {
        let (store, notebookId) = try makeStoreWithOneChunk()
        let client = RecordingClient()
        let embedder = Embedder(store: store, client: client, model: "prov-A:m")
        _ = try await embedder.embedAllPending()

        let box = KeyBox("prov-A:m")
        let retriever = Retriever(store: store, client: client, modelKey: { box.value })
        let hits = try await retriever.search(notebookId: notebookId, query: "hello")
        XCTAssertFalse(hits.isEmpty, "stored vectors under prov-A:m must be found")

        box.value = "prov-B:other"
        let missHits = try await retriever.search(notebookId: notebookId, query: "hello")
        // Vector arm finds nothing under the new key (FTS may still hit);
        // assert the embed call went out with the NEW key.
        XCTAssertEqual(client.models.last, "prov-B:other")
        _ = missHits
    }
}
