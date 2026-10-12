import Foundation
import XCTest
@testable import AINotebookCore

final class ProviderLimitPolicyTests: XCTestCase {
    /// provider-listing-limits-v1: windows advertised by OpenWebUI / OpenAI-compatible listings.
    func testSharedListingLimits() throws {
        let fixture = try SharedFixtures.json("contracts/provider-listing-limits-v1.json")
        XCTAssertEqual((fixture["listedRuntimeCap"] as? NSNumber)?.intValue, ProviderLimitPolicy.listedRuntimeCap)
        XCTAssertEqual(Set((fixture["listingTypes"] as! [String]).map { ProviderType(rawValue: $0)! }), ProviderLimitPolicy.listingTypes)
        XCTAssertEqual(fixture["keyPaths"] as? [[String]], ProviderLimitPolicy.listingKeyPaths)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 19)
        for c in cases {
            let name = c["name"] as! String
            let type = ProviderType(rawValue: c["type"] as! String)!
            let model = c["model"] as! String
            let data = Data((c["listing"] as! String).utf8)
            let expected = c["expected"] as! [String: Any]
            var window: Int?
            if expected["error"] != nil {
                XCTAssertThrowsError(try ProviderLimitPolicy.contextWindow(fromModelListing: data, model: model), name)
            } else if ProviderLimitPolicy.listingTypes.contains(type) {
                window = try ProviderLimitPolicy.contextWindow(fromModelListing: data, model: model)
                XCTAssertEqual(window, expected["window"] as? Int, name)
            }
            let limits = try ProviderLimitPolicy.automatic(providerId: "p", type: type, model: model,
                                                           contextWindow: window, listed: true)
            let row = expected["limits"] as! [String: Any]
            XCTAssertEqual(limits.contextWindow, row["contextWindow"] as? Int, name)
            XCTAssertEqual(limits.runtimeContext, row["runtimeContext"] as? Int, name)
            XCTAssertEqual(limits.maxOutputTokens, row["maxOutputTokens"] as? Int, name)
            XCTAssertEqual(limits.source, row["source"] as? String, name)
            XCTAssertEqual(limits.isAssumed, row["isAssumed"] as? Bool, name)
            XCTAssertNoThrow(try limits.validate(), name)
        }
        // Unlisted windows keep the frozen rule: advertised context never raises the runtime.
        XCTAssertEqual(try ProviderLimitPolicy.automatic(providerId: "p", type: .ollama, model: "m",
                                                         contextWindow: 32_768, listed: true).runtimeContext, 8_192)
        XCTAssertEqual(try ProviderLimitPolicy.automatic(providerId: "p", type: .openwebui, model: "m",
                                                         contextWindow: 131_072).runtimeContext, 8_192)
    }

    func testSharedLimits() throws {
        let cases = try SharedFixtures.json("contracts/provider-limits-v1.json")["cases"] as! [[String: Any]]
        for c in cases {
            let name = c["name"] as! String
            let window = c["window"] as? Int
            if let user = c["user"] as? [String: Int] {
                let value = ProviderModelLimits(providerId: "p", model: c["model"] as! String,
                    contextWindow: window, runtimeContext: user["runtimeContext"]!,
                    maxOutputTokens: user["maxOutputTokens"]!, source: "user")
                XCTAssertThrowsError(try value.validate(), name) {
                    XCTAssertEqual(($0 as? ProviderConfigurationError)?.rawValue, c["expectedError"] as? String, name)
                }
                continue
            }
            if let show = c["show"] {
                let data = try JSONSerialization.data(withJSONObject: show)
                XCTAssertEqual(try ProviderLimitPolicy.contextWindow(fromOllamaShow: data), window, name)
            }
            let value = try ProviderLimitPolicy.automatic(providerId: "p",
                type: ProviderType(rawValue: c["type"] as! String)!, model: c["model"] as! String,
                contextWindow: window)
            let expected = c["expected"] as! [String: Any]
            XCTAssertEqual(value.providerId, "p", name)
            XCTAssertEqual(value.model, c["model"] as? String, name)
            XCTAssertEqual(value.contextWindow, expected["contextWindow"] as? Int, name)
            XCTAssertEqual(value.runtimeContext, expected["runtimeContext"] as? Int, name)
            XCTAssertEqual(value.maxOutputTokens, expected["maxOutputTokens"] as? Int, name)
            XCTAssertEqual(value.source, expected["source"] as? String, name)
            XCTAssertEqual(value.isAssumed, expected["isAssumed"] as? Bool, name)
            XCTAssertEqual(value.options, ChatRequestOptions(runtimeContext: value.runtimeContext,
                                                            maxOutputTokens: value.maxOutputTokens), name)
            XCTAssertNoThrow(try value.validate(), name)
        }
    }

    func testPresets() throws {
        let rows = try SharedFixtures.json("contracts/provider-presets-v1.json")["cases"] as! [[String: String]]
        XCTAssertEqual(ProviderPresets.all.count, rows.count)
        for (preset, row) in zip(ProviderPresets.all, rows) {
            XCTAssertEqual(preset.id, row["name"])
            XCTAssertEqual(preset.name, row["label"])
            XCTAssertEqual(preset.baseURL, row["baseURL"])
            XCTAssertEqual(preset.helpKey, row["helpKey"])
        }
    }

    func testCodablePreservesRawIdentityAndNullableCeiling() throws {
        let fixture = (try SharedFixtures.json("contracts/provider-store-v1.json")["cases"] as! [[String: Any]])
            .first { $0["name"] as? String == "user-survives-auto" }!
        for window in [nil, fixture["contextWindow"] as? Int] {
            let value = ProviderModelLimits(providerId: fixture["providerId"] as! String,
                model: fixture["model"] as! String, contextWindow: window,
                runtimeContext: fixture["runtimeContext"] as! Int,
                maxOutputTokens: fixture["maxOutputTokens"] as! Int, source: "user")
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(ProviderModelLimits.self, from: encoded), value)
            XCTAssertFalse(value.isAssumed)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(fields["model"] as? String, fixture["model"] as? String)
            XCTAssertTrue(Set(fields.keys).isSubset(of: ["providerId", "model", "contextWindow", "runtimeContext", "maxOutputTokens", "source"]))
        }
    }

    func testInvalidIdentityAndSource() {
        for (id, model, source) in [("", "m", "auto"), ("p", " \n", "user"), ("p", "m", "other")] {
            let value = ProviderModelLimits(providerId: id, model: model, contextWindow: nil,
                runtimeContext: 8192, maxOutputTokens: 1024, source: source)
            XCTAssertThrowsError(try value.validate()) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .invalidLimits)
            }
        }
    }

    func testAutomaticRejectsUnusableWindowAndHonorsSuppliedCeiling() throws {
        for window in [Int.min, -1, 0, 1] {
            XCTAssertThrowsError(try ProviderLimitPolicy.automatic(providerId: "p", type: .ollama,
                model: "m", contextWindow: window)) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .invalidLimits)
            }
        }
        let value = try ProviderLimitPolicy.automatic(providerId: "p", type: .openai,
            model: "gpt-4o-mini", contextWindow: 4096)
        XCTAssertEqual(value.contextWindow, 4096)
        XCTAssertEqual(value.runtimeContext, 4096)
    }

    func testShowMalformedJSONThrowsAndInvalidMetadataIsUnknown() throws {
        XCTAssertThrowsError(try ProviderLimitPolicy.contextWindow(fromOllamaShow: Data("{".utf8)))
        for json in ["{}", "[]", "null", "{\"model_info\":null}",
                     "{\"model_info\":{\"general.architecture\":1,\"1.context_length\":8192}}",
                     "{\"model_info\":{\"general.architecture\":\"llama\",\"llama.context_length\":\"8192\"}}"] {
            XCTAssertNil(try ProviderLimitPolicy.contextWindow(fromOllamaShow: Data(json.utf8)), json)
        }
    }
}
