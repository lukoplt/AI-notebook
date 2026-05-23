import SwiftUI
import AINotebookCore

struct WelcomeStepView: View {
    @EnvironmentObject private var settings: AppSettings
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(settings.text.string(.welcome))
                .font(.largeTitle).bold()
            Text(settings.text.string(.welcomeBody))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button(settings.text.string(.continueLabel), action: onContinue)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(40)
    }
}
