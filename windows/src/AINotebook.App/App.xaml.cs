using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
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

    /// <summary>Non-null only for the headless CI startup smoke (<c>--startup-smoke &lt;temp-profile&gt;</c>).</summary>
    private readonly StartupSmokeProfile? _smokeProfile;

    public App()
    {
        // An unpackaged WinUI app that dies during startup shows no error UI at
        // all (stowed exception 0xC000027B); log to %TEMP%\ainotebook-crash.log
        // so field reports are diagnosable.
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogCrash("AppDomain", e.ExceptionObject as Exception);
        UnhandledException += (_, e) => LogCrash("XamlUnhandled", e.Exception);
        // Parse the smoke flag before any service exists: malformed smoke arguments exit 2 and never fall through
        // to the production profile.
        try
        {
            _smokeProfile = StartupSmokeProfile.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());
            _smokeProfile?.Create();
        }
        catch (Exception ex)
        {
            LogCrash("StartupSmokeArguments", ex);
            Environment.Exit(2);
        }
        try
        {
            InitializeComponent();
        }
        catch (Exception ex)
        {
            LogCrash("InitializeComponent", ex);
            throw;
        }
        // Capture UI dispatcher before any background work starts.
        var uiQueue = DispatcherQueue.GetForCurrentThread();
        try
        {
            Services = ConfigureServices(uiQueue, _smokeProfile);
        }
        catch (Exception ex) when (_smokeProfile is not null)
        {
            LogCrash("StartupSmokeServices", ex);
            Environment.Exit(1);
            throw;
        }
    }

    private static void LogCrash(string where, Exception? ex)
    {
        try
        {
            System.IO.File.AppendAllText(
                System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ainotebook-crash.log"),
                $"[{DateTime.Now:O}] [{where}] {ex}{Environment.NewLine}");
        }
        catch { }
    }

    private static IServiceProvider ConfigureServices(DispatcherQueue uiQueue, StartupSmokeProfile? smokeProfile = null)
    {
        var services = new ServiceCollection();

        // --- App-layer services ---
        services.AddSingleton<DispatcherQueue>(_ => uiQueue);
        services.AddSingleton<ISettingsService>(_ => smokeProfile is null
            ? new SettingsService() : new SettingsService(smokeProfile.SettingsPath));
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

        services.AddSingleton(sp => new UpdateChecker(sp.GetRequiredService<HttpClient>()));
        services.AddSingleton<UpdateState>();

        // --- Core service graph ---

        services.AddSingleton<NotebookStore>(sp =>
        {
            var settings = sp.GetRequiredService<ISettingsService>();
            string key = $"{settings.SelectedEmbeddingProviderId}:{settings.SelectedEmbeddingModel}";
            try
            {
                return new NotebookStore(
                    smokeProfile is null ? StorePath.Production() : new StorePath(smokeProfile.DatabasePath),
                    settings.Language, configuredEmbeddingModelKey: key);
            }
            catch (Exception ex)
            {
                throw new StartupException("Failed to open AINotebook database.", ex);
            }
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

        // WP6 durable folder ingestion: one process-wide admission gate and runtime. The runtime owns watches,
        // debounced rescans, reconciliation and job dispatch; views never run ingestion themselves.
        // Sized for this machine (ingestion-memory-pressure-v1 addendum A): half the cores, 6 % of RAM.
        services.AddSingleton<IngestionAdmission>(_ => IngestionAdmission.Standard());
        services.AddSingleton<IIngestLeaseClock>(_ => new SystemIngestLeaseClock());
        services.AddSingleton<NativeFolderFileSystem>(_ => new NativeFolderFileSystem());
        services.AddSingleton<LanguageDetector>(_ =>
        {
            try { return LanguageDetector.LoadBundled(); }
            catch (Exception) { return LanguageDetector.Unavailable; }
        });
        services.AddSingleton<FolderEmbeddingSessions>(sp => new FolderEmbeddingSessions(
            sp.GetRequiredService<ISettingsService>(), sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<ISecretStore>(), sp.GetRequiredService<HttpClient>()));
        services.AddSingleton<FolderIngestionRuntime>(sp =>
        {
            var store = sp.GetRequiredService<NotebookStore>();
            var clock = sp.GetRequiredService<IIngestLeaseClock>();
            var admission = sp.GetRequiredService<IngestionAdmission>();
            var fs = sp.GetRequiredService<NativeFolderFileSystem>();
            var sessions = sp.GetRequiredService<FolderEmbeddingSessions>();
            var extractor = new BoundedDocumentExtractor();
            var scanner = new FolderScanner(store, fs, UnicodeTables.LoadBundled(), clock,
                hashWidth: () => AdaptiveConcurrency.HashWidth(admission.ConcurrencyLimit));
            var extraction = new FolderExtractionWorker(store, fs, sp.GetRequiredService<LanguageDetector>(), clock,
                sessions.SelectedAsync, (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct),
                // Fetches a loose URL only for an explicit user Retry unless BackgroundWebRetry is on (ingestion-retry-cap-v1 §3a).
                web: new AINotebook.Core.Extractors.WebTextExtractor());
            var index = new FolderIndexCoordinator(store, admission, clock, sessions.CaptureAsync, sessions.SelectedAsync);
            return new FolderIngestionRuntime(store, scanner, extraction, index, new JobQueue(store, clock, admission), clock,
                admission, new NativeFolderWatchFactory(), memoryPressure: MemoryPressureLevels.SampleWindows, identity: fs,
                selectedSelection: sessions.SelectedAsync, embeddingAvailability: sessions.AvailabilityAsync,
                systemLoad: new WindowsSystemProbe().Sample);
        });

        // A kick wakes durable generation work (loose sources and notes included); the legacy Embedder is not registered.
        services.AddSingleton<EmbeddingWorker>(sp =>
        {
            var runtime = sp.GetRequiredService<FolderIngestionRuntime>();
            return new EmbeddingWorker(ct => runtime.RequestEmbeddingWorkAsync(ct));
        });

        // Ingestion: loose files use the bounded canonical extractor and fenced metadata publication.
        services.AddSingleton<IngestionService>(sp =>
        {
            var worker = sp.GetRequiredService<EmbeddingWorker>();
            return new IngestionService(
                sp.GetRequiredService<NotebookStore>(),
                onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; },
                leaseClock: sp.GetRequiredService<IIngestLeaseClock>(),
                detector: sp.GetRequiredService<LanguageDetector>(),
                embeddingSelection: sp.GetRequiredService<FolderEmbeddingSessions>().SelectedAsync);
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

        // WP8: chat prepares one immutable context pack per turn. The coordinator freezes the
        // provider session through the Core router (never App-side URLs/options), pins the
        // scoped WP5 candidate pool and WP6 coverage, and runs opt-in web search once while
        // preparing. One process-wide, memory-only preview session holds draft/sent previews.
        services.AddSingleton<ContextPreviewSession>(_ => new ContextPreviewSession());
        services.AddSingleton<ICitationOriginalResolver>(sp => new NativeCitationOriginalResolver(
            sp.GetRequiredService<NotebookStore>(), sp.GetRequiredService<NativeFolderFileSystem>()));
        services.AddSingleton<ChatEngine>(sp =>
        {
            var store = sp.GetRequiredService<NotebookStore>();
            var settings = sp.GetRequiredService<ISettingsService>();
            var coordinator = new ContextPackCoordinator(
                new CompatibilityPackDataSource(store, sp.GetRequiredService<Retriever>(), sp.GetRequiredService<IWebSearch>()),
                new CompatibilityPackTransportFactory(sp.GetRequiredService<ProviderRouter>(), settings.SelectedChatModel, store));
            return new ChatEngine(store, coordinator, sp.GetRequiredService<ContextPreviewSession>(),
                settings.SelectedChatModel, admission: sp.GetRequiredService<IngestionAdmission>());
        });

        services.AddSingleton<TransformationEngine>(sp => new TransformationEngine(
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<ISettingsService>().SelectedChatModel));

        services.AddSingleton<ChatEngineHolder>();
        services.AddSingleton<TransformationEngineHolder>();

        services.AddSingleton<AttachmentStore>(sp => new AttachmentStore(
            sp.GetRequiredService<NotebookStore>(),
            smokeProfile is null ? AttachmentStore.DefaultRoot() : smokeProfile.AttachmentsPath));

        // Epic D1: contextual enricher (opt-in setting).
        services.AddSingleton<ContextualEnricher>(sp =>
        {
            var settings = sp.GetRequiredService<ISettingsService>();
            return new ContextualEnricher(
                sp.GetRequiredService<NotebookStore>(),
                sp.GetRequiredService<ProviderRouter>(),
                () => settings.SelectedChatModel);
        });

        // Epic E1 compatibility facade over the durable runtime (until the persisted folder UI replaces its callers).
        services.AddSingleton<FolderWatchService>(sp =>
            new FolderWatchService(sp.GetRequiredService<FolderIngestionRuntime>()));

        // Epic E3: web search.
        services.AddSingleton<IWebSearch>(sp =>
            new DuckDuckGoWebSearch(sp.GetRequiredService<HttpClient>()));

        // ViewModels.
        services.AddTransient<Onboarding.OnboardingViewModel>();
        services.AddTransient<Shell.ShellViewModel>();
        services.AddTransient<Shell.SidebarViewModel>();
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

    private static bool _runtimeStarted;

    /// <summary>Starts the single durable ingestion runtime once per process, after the store is open.</summary>
    private void StartIngestionRuntime()
    {
        if (_runtimeStarted) return;
        _runtimeStarted = true;
        var runtime = Services.GetRequiredService<FolderIngestionRuntime>();
        _ = Task.Run(async () =>
        {
            try { await runtime.StartAsync().ConfigureAwait(false); }
            catch (Exception ex) { LogCrash("FolderIngestionRuntime.Start", ex); }
        });
        MainWindow.Closed += (_, _) =>
        {
            // Join the runtime off the UI thread so its continuations never need the dispatcher.
            try { Task.Run(() => runtime.StopAsync()).Wait(TimeSpan.FromSeconds(5)); }
            catch (Exception ex) { LogCrash("FolderIngestionRuntime.Stop", ex); }
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (_smokeProfile is not null)
        {
            // Headless: no window, callbacks, ingestion runtime start or update check.
            Ui = DispatcherQueue.GetForCurrentThread();
            _ = ExitAfterStartupSmokeAsync(_smokeProfile);
            return;
        }
        try
        {
            Ui = DispatcherQueue.GetForCurrentThread();
            WireStoreCallbacks();
            MainWindow = new MainWindow();
            StartIngestionRuntime();
            MainWindow.Activate();
            _ = RunStartupUpdateCheckAsync();
        }
        catch (Exception ex)
        {
            LogCrash("OnLaunched", ex);
            throw;
        }
    }

    private async Task ExitAfterStartupSmokeAsync(StartupSmokeProfile profile)
    {
        int code;
        try { code = await RunStartupSmokeAsync(profile); }
        catch (Exception ex)
        {
            LogCrash("StartupSmoke", ex);
            code = 1;
        }
        Environment.Exit(code);
    }

    /// <summary>
    /// Resolves the real service graph against the isolated profile (which runs the ordinary store migration),
    /// creates one notebook, disposes the graph, reopens the database and writes a result marker.
    /// 0 = success, 1 = failure. No network, watch, embedding, update check or secret read is invoked.
    /// </summary>
    private async Task<int> RunStartupSmokeAsync(StartupSmokeProfile profile)
    {
        int code = 1;
        long notebookId = 0;
        try
        {
            var store = Services.GetRequiredService<NotebookStore>();
            _ = Services.GetRequiredService<ProviderRouter>();
            _ = Services.GetRequiredService<IChatStreaming>();
            _ = Services.GetRequiredService<IEmbeddingProducing>();
            _ = Services.GetRequiredService<Retriever>();
            _ = Services.GetRequiredService<ChatEngine>();
            _ = Services.GetRequiredService<FolderIngestionRuntime>();
            _ = Services.GetRequiredService<AttachmentStore>();
            _ = Services.GetRequiredService<ILocalizedStrings>();
            _ = Services.GetRequiredService<ISettingsService>();
            var notebook = store.CreateNotebook("Startup smoke");
            notebookId = notebook.Id ?? throw new InvalidOperationException("Notebook ID missing.");
            if (store.Folders(notebookId).Count != 0) throw new InvalidOperationException("Unexpected folder rows.");
            code = 0;
        }
        catch (Exception ex) { LogCrash("StartupSmoke", ex); }
        finally
        {
            try
            {
                if (Services is IAsyncDisposable disposable) await disposable.DisposeAsync();
            }
            catch (Exception ex)
            {
                LogCrash("StartupSmokeDispose", ex);
                code = 1;
            }
        }
        if (code != 0) return code;
        try
        {
            using (var reopened = new NotebookStore(new StorePath(profile.DatabasePath)))
            {
                if (!reopened.Notebooks().Any(n => n.Id == notebookId))
                    throw new InvalidOperationException("Smoke notebook did not survive reopening.");
                _ = reopened.Folders(notebookId);
            }
            await System.IO.File.WriteAllTextAsync(profile.ResultPath, System.Text.Json.JsonSerializer.Serialize(new
            {
                status = "passed",
                version = AINotebookVersion.Current,
                notebookId,
                profile = profile.Root,
            }));
            return 0;
        }
        catch (Exception ex)
        {
            LogCrash("StartupSmokeReopen", ex);
            return 1;
        }
    }

    /// Launch-time update check: toggle on, ≥24h since last, onboarding done.
    /// Fully best-effort — failures are silent (spec).
    private async Task RunStartupUpdateCheckAsync()
    {
        try
        {
            var settings = Services.GetRequiredService<ISettingsService>();
            if (!settings.HasCompletedOnboarding || !settings.AutoCheckUpdates) return;
            var last = settings.LastUpdateCheckUtc;
            if (last is not null && DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24)) return;

            var checker = Services.GetRequiredService<UpdateChecker>();
            var info = await checker.CheckAsync();
            settings.LastUpdateCheckUtc = DateTimeOffset.UtcNow;
            if (!info.IsUpdateAvailable) return;
            Ui?.TryEnqueue(() =>
            {
                Services.GetRequiredService<UpdateState>().Available = info;
            });
        }
        catch
        {
            // silent by design
        }
    }
}

/// <summary>
/// Captures background embedding sessions from the current embedding settings. A session copies endpoint, model and
/// key at capture time; settings edits afterwards never redirect a running build. Unsupported, disabled or
/// unacknowledged providers yield no session (lexical search keeps working) and an <see cref="EmbeddingAvailability"/>
/// reason the Sources panel shows.
/// </summary>
internal sealed class FolderEmbeddingSessions(ISettingsService settings, NotebookStore store, ISecretStore secrets, HttpClient http)
{
    public EmbeddingSessionResolution Resolve(long notebookId)
    {
        var config = store.Provider(settings.SelectedEmbeddingProviderId);
        return FolderEmbeddingSession.Resolve(config, settings.SelectedEmbeddingModel,
            () => config is null || config.Type == ProviderType.Ollama ? null : secrets.Load(config.Id), http);
    }

    /// <summary>An unloadable credential fails the embed attempt (retryable <c>credentialUnavailable</c>).</summary>
    public Task<FolderEmbeddingSession?> CaptureAsync(long notebookId, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var resolved = Resolve(notebookId);
        if (resolved.Availability == EmbeddingAvailability.CredentialUnavailable)
            throw new FolderIngestionException("credentialUnavailable");
        return Task.FromResult(resolved.Session);
    }

    public Task<EmbeddingAvailability> AvailabilityAsync(long notebookId) => Task.FromResult(Resolve(notebookId).Availability);

    public async Task<EmbeddingSelection?> SelectedAsync(long notebookId) =>
        (await CaptureAsync(notebookId, CancellationToken.None).ConfigureAwait(false))?.Selection;
}

public sealed class StartupException : Exception
{
    public StartupException(string message, Exception inner) : base(message, inner) { }
}
