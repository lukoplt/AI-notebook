import SwiftUI
import AINotebookCore

struct DoneStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: DesignTokens.spacing(16)) {
            OnboardingIcon(systemName: DesignTokens.icon(.success), color: .success)
            Text(settings.text.string(.onboardingDoneTitle))
                .tokenFont(.title)
                .tokenForeground(.text1)
            Text(settings.text.string(.onboardingDoneBody))
                .tokenFont(.body)
                .tokenForeground(.text2)
                .multilineTextAlignment(.center)
            Button(settings.text.string(.startUsingApp)) {
                viewModel.markCompleted()
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
            .padding(.top, DesignTokens.spacing(8))
        }
    }
}
