import Foundation

public struct OllamaEmbedRequest: Codable, Sendable {
    public let model: String
    public let input: [String]

    public init(model: String, input: [String]) {
        self.model = model
        self.input = input
    }
}

public struct OllamaEmbedResponse: Codable, Sendable {
    public let embeddings: [[Double]]
}
