import AINotebookCore
import SwiftUI

/// "+ › Run tool" (formerly the Transformations tab): template, scope (one
/// source / whole notebook / every source), prompt preview, run with streamed
/// progress; results are saved as notes and can be opened directly.
struct RunToolSheet: View {
    let notebook: Notebook
    let preselected: Int64?
    let nav: NavigationState

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var transformationHolder: TransformationEngineHolder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    enum BatchScope: Hashable {
        case source, notebook, allSources
    }

    @State private var transformations: [Transformation] = []
    @State private var sources: [Source] = []
    @State private var selectedTransformationId: Int64?
    @State private var selectedSourceId: Int64?
    @State private var scope: BatchScope = .source
    @State private var resultBody = ""
    @State private var resultNoteId: Int64?
    @State private var batchCompleted = 0
    @State private var batchTotal = 0
    @State private var batchSavedCount: Int?
    @State private var running = false
    @State private var errorMessage: String?
    @State private var showingPreview = false
    @State private var showingHistory = false

    private var t: AppText { settings.text }

    private var selectedTransformation: Transformation? {
        transformations.first(where: { $0.id == selectedTransformationId })
    }

    private var selectedSource: Source? {
        sources.first(where: { $0.id == selectedSourceId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(16)) {
            HStack {
                Text(t.string(.composerRunTool)).tokenFont(.title).tokenForeground(.text1)
                Spacer()
                Button(t.string(.toolHistory)) { showingHistory = true }.buttonStyle(QuietButtonStyle())
                Button(t.string(.transformationEditButton)) {
                    UserDefaults.standard.set(SettingsSection.tools.rawValue, forKey: SettingsSection.storageKey)
                    openSettings()
                }
                .buttonStyle(QuietButtonStyle())
            }
            templateRow
            scopeRow
            Hairline()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let errorMessage { SettingsErrorText(errorMessage) }
            HStack {
                Spacer()
                Button(t.string(.close)) { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(t.string(.transformationRunButton)) { Task { await run() } }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(running
                              || selectedTransformationId == nil
                              || (scope == .source && selectedSourceId == nil)
                              || (scope == .allSources && sources.isEmpty))
            }
        }
        .padding(DesignTokens.spacing(24))
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 600)
        .background(DesignTokens.color(.surface1))
        .task(id: notebook.id) { reload() }
        .sheet(isPresented: $showingPreview) {
            if let tx = selectedTransformation {
                TransformationPromptPreviewSheet(transformation: tx, source: scope == .source ? selectedSource : nil,
                                                 isPresented: $showingPreview)
            }
        }
        .sheet(isPresented: $showingHistory) {
            TransformationHistorySheet(notebook: notebook, isPresented: $showingHistory)
        }
    }

    private var templateRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            HStack {
                Picker(t.string(.transformationPickerLabel), selection: $selectedTransformationId) {
                    ForEach(transformations) { tx in Text(tx.name).tag(tx.id as Int64?) }
                }
                IconButton(icon: .previewContext, label: t.string(.aiToolsPreviewButton)) { showingPreview = true }
                    .disabled(selectedTransformation == nil)
            }
            if let tx = selectedTransformation, !tx.description.isEmpty {
                Text(tx.description).tokenFont(.caption).tokenForeground(.text2)
            }
        }
        .onChange(of: selectedTransformationId) { _, _ in
            if let tx = selectedTransformation { scope = tx.scope == .notebook ? .notebook : .source }
        }
    }

    private var scopeRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            Picker(t.string(.toolScope), selection: $scope) {
                Text(t.string(.toolScopeSource)).tag(BatchScope.source)
                Text(t.string(.scopeWholeNotebook)).tag(BatchScope.notebook)
                Text(t.string(.aiToolsScopeAllSources)).tag(BatchScope.allSources)
            }
            .pickerStyle(.segmented)
            if scope == .source {
                Picker(t.string(.transformationSourcePickerLabel), selection: $selectedSourceId) {
                    ForEach(sources) { s in Text(s.title).tag(s.id as Int64?) }
                }
            }
            Text(t.string(.aiToolsScopeHint)).tokenFont(.caption).tokenForeground(.text3)
        }
    }

    @ViewBuilder
    private var content: some View {
        if running {
            VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
                if batchTotal > 0 {
                    ProgressView(String(format: t.string(.aiToolsRunningFormat), batchCompleted, batchTotal),
                                 value: Double(batchCompleted), total: Double(batchTotal))
                } else {
                    ProgressView(t.string(.transformationRunningStatus))
                }
                resultText
            }
        } else if let count = batchSavedCount, count > 1 {
            savedRow(String(format: t.string(.aiToolsBatchSavedFormat), count)) {
                nav.showPanel(.notes)
                dismiss()
            }
        } else if let noteId = resultNoteId {
            VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
                savedRow(String(format: t.string(.aiToolsResultSavedFormat), (try? store.note(id: noteId))?.title ?? "")) {
                    nav.openNote(notebookId: notebook.id ?? -1, noteId: noteId)
                    dismiss()
                }
                resultText
            }
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
                Text(t.string(.aiToolsEmptyTitle)).tokenFont(.headline).tokenForeground(.text1)
                Text(t.string(.aiToolsEmptyBody)).tokenFont(.body).tokenForeground(.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var resultText: some View {
        ScrollView {
            MarkdownView(blocks: MarkdownLite.parse(resultBody), style: .body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func savedRow(_ title: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            Label(title, systemImage: DesignTokens.icon(.success))
                .tokenFont(.body)
                .tokenForeground(.success)
            Spacer()
            Button(t.string(.aiToolsOpenNoteButton), action: open).buttonStyle(.primary)
        }
    }

    private func reload() {
        do {
            transformations = try store.transformations()
            sources = try store.sources(notebookId: notebook.id!)
            if let preselected, transformations.contains(where: { $0.id == preselected }) {
                selectedTransformationId = preselected
            } else if selectedTransformationId == nil {
                selectedTransformationId = transformations.first?.id
            }
            if selectedSourceId == nil { selectedSourceId = sources.first?.id }
            if let tx = selectedTransformation { scope = tx.scope == .notebook ? .notebook : .source }
        } catch { errorMessage = String(describing: error) }
    }

    private func run() async {
        guard let tid = selectedTransformationId, let notebookId = notebook.id else { return }
        running = true
        errorMessage = nil
        resultBody = ""
        resultNoteId = nil
        batchSavedCount = nil
        batchCompleted = 0
        batchTotal = 0
        defer { running = false }
        do {
            switch scope {
            case .source:
                guard let sid = selectedSourceId else { return }
                let note = try await transformationHolder.engine.run(transformationId: tid, sourceId: sid) { token in
                    Task { @MainActor in resultBody += token }
                }
                resultNoteId = note.id
            case .notebook:
                let note = try await transformationHolder.engine.runNotebookScope(
                    transformationId: tid, notebookId: notebookId) { token in
                    Task { @MainActor in resultBody += token }
                }
                resultNoteId = note.id
            case .allSources:
                batchTotal = sources.count
                let notes = try await transformationHolder.engine.runOnAllSources(
                    transformationId: tid, notebookId: notebookId) { done, total in
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
