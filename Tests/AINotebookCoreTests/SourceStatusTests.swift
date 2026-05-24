import XCTest
@testable import AINotebookCore

final class SourceStatusTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(SourceStatus.pending.rawValue, "pending")
        XCTAssertEqual(SourceStatus.chunking.rawValue, "chunking")
        XCTAssertEqual(SourceStatus.ready.rawValue, "ready")
        XCTAssertEqual(SourceStatus.error.rawValue, "error")
    }

    func testIsTerminal() {
        XCTAssertFalse(SourceStatus.pending.isTerminal)
        XCTAssertFalse(SourceStatus.chunking.isTerminal)
        XCTAssertTrue(SourceStatus.ready.isTerminal)
        XCTAssertTrue(SourceStatus.error.isTerminal)
    }
}
