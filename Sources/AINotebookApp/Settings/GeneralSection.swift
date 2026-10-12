import AINotebookCore
import SwiftUI

/// General: language, web search, updates.
struct GeneralSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updates: UpdateService

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(24)) {
            SettingsGroup(t.string(.language)) {
                Picker(t.string(.language), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SettingsGroup(t.string(.composerWebSearch)) {
                Toggle(t.string(.webSearchToggle), isOn: $settings.webSearchEnabled)
            }
            SettingsGroup(t.string(.settingsUpdates)) {
                Toggle(t.string(.updateAutoCheckToggle), isOn: $settings.autoCheckUpdates)
                HStack(spacing: DesignTokens.spacing(8)) {
                    Button(t.string(.updateCheckNowButton)) { Task { await updates.checkNow() } }
                        .buttonStyle(.secondary)
                        .disabled(updates.status == .checking)
                    Text(updateStatusText).tokenFont(.caption).tokenForeground(.text2)
                }
            }
        }
    }

    private var updateStatusText: String {
        switch updates.status {
        case .idle: ""
        case .checking: t.string(.updateStatusChecking)
        case .upToDate: t.string(.updateStatusUpToDate)
        case .available(let info): String(format: t.string(.updateStatusAvailable), info.latestVersion)
        case .failed: t.string(.updateStatusFailed)
        }
    }
}
