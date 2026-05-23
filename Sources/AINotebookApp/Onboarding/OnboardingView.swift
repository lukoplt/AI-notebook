import SwiftUI
import AINotebookCore

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
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
}
