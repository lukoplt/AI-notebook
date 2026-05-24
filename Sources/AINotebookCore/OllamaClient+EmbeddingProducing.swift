import Foundation

extension OllamaClient: EmbeddingProducing {
    /// Wraps the M2 `embed(model:input:)` call into the `EmbeddingProducing`
    /// protocol shape. Maps `[[Double]]` → `[[Float]]` element-wise.
    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        let doubles = try await embed(model: model, input: inputs)
        return doubles.map { $0.map(Float.init) }
    }
}
