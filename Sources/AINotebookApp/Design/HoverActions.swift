import SwiftUI

/// A row of actions revealed on hover (fast token transition, none with
/// Reduce Motion). Hidden visually only: the buttons stay in the
/// accessibility tree so VoiceOver and keyboard users always reach them.
struct HoverActions<Content: View>: View {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.spacing(4) / 2) {
            content()
        }
        .opacity(isVisible ? 1 : 0)
        .animation(DesignTokens.animation(.fastMs, reduceMotion: reduceMotion), value: isVisible)
    }
}

#Preview("HoverActions light") {
    HoverActions(isVisible: true) {
        IconButton(icon: .copy, label: "Copy") {}
        IconButton(icon: .regenerate, label: "Regenerate") {}
        IconButton(icon: .saveAsNote, label: "Save as note") {}
    }
    .padding()
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.light)
}

#Preview("HoverActions dark") {
    HoverActions(isVisible: true) {
        IconButton(icon: .copy, label: "Copy") {}
        IconButton(icon: .regenerate, label: "Regenerate") {}
    }
    .padding()
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.dark)
}
