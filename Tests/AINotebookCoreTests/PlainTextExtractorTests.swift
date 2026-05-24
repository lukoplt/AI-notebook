import XCTest
@testable import AINotebookCore

final class PlainTextExtractorTests: XCTestCase {

    func testExtractsUtf8Plaintext() async throws {
        let url = try writeTempFile(name: "memo.txt", bytes: Data("Hello, world.".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let extracted = try await PlainTextExtractor().extract(from: url, kind: .text)
        XCTAssertEqual(extracted.text, "Hello, world.")
        XCTAssertEqual(extracted.title, "memo")
    }

    func testStripsMarkdownLeadingHashes() async throws {
        let md = "# Title\n\nSome **bold** body."
        let url = try writeTempFile(name: "doc.md", bytes: Data(md.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let extracted = try await PlainTextExtractor().extract(from: url, kind: .markdown)
        // Title is the first Markdown heading.
        XCTAssertEqual(extracted.title, "Title")
        // Markdown body retained (we do NOT lose content — we just expose
        // the raw text).
        XCTAssertTrue(extracted.text.contains("Some **bold** body."))
    }

    func testEmptyFileThrows() async throws {
        let url = try writeTempFile(name: "empty.txt", bytes: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await PlainTextExtractor().extract(from: url, kind: .text)
            XCTFail("expected throw")
        } catch ExtractorError.emptyContent {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    private func writeTempFile(name: String, bytes: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-notebook-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}
