import SwiftUI
import AINotebookCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(settings.text.string(.settings))
                .font(.title2)
                .bold()

            Picker(settings.text.string(.language), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(settings.text.string(.version))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(AINotebookVersion)
                    .monospacedDigit()
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 280)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings(
            defaults: UserDefaults(suiteName: "preview-settings")!,
            preferredLanguages: ["en-US"]
        ))
}
