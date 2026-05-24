// Sources/AINotebookApp/CitationPopover.swift
import SwiftUI
import AINotebookCore

struct CitationPopover: View {

    let citation: Citation
    let sourceTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.opening")
                Text(sourceTitle)
                    .font(.headline)
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
        .frame(width: 360)
    }
}
