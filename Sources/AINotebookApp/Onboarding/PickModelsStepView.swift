import SwiftUI
import AINotebookCore

struct PickModelsStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    private let chatChoices = ["llama3.2:3b", "llama3.1:8b", "mistral:7b"]
    private let embedChoices = ["nomic-embed-text", "mxbai-embed-large"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(settings.text.string(.onboardingPickModelsTitle))
                .font(.title).bold()
            Text(settings.text.string(.onboardingPickModelsBody))
                .foregroundStyle(.secondary)

            Picker(settings.text.string(.chatModel), selection: $settings.selectedChatModel) {
                ForEach(chatChoices, id: \.self) { Text($0).tag($0) }
            }
            Picker(settings.text.string(.embeddingModel), selection: $settings.selectedEmbeddingModel) {
                ForEach(embedChoices, id: \.self) { Text($0).tag($0) }
            }

            Spacer()
            HStack {
                Spacer()
                Button(settings.text.string(.continueLabel)) {
                    viewModel.advance()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
