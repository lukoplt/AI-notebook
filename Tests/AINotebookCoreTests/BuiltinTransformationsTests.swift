import XCTest
@testable import AINotebookCore

@MainActor
final class BuiltinTransformationsTests: XCTestCase {

    func testFreshDatabaseGetsBuiltinsSeeded() throws {
        let store = try NotebookStore(path: .inMemory)
        let all = try store.transformations()
        let builtinNames = Set(all.filter(\.isBuiltin).map(\.name))
        XCTAssertEqual(builtinNames, ["Summary", "Key points", "Entities", "Action items"])
    }

    func testReopeningDatabaseDoesNotDuplicateBuiltins() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try NotebookStore(path: StorePath(fileURL: url))
        }
        do {
            let store2 = try NotebookStore(path: StorePath(fileURL: url))
            let builtins = try store2.transformations().filter(\.isBuiltin)
            XCTAssertEqual(builtins.count, 4, "should not re-seed on second open")
        }
    }
}
