import SwiftUI
import AINotebookCore

struct NotebookDetailView: View {
    @EnvironmentObject private var settings: AppSettings

    let notebook: Notebook
    @State private var selectedTab: Tab = .sources

    enum Tab: Hashable {
        case sources, chat, notes, transformations
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
    }

    private var header: some View {
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
    }
}
