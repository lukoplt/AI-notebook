using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// Port of the mac TabSwitchCoordinator. The detail page subscribes to Target,
/// switches its segmented tab, then Clear()s. Pairs with NoteJumpCoordinator.
/// </summary>
public sealed partial class TabSwitchCoordinator : ObservableObject
{
    /// Mirrors the mac nested `TabSwitchCoordinator.Tab` cases (Sources=0..Transformations=3).
    public enum Tab { Sources, Chat, Notes, Transformations }

    [ObservableProperty]
    public partial Tab? Target { get; set; }

    public void Request(Tab tab) => Target = tab;
    public void Clear() => Target = null;
}
