import XCTest
@testable import AINotebookCore

final class OllamaClientChatTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testChatStreamsChunksUntilDone() async throws {
        let lines: [Data] = [
            #"{"model":"llama3.2:3b","created_at":"t","message":{"role":"assistant","content":"He"},"done":false}"#.data(using: .utf8)!,
            #"{"model":"llama3.2:3b","created_at":"t","message":{"role":"assistant","content":"llo"},"done":false}"#.data(using: .utf8)!,
            #"{"model":"llama3.2:3b","created_at":"t","message":{"role":"assistant","content":""},"done":true}"#.data(using: .utf8)!
        ]
        StubURLProtocol.enqueue(.ndjson(lines))
        let client = OllamaClient(session: StubURLProtocol.session())

        var collected: [String] = []
        for try await chunk in client.chat(model: "llama3.2:3b", messages: [
            OllamaChatMessage(role: .user, content: "Say hi.")
        ]) {
            collected.append(chunk.message.content)
            if chunk.done { break }
        }
        XCTAssertEqual(collected.joined(), "Hello")
    }
}
