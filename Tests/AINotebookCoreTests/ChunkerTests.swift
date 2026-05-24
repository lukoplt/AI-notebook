import XCTest
@testable import AINotebookCore

final class ChunkerTests: XCTestCase {
    func testShortTextProducesSingleChunk() {
        let drafts = Chunker.chunk("Hello world.")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "Hello world.")
        XCTAssertGreaterThan(drafts[0].tokenCount, 0)
    }

    func testEmptyOrWhitespaceProducesNoChunks() {
        XCTAssertTrue(Chunker.chunk("").isEmpty)
        XCTAssertTrue(Chunker.chunk("   \n\t ").isEmpty)
    }

    func testLongTextSplitsIntoMultipleChunks() {
        let para = String(repeating: "word ", count: 2000)  // ~10 000 chars
        let drafts = Chunker.chunk(para)
        XCTAssertGreaterThan(drafts.count, 1)
        // Every chunk under the hard cap (2 048 chars + a small slack for
        // not breaking mid-word).
        for d in drafts {
            XCTAssertLessThanOrEqual(d.text.count, 2_100, "chunk too big: \(d.text.count)")
        }
    }

    func testChunksOverlap() {
        let para = String(repeating: "word ", count: 2000)
        let drafts = Chunker.chunk(para)
        guard drafts.count >= 2 else { return XCTFail("need at least 2 chunks") }
        // Last 200 chars of chunk N appear at the start of chunk N+1
        // (because of the 256-char overlap window — allow some boundary slack).
        let tail = String(drafts[0].text.suffix(200))
        XCTAssertTrue(
            drafts[1].text.contains(tail.prefix(100)),
            "expected overlap between consecutive chunks"
        )
    }

    func testWindowAndOverlapAreOverridable() {
        let drafts = Chunker.chunk(
            String(repeating: "a ", count: 500),
            windowChars: 200,
            overlapChars: 50
        )
        XCTAssertGreaterThan(drafts.count, 3)
        for d in drafts {
            XCTAssertLessThanOrEqual(d.text.count, 220)
        }
    }
}
