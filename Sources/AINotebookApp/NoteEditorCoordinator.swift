import SwiftUI
import Combine

/// Lets `NotesView` observe the active editor's dirty state and trigger
/// a synchronous flush from outside (e.g. when the user picks a different
/// note while there are unsaved changes).
@MainActor
final class NoteEditorCoordinator: ObservableObject {
    @Published var hasUnsavedChanges: Bool = false

    /// Set by the active `NoteWYSIWYGEditor` instance on appear; cleared on
    /// disappear. Calling it triggers `AutoSaveController.manualSave()`.
    var flushPendingSave: (() -> Void)?

    func reset() {
        hasUnsavedChanges = false
        flushPendingSave = nil
    }
}
