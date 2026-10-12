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
    private let admission: IngestionAdmission?
    /// WP7 named-profile drain (`ProfileEmbeddingDrain.run`); nil result = legacy selection.
    private let profileDrain: (@Sendable () async throws -> Int?)?
    public let batchSize: Int

    /// `modelKey` is read at the start of every drain, so a provider/model
    /// switch in Settings applies to the next embedding run without
    /// rebuilding the embedder (fixes the pre-registry staleness bug).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        modelKey: @escaping @Sendable () -> String,
        batchSize: Int = 16,
        admission: IngestionAdmission? = nil,
        profileDrain: (@Sendable () async throws -> Int?)? = nil
    ) {
        self.store = store
        self.client = client
        self.modelKey = modelKey
        self.batchSize = batchSize
        self.admission = admission
        self.profileDrain = profileDrain
    }

    /// Convenience for a fixed key (tests, single-provider setups).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        batchSize: Int = 16,
        admission: IngestionAdmission? = nil
    ) {
        self.init(store: store, client: client, modelKey: { model }, batchSize: batchSize, admission: admission)
    }

    /// Embeds every chunk that doesn't already have a row for the current
    /// model key. Returns total rows written.
    @discardableResult
    public func embedAllPending() async throws -> Int {
        // A selected named profile owns ordinary embedding work; nil keeps the legacy drain below.
        if let profileDrain, let count = try await profileDrain() { return count }
        let key = modelKey()
        let selection = modelKey
        var written = 0
        var generations: [Int64: Int64] = [:]
        while true {
            try Task.checkCancellation()
            let capturedGenerations = generations
            let batch = try await MainActor.run {
                try store.captureEmbeddingBatch(model: key, limit: batchSize, generations: capturedGenerations)
            }
            if batch.isEmpty {
                try await MainActor.run {
                    try store.completeEmbeddingWork(modelKey: key, selectedModelKey: selection(), now: Int64(Date().timeIntervalSince1970))
                }
                break
            }
            let inputs = batch.map { $0.chunk.embeddingText }
            // The shared chat gate holds back the next background batch.
            try await admission?.waitForBackgroundBatch()
            let vectors = try await client.embed(model: key, inputs: inputs)
            try Task.checkCancellation()
            guard vectors.count == batch.count else {
                throw EmbedderError.responseSizeMismatch(expected: batch.count, got: vectors.count)
            }
            let result = try await MainActor.run {
                try store.writeEmbeddingBatch(batch, vectors: vectors, modelKey: key,
                    selectedModelKey: selection(), now: Int64(Date().timeIntervalSince1970))
            }
            written += result.written
            generations.merge(result.generationIds) { _, newer in newer }
            // Superseded work waits for the next drain instead of spinning on stale evidence.
            if result.written == 0 { break }
        }
        return written
    }
}

public enum EmbedderError: Error, Equatable {
    case responseSizeMismatch(expected: Int, got: Int)
}
