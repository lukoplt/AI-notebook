import SwiftUI

/// Pill chip face: `surface-2`, caption text, optional leading token icon.
struct ChipLabel: View {
    let title: String
    var icon: DesignTokens.Icon?
    var isActive = false
    var highlighted = false
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: DesignTokens.spacing(4)) {
            if let icon {
                Image(systemName: DesignTokens.icon(icon))
                    .font(DesignTokens.font(.caption))
                    .accessibilityHidden(true)
            }
            if !title.isEmpty {
                Text(title)
                    .tokenFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if showsDisclosure {
                Image(systemName: DesignTokens.icon(.chevronDown))
                    .font(DesignTokens.font(.caption))
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .tokenForeground(isActive ? .text1 : .text2)
        .padding(.horizontal, DesignTokens.spacing(8))
        .frame(minHeight: DesignTokens.size(.hitMin) - DesignTokens.spacing(4))
        .background(
            Capsule(style: .continuous)
                .fill(DesignTokens.color(.surface2).opacity(highlighted || isActive ? 1 : 0.7))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DesignTokens.color(isActive ? .border : .surface2),
                              lineWidth: DesignTokens.size(.borderWidth))
        )
        .contentShape(Capsule())
    }
}

/// Pill-shaped button (composer chips, follow-up suggestions, tags).
struct ChipButton: View {
    let title: String
    var icon: DesignTokens.Icon?
    var isActive = false
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, icon: DesignTokens.Icon? = nil, isActive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, icon: icon, isActive: isActive, highlighted: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

/// A chip that opens a menu (scope / persona / model).
struct ChipMenu<Content: View>: View {
    let title: String
    var icon: DesignTokens.Icon?
    var accessibilityLabel: String?
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            ChipLabel(title: title, icon: icon, highlighted: hovering, showsDisclosure: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(accessibilityLabel ?? title)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

#Preview("Chips light") {
    HStack {
        ChipButton("Whole notebook", icon: .scope) {}
        ChipButton("Active", icon: .persona, isActive: true) {}
        ChipMenu(title: "Ollama · llama3.1", icon: .model) { Button("Item") {} }
    }
    .padding()
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.light)
}

#Preview("Chips dark") {
    HStack {
        ChipButton("Whole notebook", icon: .scope) {}
        ChipButton("Active", icon: .persona, isActive: true) {}
        ChipMenu(title: "Ollama · llama3.1", icon: .model) { Button("Item") {} }
    }
    .padding()
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.dark)
}
