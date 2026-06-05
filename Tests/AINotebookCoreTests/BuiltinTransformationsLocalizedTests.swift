import XCTest
@testable import AINotebookCore

@MainActor
final class BuiltinTransformationsLocalizedTests: XCTestCase {

    func testEnglishSeedNames() throws {
        let store = try NotebookStore(path: .inMemory, language: .english)
        let names = Set(try store.transformations().filter(\.isBuiltin).map(\.name))
        XCTAssertEqual(names, [
            "Summary", "Key points", "Entities", "Action items",
            "FAQ", "Study guide", "Timeline", "Briefing doc", "Glossary"
        ])
    }

    func testCzechSeedNames() throws {
        let store = try NotebookStore(path: .inMemory, language: .czech)
        let names = Set(try store.transformations().filter(\.isBuiltin).map(\.name))
        XCTAssertEqual(names, [
            "Souhrn", "Klíčové body", "Entity", "Úkoly",
            "FAQ", "Studijní příručka", "Časová osa", "Briefing", "Slovníček"
        ])
    }

    func testBuiltinsHaveDescriptions() throws {
        let store = try NotebookStore(path: .inMemory, language: .english)
        for t in try store.transformations().filter(\.isBuiltin) {
            XCTAssertFalse(t.description.isEmpty, "\(t.name) missing description")
        }
    }

    func testReseedSkipsExistingBuiltins() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-builtin-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try NotebookStore(path: StorePath(fileURL: url), language: .english)
        }
        do {
            let s2 = try NotebookStore(path: StorePath(fileURL: url), language: .english)
            let builtins = try s2.transformations().filter(\.isBuiltin)
            XCTAssertEqual(builtins.count, 9, "should not re-seed")
        }
    }
}
