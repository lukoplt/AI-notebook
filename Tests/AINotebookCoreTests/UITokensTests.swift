import XCTest
@testable import AINotebookCore

/// `UITokensV1` (which `DesignTokens` in the app maps to SwiftUI) must equal the
/// shared contract `ui-tokens-v1.json`, key for key, in both directions.
final class UITokensTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let f = try SharedFixtures.json("contracts/ui-tokens-v1.json")
        XCTAssertEqual(f["contract"] as? String, "ui-tokens")
        XCTAssertEqual(f["version"] as? Int, 1)
        return f
    }

    private func section(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try fixture()[name] as? [String: Any], name)
    }

    func testColors() throws {
        let colors = try section("colors")
        XCTAssertEqual(Set(colors.keys), Set(UITokensV1.ColorToken.allCases.map(\.rawValue)))
        XCTAssertEqual(colors.count, 14)
        for token in UITokensV1.ColorToken.allCases {
            let pair = try XCTUnwrap(colors[token.rawValue] as? [String: String], token.rawValue)
            XCTAssertEqual(UITokensV1.color(token), .init(light: pair["light"]!, dark: pair["dark"]!), token.rawValue)
        }
    }

    func testHexComponents() throws {
        for token in UITokensV1.ColorToken.allCases {
            XCTAssertNotNil(UITokensV1.components(UITokensV1.color(token).light), token.rawValue)
            XCTAssertNotNil(UITokensV1.components(UITokensV1.color(token).dark), token.rawValue)
        }
        let focus = try XCTUnwrap(UITokensV1.components("#2F6FEB"))
        XCTAssertEqual(focus.red, 47.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(focus.green, 111.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(focus.blue, 235.0 / 255.0, accuracy: 1e-9)
        XCTAssertNil(UITokensV1.components("2F6FEB"))
        XCTAssertNil(UITokensV1.components("#2F6FEG"))
        XCTAssertNil(UITokensV1.components("#2F6FE"))
    }

    func testTypeRamp() throws {
        let type = try section("type")
        XCTAssertEqual(Set(type.keys), Set(UITokensV1.TypeStyle.allCases.map(\.rawValue)))
        for style in UITokensV1.TypeStyle.allCases {
            let o = try XCTUnwrap(type[style.rawValue] as? [String: Any], style.rawValue)
            let spec = UITokensV1.type(style)
            XCTAssertEqual(spec.size, o["size"] as? Int, style.rawValue)
            XCTAssertEqual(spec.line, o["line"] as? Int, style.rawValue)
            XCTAssertEqual(spec.lineWindows, (o["lineWindows"] as? Int) ?? spec.line, style.rawValue)
            XCTAssertEqual(spec.weight.rawValue, o["weight"] as? String, style.rawValue)
        }
    }

    func testFonts() throws {
        let mac = try XCTUnwrap(try section("fonts")["macos"] as? [String: String])
        XCTAssertEqual(UITokensV1.fontText, mac["text"])
        XCTAssertEqual(UITokensV1.fontMono, mac["mono"])
    }

    func testSpacingRadiusSizeMotion() throws {
        XCTAssertEqual(try fixture()["spacing"] as? [Int], UITokensV1.spacing)
        let radius = try section("radius")
        XCTAssertEqual(Set(radius.keys), Set(UITokensV1.Radius.allCases.map(\.rawValue)))
        for r in UITokensV1.Radius.allCases { XCTAssertEqual(radius[r.rawValue] as? Int, UITokensV1.radius(r), r.rawValue) }
        let size = try section("size")
        XCTAssertEqual(Set(size.keys), Set(UITokensV1.Size.allCases.map(\.rawValue)))
        for s in UITokensV1.Size.allCases { XCTAssertEqual(size[s.rawValue] as? Int, UITokensV1.size(s), s.rawValue) }
        let motion = try section("motion")
        XCTAssertEqual(Set(motion.keys), Set(UITokensV1.Motion.allCases.map(\.rawValue)))
        for m in UITokensV1.Motion.allCases { XCTAssertEqual(motion[m.rawValue] as? Int, UITokensV1.milliseconds(m), m.rawValue) }
    }

    func testIcons() throws {
        let icons = try section("icons")
        XCTAssertEqual(Set(icons.keys), Set(UITokensV1.Icon.allCases.map(\.rawValue)))
        for icon in UITokensV1.Icon.allCases {
            let o = try XCTUnwrap(icons[icon.rawValue] as? [String: String], icon.rawValue)
            XCTAssertEqual(UITokensV1.icon(icon), .init(sfSymbol: o["sf"]!, fluentGlyph: o["fluent"]!), icon.rawValue)
            XCTAssertEqual(UInt32(o["fluent"]!, radix: 16).map { (0xE000...0xF8FF).contains($0) }, true,
                           "Fluent glyphs live in the private-use area: \(icon.rawValue)")
        }
    }
}
