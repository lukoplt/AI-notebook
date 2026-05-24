import Foundation

/// Minimal protocol the embedder needs from the underlying client.
/// `OllamaClient` will conform to this in Task 7 via a tiny extension.
public protocol EmbeddingProducing: Sendable {
    func embed(model: String, inputs: [String]) async throws -> [[Float]]
}

public actor Embedder {
    private let store: NotebookStore
    private let client: EmbeddingProducing
    public let model: String
    public let batchSize: Int

    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        batchSize: Int = 16
    ) {
        self.store = store
        self.client = client
        self.model = model
        self.batchSize = batchSize
    }

    /// Embeds every chunk that doesn't already have a row for `model`.
    /// Returns total rows written.
    @discardableResult
    public func embedAllPending() async throws -> Int {
        var written = 0
        while true {
            let batch = try await MainActor.run {
                try store.unembeddedChunks(model: model, limit: batchSize)
            }
            if batch.isEmpty { break }
            let inputs = batch.map(\.text)
            let vectors = try await client.embed(model: model, inputs: inputs)
            guard vectors.count == batch.count else {
                throw EmbedderError.responseSizeMismatch(expected: batch.count, got: vectors.count)
            }
            for (chunk, values) in zip(batch, vectors) {
                try await MainActor.run {
                    try store.storeEmbedding(
                        chunkId: chunk.id!,
                        model: model,
                        vector: EmbeddingVector(values: values)
                    )
                }
                written += 1
            }
        }
        return written
    }
}

public enum EmbedderError: Error, Equatable {
    case responseSizeMismatch(expected: Int, got: Int)
}
