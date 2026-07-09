import XCTest
@testable import AINotebookCore

final class OpenWebUIAdapterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    func testPostsToApiChatCompletionsNotV1() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("data: [DONE]\n".utf8))
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://192.168.1.50:3000/", apiKey: "sk-owui", session: makeMockSession())
        _ = try await collect(adapter.stream(model: "llama3.2", messages: [ChatTurn(role: .user, content: "hi")]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "http://192.168.1.50:3000/api/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-owui")
    }

    func testStreamsTokens() async throws {
        MockURLProtocol.handler = { req in
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"index\":0}]}\n" +
                       "data: {\"choices\":[{\"delta\":{\"content\":\", LAN\"},\"index\":0}]}\n" +
                       "data: [DONE]\n"
            return (httpResponse(req.url!, status: 200), Data(body.utf8))
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://h:3000", apiKey: nil, session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "llama3.2", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["Hello", ", LAN"])
    }

    func testKeylessRequestHasNoAuthHeader() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("data: [DONE]\n".utf8))
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://h:3000", apiKey: nil, session: makeMockSession())
        _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertNil(try XCTUnwrap(captured).value(forHTTPHeaderField: "Authorization"))
    }

    func testStatus401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://h:3000", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testListModelsUsesApiModelsAndNameAsDisplayName() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"data":[{"id":"gpt-4o","name":"GPT-4o (cloud)","object":"model"},{"id":"llama3.2","name":"Llama 3.2","object":"model"}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let models = try await OpenWebUIChatAdapter.listModels(baseURL: "http://h:3000", apiKey: "k", session: makeMockSession())
        XCTAssertEqual(captured?.url?.absoluteString, "http://h:3000/api/models")
        XCTAssertEqual(models.map(\.label), ["GPT-4o (cloud)", "Llama 3.2"])
        XCTAssertEqual(models.map(\.id), ["gpt-4o", "llama3.2"])
    }

    func testListModelsNetworkErrorPropagates() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await OpenWebUIChatAdapter.listModels(baseURL: "http://192.168.1.99:9999", apiKey: nil, session: makeMockSession())
            XCTFail("expected throw")
        } catch { /* propagates so Test connection reports it */ }
    }
}
