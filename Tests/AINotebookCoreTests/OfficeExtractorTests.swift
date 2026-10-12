import XCTest
import ZIPFoundation
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

    /// The legacy extractor shares the bounded OOXML reader: the main part comes
    /// from the package relationships (here "/word/document2.xml") and slides
    /// follow presentation order, not file names (slide10 before slide2).
    func testResolvesMainPartAndSlideOrderLikeTheBoundedReader() async throws {
        let docx = try await OfficeExtractor().extract(from: SharedFixtures.url("ingestion/document2.docx"), kind: .docx)
        XCTAssertEqual(docx.text, "Alpha\tBeta\nBefore \nBox\nAfter\nCell")
        XCTAssertEqual(docx.title, "document2")
        let pptx = try await OfficeExtractor().extract(from: SharedFixtures.url("ingestion/slides.pptx"), kind: .pptx)
        XCTAssertEqual(pptx.text, "## Slide 1\nA\n\n## Slide 2\nB")
    }

    func testMissingMainPartIsDistinct() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nomain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.docx")
        let archive = try Archive(url: url, accessMode: .create)
        let body = Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8)
        try archive.addEntry(with: "[Content_Types].xml", type: .file, uncompressedSize: Int64(body.count)) { offset, count in
            body.subdata(in: Int(offset)..<min(Int(offset) + count, body.count))
        }
        do {
            _ = try await OfficeExtractor().extract(from: url, kind: .docx)
            XCTFail("expected throw")
        } catch ExtractorError.officeMainPartMissing {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
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
