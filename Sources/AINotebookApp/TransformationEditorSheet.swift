import SwiftUI
import AINotebookCore

struct TransformationEditorSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Binding var isPresented: Bool
    var onChange: () -> Void

    @State private var customs: [Transformation] = []
    @State private var selection: Int64?
    @State private var draftName: String = ""
    @State private var draftTemplate: String = ""
    @State private var draftScope: TransformationScope = .source
    @State private var draftDescription: String = ""
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.transformationEditorTitle)).font(.title2).bold()
            HSplitView {
                list.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 320)
            HStack {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .task { await reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(t.string(.transformationEditorNew)) {
                    Task { await createBlank() }
                }
                Spacer()
                if let id = selection {
                    Button(role: .destructive) {
                        Task { await delete(id: id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            List(selection: $selection) {
                ForEach(customs) { tx in
                    Text(tx.name).tag(tx.id ?? -1)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, newId in
                if let id = newId, let tx = customs.first(where: { $0.id == id }) {
                    draftName = tx.name
                    draftTemplate = tx.promptTemplate
                    draftScope = tx.scope
                    draftDescription = tx.description
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if selection != nil {
            VStack(alignment: .leading, spacing: 8) {
                TextField(t.string(.transformationEditorNamePlaceholder), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                TextField(t.string(.aiToolsDescriptionPlaceholder), text: $draftDescription)
                    .textFieldStyle(.roundedBorder)
                Picker("Scope", selection: $draftScope) {
                    Text("Source").tag(TransformationScope.source)
                    Text("Notebook").tag(TransformationScope.notebook)
                }
                .pickerStyle(.segmented)
                TextEditor(text: $draftTemplate)
                    .font(.system(.body, design: .monospaced))
                    .overlay(alignment: .topLeading) {
                        if draftTemplate.isEmpty {
                            Text(t.string(.transformationEditorTemplatePlaceholder))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Spacer()
                    Button("Save") {
                        Task { await save() }
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                }
            }
        } else {
            VStack { Spacer(); Text("Pick or create a custom template").foregroundStyle(.secondary); Spacer() }
        }
    }

    @MainActor
    private func reload() async {
        do {
            customs = try store.transformations().filter { !$0.isBuiltin }
            if selection == nil { selection = customs.first?.id }
            if let id = selection, let tx = customs.first(where: { $0.id == id }) {
                draftName = tx.name
                draftTemplate = tx.promptTemplate
                draftScope = tx.scope
                draftDescription = tx.description
            }
        } catch { errorMessage = String(describing: error) }
    }

    private func createBlank() async {
        do {
            let tx = try store.createTransformation(
                name: "Untitled",
                promptTemplate: "{{source_text}}",
                scope: .source,
                isBuiltin: false
            )
            await reload()
            selection = tx.id
            onChange()
        } catch { errorMessage = String(describing: error) }
    }

    private func save() async {
        guard let id = selection else { return }
        do {
            try store.updateTransformation(
                id: id,
                name: draftName,
                promptTemplate: draftTemplate,
                description: draftDescription
            )
            try store.updateTransformationScope(id: id, scope: draftScope)
            await reload()
            onChange()
        } catch { errorMessage = String(describing: error) }
    }

    private func delete(id: Int64) async {
        do {
            try store.deleteTransformation(id: id)
            selection = nil
            await reload()
            onChange()
        } catch { errorMessage = String(describing: error) }
    }
}
