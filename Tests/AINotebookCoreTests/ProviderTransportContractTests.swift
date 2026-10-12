import Foundation
import XCTest
@testable import AINotebookCore

final class ProviderTransportContractTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await token in stream { tokens.append(token) }
        return tokens
    }

    private func adapter(_ type: ProviderType, root: String) -> any ChatStreaming {
        let session = StubURLProtocol.session()
        switch type {
        case .ollama: return OllamaClient(baseURL: URL(string: root)!, session: session)
        case .anthropic: return AnthropicChatAdapter(baseURL: root, apiKey: "k", session: session)
        case .openai, .openaiCompatible: return OpenAIChatAdapter(baseURL: root, apiKey: "k", session: session)
        case .openwebui: return OpenWebUIChatAdapter(baseURL: root, apiKey: "k", session: session)
        }
    }
    private func finish(_ type: ProviderType) {
        let body = type == .ollama
            ? "{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n"
            : type == .anthropic ? "data: {\"type\":\"message_stop\"}\n" : "data: [DONE]\n"
        StubURLProtocol.enqueue(.json(Data(body.utf8)))
    }
    func testAPIRootFixture() throws {
        let rows = try SharedFixtures.json("contracts/api-root-v1.json")["cases"] as! [[String: Any]]
        for row in rows {
            let type = ProviderType(rawValue: row["type"] as! String)!
            let endpoint = ProviderEndpoint(rawValue: row["endpoint"] as! String)!
            do {
                let raw = row["baseURL"] as! String
                let root = row["legacy"] as! Bool
                    ? try ProviderAPIRoot.convertLegacy(type: type, baseURL: raw) : raw
                let url = try ProviderAPIRoot.build(type: type, baseURL: root, endpoint: endpoint)
                XCTAssertNil(row["expectedError"], row["name"] as! String)
                XCTAssertEqual(url.absoluteString, row["expectedURL"] as? String, row["name"] as! String)
            } catch let error as ProviderConfigurationError {
                XCTAssertEqual(error.rawValue, row["expectedError"] as? String, row["name"] as! String)
            }
        }
    }
    func testOptionsReachAllAdapters() async throws {
        let rows = try SharedFixtures.json("contracts/provider-options-v1.json")["cases"] as! [[String: Any]]
        for row in rows {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: row["type"] as! String)!
            finish(type)
            let options = ChatRequestOptions(runtimeContext: row["runtimeContext"] as! Int,
                                             maxOutputTokens: row["maxOutputTokens"] as! Int)
            for try await _ in adapter(type, root: "https://unit.example/proxy/v1")
                .stream(model: "m", messages: [.init(role: .user, content: "Q")], options: options) {}
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequest?.bodyData)) as! NSDictionary
            let expected = row["expected"] as! NSDictionary
            if type == .ollama {
                XCTAssertEqual(body["options"] as? NSDictionary, expected["options"] as? NSDictionary)
                XCTAssertNil(body["max_tokens"])
            } else {
                XCTAssertEqual(body["max_tokens"] as? Int, expected["max_tokens"] as? Int)
                XCTAssertNil(body["options"])
                XCTAssertNil(body["num_ctx"])
                XCTAssertNil(body["num_predict"])
            }
        }
        StubURLProtocol.reset()
    }
    func testWireOrderFixtures() async throws {
        let canonical = try SharedFixtures.json("contracts/wire-order-v1.json")["cases"] as! [[String: Any]]
        let systems = try SharedFixtures.json("contracts/provider-systems-v1.json")["cases"] as! [[String: Any]]
        for row in canonical + systems {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: (row["provider"] ?? row["type"]) as! String)!
            var turns: [ChatTurn] = []
            if let input = row["input"] as? [String: Any] {
                turns.append(.init(role: .system, content: input["rulesText"] as! String))
                let instructions = input["userInstructions"] as! String
                if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns.append(.init(role: .system, content: instructions))
                }
                for h in input["history"] as! [[String: String]] {
                    turns.append(.init(role: ChatRole(rawValue: h["role"]!)!, content: h["content"]!))
                }
                turns.append(.init(role: .user, content: input["finalUserContent"] as! String))
            } else {
                turns = (row["input"] as! [[String: String]]).map {
                    .init(role: ChatRole(rawValue: $0["role"]!)!, content: $0["content"]!)
                }
            }
            finish(type)
            for try await _ in adapter(type, root: "https://unit.example/root").stream(model: "m", messages: turns) {}
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequest?.bodyData)) as! [String: Any]
            let projected = body.filter { $0.key == "messages" || $0.key == "system" } as NSDictionary
            XCTAssertEqual(projected, row["expected"] as? NSDictionary, row["name"] as! String)
        }
        StubURLProtocol.reset()
    }

    func testLengthErrors() async throws {
        let rows = try SharedFixtures.json("contracts/provider-errors-v1.json")["cases"] as! [[String: Any]]
        for row in rows {
            let type = ProviderType(rawValue: row["type"] as! String)!
            try await assertChatError(type, status: row["statusCode"] as! Int,
                body: JSONSerialization.data(withJSONObject: row["body"]!),
                contextTooLong: row["expectedError"] as? String == "contextTooLong",
                name: row["name"] as! String)
        }
        for type in ProviderType.allCases {
            try await assertChatError(type, status: 400, body: Data("not JSON".utf8), contextTooLong: false)
            try await assertChatError(type, status: 400,
                body: Data(#"{"error":{"code":"prompt_too_long"}}"#.utf8), contextTooLong: true)
            // Only Anthropic's own error shape uses this message-prefix rule.
            try await assertChatError(type, status: 400,
                body: Data(#"{"error":{"type":"invalid_request_error","message":"prompt is too long: 9000 tokens"}}"#.utf8),
                contextTooLong: type == .anthropic)
        }
    }

    private func assertChatError(_ type: ProviderType, status: Int, body: Data,
                                 contextTooLong: Bool, name: String = "",
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json(body, status: status))
        var tokens: [String] = []
        do {
            for try await token in adapter(type, root: "https://unit.example/root")
                .stream(model: "m", messages: [.init(role: .user, content: "Q")]) {
                tokens.append(token)
            }
            XCTFail("Expected a chat error: \(name)", file: file, line: line)
        } catch ProviderRequestError.contextTooLong {
            XCTAssertTrue(contextTooLong, name, file: file, line: line)
        } catch let error as ProviderError {
            guard case .http(let code, let detail) = error else {
                return XCTFail("Unexpected provider error: \(name)", file: file, line: line)
            }
            XCTAssertFalse(contextTooLong, name, file: file, line: line)
            XCTAssertEqual(code, status, name, file: file, line: line)
            XCTAssertLessThanOrEqual(detail.utf8.count, 65_536, file: file, line: line)
        } catch let error as OllamaError {
            guard case .httpStatus(let code, let detail) = error else {
                return XCTFail("Unexpected Ollama error: \(name)", file: file, line: line)
            }
            XCTAssertFalse(contextTooLong, name, file: file, line: line)
            XCTAssertEqual(code, status, name, file: file, line: line)
            XCTAssertLessThanOrEqual(detail.utf8.count, 65_536, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertEqual(tokens, [], name, file: file, line: line)
        XCTAssertEqual(StubURLProtocol.allRequests.count, 1, name, file: file, line: line)
    }

    func testLengthErrorBodyIsBounded() async throws {
        let suffix = Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)
        for type in ProviderType.allCases {
            // A code outside the bounded prefix must not be inspected.
            try await assertChatError(type, status: 400,
                body: Data(repeating: 0x20, count: 65_536) + suffix, contextTooLong: false)
            try await assertChatError(type, status: 413,
                body: Data(repeating: 0x61, count: 70_000), contextTooLong: true)
        }
    }

    func testInvalidOptionsNeverDispatch() async throws {
        let rows = try SharedFixtures.json("contracts/provider-limits-v1.json")["cases"] as! [[String: Any]]
        for row in rows {
            guard let user = row["user"] as? [String: Int], row["window"] is NSNull else { continue }
            let options = ChatRequestOptions(runtimeContext: user["runtimeContext"]!,
                                             maxOutputTokens: user["maxOutputTokens"]!)
            for type in ProviderType.allCases {
                StubURLProtocol.reset()
                do {
                    _ = try await collect(adapter(type, root: "https://unit.example/root")
                        .stream(model: "m", messages: [], options: options))
                    XCTFail("Expected invalid limits")
                } catch {
                    XCTAssertEqual(error as? ProviderConfigurationError, .invalidLimits)
                }
                XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
            }
        }
    }

    func testDefaultOptionsReachAllAdapters() async throws {
        let values = try SharedFixtures.json("contracts/constants-v1.json")["providers"] as! [String: Int]
        XCTAssertEqual(ChatRequestOptions.defaults.runtimeContext, values["defaultRuntimeContext"])
        XCTAssertEqual(ChatRequestOptions.defaults.maxOutputTokens, values["defaultMaxOutputTokens"])
        for type in ProviderType.allCases {
            StubURLProtocol.reset()
            finish(type)
            _ = try await collect(adapter(type, root: "https://unit.example/root").stream(model: "m", messages: []))
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequest?.bodyData)) as! [String: Any]
            if type == .ollama {
                XCTAssertEqual(body["options"] as? [String: Int],
                    ["num_ctx": values["defaultRuntimeContext"]!, "num_predict": values["defaultMaxOutputTokens"]!])
            } else {
                XCTAssertEqual(body["max_tokens"] as? Int, values["defaultMaxOutputTokens"])
            }
        }
    }

    func testInvalidRootFixturesNeverDispatch() async throws {
        let rows = try SharedFixtures.json("contracts/api-root-v1.json")["cases"] as! [[String: Any]]
        for row in rows where row["expectedError"] != nil {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: row["type"] as! String)!
            let root = row["baseURL"] as! String
            do {
                if row["endpoint"] as? String == "embeddings" {
                    _ = try ProviderAPIRoot.build(type: type, baseURL: root, endpoint: .embeddings)
                } else {
                    _ = try await collect(adapter(type, root: root).stream(model: "m", messages: []))
                }
                XCTFail("Expected invalid configuration: \(row["name"]!)")
            } catch {
                XCTAssertEqual((error as? ProviderConfigurationError)?.rawValue, row["expectedError"] as? String)
            }
            XCTAssertTrue(StubURLProtocol.allRequests.isEmpty, row["name"] as! String)
        }
    }

    func testOllamaShowAndManagementUseProxyRoot() async throws {
        let row = (try SharedFixtures.json("contracts/provider-routing-v1.json")["cases"] as! [[String: Any]])
            .first { $0["name"] as? String == "custom-ollama" }!
        let root = row["root"] as! String
        let client = OllamaClient(baseURL: URL(string: root + "///")!, session: StubURLProtocol.session())
        let data = Data(#"{"model_info":{"general.architecture":"llama","llama.context_length":32768}}"#.utf8)
        StubURLProtocol.enqueue(.json(data))
        let shown = try await client.show(model: "vendor/m:tag")
        XCTAssertEqual(shown, data)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, root + "/api/show")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequest?.bodyData)) as? [String: String],
                       ["model": "vendor/m:tag"])
        StubURLProtocol.enqueue(.json(Data(#"{"models":[]}"#.utf8)))
        let detected = await client.detect()
        XCTAssertTrue(detected)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, root + "/api/tags")
        StubURLProtocol.enqueue(.json(Data()))
        try await client.deleteModel(name: "m:tag")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, root + "/api/delete")
        StubURLProtocol.enqueue(.json(Data("{\"status\":\"success\"}\n".utf8)))
        for try await _ in client.pullModel(name: "m:tag") {}
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, root + "/api/pull")
        XCTAssertEqual(StubURLProtocol.allRequests.count, 4)
    }

    func testFixtureURLsAtHTTPBoundary() async throws {
        let rows = try SharedFixtures.json("contracts/api-root-v1.json")["cases"] as! [[String: Any]]
        for c in rows where c["expectedURL"] != nil {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: c["type"] as! String)!
            let raw = c["baseURL"] as! String
            let root = c["legacy"] as! Bool ? try ProviderAPIRoot.convertLegacy(type: type, baseURL: raw) : raw
            let session = StubURLProtocol.session()
            switch ProviderEndpoint(rawValue: c["endpoint"] as! String)! {
            case .chat:
                finish(type)
                for try await _ in adapter(type, root: root).stream(model: "m", messages: [.init(role: .user, content: "Q")]) {}
            case .models:
                StubURLProtocol.enqueue(.json(Data((type == .ollama ? "{\"models\":[]}" : "{\"data\":[]}").utf8)))
                switch type {
                case .ollama:
                    _ = try await OllamaClient(baseURL: URL(string: root)!, session: session).listModels()
                case .anthropic:
                    _ = try await AnthropicChatAdapter.listModels(baseURL: root, apiKey: "k", session: session)
                case .openai, .openaiCompatible:
                    _ = try await OpenAIChatAdapter.listModels(baseURL: root, apiKey: "k", session: session)
                case .openwebui:
                    _ = try await OpenWebUIChatAdapter.listModels(baseURL: root, apiKey: "k", session: session)
                }
            case .embeddings:
                if type == .ollama {
                    StubURLProtocol.enqueue(.json(Data("{\"embeddings\":[[1,0]]}".utf8)))
                    _ = try await OllamaClient(baseURL: URL(string: root)!, session: session).embed(model: "m", input: ["x"])
                } else {
                    StubURLProtocol.enqueue(.json(Data("{\"data\":[{\"embedding\":[1,0]}]}".utf8)))
                    _ = try await OpenAIEmbeddingAdapter(baseURL: root, apiKey: "k", session: session).embed(model: "m", inputs: ["x"])
                }
            }
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, c["expectedURL"] as? String, c["name"] as! String)
        }
        StubURLProtocol.reset()
    }

    func testEscapedProxyPathsSurviveDispatch() async throws {
        let root = "https://unit.example/proxy%2Ftenant/v1///"
        let paths: [ProviderType: String] = [
            .openai: "chat/completions", .openaiCompatible: "chat/completions",
            .anthropic: "v1/messages", .openwebui: "api/chat/completions", .ollama: "api/chat"
        ]
        for type in ProviderType.allCases {
            StubURLProtocol.reset()
            finish(type)
            _ = try await collect(adapter(type, root: root).stream(model: "m", messages: []))
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString,
                           "https://unit.example/proxy%2Ftenant/v1/" + paths[type]!)
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
        }
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json(Data("{}".utf8)))
        _ = try await OllamaClient(baseURL: URL(string: root)!, session: StubURLProtocol.session()).show(model: "m:tag")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString,
                       "https://unit.example/proxy%2Ftenant/v1/api/show")
    }

    func testOriginalControlsAndInvalidRootsPrecedeUnsupportedEndpoint() throws {
        for root in ["\u{0085}https://unit.example", "https://unit.example\u{009F}", "https://unit.example\\proxy"] {
            for type in ProviderType.allCases {
                XCTAssertThrowsError(try ProviderAPIRoot.build(type: type, baseURL: root, endpoint: .embeddings)) {
                    XCTAssertEqual($0 as? ProviderConfigurationError, .invalidBaseURL)
                }
            }
        }
        XCTAssertEqual(try ProviderAPIRoot.normalize("\u{00A0}https://unit.example/proxy%2Ftenant///\u{2003}"),
                       "https://unit.example/proxy%2Ftenant")
    }

    func testInvalidRootsNeverReachAnyTransportEndpoint() async throws {
        let root = "https://unit.example/proxy?invalid=1"
        let client = OllamaClient(baseURL: URL(string: root)!, session: StubURLProtocol.session())
        let detected = await client.detect()
        XCTAssertFalse(detected)
        let operations: [() async throws -> Void] = [
            { _ = try await client.listModels() },
            { _ = try await client.embed(model: "m", input: ["x"]) },
            { _ = try await client.show(model: "m") },
            { try await client.deleteModel(name: "m") },
            { for try await _ in client.pullModel(name: "m") {} },
            { for try await _ in client.chat(model: "m", messages: []) {} },
            { _ = try await OpenAIChatAdapter.listModels(baseURL: root, apiKey: nil, session: StubURLProtocol.session()) },
            { _ = try await AnthropicChatAdapter.listModels(baseURL: root, apiKey: "k", session: StubURLProtocol.session()) },
            { _ = try await OpenWebUIChatAdapter.listModels(baseURL: root, apiKey: nil, session: StubURLProtocol.session()) },
            { _ = try await OpenAIEmbeddingAdapter(baseURL: root, apiKey: nil, session: StubURLProtocol.session())
                .embed(model: "m", inputs: ["x"]) }
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("Expected invalidBaseURL")
            } catch {
                XCTAssertEqual(error as? ProviderConfigurationError, .invalidBaseURL)
            }
            XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
        }
        for type in ProviderType.allCases {
            do {
                _ = try await collect(adapter(type, root: root).stream(model: "m", messages: []))
                XCTFail("Expected invalidBaseURL")
            } catch {
                XCTAssertEqual(error as? ProviderConfigurationError, .invalidBaseURL)
            }
            XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
        }
    }
}
