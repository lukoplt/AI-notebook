import Foundation
import SwiftUI
import AINotebookCore

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome

    @Published var isOllamaReachable = false
    @Published var detectStatusMessage = ""

    @Published var chatPullFraction: Double? = nil
    @Published var chatPullStatus = ""

    @Published var embeddingPullFraction: Double? = nil
    @Published var embeddingPullStatus = ""

    @Published var pullError: String?

    private let client: OllamaClient
    private let settings: AppSettings
    private var pollTask: Task<Void, Never>?

    init(client: OllamaClient, settings: AppSettings) {
        self.client = client
        self.settings = settings
    }

    func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    // MARK: - Step 2: detect Ollama

    func startDetectionPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let up = await client.detect()
                await MainActor.run {
                    self.isOllamaReachable = up
                }
                if up { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopDetectionPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func openOllamaDownloadPage() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 4: pull models

    func runModelPulls() async {
        pullError = nil
        let chatModel = settings.selectedChatModel
        let embedModel = settings.selectedEmbeddingModel

        do {
            chatPullStatus = "Starting…"
            for try await event in client.pullModel(name: chatModel) {
                chatPullStatus = event.status
                chatPullFraction = event.fractionComplete
                if event.isTerminalSuccess { chatPullFraction = 1.0 }
            }

            embeddingPullStatus = "Starting…"
            for try await event in client.pullModel(name: embedModel) {
                embeddingPullStatus = event.status
                embeddingPullFraction = event.fractionComplete
                if event.isTerminalSuccess { embeddingPullFraction = 1.0 }
            }

            advance() // → .done
        } catch {
            pullError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func markCompleted() {
        settings.hasCompletedOnboarding = true
    }
}
