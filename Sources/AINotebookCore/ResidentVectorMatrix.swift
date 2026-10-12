import Accelerate
import Foundation

/// Binary16 storage shared by the resident matrix and the streamed scan, so both score the
/// identical fp32 values (retrieval-resident-v1 §3): a row is L2-normalized (fp64 sum,
/// fp32 result), rounded to IEEE binary16 (round-to-nearest-even) and widened back to fp32
/// before the fp32 dot product with the normalized query.
internal enum HalfPrecision {
    static func encode(_ source: UnsafePointer<Float>, _ target: UnsafeMutablePointer<UInt16>, count: Int) {
        guard count > 0 else { return }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                width: vImagePixelCount(count), rowBytes: count * 4)
        var dst = vImage_Buffer(data: UnsafeMutableRawPointer(target), height: 1,
                                width: vImagePixelCount(count), rowBytes: count * 2)
        vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags))
    }
    static func decode(_ source: UnsafePointer<UInt16>, _ target: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                width: vImagePixelCount(count), rowBytes: count * 2)
        var dst = vImage_Buffer(data: UnsafeMutableRawPointer(target), height: 1,
                                width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
    }
    /// Rounds a normalized fp32 row through binary16 in place (the streamed path).
    static func round(_ row: UnsafeMutableBufferPointer<Float>) {
        guard let base = row.baseAddress, !row.isEmpty else { return }
        let halves = UnsafeMutablePointer<UInt16>.allocate(capacity: row.count)
        defer { halves.deallocate() }
        encode(base, halves, count: row.count)
        decode(halves, base, count: row.count)
    }

    /// Decodes one little-endian fp32 BLOB and L2-normalizes it in place (fp64 arithmetic,
    /// fp32 result; a zero row stays zero). False for a wrong length or a non-finite value.
    /// Shared by the resident load and the streamed scan.
    static func decodeNormalized(_ blob: Data?, into row: UnsafeMutablePointer<Float>, dims: Int,
                                 scratch: UnsafeMutablePointer<Double>) -> Bool {
        guard let blob, blob.count == dims * 4 else { return false }
        #if _endian(big)
        for i in 0..<dims {
            row[i] = Float(bitPattern: UInt32(littleEndian: blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }))
        }
        #else
        _ = blob.copyBytes(to: UnsafeMutableRawBufferPointer(start: row, count: dims * 4))
        #endif
        let n = vDSP_Length(dims)
        vDSP_vspdp(row, 1, scratch, 1, n)
        var squared: Double = 0
        vDSP_dotprD(scratch, 1, scratch, 1, &squared, n)
        // A NaN or infinity anywhere makes the fp64 sum non-finite; finite fp32 squares cannot overflow it.
        guard squared.isFinite else { return false }
        if squared == 0 { return true }
        var norm = squared.squareRoot()
        vDSP_vsdivD(scratch, 1, &norm, scratch, 1, n)
        vDSP_vdpsp(scratch, 1, row, 1, n)
        return true
    }
}

/// One batch of rows loaded for a set of pinned (source, revision) pairs. Owned exclusively
/// by its sync task until it is committed to a matrix, immutable afterwards.
internal final class ResidentBlock: @unchecked Sendable {
    let dims: Int
    let capacity: Int
    let halves: UnsafeMutablePointer<UInt16>
    private(set) var chunkIds: [Int64] = []
    private(set) var sourceIds: [Int64] = []
    private(set) var revisionIds: [Int64] = []
    private(set) var ords: [Int32] = []
    private(set) var invalidBySource: [Int64: Int] = [:]
    private(set) var peakPageBytes: Int64 = 0
    var count: Int { chunkIds.count }

    init(capacity: Int, dims: Int) {
        self.capacity = capacity
        self.dims = dims
        halves = .allocate(capacity: max(1, capacity * dims))
        chunkIds.reserveCapacity(capacity)
        sourceIds.reserveCapacity(capacity)
        revisionIds.reserveCapacity(capacity)
        ords.reserveCapacity(capacity)
    }
    deinit { halves.deallocate() }

    static func charge(rows: Int, dims: Int) -> Int64? {
        guard rows >= 0, dims > 0 else { return nil }
        let (width, a) = Int64(dims).multipliedReportingOverflow(by: 2)
        let (perRow, b) = width.addingReportingOverflow(32)
        let (bytes, c) = Int64(rows).multipliedReportingOverflow(by: perRow)
        return a || b || c ? nil : bytes
    }

    /// Appends one SQL page. Returns false when the page would exceed the reserved capacity.
    func append(_ page: RawVectorPage) -> Bool {
        peakPageBytes = max(peakPageBytes, Int64(page.payloadBytes))
        let row = UnsafeMutablePointer<Float>.allocate(capacity: dims)
        let scratch = UnsafeMutablePointer<Double>.allocate(capacity: dims)
        defer { row.deallocate(); scratch.deallocate() }
        for raw in page.rows {
            guard HalfPrecision.decodeNormalized(raw.blob, into: row, dims: dims, scratch: scratch) else {
                invalidBySource[raw.reference.sourceId, default: 0] += 1
                continue
            }
            guard count < capacity else { return false }
            HalfPrecision.encode(row, halves + count * dims, count: dims)
            chunkIds.append(raw.reference.chunkId)
            sourceIds.append(raw.reference.sourceId)
            revisionIds.append(raw.reference.revisionId)
            ords.append(Int32(clamping: raw.reference.ord))
        }
        return true
    }
}

/// The resident, revision-checked matrix of one generation (retrieval-resident-v1): rows are
/// loaded per pinned (source, revision) pair and kept across queries and writes; a query uses
/// a row only when the row's revision is the query's pinned revision of an allowed source.
/// Mutated and read only by its owning `VectorMatrixCache` actor.
internal final class ResidentVectorMatrix: @unchecked Sendable {
    let dims: Int
    private(set) var blocks: [ResidentBlock] = []
    /// Source id -> the revision whose rows are loaded (possibly zero rows).
    private(set) var loaded: [Int64: Int64] = [:]
    private var rowsBySource: [Int64: Int] = [:]
    private var invalidBySource: [Int64: Int] = [:]
    private(set) var rows = 0
    private(set) var garbageRows = 0
    private(set) var peakPageBytes: Int64 = 0

    init(dims: Int) { self.dims = dims }

    var bytes: Int64 { ResidentBlock.charge(rows: blocks.reduce(0) { $0 + $1.count }, dims: dims) ?? .max }
    var invalidVectorCount: Int { invalidBySource.values.reduce(0, +) }

    func missing(_ pins: [Int64: Int64]) -> [Int64: Int64] {
        pins.filter { loaded[$0.key] != $0.value }
    }

    func commit(_ block: ResidentBlock, pairs: [Int64: Int64]) {
        for (source, revision) in pairs {
            if let old = loaded[source], old != revision { garbageRows += rowsBySource[source] ?? 0 }
            loaded[source] = revision
            rowsBySource[source] = 0
            invalidBySource[source] = block.invalidBySource[source]
        }
        for index in 0..<block.count where pairs[block.sourceIds[index]] == block.revisionIds[index] {
            rowsBySource[block.sourceIds[index], default: 0] += 1
        }
        rows += block.count
        peakPageBytes = max(peakPageBytes, block.peakPageBytes)
        if block.count > 0 { blocks.append(block) }
    }

    /// Copies the live rows (loaded revision of each source) into one block.
    func compacted() -> ResidentVectorMatrix {
        let block = ResidentBlock(capacity: rows - garbageRows, dims: dims)
        for source in blocks {
            for index in 0..<source.count where loaded[source.sourceIds[index]] == source.revisionIds[index] {
                block.appendCopy(from: source, index: index)
            }
        }
        let target = ResidentVectorMatrix(dims: dims)
        target.loaded = loaded
        target.rowsBySource = rowsBySource
        target.invalidBySource = invalidBySource
        target.peakPageBytes = peakPageBytes
        target.rows = block.count
        if block.count > 0 { target.blocks = [block] }
        return target
    }

    /// Masked top-K over binary16 rows widened to fp32; ties by smaller chunk id. A row
    /// counts only when its revision is the allowed (pinned and permitted) revision of its
    /// source. Rows of one source are adjacent, so the dictionary is probed per source run.
    func topK(query: [Float], allowed: [Int64: Int64], k: Int) -> [ScoredChunk] {
        guard var heap = MaskedVectorTopK(query: query, dims: dims, permittedSources: Set(allowed.keys), k: k) else { return [] }
        let q = heap.normalizedQuery
        let stripe = 256, dims = self.dims, n = vDSP_Length(dims)
        let widened = UnsafeMutablePointer<Float>.allocate(capacity: stripe * dims)
        let scores = UnsafeMutablePointer<Float>.allocate(capacity: stripe)
        let flags = UnsafeMutablePointer<Bool>.allocate(capacity: stripe)
        defer { widened.deallocate(); scores.deallocate(); flags.deallocate() }
        q.withUnsafeBufferPointer { qb in
            let qp = qb.baseAddress!
            for block in blocks {
                let count = block.count, halves = block.halves
                block.chunkIds.withUnsafeBufferPointer { chunks in
                block.ords.withUnsafeBufferPointer { ords in
                block.sourceIds.withUnsafeBufferPointer { sources in
                block.revisionIds.withUnsafeBufferPointer { revisions in
                    var lastSource = Int64.min, lastRevision: Int64? = nil
                    var start = 0
                    while start < count {
                        let end = min(count, start + stripe)
                        var any = false
                        for index in start..<end {
                            if sources[index] != lastSource { lastSource = sources[index]; lastRevision = allowed[lastSource] }
                            let ok = lastRevision == revisions[index]
                            flags[index - start] = ok
                            if ok { any = true }
                        }
                        if any {
                            HalfPrecision.decode(halves + start * dims, widened, count: (end - start) * dims)
                            for offset in 0..<(end - start) where flags[offset] {
                                // Same kernel and argument order as MaskedVectorTopK.score.
                                vDSP_dotpr(qp, 1, widened + offset * dims, 1, scores + offset, n)
                                let index = start + offset, score = scores[offset]
                                guard heap.admits(score: score, chunkId: chunks[index]) else { continue }
                                heap.insert(ScoredChunk(reference: ChunkReference(chunkId: chunks[index], sourceId: sources[index],
                                    revisionId: revisions[index], ord: Int(ords[index])), score: score))
                            }
                        }
                        start = end
                    }
                }}}}
            }
        }
        return heap.sorted()
    }
}

extension ResidentBlock {
    fileprivate func appendCopy(from source: ResidentBlock, index: Int) {
        precondition(count < capacity && source.dims == dims)
        (halves + count * dims).update(from: source.halves + index * dims, count: dims)
        chunkIds.append(source.chunkIds[index])
        sourceIds.append(source.sourceIds[index])
        revisionIds.append(source.revisionIds[index])
        ords.append(source.ords[index])
    }
}
