import XCTest
@testable import AINotebookCore

final class OllamaWireTypesTests: XCTestCase {
    func testChatRequestEncodes() throws {
        let req = OllamaChatRequest(
            model: "llama3.2:3b",
            messages: [
                OllamaChatMessage(role: .system, content: "You are helpful."),
                OllamaChatMessage(role: .user, content: "Hi.")
            ],
            stream: true,
            options: nil
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "llama3.2:3b")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
    }

    func testChatChunkDecode() throws {
        let json = """
        {"model":"llama3.2:3b","created_at":"2024-09-25T12:00:00Z","message":{"role":"assistant","content":"Hi"},"done":false}
        """.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: json)
        XCTAssertEqual(chunk.message.content, "Hi")
        XCTAssertEqual(chunk.message.role, .assistant)
        XCTAssertFalse(chunk.done)
    }

    func testEmbedRequestEncodesArrayInput() throws {
        let req = OllamaEmbedRequest(model: "nomic-embed-text", input: ["a", "b"])
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "nomic-embed-text")
        XCTAssertEqual(json["input"] as? [String], ["a", "b"])
    }

    func testEmbedResponseDecodes() throws {
        let json = """
        {"embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]]}
        """.data(using: .utf8)!
        let res = try JSONDecoder().decode(OllamaEmbedResponse.self, from: json)
        XCTAssertEqual(res.embeddings.count, 2)
        XCTAssertEqual(res.embeddings[0], [0.1, 0.2, 0.3])
    }
}
