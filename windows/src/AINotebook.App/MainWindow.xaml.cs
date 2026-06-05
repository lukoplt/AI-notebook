using AINotebook.App.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace AINotebook.App;

public sealed partial class MainWindow : Window
{
    private readonly ISettingsService _settings;

    public MainWindow()
    {
        InitializeComponent();
        _settings = App.Current.Services.GetRequiredService<ISettingsService>();

        Title = "AI Notebook";
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
    }

    private void Route()
    {
        if (!_settings.HasCompletedOnboarding)
        {
            // Plan 3 swaps this placeholder for OnboardingPage.
            RootHost.Children.Clear();
            RootHost.Children.Add(new TextBlock
            {
                Text = "Onboarding (Plan 3)",
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            });
        }
        else
        {
            // M2.1 swaps this placeholder for new ShellPage().
            RootHost.Children.Clear();
            RootHost.Children.Add(new TextBlock
            {
                Text = "Shell (M2)",
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            });
        }
    }
}
