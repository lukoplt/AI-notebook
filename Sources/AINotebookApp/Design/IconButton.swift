import SwiftUI

/// Icon-only button: token SF Symbol, at least the minimum hit target, a
/// `surface-2` hover background and a mandatory accessibility label (also the tooltip).
struct IconButton: View {
    let icon: DesignTokens.Icon
    let label: String
    var size: DesignTokens.Size = .iconRow
    var isActive = false
    var color: DesignTokens.ColorToken = .text2
    let action: () -> Void

    @State private var hovering = false

    init(icon: DesignTokens.Icon, label: String, size: DesignTokens.Size = .iconRow,
         isActive: Bool = false, color: DesignTokens.ColorToken = .text2, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.size = size
        self.isActive = isActive
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            IconButtonFace(icon: icon, size: size, highlighted: hovering || isActive,
                           color: isActive ? .text1 : color)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The visual of an `IconButton`, reusable as a `Menu` label.
struct IconButtonFace: View {
    let icon: DesignTokens.Icon
    var size: DesignTokens.Size = .iconRow
    var highlighted = false
    var color: DesignTokens.ColorToken = .text2

    var body: some View {
        TokenIcon(icon: icon, size: size, color: color)
            .frame(width: DesignTokens.size(.hitMin), height: DesignTokens.size(.hitMin))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                    .fill(highlighted ? DesignTokens.color(.surface2) : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

/// Icon-only `Menu` with the `IconButton` look and an accessibility label.
struct IconMenu<Content: View>: View {
    let icon: DesignTokens.Icon
    let label: String
    var size: DesignTokens.Size = .iconRow
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            IconButtonFace(icon: icon, size: size, highlighted: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

#Preview("IconButton light") {
    HStack {
        IconButton(icon: .copy, label: "Copy") {}
        IconButton(icon: .togglePanel, label: "Panel", size: .iconTopBar, isActive: true) {}
        IconMenu(icon: .more, label: "More") { Button("Item") {} }
    }
    .padding()
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.light)
}

#Preview("IconButton dark") {
    HStack {
        IconButton(icon: .copy, label: "Copy") {}
        IconButton(icon: .togglePanel, label: "Panel", size: .iconTopBar, isActive: true) {}
        IconMenu(icon: .more, label: "More") { Button("Item") {} }
    }
    .padding()
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.dark)
}
