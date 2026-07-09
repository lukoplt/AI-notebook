import XCTest
@testable import AINotebookCore

@MainActor
final class ProviderRouterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Fixed selection for tests.
    final class StaticSelection: ProviderSelectionReading, @unchecked Sendable {
        var chat: (String, String)
        var embed: (String, String)
        init(chat: (String, String), embed: (String, String)) {
            self.chat = chat
            self.embed = embed
        }
        func chatSelection() -> (providerId: String, model: String) { chat }
        func embeddingSelection() -> (providerId: String, model: String) { embed }
    }

    private func makeRouter(
        store: NotebookStore,
        selection: StaticSelection,
        secrets: InMemorySecretStore = InMemorySecretStore()
    ) -> ProviderRouter {
        ProviderRouter(store: store, secrets: secrets, selection: selection, session: makeMockSession())
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    func testChatRoutesToOpenWebUIWithLiveModelAndStoredKey() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: cfg.id, secret: "sk-owui")
        let selection = StaticSelection(chat: (cfg.id, "llama3.2"), embed: (ProviderConfig.ollamaId, "nomic-embed-text"))
        let router = makeRouter(store: store, selection: selection, secrets: secrets)

        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("data: {\"choices\":[{\"delta\":{\"content\":\"tok\"},\"index\":0}]}\ndata: [DONE]\n".utf8))
        }
        // Engines pass their launch-time model — the router must ignore it.
        let tokens = try await collect(router.stream(model: "stale-model-ignored", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["tok"])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "http://h:3000/api/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-owui")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"llama3.2""#), "live model must win: \(body)")
    }

    func testChatFallsBackToOllamaWhenConfigMissing() async throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: ("no-such-id", "llama3.2:3b"), embed: (ProviderConfig.ollamaId, "x"))
        let router = makeRouter(store: store, selection: selection)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"done\":true}\n".utf8))
        }
        _ = try await collect(router.stream(model: "ignored", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(captured?.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
    }

    func testEmbedRoutesToOpenAIEmbeddings() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com")
        try store.saveProvider(cfg)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: cfg.id, secret: "sk-oai")
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (cfg.id, "text-embedding-3-small"))
        let router = makeRouter(store: store, selection: selection, secrets: secrets)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data(#"{"data":[{"embedding":[1.0,0.0]}]}"#.utf8))
        }
        let vectors = try await router.embed(model: "ignored", inputs: ["a"])
        XCTAssertEqual(vectors, [[1.0, 0.0]])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/embeddings")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"text-embedding-3-small""#), body)
    }

    func testEmbedForChatOnlyTypeFallsBackToOllama() async throws {
        // UI never offers openwebui for embeddings; if selected anyway the
        // router falls back to Ollama (Windows parity).
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (cfg.id, "nomic-embed-text"))
        let router = makeRouter(store: store, selection: selection)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data(#"{"embeddings":[[1.0,0.0]]}"#.utf8))
        }
        _ = try await router.embed(model: "ignored", inputs: ["a"])
        // Falls back to the openwebui config's host? No — to Ollama's default.
        XCTAssertEqual(captured?.url?.absoluteString, "http://127.0.0.1:11434/api/embed")
    }

    func testListModelsOpenWebUI() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), Data(#"{"data":[{"id":"llama3.2","name":"Llama 3.2"}]}"#.utf8))
        }
        let models = await router.listModels(providerId: cfg.id)
        XCTAssertEqual(models.map(\.id), ["llama3.2"])
    }

    func testListModelsFailureIsEmptyForUI() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let models = await router.listModels(providerId: cfg.id)
        XCTAssertEqual(models, [])
    }

    func testListModelsAnthropicFailureGivesFallbackList() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .anthropic, name: "Claude", baseURL: "https://api.anthropic.com")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let models = await router.listModels(providerId: cfg.id)
        XCTAssertEqual(models, AnthropicChatAdapter.defaultModels)
    }

    func testTestConnectionSuccessReturnsNil() async throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), Data(#"{"data":[{"id":"m"}]}"#.utf8))
        }
        let error = await router.testConnection(type: .openwebui, baseURL: "http://h:3000", apiKey: "k")
        XCTAssertNil(error)
    }

    func testTestConnectionReports401() async throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let error = await router.testConnection(type: .openwebui, baseURL: "http://h:3000", apiKey: "bad")
        guard case .auth = error as? ProviderError else {
            return XCTFail("expected ProviderError.auth, got \(String(describing: error))")
        }
    }

    func testTestConnectionReportsNetworkFailure() async throws {
        // Phase 1 lesson: a typo'd LAN URL must NOT report success.
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let error = await router.testConnection(type: .openwebui, baseURL: "http://192.168.1.99:9999", apiKey: nil)
        XCTAssertNotNil(error)
    }

    /// A mid-drain settings change must not let the network call diverge
    /// from the composite key the caller (Embedder) snapshotted for storage:
    /// the passed `model` composite key must win over the live selection.
    func testEmbedHonorsCompositeKeyOverLiveSelection() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com")
        try store.saveProvider(cfg)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: cfg.id, secret: "sk-oai")
        // Live selection points at Ollama — the composite key must win anyway.
        let selection = StaticSelection(
            chat: (ProviderConfig.ollamaId, "x"),
            embed: (ProviderConfig.ollamaId, "nomic-embed-text")
        )
        let router = makeRouter(store: store, selection: selection, secrets: secrets)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data(#"{"data":[{"embedding":[1.0,0.0]}]}"#.utf8))
        }
        let vectors = try await router.embed(model: "\(cfg.id):text-embedding-3-small", inputs: ["a"])
        XCTAssertEqual(vectors, [[1.0, 0.0]])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/embeddings", "must hit provider A, not the live Ollama selection")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"text-embedding-3-small""#), body)
    }

    /// Ollama tags routinely contain colons (`llama3.2:3b`); splitting the
    /// composite key on the FIRST colon only must preserve them in full.
    func testEmbedCompositeKeyPreservesColonsInModelName() async throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(
            chat: (ProviderConfig.ollamaId, "x"),
            embed: (ProviderConfig.ollamaId, "should-be-ignored")
        )
        let router = makeRouter(store: store, selection: selection)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data(#"{"embeddings":[[1.0,0.0]]}"#.utf8))
        }
        let vectors = try await router.embed(model: "\(ProviderConfig.ollamaId):llama3.2:3b", inputs: ["a"])
        XCTAssertEqual(vectors, [[1.0, 0.0]])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:11434/api/embed")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"llama3.2:3b""#), "colons after the first must survive: \(body)")
    }

    func testEmbeddingKeyComposition() {
        let selection = StaticSelection(chat: ("c", "m"), embed: ("prov-1", "nomic-embed-text"))
        XCTAssertEqual(selection.embeddingKey(), "prov-1:nomic-embed-text")
    }

    func testDefaultsSelectionReadsSharedKeys() {
        let suiteName = "router.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let selection = DefaultsProviderSelection(defaults: defaults)
        XCTAssertEqual(selection.chatSelection().providerId, ProviderConfig.ollamaId)
        XCTAssertEqual(selection.chatSelection().model, "llama3.2:3b")
        defaults.set("p-9", forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set("gpt-4o", forKey: ProviderSettingsKeys.chatModel)
        XCTAssertEqual(selection.chatSelection().providerId, "p-9")
        XCTAssertEqual(selection.chatSelection().model, "gpt-4o")
    }
}
