import Foundation

/// Repo-root `Tests/fixtures/` — shared with the Windows test suite. Lives
/// outside the SwiftPM test target, so it is located via `#filePath`
/// (same pattern as AINotebookVersionTests).
enum SharedFixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AINotebookCoreTests/
        .deletingLastPathComponent()   // Tests/
        .appendingPathComponent("fixtures", isDirectory: true)

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    static func json(_ relativePath: String) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data(relativePath)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return obj
    }

    static func contractFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: url("contracts"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
