using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

/// <summary>
/// A checkable source in the chat "Sources" scope picker (Tier 3). When the
/// user unchecks some, only the checked source ids are passed to the chat
/// engine; when all are checked the scope is treated as unrestricted.
/// </summary>
public sealed partial class ScopeSourceItem : ObservableObject
{
    public long Id { get; }
    public string Title { get; }

    [ObservableProperty]
    public partial bool IsSelected { get; set; }

    public ScopeSourceItem(long id, string title, bool isSelected = true)
    {
        Id = id;
        Title = title;
        IsSelected = isSelected;
    }
}
