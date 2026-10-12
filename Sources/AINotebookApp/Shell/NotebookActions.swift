import AINotebookCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Notebook-level commands formerly in the notebook header (spec §2.7): export
/// ZIP, database backup and restore. Each returns a status line for an alert.
@MainActor
enum NotebookActions {
    static func savePanelURL(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func exportZip(_ notebook: Notebook, store: NotebookStore, text: AppText) -> String? {
        guard let url = savePanelURL(suggestedName: "\(notebook.name).zip", type: .zip) else { return nil }
        do {
            try ExportService.exportNotebookZip(notebookId: notebook.id ?? -1, store: store, to: url)
            return text.string(.exportDone)
        } catch { return error.localizedDescription }
    }

    static func backup(store: NotebookStore, text: AppText) -> String? {
        let type = UTType(filenameExtension: "sqlite") ?? .data
        guard let url = savePanelURL(suggestedName: "ainotebook-backup.sqlite", type: type) else { return nil }
        do {
            try store.backupDatabase(to: url)
            return text.string(.exportDone)
        } catch { return error.localizedDescription }
    }

    /// Asks for the backup file; the caller confirms before `restore(from:)`.
    static func chooseRestoreFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func restore(from url: URL, store: NotebookStore, text: AppText) -> String {
        do {
            try store.restoreDatabase(from: url)
            return text.string(.exportDone)
        } catch { return error.localizedDescription }
    }

    /// Source files picked in an open panel (the formats the ingester reads).
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .pdf, .plainText,
            UTType("net.daringfireball.markdown") ?? .plainText,
            UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
            UTType("org.openxmlformats.presentationml.presentation") ?? .data,
            UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data,
        ] + SourceType.extraFileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// "Open a folder as a notebook": a new notebook named after the folder,
    /// with the folder added (and watched by the folder runtime).
    static func openFolderAsNotebook(store: NotebookStore, runtime: FolderIngestionRuntime?) async throws -> Int64? {
        guard let url = chooseFolder() else { return nil }
        let notebook = try store.createNotebook(name: url.lastPathComponent, description: "")
        guard let id = notebook.id else { return nil }
        if let runtime { _ = try await runtime.addFolder(notebookId: id, url: url) }
        return id
    }

    /// A folder picked in an open panel (directories only).
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Per-notebook instructions (C1), formerly a header popover.
struct NotebookInstructionsSheet: View {
    let notebook: Notebook
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(12)) {
            Text(t.string(.notebookInstructions)).tokenFont(.headline).tokenForeground(.text1)
            Text(notebook.name).tokenFont(.caption).tokenForeground(.text3)
            Text(t.string(.notebookInstructionsHint)).tokenFont(.caption).tokenForeground(.text2)
            TextEditor(text: $text)
                .tokenFont(.body)
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.spacing(8))
                .frame(minHeight: 160)
                .card(radius: .sm)
            HStack {
                Spacer()
                Button(t.string(.cancel)) { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(t.string(.save)) {
                    try? store.updateNotebookInstructions(id: notebook.id ?? -1, instructions: text)
                    dismiss()
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.spacing(24))
        .frame(width: 460)
        .background(DesignTokens.color(.surface1))
        .task { text = (try? store.notebookInstructions(id: notebook.id ?? -1)) ?? "" }
    }
}
