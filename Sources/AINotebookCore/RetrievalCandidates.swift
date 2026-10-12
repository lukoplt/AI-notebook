public struct RetrievalCandidates: Equatable, Sendable {
    public let lexical: [RetrievalHit]
    public let vector: [RetrievalHit]
    public let fused: [RetrievalHit]

    public init(lexical: [RetrievalHit], vector: [RetrievalHit], fused: [RetrievalHit]) {
        self.lexical = lexical
        self.vector = vector
        self.fused = fused
    }
}
