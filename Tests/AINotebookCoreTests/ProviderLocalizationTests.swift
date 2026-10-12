import XCTest
import Foundation
@testable import AINotebookCore

final class ProviderLocalizationTests: XCTestCase {
    func testWP2ProviderKeysMatchWindowsResourcesInBothDirections() throws {
        // The contiguous WP2 key block includes the conversion notice and all
        // five safe error categories. Check values as well as presence so the
        // two platforms cannot silently acquire different user-facing meaning.
        let allKeys = AppText.Key.allCases
        let start = try XCTUnwrap(allKeys.firstIndex(of: .providerPresetLabel))
        let end = try XCTUnwrap(allKeys.firstIndex(of: .providerEndpointUnsupported))
        let keys = Array(allKeys[start...end])
        XCTAssertEqual(keys.count, 27)
        let repository = SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent()
        for (locale, language) in [("en-US", AppLanguage.english), ("cs-CZ", AppLanguage.czech)] {
            let resource = repository.appendingPathComponent("windows/src/AINotebook.App/Strings/\(locale)/Resources.resw")
            let document = try XMLDocument(contentsOf: resource)
            let entries = try document.nodes(forXPath: "/root/data")
                .compactMap { $0 as? XMLElement }
            let wp2Entries = Array(entries.drop { $0.attribute(forName: "name")?.stringValue != "providerPresetLabel" })
            let names = try wp2Entries.map { try XCTUnwrap($0.attribute(forName: "name")?.stringValue) }
            XCTAssertEqual(Set(names), Set(keys.map { String(describing: $0) }), locale)
            let text = AppText(language: language)
            for key in keys {
                let entry = try XCTUnwrap(wp2Entries.first { $0.attribute(forName: "name")?.stringValue == String(describing: key) })
                XCTAssertEqual(entry.elements(forName: "value").first?.stringValue, text.string(key), "\(locale): \(key)")
            }
        }
    }

    func testProviderFailuresUseLocalizedSafeText() {
        let rows: [(AppText.Key, String, String)] = [
            (.providerConnectionFailed, "The provider could not be reached.", "K poskytovateli se nepodařilo připojit."),
            (.providerResponseInvalid, "The provider returned an unexpected response.", "Poskytovatel vrátil neočekávanou odpověď."),
            (.providerRequestFailed, "The provider request failed.", "Požadavek poskytovateli selhal."),
            (.providerSelectionUnavailable, "Select an enabled provider in Settings.", "V Nastavení vyberte povoleného poskytovatele."),
            (.providerEndpointUnsupported, "This provider does not support the requested operation.", "Tento poskytovatel nepodporuje požadovanou operaci.")
        ]
        for (key, english, czech) in rows {
            XCTAssertEqual(AppText(language: .english).string(key), english)
            XCTAssertEqual(AppText(language: .czech).string(key), czech)
        }
    }

    func testNewProviderTextInBothLanguages() {
        let rows: [(AppText.Key, String, String)] = [
            (.providerPresetLabel, "Preset", "Předvolba"),
            (.providerPresetCustom, "Custom", "Vlastní"),
            (.providerPresetLocalHelp, "Start the local server, then check its API root. An API key is optional.", "Spusťte místní server a ověřte kořen API. Klíč API je volitelný."),
            (.providerPresetRemoteHelp, "Enter your API key and check the API root.", "Zadejte klíč API a ověřte kořen API."),
            (.providerPresetCustomHelp, "Enter the exact API root, including any version or proxy path.", "Zadejte přesný kořen API včetně verze a cesty proxy."),
            (.providerRefreshModels, "Refresh models", "Obnovit modely"),
            (.providerManualModelId, "Model ID", "ID modelu"),
            (.providerApplyModel, "Apply model ID", "Použít ID modelu"),
            (.providerListingVerified, "Model listing verified. Generation has not been tested.", "Seznam modelů byl ověřen. Generování nebylo testováno."),
            (.providerListingUnsupported, "Model listing is unavailable; generation has not been verified. Enter a model ID manually.", "Seznam modelů není dostupný; generování nebylo ověřeno. Zadejte ID modelu ručně."),
            (.providerRuntimeContext, "Runtime context", "Použitý kontext"),
            (.providerMaxOutputTokens, "Maximum output tokens", "Maximum tokenů odpovědi"),
            (.providerContextWindow, "Model context limit", "Limit kontextu modelu"),
            (.providerContextUnknown, "Unknown", "Neznámý"),
            (.providerLimitsAssumption, "Application assumption", "Předpoklad aplikace"),
            (.providerLimitsUserOverride, "User override", "Uživatelské nastavení"),
            (.providerLimitsSave, "Save limits", "Uložit limity"),
            (.providerLimitsReset, "Reset to automatic", "Obnovit automatické nastavení"),
            (.providerLimitsInvalid, "Enter positive whole numbers. Output must be smaller than runtime context, which must not exceed the known model limit.", "Zadejte kladná celá čísla. Maximum odpovědi musí být menší než použitý kontext, který nesmí překročit známý limit modelu."),
            (.providerInvalidRoot, "Enter an HTTP or HTTPS API root without credentials, a query, or a fragment.", "Zadejte kořen API HTTP nebo HTTPS bez přihlašovacích údajů, dotazu a fragmentu."),
            (.providerContextTooLong, "The provider rejected the request length. Reduce runtime context.", "Poskytovatel odmítl délku požadavku. Snižte použitý kontext."),
            (.providerEmbeddingSelectionConverted, "The previous embedding provider supports chat only. Embeddings now use local Ollama (nomic-embed-text).", "Předchozí poskytovatel embeddingů podporuje pouze chat. Embeddingy nyní používají místní Ollamu (nomic-embed-text)."),
        ]
        XCTAssertEqual(rows.count, 22)
        for (key, english, czech) in rows {
            XCTAssertEqual(AppText(language: .english).string(key), english, "English: \(key)")
            XCTAssertEqual(AppText(language: .czech).string(key), czech, "Czech: \(key)")
            XCTAssertTrue(AppText.Key.allCases.contains(key), "Key omitted from enumeration: \(key)")
        }
    }

    func testSharedPresetHelpKeysHaveEnglishAndCzechText() throws {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/provider-presets-v1.json")["cases"] as? [[String: String]])
        let keys: [String: AppText.Key] = [
            "providerPresetLocalHelp": .providerPresetLocalHelp,
            "providerPresetRemoteHelp": .providerPresetRemoteHelp,
            "providerPresetCustomHelp": .providerPresetCustomHelp
        ]
        for row in rows {
            let name = try XCTUnwrap(row["name"])
            let helpKey = try XCTUnwrap(row["helpKey"])
            let key = try XCTUnwrap(keys[helpKey], "Unknown preset help key for \(name): \(helpKey)")
            let preset = try XCTUnwrap(ProviderPresets.all.first { $0.id == name })
            XCTAssertEqual(preset.helpKey, helpKey)
            XCTAssertFalse(AppText(language: .english).string(key).isEmpty, name)
            XCTAssertFalse(AppText(language: .czech).string(key).isEmpty, name)
        }
    }
}
