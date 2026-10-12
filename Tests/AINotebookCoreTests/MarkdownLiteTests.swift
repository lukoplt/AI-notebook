import XCTest
@testable import AINotebookCore

/// Shared contract `markdown-lite-v1.json` (reference parser:
/// tools/contracts/gen_markdown_fixtures.py). The Windows suite runs the same cases.
final class MarkdownLiteTests: XCTestCase {
    private func cases() throws -> [[String: Any]] {
        let fixture = try SharedFixtures.json("contracts/markdown-lite-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "markdown-lite")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        return try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    }

    func testEveryFixtureCase() throws {
        let all = try cases()
        XCTAssertGreaterThanOrEqual(all.count, 45)
        for c in all {
            let name = try XCTUnwrap(c["name"] as? String)
            let input = try XCTUnwrap(c["input"] as? String)
            let expected = try XCTUnwrap(c["expected"] as? [[String: Any]], name)
                .map { try Self.block($0) }
            XCTAssertEqual(MarkdownLite.parse(input), expected, name)
        }
    }

    func testEveryPrefixOfEveryCaseParses() throws {
        for c in try cases() {
            let scalars = Array((c["input"] as? String ?? "").unicodeScalars)
            for cut in 0...scalars.count {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[0..<cut])
                _ = MarkdownLite.parse(String(view))
            }
        }
    }

    func testCrlfMatchesLf() {
        XCTAssertEqual(MarkdownLite.parse("- a\r\n  - b\r\n\r\ntext"),
                       MarkdownLite.parse("- a\n  - b\n\ntext"))
    }

    // MARK: - fixture JSON → model

    private struct Bad: Error { let what: String }

    static func block(_ o: [String: Any]) throws -> MarkdownBlock {
        switch o["type"] as? String {
        case "paragraph": return .paragraph(try inlines(o["inlines"]))
        case "heading":
            return .heading(level: try XCTUnwrap(o["level"] as? Int), inlines: try inlines(o["inlines"]))
        case "quote": return .quote(try inlines(o["inlines"]))
        case "code": return .code(try XCTUnwrap(o["text"] as? String))
        case "rule": return .rule
        case "list": return .list(try list(o))
        default: throw Bad(what: "block \(o)")
        }
    }

    static func list(_ o: [String: Any]) throws -> MarkdownList {
        let items = try XCTUnwrap(o["items"] as? [[String: Any]]).map { item -> MarkdownListItem in
            let sub = try (item["sublist"] as? [String: Any]).map { try list($0) }
            return MarkdownListItem(inlines: try inlines(item["inlines"]), sublist: sub)
        }
        return MarkdownList(ordered: try XCTUnwrap(o["ordered"] as? Bool),
                            start: o["start"] as? Int, items: items)
    }

    static func inlines(_ any: Any?) throws -> [MarkdownInline] {
        try XCTUnwrap(any as? [[String: Any]]).map { o in
            switch o["t"] as? String {
            case "text": return .text(try XCTUnwrap(o["v"] as? String))
            case "code": return .code(try XCTUnwrap(o["v"] as? String))
            case "strong": return .strong(try inlines(o["c"]))
            case "em": return .emphasis(try inlines(o["c"]))
            case "link": return .link(href: try XCTUnwrap(o["href"] as? String), children: try inlines(o["c"]))
            case "cite": return .cite(try XCTUnwrap(o["n"] as? Int))
            default: throw Bad(what: "inline \(o)")
            }
        }
    }
}
