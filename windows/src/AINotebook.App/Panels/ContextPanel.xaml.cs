using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Panels;

/// <summary>Right panel › Context: the chat's draft or sent context preview (WP8, unchanged semantics).</summary>
public sealed partial class ContextPanel : UserControl
{
    public ChatViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;
    /// <summary>"Set context size" under an assumed context window → Settings › Models &amp; limits.</summary>
    public event Action<SettingsSection>? SettingsRequested;

    public ContextPanel(ChatViewModel viewModel)
    {
        ViewModel = viewModel;
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        HintText.Text = _t.Get(StringKey.ContextPanelHint);
        BackToDraftButton.Content = _t.Get(StringKey.ContextPanelBackToDraft);
        SetContextSizeButton.Content = _t.Get(StringKey.ContextPreviewSetContextSize);
        SetContextSizeButton.Click += (_, _) => SettingsRequested?.Invoke(SettingsSection.ModelsLimits);
        var recalc = _t.Get(StringKey.ContextPreviewRecalculate);
        AutomationProperties.SetName(RecalculateButton, recalc);
        ToolTipService.SetToolTip(RecalculateButton, recalc);
    }

    /// <summary>"Next message" for the draft, "Show sent context" for a sent turn.</summary>
    public string KindLabel(bool draft, ContextPreviewViewModel? preview) =>
        preview is null ? _t.Get(StringKey.ContextPreviewTitle)
        : draft ? _t.Get(StringKey.ContextPanelDraft) : _t.Get(StringKey.ContextPreviewSent);

    public Visibility SentVisibility(bool draft, ContextPreviewViewModel? preview) =>
        preview is not null && !draft ? Visibility.Visible : Visibility.Collapsed;

    public Visibility HintVisibility(ContextPreviewViewModel? preview) =>
        preview is null ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>provider-listing-limits-v1 §5: the assumed-window warning offers Settings › Models &amp; limits.</summary>
    public Visibility AssumedVisibility(ContextPreviewViewModel? preview) =>
        preview is { ContextWindowAssumed: true } ? Visibility.Visible : Visibility.Collapsed;
}
