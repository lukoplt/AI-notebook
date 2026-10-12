import Foundation
import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineProviderSnapshotTests: XCTestCase {
    final class ChangingEmbedder: EmbeddingProducing, Sendable {
        let change: @MainActor @Sendable () throws -> Void
        init(change: @escaping @MainActor @Sendable () throws -> Void) { self.change = change }
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            try await change()
            return inputs.map { _ in [1, 0] }
        }
    }
    func testCaptureBeforeRetrievalAndReuseOnRetry() async throws {
        let c = (try SharedFixtures.json("contracts/provider-routing-v1.json")["cases"] as! [[String: Any]])
            .first { $0["operation"] as? String == "snapshot" }!
        let oldRoot = c["oldRoot"] as! String, newRoot = c["newRoot"] as! String
        let oldModel = c["oldModel"] as! String, newModel = c["newModel"] as! String
        let oldKey = c["oldKey"] as! String, newKey = c["newKey"] as! String
        let store = try NotebookStore(path: .inMemory)
        let notebook = try store.createNotebook(name: "N")
        let session = try store.createChatSession(notebookId: notebook.id!, title: "T")
        let source = try store.createSource(notebookId: notebook.id!, type: .text, title: "S", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: source.id!, chunks: [.init(text: "Q evidence", tokenCount: 2)])
        let chunk = try XCTUnwrap(store.chunks(sourceId: source.id!).first?.id)
        try store.storeEmbedding(chunkId: chunk, model: "embedding", vector: .init(values: [1, 0]))
        var retrievalCalls = 0
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("p", forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set(oldModel, forKey: ProviderSettingsKeys.chatModel)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: "p", secret: oldKey)
        try store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P", baseURL: oldRoot, privacyAcknowledged: true))
        try store.saveProviderModelLimits(.init(providerId: "p", model: oldModel, contextWindow: nil,
            runtimeContext: 4096, maxOutputTokens: 333, source: "user"))
        let router = ProviderRouter(store: store, secrets: secrets,
            selection: DefaultsProviderSelection(defaults: defaults), session: StubURLProtocol.session())
        let retriever = Retriever(store: store, client: ChangingEmbedder {
            retrievalCalls += 1
            if retrievalCalls == 1 { XCTAssertTrue(StubURLProtocol.allRequests.isEmpty) }
            try store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P", baseURL: newRoot, privacyAcknowledged: true))
            try secrets.save(providerId: "p", secret: newKey)
            defaults.set(newModel, forKey: ProviderSettingsKeys.chatModel)
            try store.saveProviderModelLimits(.init(providerId: "p", model: newModel, contextWindow: nil,
                runtimeContext: 8192, maxOutputTokens: 777, source: "user"))
        }, model: "embedding")
        let engine = ChatEngine(store: store, retriever: retriever, chat: router, chatModel: "stale-launch-model",
            retryAttempts: 1, retryBackoffMillis: 1)
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json(Data(), status: 429))
        StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
        StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
        let first = try await engine.send(sessionId: session.id!, notebookId: notebook.id!, userText: "Q", onToken: { _ in })
        let second = try await engine.send(sessionId: session.id!, notebookId: notebook.id!, userText: "Q2", onToken: { _ in })
        XCTAssertEqual(retrievalCalls, 2, "Both turns must actually embed during retrieval")
        XCTAssertEqual(first.model, "p:" + oldModel)
        XCTAssertEqual(second.model, "p:" + newModel)
        let requests = StubURLProtocol.allRequests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [oldRoot, oldRoot, newRoot].map { $0 + "/chat/completions" })
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization")! }, ["Bearer " + oldKey, "Bearer " + oldKey, "Bearer " + newKey])
        let bodies = try requests.map { try JSONSerialization.jsonObject(with: XCTUnwrap($0.bodyData)) as! [String: Any] }
        XCTAssertEqual(bodies.map { $0["max_tokens"] as! Int }, [333, 333, 777])
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testExplicitRawAndQualifiedOverridesSurviveLiveSelection() async throws {
        let row = try snapshotFixture()
        let fixture = try makeFixture(row)
        let oldModel = row["oldModel"] as! String
        let newModel = row["newModel"] as! String
        try fixture.store.saveProvider(.init(id: "q", type: .openaiCompatible, name: "Other",
            baseURL: row["newRoot"] as! String, privacyAcknowledged: true))
        try fixture.secrets.save(providerId: "q", secret: row["newKey"] as! String)
        try fixture.store.saveProviderModelLimits(.init(providerId: "q", model: newModel,
            contextWindow: nil, runtimeContext: row["newContext"] as! Int,
            maxOutputTokens: row["newOutput"] as! Int, source: "user"))
        let embedder = CountingEmbedder()
        let engine = engine(fixture, embedder: embedder)
        for _ in 0..<3 { StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8))) }
        let raw = try await engine.send(sessionId: fixture.sessionId, notebookId: fixture.notebookId,
            userText: "raw", model: newModel, onToken: { _ in })
        let qualified = try await engine.send(sessionId: fixture.sessionId, notebookId: fixture.notebookId,
            userText: "qualified", model: "q:" + newModel, onToken: { _ in })
        let selected = try await engine.send(sessionId: fixture.sessionId, notebookId: fixture.notebookId,
            userText: "selected", onToken: { _ in })
        XCTAssertEqual(raw.model, "p:" + newModel)
        XCTAssertEqual(qualified.model, "q:" + newModel)
        XCTAssertEqual(selected.model, "p:" + oldModel)
        let requests = StubURLProtocol.allRequests
        XCTAssertEqual(requests.map { $0.url!.absoluteString },
            [row["oldRoot"] as! String, row["newRoot"] as! String, row["oldRoot"] as! String].map { $0 + "/chat/completions" })
        XCTAssertEqual(try requests.map { try body($0)["model"] as! String }, [newModel, newModel, oldModel])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer " + (row["newKey"] as! String))
        XCTAssertEqual(try fixture.store.messages(sessionId: fixture.sessionId).filter { $0.role == .assistant }.map(\.model),
            [raw.model, qualified.model, selected.model])
    }

    func testRegenerateCapturesBeforeRetrievalAndReusesSnapshotOnRetry() async throws {
        let row = try snapshotFixture()
        let fixture = try makeFixture(row)
        let oldModel = row["oldModel"] as! String
        let newModel = row["newModel"] as! String
        try fixture.store.appendMessage(.init(sessionId: fixture.sessionId, role: .user, content: "original Q"))
        try fixture.store.appendMessage(.init(sessionId: fixture.sessionId, role: .assistant, content: "replace me", model: "old"))
        var retrievalCalls = 0
        let retriever = Retriever(store: fixture.store, client: ChangingEmbedder {
            retrievalCalls += 1
            if retrievalCalls == 1 { XCTAssertTrue(StubURLProtocol.allRequests.isEmpty) }
            try fixture.store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P",
                baseURL: row["newRoot"] as! String, privacyAcknowledged: true))
            try fixture.secrets.save(providerId: "p", secret: row["newKey"] as! String)
            fixture.defaults.set(newModel, forKey: ProviderSettingsKeys.chatModel)
        }, model: "embedding")
        let engine = ChatEngine(store: fixture.store, retriever: retriever, chat: fixture.router,
            chatModel: "stale-launch-model", retryAttempts: 1, retryBackoffMillis: 1)
        StubURLProtocol.enqueue(.json(Data(), status: 429))
        StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
        StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
        let first = try await engine.regenerate(sessionId: fixture.sessionId, notebookId: fixture.notebookId,
            model: "p:" + oldModel, onToken: { _ in })
        let second = try await engine.regenerate(sessionId: fixture.sessionId, notebookId: fixture.notebookId, onToken: { _ in })
        XCTAssertEqual(retrievalCalls, 2)
        XCTAssertEqual(first.model, "p:" + oldModel)
        XCTAssertEqual(second.model, "p:" + newModel)
        let requests = StubURLProtocol.allRequests
        XCTAssertEqual(requests.map { $0.url!.absoluteString },
            [row["oldRoot"] as! String, row["oldRoot"] as! String, row["newRoot"] as! String].map { $0 + "/chat/completions" })
        XCTAssertEqual(try requests.map { try body($0)["model"] as! String }, [oldModel, oldModel, newModel])
        XCTAssertEqual(try requests.map { try body($0)["max_tokens"] as! Int },
            [row["oldOutput"] as! Int, row["oldOutput"] as! Int, row["newOutput"] as! Int])
        let history = try fixture.store.messages(sessionId: fixture.sessionId)
        XCTAssertEqual(history.map(\.role), [.user, .assistant])
        XCTAssertEqual(history.first?.content, "original Q")
        XCTAssertEqual(history.last?.model, second.model)
        XCTAssertFalse(history.contains { $0.content == "replace me" })
    }

    func testFailedPreparationPreservesMessagesAndSkipsRetrievalAndChat() async throws {
        let routing = try fixtures("provider-routing").filter { $0["operation"] as? String == "chat" && $0["expectedError"] != nil }
        var failures: [(String, any Error & Sendable)] = routing.map { row in
            let code = row["expectedError"] as! String
            let error: any Error & Sendable = code == "consentRequired" ? ProviderError.consentRequired : ProviderConfigurationError(rawValue: code)!
            return (row["name"] as! String, error)
        }
        for row in try fixtures("provider-limits") where row["expectedError"] as? String == "invalidLimits" {
            failures.append((row["name"] as! String, ProviderConfigurationError.invalidLimits))
        }
        let invalidRoot = try XCTUnwrap(fixtures("api-root").first { $0["expectedError"] as? String == "invalidBaseURL" })
        failures.append((invalidRoot["name"] as! String, ProviderConfigurationError.invalidBaseURL))
        for (name, failure) in failures {
            for operation in ["send", "regenerate"] {
                let fixture = try makeFixture(snapshotFixture())
                try fixture.store.appendMessage(.init(sessionId: fixture.sessionId, role: .user, content: "existing Q"))
                try fixture.store.appendMessage(.init(sessionId: fixture.sessionId, role: .assistant, content: "keep this answer", model: "previous"))
                let before = try fixture.store.messages(sessionId: fixture.sessionId)
                let preparation = FailingPreparation(failure)
                let embedder = CountingEmbedder()
                let engine = ChatEngine(store: fixture.store,
                    retriever: Retriever(store: fixture.store, client: embedder, model: "embedding"),
                    chat: preparation, chatModel: "unused", retryAttempts: 3, retryBackoffMillis: 1)
                let tokens = Counter(), retries = Counter()
                do {
                    if operation == "send" {
                        _ = try await engine.send(sessionId: fixture.sessionId, notebookId: fixture.notebookId, userText: "must not persist",
                            onToken: { _ in tokens.increment() }, onRetry: { retries.increment() })
                    } else {
                        _ = try await engine.regenerate(sessionId: fixture.sessionId, notebookId: fixture.notebookId,
                            onToken: { _ in tokens.increment() }, onRetry: { retries.increment() })
                    }
                    XCTFail("Expected \(name), \(operation)")
                } catch {
                    XCTAssertEqual(String(describing: error), String(describing: failure), name)
                }
                XCTAssertEqual(preparation.preparations.value, 1)
                XCTAssertEqual(preparation.streams.value, 0)
                let retrievalCalls = await embedder.calls
                XCTAssertEqual(retrievalCalls, 0)
                XCTAssertEqual(tokens.value, 0)
                XCTAssertEqual(retries.value, 0)
                XCTAssertEqual(try fixture.store.messages(sessionId: fixture.sessionId), before, name + ": " + operation)
                XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
            }
        }
    }

    func testContextTooLongFixturesAreTerminalForEveryProvider() async throws {
        for row in try fixtures("provider-errors") where row["expectedError"] as? String == "contextTooLong" {
            StubURLProtocol.reset()
            let fixture = try makeFixture(snapshotFixture(), type: ProviderType(rawValue: row["type"] as! String)!)
            let engine = engine(fixture, embedder: CountingEmbedder(), attempts: 3)
            let retryCount = Counter()
            StubURLProtocol.enqueue(.json(try JSONSerialization.data(withJSONObject: row["body"]!), status: row["statusCode"] as! Int))
            do {
                _ = try await engine.send(sessionId: fixture.sessionId, notebookId: fixture.notebookId,
                    userText: "Q", onToken: { _ in }, onRetry: { retryCount.increment() })
                XCTFail("Expected terminal contextTooLong: \(row["name"]!)")
            } catch {
                guard case ProviderRequestError.contextTooLong = error else {
                    XCTFail("Expected contextTooLong, got \(error)"); continue
                }
            }
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1, row["name"] as! String)
            XCTAssertEqual(retryCount.value, 0)
            XCTAssertEqual(try fixture.store.messages(sessionId: fixture.sessionId).map(\.role), [.user])
        }
    }

    func testCallerCancellationDuringBothRetryBackoffsPreventsAnotherRequest() async throws {
        for code in [429, 500] {
            StubURLProtocol.reset()
            let fixture = try makeFixture(snapshotFixture())
            let engine = engine(fixture, embedder: CountingEmbedder(), attempts: 3, backoff: 60_000)
            let retryStarted = expectation(description: "retry backoff \(code)")
            StubURLProtocol.enqueue(.init(statusCode: code, headers: ["Retry-After": "60"], bodyChunks: [Data()]))
            StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
            let retries = Counter()
            let task = Task {
                try await engine.send(sessionId: fixture.sessionId, notebookId: fixture.notebookId, userText: "Q",
                    onToken: { _ in }, onRetry: { retries.increment(); retryStarted.fulfill() })
            }
            await fulfillment(of: [retryStarted], timeout: 5)
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1, "A cancelled \(code) retry must not start another request")
            XCTAssertEqual(retries.value, 1)
            XCTAssertEqual(try fixture.store.messages(sessionId: fixture.sessionId).map(\.role), [.user])
        }
    }

    func testCancelledStreamEndingNormallyDoesNotPersistAssistant() async throws {
        let fixture = try makeFixture(snapshotFixture())
        let started = expectation(description: "chat stream waiting")
        let chat = WaitingChat(started: started)
        let engine = ChatEngine(store: fixture.store,
            retriever: Retriever(store: fixture.store, client: CountingEmbedder(), model: "embedding"),
            chat: chat, chatModel: "fallback", retryAttempts: 3, retryBackoffMillis: 1)
        let task = Task {
            try await engine.send(sessionId: fixture.sessionId, notebookId: fixture.notebookId,
                userText: "Q", onToken: { _ in })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Normal stream termination must not turn cancellation into success") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(chat.calls.value, 1)
        XCTAssertEqual(try fixture.store.messages(sessionId: fixture.sessionId).map(\.role), [.user])
    }

    private struct Fixture {
        let store: NotebookStore
        let notebookId: Int64
        let sessionId: Int64
        let defaults: UserDefaults
        let secrets: InMemorySecretStore
        let router: ProviderRouter
    }

    private func makeFixture(_ row: [String: Any], type: ProviderType = .openaiCompatible) throws -> Fixture {
        let store = try NotebookStore(path: .inMemory)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "N").id)
        let sessionId = try XCTUnwrap(store.createChatSession(notebookId: notebookId, title: "T").id)
        let sourceId = try XCTUnwrap(store.createSource(notebookId: notebookId, type: .text, title: "S", uri: nil, rawPath: nil).id)
        try store.replaceChunks(sourceId: sourceId, chunks: [.init(text: "Q evidence", tokenCount: 2)])
        let chunkId = try XCTUnwrap(store.chunks(sourceId: sourceId).first?.id)
        try store.storeEmbedding(chunkId: chunkId, model: "embedding", vector: .init(values: [1, 0]))
        let name = "snapshot-test." + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        defaults.set("p", forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set(row["oldModel"] as! String, forKey: ProviderSettingsKeys.chatModel)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: "p", secret: row["oldKey"] as! String)
        try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: row["oldRoot"] as! String, privacyAcknowledged: true))
        for prefix in ["old", "new"] {
            try store.saveProviderModelLimits(.init(providerId: "p", model: row[prefix + "Model"] as! String,
                contextWindow: nil, runtimeContext: row[prefix + "Context"] as! Int,
                maxOutputTokens: row[prefix + "Output"] as! Int, source: "user"))
        }
        let router = ProviderRouter(store: store, secrets: secrets,
            selection: DefaultsProviderSelection(defaults: defaults), session: StubURLProtocol.session())
        return Fixture(store: store, notebookId: notebookId, sessionId: sessionId, defaults: defaults, secrets: secrets, router: router)
    }

    private func engine(_ fixture: Fixture, embedder: any EmbeddingProducing, attempts: Int = 1, backoff: Int = 1) -> ChatEngine {
        ChatEngine(store: fixture.store,
            retriever: Retriever(store: fixture.store, client: embedder, model: "embedding"),
            chat: fixture.router, chatModel: "stale-launch-model", retryAttempts: attempts, retryBackoffMillis: backoff)
    }
    private func fixtures(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/" + name + "-v1.json")["cases"] as? [[String: Any]])
    }
    private func snapshotFixture() throws -> [String: Any] {
        try XCTUnwrap(fixtures("provider-routing").first { $0["operation"] as? String == "snapshot" })
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any])
    }

    private actor CountingEmbedder: EmbeddingProducing {
        private(set) var calls = 0
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            calls += 1
            return inputs.map { _ in [1, 0] }
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
    private final class FailingPreparation: ChatSessionPreparing, ChatStreaming, Sendable {
        let failure: any Error & Sendable
        let preparations = Counter()
        let streams = Counter()
        init(_ failure: any Error & Sendable) { self.failure = failure }
        func prepareChat(model: String?) async throws -> ProviderChatSession {
            preparations.increment()
            throw failure
        }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            streams.increment()
            return AsyncThrowingStream { $0.finish() }
        }
    }
    private final class WaitingChat: ChatStreaming, @unchecked Sendable {
        let started: XCTestExpectation
        let calls = Counter()
        init(started: XCTestExpectation) { self.started = started }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            calls.increment()
            return AsyncThrowingStream { _ in started.fulfill() }
        }
    }
}
