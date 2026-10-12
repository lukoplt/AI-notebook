import AINotebookCore
import SwiftUI

/// Settings sections (spec §2.5).
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, providers, modelsLimits, indexing, tools, about
    var id: String { rawValue }

    var icon: DesignTokens.Icon {
        switch self {
        case .general: .settings
        case .providers: .providers
        case .modelsLimits: .modelsLimits
        case .indexing: .indexing
        case .tools: .runTool
        case .about: .info
        }
    }

    func title(_ t: AppText) -> String {
        switch self {
        case .general: t.string(.settingsGeneral)
        case .providers: t.string(.providersSectionTitle)
        case .modelsLimits: t.string(.settingsModelsLimits)
        case .indexing: t.string(.settingsIndexing)
        case .tools: t.string(.settingsTools)
        case .about: t.string(.settingsAbout)
        }
    }

    /// Remembered selection; other windows (e.g. "Edit templates") preselect it.
    static let storageKey = "ui.settings.section"
}

/// The Settings window (⌘, and the sidebar): section list on the left,
/// section content (max 640) on the right.
struct SettingsWindowView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var routerHolder: ProviderRouterHolder
    @EnvironmentObject private var folderWatch: FolderWatchController

    @AppStorage(SettingsSection.storageKey) private var sectionRaw = SettingsSection.general.rawValue
    @State private var model = SettingsModel()

    private var t: AppText { settings.text }
    private var section: SettingsSection { SettingsSection(rawValue: sectionRaw) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    Button { sectionRaw = item.rawValue } label: {
                        SidebarRow(title: item.title(t), icon: item.icon, isSelected: item == section)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(DesignTokens.spacing(12))
            .frame(width: DesignTokens.size(.sidebarMin) - DesignTokens.spacing(32))
            .background(DesignTokens.color(.bgSidebar))
            Rectangle().fill(DesignTokens.color(.border)).frame(width: DesignTokens.size(.borderWidth))
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacing(24)) {
                    Text(section.title(t)).tokenFont(.title).tokenForeground(.text1)
                    content
                    if let error = model.settingsError {
                        SettingsErrorText(error)
                    }
                }
                .frame(maxWidth: DesignTokens.size(.settingsContentMax), alignment: .leading)
                .padding(DesignTokens.spacing(32))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DesignTokens.color(.bg))
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 680)
        .tokenFont(.body)
        .task {
            model.start(.init(settings: settings, store: store, routerHolder: routerHolder, folderWatch: folderWatch))
        }
        .onDisappear { model.stop() }
        .onChange(of: settings.selectedChatProviderId) { _, _ in model.chatProviderChanged() }
        .onChange(of: settings.selectedChatModel) { _, value in model.chatModelChanged(value) }
        .onChange(of: settings.selectedEmbeddingProviderId) { _, _ in model.embeddingProviderChanged() }
        .onChange(of: settings.selectedEmbeddingModel) { _, value in model.embeddingModelChanged(value) }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSection()
        case .providers: ProvidersSection(model: model)
        case .modelsLimits: ModelsLimitsSection(model: model)
        case .indexing: IndexingSection(model: model)
        case .tools: ToolsSection()
        case .about: AboutSection()
        }
    }
}

/// A titled group inside a settings section.
struct SettingsGroup<Content: View>: View {
    let title: String?
    var footnote: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(12)) {
            if let title {
                Text(title).tokenFont(.headline).tokenForeground(.text1)
            }
            VStack(alignment: .leading, spacing: DesignTokens.spacing(12)) {
                content()
            }
            .padding(DesignTokens.spacing(16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: .md)
            if let footnote {
                Text(footnote)
                    .tokenFont(.caption)
                    .tokenForeground(.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsErrorText: View {
    let value: String
    init(_ value: String) { self.value = value }

    var body: some View {
        Label(value, systemImage: DesignTokens.icon(.warning))
            .tokenFont(.caption)
            .tokenForeground(.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}
