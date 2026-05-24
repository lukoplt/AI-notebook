// Sources/AINotebookApp/MessageBubble.swift
import SwiftUI
import AINotebookCore

struct MessageBubble: View {

    let message: ChatMessage
    let language: AppLanguage
    let onCitationTapped: (Citation) -> Void

    private var t: AppText { AppText(language: language) }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if !message.citations.isEmpty {
                    citationChips
                }
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
        .padding(.vertical, 4)
    }

    private var citationChips: some View {
        HStack(spacing: 6) {
            ForEach(message.citations, id: \.marker) { c in
                Button {
                    onCitationTapped(c)
                } label: {
                    Text("[\(c.marker)]")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.20))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
