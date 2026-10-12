using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// Port of the mac TabSwitchCoordinator. The shell (ShellViewModel) subscribes to Target, maps the
/// request onto the redesigned UI (Sources/Notes → right panel, Chat → thread, Transformations →
/// run-tool dialog; see NavigationState.ApplyAsync), then Clear()s. Pairs with NoteJumpCoordinator.
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
