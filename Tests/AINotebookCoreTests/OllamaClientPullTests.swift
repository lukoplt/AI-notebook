import XCTest
@testable import AINotebookCore

final class OllamaClientPullTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testPullEmitsEventsThenCompletes() async throws {
        let lines: [Data] = [
            #"{"status":"pulling manifest"}"#.data(using: .utf8)!,
            #"{"status":"downloading","digest":"sha256:abc","total":1000,"completed":500}"#.data(using: .utf8)!,
            #"{"status":"downloading","digest":"sha256:abc","total":1000,"completed":1000}"#.data(using: .utf8)!,
            #"{"status":"success"}"#.data(using: .utf8)!
        ]
        StubURLProtocol.enqueue(.ndjson(lines))

        let client = OllamaClient(session: StubURLProtocol.session())
        var collected: [OllamaPullEvent] = []
        for try await event in client.pullModel(name: "llama3.2:3b") {
            collected.append(event)
        }
        XCTAssertEqual(collected.count, 4)
        XCTAssertEqual(collected[0].status, "pulling manifest")
        XCTAssertEqual(collected[3].status, "success")
        XCTAssertTrue(collected[3].isTerminalSuccess)
    }

    func testPullThrowsOnHttp500() async {
        StubURLProtocol.enqueue(.json(Data("nope".utf8), status: 500))
        let client = OllamaClient(session: StubURLProtocol.session())
        do {
            for try await _ in client.pullModel(name: "llama3.2:3b") {}
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
