import XCTest
@testable import AINotebookCore

final class CosineTests: XCTestCase {

    func testIdenticalVectorsScoreOne() {
        let a: [Float] = [0.1, 0.2, 0.3, 0.4]
        XCTAssertEqual(Cosine.similarity(a, a), 1.0, accuracy: 1e-5)
    }

    func testOrthogonalVectorsScoreZero() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 1e-5)
    }

    func testOppositeVectorsScoreMinusOne() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        XCTAssertEqual(Cosine.similarity(a, b), -1.0, accuracy: 1e-5)
    }

    func testZeroMagnitudeReturnsZero() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 2, 3]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 1e-5)
    }

    func testMismatchedDimensionsReturnsZero() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1, 2]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 1e-5)
    }
}
