import Foundation

/// Pure complete-input vector kernels (benchmark-v1 §2).
public enum EmbeddingInput {
    /// Balanced Unicode-scalar split; the left half is the shorter one for odd counts.
    public static func bisect(_ text: String) throws -> (String, String) {
        let s = Array(text.unicodeScalars)
        guard s.count > 1 else { throw EmbeddingProfileError(code: "inputCannotFit") }
        let n = s.count / 2
        var left = String.UnicodeScalarView(), right = String.UnicodeScalarView()
        left.append(contentsOf: s[..<n])
        right.append(contentsOf: s[n...])
        return (String(left), String(right))
    }

    /// Prefix projection to `dims`, L2-normalized in double.
    public static func project(_ vector: [Float], nativeDims: Int, dims: Int) throws -> [Float] {
        guard vector.count == nativeDims, dims > 0, dims <= nativeDims,
              vector.allSatisfy({ $0.isFinite }) else {
            throw EmbeddingProfileError(code: "invalidEmbedding")
        }
        return try normalize(vector.prefix(dims).map(Double.init))
    }

    /// Scalar-length-weighted mean of accepted leaves, L2-normalized once.
    public static func pool(_ vectors: [[Float]], scalarWeights: [Int]) throws -> [Float] {
        guard let first = vectors.first, !first.isEmpty, vectors.count == scalarWeights.count,
              scalarWeights.allSatisfy({ $0 > 0 }),
              vectors.allSatisfy({ $0.count == first.count && $0.allSatisfy(\.isFinite) }) else {
            throw EmbeddingProfileError(code: "invalidEmbedding")
        }
        var sum = Array(repeating: 0.0, count: first.count)
        for (v, w) in zip(vectors, scalarWeights) {
            for d in sum.indices { sum[d] += Double(v[d]) * Double(w) }
        }
        return try normalize(sum)
    }

    private static func normalize(_ values: [Double]) throws -> [Float] {
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { throw EmbeddingProfileError(code: "invalidEmbedding") }
        let out = values.map { Float($0 / norm) }
        guard out.allSatisfy(\.isFinite) else { throw EmbeddingProfileError(code: "invalidEmbedding") }
        return out
    }
}
