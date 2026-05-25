import SwiftUI
import AINotebookCore

struct TransformationPromptPreviewSheet: View {

    let transformation: Transformation
    let source: Source?
    @Binding var isPresented: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @State private var rendered: String = ""
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.aiToolsPromptPreviewTitle)).font(.title2).bold()
            Text(transformation.name).font(.headline)
            if !transformation.description.isEmpty {
                Text(transformation.description)
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(rendered.isEmpty ? transformation.promptTemplate : rendered)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 360)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .task { await render() }
    }

    @MainActor
    private func render() async {
        guard let source = source else {
            rendered = transformation.promptTemplate
            return
        }
        do {
            let chunks = try store.chunks(sourceId: source.id!)
            let sourceText = chunks.map(\.text).joined(separator: "\n\n")
            rendered = transformation.promptTemplate
                .replacingOccurrences(of: "{{source_text}}", with: sourceText)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
