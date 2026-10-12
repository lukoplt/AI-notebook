using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Panels;

/// <summary>Right panel › Citations: one place for citations on both platforms (replaces the popover).</summary>
public sealed partial class CitationsPanel : UserControl
{
    public ChatViewModel ViewModel { get; }
    private static ILocalizedStrings Strings => App.Current.Services.GetRequiredService<ILocalizedStrings>();

    public CitationsPanel(ChatViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        EmptyText.Text = Strings.Get(StringKey.CitationsPanelEmpty);
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ChatViewModel.SelectedCitation)) ScrollToFocused();
        };
        Loaded += (_, _) => ScrollToFocused();
    }

    /// <summary>"p. 12" / "s. 12" (x:Bind function); null hides the line.</summary>
    public static string? PageText(int? page) => page is int p
        ? string.Format(System.Globalization.CultureInfo.CurrentCulture, Strings.Get(StringKey.CitationPage), p)
        : null;

    public static Visibility PageVisibility(int? page) => page is null ? Visibility.Collapsed : Visibility.Visible;

    public Visibility EmptyVisibility(int count) => count == 0 ? Visibility.Visible : Visibility.Collapsed;

    public static string OpenLabel(long? noteId) =>
        Strings.Get(noteId is null ? StringKey.CitationOpenOriginal : StringKey.OpenNote);

    private void ScrollToFocused()
    {
        if (ViewModel.SelectedCitation is { } focused) CitationList.ScrollIntoView(focused);
    }

    /// <summary>Note citations open the note as a document; files go through Core's click-time resolver.</summary>
    private async void OnOpenCitation(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: CitationViewModel cvm }) return;
        if (cvm.NoteIdToOpen is long noteId) ViewModel.RequestOpenNote(noteId);
        else await ViewModel.OpenCitationOriginalCommand.ExecuteAsync(cvm);
    }
}
