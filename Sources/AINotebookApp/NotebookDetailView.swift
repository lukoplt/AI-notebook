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

            placeholder
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

    private var placeholder: some View {
        VStack(spacing: 8) {
            Text(settings.text.string(.comingSoon))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(comingSoonMessage)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comingSoonMessage: String {
        switch selectedTab {
        case .sources:         settings.text.string(.sourcesTabComingSoon)
        case .chat:            settings.text.string(.chatTabComingSoon)
        case .notes:           settings.text.string(.notesTabComingSoon)
        case .transformations: settings.text.string(.transformationsTabComingSoon)
        }
    }
}
