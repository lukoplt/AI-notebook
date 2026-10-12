import SwiftUI
import AINotebookCore

struct DetectOllamaStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: DesignTokens.spacing(16)) {
            OnboardingIcon(systemName: viewModel.isOllamaReachable ? DesignTokens.icon(.success) : "cloud.bolt",
                           color: viewModel.isOllamaReachable ? .success : .text2)
            Text(settings.text.string(.onboardingDetectTitle))
                .tokenFont(.title)
                .tokenForeground(.text1)
            Text(settings.text.string(.onboardingDetectBody))
                .tokenFont(.body)
                .tokenForeground(.text2)
                .multilineTextAlignment(.center)

            if viewModel.isOllamaReachable {
                Text(settings.text.string(.onboardingDetectFound))
                    .tokenFont(.body)
                    .tokenForeground(.success)
                Button(settings.text.string(.continueLabel)) {
                    viewModel.stopDetectionPolling()
                    viewModel.advance()
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            } else {
                ProgressView().controlSize(.small)
                Text(settings.text.string(.onboardingDetectWaiting))
                    .tokenFont(.caption)
                    .tokenForeground(.text3)
                Button(settings.text.string(.openOllamaDownload)) {
                    viewModel.openOllamaDownloadPage()
                }
                .buttonStyle(.secondary)
            }
        }
        .onAppear { viewModel.startDetectionPolling() }
        .onDisappear { viewModel.stopDetectionPolling() }
    }
}
