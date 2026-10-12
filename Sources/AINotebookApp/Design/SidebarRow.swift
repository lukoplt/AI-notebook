import SwiftUI

/// One sidebar row (token row height, `surface-2` selection / hover, token icon).
struct SidebarRow<Trailing: View>: View {
    let title: String
    var icon: DesignTokens.Icon?
    var isSelected = false
    var indent: CGFloat = 0
    var emphasized = false
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    var body: some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            if let icon {
                TokenIcon(icon: icon, color: isSelected ? .text1 : .text2)
            }
            Text(title)
                .tokenFont(.body)
                .fontWeight(emphasized ? .medium : .regular)
                .tokenForeground(isSelected || emphasized ? .text1 : .text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, DesignTokens.spacing(8) + indent)
        .padding(.trailing, DesignTokens.spacing(4))
        .frame(height: DesignTokens.size(.sidebarRow))
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                .fill(isSelected ? DesignTokens.color(.surface2)
                      : hovering ? DesignTokens.color(.surface2).opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SidebarRow where Trailing == EmptyView {
    init(title: String, icon: DesignTokens.Icon? = nil, isSelected: Bool = false,
         indent: CGFloat = 0, emphasized: Bool = false) {
        self.init(title: title, icon: icon, isSelected: isSelected, indent: indent,
                  emphasized: emphasized, trailing: { EmptyView() })
    }
}

#Preview("SidebarRow light") {
    VStack(spacing: 2) {
        SidebarRow(title: "New chat", icon: .newChat, emphasized: true)
        SidebarRow(title: "Notebook A", icon: .notebook)
        SidebarRow(title: "Chat 1", isSelected: true, indent: 24)
        SidebarRow(title: "Chat 2", indent: 24)
    }
    .frame(width: 260)
    .padding()
    .background(DesignTokens.color(.bgSidebar))
    .preferredColorScheme(.light)
}

#Preview("SidebarRow dark") {
    VStack(spacing: 2) {
        SidebarRow(title: "New chat", icon: .newChat, emphasized: true)
        SidebarRow(title: "Notebook A", icon: .notebook)
        SidebarRow(title: "Chat 1", isSelected: true, indent: 24)
    }
    .frame(width: 260)
    .padding()
    .background(DesignTokens.color(.bgSidebar))
    .preferredColorScheme(.dark)
}
