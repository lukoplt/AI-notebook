import XCTest
@testable import AINotebookCore

final class ProviderTypeTests: XCTestCase {

    func testStorageStringsRoundTrip() {
        XCTAssertEqual(ProviderType.ollama.rawValue, "ollama")
        XCTAssertEqual(ProviderType.anthropic.rawValue, "anthropic")
        XCTAssertEqual(ProviderType.openai.rawValue, "openai")
        XCTAssertEqual(ProviderType.openaiCompatible.rawValue, "openai_compatible")
        XCTAssertEqual(ProviderType.openwebui.rawValue, "openwebui")
        for t in ProviderType.allCases {
            XCTAssertEqual(ProviderType.fromStorage(t.rawValue), t)
        }
    }

    func testUnknownStorageStringFallsBackToOpenAICompatible() {
        XCTAssertEqual(ProviderType.fromStorage("something_new"), .openaiCompatible)
    }

    func testDefaultBaseURLs() {
        XCTAssertEqual(ProviderType.ollama.defaultBaseURL, "http://127.0.0.1:11434")
        XCTAssertEqual(ProviderType.anthropic.defaultBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(ProviderType.openai.defaultBaseURL, "https://api.openai.com")
        XCTAssertEqual(ProviderType.openaiCompatible.defaultBaseURL, "")
        XCTAssertEqual(ProviderType.openwebui.defaultBaseURL, "")
    }

    func testEmbeddingSupport() {
        XCTAssertTrue(ProviderType.ollama.supportsEmbeddings)
        XCTAssertTrue(ProviderType.openai.supportsEmbeddings)
        XCTAssertTrue(ProviderType.openaiCompatible.supportsEmbeddings)
        XCTAssertFalse(ProviderType.anthropic.supportsEmbeddings)
        XCTAssertFalse(ProviderType.openwebui.supportsEmbeddings)
    }

    func testCloudFlagCoversEverythingButOllama() {
        XCTAssertFalse(ProviderType.ollama.isCloud)
        for t in ProviderType.allCases where t != .ollama {
            XCTAssertTrue(t.isCloud, "\(t) must be privacy-gated")
        }
    }

    func testBuiltInOllamaConfig() {
        let cfg = ProviderConfig.builtInOllama()
        XCTAssertEqual(cfg.id, ProviderConfig.ollamaId)
        XCTAssertEqual(ProviderConfig.ollamaId, "00000000-0000-0000-0000-000000000000")
        XCTAssertTrue(cfg.isBuiltInOllama)
        XCTAssertEqual(cfg.type, .ollama)
        XCTAssertTrue(cfg.privacyAcknowledged)
    }

    func testModelInfoLabelFallsBackToId() {
        XCTAssertEqual(ProviderModelInfo(id: "gpt-4o").label, "gpt-4o")
        XCTAssertEqual(ProviderModelInfo(id: "x", displayName: "Nice Name").label, "Nice Name")
        XCTAssertEqual(ProviderModelInfo(id: "x", displayName: "").label, "x")
    }
}
