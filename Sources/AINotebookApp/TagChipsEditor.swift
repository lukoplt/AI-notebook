import SwiftUI
import AINotebookCore

/// Epic B8 — a reusable tag editor: current tags as removable chips, plus a
/// menu to attach an existing tag and a field to create a new one. Works for
/// both notes and sources via the injected callbacks.
struct TagChipsEditor: View {
    @EnvironmentObject private var settings: AppSettings

    let assigned: [Tag]
    let all: [Tag]
    let onAdd: (Int64) -> Void
    let onRemove: (Int64) -> Void
    let onCreate: (String) -> Void

    @State private var newTag = ""

    private var t: AppText { settings.text }

    /// Tags that exist but aren't yet on this item.
    private var addable: [Tag] {
        let assignedIds = Set(assigned.map(\.id))
        return all.filter { !assignedIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.string(.tagsLabel)).tokenFont(.caption).tokenForeground(.text2)
            FlowChips(tags: assigned, onRemove: onRemove)
            HStack(spacing: 8) {
                if !addable.isEmpty {
                    Menu {
                        ForEach(addable) { tag in
                            Button(tag.name) { onAdd(tag.id) }
                        }
                    } label: {
                        Image(systemName: "tag")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                TextField(t.string(.tagAddPlaceholder), text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .onSubmit {
                        let name = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        onCreate(name)
                        newTag = ""
                    }
            }
        }
    }
}

/// Simple wrapping row of tag chips with a remove affordance.
private struct FlowChips: View {
    let tags: [Tag]
    let onRemove: (Int64) -> Void

    var body: some View {
        if tags.isEmpty {
            EmptyView()
        } else {
            FlowLayout(spacing: DesignTokens.spacing(4)) {
                ForEach(tags) { tag in
                    HStack(spacing: DesignTokens.spacing(4)) {
                        Text(tag.name).tokenFont(.caption).tokenForeground(.text1)
                        Button { onRemove(tag.id) } label: {
                            Image(systemName: "xmark.circle.fill").tokenFont(.caption)
                        }
                        .buttonStyle(.plain)
                        .tokenForeground(.text3)
                        .accessibilityLabel("\(tag.name) ×")
                    }
                    .padding(.horizontal, DesignTokens.spacing(8))
                    .padding(.vertical, DesignTokens.spacing(4) / 2)
                    .background(Capsule().fill(DesignTokens.color(.surface2)))
                }
            }
        }
    }
}
