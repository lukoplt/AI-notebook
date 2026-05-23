import SwiftUI
import AINotebookCore

struct RenameNotebookSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss

    let notebook: Notebook
    @State private var name: String
    @State private var errorMessage: String?

    init(notebook: Notebook) {
        self.notebook = notebook
        _name = State(initialValue: notebook.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.text.string(.renameNotebook))
                .font(.title3)
                .bold()

            TextField(settings.text.string(.notebookName), text: $name)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(settings.text.string(.cancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.text.string(.save)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || name == notebook.name)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func submit() {
        guard let id = notebook.id else { return }
        do {
            _ = try store.renameNotebook(id: id, newName: name)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? settings.text.string(.cannotBeEmpty)
        }
    }
}
