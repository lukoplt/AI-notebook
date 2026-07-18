using AINotebook.App.Onboarding;
using AINotebook.App.Services;
using AINotebook.App.Views;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace AINotebook.App;

public sealed partial class MainWindow : Window
{
    private readonly ISettingsService _settings;
    private readonly ILocalizedStrings _l;

    public MainWindow()
    {
        InitializeComponent();
        _settings = App.Current.Services.GetRequiredService<ISettingsService>();
        _l = App.Current.Services.GetRequiredService<ILocalizedStrings>();

        Title = "AI Notebook";
        NoteMenu.Title = _l["notesSectionTitle"];
        MenuSave.Text = "Save";              // literal, as in the mac app
        MenuHistory.Text = _l["historyButton"];
        ApplyMinSize();

        _settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ISettingsService.HasCompletedOnboarding))
                App.Ui.TryEnqueue(Route);
        };

        Route();
    }

    private void ApplyMinSize()
    {
        // Mirror the mac .frame(minWidth: 900, minHeight: 600) initial size.
        AppWindow.Resize(new SizeInt32(1100, 760));

        // Unpackaged apps get a generic window icon unless one is set
        // explicitly; the .ico ships as Content next to the exe.
        var icon = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico");
        if (System.IO.File.Exists(icon))
            AppWindow.SetIcon(icon);
    }

    private void Route()
    {
        if (!_settings.HasCompletedOnboarding)
        {
            RootHost.Children.Clear();
            RootHost.Children.Add(new OnboardingPage());
        }
        else
        {
            RootHost.Children.Clear();
            RootHost.Children.Add(new Views.ShellPage());
        }
    }

    private void OnMenuSave(object sender, RoutedEventArgs e)
    {
        if (CurrentPage is NotesPage notes) notes.TriggerManualSave();   // calls Editor.FlushPendingSave()
    }

    private void OnMenuHistory(object sender, RoutedEventArgs e)
    {
        if (CurrentPage is NotesPage notes) notes.TriggerHistory();      // calls ViewModel.ShowHistoryCommand
    }

    /// The page currently hosted by the active tab. Resolves the live NotesPage from the
    /// visual tree when the Notes tab is active so the window-level accelerators forward to it.
    private object? CurrentPage => FindActiveNotesPage(RootHost);

    private static NotesPage? FindActiveNotesPage(DependencyObject? root)
    {
        if (root is null) return null;
        if (root is NotesPage np) return np;
        int count = VisualTreeHelper.GetChildrenCount(root);
        for (int i = 0; i < count; i++)
        {
            var found = FindActiveNotesPage(VisualTreeHelper.GetChild(root, i));
            if (found is not null) return found;
        }
        return null;
    }
}
