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
        // Acknowledged deliberately: this test exercises routing/model/auth
        // wiring, not consent. Under FR-A8 enforcement, an unacknowledged
        // cloud provider throws `.consentRequired` before any request is
        // made — see testStreamThrowsConsentRequiredForUnacknowledgedCloudProvider.
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000", privacyAcknowledged: true)
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
        // Acknowledged deliberately (see note in the chat-routing test above).
        let cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com", privacyAcknowledged: true)
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
        // Acknowledged deliberately: the config itself is still a cloud type
        // (openwebui.isCloud == true), so the FR-A8 gate is checked on it
        // before the type-switch fallback runs — this test is about the
        // fallback-routing behavior, not consent, so we grant consent on
        // the fixture to isolate what's under test.
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000", privacyAcknowledged: true)
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
        // Acknowledged deliberately (see note in the chat-routing test above):
        // the composite key still resolves this real saved provider row, so
        // it would trip the FR-A8 gate otherwise.
        let cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com", privacyAcknowledged: true)
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

    // MARK: - FR-A8 consent gate (defense-in-depth)

    /// A cloud provider the user never acknowledged must not receive any
    /// data via chat — the router throws before the adapter makes a request.
    func testStreamThrowsConsentRequiredForUnacknowledgedCloudProvider() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com")
        XCTAssertFalse(cfg.privacyAcknowledged, "fixture must start unacknowledged")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (cfg.id, "gpt-4o"), embed: (ProviderConfig.ollamaId, "x"))
        let router = makeRouter(store: store, selection: selection)
        nonisolated(unsafe) var handlerInvoked = false
        MockURLProtocol.handler = { req in
            handlerInvoked = true
            return (httpResponse(req.url!, status: 200), Data())
        }
        do {
            _ = try await collect(router.stream(model: "ignored", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected consentRequired")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .consentRequired)
        }
        XCTAssertFalse(handlerInvoked, "no HTTP request must be made without consent")
    }

    /// Same gate for embeddings — an unacknowledged cloud provider must not
    /// receive text to embed either.
    func testEmbedThrowsConsentRequiredForUnacknowledgedCloudProvider() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com")
        XCTAssertFalse(cfg.privacyAcknowledged, "fixture must start unacknowledged")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (cfg.id, "text-embedding-3-small"))
        let router = makeRouter(store: store, selection: selection)
        nonisolated(unsafe) var handlerInvoked = false
        MockURLProtocol.handler = { req in
            handlerInvoked = true
            return (httpResponse(req.url!, status: 200), Data())
        }
        do {
            _ = try await router.embed(model: "ignored", inputs: ["a"])
            XCTFail("expected consentRequired")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .consentRequired)
        }
        XCTAssertFalse(handlerInvoked, "no HTTP request must be made without consent")
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

    /// FR-C3: passing an explicit provider-qualified model key must route to
    /// THAT provider, overriding the live chat selection. Proven via the
    /// consent gate, which fires before any network request: the selection
    /// points at consented Ollama, but a composite key aimed at an
    /// unacknowledged cloud provider must throw `.consentRequired`.
    func testStreamHonorsCompositeModelKeyOverSelection() async throws {
        let store = try NotebookStore(path: .inMemory) // seeds consented Ollama
        let cloud = ProviderConfig(type: .anthropic, name: "Claude",
                                   baseURL: "https://api.anthropic.com", privacyAcknowledged: false)
        try store.saveProvider(cloud)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "llama3.2:3b"),
                                        embed: (ProviderConfig.ollamaId, "nomic-embed-text"))
        let router = makeRouter(store: store, selection: selection)
        do {
            for try await _ in router.stream(model: "\(cloud.id):claude-sonnet-4-6",
                                             messages: [ChatTurn(role: .user, content: "hi")]) {}
            XCTFail("expected consentRequired — key must route to the cloud provider")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .consentRequired)
        }
    }

    /// A raw chat model containing a colon (e.g. `llama3.2:3b`) must NOT be
    /// mistaken for a composite key — its prefix isn't a real provider id, so
    /// resolution falls back to the live selection.
    func testStreamRawColonModelFallsBackToSelection() async throws {
        let store = try NotebookStore(path: .inMemory)
        // Selection points at an unacknowledged cloud provider so the gate
        // fires from the SELECTION path (proving the raw model didn't route).
        let cloud = ProviderConfig(type: .anthropic, name: "Claude",
                                   baseURL: "https://api.anthropic.com", privacyAcknowledged: false)
        try store.saveProvider(cloud)
        let selection = StaticSelection(chat: (cloud.id, "claude"),
                                        embed: (ProviderConfig.ollamaId, "nomic-embed-text"))
        let router = makeRouter(store: store, selection: selection)
        do {
            for try await _ in router.stream(model: "llama3.2:3b",
                                             messages: [ChatTurn(role: .user, content: "hi")]) {}
            XCTFail("expected consentRequired from the selection path")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .consentRequired)
        }
    }
}
