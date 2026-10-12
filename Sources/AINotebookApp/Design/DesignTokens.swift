import AINotebookCore
import AppKit
import SwiftUI

/// SwiftUI face of the shared design tokens (`UITokensV1`, contract
/// `ui-tokens-v1.json`, docs/design/tokens-v1.md). Views use only these
/// accessors — no hard-coded colours, font sizes, radii or spacing.
enum DesignTokens {
    typealias ColorToken = UITokensV1.ColorToken
    typealias TypeStyle = UITokensV1.TypeStyle
    typealias Radius = UITokensV1.Radius
    typealias Size = UITokensV1.Size
    typealias Icon = UITokensV1.Icon
    typealias Motion = UITokensV1.Motion

    // MARK: colour

    /// Dynamic colour that follows the effective appearance (light / dark).
    static func color(_ token: ColorToken) -> Color {
        Color(nsColor: nsColor(token))
    }

    static func nsColor(_ token: ColorToken) -> NSColor {
        let pair = UITokensV1.color(token)
        let light = srgb(pair.light)
        let dark = srgb(pair.dark)
        return NSColor(name: NSColor.Name("ainb.\(token.rawValue)")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func srgb(_ hex: String) -> NSColor {
        guard let c = UITokensV1.components(hex) else {
            assertionFailure("invalid token colour \(hex)")
            return .magenta
        }
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    // MARK: type

    static func font(_ style: TypeStyle) -> Font {
        let spec = UITokensV1.type(style)
        let weight: Font.Weight = spec.weight == .semibold ? .semibold : .regular
        return .system(size: CGFloat(spec.size), weight: weight,
                       design: style == .mono ? .monospaced : .default)
    }

    static func nsFont(_ style: TypeStyle) -> NSFont {
        let spec = UITokensV1.type(style)
        let weight: NSFont.Weight = spec.weight == .semibold ? .semibold : .regular
        return style == .mono
            ? .monospacedSystemFont(ofSize: CGFloat(spec.size), weight: weight)
            : .systemFont(ofSize: CGFloat(spec.size), weight: weight)
    }

    /// Token line height in points.
    static func lineHeight(_ style: TypeStyle) -> CGFloat {
        CGFloat(UITokensV1.type(style).line)
    }

    /// Extra leading SwiftUI must add to reach the token line height.
    static func lineSpacing(_ style: TypeStyle) -> CGFloat {
        let font = nsFont(style)
        let natural = font.ascender - font.descender + font.leading
        return max(0, lineHeight(style) - natural)
    }

    // MARK: metrics

    static func radius(_ radius: Radius) -> CGFloat {
        CGFloat(UITokensV1.radius(radius))
    }

    /// One step of the 4 pt spacing scale (4, 8, 12, 16, 24, 32).
    static func spacing(_ value: Int) -> CGFloat {
        assert(UITokensV1.spacing.contains(value), "\(value) is not a spacing token")
        return CGFloat(value)
    }

    static func size(_ size: Size) -> CGFloat {
        CGFloat(UITokensV1.size(size))
    }

    // MARK: icons

    /// SF Symbol name for an icon token.
    static func icon(_ icon: Icon) -> String {
        UITokensV1.icon(icon).sfSymbol
    }

    // MARK: motion

    /// Short ease-out transition, or nil when Reduce Motion is on.
    static func animation(_ motion: Motion, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: Double(UITokensV1.milliseconds(motion)) / 1000)
    }
}

extension View {
    /// Applies a token text style: font plus the leading that reaches its line height.
    func tokenFont(_ style: DesignTokens.TypeStyle) -> some View {
        font(DesignTokens.font(style)).lineSpacing(DesignTokens.lineSpacing(style))
    }

    /// Foreground in a token colour.
    func tokenForeground(_ token: DesignTokens.ColorToken) -> some View {
        foregroundStyle(DesignTokens.color(token))
    }
}
