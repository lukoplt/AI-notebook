import AINotebookCore
import SwiftUI

/// The chat composer (spec §2.2): text area, "+" menu, scope / persona /
/// model chips, context preview (eye) and send.
struct ChatComposer: View {
    @Bindable var model: ChatViewModel
    let nav: NavigationState
    let notebookId: Int64
    var autoFocus = false
    /// New-chat state: quiet "Add folder · Add file · New note" under the composer.
    var showsQuickActions = false

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ingestion: IngestionServiceHolder
    @EnvironmentObject private var folderWatch: FolderWatchController

    @State private var showingAddURL = false
    @State private var transformations: [Transformation] = []
    @State private var actionError: String?
    @State private var composerWidth: CGFloat = 760

    /// Composer widths below which chip labels shorten (model only, then icons).
    private static let fullChipsWidth = DesignTokens.size(.conversationMax) - DesignTokens.spacing(32) * 4
    private static let compactChipsWidth = DesignTokens.size(.panelMax) + DesignTokens.spacing(32)

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            if model.isEditing {
                HStack(spacing: DesignTokens.spacing(4)) {
                    Label(t.string(.composerEditing), systemImage: DesignTokens.icon(.edit))
                        .tokenFont(.caption)
                        .tokenForeground(.text2)
                    IconButton(icon: .close, label: t.string(.cancel)) { model.cancelEditing() }
                }
            }
            ComposerView(text: $model.input, placeholder: t.string(.composerPlaceholder),
                         isSending: model.sending, autoFocus: autoFocus,
                         onSubmit: { if model.canSend { Task { await model.send() } } }) {
                plusMenu
                // Full chips when the column is wide, shorter labels when narrow.
                chips(compactModel: composerWidth < Self.fullChipsWidth,
                      compactAll: composerWidth < Self.compactChipsWidth)
            } trailing: {
                IconButton(icon: .previewContext, label: t.string(.composerPreviewContext)) {
                    model.startPreparingDraft()
                    nav.showPanel(.context)
                }
                .disabled(!model.canPreview)
                SendButton(isSending: model.sending, isEnabled: model.canSend, label: t.string(.chatSendButton),
                           stopLabel: t.string(.chatStopButton), onStop: { model.stop() }) {
                    Task { await model.send() }
                }
            }
            if showsQuickActions {
                HStack(spacing: DesignTokens.spacing(16)) {
                    quickAction(t.string(.addFolderButton), icon: .addFolder, action: addFolder)
                    quickAction(t.string(.composerAddFile), icon: .addFile, action: addFiles)
                    quickAction(t.string(.notesNewButton), icon: .note, action: newNote)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, DesignTokens.spacing(8))
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { composerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in composerWidth = width }
        })
        .task(id: notebookId) { transformations = (try? store.transformations()) ?? [] }
        .sheet(isPresented: $showingAddURL) {
            AddSourceSheet(notebookId: notebookId, language: settings.language, ingestion: ingestion.service,
                           isPresented: $showingAddURL, initialTab: .url)
        }
        .sheet(isPresented: $model.showNewPersona) {
            NewPersonaSheet(model: model).environmentObject(settings)
        }
        .alert(actionError ?? "", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button(t.string(.doneButton)) { actionError = nil }
        }
    }

    private func chips(compactModel: Bool, compactAll: Bool) -> some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            ScopeChip(model: model, scope: model.scope, compact: compactAll)
            PersonaChip(model: model, compact: compactAll)
            ModelChip(model: model, compact: compactModel)
        }
    }

    private var plusMenu: some View {
        IconMenu(icon: .add, label: t.string(.composerAdd)) {
            Button { addFiles() } label: {
                Label(t.string(.composerAddFile), systemImage: DesignTokens.icon(.addFile))
            }
            Button { addFolder() } label: {
                Label(t.string(.addFolderButton), systemImage: DesignTokens.icon(.addFolder))
            }
            Button { showingAddURL = true } label: {
                Label(t.string(.composerAddUrl), systemImage: DesignTokens.icon(.addUrl))
            }
            Divider()
            // E3 — per-message web search, only when enabled in Settings.
            if settings.webSearchEnabled {
                Toggle(isOn: $model.useWebForNextMessage) {
                    Label(t.string(.composerWebSearch), systemImage: DesignTokens.icon(.webSearch))
                }
                .disabled(model.sending)
            }
            // WP8 — per-turn Overview (no query embedding).
            Toggle(isOn: $model.overviewForNextMessage) {
                Label(t.string(.composerOverviewMode), systemImage: DesignTokens.icon(.overview))
            }
            .disabled(model.sending)
            Divider()
            Menu {
                Button(t.string(.composerRunTool) + "…") { nav.runToolRequest = RunToolRequest(transformationId: nil) }
                Divider()
                ForEach(transformations) { tx in
                    Button(tx.name) { nav.runToolRequest = RunToolRequest(transformationId: tx.id) }
                }
            } label: {
                Label(t.string(.composerRunTool), systemImage: DesignTokens.icon(.runTool))
            }
            Button { newNote() } label: {
                Label(t.string(.notesNewButton), systemImage: DesignTokens.icon(.note))
            }
            Button { model.showNewPersona = true } label: {
                Label(t.string(.personaNew), systemImage: DesignTokens.icon(.persona))
            }
        }
    }

    private func quickAction(_ title: String, icon: DesignTokens.Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: DesignTokens.icon(icon)).tokenFont(.caption)
        }
        .buttonStyle(QuietButtonStyle(token: .text3))
    }

    // MARK: Actions

    private func addFiles() {
        let urls = NotebookActions.chooseFiles()
        guard !urls.isEmpty else { return }
        nav.showPanel(.sources)
        let service = ingestion.service
        Task {
            for url in urls {
                do { _ = try await service.ingestFile(url, into: notebookId) }
                catch { actionError = String(describing: error) }
            }
            await model.loadScopeSources()
        }
    }

    private func addFolder() {
        guard let url = NotebookActions.chooseFolder() else { return }
        nav.showPanel(.sources)
        let runtime = folderWatch.runtime
        Task {
            do { _ = try await runtime?.addFolder(notebookId: notebookId, url: url) }
            catch { actionError = t.string(FolderSourcesModel.key(for: error)) }
            await model.loadScopeSources()
        }
    }

    private func newNote() {
        do {
            let note = try store.createNote(notebookId: notebookId, title: t.string(.noteUntitled), bodyMd: "")
            if let id = note.id { nav.openNote(notebookId: notebookId, noteId: id) }
        } catch {
            actionError = String(describing: error)
        }
    }
}
