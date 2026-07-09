import XCTest
@testable import AINotebookCore

final class OpenAIAdapterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // `static` (not an instance method as in the brief): the brief's
    // `self.sseBody(...)` is captured inside a `@Sendable` closure
    // (`MockURLProtocol.handler`'s type), and `XCTestCase` is not
    // `Sendable`, so that capture fails strict concurrency checking
    // ("capture of 'self' with non-Sendable type … in a '@Sendable'
    // closure"). The function touches no instance state, so `static`
    // (called as `Self.sseBody(...)`) sidesteps the capture entirely.
    private static func sseBody(_ payloads: [String]) -> Data {
        Data((payloads.map { "data: \($0)" }.joined(separator: "\n") + "\n").utf8)
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    // ── streaming ────────────────────────────────────────────────────────

    func testStreamsTokensAndStopsAtDone() async throws {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), Self.sseBody([
                #"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#,
                #"{"choices":[{"delta":{"content":", world"},"index":0}]}"#,
                "[DONE]",
                #"{"choices":[{"delta":{"content":"IGNORED"},"index":0}]}"#
            ]))
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "sk-k", session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "gpt-4o", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["Hello", ", world"])
    }

    func testChatRequestShape() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Self.sseBody(["[DONE]"]))
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com/", apiKey: "sk-abc", session: makeMockSession())
        _ = try await collect(adapter.stream(model: "gpt-4o", messages: [
            ChatTurn(role: .system, content: "Be concise."),
            ChatTurn(role: .user, content: "Hello")
        ]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-abc")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"gpt-4o""#), body)
        XCTAssertTrue(body.contains(#""role":"system""#), "system turn stays in messages for OpenAI shape")
        XCTAssertTrue(body.contains(#""stream":true"#), body)
    }

    func testNoAuthHeaderWithoutKey() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Self.sseBody(["[DONE]"]))
        }
        let adapter = OpenAIChatAdapter(baseURL: "http://localhost:1234", apiKey: nil, session: makeMockSession())
        _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertNil(try XCTUnwrap(captured).value(forHTTPHeaderField: "Authorization"))
    }

    func testStatus401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testStatus429ThrowsRateLimitWithRetryAfter() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 429, headers: ["Retry-After": "7"]), Data())
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .rateLimit(retryAfterSeconds: 7))
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testStatus500ThrowsHTTP() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 500), Data())
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .http(let code, _) = e else { return XCTFail("expected .http, got \(e)") }
            XCTAssertEqual(code, 500)
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testMalformedSSELinesAreSkipped() async throws {
        MockURLProtocol.handler = { req in
            let body = "data: not-json\n" +
                       "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"index\":0}]}\n" +
                       "data: [DONE]\n"
            return (httpResponse(req.url!, status: 200), Data(body.utf8))
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["ok"])
    }

    func testEmptyBaseURLThrowsDecodingNotCrash() async {
        let adapter = OpenAIChatAdapter(baseURL: "", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .decoding = e else { return XCTFail("expected .decoding, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    // ── model listing ────────────────────────────────────────────────────

    func testListModelsParsesAndSorts() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"object":"list","data":[{"id":"gpt-4o"},{"id":"babbage-002"}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let models = try await OpenAIChatAdapter.listModels(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(models.map(\.id), ["babbage-002", "gpt-4o"])
    }

    func testListModels401Throws() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        do {
            _ = try await OpenAIChatAdapter.listModels(baseURL: "https://api.openai.com", apiKey: "bad", session: makeMockSession())
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testListModelsNetworkErrorPropagates() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await OpenAIChatAdapter.listModels(baseURL: "http://192.168.1.99:9999", apiKey: nil, session: makeMockSession())
            XCTFail("expected throw")
        } catch { /* URLError propagates — Test connection shows it (Phase 1 lesson) */ }
    }

    // ── embeddings ───────────────────────────────────────────────────────

    func testEmbeddingsRequestAndParsing() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"object":"list","data":[{"embedding":[0.1,0.2]},{"embedding":[0.3,0.4]}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let adapter = OpenAIEmbeddingAdapter(baseURL: "https://api.openai.com", apiKey: "sk-k", session: makeMockSession())
        let vectors = try await adapter.embed(model: "text-embedding-3-small", inputs: ["a", "b"])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/embeddings")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-k")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"text-embedding-3-small""#), body)
        XCTAssertTrue(body.contains(#""input":["a","b"]"#), body)
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], [0.1, 0.2], accuracy: 0.0001)
        XCTAssertEqual(vectors[1], [0.3, 0.4], accuracy: 0.0001)
    }

    func testEmbeddings401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = OpenAIEmbeddingAdapter(baseURL: "https://api.openai.com", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await adapter.embed(model: "m", inputs: ["a"])
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }
}

/// Float-array comparison helper.
func XCTAssertEqual(_ lhs: [Float], _ rhs: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (l, r) in zip(lhs, rhs) {
        XCTAssertEqual(l, r, accuracy: accuracy, file: file, line: line)
    }
}
