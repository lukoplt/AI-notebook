import SwiftUI
import AINotebookCore

struct PickModelsStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    private let chatChoices = ["llama3.2:3b", "llama3.1:8b", "mistral:7b"]
    private let embedChoices = ["nomic-embed-text", "mxbai-embed-large"]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(16)) {
            Text(settings.text.string(.onboardingPickModelsTitle))
                .tokenFont(.title)
                .tokenForeground(.text1)
            Text(settings.text.string(.onboardingPickModelsBody))
                .tokenFont(.body)
                .tokenForeground(.text2)
            Picker(settings.text.string(.chatModel), selection: $settings.selectedChatModel) {
                ForEach(chatChoices, id: \.self) { Text($0).tag($0) }
            }
            Picker(settings.text.string(.embeddingModel), selection: $settings.selectedEmbeddingModel) {
                ForEach(embedChoices, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Spacer()
                Button(settings.text.string(.continueLabel)) {
                    viewModel.advance()
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, DesignTokens.spacing(8))
        }
        .tokenFont(.body)
    }
}
