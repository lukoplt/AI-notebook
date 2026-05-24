import XCTest
@testable import AINotebookCore

final class WebExtractorTests: XCTestCase {

    func testExtractsArticleBodyAndTitleFromHTML() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "html", subdirectory: "Fixtures")
        )
        let html = try String(contentsOf: url, encoding: .utf8)
        let extracted = try WebExtractor.parseHTML(html, sourceURL: URL(string: "https://example.com/a")!)
        XCTAssertEqual(extracted.title, "Sample Article")
        XCTAssertTrue(extracted.text.contains("main article body"))
        XCTAssertTrue(extracted.text.contains("Another paragraph"))
        XCTAssertFalse(extracted.text.contains("never extract me"))
        XCTAssertFalse(extracted.text.contains("Site nav"))
        XCTAssertFalse(extracted.text.contains("Copyright"))
    }

    func testParseHTMLThrowsOnEmptyBody() {
        let html = "<html><head><title>T</title></head><body></body></html>"
        do {
            _ = try WebExtractor.parseHTML(html, sourceURL: URL(string: "https://example.com")!)
            XCTFail("expected throw")
        } catch ExtractorError.emptyContent {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
