import Accelerate

public enum RetrievalRanking {
    /// Integer RRF over the branches; `path` (retrieval-paths-v1 §4) is empty unless the
    /// question's terms match file paths.
    public static func fuse(lexical: [ChunkReference], vector: [ChunkReference], path: [ChunkReference] = [],
                            rrfK: Int = 60) throws -> [RankedChunk] {
        guard rrfK > 0 else { throw RetrievalError.invalidFetchK }
        var scores: [Int64: Int64] = [:], refs: [Int64: ChunkReference] = [:]
        for branch in [lexical, vector, path] {
            var seen = Set<Int64>(), rank = 0
            for ref in branch {
                if let previous = refs[ref.chunkId], previous != ref { throw RetrievalError.revisionMismatch }
                guard seen.insert(ref.chunkId).inserted else { continue }
                rank += 1
                refs[ref.chunkId] = ref
                let (denominator, overflow) = rrfK.addingReportingOverflow(rank)
                scores[ref.chunkId, default: 0] += overflow ? 0 : 1_000_000 / Int64(denominator)
            }
        }
        return scores.map { RankedChunk(reference: refs[$0.key]!, rrfMicro: $0.value) }
            .sorted { $0.rrfMicro == $1.rrfMicro ? $0.reference.chunkId < $1.reference.chunkId : $0.rrfMicro > $1.rrfMicro }
    }

    /// Convenience facade for already decoded rows. Production uses generation
    /// dimensions and offers pages to one accumulator for the entire scan.
    public static func topK(rows: [VectorRow], query: [Float], permittedSources: Set<Int64>, k: Int) -> [ScoredChunk] {
        guard let dims = rows.first(where: { !$0.values.isEmpty && $0.values.allSatisfy(\.isFinite) })?.values.count,
              var top = MaskedVectorTopK(query: query, dims: dims, permittedSources: permittedSources, k: k) else { return [] }
        for row in rows where row.values.count == dims && permittedSources.contains(row.reference.sourceId) {
            var values = row.values
            guard values.withUnsafeMutableBufferPointer({ MaskedVectorTopK.normalize($0, allowZero: true) }) else { continue }
            values.withUnsafeBufferPointer { top.offer(row.reference, normalizedRow: $0) }
        }
        return top.sorted()
    }
}


internal struct MaskedVectorTopK {
    private let query: [Float]
    private let permitted: Set<Int64>
    private let k: Int
    private var heap: [ScoredChunk] = []
    static func normalize(_ row: UnsafeMutableBufferPointer<Float>, allowZero: Bool) -> Bool {
        guard !row.isEmpty else { return false }
        var squared: Double = 0
        for x in row {
            guard x.isFinite else { return false }
            squared += Double(x) * Double(x)
        }
        guard squared.isFinite else { return false }
        if squared == 0 { return allowZero }
        let norm = squared.squareRoot()
        for i in row.indices { row[i] = Float(Double(row[i]) / norm) }
        return true
    }
    init?(query: [Float], dims: Int, permittedSources: Set<Int64>, k: Int) {
        guard k > 0, dims > 0, query.count == dims else { return nil }
        var normalized = query
        guard normalized.withUnsafeMutableBufferPointer({ Self.normalize($0, allowZero: false) }) else { return nil }
        self.query = normalized; self.permitted = permittedSources; self.k = k
    }
    private static func better(_ a: ScoredChunk, _ b: ScoredChunk) -> Bool {
        a.score > b.score || (a.score == b.score && a.reference.chunkId < b.reference.chunkId)
    }
    mutating func offer(_ reference: ChunkReference, normalizedRow row: UnsafeBufferPointer<Float>) {
        guard permitted.contains(reference.sourceId), row.count == query.count else { return }
        let score = Self.score(query, row)
        guard score.isFinite else { return }
        insert(ScoredChunk(reference: reference, score: score))
    }
    /// The one scoring kernel of every vector path (fp32 dot product of normalized rows).
    static func score(_ query: [Float], _ row: UnsafeBufferPointer<Float>) -> Float {
        var score: Float = 0
        query.withUnsafeBufferPointer { q in
            vDSP_dotpr(q.baseAddress!, 1, row.baseAddress!, 1, &score, vDSP_Length(q.count))
        }
        return score
    }
    var normalizedQuery: [Float] { query }
    /// True when a finite score would enter the heap; callers that already masked the row
    /// use it to skip building a reference for rows that cannot place.
    func admits(score: Float, chunkId: Int64) -> Bool {
        guard score.isFinite else { return false }
        guard heap.count == k else { return true }
        return score > heap[0].score || (score == heap[0].score && chunkId < heap[0].reference.chunkId)
    }
    /// Inserts an already masked, finite candidate.
    mutating func insert(_ candidate: ScoredChunk) {
        if heap.count < k {
            heap.append(candidate)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard Self.better(heap[parent], heap[i]) else { break }
                heap.swapAt(parent, i); i = parent
            }
            return
        }
        guard Self.better(candidate, heap[0]) else { return }
        heap[0] = candidate
        var i = 0
        while 2 * i + 1 < heap.count {
            let left = 2 * i + 1, right = left + 1
            var worst = left
            if right < heap.count && Self.better(heap[left], heap[right]) { worst = right }
            guard Self.better(heap[i], heap[worst]) else { break }
            heap.swapAt(i, worst); i = worst
        }
    }
    func sorted() -> [ScoredChunk] { heap.sorted(by: Self.better) }
}
