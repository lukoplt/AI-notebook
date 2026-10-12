using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Xml.Linq;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Views;
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>Pure resource, projection and rules tests; no WinUI window or DispatcherQueue is created.</summary>
public sealed class FolderSourcesTests
{
    [Theory]
    [InlineData("en.resw", "Add folder…", "No sources selected")]
    [InlineData("cs.resw", "Přidat složku…", "Nejsou vybrány žádné zdroje")]
    public void FolderResourcesExist(string path, string add, string empty)
    {
        var rows = XDocument.Load(path).Root!.Elements("data")
            .ToDictionary(e => (string)e.Attribute("name")!, e => (string)e.Element("value")!);
        Assert.Equal(add, rows["addFolderButton"]);
        Assert.Equal(empty, rows["scopeEmpty"]);
        Assert.True(Enum.IsDefined(typeof(StringKey), "FolderRefreshError"));
    }

    [Fact]
    public void AllSharedFolderStrings()
    {
        var en = Resw("en.resw");
        var cs = Resw("cs.resw");
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(RepoRoot(), "Tests", "fixtures", "contracts", "ingestion-ui-v1.json")));
        var rows = fixture.RootElement.GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("operation").GetString() == "localization").ToArray();
        Assert.Equal(51, rows.Length);
        foreach (var row in rows)
        {
            string key = row.GetProperty("input").GetProperty("key").GetString()!;
            var expected = row.GetProperty("expected");
            Assert.Equal(expected.GetProperty("en").GetString(), en[key]);
            Assert.Equal(expected.GetProperty("cs").GetString(), cs[key]);
            Assert.True(Enum.IsDefined(typeof(StringKey), char.ToUpperInvariant(key[0]) + key[1..]), key);
        }
    }

    [Fact]
    public void FolderOnlyNotebookIsNotEmpty()
    {
        Assert.True(SourcesViewModel.ComputeIsEmpty(0, 0));
        Assert.False(SourcesViewModel.ComputeIsEmpty(0, 1));
        Assert.False(SourcesViewModel.ComputeIsEmpty(1, 0));

        var en = Resw("en.resw");
        string Text(StringKey key) => en[char.ToLowerInvariant(key.ToString()[0]) + key.ToString()[1..]];
        // An empty partial folder (everything skipped or unreadable) still shows, with a lower-bound inventory.
        var folder = new FolderSource(7, 1, new FolderDraft("C:\\docs", "Docs", ["md"], [], "{}", "cp1250", true),
            new FolderIdentity("v", ["docs"], "r"), "partial", 2, null, null, 0);
        var row = new FolderRowViewModel(folder, new CoverageSnapshot(0, 0, 0, 0, 0, 0, 0, 0, true, 0, 0), Text);
        Assert.Equal("At least", row.LowerBoundText);
        Assert.Equal("Never scanned", row.LastScanValue);
        Assert.Equal(new[] { "Searchable", "Not yet searchable", "Skipped", "Missing", "Unavailable" }, row.CorpusCounts.Select(c => c.Label));
        Assert.Equal(new[] { "Current", "Refresh pending", "Refresh failed" }, row.FreshnessCounts.Select(c => c.Label));
        Assert.True(row.WatchEnabled);
        // Corpus and freshness stay separate dimensions; a refresh error never inflates the searchable total.
        var refreshed = new FolderRowViewModel(folder with { ScanState = "idle", LastFullScanAt = 10 },
            new CoverageSnapshot(1, 0, 0, 0, 0, 0, 0, 1, false, 0, 0), Text);
        Assert.Null(refreshed.LowerBoundText);
        Assert.Equal("1", refreshed.CorpusCounts[0].Value);
        Assert.Equal("1", refreshed.FreshnessCounts[2].Value);
        Assert.Equal("0", refreshed.FreshnessCounts[0].Value);
        bool? toggled = null;
        refreshed.WatchChanged = (_, value) => { toggled = value; return Task.CompletedTask; };
        refreshed.WatchEnabled = false;
        Assert.False(toggled);
        Assert.Equal(StringKey.FolderOverlapError, SourcesViewModel.FolderErrorKey(new StorageV19Exception("overlappingRoot")));
        Assert.Equal(StringKey.FolderEncodingError, SourcesViewModel.FolderErrorKey(new FolderIngestionException("unsupportedEncoding")));
    }

    [Fact]
    public void RulesRejectUnsupportedGlob()
    {
        var tables = UnicodeTables.LoadBundled();
        var valid = new FolderRulesDraft("md, .TXT", "build\n*.tmp", "1000", "2000", "300", "4", "5", "6", "none");
        var rules = valid.TryBuild(tables, caseSensitive: false);
        Assert.NotNull(rules);
        Assert.Equal(new[] { "md", "txt" }, rules!.IncludeExts);
        Assert.Equal(new[] { "build", "*.tmp" }, rules.IgnoreGlobs);
        Assert.Equal("none", rules.EncodingFallback);
        Assert.Null((valid with { IgnoreGlobs = "[abc]" }).TryBuild(tables, false));
        Assert.Null((valid with { IgnoreGlobs = "!negated" }).TryBuild(tables, false));
        Assert.Null((valid with { FileBytes = "0" }).TryBuild(tables, false));
        Assert.Null((valid with { FileBytes = "999999999999" }).TryBuild(tables, false)); // above the process ceiling
        Assert.Null((valid with { Chunks = "-1" }).TryBuild(tables, false));
        Assert.Null((valid with { IncludeExtensions = "" }).TryBuild(tables, false));
        Assert.Null((valid with { IncludeExtensions = "m*d" }).TryBuild(tables, false));
        Assert.Null((valid with { Encoding = "latin1" }).TryBuild(tables, false));
        var folder = new FolderSource(1, 1, new FolderDraft("C:\\docs", "Docs", ["pdf", "md"], ["build"], """{"maxPdfPages":10}""", "cp1250", true),
            new FolderIdentity("v", ["docs"], "r"), "idle", 0, null, null, 0);
        var round = FolderRulesDraft.From(folder);
        Assert.Equal("pdf, md", round.IncludeExtensions);
        Assert.Equal("10", round.PdfPages);
        Assert.NotNull(round.TryBuild(tables, false));
    }

    [Fact]
    public async Task FolderRemovalKeepsDisk()
    {
        string root = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "wp6-app-" + Guid.NewGuid().ToString("N"))).FullName;
        try
        {
            string file = Path.Combine(root, "keep.md");
            await File.WriteAllTextAsync(file, "# Keep\nbody");
            using var store = new NotebookStore(StorePath.InMemory);
            long nb = store.CreateNotebook("remove").Id!.Value;
            var clock = new SystemIngestLeaseClock();
            var admission = new IngestionAdmission();
            var fs = new NativeFolderFileSystem();
            var extractor = new BoundedDocumentExtractor();
            Func<long, Task<EmbeddingSelection?>> none = _ => Task.FromResult<EmbeddingSelection?>(null);
            var runtime = new FolderIngestionRuntime(store, new FolderScanner(store, fs, UnicodeTables.LoadBundled(), clock),
                new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, clock, none, (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
                new FolderIndexCoordinator(store, admission, clock, (_, _) => Task.FromResult<FolderEmbeddingSession?>(null), none),
                new JobQueue(store, clock, admission), clock, admission, new NativeFolderWatchFactory(), identity: fs);
            await runtime.StartAsync();
            var folder = await runtime.AddFolderAsync(nb, root);
            await runtime.WaitForFolderIdleAsync(folder.Id).WaitAsync(TimeSpan.FromSeconds(30));
            Assert.Single(store.SourcesIncludingShadow(nb));
            await runtime.RemoveFolderAsync(folder.Id);
            await runtime.StopAsync();
            Assert.Empty(store.Folders(nb));
            Assert.Empty(store.SourcesIncludingShadow(nb));
            Assert.Equal("# Keep\nbody", await File.ReadAllTextAsync(file));
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task UrlRefreshKeepsThePublishedRevisionHash()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("e2").Id!.Value;
        var web = new WebText { Value = "first" };
        var service = new IngestionService(store, web: web);
        var source = await service.IngestUrlAsync(new Uri("https://example.invalid/doc"), nb);
        web.Value = "second";
        await service.ReIngestAsync(source.Id!.Value);
        var refreshed = store.Source(source.Id.Value)!;
        string hash = SourcesViewModel.SyncHashAfterRefresh(refreshed);
        Assert.Equal(store.Revision(refreshed.PublishedRevisionId!.Value)!.Draft.ContentHash, hash);
        Assert.NotEqual(refreshed.Uri, hash);
        store.UpdateSourceSyncInfo(source.Id.Value, DateTime.UtcNow, hash);
        Assert.Equal(hash, store.Source(source.Id.Value)!.ContentHash);
    }

    [Fact]
    public void SourceXamlBindsFolderRows()
    {
        // UI redesign W3: Sources live in the right panel; folder actions moved into the row's "…" menu.
        string panels = Path.Combine(RepoRoot(), "windows", "src", "AINotebook.App", "Panels");
        string xaml = File.ReadAllText(Path.Combine(panels, "SourcesPanel.xaml"));
        string code = File.ReadAllText(Path.Combine(panels, "SourcesPanel.xaml.cs"));
        Assert.Contains("ItemsSource=\"{x:Bind ViewModel.Rows, Mode=OneWay}\"", xaml);
        Assert.Contains("x:DataType=\"vm:FolderRowViewModel\"", xaml);
        Assert.Contains("Text=\"{x:Bind SummaryText}\"", xaml);
        Assert.Contains("ToolTipService.ToolTip=\"{x:Bind DetailText}\"", xaml);
        Assert.Contains("Click=\"OnAddFolder\"", xaml);
        Assert.Contains("Click=\"OnFolderMore\"", xaml);
        // Watch is a checkable menu item bound to the row; failures roll back through WatchChanged.
        Assert.Contains("row.WatchEnabled = watch.IsChecked", code);
        Assert.DoesNotContain("FolderWatchButton", xaml);
        foreach (string handler in new[] { "OnAddFolder", "OnScanFolder", "OnVerifyFolder", "OnFolderRules", "OnRemoveFolder" })
            Assert.Contains($"private async void {handler}(object sender, RoutedEventArgs e)", code);
        foreach (string handler in new[] { "OnScanFolder", "OnVerifyFolder", "OnFolderRules", "OnRemoveFolder" })
            Assert.Contains($", {handler}, id)", code);
        string dialog = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "AINotebook.App", "Views", "FolderRulesDialog.xaml"));
        foreach (string name in new[] { "IncludeExtensionsBox", "IgnoreGlobsBox", "FileBytesBox", "OfficeBytesBox", "TextScalarsBox",
            "PdfPagesBox", "ChunksBox", "CellsBox", "EncodingBox" })
            Assert.Contains($"x:Name=\"{name}\"", dialog);
        Assert.Contains("Tag=\"cp1250\"", dialog);
        Assert.Contains("Tag=\"none\"", dialog);
    }

    [Fact]
    public void FolderRowSummarisesCoverageOnOneLine()
    {
        var en = Resw("en.resw");
        string Text(StringKey key) => en[char.ToLowerInvariant(key.ToString()[0]) + key.ToString()[1..]];
        var folder = new FolderSource(7, 1, new FolderDraft("C:\\docs", "Docs", ["md"], [], "{}", "cp1250", true),
            new FolderIdentity("v", ["docs"], "r"), "idle", 2, 10, null, 0);
        var clean = new FolderRowViewModel(folder, new CoverageSnapshot(1200, 0, 0, 3, 1, 0, 0, 0, false, 0, 1204), Text);
        Assert.Equal(1204, clean.TotalFiles);
        Assert.Equal($"Files: {1204.ToString("N0", System.Globalization.CultureInfo.CurrentCulture)}", clean.SummaryText);
        var failing = new FolderRowViewModel(folder, new CoverageSnapshot(10, 2, 2, 0, 0, 0, 0, 1, true, 2, 9), Text);
        Assert.Equal("At least Files: 12 · Errors: 3", failing.SummaryText);
        Assert.Contains("Searchable 10", failing.DetailText);
        Assert.Contains("Refresh failed 1", failing.DetailText);
    }

    [Fact]
    public void TagFilterKeepsOnlyTaggedLooseSources()
    {
        var en = Resw("en.resw");
        string Text(StringKey key) => en[char.ToLowerInvariant(key.ToString()[0]) + key.ToString()[1..]];
        var tagged = new SourceItem(new Source(1, 1, SourceType.Text, "a", null, null, SourceStatus.Ready, null, DateTime.UnixEpoch), Text);
        tagged.Tags.Add(new Tag(5, "work"));
        var plain = new SourceItem(new Source(2, 1, SourceType.Text, "b", null, null, SourceStatus.Ready, null, DateTime.UnixEpoch), Text);
        Assert.Equal(new[] { tagged, plain }, SourcesViewModel.FilterByTag([tagged, plain], null));
        Assert.Equal(new[] { tagged }, SourcesViewModel.FilterByTag([tagged, plain], 5));
    }

    private sealed class WebText : ITextExtractor
    {
        public string Value = "";
        public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind) => Task.FromResult(new ExtractedText("web", Value));
    }

    private static Dictionary<string, string> Resw(string path) => XDocument.Load(path).Root!.Elements("data")
        .ToDictionary(e => (string)e.Attribute("name")!, e => (string)e.Element("value")!);

    /// <summary>The App project cannot use the Core test helper; locate the repository from this source file.</summary>
    private static string RepoRoot([CallerFilePath] string here = "")
    {
        for (var dir = new DirectoryInfo(Path.GetDirectoryName(here)!); dir is not null; dir = dir.Parent)
            if (Directory.Exists(Path.Combine(dir.FullName, "Tests", "fixtures", "contracts"))) return dir.FullName;
        throw new DirectoryNotFoundException("Repository root not found from " + here);
    }
}
