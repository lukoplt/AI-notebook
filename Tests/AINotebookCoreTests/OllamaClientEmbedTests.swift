import XCTest
@testable import AINotebookCore

final class OllamaClientEmbedTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testEmbedReturnsVectors() async throws {
        let body = #"{"embeddings":[[0.1,0.2],[0.3,0.4]]}"#
        StubURLProtocol.enqueue(.json(body.data(using: .utf8)!))
        let client = OllamaClient(session: StubURLProtocol.session())
        let vectors = try await client.embed(model: "nomic-embed-text", input: ["a", "b"])
        XCTAssertEqual(vectors, [[0.1, 0.2], [0.3, 0.4]])
    }

    func testEmbedThrowsOnHttp404() async {
        StubURLProtocol.enqueue(.json(Data("nope".utf8), status: 404))
        let client = OllamaClient(session: StubURLProtocol.session())
        do {
            _ = try await client.embed(model: "x", input: ["y"])
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
