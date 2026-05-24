import XCTest
@testable import AINotebookCore

final class EmbeddingVectorTests: XCTestCase {

    func testRoundTripsThroughData() {
        let original = EmbeddingVector(values: [0.1, -0.2, 3.14, -42.0])
        let data = original.asData()
        XCTAssertEqual(data.count, 4 * 4)  // 4 floats × 4 bytes each
        let decoded = try? EmbeddingVector(data: data)
        XCTAssertEqual(decoded?.values, original.values)
        XCTAssertEqual(decoded?.dim, 4)
    }

    func testRejectsMisalignedData() {
        let bytes = Data([0x00, 0x01, 0x02])  // 3 bytes — not a multiple of 4
        XCTAssertThrowsError(try EmbeddingVector(data: bytes))
    }

    func testDimReportsCount() {
        let v = EmbeddingVector(values: Array(repeating: Float(0.5), count: 768))
        XCTAssertEqual(v.dim, 768)
    }
}
