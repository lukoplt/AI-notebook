import XCTest
@testable import AINotebookCore

/// WP6 folder ingestion embeds through the WP5/WP7 `ProviderEmbeddingSession`:
/// one endpoint identity, one format-version policy, one document/query path.
final class FolderEmbeddingSessionTests: XCTestCase {
    actor RecordingTransport: StrictEmbeddingTransport {
        var inputs: [String] = []
        func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult {
            inputs.append(input)
            return StrictEmbeddingResult(vector: [3, 4], promptTokens: input.unicodeScalars.count,
                                         totalDurationNs: 1, loadDurationNs: 0)
        }
    }

    private let profile = EmbeddingProfile(id: "fixture", model: "fixture-model", tokenizerId: "fixture-only",
                                           queryPrefix: "q: ", documentPrefix: "d: ", nativeDims: 2, dims: 2,
                                           maxInputTokens: 64, matryoshka: false, ceilingSource: "model-card")

    func testRawCaptureUsesTheSharedEndpointIdentityAndProviderSession() throws {
        let config = ProviderConfig(id: "local", type: .ollama, name: "Local", baseURL: "http://localhost:11434/")
        let folder = try FolderEmbeddingSession(config: config, model: "embed-a", apiKey: nil, modelDigest: nil,
                                                queryFormatVersion: "1", docFormatVersion: "1")
        let root = try ProviderAPIRoot.normalize(config.baseURL)
        XCTAssertEqual(folder.selection.endpointRevision, EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: root))
        XCTAssertEqual(folder.provider.endpointRevision, folder.selection.endpointRevision)
        XCTAssertEqual(folder.provider.storageKey, "local:embed-a")
        XCTAssertNil(folder.provider.profile, "format 1 is the raw-input path")
    }

    func testRawCaptureRejectsFormatsTheSharedPolicyDoesNotSupport() {
        let config = ProviderConfig.builtInOllama()
        // embedding-raw-format-v2: "2" is a raw format, but query and document formats must agree.
        for (query, doc) in [(profile.formatVersion(.query), profile.formatVersion(.document)), ("2", "1"), ("1", "2"), ("3", "3")] {
            XCTAssertThrowsError(try FolderEmbeddingSession(config: config, model: "m", apiKey: nil, modelDigest: nil,
                                                            queryFormatVersion: query, docFormatVersion: doc)) {
                XCTAssertEqual($0 as? RetrievalError, .unsupportedQueryFormat, "\(query)/\(doc)")
            }
        }
        XCTAssertThrowsError(try FolderEmbeddingSession(config: config, model: "m", apiKey: nil, modelDigest: nil,
                                                        queryFormatVersion: " ", docFormatVersion: "1")) {
            XCTAssertEqual(($0 as? IngestionError)?.code, "invalidValue")
        }
    }

    func testProfileSessionEmbedsDocumentsWithTheDocumentPrefix() async throws {
        let identity = GenerationIdentity(providerId: "local", endpointRevision: "rev", model: profile.model,
                                          modelDigest: "sha256:abc", dims: 2, normalization: "l2",
                                          queryFormatVersion: profile.formatVersion(.query),
                                          docFormatVersion: profile.formatVersion(.document), chunkerVersion: "2")
        let transport = RecordingTransport()
        let provider = ProviderEmbeddingSession(storageKey: "local:" + profile.model, endpointRevision: "rev",
                                                identity: identity, profile: profile,
                                                pipeline: StrictEmbeddingPipeline(transport: transport),
                                                effectiveLimit: profile.maxInputTokens)
        let folder = try FolderEmbeddingSession(profileSession: provider)
        XCTAssertEqual(folder.selection, EmbeddingSelection(identity: identity))
        let vectors = try await folder.embed(inputs: ["abc"])
        XCTAssertEqual(vectors, [[0.6, 0.8]])
        let sent = await transport.inputs
        XCTAssertEqual(sent, ["d: abc"])
        XCTAssertEqual(try folder.identity(dims: 2), identity)
        XCTAssertThrowsError(try folder.identity(dims: 3))
    }

    func testOnlyProfileSessionsAdaptDirectly() throws {
        let raw = ProviderEmbeddingSession(client: OllamaClient(baseURL: URL(string: "http://localhost:11434")!),
                                           model: "m", storageKey: "local:m", endpointRevision: "rev")
        XCTAssertThrowsError(try FolderEmbeddingSession(profileSession: raw)) {
            XCTAssertEqual(($0 as? EmbeddingProfileError)?.code, "unsupportedEmbeddingProfile")
        }
    }
}
