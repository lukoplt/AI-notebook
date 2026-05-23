import SwiftUI
import AINotebookCore

struct SidebarView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @Binding var selection: Int64?

    @State private var showNewSheet = false
    @State private var notebookToRename: Notebook?
    @State private var notebookToDelete: Notebook?
    @State private var deleteError: String?

    var body: some View {
        List(selection: $selection) {
            Section(settings.text.string(.notebooks)) {
                ForEach(store.notebooks) { notebook in
                    if let id = notebook.id {
                        Text(notebook.name)
                            .tag(id)
                            .contextMenu {
                                Button(settings.text.string(.renameNotebook)) {
                                    notebookToRename = notebook
                                }
                                Button(role: .destructive) {
                                    notebookToDelete = notebook
                                } label: {
                                    Text(settings.text.string(.deleteNotebook))
                                }
                            }
                    }
                }
            }
        }
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItem {
                Button {
                    showNewSheet = true
                } label: {
                    Label(settings.text.string(.createNotebook), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewNotebookSheet { created in
                selection = created.id
            }
            .environmentObject(settings)
            .environmentObject(store)
        }
        .sheet(item: $notebookToRename) { notebook in
            RenameNotebookSheet(notebook: notebook)
                .environmentObject(settings)
                .environmentObject(store)
        }
        .alert(
            settings.text.string(.deleteNotebook),
            isPresented: deleteAlertBinding,
            presenting: notebookToDelete
        ) { notebook in
            Button(settings.text.string(.delete), role: .destructive) {
                performDelete(notebook)
            }
            Button(settings.text.string(.cancel), role: .cancel) {
                notebookToDelete = nil
            }
        } message: { _ in
            Text(settings.text.string(.confirmDeleteNotebook))
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { notebookToDelete != nil },
            set: { if !$0 { notebookToDelete = nil } }
        )
    }

    private func performDelete(_ notebook: Notebook) {
        defer { notebookToDelete = nil }
        guard let id = notebook.id else { return }
        do {
            try store.deleteNotebook(id: id)
            if selection == id { selection = nil }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
