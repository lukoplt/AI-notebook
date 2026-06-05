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

    partial void OnStatusChanged(SourceStatus value) => OnPropertyChanged(nameof(StatusText));
}
