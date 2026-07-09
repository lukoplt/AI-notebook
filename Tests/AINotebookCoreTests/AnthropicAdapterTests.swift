import XCTest
@testable import AINotebookCore

final class AnthropicAdapterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    // `static` (not an instance method as in the brief): `self.sse(...)` is
    // captured inside a `@Sendable` closure (`MockURLProtocol.handler`'s
    // type), and `XCTestCase` is not `Sendable`, so that capture fails
    // strict concurrency checking ("capture of 'self' with non-Sendable
    // type … in a '@Sendable' closure"). The function touches no instance
    // state, so `static` (called as `Self.sse(...)`) sidesteps the capture
    // entirely — same fix Task 5 applied to `sseBody`.
    private static func sse(_ payloads: [String]) -> Data {
        Data((payloads.map { "data: \($0)" }.joined(separator: "\n") + "\n").utf8)
    }

    func testStreamsTextDeltas() async throws {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), Self.sse([
                #"{"type":"message_start","message":{}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                #"{"type":"message_stop"}"#
            ]))
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "sk-ant", session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "claude-sonnet-4-6", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["Hel", "lo"])
    }

    func testSystemTurnHoistedToTopLevelField() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Self.sse([#"{"type":"message_stop"}"#]))
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "sk-ant", session: makeMockSession())
        _ = try await collect(adapter.stream(model: "claude-sonnet-4-6", messages: [
            ChatTurn(role: .system, content: "Be concise."),
            ChatTurn(role: .user, content: "Hello"),
            ChatTurn(role: .assistant, content: "Hi!"),
            ChatTurn(role: .user, content: "More")
        ]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""system":"Be concise.""#), body)
        XCTAssertFalse(body.contains(#""role":"system""#), "system must NOT appear in messages: \(body)")
        XCTAssertTrue(body.contains(#""max_tokens":8192"#), body)
        XCTAssertTrue(body.contains(#""stream":true"#), body)
        XCTAssertTrue(body.contains(#""role":"assistant""#), body)
    }

    func testRefusalStopReasonThrows() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), Self.sse([
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#
            ]))
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .refusal)
        } catch { XCTFail("expected ProviderError.refusal, got \(error)") }
    }

    func testStatus401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testListModelsParsesDisplayName() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"data":[{"id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6"},{"id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5"}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let models = try await AnthropicChatAdapter.listModels(baseURL: "https://api.anthropic.com", apiKey: "sk-ant", session: makeMockSession())
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(models.contains(ProviderModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6")))
    }

    func testDefaultModelsFallbackList() {
        let ids = AnthropicChatAdapter.defaultModels.map(\.id)
        XCTAssertEqual(ids, ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-fable-5"])
    }
}
