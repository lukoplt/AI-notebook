import Foundation

public struct RetrievalHit: Equatable, Sendable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let score: Float
    public let snippet: String

    public init(chunkId: Int64, sourceId: Int64, score: Float, snippet: String) {
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.score = score
        self.snippet = snippet
    }
}
