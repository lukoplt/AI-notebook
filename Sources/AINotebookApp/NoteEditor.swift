import SwiftUI
import AINotebookCore

struct NoteEditor: View {
    @Binding var title: String
    @Binding var bodyMd: String
    let language: AppLanguage
    let onSave: () -> Void

    private var t: AppText { AppText(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(t.string(.noteTitlePlaceholder), text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            TextEditor(text: $bodyMd)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if bodyMd.isEmpty {
                        Text(t.string(.noteBodyPlaceholder))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button("Save") { onSave() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }
}
