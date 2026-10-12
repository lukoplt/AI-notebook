using System.Xml.Linq;
using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.App.ViewModels;
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>
/// Indexing progress UI (spec 2026-10-10 §4): status → strip mapping, right-panel dot, folder scan feedback, the
/// per-notebook watcher and the SourcesViewModel error handling. Pure: no WinUI window; the dispatcher is null.
/// </summary>
public sealed class IndexingStatusUiTests
{
    private static readonly Dictionary<string, string> En = Resw("en.resw");
    private static readonly Dictionary<string, string> Cs = Resw("cs.resw");

    private static string Text(StringKey key) => En[char.ToLowerInvariant(key.ToString()[0]) + key.ToString()[1..]];

    private static IndexingStatus Status(IndexingPhase phase, int? filesSeen = null, int? done = null, int? total = null,
        bool preparing = false, IndexingRetry? retry = null, IndexingBlockedReason? reason = null, string? code = null,
        int sourceErrors = 0) =>
        new(phase, filesSeen, done, total, preparing, retry, reason, code, sourceErrors, []);

    /// <summary>ingestion-memory-pressure-v1 / indexing-status-v1 §6: a slowed or paused extraction is visible.</summary>
    [Fact]
    public void ExtractingUnderMemoryPressureIsVisible()
    {
        IndexingStatus Pressured(MemoryPressureLevel level) =>
            Status(IndexingPhase.Extracting, done: 5300, total: 6000) with { MemoryPressure = level };
        var paused = IndexingStatusPresenter.Present(Pressured(MemoryPressureLevel.Critical), 0, Text);
        Assert.Equal(("Paused: the system is low on memory · files 5300 / 6000", "IconWarning", IndexingStripTone.Warning),
            (paused.Text, paused.IconKey, paused.Tone));
        Assert.Equal((true, IndexingStripAction.None), (paused.ShowProgress, paused.Action));
        Assert.Equal("Pozastaveno: systému dochází paměť · soubory 5300 / 6000",
            IndexingStatusPresenter.Present(Pressured(MemoryPressureLevel.Critical), 0,
                key => Cs[char.ToLowerInvariant(key.ToString()[0]) + key.ToString()[1..]]).Text);
        var slowed = IndexingStatusPresenter.Present(Pressured(MemoryPressureLevel.Warning), 0, Text);
        Assert.Equal(("Processing files 5300 / 6000 · slowed, the system is low on memory", "IconFile", IndexingStripTone.Neutral),
            (slowed.Text, slowed.IconKey, slowed.Tone));
        Assert.Equal("Processing files 5300 / 6000",
            IndexingStatusPresenter.Present(Status(IndexingPhase.Extracting, done: 5300, total: 6000), 0, Text).Text);
        Assert.True(IndexingStatusPresenter.ShowsPanelDot(Pressured(MemoryPressureLevel.Critical)));
    }

    /// <summary>indexing-status-v1 §7: a running scan keeps the work line and its progress.</summary>
    [Fact]
    public void WorkWhileScanningKeepsProgress()
    {
        var embedding = IndexingStatusPresenter.Present(Status(IndexingPhase.Embedding, filesSeen: 2100, done: 210, total: 530)
            with { ScanInProgress = true }, 0, Text);
        Assert.Equal(("Indexing 210 / 530 chunks · checking folder…", "IconIndexing", true), (embedding.Text, embedding.IconKey, embedding.ShowProgress));
        Assert.Equal(210.0 / 530, embedding.ProgressFraction);
        Assert.Equal("Indexuji úseky 210 / 530 · kontroluji složku…",
            IndexingStatusPresenter.Present(Status(IndexingPhase.Embedding, done: 210, total: 530) with { ScanInProgress = true }, 0,
                key => Cs[char.ToLowerInvariant(key.ToString()[0]) + key.ToString()[1..]]).Text);
        Assert.Equal("Processing files 3 / 10 · checking folder…",
            IndexingStatusPresenter.Present(Status(IndexingPhase.Extracting, done: 3, total: 10) with { ScanInProgress = true }, 0, Text).Text);
        // The scanning line itself already says so.
        Assert.Equal("Checking folder… 42 files",
            IndexingStatusPresenter.Present(Status(IndexingPhase.Scanning, filesSeen: 42) with { ScanInProgress = true }, 0, Text).Text);
    }

    [Fact]
    public void WorkingPhasesShowProgress()
    {
        var scanning = IndexingStatusPresenter.Present(Status(IndexingPhase.Scanning, filesSeen: 42), 0, Text);
        Assert.Equal(("Checking folder… 42 files", true, true, IndexingStripAction.None),
            (scanning.Text, scanning.ShowProgress, scanning.IsIndeterminate, scanning.Action));
        // A queued scan has seen nothing yet.
        Assert.Equal("Checking…", IndexingStatusPresenter.Present(Status(IndexingPhase.Scanning), 0, Text).Text);

        var extracting = IndexingStatusPresenter.Present(Status(IndexingPhase.Extracting, done: 3, total: 12), 0, Text);
        Assert.Equal("Processing files 3 / 12", extracting.Text);
        Assert.Equal(0.25, extracting.ProgressFraction);
        Assert.False(extracting.IsIndeterminate);

        var embedding = IndexingStatusPresenter.Present(Status(IndexingPhase.Embedding, done: 150, total: 600), 0, Text);
        Assert.Equal(("Indexing 150 / 600 chunks", 0.25), (embedding.Text, embedding.ProgressFraction));
        var preparing = IndexingStatusPresenter.Present(Status(IndexingPhase.Embedding, preparing: true), 0, Text);
        Assert.Equal(("Preparing index…", true), (preparing.Text, preparing.IsIndeterminate));
        // A generation whose chunk counts are not known yet stays indeterminate.
        Assert.True(IndexingStatusPresenter.Present(Status(IndexingPhase.Embedding, done: 0, total: 0), 0, Text).IsIndeterminate);
    }

    [Fact]
    public void RetryingCountsDownAndOffersRetryNow()
    {
        var display = IndexingStatusPresenter.Present(
            Status(IndexingPhase.Retrying, retry: new IndexingRetry("transport", 1_000, 2, 37)), 0, Text);
        Assert.Equal("Embedding provider unavailable — retrying in 37 s", display.Text);
        Assert.Equal((IndexingStripAction.RetryNow, "Retry now", IndexingStripTone.Warning, false),
            (display.Action, display.ActionLabel, display.Tone, display.ShowProgress));
    }

    [Theory]
    [InlineData(IndexingBlockedReason.NoEmbeddingModel, "No embedding model is set up; only full-text search works.", SettingsSection.Indexing)]
    [InlineData(IndexingBlockedReason.ProviderDisabled, "The embedding provider is turned off; only full-text search works.", SettingsSection.Providers)]
    [InlineData(IndexingBlockedReason.ConsentRequired, "The embedding provider needs your consent before indexing.", SettingsSection.Providers)]
    [InlineData(IndexingBlockedReason.CredentialUnavailable, "The embedding provider's API key could not be loaded.", SettingsSection.Providers)]
    public void ConfigurationBlocksOpenTheRightSettingsSection(IndexingBlockedReason reason, string text, SettingsSection section)
    {
        var display = IndexingStatusPresenter.Present(Status(IndexingPhase.Blocked, reason: reason), 0, Text);
        Assert.Equal((text, IndexingStripAction.OpenSettings, "Open settings", (SettingsSection?)section),
            (display.Text, display.Action, display.ActionLabel, display.SettingsTarget));
    }

    [Fact]
    public void FailuresShowTheirCodeAndRetryNow()
    {
        var failed = IndexingStatusPresenter.Present(
            Status(IndexingPhase.Blocked, reason: IndexingBlockedReason.IndexFailed, code: "HTTP 500."), 0, Text);
        Assert.Equal(("Indexing failed (HTTP 500.)", IndexingStripAction.RetryNow, IndexingStripTone.Danger),
            (failed.Text, failed.Action, failed.Tone));
        var runtime = IndexingStatusPresenter.Present(
            Status(IndexingPhase.Blocked, reason: IndexingBlockedReason.RuntimeFailed, code: "unexpectedError"), 0, Text);
        Assert.Equal(("Background indexing could not start (unexpectedError)", IndexingStripAction.RetryNow),
            (runtime.Text, runtime.Action));
    }

    [Fact]
    public void QuietStatesAndSourceErrors()
    {
        var ready = IndexingStatusPresenter.Present(Status(IndexingPhase.Ready, sourceErrors: 2), 1204, Text);
        Assert.Equal(("Searchable · 1204 files", IndexingStripTone.Quiet, IndexingStripAction.None, "2 files couldn't be read"),
            (ready.Text, ready.Tone, ready.Action, ready.SecondaryText));
        var lexical = IndexingStatusPresenter.Present(Status(IndexingPhase.LexicalOnly), 3, Text);
        Assert.Equal(("Full-text search only", IndexingStripAction.BuildIndex, "Build index"),
            (lexical.Text, lexical.Action, lexical.ActionLabel));
        Assert.Null(lexical.SecondaryText);
        Assert.False(IndexingStatusPresenter.Present(Status(IndexingPhase.Empty), 0, Text).IsVisible);
        Assert.False(IndexingStatusPresenter.Present(null, 0, Text).IsVisible);
    }

    /// <summary>ingestion-retry-cap-v1 §5/§7: the unreadable-files line explains the cap and offers "Retry all failed".</summary>
    [Fact]
    public void SourceErrorsExplainTheRetryCapAndOfferRetryAll()
    {
        var ready = IndexingStatusPresenter.Present(Status(IndexingPhase.Ready, sourceErrors: 3), 10, Text);
        Assert.Equal(("3 files couldn't be read (gave up after 3 attempts)", "Retry all failed"),
            (ready.SecondaryHelp, ready.RetryAllLabel));
        Assert.False(Status(IndexingPhase.Ready, sourceErrors: 3).IsActive);
        var scanning = IndexingStatusPresenter.Present(
            Status(IndexingPhase.Extracting, done: 1, total: 2, sourceErrors: 1) with { ScanInProgress = true }, 0, Text);
        Assert.Equal("1 files couldn't be read (gave up after 3 attempts)", scanning.SecondaryHelp);
        var clean = IndexingStatusPresenter.Present(Status(IndexingPhase.Ready), 10, Text);
        Assert.Equal(((string?)null, (string?)null), (clean.SecondaryHelp, clean.RetryAllLabel));
        Assert.Equal("Nepodařilo se přečíst souborů: {count} (vzdáno po 3 pokusech)", Cs["indexingSourceErrorsGaveUp"]);
    }

    [Fact]
    public void EveryStripIconIsAToken()
    {
        string tokens = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "AINotebook.App", "Styles", "Tokens.xaml"));
        var statuses = Enum.GetValues<IndexingPhase>().Select(p => Status(p))
            .Concat(Enum.GetValues<IndexingBlockedReason>().Select(r => Status(IndexingPhase.Blocked, reason: r)));
        foreach (var status in statuses)
            Assert.Contains($"x:Key=\"{IndexingStatusPresenter.Present(status, 0, Text).IconKey}\"", tokens);
    }

    [Fact]
    public void PanelDotOnlyForWorkOrBlocked()
    {
        foreach (var phase in new[] { IndexingPhase.Scanning, IndexingPhase.Extracting, IndexingPhase.Embedding, IndexingPhase.Retrying, IndexingPhase.Blocked })
            Assert.True(IndexingStatusPresenter.ShowsPanelDot(Status(phase)), phase.ToString());
        foreach (var phase in new[] { IndexingPhase.Ready, IndexingPhase.LexicalOnly, IndexingPhase.Empty })
            Assert.False(IndexingStatusPresenter.ShowsPanelDot(Status(phase)), phase.ToString());
        Assert.False(IndexingStatusPresenter.ShowsPanelDot(null));
    }

    [Fact]
    public void ScanOutcomeCaption()
    {
        Assert.Equal("No changes · 120 files up to date",
            IndexingStatusPresenter.ScanOutcomeCaption(new FolderScanOutcome(1, 0, 120, 10), Text));
        Assert.Equal("3 files changed", IndexingStatusPresenter.ScanOutcomeCaption(new FolderScanOutcome(1, 3, 120, 10), Text));
    }

    [Fact]
    public void ScanFeedbackChecksUntilANewerOutcomeThenCaptionsBriefly()
    {
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_000);
        var feedback = new FolderScanFeedback();
        var before = new FolderScanOutcome(7, 5, 100, 900);
        feedback.Begin(7, before, t0);
        Assert.True(feedback.IsChecking(7, "idle"));
        Assert.True(feedback.NeedsTicks);
        // The outcome known before the click is not this scan's.
        Assert.False(feedback.Observe(7, before, t0.AddSeconds(1)));
        Assert.True(feedback.IsChecking(7, "idle"));
        var after = new FolderScanOutcome(7, 0, 100, 1_002);
        Assert.True(feedback.Observe(7, after, t0.AddSeconds(2)));
        Assert.False(feedback.IsChecking(7, "idle"));
        Assert.True(feedback.IsChecking(7, "scanning")); // the persisted state still spins
        Assert.Equal(after, feedback.Caption(7, t0.AddSeconds(5)));
        Assert.Null(feedback.Caption(7, t0.AddSeconds(6.5))); // ~4 s
        Assert.False(feedback.NeedsTicks);

        // First scan ever: any outcome is new. A failed request cancels; a silent scan stops spinning after the timeout.
        feedback.Begin(8, null, t0);
        Assert.True(feedback.Observe(8, new FolderScanOutcome(8, 2, 2, 1_001), t0));
        feedback.Begin(9, null, t0);
        feedback.Cancel(9);
        Assert.False(feedback.IsChecking(9, "idle"));
        feedback.Begin(10, null, t0);
        Assert.False(feedback.Observe(10, null, t0.AddSeconds(30)));
        Assert.True(feedback.Observe(10, null, t0 + feedback.CheckTimeout));
        Assert.False(feedback.IsChecking(10, "idle"));
        Assert.Null(feedback.Caption(10, t0 + feedback.CheckTimeout));
    }

    [Fact]
    public void FolderRowWarnsAboutPartialAndExplainsErrorCodes()
    {
        FolderRowViewModel Row(string state, string? error) => new(
            new FolderSource(7, 1, new FolderDraft("C:\\docs", "Docs", ["md"], [], "{}", "cp1250", true),
                new FolderIdentity("v", ["docs"], "r"), state, 2, null, error, 0),
            new CoverageSnapshot(1, 0, 0, 0, 0, 0, 0, 0, state == "partial", 0, 1), Text);
        Assert.Null(Row("idle", null).ErrorText);
        Assert.Equal("The folder or file could not be read.", Row("partial", null).ErrorText);
        Assert.Equal("Unavailable", Row("unavailable", "rootUnavailable").ErrorText);
        Assert.Equal(Text(StringKey.FolderOverlapError), Row("error", "overlappingRoot").ErrorText);
        Assert.Equal(Text(StringKey.FolderReadError), Row("error", "somethingNew").ErrorText);
        Assert.Equal("Checking…", Row("idle", null).CheckingText);
    }

    [Fact]
    public async Task WatcherFollowsOnlyItsNotebook()
    {
        var asked = new List<long>();
        var watcher = new IndexingStatusWatcher((nb, _) =>
        {
            lock (asked) asked.Add(nb);
            return Task.FromResult(Status(nb == 1 ? IndexingPhase.Extracting : IndexingPhase.Ready, done: 1, total: 2));
        }, store: null, dispatcher: null);
        Assert.False(watcher.ShouldPoll);
        watcher.NotebookId = 1;
        await watcher.RefreshAsync();
        Assert.Equal(IndexingPhase.Extracting, watcher.Status!.Phase);
        Assert.True(watcher.ShouldPoll); // active → 1 s poll

        int before;
        lock (asked) before = asked.Count;
        watcher.OnStatusChanged(2); // another notebook's change is ignored
        await Task.Delay(300);
        lock (asked) Assert.Equal(before, asked.Count);
        watcher.OnStatusChanged(1);
        await WaitUntil(() => { lock (asked) return asked.Count > before; });

        watcher.NotebookId = 2;
        await watcher.RefreshAsync();
        Assert.Equal(IndexingPhase.Ready, watcher.Status!.Phase);
        Assert.False(watcher.ShouldPoll); // ready → no polling
        lock (asked) Assert.All(asked, id => Assert.True(id is 1 or 2));
        watcher.NotebookId = null;
        await watcher.RefreshAsync();
        Assert.Null(watcher.Status);
    }

    [Fact]
    public async Task WatcherShowsTheRealErrorOfAFailedRead()
    {
        var watcher = new IndexingStatusWatcher((_, _) => throw new InvalidOperationException("database is locked"),
            store: null, dispatcher: null) { NotebookId = 4 };
        await watcher.RefreshAsync();
        Assert.Equal("database is locked", watcher.LoadError);
        Assert.Null(watcher.Status);
    }

    [Fact]
    public async Task SourcesStripFollowsTheCurrentNotebook()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long first = store.CreateNotebook("one").Id!.Value;
        long second = store.CreateNotebook("two").Id!.Value;
        var asked = new List<long>();
        var vm = NewViewModel(store, (nb, _) =>
        {
            lock (asked) asked.Add(nb);
            return Task.FromResult(nb == first
                ? Status(IndexingPhase.Extracting, done: 3, total: 10)
                : Status(IndexingPhase.Blocked, reason: IndexingBlockedReason.NoEmbeddingModel));
        });
        vm.NotebookId = first;
        await vm.Indexing.RefreshAsync();
        Assert.Equal("Processing files 3 / 10", vm.IndexingDisplay.Text);
        Assert.Equal(0.3, vm.IndexingDisplay.ProgressFraction!.Value, 3);

        vm.NotebookId = second;
        await vm.Indexing.RefreshAsync();
        Assert.Equal(IndexingStripAction.OpenSettings, vm.IndexingDisplay.Action);
        SettingsSection? opened = null;
        vm.SettingsRequested += section => opened = section;
        await vm.RunIndexingActionAsync();
        Assert.Equal(SettingsSection.Indexing, opened);
        lock (asked) Assert.Equal(new[] { first, second }, asked.Distinct());
    }

    [Fact]
    public async Task ReloadKeepsAFreshActionError()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("errors").Id!.Value;
        var vm = NewViewModel(store, (_, _) => Task.FromResult(Status(IndexingPhase.Empty)));
        vm.NotebookId = nb;
        vm.ErrorMessage = "The folder or file could not be read.";
        await vm.LoadAsync(); // the follow-up reload after an action
        Assert.Equal("The folder or file could not be read.", vm.ErrorMessage);
        vm.ErrorMessage = null;
        await vm.LoadAsync();
        Assert.Null(vm.ErrorMessage);
    }

    [Fact]
    public async Task FailedReloadShowsItsError()
    {
        var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("broken").Id!.Value;
        var vm = NewViewModel(store, (_, _) => Task.FromResult(Status(IndexingPhase.Empty)));
        vm.NotebookId = nb;
        store.Dispose();
        await vm.LoadAsync();
        Assert.False(string.IsNullOrWhiteSpace(vm.ErrorMessage));
    }

    [Fact]
    public void IndexingStringsExistInBothLanguages()
    {
        string[] keys =
        [
            "indexingScanning", "indexingExtracting", "indexingExtractingSlowed", "indexingExtractingPaused", "indexingEmbedding", "indexingPreparing", "indexingRetrying",
            "indexingRetryNow", "indexingBlockedNoModel", "indexingBlockedProviderDisabled", "indexingBlockedConsent",
            "indexingBlockedCredential", "indexingFailed", "indexingRuntimeFailed", "indexingOpenSettings", "indexingReady",
            "indexingLexicalOnly", "indexingBuildIndex", "indexingSourceErrors", "folderChecking", "folderNoChanges",
            "folderChangedFiles", "indexingSourceErrorsGaveUp", "indexingRetryAllFailed", "sourceRetryButton", "sourceGaveUp",
        ];
        foreach (string key in keys)
        {
            Assert.True(Enum.IsDefined(typeof(StringKey), char.ToUpperInvariant(key[0]) + key[1..]), key);
            Assert.False(string.IsNullOrWhiteSpace(En[key]), key);
            Assert.False(string.IsNullOrWhiteSpace(Cs[key]), key);
            // Same named tokens in both languages (the presenter replaces them literally).
            foreach (string token in new[] { "{count}", "{done}", "{total}", "{seconds}", "{code}" })
                Assert.Equal(En[key].Contains(token), Cs[key].Contains(token));
        }
        Assert.Equal("Searchable · {count} files", En["indexingReady"]);
    }

    private static SourcesViewModel NewViewModel(NotebookStore store, Func<long, CancellationToken, Task<IndexingStatus>> fetch)
    {
        var clock = new SystemIngestLeaseClock();
        var admission = new IngestionAdmission();
        var fs = new NativeFolderFileSystem();
        var extractor = new BoundedDocumentExtractor();
        Func<long, Task<EmbeddingSelection?>> none = _ => Task.FromResult<EmbeddingSelection?>(null);
        var runtime = new FolderIngestionRuntime(store, new FolderScanner(store, fs, UnicodeTables.LoadBundled(), clock),
            new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, clock, none, (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
            new FolderIndexCoordinator(store, admission, clock, (_, _) => Task.FromResult<FolderEmbeddingSession?>(null), none),
            new JobQueue(store, clock, admission), clock, admission, new NativeFolderWatchFactory(), identity: fs);
        return new SourcesViewModel(store, Text, null!, null!, new IngestionService(store), runtime, dispatcher: null, fetch);
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "condition not met in time");
            await Task.Delay(20);
        }
    }

    private static Dictionary<string, string> Resw(string path) => XDocument.Load(path).Root!.Elements("data")
        .ToDictionary(e => (string)e.Attribute("name")!, e => (string)e.Element("value")!);

    private static string RepoRoot([System.Runtime.CompilerServices.CallerFilePath] string here = "")
    {
        for (var dir = new DirectoryInfo(Path.GetDirectoryName(here)!); dir is not null; dir = dir.Parent)
            if (Directory.Exists(Path.Combine(dir.FullName, "Tests", "fixtures", "contracts"))) return dir.FullName;
        throw new DirectoryNotFoundException("Repository root not found from " + here);
    }
}
