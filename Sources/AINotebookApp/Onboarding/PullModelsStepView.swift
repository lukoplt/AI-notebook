import SwiftUI
import AINotebookCore

struct PullModelsStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(16)) {
            Text(settings.text.string(.onboardingPullTitle))
                .tokenFont(.title)
                .tokenForeground(.text1)
            Text(settings.text.string(.onboardingPullBody))
                .tokenFont(.body)
                .tokenForeground(.text2)

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
                Label(error, systemImage: DesignTokens.icon(.warning))
                    .tokenFont(.body)
                    .tokenForeground(.danger)
            }
        }
        .task { await viewModel.runModelPulls() }
    }

    private func modelProgress(title: String, fraction: Double?, status: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
            Text(title).tokenFont(.headline).tokenForeground(.text1)
            ProgressView(value: fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(DesignTokens.color(.accent))
            Text(status)
                .tokenFont(.caption)
                .tokenForeground(.text3)
        }
    }
}
