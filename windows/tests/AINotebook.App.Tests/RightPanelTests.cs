using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>UI redesign W3: right panel segments (Sources, Notes, Context, Citations).</summary>
public sealed class RightPanelTests
{
    private static string Panel(string file) => File.ReadAllText(Path.Combine(ShellNavigationTests.AppRoot(), "Panels", file));

    [Fact]
    public void NotesTagFilterKeepsOnlyTaggedNotes()
    {
        Note Make(long id) => new(id, 1, "n" + id, "", NoteOrigin.Manual, null, null, "u" + id, DateTime.UnixEpoch, DateTime.UnixEpoch);
        var notes = new[] { Make(1), Make(2), Make(3) };
        var tags = new Dictionary<long, IReadOnlyCollection<long>> { [1] = [7], [2] = [], [3] = [7, 8] };
        Assert.Equal(new long?[] { 1, 3 }, NotesViewModel.FilterByTag(notes, id => tags[id], 7).Select(n => n.Id));
        Assert.Equal(3, NotesViewModel.FilterByTag(notes, id => tags[id], null).Count());
    }

    [Fact]
    public void PanelsBindTheSharedChatViewModel()
    {
        string context = Panel("ContextPanel.xaml");
        Assert.Contains("ItemsSource=\"{x:Bind ViewModel.ContextPreview.Rows, Mode=OneWay}\"", context);
        Assert.Contains("Command=\"{x:Bind ViewModel.PrepareContextCommand}\"", context);
        Assert.Contains("<Expander", context); // collapsible sections

        string citations = Panel("CitationsPanel.xaml");
        Assert.Contains("ItemsSource=\"{x:Bind ViewModel.PanelCitations, Mode=OneWay}\"", citations);
        Assert.Contains("Text=\"{x:Bind ViewModel.CitationStatus, Mode=OneWay}\"", citations);
        Assert.Contains("Click=\"OnOpenCitation\"", citations);
        Assert.Contains("OpenCitationOriginalCommand", Panel("CitationsPanel.xaml.cs"));

        string notes = Panel("NotesPanel.xaml");
        Assert.Contains("ItemsSource=\"{x:Bind ViewModel.FilteredNotes, Mode=OneWay}\"", notes);
        Assert.Contains("Text=\"{x:Bind ViewModel.SearchQuery, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}\"", notes);
        Assert.Contains("TransformationHistoryDialog", Panel("NotesPanel.xaml.cs")); // tool history lives here (§2.7)

        foreach (var file in new[] { "SourcesPanel.xaml", "NotesPanel.xaml", "ContextPanel.xaml", "CitationsPanel.xaml" })
        {
            string xaml = Panel(file);
            Assert.DoesNotContain("Foreground=\"Red\"", xaml);
            Assert.DoesNotContain("#FF", xaml);
            Assert.DoesNotContain("SystemFillColor", xaml);
        }
        Assert.False(File.Exists(Path.Combine(ShellNavigationTests.AppRoot(), "Views", "SourceListPage.xaml")));
    }
}
