import XCTest
@testable import AINotebookCore

@MainActor
final class FollowupSuggesterTests: XCTestCase {

    final class MockChatClient: ChatStreaming, @unchecked Sendable {
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            let toks = tokens
            return AsyncThrowingStream { continuation in
                Task {
                    for t in toks { continuation.yield(t) }
                    continuation.finish()
                }
            }
        }
    }

    func testParsesAndStripsMarkers() async throws {
        let chat = MockChatClient(tokens: ["What about X?\n2. How does Y work?\n- Z?"])
        let suggester = FollowupSuggester(chat: chat, chatModel: "m")
        let questions = try await suggester.generate(
            userText: "original question", answer: "original answer"
        )
        XCTAssertEqual(questions, ["What about X?", "How does Y work?", "Z?"])
    }
}
