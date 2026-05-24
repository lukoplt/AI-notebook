import SwiftUI
import AppKit
import AINotebookCore

struct CitationPopover: View {

    let citation: Citation
    let sourceTitle: String
    let pageHint: Int?
    let pdfFileURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.opening")
                Text(sourceTitle).font(.headline)
                Spacer()
                if let page = pageHint, let url = pdfFileURL {
                    Button("Open page \(page)") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Divider()
            ScrollView {
                Text(citation.snippet)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 400)
    }
}
