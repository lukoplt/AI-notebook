import SwiftUI
import AINotebookCore

/// First-run flow (spec §2.6): same steps, shown as a centered card (max 520)
/// with token styling and a monochrome primary button.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        ZStack {
            DesignTokens.color(.bg).ignoresSafeArea()
            Group {
                switch viewModel.step {
                case .welcome:
                    WelcomeStepView { viewModel.advance() }
                case .detectOllama:
                    DetectOllamaStepView(viewModel: viewModel)
                case .pickModels:
                    PickModelsStepView(viewModel: viewModel)
                case .pullModels:
                    PullModelsStepView(viewModel: viewModel)
                case .done:
                    DoneStepView(viewModel: viewModel)
                }
            }
            .padding(DesignTokens.spacing(32))
            .frame(maxWidth: DesignTokens.size(.onboardingCardMax))
            .card(radius: .lg)
            .padding(DesignTokens.spacing(32))
        }
    }
}

/// Large step icon (token colour, size derived from the top-bar icon token).
struct OnboardingIcon: View {
    let systemName: String
    var color: DesignTokens.ColorToken = .text2

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: DesignTokens.size(.iconTopBar) * 2, weight: .light))
            .tokenForeground(color)
            .accessibilityHidden(true)
    }
}
