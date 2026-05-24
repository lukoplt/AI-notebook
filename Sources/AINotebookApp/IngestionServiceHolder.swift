import SwiftUI
import AINotebookCore

/// `IngestionService` is a `final Sendable` value-style type, not an
/// `ObservableObject`, so it can't be `@StateObject`'d directly. Wrap it
/// in a holder so SwiftUI can inject it through the environment.
@MainActor
final class IngestionServiceHolder: ObservableObject {
    let service: IngestionService
    init(service: IngestionService) { self.service = service }
}
