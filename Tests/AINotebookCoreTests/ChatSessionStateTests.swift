import XCTest
@testable import AINotebookCore

/// Pure chat-surface rules extracted from the macOS ChatView (UI redesign B1).
final class ChatSessionStateTests: XCTestCase {

    private func session(_ id: Int64?, _ title: String = "S") -> ChatSession {
        ChatSession(id: id, notebookId: 1, title: title, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func message(_ id: Int64?, _ role: ChatRole, _ text: String = "x") -> ChatMessage {
        ChatMessage(id: id, sessionId: 1, role: role, content: text)
    }

    private func persona(instructions: String) -> Persona {
        Persona(id: 1, notebookId: 1, name: "P", instructions: instructions, createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Session list

    func testInitialSelectionIsFirstSession() {
        XCTAssertEqual(ChatSessionState.initialSelection([session(7), session(3)]), 7)
        XCTAssertNil(ChatSessionState.initialSelection([]))
    }

    func testInsertingNewSessionPutsItFirstAndSelectsIt() {
        let result = ChatSessionState.inserting(session(9, "new"), into: [session(7), session(3)])
        XCTAssertEqual(result.sessions.map(\.id), [9, 7, 3])
        XCTAssertEqual(result.selection, 9)
    }

    func testRemovingSessionSelectsFirstRemaining() {
        let result = ChatSessionState.removing(id: 7, from: [session(7), session(3), session(2)])
        XCTAssertEqual(result.sessions.map(\.id), [3, 2])
        XCTAssertEqual(result.selection, 3)
    }

    func testRemovingNonFirstSessionStillSelectsFirst() {
        // The original behaviour: deletion always selects the first remaining row.
        let result = ChatSessionState.removing(id: 3, from: [session(7), session(3)])
        XCTAssertEqual(result.sessions.map(\.id), [7])
        XCTAssertEqual(result.selection, 7)
    }

    func testRemovingLastSessionLeavesNoSelection() {
        let result = ChatSessionState.removing(id: 7, from: [session(7)])
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNil(result.selection)
    }

    // MARK: - Edit last user message

    func testEditTargetPairsLastUserWithFollowingAssistant() {
        let messages = [message(1, .user), message(2, .assistant), message(3, .user), message(4, .assistant)]
        XCTAssertEqual(ChatSessionState.editTarget(in: messages), ChatEditTarget(userId: 3, assistantId: 4))
    }

    func testEditTargetWithoutAnswerHasNoAssistant() {
        let messages = [message(1, .user), message(2, .assistant), message(3, .user)]
        XCTAssertEqual(ChatSessionState.editTarget(in: messages), ChatEditTarget(userId: 3, assistantId: nil))
    }

    func testEditTargetIgnoresAssistantOlderThanUser() {
        // Ids out of order: the trailing assistant row predates the user row.
        let messages = [message(5, .user), message(4, .assistant)]
        XCTAssertEqual(ChatSessionState.editTarget(in: messages), ChatEditTarget(userId: 5, assistantId: nil))
    }

    func testEditTargetNeedsPersistedUserMessage() {
        XCTAssertNil(ChatSessionState.editTarget(in: []))
        XCTAssertNil(ChatSessionState.editTarget(in: [message(nil, .user)]))
        XCTAssertNil(ChatSessionState.editTarget(in: [message(1, .assistant)]))
    }

    func testEditTextIsLastUserContent() {
        let messages = [message(1, .user, "first"), message(2, .assistant), message(3, .user, "second")]
        XCTAssertEqual(ChatSessionState.editText(in: messages), "second")
        XCTAssertNil(ChatSessionState.editText(in: [message(1, .assistant)]))
    }

    // MARK: - Action availability

    func testRegenerateAvailableOnlyAfterSettledAssistantAnswer() {
        let answered = [message(1, .user), message(2, .assistant)]
        XCTAssertTrue(ChatSessionState.canRegenerate(messages: answered, sending: false, streamingDraft: ""))
        XCTAssertFalse(ChatSessionState.canRegenerate(messages: answered, sending: true, streamingDraft: ""))
        XCTAssertFalse(ChatSessionState.canRegenerate(messages: answered, sending: false, streamingDraft: "…"))
        XCTAssertFalse(ChatSessionState.canRegenerate(messages: [message(1, .user)], sending: false, streamingDraft: ""))
        XCTAssertFalse(ChatSessionState.canRegenerate(messages: [], sending: false, streamingDraft: ""))
    }

    func testSendButtonTrimsSpacesOnly() {
        XCTAssertTrue(ChatSessionState.canSend(input: "hi", sending: false, preparing: false))
        XCTAssertFalse(ChatSessionState.canSend(input: "  ", sending: false, preparing: false))
        // The button historically trims spaces only; send() then trims newlines too.
        XCTAssertTrue(ChatSessionState.canSend(input: "\n", sending: false, preparing: false))
        XCTAssertFalse(ChatSessionState.canSend(input: "hi", sending: true, preparing: false))
        XCTAssertFalse(ChatSessionState.canSend(input: "hi", sending: false, preparing: true))
    }

    func testPreviewButtonTrimsWhitespaceAndNewlines() {
        XCTAssertTrue(ChatSessionState.canPreview(input: "hi", sending: false, preparing: false))
        XCTAssertFalse(ChatSessionState.canPreview(input: " \n ", sending: false, preparing: false))
        XCTAssertFalse(ChatSessionState.canPreview(input: "hi", sending: true, preparing: false))
        XCTAssertFalse(ChatSessionState.canPreview(input: "hi", sending: false, preparing: true))
    }

    func testSendableTextTrimsAndRejectsBlank() {
        XCTAssertEqual(ChatSessionState.sendableText("  ahoj\n"), "ahoj")
        XCTAssertNil(ChatSessionState.sendableText(" \n\t"))
    }

    func testFollowupsAreShownOnlyWhileIdle() {
        XCTAssertTrue(ChatSessionState.acceptsFollowups(sending: false))
        XCTAssertFalse(ChatSessionState.acceptsFollowups(sending: true))
        XCTAssertTrue(ChatSessionState.wantsFollowups(answer: "Answer"))
        XCTAssertFalse(ChatSessionState.wantsFollowups(answer: " \n"))
    }

    // MARK: - Persona / model

    func testPersonaInstructionsEmptyMeansNoOverride() {
        XCTAssertNil(ChatSessionState.personaInstructions(nil))
        XCTAssertNil(ChatSessionState.personaInstructions(persona(instructions: "")))
        XCTAssertEqual(ChatSessionState.personaInstructions(persona(instructions: "Be brief")), "Be brief")
    }

    func testProviderQualifiedModelKey() {
        XCTAssertEqual(ChatSessionState.providerQualifiedModel(providerId: "ollama", model: "llama3"), "ollama:llama3")
    }

    func testTurnModeFollowsOverviewToggle() {
        XCTAssertEqual(ChatSessionState.turnMode(overview: true), "overview")
        XCTAssertEqual(ChatSessionState.turnMode(overview: false), "answer")
    }

    func testWebSearchNeedsSettingAndPerMessageOptIn() {
        XCTAssertTrue(ChatSessionState.useWebSearch(enabledInSettings: true, optedIn: true))
        XCTAssertFalse(ChatSessionState.useWebSearch(enabledInSettings: false, optedIn: true))
        XCTAssertFalse(ChatSessionState.useWebSearch(enabledInSettings: true, optedIn: false))
    }

    // MARK: - Scope summary

    func testScopeSummary() {
        XCTAssertEqual(ChatSessionState.scopeSummary(FolderScopeSelection()), .wholeNotebook)
        XCTAssertEqual(ChatSessionState.scopeSummary(FolderScopeSelection(wholeNotebook: false)), .empty)
        XCTAssertEqual(ChatSessionState.scopeSummary(
            FolderScopeSelection(wholeNotebook: false, sourceIds: [1, 2], folderIds: [3], setIds: [4])), .selected(4))
        // Whole notebook wins even when ids linger from an earlier selection.
        XCTAssertEqual(ChatSessionState.scopeSummary(FolderScopeSelection(wholeNotebook: true, sourceIds: [1])), .wholeNotebook)
    }

    // MARK: - Stale preview rules

    func testDraftGenerationMarksEarlierPreparationsStale() {
        var generation = DraftGeneration()
        let first = generation.advance()
        XCTAssertTrue(generation.isCurrent(first))
        let second = generation.advance()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
        generation.advance()
        XCTAssertFalse(generation.isCurrent(second))
    }

    func testPreparationAppliesOnlyWhenCurrentUncancelledAndSameSession() {
        XCTAssertTrue(ChatSessionState.preparationIsCurrent(
            cancelled: false, generation: 2, currentGeneration: 2, sessionId: 5, selectedSessionId: 5))
        XCTAssertFalse(ChatSessionState.preparationIsCurrent(
            cancelled: true, generation: 2, currentGeneration: 2, sessionId: 5, selectedSessionId: 5))
        XCTAssertFalse(ChatSessionState.preparationIsCurrent(
            cancelled: false, generation: 1, currentGeneration: 2, sessionId: 5, selectedSessionId: 5))
        XCTAssertFalse(ChatSessionState.preparationIsCurrent(
            cancelled: false, generation: 2, currentGeneration: 2, sessionId: 5, selectedSessionId: 6))
        XCTAssertFalse(ChatSessionState.preparationIsCurrent(
            cancelled: false, generation: 2, currentGeneration: 2, sessionId: 5, selectedSessionId: nil))
    }

    func testPreparedHandleReusedOnlyForMatchingUnconsumedKey() {
        let a = Data(repeating: 1, count: 32)
        let b = Data(repeating: 2, count: 32)
        XCTAssertTrue(ChatSessionState.canReusePrepared(preparedKey: a, consumed: false, freshKey: a))
        XCTAssertFalse(ChatSessionState.canReusePrepared(preparedKey: a, consumed: true, freshKey: a))
        XCTAssertFalse(ChatSessionState.canReusePrepared(preparedKey: a, consumed: false, freshKey: b))
        XCTAssertFalse(ChatSessionState.canReusePrepared(preparedKey: nil, consumed: false, freshKey: a))
    }

    func testRetryAfterFailedSendRegeneratesASavedQuestion() {
        let saved = [message(1, .user, "a"), message(2, .assistant, "b"), message(3, .user, "q")]
        XCTAssertEqual(ChatSessionState.retryAfterFailedSend(question: "q", messages: saved), .regenerate)
        let unsaved = [message(1, .user, "a"), message(2, .assistant, "b")]
        XCTAssertEqual(ChatSessionState.retryAfterFailedSend(question: "q", messages: unsaved), .resend("q"))
        XCTAssertEqual(ChatSessionState.retryAfterFailedSend(question: "q", messages: []), .resend("q"))
        let other = [message(3, .user, "different")]
        XCTAssertEqual(ChatSessionState.retryAfterFailedSend(question: "q", messages: other), .resend("q"))
    }
    // MARK: Rename + Stop (UI redesign C1; parity with Windows ChatSessionStateTests)

    func testRenamedTitleTrimsAndIgnoresBlankOrUnchanged() {
        XCTAssertEqual(ChatSessionState.renamedTitle("  New \n", current: "Old"), "New")
        XCTAssertNil(ChatSessionState.renamedTitle(" \n\t", current: "Old"))
        XCTAssertNil(ChatSessionState.renamedTitle(" Old ", current: "Old"))
    }

    func testStoppedAnswerKeepsStreamedTextOfANewTurnOnly() {
        XCTAssertEqual(ChatSessionState.stoppedAnswer("  Partial **answer** [1]\n\n", isReplacement: false),
                       "  Partial **answer** [1]")
        XCTAssertNil(ChatSessionState.stoppedAnswer(" \n ", isReplacement: false))
        XCTAssertNil(ChatSessionState.stoppedAnswer("", isReplacement: false))
        XCTAssertNil(ChatSessionState.stoppedAnswer("Partial", isReplacement: true))
    }

    func testOnlyAnEmptyStoppedNewTurnReturnsItsQuestion() {
        XCTAssertTrue(ChatSessionState.returnsQuestion(partial: "", isReplacement: false))
        XCTAssertTrue(ChatSessionState.returnsQuestion(partial: " \n ", isReplacement: false))
        XCTAssertFalse(ChatSessionState.returnsQuestion(partial: "Partial", isReplacement: false))
        XCTAssertFalse(ChatSessionState.returnsQuestion(partial: "", isReplacement: true))
    }

    func testOrphanedQuestionIsTheNewestUserRowOfThisTurn() {
        let before = [message(1, .user, "a"), message(2, .assistant, "b")]
        XCTAssertEqual(ChatSessionState.orphanedQuestionId(
            question: "q", messages: before + [message(3, .user, "q")], newestIdBeforeSend: 2), 3)
        XCTAssertEqual(ChatSessionState.orphanedQuestionId(
            question: "q", messages: [message(1, .user, "q")], newestIdBeforeSend: nil), 1)
        // Core never saved it (stopped before streaming): the history is unchanged.
        XCTAssertNil(ChatSessionState.orphanedQuestionId(question: "q", messages: before, newestIdBeforeSend: 2))
        // An older unanswered row with the same text is not this turn's.
        XCTAssertNil(ChatSessionState.orphanedQuestionId(
            question: "q", messages: [message(1, .user, "q")], newestIdBeforeSend: 1))
        XCTAssertNil(ChatSessionState.orphanedQuestionId(
            question: "q", messages: before + [message(3, .user, "other")], newestIdBeforeSend: 2))
        XCTAssertNil(ChatSessionState.orphanedQuestionId(
            question: "q", messages: before + [message(3, .user, "q"), message(4, .assistant, "x")],
            newestIdBeforeSend: 2))
        XCTAssertNil(ChatSessionState.orphanedQuestionId(question: "q", messages: [], newestIdBeforeSend: nil))
    }

    func testStoppedCitationsResolveKnownMarkersOnceInOrder() {
        let map = [
            Citation(marker: 1, chunkId: 10, sourceId: 1, snippet: "a"),
            Citation(marker: 2, chunkId: 20, sourceId: 2, snippet: "b"),
        ]
        let cited = ChatSessionState.stoppedCitations(answer: "B [2], A [1], again [2], unknown [7], cut [", citationMap: map)
        XCTAssertEqual(cited.map(\.marker), [2, 1])
        XCTAssertEqual(ChatSessionState.stoppedCitations(answer: "none", citationMap: map), [])
    }
}
