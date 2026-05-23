import XCTest
@testable import AINotebookCore

final class OllamaPullEventTests: XCTestCase {
    func testDecodeStartStatus() throws {
        let json = #"{"status":"pulling manifest"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(OllamaPullEvent.self, from: json)
        XCTAssertEqual(event.status, "pulling manifest")
        XCTAssertNil(event.total)
        XCTAssertNil(event.completed)
        XCTAssertNil(event.digest)
    }

    func testDecodeProgressEvent() throws {
        let json = """
        {"status":"downloading","digest":"sha256:abc","total":2019377664,"completed":1000000}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(OllamaPullEvent.self, from: json)
        XCTAssertEqual(event.status, "downloading")
        XCTAssertEqual(event.digest, "sha256:abc")
        XCTAssertEqual(event.total, 2_019_377_664)
        XCTAssertEqual(event.completed, 1_000_000)
        XCTAssertEqual(event.fractionComplete!, 1_000_000.0 / 2_019_377_664.0, accuracy: 1e-9)
    }

    func testFractionCompleteIsNilWhenMissing() throws {
        let json = #"{"status":"verifying"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(OllamaPullEvent.self, from: json)
        XCTAssertNil(event.fractionComplete)
    }

    func testIsTerminalSuccess() {
        let success = OllamaPullEvent(status: "success", digest: nil, total: nil, completed: nil)
        XCTAssertTrue(success.isTerminalSuccess)

        let mid = OllamaPullEvent(status: "downloading", digest: nil, total: 100, completed: 50)
        XCTAssertFalse(mid.isTerminalSuccess)
    }
}
