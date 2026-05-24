import XCTest
@testable import AINotebookCore

final class OllamaClientDeleteTests: XCTestCase {

    override func setUp() { StubURLProtocol.reset() }

    func testDeleteSendsCorrectRequest() async throws {
        StubURLProtocol.enqueue(.json(Data(), status: 200))
        let client = OllamaClient(session: StubURLProtocol.session())
        try await client.deleteModel(name: "llama3.2:3b")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/delete")
        XCTAssertEqual(request.httpMethod, "DELETE")
        let body = try XCTUnwrap(request.httpBodyStreamData())
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(decoded["name"], "llama3.2:3b")
    }

    func testDeleteThrowsOnHttp404() async throws {
        StubURLProtocol.enqueue(.json(Data("not found".utf8), status: 404))
        let client = OllamaClient(session: StubURLProtocol.session())
        do {
            try await client.deleteModel(name: "ghost")
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

private extension URLRequest {
    func httpBodyStreamData() throws -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
