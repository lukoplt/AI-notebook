import AINotebookCore
import SwiftUI

/// Persona chip (C5): hidden when the notebook has no persona; "New persona…"
/// is also reachable from the composer "+" menu.
struct PersonaChip: View {
    let model: ChatViewModel
    /// Narrow composer: the persona name without the icon.
    var compact = false
    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }

    var body: some View {
        if !model.personas.isEmpty {
            ChipMenu(title: model.activePersona?.name ?? t.string(.personaNone), icon: compact ? nil : .persona,
                     accessibilityLabel: "\(t.string(.personaMenu)): \(model.activePersona?.name ?? t.string(.personaNone))") {
                Button { model.clearPersona() } label: {
                    if model.activePersona == nil { Label(t.string(.personaNone), systemImage: "checkmark") }
                    else { Text(t.string(.personaNone)) }
                }
                Divider()
                ForEach(model.personas) { p in
                    Button { model.applyPersona(p) } label: {
                        if model.activePersona?.id == p.id { Label(p.name, systemImage: "checkmark") }
                        else { Text(p.name) }
                    }
                }
                Divider()
                Button(t.string(.personaNew)) { model.showNewPersona = true }
            }
        }
    }
}

/// New persona form (name + instructions), presented as a sheet.
struct NewPersonaSheet: View {
    @Bindable var model: ChatViewModel
    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(12)) {
            Text(t.string(.personaNew)).tokenFont(.headline).tokenForeground(.text1)
            TextField(t.string(.personaNamePlaceholder), text: $model.newPersonaName)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $model.newPersonaInstructions)
                .tokenFont(.body)
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.spacing(8))
                .frame(height: 120)
                .card(radius: .sm)
            HStack {
                Spacer()
                Button(t.string(.cancel)) { model.showNewPersona = false }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(t.string(.save)) { model.saveNewPersona() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newPersonaName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DesignTokens.spacing(24))
        .frame(width: 420)
    }
}
