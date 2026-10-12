import Foundation
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class ProviderSessionTests: XCTestCase {
    func testFixtureEndpointChangesFenceInFlightAutomaticMetadata() async throws {
        let rows = try fixtures("provider-store").filter { $0["operation"] as? String == "inflightEndpointChange" }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            StubURLProtocol.reset()
            SuspendedProviderURLProtocol.reset()
            let name = try XCTUnwrap(row["name"] as? String)
            let id = try XCTUnwrap(row["providerId"] as? String)
            let model = try XCTUnwrap(row["model"] as? String)
            let oldRoot = try XCTUnwrap(row["oldRoot"] as? String)
            let newRoot = try XCTUnwrap(row["newRoot"] as? String)
            let oldWindow = try XCTUnwrap(row["oldWindow"] as? Int)
            let newWindow = try XCTUnwrap(row["newWindow"] as? Int)
            let newCache = try XCTUnwrap(row["newCache"] as? String)
            func metadata(_ window: Int) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["model_info": [
                    "general.architecture": "llama", "llama.context_length": window]])
            }
            let store = try NotebookStore(path: .inMemory)
            var config = ProviderConfig(id: id, type: .ollama, name: "P", baseURL: oldRoot)
            try store.saveProvider(config)
            let defaults = preferences(providerId: id, model: model)
            let started = expectation(description: name)
            SuspendedProviderURLProtocol.configure(holding: "/api/show", started: started)
            let oldRouter = makeRouter(store, defaults: defaults, session: SuspendedProviderURLProtocol.session())
            let preparing = Task { try await oldRouter.prepareChat() }
            await fulfillment(of: [started], timeout: 5)
            config.baseURL = newRoot
            try store.saveProvider(config)
            let nextRouter = makeRouter(store, defaults: defaults)
            if newCache == "user" {
                try store.saveProviderModelLimits(.init(providerId: id, model: model, contextWindow: newWindow,
                    runtimeContext: newWindow, maxOutputTokens: 333, source: "user"))
            } else {
                StubURLProtocol.enqueue(.json(try metadata(newWindow)))
                if newCache == "auto" { _ = try await nextRouter.prepareChat() }
            }

            SuspendedProviderURLProtocol.release(data: try metadata(oldWindow))
            let captured = try await preparing.value
            XCTAssertEqual(captured.limits.contextWindow, row["expectedCapturedWindow"] as? Int, name)
            let saved = try store.providerModelLimits(providerId: id, model: model)
            if newCache == "empty" { XCTAssertNil(saved, name) }
            else {
                XCTAssertEqual(saved?.contextWindow, row["expectedCachedWindow"] as? Int, name)
                XCTAssertEqual(saved?.source, newCache, name)
            }
            try await drain(captured.stream(messages: question))
            XCTAssertEqual(SuspendedProviderURLProtocol.requests.map { $0.url!.absoluteString },
                [oldRoot + "/api/show", oldRoot + "/api/chat"], name)
            let next = try await nextRouter.prepareChat()
            XCTAssertEqual(next.limits.contextWindow, newWindow, name)
            XCTAssertEqual(next.limits.runtimeContext, row["expectedNewRuntime"] as? Int, name)
            XCTAssertEqual(try store.providerModelLimits(providerId: id, model: model), next.limits, name)
            XCTAssertEqual(StubURLProtocol.allRequests.map { $0.url!.absoluteString },
                newCache == "user" ? [] : [newRoot + "/api/show"], name)
        }
    }

    func testProbeFixture() async throws {
        let store = try NotebookStore(path: .inMemory)
        let defaults = preferenceSuite()
        let router = ProviderRouter(store: store, secrets: InMemorySecretStore(),
            selection: DefaultsProviderSelection(defaults: defaults), session: StubURLProtocol.session())
        for c in try SharedFixtures.json("contracts/provider-probe-v1.json")["cases"] as! [[String: Any]] {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: c["type"] as! String)!
            let response = c["response"] as! String
            if response == "transport" { StubURLProtocol.enqueue(.connectionRefused()) }
            else {
                let body: String
                switch response {
                case "validEmpty": body = type == .ollama ? "{\"models\":[]}" : "{\"data\":[]}"
                case "validOne": body = type == .ollama ? "{\"models\":[{\"name\":\"m:tag\",\"modified_at\":\"\",\"size\":0,\"digest\":\"d\",\"details\":{}}]}" : "{\"data\":[{\"id\":\"m:tag\"}]}"
                case "malformed": body = "{}"
                default: body = "{\"error\":\"denied\"}"
                }
                StubURLProtocol.enqueue(.json(Data(body.utf8), status: c["statusCode"] as! Int))
            }
            let result = try await router.probe(type: type, baseURL: "https://unit.example/root", apiKey: "k")
            XCTAssertEqual(result.status.rawValue, c["expectedStatus"] as? String, c["name"] as! String)
            XCTAssertEqual(result.errorCode, c["errorCode"] as? String)
            XCTAssertFalse(result.generationVerified)
            XCTAssertEqual(result.models.map(\.id), response == "validOne" ? ["m:tag"] : [])
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
            XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        }
        StubURLProtocol.reset()
    }
    func testCapturedAdapterKeepsRootKeyModelAndOptions() async throws {
        let c = (try SharedFixtures.json("contracts/provider-routing-v1.json")["cases"] as! [[String: Any]])
            .first { $0["operation"] as? String == "snapshot" }!
        let store = try NotebookStore(path: .inMemory)
        let secrets = InMemorySecretStore()
        let defaults = preferenceSuite()
        defaults.set("p", forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set(c["oldModel"] as! String, forKey: ProviderSettingsKeys.chatModel)
        var config = ProviderConfig(id: "p", type: .openaiCompatible, name: "P",
            baseURL: c["oldRoot"] as! String, privacyAcknowledged: true)
        try store.saveProvider(config)
        try secrets.save(providerId: "p", secret: c["oldKey"] as! String)
        try store.saveProviderModelLimits(.init(providerId: "p", model: c["oldModel"] as! String,
            contextWindow: nil, runtimeContext: 4096, maxOutputTokens: 333, source: "user"))
        let router = ProviderRouter(store: store, secrets: secrets,
            selection: DefaultsProviderSelection(defaults: defaults), session: StubURLProtocol.session())
        let captured = try await router.prepareChat()
        config.baseURL = c["newRoot"] as! String
        try store.saveProvider(config)
        try secrets.save(providerId: "p", secret: c["newKey"] as! String)
        defaults.set(c["newModel"] as! String, forKey: ProviderSettingsKeys.chatModel)
        try store.saveProviderModelLimits(.init(providerId: "p", model: c["newModel"] as! String,
            contextWindow: nil, runtimeContext: 8192, maxOutputTokens: 777, source: "user"))
        StubURLProtocol.reset()
        let next = try await router.prepareChat()
        for session in [captured, captured, next] {
            StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
            for try await _ in session.stream(messages: [.init(role: .user, content: "Q")]) {}
        }
        let requests = StubURLProtocol.allRequests
        XCTAssertEqual(requests.map { $0.url!.absoluteString },
            [c["oldRoot"] as! String, c["oldRoot"] as! String, c["newRoot"] as! String].map { $0 + "/chat/completions" })
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization")! }, ["Bearer key-A", "Bearer key-A", "Bearer key-B"])
        let bodies = try requests.map { try JSONSerialization.jsonObject(with: XCTUnwrap($0.bodyData)) as! [String: Any] }
        XCTAssertEqual(bodies.map { $0["model"] as! String }, ["model:old", "model:old", "model:new"])
        XCTAssertEqual(bodies.map { $0["max_tokens"] as! Int }, [333, 333, 777])
        XCTAssertEqual(captured.storageKey, "p:model:old")
        XCTAssertEqual(captured.limits.runtimeContext, 4096)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        SuspendedProviderURLProtocol.reset()
        super.tearDown()
    }

    func testEveryRoutingFailureAndPrivacyFixture() async throws {
        for row in try fixtures("provider-routing") where row["expectedError"] != nil {
            StubURLProtocol.reset()
            let name = row["name"] as! String
            let operation = row["operation"] as! String
            let expected = row["expectedError"] as! String
            let type = ProviderType(rawValue: row["type"] as! String)!
            let store = try NotebookStore(path: .inMemory)
            let defaults = preferences(providerId: "p", model: "m:tag")
            if row["missing"] as? Bool != true {
                try store.saveProvider(.init(id: "p", type: type, name: name,
                    baseURL: "https://unit.example/root", enabled: row["enabled"] as? Bool ?? true,
                    privacyAcknowledged: row["acknowledged"] as? Bool ?? true))
            }
            let router = makeRouter(store, defaults: defaults)
            if operation == "backgroundEmbed" {
                let notebook = try store.createNotebook(name: name)
                let source = try store.createSource(notebookId: XCTUnwrap(notebook.id), type: .text,
                    title: "pending", uri: nil, rawPath: nil)
                try store.replaceChunks(sourceId: XCTUnwrap(source.id),
                    chunks: [.init(text: "private text", tokenCount: 2)])
                let worker = EmbeddingWorker(embedder: Embedder(store: store, client: router, model: "p:m:tag"))
                await worker.kick()
                await worker.waitUntilIdle()
                let failure = await worker.lastError
                XCTAssertEqual(failure as? ProviderError, .consentRequired, name)
                let embedded = await worker.totalEmbedded
                XCTAssertEqual(embedded, 0, name)
                XCTAssertEqual(try store.unembeddedCount(model: "p:m:tag"), 1, name)
                try store.runOnDatabase { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings"), 0, name)
                }
            } else {
                do {
                    if operation == "embed" {
                        _ = try await router.embed(model: "p:m:tag", inputs: ["private text"])
                    } else {
                        _ = try await router.prepareChat()
                    }
                    XCTFail("Expected \(expected): \(name)")
                } catch {
                    XCTAssertEqual(errorCode(error), expected, name)
                }
            }
            XCTAssertEqual(StubURLProtocol.allRequests.count, row["expectedRequests"] as? Int, name)
        }
    }

    func testCapturedConsentSurvivesRevocationButNewTurnFails() async throws {
        let row = try fixture("provider-routing", name: "capture-and-rotate")
        let store = try NotebookStore(path: .inMemory)
        let defaults = preferences(providerId: "p", model: row["oldModel"] as! String)
        try store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P",
            baseURL: row["oldRoot"] as! String, privacyAcknowledged: true))
        let router = makeRouter(store, defaults: defaults)
        let captured = try await router.prepareChat()
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE providers SET privacy_acknowledged=0 WHERE id=?", arguments: ["p"])
        }
        StubURLProtocol.enqueue(.json(Data("data: [DONE]\n".utf8)))
        try await drain(captured.stream(messages: question))
        XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
        StubURLProtocol.reset()
        do {
            _ = try await router.prepareChat()
            XCTFail("New turns must recheck consent")
        } catch { XCTAssertEqual(error as? ProviderError, .consentRequired) }
        XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
        try store.acknowledgePrivacy(providerId: "p")
        _ = try await router.prepareChat()
        XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
    }

    func testPrepareModelOverridesPreserveRawTagsAndQualifiedModels() async throws {
        let row = try fixture("provider-routing", name: "capture-and-rotate")
        let store = try NotebookStore(path: .inMemory)
        let defaults = preferences(providerId: "selected", model: "selected:model")
        for id in ["selected", "p"] {
            try store.saveProvider(.init(id: id, type: .openaiCompatible, name: id,
                baseURL: row["oldRoot"] as! String, privacyAcknowledged: true))
        }
        let router = makeRouter(store, defaults: defaults)
        let selected = try await router.prepareChat()
        XCTAssertEqual(selected.storageKey, "selected:selected:model")
        let tagged = try await router.prepareChat(model: "llama3.2:3b")
        XCTAssertEqual(tagged.providerId, "selected")
        XCTAssertEqual(tagged.model, "llama3.2:3b")
        let qualified = try await router.prepareChat(model: "p:model:tag:extra")
        XCTAssertEqual(qualified.providerId, "p")
        XCTAssertEqual(qualified.model, "model:tag:extra")
        XCTAssertEqual(qualified.storageKey, "p:model:tag:extra")
        let absentID = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
        do {
            _ = try await router.prepareChat(model: absentID + ":m:tag")
            XCTFail("A recognized missing provider ID must fail")
        } catch { XCTAssertEqual(error as? ProviderConfigurationError, .missingProvider) }
        XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
    }

    func testCustomOllamaRootReachesEveryFixturePath() async throws {
        let row = try fixture("provider-routing", name: "custom-ollama")
        let metadata = try fixture("provider-limits", name: "ollama-large")
        let store = try NotebookStore(path: .inMemory)
        let defaults = preferences(providerId: "p", model: metadata["model"] as! String)
        let root = row["root"] as! String
        try store.saveProvider(.init(id: "p", type: .ollama, name: "GPU", baseURL: root))
        let router = makeRouter(store, defaults: defaults)
        try store.saveProviderModelLimits(ProviderLimitPolicy.automatic(providerId: "p", type: .ollama,
            model: metadata["model"] as! String, contextWindow: nil))
        StubURLProtocol.enqueue(.json(chatDone(.ollama)))
        try await drain(router.stream(model: "stale", messages: question))
        StubURLProtocol.enqueue(.json(Data("{\"embeddings\":[[1,0]]}".utf8)))
        let vectors = try await router.embed(model: "p:m:tag", inputs: ["a"])
        XCTAssertEqual(vectors, [[1, 0]])
        StubURLProtocol.enqueue(.json(Data("{\"models\":[{\"name\":\"m:tag\"}]}".utf8)))
        let models = try await router.discoverModels(providerId: "p")
        XCTAssertEqual(models.map(\.id), ["m:tag"])
        StubURLProtocol.enqueue(.json(try JSONSerialization.data(withJSONObject: metadata["show"]!)))
        let limits = try await router.resolveLimits(providerId: "p", model: "m:tag", refresh: true)
        XCTAssertEqual(limits.contextWindow, metadata["window"] as? Int)
        XCTAssertEqual(limits.runtimeContext, 8192, "Advertised context must not raise runtime")
        XCTAssertEqual(StubURLProtocol.allRequests.map { $0.url!.absoluteString },
            (row["paths"] as! [String]).map { root + "/" + $0 })
        XCTAssertEqual(StubURLProtocol.allRequests.map(\.httpMethod), ["POST", "POST", "GET", "POST"])
        XCTAssertEqual(try body(StubURLProtocol.allRequests.last!)["model"] as? String, "m:tag")
    }

    func testResolvedLimitsMatchEveryAutomaticFixtureAndCacheMetadata() async throws {
        for row in try fixtures("provider-limits") where row["expected"] != nil {
            guard row["show"] != nil || row["type"] as? String != "ollama" else { continue }
            StubURLProtocol.reset()
            let store = try NotebookStore(path: .inMemory)
            let type = ProviderType(rawValue: row["type"] as! String)!
            let model = row["model"] as! String
            try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: "https://unit.example/root",
                privacyAcknowledged: true))
            let router = makeRouter(store, defaults: preferences(providerId: "p", model: model))
            if let show = row["show"] {
                StubURLProtocol.enqueue(.json(try JSONSerialization.data(withJSONObject: show)))
            }
            let limits = try await router.resolveLimits(providerId: "p", model: model)
            let expected = row["expected"] as! [String: Any]
            XCTAssertEqual(limits.contextWindow, expected["contextWindow"] as? Int, row["name"] as! String)
            XCTAssertEqual(limits.runtimeContext, expected["runtimeContext"] as? Int)
            XCTAssertEqual(limits.maxOutputTokens, expected["maxOutputTokens"] as? Int)
            XCTAssertEqual(limits.isAssumed, expected["isAssumed"] as? Bool)
            XCTAssertEqual(try store.providerModelLimits(providerId: "p", model: model), limits)
            let cached = try await router.resolveLimits(providerId: "p", model: model)
            XCTAssertEqual(cached, limits)
            XCTAssertEqual(StubURLProtocol.allRequests.count, type == .ollama ? 1 : 0)
        }
    }

    /// provider-listing-limits-v1: discovery stores advertised windows; an explicit refresh re-reads the
    /// listing; chat preparation never sends an extra request; user limits always win.
    func testListingWindowsBecomeAutomaticLimits() async throws {
        for type in [ProviderType.openwebui, .openaiCompatible] {
            StubURLProtocol.reset()
            let store = try NotebookStore(path: .inMemory)
            try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: "https://unit.example/root",
                privacyAcknowledged: true))
            let router = makeRouter(store, defaults: preferences(providerId: "p", model: "big"))
            try store.saveProviderModelLimits(ProviderModelLimits(providerId: "p", model: "pinned", contextWindow: nil,
                runtimeContext: 4_096, maxOutputTokens: 512, source: "user"))
            let listing = Data(#"{"data":[{"id":"big","max_model_len":131072},{"id":"small","context_length":4096},{"id":"pinned","max_model_len":65536},{"id":"plain"}]}"#.utf8)
            StubURLProtocol.enqueue(.json(listing))
            let models = try await router.discoverModels(providerId: "p")
            XCTAssertEqual(models.map(\.id), ["big", "pinned", "plain", "small"])
            XCTAssertEqual(models.map(\.contextWindow), [131_072, 65_536, nil, 4_096])
            XCTAssertEqual(try store.providerModelLimits(providerId: "p", model: "big")?.runtimeContext, 32_768)
            XCTAssertEqual(try store.providerModelLimits(providerId: "p", model: "small")?.runtimeContext, 4_096)
            XCTAssertEqual(try store.providerModelLimits(providerId: "p", model: "pinned")?.source, "user")
            XCTAssertNil(try store.providerModelLimits(providerId: "p", model: "plain"))
            // Chat-path resolution of an unknown model stays offline and assumed.
            let assumed = try await router.resolveLimits(providerId: "p", model: "plain")
            XCTAssertTrue(assumed.isAssumed)
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
            // An explicit refresh reads the listing again.
            StubURLProtocol.enqueue(.json(Data(#"{"data":[{"id":"plain","info":{"params":{"num_ctx":24576}}}]}"#.utf8)))
            let refreshed = try await router.resolveLimits(providerId: "p", model: "plain", refresh: true)
            XCTAssertEqual(refreshed.contextWindow, 24_576)
            XCTAssertEqual(refreshed.runtimeContext, 24_576)
            XCTAssertFalse(refreshed.isAssumed)
            // A failing listing leaves a refresh assumed instead of failing it.
            StubURLProtocol.enqueue(.json(Data("{}".utf8), status: 500))
            try store.deleteProviderModelLimits(providerId: "p", model: "plain")
            let failed = try await router.resolveLimits(providerId: "p", model: "plain", refresh: true)
            XCTAssertTrue(failed.isAssumed)
            XCTAssertEqual(StubURLProtocol.allRequests.map(\.httpMethod), ["GET", "GET", "GET"])
        }
    }

    func testUserLimitsSkipShowEvenWhenRefreshRequested() async throws {
        let row = try fixture("provider-store", name: "user-survives-auto")
        let store = try NotebookStore(path: .inMemory)
        let user = userLimits(row)
        try store.saveProvider(.init(id: user.providerId, type: .ollama, name: "P", baseURL: "http://gpu-box:11434"))
        try store.saveProviderModelLimits(user)
        let router = makeRouter(store, defaults: preferences(providerId: user.providerId, model: user.model))
        let refreshed = try await router.resolveLimits(providerId: user.providerId, model: user.model, refresh: true)
        XCTAssertEqual(refreshed, user)
        let captured = try await router.prepareChat()
        XCTAssertEqual(captured.limits, user)
        XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
    }

    func testAutomaticRefreshReturnsConcurrentUserOverride() async throws {
        let row = try fixture("provider-store", name: "user-survives-auto")
        let metadata = try fixture("provider-limits", name: "ollama-large")
        let user = userLimits(row)
        let store = try NotebookStore(path: .inMemory)
        try store.saveProvider(.init(id: user.providerId, type: .ollama, name: "P", baseURL: "http://gpu-box:11434"))
        try store.saveProviderModelLimits(ProviderLimitPolicy.automatic(providerId: user.providerId,
            type: .ollama, model: user.model, contextWindow: nil))
        let started = expectation(description: "show started")
        SuspendedProviderURLProtocol.configure(holding: "/api/show", started: started)
        let router = makeRouter(store, defaults: preferences(providerId: user.providerId, model: user.model),
            session: SuspendedProviderURLProtocol.session())
        let refresh = Task { try await router.resolveLimits(providerId: user.providerId, model: user.model, refresh: true) }
        await fulfillment(of: [started], timeout: 5)
        try store.saveProviderModelLimits(user)
        SuspendedProviderURLProtocol.release(data: try JSONSerialization.data(withJSONObject: metadata["show"]!))
        let refreshed = try await refresh.value
        XCTAssertEqual(refreshed, user)
        XCTAssertEqual(try store.providerModelLimits(providerId: user.providerId, model: user.model), user)
    }

    func testPrepareCapturesBeforeShowSuspendsAndDoesNotRereadSecrets() async throws {
        let row = try fixture("provider-routing", name: "capture-and-rotate")
        let metadata = try fixture("provider-limits", name: "ollama-large")
        let store = try NotebookStore(path: .inMemory)
        let defaults = preferences(providerId: "p", model: row["oldModel"] as! String)
        var config = ProviderConfig(id: "p", type: .ollama, name: "Before",
            baseURL: row["oldRoot"] as! String, privacyAcknowledged: true)
        try store.saveProvider(config)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: "p", secret: row["oldKey"] as! String)
        let started = expectation(description: "captured show started")
        SuspendedProviderURLProtocol.configure(holding: "/api/show", started: started)
        let router = makeRouter(store, defaults: defaults, secrets: secrets, session: SuspendedProviderURLProtocol.session())
        let preparation = Task { try await router.prepareChat() }
        await fulfillment(of: [started], timeout: 5)
        config.baseURL = row["newRoot"] as! String
        config.type = .openaiCompatible
        try store.saveProvider(config)
        defaults.set(row["newModel"] as! String, forKey: ProviderSettingsKeys.chatModel)
        try secrets.save(providerId: "p", secret: row["newKey"] as! String)
        SuspendedProviderURLProtocol.release(data: try JSONSerialization.data(withJSONObject: metadata["show"]!))
        let captured = try await preparation.value
        XCTAssertEqual(captured.model, row["oldModel"] as? String)
        XCTAssertEqual(captured.limits.contextWindow, metadata["window"] as? Int)
        try await drain(captured.stream(messages: question))
        let next = try await router.prepareChat()
        try await drain(next.stream(messages: question))
        let requests = SuspendedProviderURLProtocol.requests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [
            (row["oldRoot"] as! String) + "/api/show",
            (row["oldRoot"] as! String) + "/api/chat",
            (row["newRoot"] as! String) + "/chat/completions"])
        XCTAssertEqual(try body(requests[0])["model"] as? String, row["oldModel"] as? String)
        XCTAssertEqual(try body(requests[1])["model"] as? String, row["oldModel"] as? String)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer " + (row["newKey"] as! String))
    }

    func testExplicitOptionsAreAppliedForEveryProviderWithoutSavingAnOverride() async throws {
        for row in try fixtures("provider-options") {
            StubURLProtocol.reset()
            let type = ProviderType(rawValue: row["type"] as! String)!
            let store = try NotebookStore(path: .inMemory)
            try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: "https://unit.example/root",
                privacyAcknowledged: true))
            let persisted = try ProviderLimitPolicy.automatic(providerId: "p", type: type, model: "m:tag", contextWindow: 32768)
            try store.saveProviderModelLimits(persisted)
            let router = makeRouter(store, defaults: preferences(providerId: "p", model: "m:tag"))
            let options = ChatRequestOptions(runtimeContext: row["runtimeContext"] as! Int,
                maxOutputTokens: row["maxOutputTokens"] as! Int)
            StubURLProtocol.enqueue(.json(chatDone(type)))
            try await drain(router.stream(model: "stale", messages: question, options: options))
            let request = try XCTUnwrap(StubURLProtocol.lastRequest)
            let payload = try body(request)
            XCTAssertEqual(payload["model"] as? String, "m:tag")
            for (key, expected) in row["expected"] as! [String: Any] {
                XCTAssertEqual(payload[key] as? NSObject, expected as? NSObject, row["name"] as! String)
            }
            XCTAssertEqual(try store.providerModelLimits(providerId: "p", model: "m:tag"), persisted)
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
        }
    }

    func testExplicitOptionsRejectKnownCeilingAndInvalidBudgetsBeforeHTTP() async throws {
        let store = try NotebookStore(path: .inMemory)
        try store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P", baseURL: "https://unit.example/root",
            privacyAcknowledged: true))
        let saved = ProviderModelLimits(providerId: "p", model: "m", contextWindow: 4096,
            runtimeContext: 4096, maxOutputTokens: 333, source: "user")
        try store.saveProviderModelLimits(saved)
        let router = makeRouter(store, defaults: preferences(providerId: "p", model: "m"))
        for row in try fixtures("provider-limits") where row["user"] != nil && row["name"] as? String != "negative-window" {
            let user = row["user"] as! [String: Int]
            do {
                try await drain(router.stream(model: "stale", messages: question,
                    options: .init(runtimeContext: user["runtimeContext"]!, maxOutputTokens: user["maxOutputTokens"]!)))
                XCTFail("Expected invalidLimits for \(row["name"]!)")
            } catch { XCTAssertEqual(error as? ProviderConfigurationError, .invalidLimits) }
        }
        XCTAssertEqual(try store.providerModelLimits(providerId: "p", model: "m"), saved)
        XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
    }

    func testDiscoveryRejectsMalformedArraysAndModelIDsForEveryProvider() async throws {
        for type in ProviderType.allCases {
            let store = try NotebookStore(path: .inMemory)
            try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: "https://unit.example/root",
                privacyAcknowledged: true))
            let router = makeRouter(store, defaults: preferences(providerId: "p", model: "m"))
            let array = type == .ollama ? "models" : "data"
            let id = type == .ollama ? "name" : "id"
            for payload in ["{}", "{\"\(array)\":null}", "{\"\(array)\":{}}", "{\"\(array)\":[{}]}", "{\"\(array)\":[{\"\(id)\":42}]}", "{"] {
                StubURLProtocol.reset()
                StubURLProtocol.enqueue(.json(Data(payload.utf8)))
                do {
                    _ = try await router.discoverModels(providerId: "p")
                    XCTFail("Expected decoding failure for \(type): \(payload)")
                } catch { XCTAssertEqual(errorCode(error), "decoding") }
                XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
            }
        }
    }

    func testDiscoveryPropagatesEveryProbeFailureAndUnsupportedStatus() async throws {
        for row in try fixtures("provider-probe") where row["expectedStatus"] as? String != "verified" {
            StubURLProtocol.reset()
            let store = try NotebookStore(path: .inMemory)
            let type = ProviderType(rawValue: row["type"] as! String)!
            try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: "https://unit.example/root",
                privacyAcknowledged: true))
            let router = makeRouter(store, defaults: preferences(providerId: "p", model: "m"))
            if row["response"] as? String == "transport" { StubURLProtocol.enqueue(.connectionRefused()) }
            else { StubURLProtocol.enqueue(.json(Data("{}".utf8), status: row["statusCode"] as! Int)) }
            do {
                _ = try await router.discoverModels(providerId: "p")
                XCTFail("Expected discovery failure for \(row["name"]!)")
            } catch {
                let expected = row["expectedStatus"] as? String == "listingUnsupported" ? "listingUnsupported" : row["errorCode"] as! String
                XCTAssertEqual(errorCode(error), expected, row["name"] as! String)
            }
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
        }
    }

    func testInvalidRootsFailBeforeConsentAndProbeDetailsNeverExposeCredentials() async throws {
        let store = try NotebookStore(path: .inMemory)
        let invalid = "http://user:secret@host/v1"
        try store.saveProvider(.init(id: "p", type: .openaiCompatible, name: "P", baseURL: invalid))
        let router = makeRouter(store, defaults: preferences(providerId: "p", model: "m"))
        do {
            _ = try await router.prepareChat()
            XCTFail("Expected invalidBaseURL before consent")
        } catch { XCTAssertEqual(error as? ProviderConfigurationError, .invalidBaseURL) }
        let invalidResult = try await router.probe(type: .openaiCompatible, baseURL: invalid, apiKey: "private-key")
        XCTAssertEqual(invalidResult.status.rawValue, "failed")
        XCTAssertEqual(invalidResult.errorCode, "invalidBaseURL")
        XCTAssertFalse(invalidResult.detail?.contains("secret") ?? false)
        XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
        StubURLProtocol.enqueue(.json(Data("{\"error\":\"Authorization: Bearer private-key\"}".utf8), status: 401))
        let result = try await router.probe(type: .openaiCompatible, baseURL: "https://unit.example/root", apiKey: "private-key")
        XCTAssertEqual(result.errorCode, "auth")
        XCTAssertFalse(result.detail?.contains("private-key") ?? false)
        XCTAssertFalse(result.detail?.contains("Authorization") ?? false)
    }

    func testProbeDiscoveryShowAndPrepareCancellationRemainCancellation() async throws {
        for operation in ["probe", "discover", "show", "prepare"] {
            SuspendedProviderURLProtocol.reset()
            let store = try NotebookStore(path: .inMemory)
            let type: ProviderType = ["show", "prepare"].contains(operation) ? .ollama : .openaiCompatible
            try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: "https://unit.example/root",
                privacyAcknowledged: true))
            let started = expectation(description: operation + " started")
            SuspendedProviderURLProtocol.configure(holding: type == .ollama ? "/api/show" : "/models", started: started)
            let router = makeRouter(store, defaults: preferences(providerId: "p", model: "m"),
                session: SuspendedProviderURLProtocol.session())
            let task = Task {
                if operation == "probe" {
                    _ = try await router.probe(type: .openaiCompatible, baseURL: "https://unit.example/root", apiKey: nil)
                } else if operation == "discover" { _ = try await router.discoverModels(providerId: "p") }
                else if operation == "show" { _ = try await router.resolveLimits(providerId: "p", model: "m") }
                else { _ = try await router.prepareChat() }
            }
            await fulfillment(of: [started], timeout: 5)
            task.cancel()
            do { try await task.value; XCTFail("Cancellation must throw") }
            catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
            XCTAssertEqual(SuspendedProviderURLProtocol.requests.count, 1)
        }
    }

    func testShowUnsupportedAllowsAssumptionsButOtherFailuresPropagate() async throws {
        let probeRows = try fixtures("provider-probe").filter { $0["type"] as? String == "ollama" && $0["expectedStatus"] as? String != "verified" }
        for row in probeRows {
            StubURLProtocol.reset()
            let store = try NotebookStore(path: .inMemory)
            let router = makeRouter(store, defaults: preferences(providerId: ProviderConfig.ollamaId, model: "m"))
            if row["response"] as? String == "transport" { StubURLProtocol.enqueue(.connectionRefused()) }
            else {
                let body = row["response"] as? String == "malformed" ? "{" : "{}"
                StubURLProtocol.enqueue(.json(Data(body.utf8), status: row["statusCode"] as! Int))
            }
            do {
                let limits = try await router.resolveLimits(providerId: ProviderConfig.ollamaId, model: "m", refresh: true)
                XCTAssertEqual(row["expectedStatus"] as? String, "listingUnsupported", row["name"] as! String)
                XCTAssertTrue(limits.isAssumed)
                XCTAssertEqual(limits.options, .defaults)
            } catch {
                XCTAssertEqual(errorCode(error), row["errorCode"] as? String, row["name"] as! String)
                XCTAssertNil(try store.providerModelLimits(providerId: ProviderConfig.ollamaId, model: "m"))
            }
            XCTAssertEqual(StubURLProtocol.allRequests.count, 1)
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/show")
        }
    }

    private var question: [ChatTurn] { [.init(role: .user, content: "Q")] }
    private func fixtures(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/" + name + "-v1.json")["cases"] as? [[String: Any]])
    }
    private func fixture(_ name: String, name caseName: String) throws -> [String: Any] {
        try XCTUnwrap(fixtures(name).first { $0["name"] as? String == caseName })
    }
    private func preferenceSuite() -> UserDefaults {
        let name = "provider-session." + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
    private func preferences(providerId: String, model: String) -> UserDefaults {
        let defaults = preferenceSuite()
        defaults.set(providerId, forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set(providerId, forKey: ProviderSettingsKeys.embeddingProviderId)
        defaults.set(model, forKey: ProviderSettingsKeys.chatModel)
        defaults.set(model, forKey: ProviderSettingsKeys.embeddingModel)
        return defaults
    }
    private func makeRouter(_ store: NotebookStore, defaults: UserDefaults,
                            secrets: InMemorySecretStore = InMemorySecretStore(), session: URLSession = StubURLProtocol.session()) -> ProviderRouter {
        ProviderRouter(store: store, secrets: secrets, selection: DefaultsProviderSelection(defaults: defaults), session: session)
    }
    private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws {
        for try await _ in stream {}
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any])
    }
    private func chatDone(_ type: ProviderType) -> Data {
        switch type {
        case .ollama: Data("{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n".utf8)
        case .anthropic: Data("data: {\"type\":\"message_stop\"}\n".utf8)
        default: Data("data: [DONE]\n".utf8)
        }
    }
    private func userLimits(_ row: [String: Any]) -> ProviderModelLimits {
        .init(providerId: row["providerId"] as! String, model: row["model"] as! String,
            contextWindow: row["contextWindow"] as? Int, runtimeContext: row["runtimeContext"] as! Int,
            maxOutputTokens: row["maxOutputTokens"] as! Int, source: "user")
    }
    private func errorCode(_ error: Error) -> String {
        if let config = error as? ProviderConfigurationError { return config.rawValue }
        if error is ProviderListingUnsupported { return "listingUnsupported" }
        if let provider = error as? ProviderError {
            switch provider {
            case .consentRequired: return "consentRequired"
            case .auth: return "auth"
            case .decoding: return "decoding"
            default: return "http"
            }
        }
        if case let OllamaError.httpStatus(code, _) = error { return [401, 403].contains(code) ? "auth" : "http" }
        if error is DecodingError { return "decoding" }
        let foundationError = error as NSError
        if foundationError.domain == NSCocoaErrorDomain && foundationError.code == 3840 { return "decoding" }
        return "transport"
    }
}

/// A single explicitly held response makes MainActor configuration races deterministic.
private final class SuspendedProviderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var heldPath: String?
    private static nonisolated(unsafe) var started: XCTestExpectation?
    private static nonisolated(unsafe) var held: SuspendedProviderURLProtocol?
    private static nonisolated(unsafe) var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(holding path: String, started expectation: XCTestExpectation) {
        lock.withLock { heldPath = path; started = expectation }
    }
    static func reset() { lock.withLock { heldPath = nil; started = nil; held = nil; recorded = [] } }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }
    static func release(data: Data) {
        let pending = lock.withLock { let value = held; held = nil; heldPath = nil; return value }
        pending?.finish(data)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let waiting: (Bool, XCTestExpectation?) = Self.lock.withLock {
            Self.recorded.append(request)
            if let suffix = Self.heldPath, request.url!.path.hasSuffix(suffix) {
                Self.held = self
                return (true, Self.started)
            }
            return (false, nil)
        }
        if waiting.0 { waiting.1?.fulfill(); return }
        if request.url!.path.hasSuffix("/api/chat") {
            finish(Data("{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n".utf8))
        } else { finish(Data("data: [DONE]\n".utf8)) }
    }
    private func finish(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.withLock { if Self.held === self { Self.held = nil } }
    }
}
