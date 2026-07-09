import Foundation

/// Minimal protocol the embedder needs from the underlying client.
/// `OllamaClient` will conform to this in Task 7 via a tiny extension.
public protocol EmbeddingProducing: Sendable {
    func embed(model: String, inputs: [String]) async throws -> [[Float]]
}

public actor Embedder {
    private let store: NotebookStore
    private let client: EmbeddingProducing
    private let modelKey: @Sendable () -> String
    public let batchSize: Int

    /// `modelKey` is read at the start of every drain, so a provider/model
    /// switch in Settings applies to the next embedding run without
    /// rebuilding the embedder (fixes the pre-registry staleness bug).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        modelKey: @escaping @Sendable () -> String,
        batchSize: Int = 16
    ) {
        self.store = store
        self.client = client
        self.modelKey = modelKey
        self.batchSize = batchSize
    }

    /// Convenience for a fixed key (tests, single-provider setups).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        batchSize: Int = 16
    ) {
        self.init(store: store, client: client, modelKey: { model }, batchSize: batchSize)
    }

    /// Embeds every chunk that doesn't already have a row for the current
    /// model key. Returns total rows written.
    @discardableResult
    public func embedAllPending() async throws -> Int {
        let key = modelKey()
        var written = 0
        while true {
            let batch = try await MainActor.run {
                try store.unembeddedChunks(model: key, limit: batchSize)
            }
            if batch.isEmpty { break }
            let inputs = batch.map(\.text)
            let vectors = try await client.embed(model: key, inputs: inputs)
            guard vectors.count == batch.count else {
                throw EmbedderError.responseSizeMismatch(expected: batch.count, got: vectors.count)
            }
            for (chunk, values) in zip(batch, vectors) {
                try await MainActor.run {
                    try store.storeEmbedding(
                        chunkId: chunk.id!,
                        model: key,
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
