using AINotebook.App.Services;
using AINotebook.Core.Models;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public sealed partial class SourceItem : ObservableObject
{
    private readonly LocalizedStrings _strings;

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

    public bool HasSummary => !string.IsNullOrWhiteSpace(Summary);
    // Offer "Summarize" only for a ready source that has no summary yet and isn't already running.
    public bool CanSummarize => Status == SourceStatus.Ready && !HasSummary && !IsSummarizing;

    // Localized labels surfaced as bindable properties (DataTemplate can't x:Name per item).
    public string SummarizeButtonText => _strings.Get(StringKey.SourceSummarizeButton);
    public string SummarizingText => _strings.Get(StringKey.SourceSummarizingStatus);

    public SourceItem(Source source, LocalizedStrings strings)
    {
        _strings = strings;
        Id = source.Id!.Value;
        Title = source.Title;
        Status = source.Status;
    }

    public string StatusText => Status switch
    {
        SourceStatus.Pending => _strings.Get(StringKey.SourceStatusPending),
        SourceStatus.Chunking => _strings.Get(StringKey.SourceStatusChunking),
        SourceStatus.Ready => _strings.Get(StringKey.SourceStatusReady),
        SourceStatus.Error => _strings.Get(StringKey.SourceStatusError),
        _ => _strings.Get(StringKey.SourceStatusPending)
    };

    partial void OnStatusChanged(SourceStatus value)
    {
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(CanSummarize));
    }

    partial void OnSummaryChanged(string? value)
    {
        OnPropertyChanged(nameof(HasSummary));
        OnPropertyChanged(nameof(CanSummarize));
    }

    partial void OnIsSummarizingChanged(bool value) => OnPropertyChanged(nameof(CanSummarize));
}
