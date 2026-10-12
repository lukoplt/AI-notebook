import Foundation

/// Edit-and-resend target: the last user message and, when it was answered,
/// the assistant reply that the edited turn replaces once it commits.
public struct ChatEditTarget: Equatable, Sendable {
    public let userId: Int64
    public let assistantId: Int64?

    public init(userId: Int64, assistantId: Int64?) {
        self.userId = userId
        self.assistantId = assistantId
    }
}

/// Monotonic counter for the draft context preview. Every invalidation
/// advances it; a preparation that started under an older value completes
/// silently instead of publishing a stale preview.
public struct DraftGeneration: Equatable, Sendable {
    public private(set) var value = 0

    public init() {}

    @discardableResult
    public mutating func advance() -> Int {
        value += 1
        return value
    }

    public func isCurrent(_ generation: Int) -> Bool { generation == value }
}

/// Pure chat-surface rules shared by the chat view model (macOS ChatView).
/// Stateless: callers own the state and apply the results.
public enum ChatSessionState {

    // MARK: Session list

    /// Sessions arrive newest first; the first one is selected.
    public static func initialSelection(_ sessions: [ChatSession]) -> Int64? {
        sessions.first?.id
    }

    /// A new session goes to the top of the list and becomes the selection.
    public static func inserting(_ session: ChatSession, into sessions: [ChatSession])
        -> (sessions: [ChatSession], selection: Int64?) {
        var result = sessions
        result.insert(session, at: 0)
        return (result, session.id)
    }

    /// Deleting a session selects the first remaining one (or none).
    public static func removing(id: Int64, from sessions: [ChatSession])
        -> (sessions: [ChatSession], selection: Int64?) {
        let result = sessions.filter { $0.id != id }
        return (result, result.first?.id)
    }

    // MARK: Edit last user message

    /// The last persisted user message, paired with the trailing assistant
    /// reply only when that reply is newer than it.
    public static func editTarget(in messages: [ChatMessage]) -> ChatEditTarget? {
        guard let lastUser = messages.last(where: { $0.role == .user }),
              let userId = lastUser.id else { return nil }
        let assistantId = messages.last.flatMap {
            $0.role == .assistant && ($0.id ?? 0) > userId ? $0.id : nil
        }
        return ChatEditTarget(userId: userId, assistantId: assistantId)
    }

    /// Text pulled back into the input when editing the last user message.
    public static func editText(in messages: [ChatMessage]) -> String? {
        messages.last(where: { $0.role == .user })?.content
    }

    // MARK: Action availability

    /// Regenerate / edit appear only under a settled assistant answer.
    public static func canRegenerate(messages: [ChatMessage], sending: Bool, streamingDraft: String) -> Bool {
        guard let last = messages.last else { return false }
        return last.role == .assistant && !sending && streamingDraft.isEmpty
    }

    /// Send button: trims spaces only (send itself trims newlines too).
    /// Background ingestion may change the scope's evidence between capture and
    /// send (`stalePreparedRequest`, nothing written yet): the same turn is
    /// prepared again from the new snapshot, at most this many times.
    public static let staleRepreparations = 3

    public static func reprepareAfterStale(attempt: Int) -> Bool { attempt < staleRepreparations }

    public static func canSend(input: String, sending: Bool, preparing: Bool) -> Bool {
        !sending && !preparing && !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "Preview before send" button.
    public static func canPreview(input: String, sending: Bool, preparing: Bool) -> Bool {
        !sending && !preparing && sendableText(input) != nil
    }

    /// The question actually sent or prepared; nil when blank.
    public static func sendableText(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Follow-up suggestions are generated only for a non-blank answer.
    public static func wantsFollowups(answer: String) -> Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Suggestions are shown only if the conversation has not moved on.
    public static func acceptsFollowups(sending: Bool) -> Bool { !sending }

    // MARK: Persona / model / per-turn options

    /// Empty persona instructions mean "no override".
    public static func personaInstructions(_ persona: Persona?) -> String? {
        guard let instructions = persona?.instructions, !instructions.isEmpty else { return nil }
        return instructions
    }

    /// Router key that pins a provider (`providerId:model`).
    public static func providerQualifiedModel(providerId: String, model: String) -> String {
        "\(providerId):\(model)"
    }

    public static func turnMode(overview: Bool) -> String { overview ? "overview" : "answer" }

    public static func useWebSearch(enabledInSettings: Bool, optedIn: Bool) -> Bool {
        enabledInSettings && optedIn
    }

    // MARK: Scope summary

    public enum ScopeSummary: Equatable, Sendable {
        case wholeNotebook
        case empty
        case selected(Int)
    }

    public static func scopeSummary(_ selection: FolderScopeSelection) -> ScopeSummary {
        if selection.wholeNotebook { return .wholeNotebook }
        let count = selection.sourceIds.count + selection.folderIds.count + selection.setIds.count
        return count == 0 ? .empty : .selected(count)
    }

    // MARK: Stale preview rules

    /// A finished preparation may publish its preview only when it was not
    /// cancelled, no invalidation happened meanwhile and the session is unchanged.
    public static func preparationIsCurrent(cancelled: Bool, generation: Int, currentGeneration: Int,
                                            sessionId: Int64, selectedSessionId: Int64?) -> Bool {
        !cancelled && generation == currentGeneration && selectedSessionId == sessionId
    }

    /// Send reuses the previewed handle only when a fresh capture yields the
    /// same intent key and the one-shot handle is still unconsumed.
    public static func canReusePrepared(preparedKey: Data?, consumed: Bool, freshKey: Data) -> Bool {
        guard let preparedKey else { return false }
        return preparedKey == freshKey && !consumed
    }

    // MARK: Retry after an error

    /// What "Try again" does after a failed turn.
    public enum Retry: Equatable, Sendable {
        /// Answer the last user message again (it was saved, or a regenerate failed).
        case regenerate
        /// The question never reached the history: send it again.
        case resend(String)
    }

    /// A failed send whose question was already saved as the last (unanswered)
    /// user row is retried by regenerating it, never by duplicating the row.
    public static func retryAfterFailedSend(question: String, messages: [ChatMessage]) -> Retry {
        if let last = messages.last, last.role == .user, last.content == question { return .regenerate }
        return .resend(question)
    }

    // MARK: Rename (UI redesign C1)

    /// The title a rename commits: trimmed, or nil when blank or unchanged
    /// (the store keeps the current title).
    public static func renamedTitle(_ input: String, current: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == current ? nil : trimmed
    }

    // MARK: Stop (UI redesign C1)

    /// What a turn the user stopped keeps: the streamed text without trailing
    /// whitespace, or nil when nothing (or only whitespace) arrived. Only a new
    /// turn keeps it; a stopped regenerate/edit leaves the previous exchange
    /// unchanged, because Core replaces it only after a complete stream.
    public static func stoppedAnswer(_ partial: String, isReplacement: Bool) -> String? {
        guard !isReplacement else { return nil }
        var text = partial
        while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            text.unicodeScalars.removeLast()
        }
        return text.isEmpty ? nil : text
    }

    /// A new turn stopped before any answer text arrived keeps nothing: its
    /// question goes back into the composer and the row Core saved for it is
    /// removed (see `orphanedQuestionId`), so sending again does not store the
    /// question twice. A stopped regenerate/edit keeps its previous exchange.
    public static func returnsQuestion(partial: String, isReplacement: Bool) -> Bool {
        !isReplacement && stoppedAnswer(partial, isReplacement: false) == nil
    }

    /// The user row a stopped, unanswered new turn left behind: the newest row,
    /// a user row with the sent question, newer than every row the turn started
    /// from (`newestIdBeforeSend`, nil for an empty history). nil when Core never
    /// saved the question (the turn stopped before streaming began).
    public static func orphanedQuestionId(question: String, messages: [ChatMessage],
                                          newestIdBeforeSend: Int64?) -> Int64? {
        guard let last = messages.max(by: { ($0.id ?? 0) < ($1.id ?? 0) }), let id = last.id,
              last.role == .user, last.content == question,
              id > (newestIdBeforeSend ?? 0) else { return nil }
        return id
    }

    /// Citations of a stopped answer, resolved like a completed turn: each
    /// marker once in order of first use; markers the pack does not know are dropped.
    public static func stoppedCitations(answer: String, citationMap: [Citation]) -> [Citation] {
        let byMarker = Dictionary(citationMap.map { ($0.marker, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        return CitationParser.markers(in: answer).compactMap { marker in
            guard seen.insert(marker).inserted else { return nil }
            return byMarker[marker]
        }
    }
}
