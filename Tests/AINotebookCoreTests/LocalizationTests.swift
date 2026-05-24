import XCTest
@testable import AINotebookCore

final class LocalizationTests: XCTestCase {
    func testEveryKeyHasEnglishString() {
        let text = AppText(language: .english)
        for key in AppText.Key.allCases {
            let value = text.string(key)
            XCTAssertFalse(value.isEmpty, "English string missing for \(key)")
        }
    }

    func testEveryKeyHasCzechString() {
        let text = AppText(language: .czech)
        for key in AppText.Key.allCases {
            let value = text.string(key)
            XCTAssertFalse(value.isEmpty, "Czech string missing for \(key)")
        }
    }

    func testEnglishAndCzechDiffer() {
        let en = AppText(language: .english)
        let cs = AppText(language: .czech)
        // At least one key must actually differ — guards against accidentally
        // leaving Czech as a copy of English.
        let differs = AppText.Key.allCases.contains { key in
            en.string(key) != cs.string(key)
        }
        XCTAssertTrue(differs, "Czech strings appear identical to English")
    }

    func testKnownStringsExact() {
        let en = AppText(language: .english)
        XCTAssertEqual(en.string(.settings), "Settings")
        XCTAssertEqual(en.string(.notebooks), "Notebooks")
        XCTAssertEqual(en.string(.create), "Create")
        XCTAssertEqual(en.string(.cancel), "Cancel")
        XCTAssertEqual(en.string(.delete), "Delete")
        XCTAssertEqual(en.string(.welcome), "Welcome")
        XCTAssertEqual(en.string(.openOllamaDownload), "Open download page")

        let cs = AppText(language: .czech)
        XCTAssertEqual(cs.string(.settings), "Nastavení")
        XCTAssertEqual(cs.string(.notebooks), "Poznámkové bloky")
        XCTAssertEqual(cs.string(.create), "Vytvořit")
        XCTAssertEqual(cs.string(.welcome), "Vítejte")
        XCTAssertEqual(cs.string(.openOllamaDownload), "Otevřít stránku ke stažení")
    }

    func testAddSourceButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.addSourceButton), "Add source")
        XCTAssertEqual(AppText(language: .czech).string(.addSourceButton),   "Přidat zdroj")
    }

    func testSourceStatusReadyIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.sourceStatusReady), "Ready")
        XCTAssertEqual(AppText(language: .czech).string(.sourceStatusReady),   "Hotovo")
    }

    func testIndexingCompleteIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.indexingComplete), "Indexed")
        XCTAssertEqual(AppText(language: .czech)  .string(.indexingComplete), "Indexováno")
    }

    func testChatSendButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.chatSendButton), "Send")
        XCTAssertEqual(AppText(language: .czech)  .string(.chatSendButton), "Odeslat")
    }

    func testNotesNewButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.notesNewButton), "New note")
        XCTAssertEqual(AppText(language: .czech)  .string(.notesNewButton), "Nová poznámka")
    }

    func testTransformationRunButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.transformationRunButton), "Run")
        XCTAssertEqual(AppText(language: .czech)  .string(.transformationRunButton), "Spustit")
    }

    func testTransformationEditorNewIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.transformationEditorNew), "New")
        XCTAssertEqual(AppText(language: .czech)  .string(.transformationEditorNew), "Nový")
    }

    func testChatNewSessionButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.chatNewSessionButton), "New session")
        XCTAssertEqual(AppText(language: .czech)  .string(.chatNewSessionButton), "Nová konverzace")
    }

    func testChatSaveAsNoteIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.chatSaveAsNoteButton), "Save as note")
        XCTAssertEqual(AppText(language: .czech)  .string(.chatSaveAsNoteButton), "Uložit jako poznámku")
    }

    func testReembedButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.reembedButton), "Re-embed all sources")
        XCTAssertEqual(AppText(language: .czech)  .string(.reembedButton), "Přeindexovat všechny zdroje")
    }

    func testManageModelsButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.manageModelsButton), "Manage models…")
        XCTAssertEqual(AppText(language: .czech)  .string(.manageModelsButton), "Spravovat modely…")
    }
}
