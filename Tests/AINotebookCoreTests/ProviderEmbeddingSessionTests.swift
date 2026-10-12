import Foundation
import XCTest
@testable import AINotebookCore

@MainActor final class ProviderEmbeddingSessionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testEndpointIdentityFixture() throws {
        let f = try SharedFixtures.json("contracts/retrieval-session-v1.json")
        var checked = 0
        for c in f["cases"] as! [[String:Any]] where c["expectedEndpointRevision"] != nil {
            let type = try XCTUnwrap(ProviderType(rawValue: c["type"] as! String))
            XCTAssertEqual(EmbeddingEndpointRevision.make(type: type, normalizedRoot: c["normalizedRoot"] as! String),
                           c["expectedEndpointRevision"] as? String, c["name"] as! String)
            if let newRevision = c["expectedNewEndpointRevision"] as? String {
                XCTAssertEqual(EmbeddingEndpointRevision.make(type: type, normalizedRoot: c["newRoot"] as! String), newRevision)
            }
            checked += 1
        }
        XCTAssertEqual(checked, 3)
        let moved = try fixtureCase("root-change")
        let type = try XCTUnwrap(ProviderType(rawValue: moved["type"] as! String))
        XCTAssertEqual(EmbeddingEndpointRevision.make(type: type, normalizedRoot: moved["oldRoot"] as! String),
                       moved["generationEndpointRevision"] as? String)
        XCTAssertEqual(EmbeddingEndpointRevision.make(type: type, normalizedRoot: moved["newRoot"] as! String),
                       moved["newEndpointRevision"] as? String)
    }

    func testCapturedRootKeyAndModelSurviveSettingsMutation() async throws {
        let c = try fixtureCase("key-rotation")
        let moved = try fixtureCase("root-change")
        let store = try NotebookStore(path: .inMemory)
        let id = c["providerId"] as! String, root = c["oldRoot"] as! String, model = c["rawModel"] as! String
        var config = ProviderConfig(id: id, type: .openaiCompatible, name: "P", baseURL: root, privacyAcknowledged: true)
        try store.saveProvider(config)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: id, secret: c["oldKey"] as! String)
        let selection = MutableSelection((id, model))
        let router = ProviderRouter(store: store, secrets: secrets, selection: selection, session: makeMockSession())
        let identity = GenerationIdentity(providerId: id,
            endpointRevision: EmbeddingEndpointRevision.make(type: config.type, normalizedRoot: root),
            model: model, modelDigest: nil, dims: 2, normalization: "l2", queryFormatVersion: "1",
            docFormatVersion: "1", chunkerVersion: "2")
        let session = try await router.prepareEmbedding(identity: identity)
        XCTAssertEqual(session.storageKey, id + ":" + model)
        XCTAssertEqual(session.endpointRevision, c["expectedEndpointRevision"] as? String)
        XCTAssertFalse(session.legacyEndpointUnverified)

        config.baseURL = moved["newRoot"] as! String
        try store.saveProvider(config)
        try secrets.save(providerId: id, secret: c["newKey"] as! String)
        selection.value = (id, c["newModel"] as! String)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = recorder.handler(#"{"data":[{"embedding":[1,0]}]}"#)
        let vectors = try await session.embed(inputs: c["inputs"] as! [String])
        XCTAssertEqual(vectors, [[1, 0]])
        let expected = c["expectedRequest"] as! [String: Any]
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, c["requests"] as? Int)
        XCTAssertEqual(request.url?.absoluteString, expected["url"] as? String)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected["authorization"] as? String)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, expected["model"] as? String)
        XCTAssertEqual(body["input"] as? [String], expected["inputs"] as? [String])

        // A freshly prepared session sees the rotated key but rejects the moved root.
        do {
            _ = try await router.prepareEmbedding(identity: identity)
            XCTFail("Moved endpoint prepared a session")
        } catch { XCTAssertEqual(error as? RetrievalError, .endpointRevisionMismatch) }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testMismatchedEndpointAndChatOnlySendNothing() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = recorder.handler(#"{"data":[{"embedding":[1,0]}]}"#)
        for name in ["root-change", "chat-only-anthropic", "chat-only-openwebui", "legacy-unresolved",
                     "legacy-unresolved-type"] {
            let c = try fixtureCase(name)
            let type = try XCTUnwrap(ProviderType(rawValue: c["type"] as! String))
            let store = try NotebookStore(path: .inMemory)
            let id = "provider-a"
            try store.saveProvider(ProviderConfig(id: id, type: type, name: "P",
                baseURL: c["newRoot"] as? String ?? c["root"] as! String, privacyAcknowledged: true))
            let secrets = InMemorySecretStore()
            try secrets.save(providerId: id, secret: "key")
            let router = ProviderRouter(store: store, secrets: secrets,
                selection: MutableSelection((id, "selected")), session: makeMockSession())
            let identity: GenerationIdentity
            if c["queryFormatVersion"] as? String == "legacy" {
                identity = legacyIdentity(storedKey: c["storedKey"] as! String)
            } else {
                identity = GenerationIdentity(providerId: id,
                    endpointRevision: c["generationEndpointRevision"] as? String
                        ?? EmbeddingEndpointRevision.make(type: type, normalizedRoot: c["normalizedRoot"] as! String),
                    model: c["model"] as! String, modelDigest: nil, dims: 2, normalization: "l2",
                    queryFormatVersion: c["queryFormatVersion"] as! String, docFormatVersion: "1", chunkerVersion: "2")
            }
            do {
                _ = try await router.prepareEmbedding(identity: identity)
                XCTFail("\(name) prepared a session")
            } catch {
                XCTAssertEqual(errorCode(error), c["expectedError"] as? String, name)
            }
            XCTAssertEqual(recorder.requests.count, c["requests"] as? Int, name)
        }
    }

    func testFormatsAndModelTags() async throws {
        for name in ["root", "proxy", "legacy", "legacy-bare", "legacy-bare-tag", "legacy-bare-size-tag",
                     "legacy-unknown-prefix", "legacy-empty-prefix", "unknown-format"] {
            let c = try fixtureCase(name)
            let type = try XCTUnwrap(ProviderType(rawValue: c["type"] as! String))
            let store = try NotebookStore(path: .inMemory)
            let id = c["providerId"] as? String ?? "provider-a"
            try store.saveProvider(ProviderConfig(id: id, type: type, name: "P", baseURL: c["root"] as! String,
                                                  privacyAcknowledged: true))
            let secrets = InMemorySecretStore()
            try secrets.save(providerId: id, secret: "key")
            let selection = MutableSelection((c["selectedProviderId"] as? String ?? id, c["selectedModel"] as? String ?? "selected"))
            let router = ProviderRouter(store: store, secrets: secrets, selection: selection, session: makeMockSession())
            let identity: GenerationIdentity
            if c["queryFormatVersion"] as? String == "legacy" {
                identity = legacyIdentity(storedKey: c["storedKey"] as! String)
            } else {
                identity = GenerationIdentity(providerId: id,
                    endpointRevision: EmbeddingEndpointRevision.make(type: type, normalizedRoot: c["normalizedRoot"] as! String),
                    model: c["model"] as! String, modelDigest: nil, dims: 2, normalization: "l2",
                    queryFormatVersion: c["queryFormatVersion"] as! String, docFormatVersion: "1", chunkerVersion: "2")
            }
            let recorder = RequestRecorder()
            MockURLProtocol.handler = recorder.handler(type == .ollama
                ? #"{"embeddings":[[1,0]]}"# : #"{"data":[{"embedding":[1,0]}]}"#)
            if let expectedError = c["expectedError"] as? String {
                do {
                    _ = try await router.prepareEmbedding(identity: identity)
                    XCTFail("\(name) prepared a session")
                } catch { XCTAssertEqual(errorCode(error), expectedError, name) }
                XCTAssertEqual(recorder.requests.count, 0, name)
                continue
            }
            let session = try await router.prepareEmbedding(identity: identity)
            let isLegacy = c["expectedStatus"] as? String == "legacyEndpointUnverified"
            XCTAssertEqual(session.legacyEndpointUnverified, isLegacy, name)
            XCTAssertEqual(session.storageKey, isLegacy ? c["storedKey"] as? String : id + ":" + (c["model"] as! String), name)
            XCTAssertEqual(session.endpointRevision,
                EmbeddingEndpointRevision.make(type: type, normalizedRoot: c["normalizedRoot"] as! String), name)
            _ = try await session.embed(inputs: c["inputs"] as! [String])
            XCTAssertEqual(recorder.requests.count, c["requests"] as? Int, name)
            let request = try XCTUnwrap(recorder.requests.first, name)
            XCTAssertTrue(request.url!.absoluteString.hasPrefix(c["normalizedRoot"] as! String + "/"), name)
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, c["rawModel"] as? String ?? c["model"] as? String, name)
            XCTAssertEqual(body["input"] as? [String], c["expectedInputs"] as? [String], name)
        }
    }

    func testPrivacyGateRunsBeforeSessionCreation() async throws {
        let c = try fixtureCase("proxy")
        let type = try XCTUnwrap(ProviderType(rawValue: c["type"] as! String))
        XCTAssertTrue(type.isCloud)
        let store = try NotebookStore(path: .inMemory)
        let id = "provider-a"
        try store.saveProvider(ProviderConfig(id: id, type: type, name: "P", baseURL: c["root"] as! String,
                                              privacyAcknowledged: false))
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: id, secret: "key")
        let router = ProviderRouter(store: store, secrets: secrets, selection: MutableSelection((id, "m")),
                                    session: makeMockSession())
        let recorder = RequestRecorder()
        MockURLProtocol.handler = recorder.handler(#"{"data":[{"embedding":[1,0]}]}"#)
        let identity = GenerationIdentity(providerId: id,
            endpointRevision: EmbeddingEndpointRevision.make(type: type, normalizedRoot: c["normalizedRoot"] as! String),
            model: "m", modelDigest: nil, dims: 2, normalization: "l2", queryFormatVersion: "1",
            docFormatVersion: "1", chunkerVersion: "2")
        do {
            _ = try await router.prepareEmbedding(identity: identity)
            XCTFail("Unacknowledged remote provider prepared a session")
        } catch { XCTAssertEqual(error as? ProviderError, .consentRequired) }
        do {
            _ = try await router.prepareEmbedding(identity: legacyIdentity(storedKey: id + ":m"))
            XCTFail("Unacknowledged legacy provider prepared a session")
        } catch { XCTAssertEqual(error as? ProviderError, .consentRequired) }
        XCTAssertEqual(recorder.requests.count, 0)
    }

    // MARK: - Helpers

    private func fixtureCase(_ name: String) throws -> [String: Any] {
        let f = try SharedFixtures.json("contracts/retrieval-session-v1.json")
        return try XCTUnwrap((f["cases"] as! [[String: Any]]).first { $0["name"] as? String == name }, name)
    }

    private func legacyIdentity(storedKey: String) -> GenerationIdentity {
        GenerationIdentity(providerId: "legacy", endpointRevision: "legacy", model: storedKey, modelDigest: nil,
            dims: 2, normalization: "legacy", queryFormatVersion: "legacy", docFormatVersion: "legacy",
            chunkerVersion: "legacy")
    }

    private func errorCode(_ error: any Error) -> String {
        if let error = error as? RetrievalError { return error.rawValue }
        if let error = error as? ProviderConfigurationError { return error.rawValue }
        return String(describing: error)
    }
}

private final class MutableSelection: ProviderSelectionReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current: (String, String)
    init(_ value: (String, String)) { current = value }
    var value: (String, String) {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    func chatSelection() -> (providerId: String, model: String) { value }
    func embeddingSelection() -> (providerId: String, model: String) { value }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    func handler(_ body: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { [self] request in
            var copy = request
            copy.httpBody = request.bodyData
            lock.withLock { captured.append(copy) }
            return (httpResponse(request.url!, status: 200), Data(body.utf8))
        }
    }
}
