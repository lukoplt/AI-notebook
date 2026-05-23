import SwiftUI
import AINotebookCore

struct DetectOllamaStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: viewModel.isOllamaReachable ? "checkmark.circle.fill" : "cloud.bolt")
                .font(.system(size: 48))
                .foregroundStyle(viewModel.isOllamaReachable ? .green : .secondary)
            Text(settings.text.string(.onboardingDetectTitle))
                .font(.title).bold()
            Text(settings.text.string(.onboardingDetectBody))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.isOllamaReachable {
                Text(settings.text.string(.onboardingDetectFound))
                    .foregroundStyle(.green)
                Button(settings.text.string(.continueLabel)) {
                    viewModel.stopDetectionPolling()
                    viewModel.advance()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            } else {
                ProgressView()
                Text(settings.text.string(.onboardingDetectWaiting))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Button(settings.text.string(.openOllamaDownload)) {
                    viewModel.openOllamaDownloadPage()
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.startDetectionPolling() }
        .onDisappear { viewModel.stopDetectionPolling() }
    }
}
