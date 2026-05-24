import XCTest
@testable import AINotebookCore

final class CitationParserTests: XCTestCase {

    func testFindsSingleCitation() {
        let markers = CitationParser.markers(in: "The sky is blue [1].")
        XCTAssertEqual(markers, [1])
    }

    func testFindsMultipleCitationsInOrder() {
        let markers = CitationParser.markers(in: "First [2]. Second [5]. Third [2].")
        XCTAssertEqual(markers, [2, 5, 2])
    }

    func testIgnoresMalformedMarkers() {
        let markers = CitationParser.markers(in: "[abc] [1.2] [-3] [1]")
        XCTAssertEqual(markers, [1])
    }

    func testHandlesAdjacentMarkers() {
        let markers = CitationParser.markers(in: "Both true [1][3].")
        XCTAssertEqual(markers, [1, 3])
    }

    func testEmptyOrNoMatchReturnsEmpty() {
        XCTAssertEqual(CitationParser.markers(in: ""), [])
        XCTAssertEqual(CitationParser.markers(in: "no markers here"), [])
    }
}
