using AINotebook.App.Onboarding;
using AINotebook.App.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
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

        Title = _l.Get(StringKey.AppName);
        AppTitleText.Text = Title;
        _l.PropertyChanged += (_, _) => { Title = _l.Get(StringKey.AppName); AppTitleText.Text = Title; };

        // Codex-style chrome: content under the caption buttons, the strip above it drags the window.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        // Mica needs Windows 11; elsewhere the backdrop would be a flat system colour, so use the token.
        if (!MicaController.IsSupported())
            RootGrid.Background = (Brush)Application.Current.Resources["BgSidebarBrush"];
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
        AppWindow.Resize(new SizeInt32(1200, 800));

        // Unpackaged apps get a generic window icon unless one is set
        // explicitly; the .ico ships as Content next to the exe.
        var icon = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico");
        if (System.IO.File.Exists(icon))
            AppWindow.SetIcon(icon);
    }

    private void Route()
    {
        RootHost.Children.Clear();
        // Save (Ctrl+S) and History (Ctrl+Shift+H) live on the note document's top bar now; the
        // window-level menu bar is gone (spec §2.4).
        if (!_settings.HasCompletedOnboarding) RootHost.Children.Add(new OnboardingPage());
        else RootHost.Children.Add(new Shell.ShellPage());
    }
}
