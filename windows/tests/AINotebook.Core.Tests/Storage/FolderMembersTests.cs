using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>Shared folder-members-v1 fixture: the paged member query behind the grouped Sources list.</summary>
public sealed class FolderMembersTests
{
    private sealed class PathIdentity : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string path) => new("v", [path], path);
    }

    private static JsonElement Fixture() => SharedFixtures.Json("contracts/folder-members-v1.json");

    private static JsonElement Case(string name) =>
        Fixture().GetProperty("cases").EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);

    private static string[] Strings(JsonElement c, string property) =>
        c.TryGetProperty(property, out var value) ? value.EnumerateArray().Select(v => v.GetString()!).ToArray() : [];

    private static FolderDraft Draft(string root) => new(root, root, ["md"], [], "{}", "cp1250", false);

    private sealed record Seeded(NotebookStore Store, long Notebook, long Folder, Dictionary<string, long> Ids);

    private static Seeded Seed(JsonElement c, Func<string, string?>? rawPath = null)
    {
        var store = V19TestStore.Create();
        long notebook = store.CreateNotebook("members").Id!.Value;
        var folder = store.CreateFolder(notebook, Draft("/docs"), new PathIdentity(), 0);
        var other = store.CreateFolder(notebook, Draft("/other"), new PathIdentity(), 0);
        var ids = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var path in Strings(c, "members"))
        {
            long id = store.CreateSource(notebook, SourceType.Text, "t-" + path, null, rawPath?.Invoke(path)).Id!.Value;
            store.AttachSource(id, folder.Id, path);
            ids[path] = id;
        }
        foreach (var path in Strings(c, "otherFolderMembers"))
        {
            long id = store.CreateSource(notebook, SourceType.Text, "o-" + path, null, null).Id!.Value;
            store.AttachSource(id, other.Id, path);
        }
        foreach (var title in Strings(c, "looseTitles")) store.CreateSource(notebook, SourceType.Text, title, null, null);
        foreach (var title in Strings(c, "noteTitles")) store.CreateSource(notebook, SourceType.Note, title, null, null);
        return new Seeded(store, notebook, folder.Id, ids);
    }

    private static void AssertPage(NotebookStore store, long folder, JsonElement p)
    {
        var page = store.FolderMembers(folder, p.GetProperty("offset").GetInt32(), p.GetProperty("limit").GetInt32());
        Assert.Equal(Strings(p, "expected"), page.Members.Select(m => m.RelPath ?? "").ToArray());
        Assert.All(page.Members, m => Assert.Equal(folder, m.FolderId));
        Assert.Equal(p.GetProperty("total").GetInt32(), page.Total);
        Assert.Equal(p.GetProperty("nextOffset").GetInt32(), page.NextOffset);
        Assert.Equal(p.GetProperty("hasMore").GetBoolean(), page.HasMore);
    }

    [Theory]
    [InlineData("paged-byte-order")]
    [InlineData("empty-folder")]
    public void PagesFollowByteOrderAndExcludeOtherFoldersAndLooseSources(string name)
    {
        var c = Case(name);
        var seeded = Seed(c);
        using var store = seeded.Store;
        foreach (var p in c.GetProperty("pages").EnumerateArray()) AssertPage(store, seeded.Folder, p);
        var loose = store.LooseSources(seeded.Notebook);
        Assert.Equal(Strings(c, "expectedLooseTitles"), loose.Select(s => s.Title).OrderBy(t => t, StringComparer.Ordinal).ToArray());
        Assert.All(loose, s => { Assert.Null(s.FolderId); Assert.NotEqual(SourceType.Note, s.Type); });
    }

    [Fact]
    public void InvalidArgumentsAreRejected()
    {
        Assert.Equal(Fixture().GetProperty("maxLimit").GetInt32(), NotebookStore.FolderMembersMaxLimit);
        Assert.Equal(Fixture().GetProperty("uiPageSize").GetInt32(), NotebookStore.FolderMembersPageSize);
        var c = Case("invalid-arguments");
        var seeded = Seed(c);
        using var store = seeded.Store;
        foreach (var row in c.GetProperty("invalid").EnumerateArray())
        {
            long folder = row.GetProperty("folder").GetString() == "missing" ? 999_999 : seeded.Folder;
            var error = Assert.Throws<StorageV19Exception>(() =>
                store.FolderMembers(folder, row.GetProperty("offset").GetInt32(), row.GetProperty("limit").GetInt32()));
            Assert.Equal(row.GetProperty("expectedError").GetString(), error.Code);
        }
    }

    [Fact]
    public void DeletingAMemberKeepsTheFileOnDisk()
    {
        var c = Case("delete-member-keeps-file");
        string directory = Path.Combine(Path.GetTempPath(), $"ainotebook-members-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            string target = c.GetProperty("deleteMember").GetString()!;
            string file = Path.Combine(directory, "member.md");
            File.WriteAllText(file, "keep me");
            var seeded = Seed(c, path => path == target ? file : null);
            using var store = seeded.Store;
            store.DeleteSource(seeded.Ids[target]);
            Assert.True(File.Exists(file));
            Assert.Equal("keep me", File.ReadAllText(file));
            AssertPage(store, seeded.Folder, c.GetProperty("after"));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }
}
