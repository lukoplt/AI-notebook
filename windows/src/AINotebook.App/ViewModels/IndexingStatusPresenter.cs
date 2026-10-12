using System.Globalization;
using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.Core.Ingestion;

namespace AINotebook.App.ViewModels;

/// <summary>Colour role of the Sources status strip (tokens: Text2, Text3, Warning, Danger).</summary>
public enum IndexingStripTone { Neutral, Quiet, Warning, Danger }

/// <summary>The one action the strip offers for the current phase.</summary>
public enum IndexingStripAction { None, RetryNow, OpenSettings, BuildIndex }

/// <summary>
/// What the Sources status strip shows (spec 2026-10-10 indexing progress §4). <see cref="ProgressFraction"/> is 0…1 when
/// done/total are known and null for an indeterminate bar; <see cref="IconKey"/> names a Tokens.xaml icon string.
/// </summary>
public sealed record IndexingStripDisplay(
    bool IsVisible,
    string Text,
    string? SecondaryText,
    string IconKey,
    IndexingStripTone Tone,
    bool ShowProgress,
    double? ProgressFraction,
    IndexingStripAction Action,
    string? ActionLabel,
    SettingsSection? SettingsTarget)
{
    public static IndexingStripDisplay Hidden { get; } =
        new(false, "", null, "IconIndexing", IndexingStripTone.Quiet, false, null, IndexingStripAction.None, null, null);

    public bool IsIndeterminate => ShowProgress && ProgressFraction is null;

    /// <summary>Tooltip of the "N files couldn't be read" line: "… (gave up after 3 attempts)" (ingestion-retry-cap-v1 §7).</summary>
    public string? SecondaryHelp { get; init; }

    /// <summary>"Retry all failed" next to the "N files couldn't be read" line; null when there are no source errors.</summary>
    public string? RetryAllLabel { get; init; }
}

/// <summary>Pure IndexingStatus → strip mapping, shared by the Sources panel and its tests (no WinUI types).</summary>
public static class IndexingStatusPresenter
{
    /// <param name="searchableFiles">Files the panel counts as searchable (for "Searchable · N files").</param>
    /// <remarks>While a scan runs behind extraction/embedding (indexing-status-v1 §7) the work line keeps its progress
    /// and gains "· checking folder…".</remarks>
    public static IndexingStripDisplay Present(IndexingStatus? status, int searchableFiles, Func<StringKey, string> text)
    {
        var display = PresentPhase(status, searchableFiles, text);
        if (!display.IsVisible || status is not { ScanInProgress: true } || status.Phase == IndexingPhase.Scanning) return display;
        return display with
        {
            Text = text(StringKey.IndexingWithScan).Replace("{status}", display.Text, StringComparison.Ordinal)
        };
    }

    private static IndexingStripDisplay PresentPhase(IndexingStatus? status, int searchableFiles, Func<StringKey, string> text)
    {
        if (status is null || status.Phase == IndexingPhase.Empty) return IndexingStripDisplay.Hidden;
        string? secondary = status.SourceErrors > 0 ? Count(text(StringKey.IndexingSourceErrors), status.SourceErrors) : null;
        string? secondaryHelp = status.SourceErrors > 0 ? Count(text(StringKey.IndexingSourceErrorsGaveUp), status.SourceErrors) : null;
        string? retryAll = status.SourceErrors > 0 ? text(StringKey.IndexingRetryAllFailed) : null;
        IndexingStripDisplay Show(string line, string icon, IndexingStripTone tone, bool progress = false, double? fraction = null,
            IndexingStripAction action = IndexingStripAction.None, StringKey? label = null, SettingsSection? target = null) =>
            new(true, line, secondary, icon, tone, progress, fraction, action, label is { } key ? text(key) : null, target)
            {
                SecondaryHelp = secondaryHelp,
                RetryAllLabel = retryAll,
            };

        switch (status.Phase)
        {
            case IndexingPhase.Scanning:
                return Show(status.FilesSeen is int seen ? Count(text(StringKey.IndexingScanning), seen) : text(StringKey.FolderChecking),
                    "IconScan", IndexingStripTone.Neutral, progress: true);
            case IndexingPhase.Extracting:
                // ingestion-memory-pressure-v1: critical pauses new extractions (re-checked every tick), warning slows them.
                if (status.MemoryPressure == MemoryPressureLevel.Critical)
                    return Show(Progress(text(StringKey.IndexingExtractingPaused), status.Done ?? 0, status.Total ?? 0), "IconWarning",
                        IndexingStripTone.Warning, progress: true, fraction: Fraction(status.Done, status.Total));
                var extracting = status.MemoryPressure == MemoryPressureLevel.Warning
                    ? StringKey.IndexingExtractingSlowed : StringKey.IndexingExtracting;
                return Show(Progress(text(extracting), status.Done ?? 0, status.Total ?? 0), "IconFile",
                    IndexingStripTone.Neutral, progress: true, fraction: Fraction(status.Done, status.Total));
            case IndexingPhase.Embedding:
                // A bootstrap (dimensions unknown) or a generation without counts yet reads as "Preparing index…".
                if (status.Preparing || status.Done is null || status.Total is not > 0)
                    return Show(text(StringKey.IndexingPreparing), "IconIndexing", IndexingStripTone.Neutral, progress: true);
                return Show(Progress(text(StringKey.IndexingEmbedding), status.Done.Value, status.Total.Value), "IconIndexing",
                    IndexingStripTone.Neutral, progress: true, fraction: Fraction(status.Done, status.Total));
            case IndexingPhase.Retrying:
                long seconds = Math.Max(0, status.Retry?.RetryInSeconds ?? 0);
                return Show(text(StringKey.IndexingRetrying).Replace("{seconds}", seconds.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal),
                    "IconWarning", IndexingStripTone.Warning, action: IndexingStripAction.RetryNow, label: StringKey.IndexingRetryNow);
            case IndexingPhase.Blocked:
                return Blocked(status, text, Show);
            case IndexingPhase.Ready:
                return Show(Count(text(StringKey.IndexingReady), Math.Max(0, searchableFiles)), "IconSuccess", IndexingStripTone.Quiet);
            case IndexingPhase.LexicalOnly:
                return Show(text(StringKey.IndexingLexicalOnly), "IconSearch", IndexingStripTone.Neutral,
                    action: IndexingStripAction.BuildIndex, label: StringKey.IndexingBuildIndex);
            default:
                return IndexingStripDisplay.Hidden;
        }
    }

    private static IndexingStripDisplay Blocked(IndexingStatus status, Func<StringKey, string> text,
        Func<string, string, IndexingStripTone, bool, double?, IndexingStripAction, StringKey?, SettingsSection?, IndexingStripDisplay> show)
    {
        string code = string.IsNullOrWhiteSpace(status.ErrorCode) ? "unknown" : status.ErrorCode!;
        return status.BlockedReason switch
        {
            IndexingBlockedReason.IndexFailed => show(Code(text(StringKey.IndexingFailed), code), "IconError", IndexingStripTone.Danger,
                false, null, IndexingStripAction.RetryNow, StringKey.IndexingRetryNow, null),
            IndexingBlockedReason.RuntimeFailed => show(Code(text(StringKey.IndexingRuntimeFailed), code), "IconError",
                IndexingStripTone.Danger, false, null, IndexingStripAction.RetryNow, StringKey.IndexingRetryNow, null),
            // The embedding model is picked in Settings › Indexing; provider switches, consent and keys live in Providers.
            IndexingBlockedReason.NoEmbeddingModel => show(text(StringKey.IndexingBlockedNoModel), "IconWarning",
                IndexingStripTone.Warning, false, null, IndexingStripAction.OpenSettings, StringKey.IndexingOpenSettings, SettingsSection.Indexing),
            IndexingBlockedReason.ProviderDisabled => show(text(StringKey.IndexingBlockedProviderDisabled), "IconWarning",
                IndexingStripTone.Warning, false, null, IndexingStripAction.OpenSettings, StringKey.IndexingOpenSettings, SettingsSection.Providers),
            IndexingBlockedReason.ConsentRequired => show(text(StringKey.IndexingBlockedConsent), "IconWarning",
                IndexingStripTone.Warning, false, null, IndexingStripAction.OpenSettings, StringKey.IndexingOpenSettings, SettingsSection.Providers),
            IndexingBlockedReason.CredentialUnavailable => show(text(StringKey.IndexingBlockedCredential), "IconWarning",
                IndexingStripTone.Warning, false, null, IndexingStripAction.OpenSettings, StringKey.IndexingOpenSettings, SettingsSection.Providers),
            _ => show(Code(text(StringKey.IndexingFailed), code), "IconError", IndexingStripTone.Danger,
                false, null, IndexingStripAction.RetryNow, StringKey.IndexingRetryNow, null),
        };
    }

    /// <summary>Right-panel toggle dot: work in progress or a blocked notebook while the panel is closed.</summary>
    public static bool ShowsPanelDot(IndexingStatus? status) =>
        status is not null && (status.IsActive || status.Phase == IndexingPhase.Blocked);

    /// <summary>"No changes · N files up to date" or "N files changed" for a finished user-requested scan.</summary>
    public static string ScanOutcomeCaption(FolderScanOutcome outcome, Func<StringKey, string> text) =>
        outcome.ChangedFiles > 0
            ? Count(text(StringKey.FolderChangedFiles), outcome.ChangedFiles)
            : Count(text(StringKey.FolderNoChanges), outcome.FilesSeen);

    private static double? Fraction(int? done, int? total) =>
        done is int d && total is int t && t > 0 ? Math.Clamp((double)d / t, 0, 1) : null;

    // Named tokens shared with macOS AppText (plain integers, like folderFilesCount).
    private static string Count(string format, long count) =>
        format.Replace("{count}", count.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);

    private static string Progress(string format, int done, int total) =>
        format.Replace("{done}", done.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
              .Replace("{total}", total.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);

    private static string Code(string format, string code) => format.Replace("{code}", code, StringComparison.Ordinal);
}
