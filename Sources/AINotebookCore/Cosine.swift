import Accelerate
import Foundation

public enum Cosine {

    /// Cosine similarity in [-1, 1]. Returns 0 when either input is zero-magnitude
    /// or the dimensions don't match.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var magA: Float = 0
        var magB: Float = 0
        vDSP_svesq(a, 1, &magA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &magB, vDSP_Length(b.count))
        let denom = sqrtf(magA) * sqrtf(magB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
