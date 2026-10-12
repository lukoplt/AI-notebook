using System.Runtime.CompilerServices;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Views;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>
/// Binding contract checks over the repository XAML plus pure scope/progress models. They do not pretend to automate
/// WinUI rendering; the Windows build validates x:Bind names and types.
/// </summary>
public sealed class FolderScopeBindingTests
{
    [Fact]
    public void ChatScopeFlyoutHasFourGroupsAndExplicitModes()
    {
        // UI redesign W2: the scope flyout moved into the composer's scope chip.
        string xaml = File.ReadAllText(Path.Combine(Views(), "..", "Chat", "ChatThreadPage.xaml"));
        Assert.Contains("x:Name=\"WholeNotebookRadio\"", xaml);
        Assert.Contains("x:Name=\"SelectedItemsRadio\"", xaml);
        Assert.Contains("IsChecked=\"{x:Bind ViewModel.Scope.WholeNotebook, Mode=TwoWay}\"", xaml);
        Assert.Contains("IsChecked=\"{x:Bind ViewModel.Scope.SelectedItems, Mode=TwoWay}\"", xaml);
        Assert.Contains("x:Name=\"EmptyScopeText\"", xaml);
        foreach (var (name, source) in new[] { ("FolderScopeList", "Folders"), ("SetScopeList", "Sets"), ("SourceScopeList", "Sources") })
            Assert.Contains($"x:Name=\"{name}\" ItemsSource=\"{{x:Bind ViewModel.Scope.{source}, Mode=OneWay}}\"", xaml);
        Assert.Equal(3, Count(xaml, "IsChecked=\"{x:Bind IsSelected, Mode=TwoWay}\""));
        // The saved-set actions remain available.
        Assert.Contains("Click=\"OnApplySourceSet\"", xaml);
        Assert.DoesNotContain("ViewModel.ScopeSources", xaml);
    }

    [Fact]
    public void SettingsBindsIndexBuildsWithRetryDiscardAndDualSpaceNote()
    {
        // UI redesign W4: settings moved from SettingsDialog to the Settings page (Indexing section).
        string xaml = File.ReadAllText(Path.Combine(Views(), "..", "Settings", "SettingsPage.xaml"));
        string code = File.ReadAllText(Path.Combine(Views(), "..", "Settings", "SettingsPage.xaml.cs"));
        Assert.Contains("ItemsSource=\"{x:Bind ViewModel.IndexBuilds, Mode=OneWay}\"", xaml);
        Assert.Contains("x:DataType=\"vm:GenerationProgressRow\"", xaml);
        Assert.Contains("Click=\"OnRetryIndex\"", xaml);
        Assert.Contains("Click=\"OnDiscardIndex\"", xaml);
        Assert.Contains("x:Name=\"ReindexDualSpaceNote\"", xaml);
        Assert.Contains("StringKey.ReindexDualSpaceNote", code);
        Assert.DoesNotContain("DeleteAllEmbeddings", File.ReadAllText(Path.Combine(Views(), "..", "ViewModels", "SettingsViewModel.cs")));
    }

    [Fact]
    public void ScopeModelResolvesCurrentSetMembershipAndNeverWidens()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("scope").Id!.Value;
        long a = store.CreateSource(nb, SourceType.Text, "a", null, null).Id!.Value;
        long b = store.CreateSource(nb, SourceType.Text, "b", null, null).Id!.Value;
        store.UpdateSourceStatus(a, SourceStatus.Ready, null);
        store.UpdateSourceStatus(b, SourceStatus.Ready, null);
        var set = store.CreateSourceSet(nb, "set");
        store.SetSourceSetMembers(set.Id, [a]);
        var model = new FolderScopeModel(store, key => key.ToString());
        model.Reload(nb);
        Assert.True(model.WholeNotebook);
        Assert.IsType<RetrievalScope.All>(model.ResolveForTurn());

        // Selected mode with nothing checked is an explicit empty scope.
        model.SelectedItems = true;
        Assert.True(model.IsEmptySelection);
        Assert.True(model.ResolveForTurn().IsEmptySelection);
        Assert.Equal("ScopeEmpty", model.ButtonText);

        // A saved set contributes its *current* members on every turn.
        model.SelectSet(set.Id);
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long> { a }, new HashSet<long>()), model.ResolveForTurn());
        store.SetSourceSetMembers(set.Id, [b]);
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long> { b }, new HashSet<long>()), model.ResolveForTurn());

        // Checking every visible source stays an explicit selection.
        foreach (var item in model.Sources) item.IsSelected = true;
        Assert.False(model.WholeNotebook);
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long> { a, b }, new HashSet<long>()), model.ResolveForTurn());

        // A removed selected set leaves the selection empty after reload (never the whole notebook).
        foreach (var item in model.Sources) item.IsSelected = false;
        store.DeleteSourceSet(set.Id);
        model.Reload(nb);
        Assert.False(model.WholeNotebook);
        Assert.True(model.ResolveForTurn().IsEmptySelection);

        // Saving an explicit selection persists it; whole notebook cannot be saved.
        model.Sources.First(s => s.Id == a).IsSelected = true;
        var saved = model.SaveAsSet("mine");
        Assert.Equal(new long[] { a }, store.SourceSetMembers(saved.Id));
        model.WholeNotebook = true;
        Assert.Throws<StorageV19Exception>(() => model.SaveAsSet("all"));
        // Switching notebook deliberately resets to whole notebook.
        long other = store.CreateNotebook("other").Id!.Value;
        model.SelectedItems = true;
        model.Reload(other);
        Assert.True(model.WholeNotebook);
    }

    [Fact]
    public void ProgressRowsNeverClaimCompleteWithoutAnActiveIndex()
    {
        string Text(StringKey key) => key.ToString();
        var preparing = new GenerationProgress(null, 0, 0, 0, false, false, false, 7, true, null);
        Assert.Equal("ReindexDiscovering", GenerationProgressRow.From(1, "nb", preparing, Text).StatusText);
        var paused = new GenerationProgress(3, 1, 4, 1, false, true, true, 8, false, null);
        var row = GenerationProgressRow.From(1, "nb", paused, Text);
        Assert.Equal(("ReindexPausedForChat", "1 / 4", "1"), (row.StatusText, row.ProgressText, row.ExcludedText));
        Assert.True(row.CanDiscard);
        Assert.False(row.CanRetry);
        var failed = GenerationProgressRow.From(1, "nb", paused with { Failed = true, PausedForChat = false }, Text);
        Assert.Equal("ReindexFailed", failed.StatusText);
        Assert.True(failed.CanRetry);

        // Settings › Indexing names the persisted failure code (the Sources strip replaced the aggregate badge).
        var coded = GenerationProgressRow.From(1, "nb", paused with { Failed = true, PausedForChat = false, ErrorCode = "transport" }, Text);
        Assert.Equal("ReindexFailed (transport)", coded.StatusText);
    }

    private static int Count(string text, string value)
    {
        int count = 0;
        for (int i = text.IndexOf(value, StringComparison.Ordinal); i >= 0; i = text.IndexOf(value, i + value.Length, StringComparison.Ordinal)) count++;
        return count;
    }

    private static string Views([CallerFilePath] string here = "")
    {
        for (var dir = new DirectoryInfo(Path.GetDirectoryName(here)!); dir is not null; dir = dir.Parent)
        {
            string candidate = Path.Combine(dir.FullName, "windows", "src", "AINotebook.App", "Views");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new DirectoryNotFoundException("App Views not found from " + here);
    }
}
