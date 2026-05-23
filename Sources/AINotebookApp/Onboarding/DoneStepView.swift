import SwiftUI
import AINotebookCore

struct DoneStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(settings.text.string(.onboardingDoneTitle))
                .font(.largeTitle).bold()
            Text(settings.text.string(.onboardingDoneBody))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button(settings.text.string(.startUsingApp)) {
                viewModel.markCompleted()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(40)
    }
}
