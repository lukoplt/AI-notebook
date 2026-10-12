import Foundation
import XCTest
@testable import AINotebookCore

/// Dedicated interceptor so benchmark wire tests never share state with other suites.
final class BenchmarkURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static nonisolated(unsafe) var _handler: Handler?
    private static nonisolated(unsafe) var _requests: [URLRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock { _handler = handler; _requests = [] }
    }
    static var requests: [URLRequest] { lock.withLock { _requests } }
    static func reset() { lock.withLock { _handler = nil; _requests = [] } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BenchmarkURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        copy.httpBody = request.bodyData
        let handler = Self.lock.withLock { () -> Handler? in Self._requests.append(copy); return Self._handler }
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        do {
            let (status, data) = try handler(copy)
            client?.urlProtocol(self, didReceive: httpResponse(request.url!, status: status), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Maps WP7 errors to contract codes for fixture assertions.
func benchmarkErrorCode(_ error: any Error) -> String {
    switch error {
    case let e as EmbeddingProfileError: return e.code
    case is EmbeddingInputTooLong: return "inputTooLong"
    case ProviderError.http: return "providerError"
    case is CancellationError: return "cancelled"
    case let e as RetrievalError: return e.rawValue
    case let e as ProviderConfigurationError: return e.rawValue
    default: return "unexpected:\(error)"
    }
}

func jsonData(_ value: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
}

func assertJSONEqual(_ data: Data?, _ expected: Any?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let expected, !(expected is NSNull) else {
        XCTAssertTrue(data == nil || data?.isEmpty == true, message, file: file, line: line); return
    }
    guard let data, let actual = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
        XCTFail("missing JSON body: \(message)", file: file, line: line); return
    }
    XCTAssertEqual(actual as? NSObject, expected as? NSObject, message, file: file, line: line)
}

@MainActor
final class OllamaBenchmarkClientTests: XCTestCase {
    private let file = "embedding-strict-v1.json"

    override func tearDown() {
        BenchmarkURLProtocol.reset()
        super.tearDown()
    }

    private func client(_ root: String) -> OllamaBenchmarkClient {
        OllamaBenchmarkClient(baseURL: URL(string: root)!, session: BenchmarkURLProtocol.session())
    }

    private func serve(_ response: [String: Any]) {
        let status = response["status"] as! Int
        let body: Data
        if let text = response["bodyText"] as? String { body = Data(text.utf8) } else { body = jsonData(response["body"]!) }
        BenchmarkURLProtocol.install { _ in (status, body) }
    }

    private func assertRequest(_ request: URLRequest?, _ expected: [String: Any], _ name: String) {
        XCTAssertEqual(request?.httpMethod, expected["method"] as? String, name)
        XCTAssertEqual(request?.url?.absoluteString, expected["url"] as? String, name)
        assertJSONEqual(request?.httpBody, expected["body"], name)
    }

    func testSharedWireCases() async throws {
        let rows = try BenchmarkFixture.cases(file, kind: "wire")
        XCTAssertEqual(rows.count, 19)
        for c in rows {
            let name = c["name"] as! String
            let call = c["call"] as! [String: Any]
            let expected = c["expected"] as! [String: Any]
            serve(c["response"] as! [String: Any])
            let client = client(call["root"] as! String)
            do {
                switch call["method"] as! String {
                case "embed":
                    let r = try await client.embed(model: call["model"] as! String, input: call["input"] as! String,
                                                   nativeDims: call["nativeDims"] as! Int, inputLimit: call["inputLimit"] as! Int)
                    XCTAssertNil(expected["error"], name)
                    XCTAssertEqual(r.promptTokens, expected["promptTokens"] as? Int, name)
                    XCTAssertEqual(r.totalDurationNs, (expected["totalDurationNs"] as? NSNumber)?.int64Value, name)
                    XCTAssertEqual(r.loadDurationNs, (expected["loadDurationNs"] as? NSNumber)?.int64Value, name)
                    if let millionths = expected["vectorMillionths"] {
                        BenchmarkFixture.assertMillionths(r.vector, millionths, name)
                    } else {
                        XCTAssertEqual(r.vector.count, expected["vectorLength"] as? Int, name)
                        XCTAssertEqual(Double(r.vector[0]), (expected["firstComponentMillionths"] as! Double) / 1e6,
                                       accuracy: 1e-6, name)
                    }
                case let method:
                    let o = call["options"] as! [String: Any]
                    let options = ChatRequestOptions(runtimeContext: o["runtimeContext"] as! Int,
                                                     maxOutputTokens: o["maxOutputTokens"] as! Int)
                    let observation: ChatTokenObservation
                    let providerMethod: String
                    if method == "observeRaw" {
                        observation = try await client.observeRaw(model: call["model"] as! String,
                                                                  text: call["text"] as! String, options: options)
                        providerMethod = OllamaBenchmarkClient.rawMethod
                    } else {
                        let turns = (call["messages"] as! [[String: String]]).map {
                            ChatTurn(role: ChatRole(rawValue: $0["role"]!)!, content: $0["content"]!)
                        }
                        observation = try await client.observeChat(model: call["model"] as! String, messages: turns,
                                                                   options: options)
                        providerMethod = OllamaBenchmarkClient.chatMethod
                    }
                    XCTAssertNil(expected["error"], name)
                    XCTAssertEqual(observation.text, expected["text"] as? String, name)
                    XCTAssertEqual(observation.promptTokens, expected["promptTokens"] as? Int, name)
                    XCTAssertEqual(observation.outputTokens, expected["outputTokens"] as? Int, name)
                    var fallback: (@Sendable () async throws -> OfflineTokenCount)?
                    if let request = expected["fallbackRequest"] as? [String: Any],
                       let response = expected["fallbackResponse"] as? [String: Any] {
                        let line = try OfflineTokenizerProtocol.encodeRequest(
                            requestId: request["requestId"] as! String, tokenizerId: request["tokenizerId"] as! String,
                            text: request["text"] as! String)
                        XCTAssertEqual(line.last, 0x0A, name)
                        assertJSONEqual(line.dropLast(), request, name)
                        XCTAssertEqual(request["text"] as? String, call["text"] as? String, name)
                        let decoded = try OfflineTokenizerProtocol.decodeResponse(
                            jsonData(response), requestId: request["requestId"] as! String,
                            tokenizerId: request["tokenizerId"] as! String)
                        fallback = { decoded }
                    }
                    let resolved = try await OllamaBenchmarkClient.resolvePromptCount(
                        observation, providerMethod: providerMethod, fallback: fallback)
                    XCTAssertEqual(resolved?.method, expected["method"] as? String, name)
                    XCTAssertEqual(resolved?.tokens, (expected["observedTokens"] ?? expected["promptTokens"]) as? Int, name)
                }
            } catch {
                XCTAssertEqual(benchmarkErrorCode(error), expected["error"] as? String, name)
                if let status = expected["status"] as? Int {
                    guard case let ProviderError.http(code, _) = error else { XCTFail(name); continue }
                    XCTAssertEqual(code, status, name)
                }
            }
            XCTAssertEqual(BenchmarkURLProtocol.requests.count, 1, name)
            assertRequest(BenchmarkURLProtocol.requests.first, c["request"] as! [String: Any], name)
        }
    }

    // MARK: - Captured profile preparation

    private func serveDiscovery(tags: Any?, show: Any?) {
        let tagsData = jsonData(tags ?? ["models": []]), showData = show.flatMap { $0 is NSNull ? nil : jsonData($0) }
        BenchmarkURLProtocol.install { request in
            switch request.url?.path {
            case let path? where path.hasSuffix("/api/tags"): return (200, tagsData)
            case let path? where path.hasSuffix("/api/show"):
                return showData.map { (200, $0) } ?? (404, Data(#"{"error":"not found"}"#.utf8))
            default: return (500, Data(#"{"error":"unexpected"}"#.utf8))
            }
        }
    }

    private func assertRequests(_ expected: Any?, _ name: String) {
        let want = expected as? [[String: Any]] ?? []
        let got = BenchmarkURLProtocol.requests
        XCTAssertEqual(got.count, want.count, name)
        for (g, w) in zip(got, want) { assertRequest(g, w, name) }
        XCTAssertFalse(got.contains { $0.url?.path.hasSuffix("/api/embed") == true }, name)
    }

    private func identity(_ object: [String: Any]) -> GenerationIdentity {
        GenerationIdentity(providerId: object["providerId"] as! String, endpointRevision: object["endpointRevision"] as! String,
                           model: object["model"] as! String, modelDigest: object["modelDigest"] as? String,
                           dims: object["dims"] as! Int, normalization: object["normalization"] as! String,
                           queryFormatVersion: object["queryFormatVersion"] as! String,
                           docFormatVersion: object["docFormatVersion"] as! String,
                           chunkerVersion: object["chunkerVersion"] as! String)
    }

    func testSharedPrepareCases() async throws {
        let rows = try BenchmarkFixture.cases(file, kind: "prepare")
        XCTAssertEqual(rows.count, 14)
        for c in rows {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let p = c["provider"] as! [String: Any]
            let snapshot = EmbeddingProviderSnapshot(
                providerId: p["id"] as! String, type: ProviderType(rawValue: p["type"] as! String)!,
                root: p["root"] as! String, enabled: p["enabled"] as! Bool, consented: p["consented"] as! Bool,
                embeddingCapable: p["embeddingCapable"] as! Bool)
            serveDiscovery(tags: c["tags"], show: c["show"])
            let profile = try EmbeddingProfiles.require(c["profileId"] as! String)
            do {
                let prepared = try await OllamaBenchmarkClient.prepareProfile(profile, provider: snapshot,
                                                                              client: client(snapshot.root))
                XCTAssertNil(expected["error"] as? String, name)
                XCTAssertEqual(prepared.identity, identity(expected["identity"] as! [String: Any]), name)
                XCTAssertEqual(prepared.effectiveLimit, expected["effectiveLimit"] as? Int, name)
            } catch {
                XCTAssertEqual(benchmarkErrorCode(error), expected["error"] as? String, name)
            }
            assertRequests(expected["requests"], name)
            XCTAssertEqual(expected["embeddingRequests"] as? Int, 0, name)
        }
    }

    func testSharedResumeCases() async throws {
        let rows = try BenchmarkFixture.cases(file, kind: "resume")
        XCTAssertEqual(rows.count, 4)
        for c in rows {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let stored = identity(c["identity"] as! [String: Any])
            serveDiscovery(tags: c["tags"], show: nil)
            let profile = try EmbeddingProfiles.require(OllamaBenchmarkClient.profileId(fromFormatVersion: stored.queryFormatVersion)!)
            do {
                let limit = try await OllamaBenchmarkClient.revalidate(stored, profile: profile,
                                                                       client: client("http://127.0.0.1:11434"))
                XCTAssertNil(expected["error"] as? String, name)
                XCTAssertEqual(limit, expected["effectiveLimit"] as? Int, name)
            } catch {
                XCTAssertEqual(benchmarkErrorCode(error), expected["error"] as? String, name)
            }
            assertRequests(expected["requests"], name)
        }
    }

    // MARK: - Router capture

    private func router(root: String, type: ProviderType = .ollama) throws -> (ProviderRouter, NotebookStore) {
        let store = try NotebookStore(path: .inMemory)
        try store.saveProvider(ProviderConfig(id: ProviderConfig.ollamaId, type: type, name: "Ollama", baseURL: root,
                                              privacyAcknowledged: true))
        let router = ProviderRouter(store: store, secrets: InMemorySecretStore(),
                                    selection: FixedBenchmarkSelection(), session: BenchmarkURLProtocol.session())
        return (router, store)
    }

    func testPrepareProfileCapturesIdentityOnceAcrossRootMutation() async throws {
        let c = try XCTUnwrap(try BenchmarkFixture.cases(file, kind: "prepare").first { $0["name"] as? String == "prepare-profile-root-change" })
        let mutation = (c["mutations"] as! [[String: Any]])[0]
        XCTAssertEqual(mutation["after"] as? String, "tags")
        let original = (c["provider"] as! [String: Any])["root"] as! String
        let (router, store) = try router(root: original)
        let tagsData = jsonData(c["tags"]!), showData = jsonData(c["show"]!)
        let newRoot = mutation["value"] as! String
        BenchmarkURLProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/api/tags") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        var moved = try! store.provider(id: ProviderConfig.ollamaId)!
                        moved.baseURL = newRoot
                        try! store.saveProvider(moved)
                    }
                }
                return (200, tagsData)
            }
            if path.hasSuffix("/api/show") { return (200, showData) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let dims = body["dimensions"] as! Int
            var vector = [Double](repeating: 0, count: dims); vector[0] = 1
            return (200, jsonData(["embeddings": [vector], "prompt_eval_count": 3]))
        }
        let prepared = try await router.prepareEmbeddingProfile(providerId: ProviderConfig.ollamaId,
                                                                profileId: c["profileId"] as! String)
        let expected = c["expected"] as! [String: Any]
        XCTAssertEqual(prepared.identity, identity(expected["identity"] as! [String: Any]))
        XCTAssertEqual(prepared.session.identity, prepared.identity)
        XCTAssertEqual(try store.provider(id: ProviderConfig.ollamaId)?.baseURL, newRoot)
        let query = try await prepared.session.embed(inputs: ["Kdo ručí?"])
        let docs = try await prepared.session.embedDocuments(inputs: ["Záruka"])
        XCTAssertEqual(query[0].count, 256)
        XCTAssertEqual(docs[0].count, 256)
        let requests = BenchmarkURLProtocol.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url!.absoluteString.hasPrefix(original + "/api/") })
        let inputs = requests.suffix(2).map { (try! JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any])["input"] as! [String] }
        XCTAssertEqual(inputs, [["search_query: Kdo ručí?"], ["search_document: Záruka"]])
    }

    func testRouterRejectsUnsupportedProviderWithoutRequests() async throws {
        let (router, _) = try router(root: "https://api.openai.com/v1", type: .openai)
        serveDiscovery(tags: nil, show: nil)
        do {
            _ = try await router.prepareEmbeddingProfile(providerId: ProviderConfig.ollamaId, profileId: "bge-m3-1024")
            XCTFail("prepared a remote provider")
        } catch { XCTAssertEqual(benchmarkErrorCode(error), "unsupportedEmbeddingProfile") }
        do {
            _ = try await router.prepareEmbeddingProfile(providerId: ProviderConfig.ollamaId, profileId: "bge-m3")
            XCTFail("model name accepted as profile")
        } catch { XCTAssertEqual(benchmarkErrorCode(error), "unknownProfile") }
        XCTAssertTrue(BenchmarkURLProtocol.requests.isEmpty)
    }

    func testStoredProfileIdentityReopensThroughPrepareEmbedding() async throws {
        let rows = try BenchmarkFixture.cases(file, kind: "resume")
        let same = try XCTUnwrap(rows.first { $0["name"] as? String == "resume-digest-same" })
        let changed = try XCTUnwrap(rows.first { $0["name"] as? String == "resume-digest-changed" })
        let (router, _) = try router(root: "http://127.0.0.1:11434")
        let stored = identity(same["identity"] as! [String: Any])

        serveDiscovery(tags: changed["tags"], show: nil)
        do {
            _ = try await router.prepareEmbedding(identity: stored)
            XCTFail("changed digest prepared a session")
        } catch { XCTAssertEqual(benchmarkErrorCode(error), "embeddingModelChanged") }
        XCTAssertEqual(BenchmarkURLProtocol.requests.map { $0.url!.path }, ["/api/tags"])

        let tags = jsonData(same["tags"]!)
        BenchmarkURLProtocol.install { request in
            if request.url!.path.hasSuffix("/api/tags") { return (200, tags) }
            var vector = [Double](repeating: 0, count: 768); vector[1] = 2
            return (200, jsonData(["embeddings": [vector], "prompt_eval_count": 6]))
        }
        let session = try await router.prepareEmbedding(identity: stored)
        XCTAssertEqual(session.identity, stored)
        XCTAssertFalse(session.legacyEndpointUnverified)
        let vectors = try await session.embed(inputs: ["Kdo"])
        XCTAssertEqual(vectors[0].count, 256)
        XCTAssertEqual(vectors[0][1], 1, accuracy: 1e-6)
        let embed = BenchmarkURLProtocol.requests.last!
        assertJSONEqual(embed.httpBody, ["model": "nomic-embed-text-v2-moe", "input": ["search_query: Kdo"],
                                         "dimensions": 768, "truncate": false, "options": ["num_ctx": 512]], "embed")
        XCTAssertEqual(BenchmarkURLProtocol.requests.map { $0.url!.path }, ["/api/tags", "/api/embed"])
    }

    func testMissingDigestOrLegacyFormatsAreNotNamedProfiles() async throws {
        let (router, _) = try router(root: "http://127.0.0.1:11434")
        serveDiscovery(tags: nil, show: nil)
        let profile = try EmbeddingProfiles.require("nomic-v2-256")
        let noDigest = GenerationIdentity(
            providerId: ProviderConfig.ollamaId,
            endpointRevision: EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: "http://127.0.0.1:11434"),
            model: profile.model, modelDigest: nil, dims: 256, normalization: "l2",
            queryFormatVersion: profile.formatVersion(.query), docFormatVersion: profile.formatVersion(.document),
            chunkerVersion: "2")
        do {
            _ = try await router.prepareEmbedding(identity: noDigest)
            XCTFail("missing digest prepared")
        } catch { XCTAssertEqual(benchmarkErrorCode(error), "embeddingModelChanged") }
        let wrongDims = GenerationIdentity(
            providerId: noDigest.providerId, endpointRevision: noDigest.endpointRevision, model: profile.model,
            modelDigest: "sha256:" + String(repeating: "3", count: 64), dims: 768, normalization: "l2",
            queryFormatVersion: noDigest.queryFormatVersion, docFormatVersion: noDigest.docFormatVersion,
            chunkerVersion: "2")
        do {
            _ = try await router.prepareEmbedding(identity: wrongDims)
            XCTFail("wrong dims prepared")
        } catch { XCTAssertEqual(benchmarkErrorCode(error), "profileIdentityMismatch") }
        XCTAssertEqual(BenchmarkURLProtocol.requests.count, 0, "identity checks precede the network")
    }
}

private final class FixedBenchmarkSelection: ProviderSelectionReading, @unchecked Sendable {
    func chatSelection() -> (providerId: String, model: String) { (ProviderConfig.ollamaId, "llama3.2:3b") }
    func embeddingSelection() -> (providerId: String, model: String) { (ProviderConfig.ollamaId, "nomic-embed-text") }
}
