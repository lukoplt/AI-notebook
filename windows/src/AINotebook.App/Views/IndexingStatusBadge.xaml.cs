using AINotebook.App.Services;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class IndexingStatusBadge : UserControl
{
    private readonly NotebookStore _store;
    private readonly ISettingsService _settings;
    private readonly LocalizedStrings _strings;
    private DispatcherQueueTimer? _timer;

    public IndexingStatusBadge()
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        _store = sp.GetRequiredService<NotebookStore>();
        _settings = sp.GetRequiredService<ISettingsService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();
        Apply(0);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var dq = DispatcherQueue.GetForCurrentThread();
        _timer = dq.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        Tick();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _timer?.Stop();
        _timer = null;
    }

    private void Tick()
    {
        int pending;
        try { pending = _store.UnembeddedCount(_settings.SelectedEmbeddingModel); }
        catch { pending = 0; }
        Apply(pending);
    }

    private void Apply(int pending)
    {
        if (pending == 0)
        {
            CheckIcon.Visibility = Visibility.Visible;
            Spinner.Visibility = Visibility.Collapsed;
            Spinner.IsActive = false;
            BadgeText.Text = _strings.Get(StringKey.IndexingComplete);
        }
        else
        {
            CheckIcon.Visibility = Visibility.Collapsed;
            Spinner.Visibility = Visibility.Visible;
            Spinner.IsActive = true;
            BadgeText.Text = string.Format(_strings.Get(StringKey.IndexingInProgress), pending);
        }
    }
}
