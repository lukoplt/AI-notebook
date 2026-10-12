import XCTest
@testable import AINotebookCore

/// WP8 Task 10: the exact EN/CS strings of the plan's UI localization table.
final class ContextPackLocalizationTests: XCTestCase {
    private let table: [(AppText.Key, String, String)] = [
            (.chatOverviewToggle, "Overview", "Přehled"),
            (.contextPreviewBeforeSend, "Show what will be sent", "Zobrazit, co se pošle"),
            (.contextPreviewSent, "Show sent context", "Zobrazit odeslaný kontext"),
            (.contextPreviewTitle, "Context preview", "Náhled kontextu"),
            (.contextPreviewPreparing, "Preparing context…", "Připravuji kontext…"),
            (.contextPreviewUnavailable, "This context preview is no longer in memory.", "Tento náhled kontextu už není v paměti."),
            (.contextPreviewEstimatedTokens, "Estimated tokens", "Odhad tokenů"),
            (.contextPreviewAssumedLimit, "Context size assumed by the app", "Velikost kontextu předpokládaná aplikací"),
            (.contextPreviewMessages, "Logical messages", "Logické zprávy"),
            (.contextPreviewWireOrder, "Sent message order", "Pořadí odeslaných zpráv"),
            (.contextPreviewOptions, "Request options", "Nastavení požadavku"),
            (.contextPreviewIncluded, "Included content", "Zahrnutý obsah"),
            (.contextPreviewOmitted, "Omitted content", "Vynechaný obsah"),
            (.contextPreviewCoverage, "Scope and turn coverage", "Pokrytí rozsahu a dotazu"),
            (.contextPreviewRecalculate, "Recalculate preview", "Přepočítat náhled"),
            (.contextPreviewClose, "Close preview", "Zavřít náhled"),
            (.contextTooSmall, "Context is too small. Increase its size or shorten the instructions.", "Kontext je příliš malý. Zvětšete ho nebo zkraťte instrukce."),
            (.citationOpenOriginal, "Open original", "Otevřít originál"),
            (.citationRevisionChanged, "The original has changed since this answer.", "Originál se od této odpovědi změnil."),
            (.citationOriginalUnavailable, "The original is unavailable.", "Originál není dostupný."),
            (.citationOriginalOutsideFolder, "The original is outside the selected folder.", "Originál je mimo vybranou složku."),
            (.contextOmittedEvidenceBudget, "Evidence budget exhausted", "Vyčerpán rozpočet důkazů"),
            (.contextOmittedTopK, "Passage limit reached", "Dosažen limit pasáží"),
            (.contextOmittedHistoryBudget, "Complete conversation turn did not fit", "Celý tah konverzace se nevešel"),
            (.contextOmittedMapBudget, "Map budget exhausted", "Vyčerpán rozpočet mapy"),
            (.contextOmittedExternalBudget, "Additional context did not fit", "Doplňující kontext se nevešel"),
            (.contextOmittedTruncated, "Excerpt shortened at a sentence boundary", "Úryvek zkrácen na hranici věty"),
            (.contextOmittedDuplicate, "Duplicate excerpt", "Duplicitní úryvek"),
            (.contextOmittedRevisionMismatch, "Different document revision", "Jiná revize dokumentu"),
            (.contextOmittedNeighbourBudget, "Neighbouring excerpt did not fit", "Sousední úryvek se nevešel"),
            (.contextOmittedLegacyNoSpan, "Legacy excerpt has no position data", "Starší úryvek nemá údaje o pozici"),
            (.contextOmittedEmptySelection, "No sources selected", "Nejsou vybrány žádné zdroje"),
    ]

    func testContextPackLabelsAreBilingual() {
        let en = AppText(language: .english), cs = AppText(language: .czech)
        XCTAssertEqual(en.string(.chatOverviewToggle), "Overview")
        XCTAssertEqual(cs.string(.chatOverviewToggle), "Přehled")
        XCTAssertEqual(en.string(.contextPreviewBeforeSend), "Show what will be sent")
        XCTAssertEqual(cs.string(.contextPreviewBeforeSend), "Zobrazit, co se pošle")
        XCTAssertEqual(en.string(.citationOpenOriginal), "Open original")
        XCTAssertEqual(cs.string(.citationOpenOriginal), "Otevřít originál")
        XCTAssertEqual(en.string(.contextOmittedTruncated), "Excerpt shortened at a sentence boundary")
        XCTAssertEqual(cs.string(.contextOmittedTruncated), "Úryvek zkrácen na hranici věty")
        XCTAssertEqual(table.count, 32)
        XCTAssertEqual(Set(table.map { String(describing: $0.0) }).count, 32)
        for (key, english, czech) in table {
            XCTAssertEqual(en.string(key), english, "\(key)")
            XCTAssertEqual(cs.string(key), czech, "\(key)")
        }
    }

    /// The 11 omission reasons map to the schema's reason codes in table order.
    func testOmissionReasonsCoverEverySchemaCode() {
        let codes = ["evidenceBudget", "topK", "historyBudget", "mapBudget", "externalBudget", "truncated",
                     "duplicate", "revisionMismatch", "neighbourBudget", "legacyNoSpan", "emptySelection"]
        let en = AppText(language: .english)
        XCTAssertEqual(codes.map { AppText.omissionReasonKey($0) }, Array(table.suffix(11).map(\.0)))
        XCTAssertNil(AppText.omissionReasonKey("unknown"))
        XCTAssertEqual(en.omissionReason("topK"), "Passage limit reached")
        XCTAssertEqual(en.omissionReason("somethingNew"), "somethingNew")
    }
}
