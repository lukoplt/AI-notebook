import XCTest
@testable import AINotebookCore

final class CitationOriginalPolicyTests: XCTestCase {
    private func input(relativePath: String = "docs/a.txt",
                       rootComponents: [String] = ["volume", "folder"],
                       resolvedComponents: [String] = ["volume", "folder", "docs", "a.txt"],
                       caseSensitive: Bool = true, exists: Bool = true,
                       isRegularFile: Bool = true, sourceExists: Bool = true,
                       currentRevisionId: Int64? = 11, citedRevisionId: Int64? = 11) -> CitationOriginalInput {
        CitationOriginalInput(relativePath: relativePath, rootComponents: rootComponents,
            resolvedComponents: resolvedComponents, caseSensitive: caseSensitive, exists: exists,
            isRegularFile: isRegularFile, sourceExists: sourceExists,
            currentRevisionId: currentRevisionId, citedRevisionId: citedRevisionId)
    }

    func testAllSharedOriginalDecisions() throws {
        let rows = try ContextPackFixtures.cases("original")
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let input = try ContextPackFixtures.decode(row["input"]!, as: CitationOriginalInput.self)
            XCTAssertEqual(CitationOriginalPolicy.evaluate(input).rawValue,
                           row["expected"] as! String, row["name"] as! String)
        }
    }

    func testUnsafeRelativePathsUseScalarComponents() {
        let paths = ["", "/docs/a.txt", "docs/", "docs//a.txt", "./a.txt", "../a.txt",
                     "docs/./a.txt", "docs/../a.txt", "C:/a.txt", "C:\\a.txt", "\\\\server\\a.txt",
                     "docs/a\u{0000}.txt", "docs/a\u{001F}.txt", "docs/a\n.txt",
                     "../\u{0301}a.txt", "./\u{0301}a.txt", "docs//\u{0301}a.txt", "/\u{0301}a.txt"]
        for (index, path) in paths.enumerated() {
            XCTAssertEqual(CitationOriginalPolicy.evaluate(input(relativePath: path)), .unsafe, "path case \(index)")
        }
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(relativePath: "../a.txt", sourceExists: false)), .unsafe)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(relativePath: "docs/\u{0301}a.txt")), .available)
        // The original-opening reference rejects C0; C1 is not reclassified here.
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(relativePath: "docs/a\u{0085}.txt")), .available)
    }

    func testUnavailableSourceAndFileConditionsPrecedeContainment() {
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(exists: false)), .unavailable)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(isRegularFile: false)), .unavailable)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(sourceExists: false)), .unavailable)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(rootComponents: [], exists: false)), .unavailable)
    }

    func testResolvedIdentityMustBeStrictlyWithinRoot() {
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(rootComponents: [])), .unsafe)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(resolvedComponents: ["volume", "folder"])), .unsafe)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(resolvedComponents: ["volume"])), .unsafe)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(resolvedComponents: ["volume", "folder-other", "a.txt"])), .unsafe)
    }

    func testResolvedComponentsCompareExactScalarsOnBothVolumeModes() {
        for caseSensitive in [true, false] {
            XCTAssertEqual(CitationOriginalPolicy.evaluate(input(
                rootComponents: ["volume", "café"],
                resolvedComponents: ["volume", "cafe\u{0301}", "a.txt"],
                caseSensitive: caseSensitive)), .unsafe)
            XCTAssertEqual(CitationOriginalPolicy.evaluate(input(
                resolvedComponents: ["volume", "Folder", "a.txt"],
                caseSensitive: caseSensitive)), .unsafe)
            XCTAssertEqual(CitationOriginalPolicy.evaluate(input(
                rootComponents: ["volume", "cafe\u{0301}"],
                resolvedComponents: ["volume", "cafe\u{0301}", "a.txt"],
                caseSensitive: caseSensitive)), .available)
        }
    }

    func testRevisionChangesDoNotDiscardAvailableLegacyOriginals() {
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(currentRevisionId: 12)), .changed)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(currentRevisionId: nil)), .changed)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(currentRevisionId: 12, citedRevisionId: nil)), .available)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input(currentRevisionId: nil, citedRevisionId: nil)), .available)
        XCTAssertEqual(CitationOriginalPolicy.evaluate(input()), .available)
    }
}
