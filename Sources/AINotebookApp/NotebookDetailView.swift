import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AINotebookCore

struct NotebookDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tabSwitch: TabSwitchCoordinator
    @EnvironmentObject private var store: NotebookStore

    let notebook: Notebook
    @State private var selectedTab: Tab = .sources

    // C1 — per-notebook instructions popover.
    @State private var showInstructions = false
    @State private var instructionsText = ""
    // B2/B3 — export / backup status + restore confirm.
    @State private var exportStatus: String?
    @State private var showRestoreConfirm = false
    @State private var pendingRestoreURL: URL?

    enum Tab: Hashable {
        case sources, chat, notes, transformations
    }

    private func mapTab(_ t: TabSwitchCoordinator.Tab) -> Tab {
        switch t {
        case .sources:         return .sources
        case .chat:            return .chat
        case .notes:           return .notes
        case .transformations: return .transformations
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Picker("", selection: $selectedTab) {
                Text(settings.text.string(.sources)).tag(Tab.sources)
                Text(settings.text.string(.chat)).tag(Tab.chat)
                Text(settings.text.string(.notes)).tag(Tab.notes)
                Text(settings.text.string(.transformations)).tag(Tab.transformations)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            Divider()
                .padding(.top, 12)

            Group {
                switch selectedTab {
                case .sources:
                    SourceListView(notebook: notebook)
                case .chat:
                    ChatView(notebook: notebook)
                case .notes:
                    NotesView(notebook: notebook)
                case .transformations:
                    TransformationsView(notebook: notebook)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(tabSwitch.$target.compactMap { $0 }) { t in
            selectedTab = mapTab(t)
            tabSwitch.clear()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(notebook.name)
                    .font(.title)
                    .bold()
                if !notebook.description.isEmpty {
                    Text(notebook.description)
                        .foregroundStyle(.secondary)
                }
                Text(notebook.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            headerActions
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if let status = exportStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            // C1 — instructions
            Button {
                instructionsText = (try? store.notebookInstructions(id: notebook.id ?? -1)) ?? ""
                showInstructions = true
            } label: {
                Image(systemName: "text.badge.star")
            }
            .help(settings.text.string(.notebookInstructions))
            .popover(isPresented: $showInstructions, arrowEdge: .bottom) {
                instructionsEditor
            }

            // B2/B3 — export & backup
            Menu {
                Button(settings.text.string(.exportNotebookZip)) { exportNotebookZip() }
                Divider()
                Button(settings.text.string(.backupDatabase)) { backupDatabase() }
                Button(settings.text.string(.restoreDatabase)) { chooseRestore() }
            } label: {
                Label(settings.text.string(.exportBackupMenu), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .alert(settings.text.string(.restoreDatabase), isPresented: $showRestoreConfirm) {
            Button(settings.text.string(.cancel), role: .cancel) { pendingRestoreURL = nil }
            Button(settings.text.string(.restoreDatabase), role: .destructive) { performRestore() }
        } message: {
            Text(settings.text.string(.restoreConfirm))
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.text.string(.notebookInstructions)).font(.headline)
            Text(settings.text.string(.notebookInstructionsHint))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $instructionsText)
                .frame(width: 360, height: 140)
                .border(.quaternary)
            HStack {
                Spacer()
                Button(settings.text.string(.save)) {
                    try? store.updateNotebookInstructions(id: notebook.id ?? -1, instructions: instructionsText)
                    showInstructions = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Export / backup actions

    private func savePanelURL(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportNotebookZip() {
        guard let url = savePanelURL(suggestedName: "\(notebook.name).zip", type: .zip) else { return }
        do {
            try ExportService.exportNotebookZip(notebookId: notebook.id ?? -1, store: store, to: url)
            exportStatus = settings.text.string(.exportDone)
        } catch { exportStatus = error.localizedDescription }
    }

    private func backupDatabase() {
        guard let url = savePanelURL(suggestedName: "ainotebook-backup.sqlite", type: .init(filenameExtension: "sqlite") ?? .data) else { return }
        do {
            try store.backupDatabase(to: url)
            exportStatus = settings.text.string(.exportDone)
        } catch { exportStatus = error.localizedDescription }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
        showRestoreConfirm = true
    }

    private func performRestore() {
        guard let url = pendingRestoreURL else { return }
        pendingRestoreURL = nil
        do {
            try store.restoreDatabase(from: url)
            exportStatus = settings.text.string(.exportDone)
        } catch { exportStatus = error.localizedDescription }
    }
}
