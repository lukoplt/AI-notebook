import XCTest
@testable import AINotebookCore

final class AINotebookVersionTests: XCTestCase {

    /// Repo root = three levels up from this file
    /// (Tests/AINotebookCoreTests/AINotebookVersionTests.swift).
    private func repoRootVersion() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // AINotebookCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        let versionURL = repoRoot.appendingPathComponent("VERSION")
        let raw = try String(contentsOf: versionURL, encoding: .utf8)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The in-code constant must always match the repo-root VERSION file —
    /// this is what makes a release bump that forgets the constant fail CI.
    func testVersionMatchesRepoVersionFile() throws {
        XCTAssertEqual(AINotebookVersion, try repoRootVersion())
    }

    func testVersionIsSemverShape() {
        let parts = AINotebookVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "Version must have three dot-separated parts")
        for part in parts {
            XCTAssertNotNil(Int(part), "Each part of version must be an integer")
        }
    }
}
