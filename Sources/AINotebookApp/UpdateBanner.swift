import SwiftUI
import AINotebookCore

/// Non-modal top bar shown in the main window when an update is available.
struct UpdateBanner: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updates: UpdateService

    let info: UpdateInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
            Text(String(format: settings.text.string(.updateBannerTitle), info.latestVersion))
            Spacer()
            Button(settings.text.string(.updateDownloadButton)) {
                if let url = URL(string: info.downloadURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button(settings.text.string(.updateLaterButton)) {
                updates.bannerDismissed = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary)
    }
}
