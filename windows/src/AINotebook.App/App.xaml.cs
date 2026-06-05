using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AINotebook.App;

public partial class App : Application
{
    public static App Current => (App)Application.Current;
    public IServiceProvider Services { get; }
    public static Window MainWindow { get; private set; } = null!;

    // Captured so background Core callbacks can marshal to the UI thread.
    public static DispatcherQueue Ui { get; private set; } = null!;

    public App()
    {
        InitializeComponent();
        Services = ConfigureServices();
    }

    private static IServiceProvider ConfigureServices()
    {
        var services = new ServiceCollection();

        // --- App-layer services (singletons) ---
        services.AddSingleton<ISettingsService, SettingsService>();          // M1
        services.AddSingleton<LocalizedStrings>();                           // M1 (concrete)
        services.AddSingleton<ILocalizedStrings>(sp => sp.GetRequiredService<LocalizedStrings>()); // same singleton via the interface
        services.AddSingleton<IDialogService, DialogService>();              // M2
        services.AddSingleton<TabSwitchCoordinator>();   // class defined in M3.4
        services.AddSingleton<NoteJumpCoordinator>();    // class defined in M3.4
        services.AddSingleton<NoteEditorCoordinator>();  // class defined in M3.4

        // --- Core service graph, in AINotebookApp.swift init() order ---

        // 2. Data store (fatal on failure, like the mac fatalError).
        //    Pass the persisted language so Core's BuiltinTransformations.SeedIfNeeded
        //    seeds the built-in transformations localized (NotebookStore's optional
        //    `language` ctor arg; defaults to English if omitted).
        services.AddSingleton<NotebookStore>(sp =>
        {
            try { return new NotebookStore(StorePath.Production(), sp.GetRequiredService<ISettingsService>().Language); }
            catch (Exception ex) { throw new StartupException("Failed to open AINotebook database.", ex); }
        });

        // 3. One shared OllamaClient reused by every consumer below.
        services.AddSingleton<OllamaClient>();

        // 4. Embedder + EmbeddingWorker (bind the ADAPTER, not the raw client).
        services.AddSingleton<Embedder>(sp => new Embedder(
            sp.GetRequiredService<NotebookStore>(),
            new OllamaEmbeddingAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedEmbeddingModel));
        services.AddSingleton<EmbeddingWorker>(sp =>
            new EmbeddingWorker(sp.GetRequiredService<Embedder>()));

        // 5. Ingestion -> kick the worker after chunks are written.
        services.AddSingleton<IngestionService>(sp =>
        {
            var worker = sp.GetRequiredService<EmbeddingWorker>();
            return new IngestionService(
                sp.GetRequiredService<NotebookStore>(),
                onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; });
        });

        // 6. NoteIndexer -> kick worker; wire store.OnNoteSaved.
        services.AddSingleton<NoteIndexer>(sp =>
        {
            var worker = sp.GetRequiredService<EmbeddingWorker>();
            return new NoteIndexer(
                sp.GetRequiredService<NotebookStore>(),
                onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; });
        });

        // 8. Retriever (adapter again).
        services.AddSingleton<Retriever>(sp => new Retriever(
            sp.GetRequiredService<NotebookStore>(),
            new OllamaEmbeddingAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedEmbeddingModel));

        // 9. ChatEngine (chat adapter).
        services.AddSingleton<ChatEngine>(sp => new ChatEngine(
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<Retriever>(),
            new OllamaChatAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedChatModel));

        // 10. TransformationEngine (chat adapter).
        services.AddSingleton<TransformationEngine>(sp => new TransformationEngine(
            sp.GetRequiredService<NotebookStore>(),
            new OllamaChatAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedChatModel));

        // 11. AttachmentStore + OnNoteDeleted wiring.
        services.AddSingleton<AttachmentStore>(sp => new AttachmentStore(
            sp.GetRequiredService<NotebookStore>(), AttachmentStore.DefaultRoot()));

        // ViewModels (fresh per request).
        services.AddTransient<ShellViewModel>();
        services.AddTransient<NotebookSidebarViewModel>();
        services.AddTransient<NotebookDetailViewModel>();
        services.AddTransient<ChatViewModel>();   // M5.2: fresh per notebook-switch page
        services.AddTransient<NotesViewModel>();           // M6.2
        services.AddTransient<NotesChatPanelViewModel>();  // M6.2
        services.AddTransient<NoteHistoryViewModel>();     // M6.2

        return services.BuildServiceProvider();
    }

    /// Resolve, then wire the cross-service store callbacks once
    /// (NoteIndexer/AttachmentStore depend on the store the callbacks reference).
    private void WireStoreCallbacks()
    {
        var store = Services.GetRequiredService<NotebookStore>();
        var indexer = Services.GetRequiredService<NoteIndexer>();
        var attachments = Services.GetRequiredService<AttachmentStore>();

        // Fired un-awaited off any thread; IndexAsync touches the store, so marshal.
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
            Ui.TryEnqueue(() => { try { attachments.DeleteFolder(uuid); } catch { /* best effort */ } });
            return Task.CompletedTask;
        };

        // Touch the worker/ingestion graph so singletons are constructed eagerly.
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

/// Wraps a fatal startup failure (the mac fatalError equivalent).
public sealed class StartupException : Exception
{
    public StartupException(string message, Exception inner) : base(message, inner) { }
}
