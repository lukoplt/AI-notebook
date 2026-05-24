import XCTest
@testable import AINotebookCore

final class SourceTypeTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(SourceType.pdf.rawValue, "pdf")
        XCTAssertEqual(SourceType.text.rawValue, "text")
        XCTAssertEqual(SourceType.markdown.rawValue, "markdown")
        XCTAssertEqual(SourceType.web.rawValue, "web")
        XCTAssertEqual(SourceType.docx.rawValue, "docx")
        XCTAssertEqual(SourceType.pptx.rawValue, "pptx")
        XCTAssertEqual(SourceType.xlsx.rawValue, "xlsx")
    }

    func testDetectFromFilenameMatchesExtension() {
        XCTAssertEqual(SourceType.detect(filename: "doc.pdf"), .pdf)
        XCTAssertEqual(SourceType.detect(filename: "Notes.MD"), .markdown)
        XCTAssertEqual(SourceType.detect(filename: "plain.txt"), .text)
        XCTAssertEqual(SourceType.detect(filename: "deck.pptx"), .pptx)
        XCTAssertEqual(SourceType.detect(filename: "sheet.xlsx"), .xlsx)
        XCTAssertEqual(SourceType.detect(filename: "memo.docx"), .docx)
    }

    func testDetectReturnsNilForUnknown() {
        XCTAssertNil(SourceType.detect(filename: "image.png"))
        XCTAssertNil(SourceType.detect(filename: "noextension"))
    }
}
