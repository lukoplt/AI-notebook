import XCTest
@testable import AINotebookCore

final class OllamaClientDetectAndListTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.reset()
    }

    private func makeClient() -> OllamaClient {
        OllamaClient(session: StubURLProtocol.session())
    }

    func testDetectTrueOn200() async throws {
        StubURLProtocol.enqueue(.json(#"{"models":[]}"#.data(using: .utf8)!))
        let client = makeClient()
        let isUp = await client.detect()
        XCTAssertTrue(isUp)
    }

    func testDetectFalseOnConnectionRefused() async {
        StubURLProtocol.enqueue(.connectionRefused())
        let client = makeClient()
        let isUp = await client.detect()
        XCTAssertFalse(isUp)
    }

    func testListModelsReturnsParsedList() async throws {
        let json = #"{"models":[{"name":"llama3.2:3b","modified_at":"x","size":1,"digest":"d","details":{"format":"gguf","family":"llama","parameter_size":"3B","quantization_level":"Q4"}}]}"#
        StubURLProtocol.enqueue(.json(json.data(using: .utf8)!))
        let client = makeClient()
        let models = try await client.listModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].name, "llama3.2:3b")
    }

    func testListModelsThrowsOnHttpError() async {
        StubURLProtocol.enqueue(.json(Data("oops".utf8), status: 500))
        let client = makeClient()
        do {
            _ = try await client.listModels()
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
