import SwiftUI

/// Quiet segmented control for the right panel tabs.
struct PanelSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: DesignTokens.spacing(4)) {
            ForEach(items, id: \.value) { item in
                Segment(title: item.title, isSelected: item.value == selection) {
                    selection = item.value
                }
            }
        }
        .padding(DesignTokens.spacing(4) / 2)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                .fill(DesignTokens.color(.surface2))
        )
        .accessibilityElement(children: .contain)
    }

    private struct Segment: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .tokenFont(.caption)
                    .fontWeight(isSelected ? .medium : .regular)
                    .tokenForeground(isSelected || hovering ? .text1 : .text2)
                    .lineLimit(1)
                    .padding(.horizontal, DesignTokens.spacing(8))
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: DesignTokens.size(.hitMin) - DesignTokens.spacing(4))
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.radius(.sm) - 1, style: .continuous)
                            .fill(isSelected ? DesignTokens.color(.surface1) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

private struct SegmentPreview: View {
    @State var value = 0
    var body: some View {
        PanelSegmentedControl(selection: $value, items: [(0, "Sources"), (1, "Notes"), (2, "Context"), (3, "Citations")])
            .frame(width: 360)
            .padding()
            .background(DesignTokens.color(.surface1))
    }
}

#Preview("Segments light") { SegmentPreview().preferredColorScheme(.light) }
#Preview("Segments dark") { SegmentPreview().preferredColorScheme(.dark) }
