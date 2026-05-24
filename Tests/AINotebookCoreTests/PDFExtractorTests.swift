// Tests/AINotebookCoreTests/PDFExtractorTests.swift
import XCTest
@testable import AINotebookCore

final class PDFExtractorTests: XCTestCase {
    func testExtractsTextFromMultiPagePDF() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "pdf", subdirectory: "Fixtures")
        )
        let extracted = try await PDFExtractor().extract(from: url, kind: .pdf)
        XCTAssertTrue(extracted.text.contains("First page text"))
        XCTAssertTrue(extracted.text.contains("Second page text"))
        XCTAssertEqual(extracted.title, "sample")
    }

    func testThrowsOnNonPDF() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notpdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await PDFExtractor().extract(from: url, kind: .pdf)
            XCTFail("expected throw")
        } catch ExtractorError.pdfOpenFailed {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
