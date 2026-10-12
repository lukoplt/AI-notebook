import XCTest
@testable import AINotebookCore

/// Status → strip mapping (spec 2026-10-10 §4) for every phase, the panel
/// dot, folder-row texts and the optimistic scan tracker.
final class IndexingStatusPresentationTests: XCTestCase {
    private let en = AppText(language: .english)
    private let cs = AppText(language: .czech)

    private func status(_ phase: IndexingPhase, errors: Int = 0,
                        warnings: [IndexingScanWarning] = []) -> IndexingStatus {
        IndexingStatus(phase: phase, sourceErrors: errors, scanWarnings: warnings)
    }

    private func make(_ phase: IndexingPhase, errors: Int = 0, files: Int = 0,
                      text: AppText? = nil) -> IndexingStatusPresentation? {
        IndexingStatusPresentation.make(status(phase, errors: errors), searchableFiles: files, text: text ?? en)
    }

    func testScanning() throws {
        let known = try XCTUnwrap(make(.scanning(filesSeen: 42)))
        XCTAssertEqual(known.text, "Checking folder… 42 files")
        XCTAssertEqual(known.icon, .scan)
        XCTAssertEqual(known.tone, .active)
        XCTAssertEqual(known.progress, .indeterminate)
        XCTAssertNil(known.action)
        XCTAssertEqual(make(.scanning(filesSeen: nil))?.text, "Checking…")
        XCTAssertEqual(make(.scanning(filesSeen: 3), text: cs)?.text, "Kontroluji složku… nalezeno souborů: 3")
    }

    func testExtracting() throws {
        let value = try XCTUnwrap(make(.extracting(done: 3, total: 10)))
        XCTAssertEqual(value.text, "Processing files 3 / 10")
        XCTAssertEqual(value.progress, .determinate(done: 3, total: 10))
        XCTAssertEqual(value.progress.fraction, 0.3)
        XCTAssertEqual(make(.extracting(done: 0, total: 0))?.progress, .indeterminate)
        XCTAssertEqual(make(.extracting(done: 3, total: 10), text: cs)?.text, "Zpracovávám soubory 3 / 10")
    }

    /// ingestion-memory-pressure-v1 / indexing-status-v1 §6: a slowed or paused extraction is visible.
    func testExtractingUnderMemoryPressure() throws {
        func pressured(_ level: MemoryPressureLevel, _ text: AppText) -> IndexingStatusPresentation? {
            IndexingStatusPresentation.make(IndexingStatus(phase: .extracting(done: 5300, total: 6000), sourceErrors: 0,
                                                           scanWarnings: [], memoryPressure: level),
                                            searchableFiles: 0, text: text)
        }
        let paused = try XCTUnwrap(pressured(.critical, en))
        XCTAssertEqual(paused.text, "Paused: the system is low on memory · files 5300 / 6000")
        XCTAssertEqual(paused.icon, .warning)
        XCTAssertEqual(paused.tone, .warning)
        XCTAssertEqual(paused.progress, .determinate(done: 5300, total: 6000))
        XCTAssertNil(paused.action)
        XCTAssertEqual(pressured(.critical, cs)?.text, "Pozastaveno: systému dochází paměť · soubory 5300 / 6000")
        let slowed = try XCTUnwrap(pressured(.warning, en))
        XCTAssertEqual(slowed.text, "Processing files 5300 / 6000 · slowed, the system is low on memory")
        XCTAssertEqual(slowed.icon, .file)
        XCTAssertEqual(slowed.tone, .active)
        XCTAssertEqual(pressured(.warning, cs)?.text, "Zpracovávám soubory 5300 / 6000 · zpomaleno, systému dochází paměť")
        XCTAssertEqual(pressured(.normal, en)?.text, "Processing files 5300 / 6000")
        XCTAssertTrue(IndexingStatusPresentation.showsPanelDot(IndexingStatus(phase: .extracting(done: 0, total: 1),
            sourceErrors: 0, scanWarnings: [], memoryPressure: .critical)))
    }

    func testEmbedding() throws {
        let value = try XCTUnwrap(make(.embedding(done: 120, total: 480, preparing: false)))
        XCTAssertEqual(value.text, "Indexing 120 / 480 chunks")
        XCTAssertEqual(value.icon, .indexing)
        XCTAssertEqual(value.progress.fraction, 0.25)
        for phase in [IndexingPhase.embedding(done: nil, total: nil, preparing: true),
                      .embedding(done: nil, total: nil, preparing: false),
                      .embedding(done: 0, total: 0, preparing: false)] {
            let preparing = try XCTUnwrap(make(phase))
            XCTAssertEqual(preparing.text, "Preparing index…")
            XCTAssertEqual(preparing.progress, .indeterminate)
        }
        XCTAssertEqual(make(.embedding(done: 1, total: 2, preparing: false), text: cs)?.text, "Indexuji úseky 1 / 2")
    }

    /// indexing-status-v1 §7: a running scan keeps the work line and its progress.
    func testWorkWhileScanning() throws {
        let embedding = IndexingStatus(phase: .embedding(done: 210, total: 530, preparing: false), sourceErrors: 2,
                                       scanWarnings: [], scanInProgress: true, scanFilesSeen: 2_100)
        let value = try XCTUnwrap(IndexingStatusPresentation.make(embedding, searchableFiles: 0, text: en))
        XCTAssertEqual(value.text, "Indexing 210 / 530 chunks · checking folder…")
        XCTAssertEqual(value.icon, .indexing)
        XCTAssertEqual(value.progress, .determinate(done: 210, total: 530))
        XCTAssertEqual(value.sourceErrors, "2 files couldn't be read")
        XCTAssertEqual(IndexingStatusPresentation.make(embedding, searchableFiles: 0, text: cs)?.text,
                       "Indexuji úseky 210 / 530 · kontroluji složku…")
        let extracting = IndexingStatus(phase: .extracting(done: 3, total: 10), sourceErrors: 0, scanWarnings: [],
                                        memoryPressure: .warning, scanInProgress: true, scanFilesSeen: nil)
        XCTAssertEqual(IndexingStatusPresentation.make(extracting, searchableFiles: 0, text: en)?.text,
                       "Processing files 3 / 10 · slowed, the system is low on memory · checking folder…")
        // The scanning line itself already says so.
        let scanning = IndexingStatus(phase: .scanning(filesSeen: 42), sourceErrors: 0, scanWarnings: [],
                                      scanInProgress: true, scanFilesSeen: 42)
        XCTAssertEqual(IndexingStatusPresentation.make(scanning, searchableFiles: 0, text: en)?.text, "Checking folder… 42 files")
        XCTAssertNil(IndexingStatus(phase: .ready, sourceErrors: 0, scanWarnings: [], scanFilesSeen: 5).scanFilesSeen)
    }

    func testRetrying() throws {
        let retry = IndexingRetry(code: "connectionFailed", retryAt: 1_000, attempt: 2, retryInSeconds: 37)
        let value = try XCTUnwrap(make(.retrying(retry)))
        XCTAssertEqual(value.text, "Embedding provider unavailable — retrying in 37 s")
        XCTAssertEqual(value.tone, .warning)
        XCTAssertEqual(value.action, .retryNow)
        XCTAssertEqual(value.progress, .none)
        XCTAssertEqual(IndexingStatusPresentation.title(.retryNow, text: en), "Retry now")
        XCTAssertEqual(IndexingStatusPresentation.title(.retryNow, text: cs), "Zkusit hned")
    }

    func testBlockedConfigurationReasonsOpenTheFixingSettingsSection() throws {
        let rows: [(IndexingBlockedReason, String, IndexingStatusPresentation.SettingsTarget)] = [
            (.noEmbeddingModel, "No embedding model is set up; only full-text search works.", .indexing),
            (.providerDisabled, "The embedding provider is turned off; only full-text search works.", .providers),
            (.consentRequired, "The embedding provider needs your consent before indexing.", .providers),
            (.credentialUnavailable, "The embedding provider's API key could not be loaded.", .providers),
        ]
        for (reason, text, target) in rows {
            let value = try XCTUnwrap(make(.blocked(reason)))
            XCTAssertEqual(value.text, text)
            XCTAssertEqual(value.tone, .warning)
            XCTAssertEqual(value.icon, .warning)
            XCTAssertEqual(value.action, .openSettings(target))
            XCTAssertEqual(IndexingStatusPresentation.title(value.action!, text: en), "Open settings")
        }
        // Raw values match the macOS settings section identifiers.
        XCTAssertEqual(IndexingStatusPresentation.SettingsTarget.providers.rawValue, "providers")
        XCTAssertEqual(IndexingStatusPresentation.SettingsTarget.indexing.rawValue, "indexing")
    }

    func testBlockedFailuresOfferRetry() throws {
        let failed = try XCTUnwrap(make(.blocked(.indexFailed(code: "dimensionMismatch"))))
        XCTAssertEqual(failed.text, "Indexing failed (dimensionMismatch)")
        XCTAssertEqual(failed.tone, .danger)
        XCTAssertEqual(failed.icon, .error)
        XCTAssertEqual(failed.action, .retryNow)
        let runtime = try XCTUnwrap(make(.blocked(.runtimeFailed(code: "unexpectedError"))))
        XCTAssertEqual(runtime.text, "Background indexing could not start (unexpectedError)")
        XCTAssertEqual(runtime.action, .retryNow)
        XCTAssertEqual(make(.blocked(.indexFailed(code: "x")), text: cs)?.text, "Indexování selhalo (x)")
    }

    func testReadyLexicalOnlyAndEmpty() throws {
        let ready = try XCTUnwrap(make(.ready, files: 1204))
        XCTAssertEqual(ready.text, "Searchable · 1204 files")
        XCTAssertEqual(ready.tone, .quiet)
        XCTAssertNil(ready.action)
        XCTAssertEqual(ready.progress, .none)
        XCTAssertEqual(make(.ready, files: 5, text: cs)?.text, "Prohledávatelné · souborů: 5")
        let lexical = try XCTUnwrap(make(.lexicalOnly))
        XCTAssertEqual(lexical.text, "Full-text search only")
        XCTAssertEqual(lexical.action, .buildIndex)
        XCTAssertEqual(IndexingStatusPresentation.title(.buildIndex, text: en), "Build index")
        XCTAssertNil(make(.empty))
    }

    func testSourceErrorsLineInEveryVisiblePhase() {
        XCTAssertNil(make(.ready)?.sourceErrors)
        XCTAssertEqual(make(.ready, errors: 3)?.sourceErrors, "3 files couldn't be read")
        XCTAssertEqual(make(.extracting(done: 1, total: 4), errors: 1)?.sourceErrors, "1 files couldn't be read")
        XCTAssertEqual(make(.lexicalOnly, errors: 2, text: cs)?.sourceErrors, "Nepodařilo se přečíst souborů: 2")
    }

    func testPanelDot() {
        XCTAssertFalse(IndexingStatusPresentation.showsPanelDot(nil))
        XCTAssertTrue(IndexingStatusPresentation.showsPanelDot(status(.scanning(filesSeen: nil))))
        XCTAssertTrue(IndexingStatusPresentation.showsPanelDot(status(.extracting(done: 0, total: 1))))
        XCTAssertTrue(IndexingStatusPresentation.showsPanelDot(status(.embedding(done: nil, total: nil, preparing: true))))
        XCTAssertTrue(IndexingStatusPresentation.showsPanelDot(status(.retrying(
            IndexingRetry(code: "c", retryAt: 0, attempt: 1, retryInSeconds: 0)))))
        XCTAssertTrue(IndexingStatusPresentation.showsPanelDot(status(.blocked(.noEmbeddingModel))))
        XCTAssertTrue(IndexingStatusPresentation.showsPanelDot(status(.blocked(.runtimeFailed(code: "x")))))
        XCTAssertFalse(IndexingStatusPresentation.showsPanelDot(status(.ready)))
        XCTAssertFalse(IndexingStatusPresentation.showsPanelDot(status(.lexicalOnly)))
        XCTAssertFalse(IndexingStatusPresentation.showsPanelDot(status(.empty)))
    }

    func testScanWarningAndOutcomeTexts() {
        let errorKey: (String?) -> AppText.Key = { $0 == "fileLimit" ? .folderLimitError : .folderReadError }
        func warning(_ state: String, _ error: String?, _ text: AppText) -> String {
            IndexingStatusPresentation.scanWarningText(IndexingScanWarning(folderId: 1, state: state, error: error),
                                                       text: text, errorKey: errorKey)
        }
        XCTAssertEqual(warning("partial", nil, en), "The folder or file could not be read.")
        XCTAssertEqual(warning("unavailable", "rootUnavailable", en), "Unavailable")
        XCTAssertEqual(warning("error", "fileLimit", en), "The extraction limit was exceeded.")
        XCTAssertEqual(warning("error", "somethingNew", cs), "Složku nebo soubor se nepodařilo přečíst.")
        XCTAssertEqual(IndexingStatusPresentation.scanOutcomeText(
            FolderScanOutcome(folderId: 1, changedFiles: 0, filesSeen: 812, finishedAt: 5), text: en),
            "No changes · 812 files up to date")
        XCTAssertEqual(IndexingStatusPresentation.scanOutcomeText(
            FolderScanOutcome(folderId: 1, changedFiles: 4, filesSeen: 812, finishedAt: 5), text: en),
            "4 files changed")
        XCTAssertEqual(IndexingStatusPresentation.scanOutcomeText(
            FolderScanOutcome(folderId: 1, changedFiles: 0, filesSeen: 2, finishedAt: 5), text: cs),
            "Beze změn · aktuálních souborů: 2")
    }

    // MARK: FolderScanTracker

    func testTrackerShowsCheckingUntilANewerOutcomeThenCaption() {
        var tracker = FolderScanTracker()
        let old = FolderScanOutcome(folderId: 7, changedFiles: 2, filesSeen: 10, finishedAt: 50)
        tracker.begin(folderId: 7, now: 100.4, previous: old)
        XCTAssertTrue(tracker.isPending(7))
        XCTAssertTrue(tracker.needsTicks)
        // The old outcome does not end the optimistic state.
        tracker.update(folderId: 7, scanning: false, outcome: old, now: 101)
        XCTAssertTrue(tracker.isPending(7))
        tracker.update(folderId: 7, scanning: true, outcome: old, now: 102)
        XCTAssertTrue(tracker.isPending(7))
        // A scan finished in the click's second counts (lease clock has whole seconds).
        let fresh = FolderScanOutcome(folderId: 7, changedFiles: 0, filesSeen: 10, finishedAt: 100)
        tracker.update(folderId: 7, scanning: false, outcome: fresh, now: 103)
        XCTAssertFalse(tracker.isPending(7))
        XCTAssertEqual(tracker.caption(7), fresh)
        tracker.expire(now: 103 + FolderScanTracker.captionSeconds - 0.5)
        XCTAssertEqual(tracker.caption(7), fresh)
        tracker.expire(now: 103 + FolderScanTracker.captionSeconds)
        XCTAssertNil(tracker.caption(7))
        XCTAssertFalse(tracker.needsTicks)
    }

    func testTrackerEndsWhenScanFinishedWithoutOutcomeOrTimesOut() {
        var tracker = FolderScanTracker()
        tracker.begin(folderId: 1, now: 0, previous: nil)
        tracker.update(folderId: 1, scanning: true, outcome: nil, now: 1)
        tracker.update(folderId: 1, scanning: false, outcome: nil, now: 2)
        XCTAssertFalse(tracker.isPending(1))
        XCTAssertNil(tracker.caption(1))

        tracker.begin(folderId: 2, now: 0, previous: nil)
        tracker.update(folderId: 2, scanning: false, outcome: nil, now: FolderScanTracker.pendingTimeoutSeconds)
        XCTAssertTrue(tracker.isPending(2))
        tracker.update(folderId: 2, scanning: false, outcome: nil, now: FolderScanTracker.pendingTimeoutSeconds + 1)
        XCTAssertFalse(tracker.isPending(2))
    }

    func testTrackerCancelAndStaleOutcome() {
        var tracker = FolderScanTracker()
        tracker.begin(folderId: 3, now: 200, previous: nil)
        // An outcome finished before the click (e.g. a watcher scan) is not this scan's.
        tracker.update(folderId: 3, scanning: false,
                       outcome: FolderScanOutcome(folderId: 3, changedFiles: 1, filesSeen: 1, finishedAt: 150), now: 201)
        XCTAssertTrue(tracker.isPending(3))
        tracker.cancel(folderId: 3)
        XCTAssertFalse(tracker.isPending(3))
        XCTAssertEqual(tracker.pendingFolderIds, [])
    }
}

extension IndexingStatusPresentationTests {
    /// ingestion-retry-cap-v1 §7: the chip's tooltip says the app gave up after three attempts;
    /// given-up sources never make the strip active.
    func testSourceErrorsTooltipExplainsTheRetryCap() throws {
        let ready = try XCTUnwrap(make(.ready, errors: 3, files: 10))
        XCTAssertEqual(ready.sourceErrors, "3 files couldn't be read")
        XCTAssertEqual(ready.sourceErrorsHelp, "3 files couldn't be read (gave up after 3 attempts)")
        XCTAssertEqual(make(.ready, errors: 3, text: cs)?.sourceErrorsHelp,
                       "Nepodařilo se přečíst souborů: 3 (vzdáno po 3 pokusech)")
        XCTAssertNil(make(.ready, files: 10)?.sourceErrorsHelp)
        XCTAssertFalse(status(.ready, errors: 3).isActive)
        XCTAssertFalse(status(.lexicalOnly, errors: 3).isActive)
        let scanning = IndexingStatus(phase: .embedding(done: 1, total: 2, preparing: false), sourceErrors: 2,
                                      scanWarnings: [], scanInProgress: true, scanFilesSeen: 1)
        XCTAssertEqual(IndexingStatusPresentation.make(scanning, searchableFiles: 0, text: en)?.sourceErrorsHelp,
                       "2 files couldn't be read (gave up after 3 attempts)")
    }

    func testNamedTokenFill() {
        XCTAssertEqual(IndexingStatusPresentation.fill("{done} / {total} ({code})", ["done": 1, "total": 2, "code": "x"]),
                       "1 / 2 (x)")
    }
}
