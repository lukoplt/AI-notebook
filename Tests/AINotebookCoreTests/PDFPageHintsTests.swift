import XCTest
@testable import AINotebookCore

@MainActor
final class PDFPageHintsTests: XCTestCase {

    func testIngestedPDFChunksCarryPageHints() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "pdf", subdirectory: "Fixtures")
        )
        let service = IngestionService(store: store)
        let source = try await service.ingestFile(url, into: nb.id!)
        let chunks = try store.chunks(sourceId: source.id!)
        XCTAssertFalse(chunks.isEmpty)
        // At least one chunk should have a non-nil page hint > 0.
        XCTAssertTrue(
            chunks.contains { $0.pageHint != nil && $0.pageHint! > 0 },
            "expected at least one chunk with a page hint, got: \(chunks.map { $0.pageHint as Any })"
        )
    }
}
