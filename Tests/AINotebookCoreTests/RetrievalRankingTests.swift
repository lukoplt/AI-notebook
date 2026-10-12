import XCTest
@testable import AINotebookCore

final class RetrievalRankingTests: XCTestCase {
    func testIntegerRRFSharedCases() throws {
        let file = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        for c in file["cases"] as! [[String: Any]] where c["lexical"] != nil {
            func refs(_ key: String) -> [ChunkReference] {
                (c[key] as! [NSNumber]).map { .init(chunkId: $0.int64Value, sourceId: 1, revisionId: 1, ord: 0) }
            }
            let actual = try RetrievalRanking.fuse(lexical: refs("lexical"), vector: refs("vector"))
            let expected = c["expected"] as! [[String: NSNumber]]
            XCTAssertEqual(actual.map { $0.reference.chunkId }, expected.map { $0["chunkId"]!.int64Value })
            XCTAssertEqual(actual.map(\.rrfMicro), expected.map { $0["rrfMicro"]!.int64Value })
        }
        let dedupe = try XCTUnwrap((file["cases"] as? [[String: Any]])?.first { $0["name"] as? String == "dedupe" })
        let chunkID = try XCTUnwrap((dedupe["lexical"] as? [NSNumber])?.first).int64Value
        let original = ChunkReference(chunkId: chunkID, sourceId: 1, revisionId: 1, ord: 0)
        let conflicts = [
            ChunkReference(chunkId: chunkID, sourceId: 2, revisionId: 1, ord: 0),
            ChunkReference(chunkId: chunkID, sourceId: 1, revisionId: 2, ord: 0),
            ChunkReference(chunkId: chunkID, sourceId: 1, revisionId: 1, ord: 1)
        ]
        for conflict in conflicts {
            XCTAssertThrowsError(try RetrievalRanking.fuse(lexical: [original, conflict], vector: [])) {
                XCTAssertEqual($0 as? RetrievalError, .revisionMismatch)
            }
            XCTAssertThrowsError(try RetrievalRanking.fuse(lexical: [original], vector: [conflict])) {
                XCTAssertEqual($0 as? RetrievalError, .revisionMismatch)
            }
            XCTAssertThrowsError(try RetrievalRanking.fuse(lexical: [], vector: [original, conflict])) {
                XCTAssertEqual($0 as? RetrievalError, .revisionMismatch)
            }
        }
        for invalidK in [0, -1] {
            XCTAssertThrowsError(try RetrievalRanking.fuse(lexical: [original], vector: [], rrfK: invalidK)) {
                XCTAssertEqual($0 as? RetrievalError, .invalidFetchK)
            }
        }
        let hugeK = try RetrievalRanking.fuse(lexical: [original], vector: [original], rrfK: .max)
        XCTAssertEqual(hugeK.map(\.rrfMicro), [0])
        XCTAssertEqual(hugeK.map(\.reference), [original])
    }
    func testMaskBeforeHeapSharedCase() throws {
        let file = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        let c = (file["cases"] as! [[String:Any]]).first { $0["name"] as? String == "mask-before-heap" }!
        let input = c["rows"] as! [[String:Any]]
        let rows = input.map { r in VectorRow(reference: .init(chunkId: (r["chunkId"] as! NSNumber).int64Value,
            sourceId: (r["sourceId"] as! NSNumber).int64Value, revisionId: (r["revisionId"] as! NSNumber).int64Value, ord: r["ord"] as! Int), values: (r["vector"] as! [NSNumber]).map(\.floatValue)) }
        let eligible = Set(input.filter { ($0["eligible"] as! Int) == 1 }.map { ($0["sourceId"] as! NSNumber).int64Value })
        let found = RetrievalRanking.topK(rows: rows, query: (c["query"] as! [NSNumber]).map(\.floatValue), permittedSources: eligible, k: c["k"] as! Int)
        XCTAssertEqual(found.map { $0.reference.chunkId }, (c["expectedIds"] as! [NSNumber]).map(\.int64Value))
    }

    func testHeapFixtureCases() throws {
        let file = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        for c in file["cases"] as! [[String: Any]] where c["dims"] != nil {
            let name = c["name"] as! String
            let dims = (c["dims"] as! NSNumber).intValue
            guard let input = c["rows"] as? [[String: Any]] else {
                XCTAssertEqual(c["expectedStatus"] as? String, "oversizedVector", name)
                XCTAssertNil(RetrievalSQL.byteWidth(dims: dims), name)
                continue
            }
            let decoded = try input.map { try rawRow($0) }.compactMap { RetrievalSQL.decode($0, dims: dims) }
            XCTAssertEqual(input.count - decoded.count, (c["invalidVectorCount"] as? NSNumber)?.intValue ?? 0, name)
            let permitted = Set(input.filter { ($0["eligible"] as! NSNumber).intValue == 1 }
                .map { ($0["sourceId"] as! NSNumber).int64Value })
            let query = try query(c)
            let k = (c["k"] as! NSNumber).intValue
            let expectedIDs = (c["expectedIds"] as! [NSNumber]).map(\.int64Value)
            let expectedScores = (c["expectedScoreMicros"] as! [NSNumber]).map { $0.floatValue / 1_000_000 }
            // Every supplied order and its reverse must produce the same final
            // bounded heap, including exact ties and replacements at the root.
            for rows in [decoded, Array(decoded.reversed())] {
                let found = RetrievalRanking.topK(rows: rows, query: query, permittedSources: permitted, k: k)
                XCTAssertEqual(found.map { $0.reference.chunkId }, expectedIDs, name)
                XCTAssertEqual(found.count, expectedScores.count, name)
                for (actual, expected) in zip(found, expectedScores) {
                    XCTAssertEqual(actual.score, expected, accuracy: 0.000_001, name)
                }
                XCTAssertLessThanOrEqual(found.count, max(0, k), name)
            }
            if c["expectedStatus"] as? String == "invalidQueryVector" {
                XCTAssertNil(MaskedVectorTopK(query: query, dims: dims, permittedSources: permitted, k: k), name)
            }
        }
    }

    func testSIMDDotWithinTolerance() throws {
        let file = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        let c = try XCTUnwrap((file["cases"] as? [[String: Any]])?.first { $0["name"] as? String == "normalized-dot" })
        let input = try XCTUnwrap(c["rows"] as? [[String: Any]])
        let dims = (c["dims"] as! NSNumber).intValue
        let row = try XCTUnwrap(RetrievalSQL.decode(rawRow(XCTUnwrap(input.first)), dims: dims))
        let query = try query(c)
        let expectedScore = try XCTUnwrap((c["expectedScoreMicros"] as? [NSNumber])?.first).floatValue / 1_000_000
        var normalized = row.values
        XCTAssertTrue(normalized.withUnsafeMutableBufferPointer { MaskedVectorTopK.normalize($0, allowZero: true) })
        var accumulator = try XCTUnwrap(MaskedVectorTopK(query: query, dims: dims,
            permittedSources: [row.reference.sourceId], k: (c["k"] as! NSNumber).intValue))
        normalized.withUnsafeBufferPointer { accumulator.offer(row.reference, normalizedRow: $0) }
        let result = accumulator.sorted()
        XCTAssertEqual(result.map { $0.reference.chunkId }, (c["expectedIds"] as! [NSNumber]).map(\.int64Value))
        XCTAssertEqual(try XCTUnwrap(result.first).score, expectedScore, accuracy: 0.000_001)
        let facade = RetrievalRanking.topK(rows: [row], query: query, permittedSources: [row.reference.sourceId], k: 1)
        XCTAssertEqual(try XCTUnwrap(facade.first).score, expectedScore, accuracy: 0.000_001)
    }

    private func query(_ fixture: [String: Any]) throws -> [Float] {
        if let values = fixture["query"] as? [NSNumber] { return values.map(\.floatValue) }
        return try XCTUnwrap(fixture["queryFloat32Bits"] as? [NSNumber]).map { Float(bitPattern: $0.uint32Value) }
    }

    private func rawRow(_ fixture: [String: Any]) throws -> RawVectorRow {
        let reference = ChunkReference(chunkId: (fixture["chunkId"] as! NSNumber).int64Value,
            sourceId: (fixture["sourceId"] as! NSNumber).int64Value,
            revisionId: (fixture["revisionId"] as! NSNumber).int64Value,
            ord: (fixture["ord"] as! NSNumber).intValue)
        let blob: Data
        if let values = fixture["vector"] as? [NSNumber] {
            blob = EmbeddingVector(values: values.map(\.floatValue)).asData()
        } else if let bits = fixture["float32Bits"] as? [NSNumber] {
            blob = bits.reduce(into: Data()) { bytes, number in
                var littleEndian = number.uint32Value.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            }
        } else {
            let text = try XCTUnwrap(fixture["blobHex"] as? String)
            let bytes = Array(text.utf8)
            XCTAssertEqual(bytes.count % 2, 0)
            blob = Data(try stride(from: 0, to: bytes.count, by: 2).map {
                try XCTUnwrap(UInt8(String(decoding: bytes[$0..<($0 + 2)], as: UTF8.self), radix: 16))
            })
        }
        return RawVectorRow(reference: reference, blob: blob)
    }
}
