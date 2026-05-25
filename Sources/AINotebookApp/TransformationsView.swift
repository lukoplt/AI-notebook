import SwiftUI
import AINotebookCore

struct TransformationsView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var transformationHolder: TransformationEngineHolder
    @EnvironmentObject private var noteJump: NoteJumpCoordinator
    @EnvironmentObject private var tabSwitch: TabSwitchCoordinator

    enum BatchScope: Hashable {
        case source, notebook, allSources
    }

    @State private var transformations: [Transformation] = []
    @State private var sources: [Source] = []
    @State private var selectedTransformationId: Int64?
    @State private var selectedSourceId: Int64?
    @State private var scope: BatchScope = .source
    @State private var resultBody: String = ""
    @State private var resultNoteId: Int64?
    @State private var batchCompleted: Int = 0
    @State private var batchTotal: Int = 0
    @State private var batchSavedCount: Int? = nil
    @State private var running = false
    @State private var errorMessage: String?
    @State private var showingEditor = false
    @State private var showingPreview = false
    @State private var showingHistory = false

    private var t: AppText { settings.text }

    private var selectedTransformation: Transformation? {
        guard let id = selectedTransformationId else { return nil }
        return transformations.first(where: { $0.id == id })
    }

    private var selectedSource: Source? {
        guard let id = selectedSourceId else { return nil }
        return sources.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            templateRow
            scopeRow
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: notebook.id) { await reload() }
        .sheet(isPresented: $showingEditor, onDismiss: { Task { await reload() } }) {
            TransformationEditorSheet(isPresented: $showingEditor, onChange: { Task { await reload() } })
        }
        .sheet(isPresented: $showingPreview) {
            if let tx = selectedTransformation {
                TransformationPromptPreviewSheet(
                    transformation: tx,
                    source: scope == .source ? selectedSource : nil,
                    isPresented: $showingPreview
                )
            }
        }
        .sheet(isPresented: $showingHistory) {
            TransformationHistorySheet(notebook: notebook, isPresented: $showingHistory)
        }
    }

    private var header: some View {
        HStack {
            Text(t.string(.aiToolsSectionTitle)).font(.title2).bold()
            Spacer()
            Button(t.string(.aiToolsHistoryButton)) { showingHistory = true }
            Button(t.string(.transformationEditButton)) { showingEditor = true }
        }
    }

    private var templateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t.string(.transformationPickerLabel)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingPreview = true
                } label: {
                    Label(t.string(.aiToolsPreviewButton), systemImage: "eye")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(selectedTransformation == nil)
            }
            Picker("", selection: $selectedTransformationId) {
                ForEach(transformations) { tx in
                    Text(tx.name).tag(tx.id as Int64?)
                }
            }
            .labelsHidden()
            if let tx = selectedTransformation, !tx.description.isEmpty {
                Text(tx.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedTransformationId) { _, _ in
            if let tx = selectedTransformation {
                scope = (tx.scope == .notebook) ? .notebook : .source
            }
        }
    }

    private var scopeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $scope) {
                Text("Source").tag(BatchScope.source)
                Text("Notebook").tag(BatchScope.notebook)
                Text(t.string(.aiToolsScopeAllSources)).tag(BatchScope.allSources)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text(t.string(.aiToolsScopeHint))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack {
                if scope == .source {
                    Picker(t.string(.transformationSourcePickerLabel), selection: $selectedSourceId) {
                        ForEach(sources) { s in
                            Text(s.title).tag(s.id as Int64?)
                        }
                    }
                    .frame(maxWidth: 360)
                }
                Spacer()
                Button(t.string(.transformationRunButton)) {
                    Task { await run() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(running
                          || selectedTransformationId == nil
                          || (scope == .source && selectedSourceId == nil)
                          || (scope == .allSources && sources.isEmpty))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if running {
            runningSection
        } else if let savedCount = batchSavedCount, savedCount > 1 {
            batchSavedToast(count: savedCount)
        } else if let nid = resultNoteId {
            singleSavedSection(noteId: nid)
        } else {
            emptyExplainer
        }
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if batchTotal > 0 {
                ProgressView(
                    String(format: t.string(.aiToolsRunningFormat), batchCompleted, batchTotal),
                    value: Double(batchCompleted),
                    total: Double(batchTotal)
                )
            } else {
                ProgressView(t.string(.transformationRunningStatus))
            }
            if !resultBody.isEmpty {
                ScrollView {
                    Text(resultBody)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.string(.aiToolsEmptyTitle)).font(.headline)
                    Text(t.string(.aiToolsEmptyBody))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func singleSavedSection(noteId: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let title = (try? store.note(id: noteId))?.title ?? ""
                Text(String(format: t.string(.aiToolsResultSavedFormat), title))
                    .font(.callout)
                Spacer()
                Button(t.string(.aiToolsOpenNoteButton)) {
                    tabSwitch.request(.notes)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        noteJump.request(noteId: noteId)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Text(t.string(.transformationResultTitle)).font(.headline)
            ScrollView {
                Text(resultBody)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func batchSavedToast(count: Int) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(String(format: t.string(.aiToolsBatchSavedFormat), count))
                .font(.headline)
            Spacer()
            Button(t.string(.aiToolsOpenNoteButton)) {
                tabSwitch.request(.notes)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @MainActor
    private func reload() async {
        do {
            transformations = try store.transformations()
            sources = try store.sources(notebookId: notebook.id!)
            if selectedTransformationId == nil { selectedTransformationId = transformations.first?.id }
            if selectedSourceId == nil          { selectedSourceId         = sources.first?.id }
            if let tx = selectedTransformation, tx.scope == .notebook { scope = .notebook }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func run() async {
        guard let tid = selectedTransformationId else { return }
        running = true; errorMessage = nil
        resultBody = ""; resultNoteId = nil
        batchSavedCount = nil; batchCompleted = 0; batchTotal = 0
        defer { running = false }

        do {
            switch scope {
            case .source:
                guard let sid = selectedSourceId else { return }
                let note = try await transformationHolder.engine.run(
                    transformationId: tid, sourceId: sid
                ) { token in
                    Task { @MainActor in resultBody += token }
                }
                resultNoteId = note.id
            case .notebook:
                let note = try await transformationHolder.engine.runNotebookScope(
                    transformationId: tid, notebookId: notebook.id!
                ) { token in
                    Task { @MainActor in resultBody += token }
                }
                resultNoteId = note.id
            case .allSources:
                batchTotal = sources.count
                let notes = try await transformationHolder.engine.runOnAllSources(
                    transformationId: tid, notebookId: notebook.id!
                ) { done, total in
                    Task { @MainActor in
                        batchCompleted = done
                        batchTotal = total
                    }
                }
                batchSavedCount = notes.count
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
