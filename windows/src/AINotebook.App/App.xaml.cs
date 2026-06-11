using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AINotebook.App;

public partial class App : Application
{
    public static App Current => (App)Application.Current;
    public IServiceProvider Services { get; }
    public static Window MainWindow { get; private set; } = null!;

    public static DispatcherQueue Ui { get; private set; } = null!;

    public App()
    {
        InitializeComponent();
        // Capture UI dispatcher before any background work starts.
        var uiQueue = DispatcherQueue.GetForCurrentThread();
        Services = ConfigureServices(uiQueue);
    }

    private static IServiceProvider ConfigureServices(DispatcherQueue uiQueue)
    {
        var services = new ServiceCollection();

        // --- App-layer services ---
        services.AddSingleton<DispatcherQueue>(_ => uiQueue);
        services.AddSingleton<ISettingsService, SettingsService>();
        services.AddSingleton<LocalizedStrings>();
        services.AddSingleton<ILocalizedStrings>(sp => sp.GetRequiredService<LocalizedStrings>());
        services.AddSingleton<IDialogService, DialogService>();
        services.AddSingleton<ISecretStore, WindowsPasswordVaultSecretStore>();
        services.AddSingleton<TabSwitchCoordinator>();
        services.AddSingleton<NoteJumpCoordinator>();
        services.AddSingleton<NoteEditorCoordinator>();

        // Shared HttpClient for all cloud provider requests.
        services.AddSingleton<HttpClient>(_ =>
        {
            var http = new HttpClient();
            http.Timeout = TimeSpan.FromSeconds(120);
            return http;
        });

        // --- Core service graph ---

        services.AddSingleton<NotebookStore>(sp =>
        {
            try { return new NotebookStore(StorePath.Production(), sp.GetRequiredService<ISettingsService>().Language); }
            catch (Exception ex) { throw new StartupException("Failed to open AINotebook database.", ex); }
        });

        services.AddSingleton<OllamaClient>();

        // ProviderRouter: the single IChatStreaming + IEmbeddingProducing implementation.
        // All engines get the router — it reads the active provider/model at each call.
        services.AddSingleton<ProviderRouter>(sp => new ProviderRouter(
            sp.GetRequiredService<ISettingsService>(),
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<ISecretStore>(),
            sp.GetRequiredService<OllamaClient>(),
            sp.GetRequiredService<HttpClient>()));

        // Register as the interfaces so consumers can inject IChatStreaming / IEmbeddingProducing directly.
        services.AddSingleton<IChatStreaming>(sp => sp.GetRequiredService<ProviderRouter>());
        services.AddSingleton<IEmbeddingProducing>(sp => sp.GetRequiredService<ProviderRouter>());

        // Embedder + EmbeddingWorker — model key comes from router at runtime.
        services.AddSingleton<Embedder>(sp =>
        {
            var router = sp.GetRequiredService<ProviderRouter>();
            return new Embedder(
                sp.GetRequiredService<NotebookStore>(),
                router,
                () => router.CurrentEmbeddingKey);
        });
        services.AddSingleton<EmbeddingWorker>(sp =>
            new EmbeddingWorker(sp.GetRequiredService<Embedder>()));

        // Ingestion.
        services.AddSingleton<IngestionService>(sp =>
        {
            var worker = sp.GetRequiredService<EmbeddingWorker>();
            return new IngestionService(
                sp.GetRequiredService<NotebookStore>(),
                onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; });
        });

        // NoteIndexer.
        services.AddSingleton<NoteIndexer>(sp =>
        {
            var worker = sp.GetRequiredService<EmbeddingWorker>();
            return new NoteIndexer(
                sp.GetRequiredService<NotebookStore>(),
                onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; });
        });

        // Retriever — model key also comes from router at runtime.
        services.AddSingleton<Retriever>(sp =>
        {
            var router = sp.GetRequiredService<ProviderRouter>();
            return new Retriever(
                sp.GetRequiredService<NotebookStore>(),
                router,
                () => router.CurrentEmbeddingKey);
        });

        // Engines pass the router; router ignores the chatModel param and uses live settings.
        services.AddSingleton<ChatEngine>(sp => new ChatEngine(
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<Retriever>(),
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<ISettingsService>().SelectedChatModel));

        services.AddSingleton<TransformationEngine>(sp => new TransformationEngine(
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<ISettingsService>().SelectedChatModel));

        services.AddSingleton<ChatEngineHolder>();
        services.AddSingleton<TransformationEngineHolder>();

        services.AddSingleton<AttachmentStore>(sp => new AttachmentStore(
            sp.GetRequiredService<NotebookStore>(), AttachmentStore.DefaultRoot()));

        // Epic D1: contextual enricher (opt-in setting).
        services.AddSingleton<ContextualEnricher>(sp =>
        {
            var settings = sp.GetRequiredService<ISettingsService>();
            return new ContextualEnricher(
                sp.GetRequiredService<NotebookStore>(),
                sp.GetRequiredService<ProviderRouter>(),
                () => settings.SelectedChatModel);
        });

        // Epic E1: folder watch per-notebook (singleton, notebookId set at runtime).
        services.AddSingleton<FolderWatchService>(sp =>
            new FolderWatchService(
                sp.GetRequiredService<NotebookStore>(),
                sp.GetRequiredService<IngestionService>()));

        // Epic E3: web search.
        services.AddSingleton<IWebSearch>(sp =>
            new DuckDuckGoWebSearch(sp.GetRequiredService<HttpClient>()));

        // ViewModels.
        services.AddTransient<ShellViewModel>();
        services.AddTransient<NotebookSidebarViewModel>();
        services.AddTransient<NotebookDetailViewModel>();
        services.AddTransient<ChatViewModel>();
        services.AddTransient<NotesViewModel>();
        services.AddTransient<NotesChatPanelViewModel>();
        services.AddTransient<NoteHistoryViewModel>();
        services.AddTransient<TransformationsViewModel>();
        services.AddTransient<TransformationEditorViewModel>();
        services.AddTransient<TransformationHistoryViewModel>();
        services.AddTransient<GlobalSearchViewModel>();
        services.AddTransient<SourcePreviewViewModel>();

        return services.BuildServiceProvider();
    }

    private void WireStoreCallbacks()
    {
        var store = Services.GetRequiredService<NotebookStore>();
        var indexer = Services.GetRequiredService<NoteIndexer>();
        var attachments = Services.GetRequiredService<AttachmentStore>();

        store.OnNoteSaved = noteId =>
        {
            Ui.TryEnqueue(async () =>
            {
                try { await indexer.IndexAsync(noteId); }
                catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"NoteIndexer: {ex}"); }
            });
            return Task.CompletedTask;
        };
        store.OnNoteDeleted = uuid =>
        {
            Ui.TryEnqueue(() => { try { attachments.DeleteFolder(uuid); } catch { } });
            return Task.CompletedTask;
        };

        _ = Services.GetRequiredService<EmbeddingWorker>();
        _ = Services.GetRequiredService<IngestionService>();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Ui = DispatcherQueue.GetForCurrentThread();
        WireStoreCallbacks();
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}

public sealed class StartupException : Exception
{
    public StartupException(string message, Exception inner) : base(message, inner) { }
}
