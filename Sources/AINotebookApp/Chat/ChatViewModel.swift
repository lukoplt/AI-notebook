// Sources/AINotebookApp/Chat/ChatViewModel.swift
import Foundation
import Combine
import Observation
import AINotebookCore

/// All state and behaviour of the notebook chat surface: sessions, scope,
/// persona, the WP8 context preview, send/regenerate/edit and follow-ups.
/// Views bind to it; pure rules live in Core `ChatSessionState`.
@MainActor
@Observable
final class ChatViewModel {
    /// App-wide services injected by the view (environment objects).
    struct Dependencies {
        let settings: AppSettings
        let store: NotebookStore
        let chatHolder: ChatEngineHolder
        let routerHolder: ProviderRouterHolder
    }

    // MARK: Sessions + messages

    private(set) var sessions: [ChatSession] = []
    var selectedSessionId: Int64? {
        didSet { if oldValue != selectedSessionId { selectedSessionChanged() } }
    }
    private(set) var messages: [ChatMessage] = []
    private(set) var streamingDraft: String = ""
    private(set) var sending = false
    var errorMessage: String?
    private(set) var followups: [String] = []
    private(set) var chatProviders: [ProviderConfig] = []
    /// The answer the user stopped mid-stream (its row shows "Stopped").
    private(set) var stoppedMessageId: Int64?

    // MARK: Turn (send / regenerate) + Stop

    /// The running send or regenerate; Stop cancels it.
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    /// Set by Stop: the cancellation that follows is the user's, not an error.
    @ObservationIgnored private var stopRequested = false
    /// Tokens of an earlier (stopped) turn that arrive late are dropped.
    @ObservationIgnored private var turnGeneration = 0

    // MARK: Composer

    var input: String = "" {
        didSet { if oldValue != input { invalidateDraft() } }
    }
    var useWebForNextMessage = false {
        didSet { if oldValue != useWebForNextMessage { invalidateDraft() } }
    }
    /// WP8 — per-turn Overview mode (no query embedding).
    var overviewForNextMessage = false {
        didSet { if oldValue != overviewForNextMessage { invalidateDraft() } }
    }
    /// Edit-and-resend keeps the old pair until the replacement commits.
    private(set) var editingTarget: ChatEditTarget?

    // MARK: Citations panel

    /// The answer whose citations the Citations panel lists, and the focused marker.
    private(set) var citationFocus: CitationFocus?

    // MARK: Errors

    /// What "Try again" does for the current error (nil: nothing to retry).
    private(set) var retry: ChatSessionState.Retry?
    /// The note most recently saved from an answer (confirmation + open).
    var savedNoteId: Int64?

    // MARK: Scope

    /// Explicit chat scope (whole notebook / selected sources, folders, sets).
    let scope = FolderScopeModel()
    var showingScopePopover = false
    var newSetName = ""

    // MARK: Persona (C5)

    private(set) var personas: [Persona] = []
    private(set) var activePersona: Persona? {
        didSet { if oldValue?.id != activePersona?.id { invalidateDraft() } }
    }
    var showNewPersona = false
    var newPersonaName = ""
    var newPersonaInstructions = ""

    // MARK: Context preview (WP8)

    private(set) var previewSnapshot: ContextPreviewSnapshot?
    private(set) var previewError: String?
    private(set) var preparing = false
    var sentPreview: SentPreviewItem?
    @ObservationIgnored private var prepared: PreparedPackHandle?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    /// Bumped on every invalidation; a stale preparation completes silently.
    @ObservationIgnored private var draftGeneration = DraftGeneration()

    @ObservationIgnored private var deps: Dependencies?
    /// The notebook whose chats this model serves (the shell's current notebook).
    private(set) var notebookId: Int64?
    /// Called after the first message of a new chat created its session.
    @ObservationIgnored var onSessionCreated: ((_ notebookId: Int64, _ sessionId: Int64) -> Void)?
    @ObservationIgnored private var scopeSubscription: AnyCancellable?

    init() {
        // Scope changes alter the turn exactly like composer edits do.
        scopeSubscription = scope.$selection
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateDraft() }
            }
    }

    private var t: AppText? { deps?.settings.text }

    // MARK: - Derived state

    var canRegenerate: Bool {
        ChatSessionState.canRegenerate(messages: messages, sending: sending, streamingDraft: streamingDraft)
    }

    var canSend: Bool { ChatSessionState.canSend(input: input, sending: sending, preparing: preparing) }

    var canPreview: Bool { ChatSessionState.canPreview(input: input, sending: sending, preparing: preparing) }

    var isEditing: Bool { editingTarget != nil }

    /// The newest saved assistant answer (top bar "sent context").
    var lastAssistantMessage: ChatMessage? {
        messages.last(where: { $0.role == .assistant && $0.id != nil })
    }

    // MARK: - Lifecycle

    /// Called whenever the shell shows (another) notebook. `sessionId` nil is
    /// the new-chat state: the session is created by the first message.
    func load(notebookId: Int64, sessionId: Int64?, dependencies: Dependencies) async {
        deps = dependencies
        if self.notebookId != notebookId {
            self.notebookId = notebookId
            selectedSessionId = nil
            messages = []
        }
        refreshNotebookData()
        select(sessionId: sessionId)
        await reloadMessages()
        await loadScopeSources()
    }

    /// Providers, personas and sessions of the current notebook.
    func refreshNotebookData() {
        guard let deps, let notebookId else { return }
        chatProviders = (try? deps.store.providers().filter(\.enabled)) ?? []
        personas = (try? deps.store.personas(notebookId: notebookId)) ?? []
        sessions = (try? deps.store.chatSessions(notebookId: notebookId)) ?? []
    }

    /// Shows a thread of the current notebook (nil = new chat).
    func select(sessionId: Int64?) {
        selectedSessionId = sessionId
        if sessionId == nil {
            messages = []
            errorMessage = nil
        }
    }

    /// The selected session, creating it (titled by the question) for a new chat.
    private func ensureSession(title question: String) -> Int64? {
        if let selectedSessionId { return selectedSessionId }
        guard let deps, let notebookId, let t else { return nil }
        do {
            let title = ShellNavigation.sessionTitle(firstMessage: question, fallback: t.string(.chatNewSessionTitle))
            let session = try deps.store.createChatSession(notebookId: notebookId, title: title)
            guard let id = session.id else { return nil }
            sessions = ChatSessionState.inserting(session, into: sessions).sessions
            selectedSessionId = id
            onSessionCreated?(notebookId, id)
            return id
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Reloads scope rows; the selection itself survives reloads and resets
    /// only when the notebook changes.
    func loadScopeSources() async {
        guard let deps, let notebookId else { return }
        scope.configure(store: deps.store)
        do { try scope.reload(notebookId: notebookId) }
        catch { errorMessage = String(describing: error) }
    }

    /// Fresh rows (new folder members, removed sets); the selection is kept.
    func openScopePopover() async {
        await loadScopeSources()
        showingScopePopover = true
    }

    // MARK: - Sessions

    private func selectedSessionChanged() {
        followups = []
        retry = nil
        errorMessage = nil
        stoppedMessageId = nil
        // Retained previews of other sessions survive; the draft does not.
        editingTarget = nil
        invalidateDraft()
        Task { await reloadMessages() }
    }

    private func reloadMessages() async {
        guard let sid = selectedSessionId else {
            messages = []
            return
        }
        guard let deps else { return }
        do {
            messages = try deps.store.messages(sessionId: sid)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Context preview (WP8)

    /// Prepares the current draft for the Context panel (preview before send).
    func startPreparingDraft() {
        sentPreview = nil
        guard let text = ChatSessionState.sendableText(input), ensureSession(title: text) != nil else { return }
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in await self?.prepareCurrentDraft() }
    }

    /// Captures the current draft's intent once, prepares it and keeps the
    /// handle so Send streams exactly what the panel shows.
    private func prepareCurrentDraft() async {
        guard let deps, let sid = selectedSessionId else { return }
        guard let text = ChatSessionState.sendableText(input) else { return }
        let generation = draftGeneration.advance()
        preparing = true
        previewError = nil
        previewSnapshot = nil
        prepared = nil
        do {
            let intent = try await captureIntent(sessionId: sid, question: text, editing: editingTarget)
            let key = PackIntentKey.make(intent)
            let cacheGeneration = await deps.chatHolder.previews.beginDraft(sessionId: sid, key: key)
            let handle = try await deps.chatHolder.engine.prepare(intent)
            guard ChatSessionState.preparationIsCurrent(
                cancelled: Task.isCancelled, generation: generation, currentGeneration: draftGeneration.value,
                sessionId: sid, selectedSessionId: selectedSessionId) else { return }
            let bytes = try ContextPreviewSnapshotJSON.encode(handle.snapshot)
            _ = await deps.chatHolder.previews.completeDraft(generation: cacheGeneration, key: key, bytes: bytes)
            guard draftGeneration.isCurrent(generation) else { return }
            prepared = handle
            previewSnapshot = handle.snapshot
        } catch {
            if draftGeneration.isCurrent(generation), !(error is CancellationError) {
                previewError = chatErrorText(error)
            }
        }
        if draftGeneration.isCurrent(generation) { preparing = false }
    }

    /// Any change to what the turn depends on drops the prepared request.
    func invalidateDraft() {
        draftGeneration.advance()
        prepareTask?.cancel()
        prepareTask = nil
        prepared = nil
        previewSnapshot = nil
        previewError = nil
        preparing = false
        guard let previews = deps?.chatHolder.previews else { return }
        Task { await previews.invalidateDraft() }
    }

    private func captureIntent(sessionId: Int64, question: String, editing: ChatEditTarget?,
                               overview: Bool? = nil, useWeb: Bool? = nil) async throws -> PackIntent {
        guard let deps, let notebookId else { throw CancellationError() }
        let turnScope = try scope.resolveForTurn()
        return try await deps.chatHolder.engine.captureIntent(
            sessionId: sessionId, notebookId: notebookId, question: question, scope: turnScope,
            mode: ChatSessionState.turnMode(overview: overview ?? overviewForNextMessage),
            useWebSearch: ChatSessionState.useWebSearch(
                enabledInSettings: deps.settings.webSearchEnabled, optedIn: useWeb ?? useWebForNextMessage),
            model: activePersona?.model,
            instructionsOverride: ChatSessionState.personaInstructions(activePersona),
            regenerateUserId: editing?.userId, replacesAssistantId: editing?.assistantId,
            editUserText: editing != nil)
    }

    func showSentPreview(_ message: ChatMessage) {
        guard let deps, let sid = selectedSessionId, let id = message.id else { return }
        Task { @MainActor in
            let bytes = await deps.chatHolder.previews.sent(sessionId: sid, assistantId: id)
            sentPreview = SentPreviewItem(id: id, snapshot: bytes.flatMap { try? ContextPreviewSnapshotJSON.decode($0) })
        }
    }

    private func chatErrorText(_ error: Error) -> String {
        guard let t else { return String(describing: error) }
        if (error as? ContextPackError) == .contextTooSmall { return t.string(.contextTooSmall) }
        return providerErrorText(error, text: t)
    }

    // MARK: - Persona (C5)

    func clearPersona() { activePersona = nil }

    /// Applies a persona: its source set narrows scope, its model + instructions
    /// are used for subsequent sends.
    func applyPersona(_ p: Persona) {
        activePersona = p
        if let setId = p.sourceSetId { scope.apply(setId: setId) }
    }

    func saveNewPersona() {
        guard let deps, let notebookId else { return }
        let name = newPersonaName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            // Capture the current model; a source set can be attached later.
            let p = try deps.store.createPersona(
                notebookId: notebookId,
                name: name,
                instructions: newPersonaInstructions,
                sourceSetId: nil,
                model: ChatSessionState.providerQualifiedModel(
                    providerId: deps.settings.selectedChatProviderId, model: deps.settings.selectedChatModel)
            )
            newPersonaName = ""
            newPersonaInstructions = ""
            showNewPersona = false
            personas = (try? deps.store.personas(notebookId: notebookId)) ?? []
            applyPersona(p)
        } catch { errorMessage = String(describing: error) }
    }

    // MARK: - Scope sets

    func saveCurrentAsSet() {
        let name = newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try scope.saveCurrent(name: name)
            newSetName = ""
        } catch { errorMessage = String(describing: error) }
    }

    func deleteSet(_ id: Int64) {
        do { try scope.delete(set: id) } catch { errorMessage = String(describing: error) }
    }

    // MARK: - Send / regenerate / edit

    func send() async {
        guard let text = ChatSessionState.sendableText(input) else { return }
        await send(text: text, fromInput: true)
    }

    func sendFollowup(_ question: String) async {
        guard !sending else { return }
        await send(text: question, fromInput: false)
    }

    /// C3 — regenerate via a specific provider; the router honors this
    /// provider-qualified key.
    func regenerate(via provider: ProviderConfig) async {
        guard let deps else { return }
        await regenerate(model: ChatSessionState.providerQualifiedModel(
            providerId: provider.id, model: deps.settings.selectedChatModel))
    }

    /// C3 — regenerate the last assistant answer. `model` nil uses the current
    /// selection; a provider-qualified key regenerates via that provider.
    func regenerate(model: String? = nil) async {
        await runTurn { await $0.runRegenerate(model: model) }
    }

    private func runRegenerate(model: String?) async {
        guard let deps, let notebookId, let sid = selectedSessionId, !sending else { return }
        let generation = beginTurn()
        defer { endTurn() }
        do {
            let turnScope = try scope.resolveForTurn()
            // The previous answer stays until the replacement commits.
            _ = try await deps.chatHolder.engine.regenerate(
                sessionId: sid,
                notebookId: notebookId,
                scope: turnScope,
                model: model,
                instructionsOverride: ChatSessionState.personaInstructions(activePersona),
                onToken: { [weak self] token in
                    Task { @MainActor in self?.appendToken(token, generation: generation) }
                },
                onRetry: { [weak self] in
                    // Drop the failed attempt's partial text so the retry does
                    // not render appended to it.
                    Task { @MainActor in self?.resetDraft(generation: generation) }
                }
            )
            await reloadMessages()
        } catch where stopRequested {
            // A stopped regenerate keeps the previous answer (Core replaces it
            // only after a complete stream); no error row.
            await keepStoppedAnswer(sessionId: sid, handle: nil, isReplacement: true)
        } catch {
            errorMessage = chatErrorText(error)
            await reloadMessages()
            retry = .regenerate
        }
    }

    /// "Try again" after an error row.
    func performRetry() async {
        guard let retry, !sending else { return }
        switch retry {
        case .regenerate: await regenerate()
        case .resend(let text): await send(text: text, fromInput: false)
        }
    }

    /// C3 — pull the last user message back into the input for editing. The
    /// old exchange stays until the edited turn's answer commits; a failed
    /// edit leaves it unchanged.
    func editLastUserMessage() {
        guard let target = ChatSessionState.editTarget(in: messages),
              let text = ChatSessionState.editText(in: messages) else { return }
        input = text
        editingTarget = target
    }

    func cancelEditing() {
        editingTarget = nil
        input = ""
    }

    /// Sends the previewed handle when its key still matches a fresh capture;
    /// otherwise prepares once. The input clears only after preparation.
    private func send(text: String, fromInput: Bool) async {
        await runTurn { await $0.runSend(text: text, fromInput: fromInput) }
    }

    private func runSend(text: String, fromInput: Bool) async {
        guard let deps, !sending, let sid = ensureSession(title: text) else { return }
        let generation = beginTurn()
        defer { endTurn() }
        let editing = fromInput ? editingTarget : nil
        // Rows newer than this belong to this turn (a stopped empty turn removes its question).
        let newestIdBeforeSend = messages.compactMap(\.id).max()
        var sentHandle: PreparedPackHandle?
        // Per-turn flags are captured once: a re-preparation after a background
        // change (below) must describe the same turn.
        let overview = overviewForNextMessage, useWeb = useWebForNextMessage
        do {
            var reply: ChatMessage?
            var attempt = 0
            while reply == nil {
                let intent = try await captureIntent(sessionId: sid, question: text, editing: editing,
                                                     overview: overview, useWeb: useWeb)
                let key = PackIntentKey.make(intent)
                let handle: PreparedPackHandle
                do {
                    if attempt == 0, let ready = prepared, ChatSessionState.canReusePrepared(
                        preparedKey: ready.key, consumed: await ready.isConsumed, freshKey: key) {
                        handle = ready
                    } else {
                        handle = try await deps.chatHolder.engine.prepare(intent)
                    }
                    try Task.checkCancellation()
                    sentHandle = handle
                    // The intent is captured: per-turn state resets without touching the in-flight handle.
                    if fromInput { input = "" }
                    editingTarget = nil
                    overviewForNextMessage = false
                    useWebForNextMessage = false
                    reply = try await deps.chatHolder.engine.sendPrepared(
                        handle,
                        expectedKey: key,
                        onToken: { [weak self] token in
                            Task { @MainActor in self?.appendToken(token, generation: generation) }
                        },
                        onRetry: { [weak self] in
                            // Drop the failed attempt's partial text so the retry does
                            // not render appended to it.
                            Task { @MainActor in self?.resetDraft(generation: generation) }
                        }
                    )
                } catch ChatEngineError.stalePreparedRequest
                            where ChatSessionState.reprepareAfterStale(attempt: attempt) {
                    // A running folder check / extraction changed the scope's evidence
                    // between capture and send; nothing was written. Prepare the same
                    // turn again from the new snapshot (chat-during-scan-v1 §3).
                    attempt += 1
                    sentHandle = nil
                }
            }
            await reloadMessages()
            let answer = reply?.content ?? ""
            await generateFollowups(userText: text, answer: answer)
        } catch where stopRequested {
            // Stopped before streaming: the question is still in the input
            // (it clears only after preparation). Stopped while streaming: the
            // partial answer of a new turn is kept; an edit keeps the old pair.
            // Stopped before any text arrived: the question returns to the composer.
            let returnsQuestion = sentHandle != nil
                && ChatSessionState.returnsQuestion(partial: streamingDraft, isReplacement: editing != nil)
            if returnsQuestion {
                removeOrphanedQuestion(sessionId: sid, question: text, newestIdBeforeSend: newestIdBeforeSend)
            }
            await keepStoppedAnswer(sessionId: sid, handle: sentHandle, isReplacement: editing != nil)
            if let editing, sentHandle != nil {
                // The edited question returns to the composer, still editing.
                input = text
                editingTarget = editing
            } else if returnsQuestion,
                      fromInput || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A follow-up / resend never cleared the input: keep anything typed meanwhile.
                input = text
            }
        } catch {
            errorMessage = chatErrorText(error)
            await reloadMessages()
            retry = ChatSessionState.retryAfterFailedSend(question: text, messages: messages)
        }
    }

    // MARK: - Turn lifecycle + Stop

    /// Runs a send/regenerate as a task Stop can cancel; returns when it ends.
    private func runTurn(_ body: @escaping @MainActor (ChatViewModel) async -> Void) async {
        guard !sending else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await body(self)
        }
        turnTask = task
        await task.value
        if turnTask == task { turnTask = nil }
    }

    /// Stops the running answer (composer Stop button). Not an error: no
    /// error row, and a new turn keeps what has streamed so far.
    func stop() {
        guard sending, let turnTask else { return }
        stopRequested = true
        turnTask.cancel()
    }

    private func beginTurn() -> Int {
        turnGeneration += 1
        stopRequested = false
        stoppedMessageId = nil
        sending = true
        errorMessage = nil
        retry = nil
        streamingDraft = ""
        followups = []
        return turnGeneration
    }

    private func endTurn() {
        sending = false
        streamingDraft = ""
        stopRequested = false
    }

    private func appendToken(_ token: String, generation: Int) {
        guard generation == turnGeneration, sending else { return }
        streamingDraft += token
    }

    private func resetDraft(generation: Int) {
        guard generation == turnGeneration else { return }
        streamingDraft = ""
    }

    /// Persists the streamed part of a stopped new turn under its question
    /// (Core already saved the question when streaming began), with the
    /// citations it already used; nothing is written for a replacement.
    private func keepStoppedAnswer(sessionId: Int64, handle: PreparedPackHandle?, isReplacement: Bool) async {
        if let deps, let handle,
           let answer = ChatSessionState.stoppedAnswer(streamingDraft, isReplacement: isReplacement) {
            let citations = ChatSessionState.stoppedCitations(answer: answer, citationMap: handle.request.citationMap)
            do {
                let saved = try deps.store.commitContextAssistant(
                    sessionId: sessionId, content: answer, citations: citations,
                    model: handle.transport.storageModel,
                    replacesAssistantId: nil, replacesUserId: nil, replacementUserText: nil)
                stoppedMessageId = saved.id
            } catch {
                errorMessage = String(describing: error)
            }
        }
        await reloadMessages()
    }

    /// A new turn stopped before any text arrived removes the question row Core
    /// saved when streaming began (if it did), so resending stores it once.
    private func removeOrphanedQuestion(sessionId: Int64, question: String, newestIdBeforeSend: Int64?) {
        guard let deps else { return }
        do {
            let history = try deps.store.messages(sessionId: sessionId)
            if let id = ChatSessionState.orphanedQuestionId(
                question: question, messages: history, newestIdBeforeSend: newestIdBeforeSend) {
                try deps.store.deleteUnansweredQuestion(sessionId: sessionId, messageId: id)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func generateFollowups(userText: String, answer: String) async {
        guard let deps, ChatSessionState.wantsFollowups(answer: answer) else { return }
        do {
            let suggester = FollowupSuggester(chat: deps.routerHolder.router, chatModel: deps.settings.selectedChatModel)
            let suggestions = try await suggester.generate(userText: userText, answer: answer)
            // Only show if the conversation hasn't moved on.
            if ChatSessionState.acceptsFollowups(sending: sending) { followups = suggestions }
        } catch {
            // Follow-ups are best-effort; never surface an error for them.
            followups = []
        }
    }

    // MARK: - Citations + notes

    /// Opens the Citations panel content for one answer, focused on `marker`.
    func focusCitation(in message: ChatMessage, marker: Int) {
        citationFocus = CitationFocus(messageId: message.id, citations: message.citations, marker: marker)
    }

    func saveAsNote(_ msg: ChatMessage) async {
        guard let deps, let notebookId, let t else { return }
        do {
            let note = try deps.store.createNote(
                notebookId: notebookId,
                title: String(format: t.string(.chatReplyNoteTitle),
                              msg.createdAt.formatted(date: .abbreviated, time: .shortened)),
                bodyMd: msg.content,
                origin: .chat,
                originRef: msg.id
            )
            savedNoteId = note.id
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

struct SentPreviewItem: Identifiable {
    let id: Int64
    let snapshot: ContextPreviewSnapshot?
}

/// The answer whose citations the Citations panel shows.
struct CitationFocus: Equatable {
    let messageId: Int64?
    let citations: [Citation]
    var marker: Int
}

// SwiftUI `.popover(item:)` requires Identifiable.
extension Citation: Identifiable {
    public var id: Int { marker * 1_000_000 + Int(chunkId % 999_999) }
}
