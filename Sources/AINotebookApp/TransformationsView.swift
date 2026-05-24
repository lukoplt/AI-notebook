import SwiftUI
import AINotebookCore

struct TransformationsView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var transformationHolder: TransformationEngineHolder

    @State private var transformations: [Transformation] = []
    @State private var sources: [Source] = []
    @State private var selectedTransformationId: Int64?
    @State private var selectedSourceId: Int64?
    @State private var resultBody: String = ""
    @State private var resultNoteId: Int64?
    @State private var running = false
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t.string(.transformationsSectionTitle))
                .font(.title2).bold()

            HStack {
                pickerColumn(title: t.string(.transformationPickerLabel)) {
                    Picker("", selection: $selectedTransformationId) {
                        ForEach(transformations) { tx in
                            Text(tx.name).tag(tx.id as Int64?)
                        }
                    }
                    .labelsHidden()
                }
                pickerColumn(title: t.string(.transformationSourcePickerLabel)) {
                    Picker("", selection: $selectedSourceId) {
                        ForEach(sources) { s in
                            Text(s.title).tag(s.id as Int64?)
                        }
                    }
                    .labelsHidden()
                }
                Spacer()
                Button(t.string(.transformationRunButton)) {
                    Task { await run() }
                }
                .disabled(running
                          || selectedTransformationId == nil
                          || selectedSourceId == nil)
            }

            if running {
                ProgressView(t.string(.transformationRunningStatus))
            }

            if !resultBody.isEmpty {
                Text(t.string(.transformationResultTitle)).font(.headline)
                ScrollView {
                    Text(resultBody)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .task(id: notebook.id) { await reload() }
    }

    @ViewBuilder
    private func pickerColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    @MainActor
    private func reload() async {
        do {
            transformations = try store.transformations()
            sources = try store.sources(notebookId: notebook.id!)
            if selectedTransformationId == nil { selectedTransformationId = transformations.first?.id }
            if selectedSourceId == nil          { selectedSourceId         = sources.first?.id }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func run() async {
        guard let tid = selectedTransformationId, let sid = selectedSourceId else { return }
        running = true
        errorMessage = nil
        resultBody = ""
        resultNoteId = nil
        defer { running = false }
        do {
            let note = try await transformationHolder.engine.run(
                transformationId: tid, sourceId: sid
            )
            resultBody = note.bodyMd
            resultNoteId = note.id
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
