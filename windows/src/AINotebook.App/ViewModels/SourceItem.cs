using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;

namespace AINotebook.App.ViewModels;

public sealed partial class SourceItem : ObservableObject
{
    private readonly Func<StringKey, string> _text;

    public long Id { get; }
    public string Title { get; }

    [ObservableProperty]
    public partial SourceStatus Status { get; set; }

    // Per-source summary (Tier 2b). Loaded from store.SourceSummary on refresh,
    // set after on-demand summarization.
    [ObservableProperty]
    public partial string? Summary { get; set; }

    [ObservableProperty]
    public partial bool IsSummarizing { get; set; }

    [ObservableProperty]
    public partial bool IsSelected { get; set; }

    [ObservableProperty]
    public partial bool IsRefreshing { get; set; }

    /// <summary>Extraction was given up after three failed attempts (ingestion-retry-cap-v1).</summary>
    [ObservableProperty]
    public partial bool IsGaveUp { get; set; }

    /// <summary>Drives the per-row bulk checkbox (rows live in one heterogeneous list, so no ElementName binding).</summary>
    [ObservableProperty]
    public partial bool IsBulkMode { get; set; }

    public bool HasSummary => !string.IsNullOrWhiteSpace(Summary);
    // Offer "Summarize" only for a ready source that has no summary yet and isn't already running.
    public bool CanSummarize => Status == SourceStatus.Ready && !HasSummary && !IsSummarizing;
    public bool IsUrl => Source.Type == SourceType.Web && Source.Uri is not null;
    /// <summary>A failed folder member or loose file/URL offers "Retry" (its failure budget starts over).</summary>
    public bool CanRetry => Status == SourceStatus.Error && Source.Type != SourceType.Note &&
        (IsFolderMember || Source.RawPath is not null || Source.Uri is not null);
    public string RetryText => _text(StringKey.SourceRetryButton);

    public Source Source { get; }

    // B8: tags assigned to this source.
    public ObservableCollection<Tag> Tags { get; } = new();

    // Localized labels surfaced as bindable properties (DataTemplate can't x:Name per item).
    public string SummarizeButtonText => _text(StringKey.SourceSummarizeButton);
    public string SummarizingText => _text(StringKey.SourceSummarizingStatus);

    public SourceItem(Source source, LocalizedStrings strings) : this(source, strings.Get) { }

    public SourceItem(Source source, Func<StringKey, string> text)
    {
        _text = text;
        Source = source;
        Id = source.Id!.Value;
        Title = source.Title;
        Status = source.Status;
    }

    /// <summary>A folder member is listed under its folder by relative path (the title alone is ambiguous).</summary>
    public bool IsFolderMember => Source.FolderId is not null;
    /// <summary>Row icon (tokens-v1 icon map): a link for web sources, a document otherwise.</summary>
    public string KindGlyph => AINotebook.Core.Text.UITokensV1.Icons[IsUrl ? "addUrl" : "file"].Glyph;
    public string DisplayTitle => IsFolderMember && !string.IsNullOrEmpty(Source.RelPath) ? Source.RelPath! : Title;
    public Thickness IndentMargin => IsFolderMember ? new Thickness(28, 0, 0, 0) : new Thickness(0);

    /// <summary>Missing / unavailable member files are flagged; a present file shows no availability badge.</summary>
    public string? AvailabilityText => Source.Availability switch
    {
        "missing" => _text(StringKey.FolderMissing),
        "unavailable" => _text(StringKey.FolderUnavailable),
        _ => null
    };

    public string? LanguageBadge => LanguageBadgeText(Source.Lang, _text);
    public string LanguageLabel => _text(StringKey.SourceLanguageLabel);

    /// <summary>cs/sk/en/de as an upper-case code, "mixed" localized; undetermined or unknown shows nothing.</summary>
    public static string? LanguageBadgeText(string? lang, Func<StringKey, string> text) => lang switch
    {
        "cs" or "sk" or "en" or "de" => lang!.ToUpperInvariant(),
        "mixed" => text(StringKey.SourceLanguageMixed),
        _ => null
    };

    public string StatusText => Status switch
    {
        SourceStatus.Pending => _text(StringKey.SourceStatusPending),
        SourceStatus.Chunking => _text(StringKey.SourceStatusChunking),
        SourceStatus.Ready => _text(StringKey.SourceStatusReady),
        SourceStatus.Error => (ErrorDetail is { } detail
            ? _text(StringKey.SourceStatusError) + " · " + detail : _text(StringKey.SourceStatusError))
            + (IsGaveUp ? " · " + _text(StringKey.SourceGaveUp) : ""),
        _ => _text(StringKey.SourceStatusPending)
    };

    /// <summary>Localized explanation of the persisted error code (same table as macOS), or null.</summary>
    public string? ErrorDetail =>
        AINotebook.Core.Ingestion.IngestionErrorText.KeyName(Source.Error) is { } name &&
        Enum.TryParse<StringKey>(name, ignoreCase: true, out var key) ? _text(key) : null;

    partial void OnStatusChanged(SourceStatus value)
    {
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(CanSummarize));
        OnPropertyChanged(nameof(CanRetry));
    }

    partial void OnIsGaveUpChanged(bool value) => OnPropertyChanged(nameof(StatusText));

    partial void OnSummaryChanged(string? value)
    {
        OnPropertyChanged(nameof(HasSummary));
        OnPropertyChanged(nameof(CanSummarize));
    }

    partial void OnIsSummarizingChanged(bool value) => OnPropertyChanged(nameof(CanSummarize));
}
