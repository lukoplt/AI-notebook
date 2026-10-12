import Foundation

/// What the Sources-panel status strip shows for an `IndexingStatus`
/// (spec 2026-10-10-indexing-progress-design §4). Pure: the App renders it
/// with design tokens; the mapping is unit-tested here for every phase.
public struct IndexingStatusPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Ready: one quiet `text-3` line.
        case quiet
        /// Work in progress (`text-2`).
        case active
        /// Needs the user (configuration, retry wait).
        case warning
        /// A failure.
        case danger
    }

    public enum Progress: Equatable, Sendable {
        case none
        case indeterminate
        case determinate(done: Int, total: Int)

        /// 0…1 for a determinate bar; nil otherwise.
        public var fraction: Double? {
            guard case let .determinate(done, total) = self, total > 0 else { return nil }
            return min(1, max(0, Double(done) / Double(total)))
        }
    }

    /// Settings section a blocked reason is fixed in (raw values = macOS `SettingsSection`):
    /// a missing embedding model → Indexing (provider/model picker); a disabled provider,
    /// missing consent or API key → Providers (same targets as Windows).
    public enum SettingsTarget: String, Equatable, Sendable {
        case providers
        case indexing
    }

    public enum Action: Equatable, Sendable {
        /// `retryIndexingNow` (retry wait, failed index, failed runtime start).
        case retryNow
        /// `retryIndexingNow` on a notebook without a current vector index.
        case buildIndex
        case openSettings(SettingsTarget)
    }

    public let icon: UITokensV1.Icon
    public let tone: Tone
    public let text: String
    public let progress: Progress
    public let action: Action?
    /// "N files couldn't be read" (nil when there are none).
    public let sourceErrors: String?
    /// Tooltip of the source-errors chip: "N files couldn't be read (gave up after 3 attempts)"
    /// (`ingestion-retry-cap-v1` §7); nil when there are no source errors.
    public let sourceErrorsHelp: String?

    public init(icon: UITokensV1.Icon, tone: Tone, text: String, progress: Progress = .none,
                action: Action? = nil, sourceErrors: String? = nil, sourceErrorsHelp: String? = nil) {
        self.icon = icon
        self.tone = tone
        self.text = text
        self.progress = progress
        self.action = action
        self.sourceErrors = sourceErrors
        self.sourceErrorsHelp = sourceErrorsHelp
    }

    /// Strip content, or nil when the strip is hidden (`empty`).
    /// `searchableFiles` is the notebook's searchable file count ("Searchable · N files").
    /// While a scan runs behind extraction/embedding (addendum §7) the work line
    /// keeps its progress and gains "· checking folder…".
    public static func make(_ status: IndexingStatus, searchableFiles: Int, text t: AppText) -> IndexingStatusPresentation? {
        guard let base = phaseLine(status, searchableFiles: searchableFiles, text: t) else { return nil }
        if case .scanning = status.phase { return base }
        guard status.scanInProgress else { return base }
        return IndexingStatusPresentation(icon: base.icon, tone: base.tone,
                                          text: fill(t.string(.indexingWithScan), ["status": base.text]),
                                          progress: base.progress, action: base.action, sourceErrors: base.sourceErrors,
                                          sourceErrorsHelp: base.sourceErrorsHelp)
    }

    private static func phaseLine(_ status: IndexingStatus, searchableFiles: Int, text t: AppText) -> IndexingStatusPresentation? {
        let errors = status.sourceErrors > 0 ? fill(t.string(.indexingSourceErrors), ["count": status.sourceErrors]) : nil
        let errorsHelp = status.sourceErrors > 0
            ? fill(t.string(.indexingSourceErrorsGaveUp), ["count": status.sourceErrors]) : nil
        func p(_ icon: UITokensV1.Icon, _ tone: Tone, _ text: String, _ progress: Progress = .none,
               _ action: Action? = nil) -> IndexingStatusPresentation {
            IndexingStatusPresentation(icon: icon, tone: tone, text: text, progress: progress, action: action,
                                       sourceErrors: errors, sourceErrorsHelp: errorsHelp)
        }
        switch status.phase {
        case .scanning(let filesSeen):
            let text = filesSeen.map { fill(t.string(.indexingScanning), ["count": $0]) } ?? t.string(.folderChecking)
            return p(.scan, .active, text, .indeterminate)
        case let .extracting(done, total):
            let progress: Progress = total > 0 ? .determinate(done: done, total: total) : .indeterminate
            let counts: [String: CustomStringConvertible] = ["done": done, "total": total]
            switch status.memoryPressure {
            case .critical?:
                // Nothing new starts until memory recovers; the runtime re-checks every tick.
                return p(.warning, .warning, fill(t.string(.indexingExtractingPaused), counts), progress)
            case .warning?:
                return p(.file, .active, fill(t.string(.indexingExtractingSlowed), counts), progress)
            case .normal?, nil:
                return p(.file, .active, fill(t.string(.indexingExtracting), counts), progress)
            }
        case let .embedding(done, total, preparing):
            guard !preparing, let done, let total, total > 0 else {
                return p(.indexing, .active, t.string(.indexingPreparing), .indeterminate)
            }
            return p(.indexing, .active, fill(t.string(.indexingEmbedding), ["done": done, "total": total]),
                     .determinate(done: done, total: total))
        case .retrying(let retry):
            return p(.warning, .warning, fill(t.string(.indexingRetrying), ["seconds": Int(retry.retryInSeconds)]),
                     .none, .retryNow)
        case .blocked(let reason):
            switch reason {
            case .noEmbeddingModel:
                return p(.warning, .warning, t.string(.indexingBlockedNoModel), .none, .openSettings(.indexing))
            case .providerDisabled:
                return p(.warning, .warning, t.string(.indexingBlockedProviderDisabled), .none, .openSettings(.providers))
            case .consentRequired:
                return p(.warning, .warning, t.string(.indexingBlockedConsent), .none, .openSettings(.providers))
            case .credentialUnavailable:
                return p(.warning, .warning, t.string(.indexingBlockedCredential), .none, .openSettings(.providers))
            case .indexFailed(let code):
                return p(.error, .danger, fill(t.string(.indexingFailed), ["code": code]), .none, .retryNow)
            case .runtimeFailed(let code):
                return p(.error, .danger, fill(t.string(.indexingRuntimeFailed), ["code": code]), .none, .retryNow)
            }
        case .ready:
            return p(.success, .quiet, fill(t.string(.indexingReady), ["count": searchableFiles]))
        case .lexicalOnly:
            return p(.search, .active, t.string(.indexingLexicalOnly), .none, .buildIndex)
        case .empty:
            return nil
        }
    }

    /// Button title of an action.
    public static func title(_ action: Action, text t: AppText) -> String {
        switch action {
        case .retryNow: t.string(.indexingRetryNow)
        case .buildIndex: t.string(.indexingBuildIndex)
        case .openSettings: t.string(.indexingOpenSettings)
        }
    }

    /// Right-panel toggle dot (top bar): work in progress or something blocked.
    public static func showsPanelDot(_ status: IndexingStatus?) -> Bool {
        guard let status else { return false }
        if status.isActive { return true }
        if case .blocked = status.phase { return true }
        return false
    }

    /// Folder-row text for a scan warning (same table as Windows `FolderSourceItem.ErrorText`):
    /// unavailable root → "Unavailable"; failed scan → its persisted code explained by
    /// `errorKey` (the App's folder error table); partial scan → the read error.
    public static func scanWarningText(_ warning: IndexingScanWarning, text t: AppText,
                                       errorKey: (String?) -> AppText.Key) -> String {
        switch warning.state {
        case "unavailable": return t.string(.folderUnavailable)
        case "error": return t.string(errorKey(warning.error))
        default: return t.string(.folderReadError)
        }
    }

    /// Replaces `{name}` tokens (the shared EN/CS string convention, e.g. `folderFilesCount`).
    static func fill(_ template: String, _ values: [String: CustomStringConvertible]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value.description) }
    }

    /// Transient caption after a finished scan: "No changes · N files up to date" or "N files changed".
    public static func scanOutcomeText(_ outcome: FolderScanOutcome, text t: AppText) -> String {
        outcome.changedFiles == 0
            ? fill(t.string(.folderNoChanges), ["count": outcome.filesSeen])
            : fill(t.string(.folderChangedFiles), ["count": outcome.changedFiles])
    }
}

/// Optimistic "Checking…" state of folder rows after Scan now / Verify all,
/// and the transient caption once that scan finished. Pure state machine
/// (times in seconds since 1970, the ingestion lease clock).
public struct FolderScanTracker: Equatable, Sendable {
    /// Seconds the outcome caption stays visible.
    public static let captionSeconds: Double = 4
    /// The optimistic state never outlives this without a scan being observed.
    public static let pendingTimeoutSeconds: Double = 60

    struct Pending: Equatable, Sendable {
        var clickedAt: Double
        var previous: FolderScanOutcome?
        var sawScanning = false
    }

    struct Caption: Equatable, Sendable {
        var outcome: FolderScanOutcome
        var expiresAt: Double
    }

    private var pending: [Int64: Pending] = [:]
    private var captions: [Int64: Caption] = [:]

    public init() {}

    /// The user asked for a scan; `previous` is the folder's last outcome at that moment.
    public mutating func begin(folderId: Int64, now: Double, previous: FolderScanOutcome?) {
        pending[folderId] = Pending(clickedAt: now, previous: previous)
        captions[folderId] = nil
    }

    /// The request failed: drop the optimistic state.
    public mutating func cancel(folderId: Int64) {
        pending[folderId] = nil
    }

    /// Feeds the latest facts for one folder: whether it is scanning right now
    /// and its last finished scan. A newer outcome than the one seen at the
    /// click ends the optimistic state and shows the caption.
    public mutating func update(folderId: Int64, scanning: Bool, outcome: FolderScanOutcome?, now: Double) {
        guard var item = pending[folderId] else { return }
        if let outcome, outcome != item.previous, Double(outcome.finishedAt) >= item.clickedAt.rounded(.down) {
            pending[folderId] = nil
            captions[folderId] = Caption(outcome: outcome, expiresAt: now + Self.captionSeconds)
        } else if scanning {
            item.sawScanning = true
            pending[folderId] = item
        } else if item.sawScanning || now - item.clickedAt > Self.pendingTimeoutSeconds {
            // Finished without a recorded outcome (or never started): stop spinning.
            pending[folderId] = nil
        }
    }

    /// Drops expired captions.
    public mutating func expire(now: Double) {
        captions = captions.filter { $0.value.expiresAt > now }
    }

    public mutating func remove(folderId: Int64) {
        pending[folderId] = nil
        captions[folderId] = nil
    }

    public func isPending(_ folderId: Int64) -> Bool { pending[folderId] != nil }

    public func caption(_ folderId: Int64) -> FolderScanOutcome? { captions[folderId]?.outcome }

    public var pendingFolderIds: Set<Int64> { Set(pending.keys) }

    /// Something time-based is on screen (spinner or caption): keep refreshing.
    public var needsTicks: Bool { !pending.isEmpty || !captions.isEmpty }
}
