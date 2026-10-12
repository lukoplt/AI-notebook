import SwiftUI

/// One action of an empty state.
struct EmptyStateAction: Identifiable {
    let id = UUID()
    let title: String
    var icon: DesignTokens.Icon?
    var isPrimary = false
    let action: () -> Void
}

/// Centered calm empty state: title, optional subtitle, actions.
struct EmptyStateView<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var actions: [EmptyStateAction] = []
    /// Panel-sized variant: body-size title, smaller padding.
    var compact = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: DesignTokens.spacing(compact ? 12 : 16)) {
            Text(title)
                .tokenFont(compact ? .body : .title)
                .tokenForeground(.text1)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .tokenFont(.body)
                    .tokenForeground(.text2)
                    .multilineTextAlignment(.center)
            }
            accessory()
            if !actions.isEmpty {
                HStack(spacing: DesignTokens.spacing(8)) {
                    ForEach(actions) { action in
                        if action.isPrimary {
                            Button(action: action.action) { label(action) }.buttonStyle(.primary)
                        } else {
                            Button(action: action.action) { label(action) }.buttonStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.spacing(compact ? 16 : 32))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func label(_ action: EmptyStateAction) -> some View {
        if let icon = action.icon {
            Label(action.title, systemImage: DesignTokens.icon(icon))
        } else {
            Text(action.title)
        }
    }
}

extension EmptyStateView where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, actions: [EmptyStateAction] = [], compact: Bool = false) {
        self.init(title: title, subtitle: subtitle, actions: actions, compact: compact, accessory: { EmptyView() })
    }
}

#Preview("Empty light") {
    EmptyStateView(title: "Start by adding a folder or creating a notebook", actions: [
        EmptyStateAction(title: "Add folder", icon: .addFolder, isPrimary: true) {},
        EmptyStateAction(title: "New notebook", icon: .add) {},
    ])
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.light)
}

#Preview("Empty dark") {
    EmptyStateView(title: "Start by adding a folder or creating a notebook", actions: [
        EmptyStateAction(title: "Add folder", icon: .addFolder, isPrimary: true) {},
        EmptyStateAction(title: "New notebook", icon: .add) {},
    ])
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.dark)
}
