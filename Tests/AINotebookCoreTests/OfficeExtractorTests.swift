import XCTest
@testable import AINotebookCore

final class OfficeExtractorTests: XCTestCase {

    private let marker = "M3 OFFICE TEST DOCUMENT BODY"

    func testExtractsDocxBodyText() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "docx", subdirectory: "Fixtures"))
        let extracted = try await OfficeExtractor().extract(from: url, kind: .docx)
        XCTAssertTrue(extracted.text.contains(marker), "got: \(extracted.text)")
        XCTAssertFalse(extracted.text.isEmpty)
    }

    func testExtractsPptxSlideText() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "pptx", subdirectory: "Fixtures"))
        let extracted = try await OfficeExtractor().extract(from: url, kind: .pptx)
        XCTAssertTrue(extracted.text.contains(marker))
    }

    func testExtractsXlsxSharedStrings() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "xlsx", subdirectory: "Fixtures"))
        let extracted = try await OfficeExtractor().extract(from: url, kind: .xlsx)
        XCTAssertTrue(extracted.text.contains(marker))
    }

    func testCorruptArchiveThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake.docx")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await OfficeExtractor().extract(from: url, kind: .docx)
            XCTFail("expected throw")
        } catch ExtractorError.officeArchiveCorrupt {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
