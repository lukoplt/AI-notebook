using AINotebook.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// Bridges the launch-time update check to the ShellPage banner.
/// UI-thread only (mutated via App.Ui.TryEnqueue).
public sealed partial class UpdateState : ObservableObject
{
    [ObservableProperty]
    public partial UpdateInfo? Available { get; set; }

    [ObservableProperty]
    public partial bool BannerDismissed { get; set; }
}
