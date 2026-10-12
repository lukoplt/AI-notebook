import AINotebookCore
import SwiftUI

/// Status strip at the top of the Sources panel (spec 2026-10-10 §4): what
/// indexing is doing for the current notebook, why it cannot proceed, and the
/// one action that fixes it. Hidden for an empty notebook. Replaces the old
/// header badge, whose "Not yet searchable" ignored full-text search.
struct IndexingStatusStrip: View {
    /// "N files couldn't be read" filters the panel to the failing sources.
    @Binding var showingErrorsOnly: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var indexing: IndexingStatusModel
    @EnvironmentObject private var folderWatch: FolderWatchController
    @Environment(\.openSettings) private var openSettings

    private var t: AppText { settings.text }

    var body: some View {
        if let status = indexing.status,
           let presentation = IndexingStatusPresentation.make(status, searchableFiles: indexing.searchableFiles, text: t) {
            VStack(spacing: 0) {
                IndexingStatusStripView(
                    presentation: presentation,
                    actionTitle: presentation.action.map { IndexingStatusPresentation.title($0, text: t) },
                    detail: detail(status),
                    showingErrorsOnly: showingErrorsOnly,
                    onAction: { perform(presentation.action) },
                    onSourceErrors: { showingErrorsOnly.toggle() },
                    retryAllTitle: t.string(.indexingRetryAllFailed),
                    onRetryAll: { Task { await indexing.retryAllFailed() } }
                )
                Hairline()
            }
            .onChange(of: status.sourceErrors) { _, count in if count == 0 { showingErrorsOnly = false } }
        }
    }

    /// Tooltip detail: a failed action, or the runtime's own start error.
    private func detail(_ status: IndexingStatus) -> String? {
        if let actionError = indexing.actionError { return actionError }
        if case .blocked(.runtimeFailed) = status.phase { return folderWatch.errorMessage }
        return nil
    }

    private func perform(_ action: IndexingStatusPresentation.Action?) {
        switch action {
        case .retryNow, .buildIndex:
            Task { await indexing.retryNow() }
        case .openSettings(let target):
            // The Settings window follows its remembered section (also when already open).
            UserDefaults.standard.set(target.rawValue, forKey: SettingsSection.storageKey)
            openSettings()
        case nil:
            break
        }
    }
}

/// Environment-free face of the strip (also rendered for debug screenshots).
struct IndexingStatusStripView: View {
    let presentation: IndexingStatusPresentation
    var actionTitle: String?
    var detail: String?
    var showingErrorsOnly = false
    var onAction: () -> Void = {}
    var onSourceErrors: () -> Void = {}
    /// "Retry all failed", offered while the panel shows only the failing sources.
    var retryAllTitle: String?
    var onRetryAll: () -> Void = {}

    private var textColor: DesignTokens.ColorToken {
        switch presentation.tone {
        case .quiet: .text3
        case .active: .text2
        case .warning: .warning
        case .danger: .danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
            HStack(alignment: .center, spacing: DesignTokens.spacing(8)) {
                TokenIcon(icon: presentation.icon, color: presentation.tone == .active ? .text3 : textColor)
                Text(presentation.text)
                    .tokenFont(.caption)
                    .tokenForeground(textColor)
                    .monospacedDigit()
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let actionTitle {
                    Button(action: onAction) { Text(actionTitle).tokenFont(.caption) }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
            }
            .frame(minHeight: DesignTokens.size(.hitMin))
            switch presentation.progress {
            case .none:
                EmptyView()
            case .indeterminate:
                ThinProgressBar(fraction: nil)
            case .determinate:
                ThinProgressBar(fraction: presentation.progress.fraction)
            }
            if let errors = presentation.sourceErrors {
                HStack(spacing: DesignTokens.spacing(8)) {
                    ChipButton(errors, icon: .warning, isActive: showingErrorsOnly, action: onSourceErrors)
                        .help(presentation.sourceErrorsHelp ?? errors)
                    if showingErrorsOnly, let retryAllTitle {
                        Button(action: onRetryAll) { Text(retryAllTitle).tokenFont(.caption) }
                            .buttonStyle(.secondary)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, DesignTokens.spacing(4))
            }
        }
        .padding(.horizontal, DesignTokens.spacing(12))
        .padding(.vertical, DesignTokens.spacing(4))
        .help(detail ?? presentation.text)
        .accessibilityElement(children: .contain)
    }
}

/// Thin token-coloured progress bar: determinate fill, or a sliding segment
/// when the amount is unknown (static under Reduce Motion).
struct ThinProgressBar: View {
    /// 0…1, nil = indeterminate.
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(DesignTokens.color(.surface2))
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(DesignTokens.color(.text3))
                        .frame(width: max(width * fraction, fraction > 0 ? DesignTokens.spacing(4) : 0))
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let period = 1.4
                        let phase = reduceMotion ? 0.35
                            : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        Capsule(style: .continuous)
                            .fill(DesignTokens.color(.text3))
                            .frame(width: width * 0.3)
                            .offset(x: (width * 1.3) * phase - width * 0.3)
                    }
                }
            }
        }
        .frame(height: DesignTokens.spacing(4))
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? "")
    }
}
