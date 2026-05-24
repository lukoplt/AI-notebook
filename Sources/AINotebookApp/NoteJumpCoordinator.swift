import SwiftUI
import Combine

@MainActor
final class NoteJumpCoordinator: ObservableObject {
    @Published var target: Int64?

    func request(noteId: Int64) {
        target = noteId
    }

    func clear() {
        target = nil
    }
}
