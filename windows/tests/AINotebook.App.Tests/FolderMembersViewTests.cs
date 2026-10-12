using System.Xml.Linq;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>Grouped Sources projection: pure view-model logic, no WinUI window or DispatcherQueue.</summary>
public sealed class FolderMembersViewTests
{
    private static readonly Dictionary<string, string> En = XDocument.Load("en.resw").Root!.Elements("data")
        .ToDictionary(e => (string)e.Attribute("name")!, e => (string)e.Element("value")!);
    private static readonly Dictionary<string, string> Cs = XDocument.Load("cs.resw").Root!.Elements("data")
        .ToDictionary(e => (string)e.Attribute("name")!, e => (string)e.Element("value")!);

    private static Func<StringKey, string> Text(Dictionary<string, string> rows) =>
        key => rows[char.ToLowerInvariant(key.ToString()[0]) + key.ToString()[1..]];

    private static Source Make(long id, long? folder = null, string? rel = null, string availability = "present", string? lang = null) =>
        new(id, 1, SourceType.Text, "title-" + id, null, null, SourceStatus.Ready, null, DateTime.UnixEpoch,
            FolderId: folder, RelPath: rel, Availability: availability, Lang: lang);

    private static FolderRowViewModel Folder(long id) => new(
        new FolderSource(id, 1, new FolderDraft("C:\\docs" + id, "Docs" + id, ["md"], [], "{}", "cp1250", false),
            new FolderIdentity("v", ["docs" + id], "r"), "idle", 1, 10, null, 0),
        new CoverageSnapshot(0, 0, 0, 0, 0, 0, 0, 0, false, 0, 0), Text(En));

    [Fact]
    public void FoldersAreCollapsedByDefaultAndExpandedMembersFollowTheirFolder()
    {
        var text = Text(En);
        var first = Folder(1);
        var second = Folder(2);
        var loose = new SourceItem(Make(9), text);
        Assert.False(first.IsExpanded);
        Assert.Equal(new object[] { first, second, loose }, SourcesViewModel.Flatten([first, second], [loose]));

        var member = new SourceItem(Make(5, 1, "a/b.md"), text);
        first.IsExpanded = true;
        first.Members.Add(member);
        Assert.Equal(new object[] { first, member, first.Footer, second, loose }, SourcesViewModel.Flatten([first, second], [loose]));
        Assert.Equal("Hide files", first.ToggleLabel);
        Assert.Equal("Show files", second.ToggleLabel);
    }

    /// <summary>ingestion-retry-cap-v1 §5: failed folder members and loose files/URLs offer Retry; pasted text and notes don't.</summary>
    [Fact]
    public void FailedFolderMembersAndLooseFilesOfferRetry()
    {
        var text = Text(En);
        Source Failed(Source source) => source with { Status = SourceStatus.Error, Error = "corruptArchive" };
        Assert.True(new SourceItem(Failed(Make(5, 1, "a.docx")), text).CanRetry);
        Assert.True(new SourceItem(Failed(Make(6) with { RawPath = "C:\\a.docx" }), text).CanRetry);
        Assert.True(new SourceItem(Failed(Make(7) with { Type = SourceType.Web, Uri = "https://example.org/" }), text).CanRetry);
        Assert.False(new SourceItem(Failed(Make(8)), text).CanRetry);
        Assert.False(new SourceItem(Failed(Make(9) with { Type = SourceType.Note, RawPath = "x" }), text).CanRetry);
        Assert.False(new SourceItem(Make(10, 1, "b.docx"), text).CanRetry);
        var gaveUp = new SourceItem(Failed(Make(11) with { RawPath = "C:\\b.docx" }), text) { IsGaveUp = true };
        Assert.Equal("Error · The file is damaged or is not a valid document. · Gave up after 3 attempts", gaveUp.StatusText);
    }

    [Fact]
    public void MembersShowRelativePathAvailabilityAndLanguage()
    {
        var text = Text(En);
        var member = new SourceItem(Make(5, 1, "sub/č.md", "missing", "cs"), text);
        Assert.True(member.IsFolderMember);
        Assert.Equal("sub/č.md", member.DisplayTitle);
        Assert.Equal("Missing", member.AvailabilityText);
        Assert.Equal("CS", member.LanguageBadge);
        var loose = new SourceItem(Make(6), text);
        Assert.False(loose.IsFolderMember);
        Assert.Equal("title-6", loose.DisplayTitle);
        Assert.Null(loose.AvailabilityText);
        Assert.Null(loose.LanguageBadge);
        Assert.Equal("Unavailable", new SourceItem(Make(7, 1, "x.md", "unavailable"), text).AvailabilityText);

        Assert.Equal("Mixed", SourceItem.LanguageBadgeText("mixed", Text(En)));
        Assert.Equal("Více jazyků", SourceItem.LanguageBadgeText("mixed", Text(Cs)));
        Assert.Equal("DE", SourceItem.LanguageBadgeText("de", Text(Cs)));
        Assert.Null(SourceItem.LanguageBadgeText("und", Text(En)));
        Assert.Null(SourceItem.LanguageBadgeText(null, Text(En)));
    }

    [Fact]
    public void FooterCountsAndOffersMoreOnlyWhileIncomplete()
    {
        var footer = new FolderFooterRow(1, Text(En)) { Total = 5000, Shown = NotebookStore.FolderMembersPageSize };
        Assert.Equal("Files: 200 / 5000", footer.CountText);
        Assert.True(footer.HasMore);
        Assert.False(footer.IsEmptyFolder);
        footer.IsLoading = true;
        Assert.False(footer.HasMore);
        footer.IsLoading = false;
        footer.Shown = 5000;
        Assert.False(footer.HasMore);
        var empty = new FolderFooterRow(2, Text(Cs));
        Assert.True(empty.IsEmptyFolder);
        Assert.Equal("Soubory: 0 / 0", empty.CountText);
        Assert.Equal("Ze složky zatím nejsou žádné soubory", empty.NoFilesText);
    }
}
