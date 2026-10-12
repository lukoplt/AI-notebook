import SwiftUI

/// Monochrome primary button (accent fill, on-accent text), radius `sm`,
/// at least the primary hit target tall.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tokenFont(.body)
            .fontWeight(.medium)
            .tokenForeground(.onAccent)
            .padding(.horizontal, DesignTokens.spacing(16))
            .frame(minHeight: DesignTokens.size(.primaryHitMin))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                    .fill(DesignTokens.color(.accent))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// Quiet secondary button: hairline border on `surface-1`, primary text.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tokenFont(.body)
            .tokenForeground(.text1)
            .padding(.horizontal, DesignTokens.spacing(12))
            .frame(minHeight: DesignTokens.size(.hitMin))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                    .fill(DesignTokens.color(hovering || configuration.isPressed ? .surface2 : .surface1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                    .strokeBorder(DesignTokens.color(.border), lineWidth: DesignTokens.size(.borderWidth))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Text-only button in a secondary colour (e.g. "+ New notebook", "Show more").
struct QuietButtonStyle: ButtonStyle {
    var token: DesignTokens.ColorToken = .text2
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tokenFont(.body)
            .tokenForeground(hovering ? .text1 : token)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// Token-styled hairline card container (`surface-1`, `border`, radius `md`).
struct CardBackground: ViewModifier {
    var radius: DesignTokens.Radius = .md
    var fill: DesignTokens.ColorToken = .surface1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius(radius), style: .continuous)
                    .fill(DesignTokens.color(fill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radius(radius), style: .continuous)
                    .strokeBorder(DesignTokens.color(.border), lineWidth: DesignTokens.size(.borderWidth))
            )
    }
}

extension View {
    func card(radius: DesignTokens.Radius = .md, fill: DesignTokens.ColorToken = .surface1) -> some View {
        modifier(CardBackground(radius: radius, fill: fill))
    }

    /// Token icon image at a token icon size.
    func iconFrame(_ size: DesignTokens.Size = .iconRow) -> some View {
        frame(width: DesignTokens.size(size), height: DesignTokens.size(size))
    }
}

/// SF Symbol for an icon token at a token size.
struct TokenIcon: View {
    let icon: DesignTokens.Icon
    var size: DesignTokens.Size = .iconRow
    var color: DesignTokens.ColorToken = .text2

    var body: some View {
        Image(systemName: DesignTokens.icon(icon))
            .font(.system(size: DesignTokens.size(size) * 0.85, weight: .regular))
            .iconFrame(size)
            .tokenForeground(color)
            .accessibilityHidden(true)
    }
}

/// A thin horizontal hairline in the `border` colour.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(DesignTokens.color(.border))
            .frame(height: DesignTokens.size(.borderWidth))
    }
}
