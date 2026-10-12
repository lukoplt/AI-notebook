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
        XCTAssertEqual(cs.string(.notebooks), "Notebooky")
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

    func testOpenNoteFromCitationBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.openNoteFromCitation), "Open note")
        XCTAssertEqual(AppText(language: .czech)  .string(.openNoteFromCitation), "Otevřít poznámku")
    }

    func testEditorStatusSavedIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.editorStatusSaved), "Saved")
        XCTAssertEqual(AppText(language: .czech)  .string(.editorStatusSaved), "Uloženo")
    }

    func testAttachmentOpenButtonBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.attachmentOpenButton), "Open")
        XCTAssertEqual(AppText(language: .czech)  .string(.attachmentOpenButton), "Otevřít")
    }

    func testHistoryRestoreButtonBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.historyRestoreButton), "Restore this version")
        XCTAssertEqual(AppText(language: .czech)  .string(.historyRestoreButton), "Obnovit tuto verzi")
    }

    func testAiToolsSectionTitleBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.aiToolsSectionTitle), "AI tools")
        XCTAssertEqual(AppText(language: .czech)  .string(.aiToolsSectionTitle), "AI nástroje")
    }

    func testProviderSectionKeysAreBilingual() {
        let en = AppText(language: .english)
        let cs = AppText(language: .czech)
        XCTAssertEqual(en.string(.providersSectionTitle), "AI providers")
        XCTAssertEqual(cs.string(.providersSectionTitle), "AI provideři")
        XCTAssertEqual(en.string(.addProviderButton), "Add provider…")
        XCTAssertEqual(cs.string(.addProviderButton), "Přidat providera…")
        XCTAssertEqual(en.string(.providerTestButton), "Test connection")
        XCTAssertEqual(cs.string(.providerTestButton), "Otestovat připojení")
        XCTAssertEqual(en.string(.privacyGateTitle), "Send data to this provider?")
        XCTAssertEqual(cs.string(.privacyGateTitle), "Odesílat data tomuto providerovi?")
        XCTAssertEqual(en.string(.errorInvalidApiKey), "Invalid API key")
        XCTAssertEqual(cs.string(.errorInvalidApiKey), "Neplatný API klíč")
        XCTAssertEqual(en.string(.errorConsentRequired), "Provider not enabled — confirm data sharing in Settings")
        XCTAssertEqual(cs.string(.errorConsentRequired), "Provider není povolen — potvrďte sdílení dat v Nastavení")
        XCTAssertEqual(en.string(.doneButton), "Done")
        XCTAssertEqual(cs.string(.doneButton), "Hotovo")
    }

    func testUpdateKeysAreBilingual() {
        let en = AppText(language: .english)
        let cs = AppText(language: .czech)
        XCTAssertEqual(en.string(.updateBannerTitle), "A new version (%@) is available.")
        XCTAssertEqual(cs.string(.updateBannerTitle), "Je k dispozici nová verze (%@).")
        XCTAssertEqual(en.string(.updateDownloadButton), "Download")
        XCTAssertEqual(cs.string(.updateDownloadButton), "Stáhnout")
        XCTAssertEqual(en.string(.updateLaterButton), "Later")
        XCTAssertEqual(cs.string(.updateLaterButton), "Později")
        XCTAssertEqual(en.string(.updateStatusFailed), "Couldn't check for updates.")
        XCTAssertEqual(cs.string(.updateStatusFailed), "Kontrola aktualizací se nezdařila.")
    }

    // MARK: UI redesign (Codex-style shell)

    func testRedesignShellStringsAreBilingual() {
        let en = AppText(language: .english), cs = AppText(language: .czech)
        XCTAssertEqual(en.string(.shellNewChat), "New chat")
        XCTAssertEqual(cs.string(.shellNewChat), "Nový chat")
        XCTAssertEqual(en.string(.chatEmptyTitle), "What are we working on?")
        XCTAssertEqual(cs.string(.chatEmptyTitle), "Na čem pracujeme?")
        XCTAssertEqual(cs.string(.composerPlaceholder), "Zeptej se na cokoliv v notebooku…")
        XCTAssertEqual(cs.string(.shellEmptyAppTitle), "Začni přidáním složky nebo vytvořením notebooku")
        XCTAssertEqual(cs.string(.panelNoteChat), "Chat k poznámce")
        XCTAssertEqual(cs.string(.toolHistory), "Historie nástrojů")
        XCTAssertEqual(cs.string(.settingsAbout), "O aplikaci")
        XCTAssertEqual(en.string(.documentExportPDF), "Export as PDF…")
    }

    func testRedesignFormatStringsKeepTheirPlaceholders() {
        for language in [AppLanguage.english, .czech] {
            let t = AppText(language: language)
            XCTAssertTrue(t.string(.shellShowMore).contains("%d"), "\(language)")
            XCTAssertTrue(t.string(.folderSummaryErrors).contains("%d"), "\(language)")
            XCTAssertTrue(t.string(.folderSummaryFiles).contains("%@"), "\(language)")
            XCTAssertTrue(t.string(.citationPage).contains("%@"), "\(language)")
            XCTAssertTrue(t.string(.chatReplyNoteTitle).contains("%@"), "\(language)")
        }
        XCTAssertEqual(String(format: AppText(language: .czech).string(.citationPage), "3–4"), "s. 3–4")
        XCTAssertEqual(String(format: AppText(language: .english).string(.shellShowMore), 2), "Show more (2)")
    }
    /// UI redesign C1: Czech UI says "notebook" (declined), never "blok", on both
    /// platforms (Windows: LocalizedStringsTests.Czech_text_says_notebook_not_blok).
    func testCzechTextSaysNotebookNotBlok() throws {
        let blok = try NSRegularExpression(pattern: #"\b(poznámkov\w* )?blok(u|y|ů|em|ům|ích|ách)?\b"#,
                                           options: [.caseInsensitive])
        let cs = AppText(language: .czech)
        for key in AppText.Key.allCases {
            let value = cs.string(key)
            let range = NSRange(value.startIndex..., in: value)
            XCTAssertNil(blok.firstMatch(in: value, range: range), "\(key): \(value)")
        }
        XCTAssertEqual(cs.string(.createNotebook), "Vytvořit notebook")
        XCTAssertEqual(cs.string(.notebookName), "Název notebooku")
    }
}
