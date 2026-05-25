import XCTest
@testable import AINotebookCore

final class AINotebookVersionTests: XCTestCase {
    func testVersionMatchesExpected() {
        XCTAssertEqual(AINotebookVersion, "0.7.0")
    }

    func testVersionIsSemverShape() {
        let parts = AINotebookVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "Version must have three dot-separated parts")
        for part in parts {
            XCTAssertNotNil(Int(part), "Each part of version must be an integer")
        }
    }
}
