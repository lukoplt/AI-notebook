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
    private readonly ProviderRouter _router;
    private readonly LocalizedStrings _strings;
    private DispatcherQueueTimer? _timer;

    public IndexingStatusBadge()
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        _store = sp.GetRequiredService<NotebookStore>();
        _router = sp.GetRequiredService<ProviderRouter>();
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
        // Rows are stored under the composite "{providerId}:{model}" key
        // (router.CurrentEmbeddingKey), not the raw settings model name —
        // polling the raw name here would show "pending" forever once any
        // non-Ollama provider is selected, since no row's `model` column
        // ever matches a bare model string post-provider-registry.
        int pending;
        try { pending = _store.UnembeddedCount(_router.CurrentEmbeddingKey); }
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
