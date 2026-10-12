import AINotebookCore
import SwiftUI

/// Tools: the custom transformation template editor (formerly a sheet).
/// Built-in templates are run from "+ › Run tool" and are not editable.
struct ToolsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @State private var customs: [Transformation] = []
    @State private var selection: Int64?
    @State private var draftName = ""
    @State private var draftTemplate = ""
    @State private var draftScope: TransformationScope = .source
    @State private var draftDescription = ""
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        SettingsGroup(t.string(.transformationEditorTitle), footnote: t.string(.aiToolsScopeHint)) {
            HStack(alignment: .top, spacing: DesignTokens.spacing(16)) {
                list.frame(width: 180)
                Rectangle().fill(DesignTokens.color(.border)).frame(width: DesignTokens.size(.borderWidth))
                editor.frame(maxWidth: .infinity)
            }
            .frame(minHeight: 320)
            if let errorMessage { SettingsErrorText(errorMessage) }
        }
        .task { reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            HStack {
                Button(t.string(.transformationEditorNew)) { createBlank() }
                    .buttonStyle(.secondary)
                Spacer()
                if let id = selection {
                    IconButton(icon: .delete, label: t.string(.delete)) { delete(id: id) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(customs) { tx in
                        Button { select(tx.id) } label: {
                            SidebarRow(title: tx.name, isSelected: tx.id == selection)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if selection != nil {
            VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
                TextField(t.string(.transformationEditorNamePlaceholder), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                TextField(t.string(.aiToolsDescriptionPlaceholder), text: $draftDescription)
                    .textFieldStyle(.roundedBorder)
                Picker(t.string(.toolScope), selection: $draftScope) {
                    Text(t.string(.toolScopeSource)).tag(TransformationScope.source)
                    Text(t.string(.scopeWholeNotebook)).tag(TransformationScope.notebook)
                }
                .pickerStyle(.segmented)
                TextEditor(text: $draftTemplate)
                    .font(DesignTokens.font(.mono))
                    .scrollContentBackground(.hidden)
                    .padding(DesignTokens.spacing(8))
                    .frame(minHeight: 200)
                    .card(radius: .sm)
                    .overlay(alignment: .topLeading) {
                        if draftTemplate.isEmpty {
                            Text(t.string(.transformationEditorTemplatePlaceholder))
                                .tokenForeground(.text3)
                                .padding(DesignTokens.spacing(12))
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Spacer()
                    Button(t.string(.save)) { save() }
                        .buttonStyle(.primary)
                        .keyboardShortcut("s", modifiers: [.command])
                }
            }
        } else {
            Text(t.string(.toolsPickTemplate))
                .tokenForeground(.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ id: Int64?) {
        selection = id
        if let id, let tx = customs.first(where: { $0.id == id }) {
            draftName = tx.name
            draftTemplate = tx.promptTemplate
            draftScope = tx.scope
            draftDescription = tx.description
        }
    }

    private func reload() {
        do {
            customs = try store.transformations().filter { !$0.isBuiltin }
            if selection == nil || !customs.contains(where: { $0.id == selection }) { selection = customs.first?.id }
            select(selection)
        } catch { errorMessage = String(describing: error) }
    }

    private func createBlank() {
        do {
            let tx = try store.createTransformation(
                name: t.string(.noteUntitled),
                promptTemplate: "{{source_text}}",
                scope: .source,
                isBuiltin: false
            )
            reload()
            select(tx.id)
        } catch { errorMessage = String(describing: error) }
    }

    private func save() {
        guard let id = selection else { return }
        do {
            try store.updateTransformation(id: id, name: draftName, promptTemplate: draftTemplate,
                                           description: draftDescription)
            try store.updateTransformationScope(id: id, scope: draftScope)
            reload()
        } catch { errorMessage = String(describing: error) }
    }

    private func delete(id: Int64) {
        do {
            try store.deleteTransformation(id: id)
            selection = nil
            reload()
        } catch { errorMessage = String(describing: error) }
    }
}
