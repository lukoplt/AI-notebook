import XCTest
@testable import AINotebookCore

final class SystemPromptTests: XCTestCase {

    func testRendersHitsAsNumberedBlocks() {
        let hits = [
            RetrievalHit(chunkId: 10, sourceId: 1, score: 0.9, snippet: "alpha facts"),
            RetrievalHit(chunkId: 11, sourceId: 2, score: 0.7, snippet: "beta facts")
        ]
        let prompt = SystemPrompt.compose(hits: hits)
        XCTAssertTrue(prompt.contains("[1] alpha facts"))
        XCTAssertTrue(prompt.contains("[2] beta facts"))
    }

    func testIncludesCitationInstruction() {
        let prompt = SystemPrompt.compose(hits: [])
        XCTAssertTrue(prompt.lowercased().contains("cite"))
        XCTAssertTrue(prompt.contains("[N]"))
    }

    func testNoHitsStillProducesValidPrompt() {
        let prompt = SystemPrompt.compose(hits: [])
        XCTAssertFalse(prompt.isEmpty)
    }
}
