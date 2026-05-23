import SwiftUI
import AINotebookCore

struct PullModelsStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(settings.text.string(.onboardingPullTitle))
                .font(.title).bold()
            Text(settings.text.string(.onboardingPullBody))
                .foregroundStyle(.secondary)

            modelProgress(
                title: settings.text.string(.onboardingPullingChat),
                fraction: viewModel.chatPullFraction,
                status: viewModel.chatPullStatus
            )
            modelProgress(
                title: settings.text.string(.onboardingPullingEmbedding),
                fraction: viewModel.embeddingPullFraction,
                status: viewModel.embeddingPullStatus
            )

            if let error = viewModel.pullError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await viewModel.runModelPulls() }
    }

    private func modelProgress(title: String, fraction: Double?, status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ProgressView(value: fraction ?? 0)
                .progressViewStyle(.linear)
            Text(status)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
