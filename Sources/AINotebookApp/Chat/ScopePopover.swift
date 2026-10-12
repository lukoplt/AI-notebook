import AINotebookCore
import SwiftUI

/// Scope chip ("Whole notebook" / "Selected items (3)") and its popover with
/// today's scope selection: whole notebook vs. selected folders, sets, sources,
/// plus "save as set".
struct ScopeChip: View {
    @Bindable var model: ChatViewModel
    @ObservedObject var scope: FolderScopeModel
    /// Narrow composer: the icon and the selection count only.
    var compact = false
    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    private var t: AppText { settings.text }

    private var title: String {
        switch ChatSessionState.scopeSummary(scope.selection) {
        case .wholeNotebook: t.string(.scopeWholeNotebook)
        case .empty: t.string(.scopeEmpty)
        case .selected(let count): "\(t.string(.scopeSelection)) (\(count))"
        }
    }

    private var compactTitle: String {
        if case .selected(let count) = ChatSessionState.scopeSummary(scope.selection) { return "\(count)" }
        return ""
    }

    var body: some View {
        Button {
            Task { await model.openScopePopover() }
        } label: {
            ChipLabel(title: compact ? compactTitle : title, icon: .scope, isActive: !scope.selection.wholeNotebook,
                      highlighted: hovering, showsDisclosure: true)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(t.string(.chatScopeTitle))
        .accessibilityLabel("\(t.string(.composerScope)): \(title)")
        .popover(isPresented: $model.showingScopePopover, arrowEdge: .bottom) {
            ScopePopover(model: model, scope: scope)
        }
    }
}

struct ScopePopover: View {
    @Bindable var model: ChatViewModel
    @ObservedObject var scope: FolderScopeModel
    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            Text(t.string(.chatScopeTitle)).tokenFont(.headline).tokenForeground(.text1)
            Picker("", selection: Binding(get: { scope.selection.wholeNotebook },
                                          set: { scope.setWholeNotebook($0) })) {
                Text(t.string(.scopeWholeNotebook)).tag(true)
                Text(t.string(.scopeSelection)).tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if scope.isEmptySelection {
                Label(t.string(.scopeEmpty), systemImage: DesignTokens.icon(.warning))
                    .tokenFont(.caption)
                    .tokenForeground(.warning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
                    if !scope.folders.isEmpty {
                        sectionHeader(t.string(.scopeFolders))
                        ForEach(scope.folders, id: \.id) { folder in
                            Toggle(isOn: Binding(get: { scope.selection.folderIds.contains(folder.id) },
                                                 set: { scope.toggle(folder: folder.id, $0) })) {
                                Label(folder.draft.displayName, systemImage: DesignTokens.icon(.folder))
                                    .lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    if !scope.sets.isEmpty {
                        sectionHeader(t.string(.scopeSourceSets))
                        ForEach(scope.sets) { set in
                            HStack {
                                Toggle(isOn: Binding(get: { scope.selection.setIds.contains(set.id) },
                                                     set: { scope.toggle(set: set.id, $0) })) {
                                    Text(set.name).lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                IconButton(icon: .delete, label: t.string(.delete)) { model.deleteSet(set.id) }
                            }
                        }
                    }
                    if !scope.sources.isEmpty {
                        sectionHeader(t.string(.scopeSources))
                        ForEach(scope.sources) { source in
                            if let id = source.id {
                                Toggle(isOn: Binding(get: { scope.selection.sourceIds.contains(id) },
                                                     set: { scope.toggle(source: id, $0) })) {
                                    Text(source.title).lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .tokenFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            if !scope.selection.wholeNotebook {
                Hairline()
                HStack(spacing: DesignTokens.spacing(8)) {
                    TextField(t.string(.sourceSetNamePlaceholder), text: $model.newSetName)
                        .textFieldStyle(.roundedBorder)
                    Button(t.string(.save)) { model.saveCurrentAsSet() }
                        .buttonStyle(.secondary)
                        .disabled(model.newSetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(DesignTokens.spacing(16))
        .frame(minWidth: 280, maxWidth: 380)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .tokenFont(.caption)
            .tokenForeground(.text3)
            .padding(.top, DesignTokens.spacing(8))
    }
}
