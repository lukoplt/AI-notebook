import SwiftUI
import AINotebookCore

struct WelcomeStepView: View {
    @EnvironmentObject private var settings: AppSettings
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.spacing(16)) {
            OnboardingIcon(systemName: "sparkles", color: .text1)
            Text(settings.text.string(.welcome))
                .tokenFont(.title)
                .tokenForeground(.text1)
            Text(settings.text.string(.welcomeBody))
                .tokenFont(.body)
                .tokenForeground(.text2)
                .multilineTextAlignment(.center)
            Button(settings.text.string(.continueLabel), action: onContinue)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .padding(.top, DesignTokens.spacing(8))
        }
    }
}
