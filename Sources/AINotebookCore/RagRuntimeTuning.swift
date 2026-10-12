import Foundation

public enum RagTuningError: Error, Equatable, Sendable { case invalidTuning }

/// Versioned runtime retrieval/packing parameters carried from the benchmark decision.
/// `pending` decisions are exactly the frozen v1 values (32/16/6000).
public struct RagRuntimeTuning: Codable, Equatable, Sendable {
    public let fetchK: Int
    public let topK: Int
    public let evidenceShareBp: Int

    public init(fetchK: Int, topK: Int, evidenceShareBp: Int) throws {
        guard fetchK >= topK, topK > 0, fetchK <= 1024, (0...10_000).contains(evidenceShareBp) else {
            throw RagTuningError.invalidTuning
        }
        self.fetchK = fetchK
        self.topK = topK
        self.evidenceShareBp = evidenceShareBp
    }

    private init(unchecked fetchK: Int, topK: Int, evidenceShareBp: Int) {
        self.fetchK = fetchK
        self.topK = topK
        self.evidenceShareBp = evidenceShareBp
    }

    public static let v1 = RagRuntimeTuning(unchecked: RagContractV1.Retrieval.fetchK,
                                            topK: RagContractV1.Retrieval.topK,
                                            evidenceShareBp: RagContractV1.Pack.evidenceShareBp)

    private enum CodingKeys: String, CodingKey { case fetchK, topK, evidenceShareBp }

    /// Decoding always goes through the validating initializer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(fetchK: try c.decode(Int.self, forKey: .fetchK), topK: try c.decode(Int.self, forKey: .topK),
                          evidenceShareBp: try c.decode(Int.self, forKey: .evidenceShareBp))
        } catch is DecodingError { throw RagTuningError.invalidTuning }
    }

    public static func decodeDecision(_ data: Data) throws -> RagRuntimeTuning {
        struct Envelope: Decodable {
            let status: String
            let parameters: RagRuntimeTuning?
        }
        let value: Envelope
        do { value = try JSONDecoder().decode(Envelope.self, from: data) }
        catch let error as RagTuningError { throw error }
        catch { throw RagTuningError.invalidTuning }
        if value.status == "pending" { return .v1 }
        guard value.status == "accepted", let p = value.parameters else { throw RagTuningError.invalidTuning }
        return p
    }

    public static func bundled() throws -> RagRuntimeTuning { try cached.get() }

    private static let cached: Result<RagRuntimeTuning, Error> = Result {
        try decodeDecision(try EmbeddingDecision.resourceData())
    }
}
