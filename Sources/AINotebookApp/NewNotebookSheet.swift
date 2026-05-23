import SwiftUI
import AINotebookCore

struct NewNotebookSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var errorMessage: String?

    /// Called with the freshly created notebook so the parent view can
    /// select it.
    var onCreated: (Notebook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.text.string(.createNotebook))
                .font(.title3)
                .bold()

            TextField(settings.text.string(.notebookName), text: $name)
                .textFieldStyle(.roundedBorder)

            TextField(
                settings.text.string(.notebookDescription),
                text: $description,
                axis: .vertical
            )
            .lineLimit(3, reservesSpace: true)
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
                Button(settings.text.string(.create)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func submit() {
        do {
            let created = try store.createNotebook(name: name, description: description)
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? settings.text.string(.cannotBeEmpty)
        }
    }
}
