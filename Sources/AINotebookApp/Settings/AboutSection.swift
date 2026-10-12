import AINotebookCore
import AppKit
import SwiftUI

/// About: version, license, third-party notices, credits.
struct AboutSection: View {
    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }
    private static let repository = "https://github.com/lukoplt/AI-notebook"

    var body: some View {
        SettingsGroup {
            LabeledContent(t.string(.version)) {
                Text(AINotebookVersion).monospacedDigit().tokenForeground(.text2)
            }
            Hairline()
            HStack(spacing: DesignTokens.spacing(16)) {
                link(t.string(.aboutLicense), path: "/blob/main/LICENSE")
                link(t.string(.aboutNotice), path: "/blob/main/NOTICE")
                link(t.string(.aboutSourceCode), path: "")
            }
            Text(t.string(.aboutCredits)).tokenFont(.caption).tokenForeground(.text3)
        }
    }

    private func link(_ title: String, path: String) -> some View {
        Button(title) {
            if let url = URL(string: Self.repository + path) { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(QuietButtonStyle(token: .focus))
    }
}
