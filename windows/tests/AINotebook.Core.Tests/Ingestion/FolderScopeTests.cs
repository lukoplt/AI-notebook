using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class FolderScopeTests
{
    [Fact]
    public void EmptySelectionNeverBecomesAll()
    {
        var s = new FolderScopeSelection(false, new HashSet<long>(), new HashSet<long>(), new HashSet<long>());
        Assert.True(s.Resolved(new Dictionary<long, RetrievalScope>()).IsEmptySelection);
        Assert.IsType<RetrievalScope.All>((s with { WholeNotebook = true }).Resolved(new Dictionary<long, RetrievalScope>()));
    }

    [Fact]
    public void SetsResolveEachTurnWithoutExpandingFolders()
    {
        var s = new FolderScopeSelection(false, new HashSet<long> { 1 }, new HashSet<long> { 8 }, new HashSet<long> { 9 });
        var first = s.Resolved(new Dictionary<long, RetrievalScope> { [9] = new RetrievalScope.Selection(new HashSet<long> { 2 }, new HashSet<long> { 7 }) });
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long> { 1, 2 }, new HashSet<long> { 7, 8 }), first);
        var second = s.Resolved(new Dictionary<long, RetrievalScope> { [9] = new RetrievalScope.Selection(new HashSet<long> { 3 }, new HashSet<long> { 10 }) });
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long> { 1, 3 }, new HashSet<long> { 8, 10 }), second);
        // Input sets are snapshotted.
        var sources = new HashSet<long> { 4 };
        var copy = new FolderScopeSelection(false, sources, new HashSet<long>(), new HashSet<long>());
        sources.Add(5);
        Assert.Equal(new long[] { 4 }, copy.SourceIds);
    }

    [Fact]
    public void AllSharedScopeCases()
    {
        var cases = SharedFixtures.Json("contracts/ingestion-ui-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("operation").GetString() == "scope").ToArray();
        Assert.Equal(7, cases.Length);
        foreach (var c in cases)
        {
            var i = c.GetProperty("input"); var e = c.GetProperty("expected");
            var s = new FolderScopeSelection(i.GetProperty("wholeNotebook").GetBoolean(), Ids(i, "sourceIds"), Ids(i, "folderIds"), Ids(i, "setIds"));
            var sets = i.GetProperty("members").EnumerateArray().ToDictionary(x => x.GetProperty("setId").GetInt64(),
                x => (RetrievalScope)new RetrievalScope.Selection(Ids(x, "sourceIds"), Ids(x, "folderIds")));
            RetrievalScope expected = e.GetProperty("kind").GetString() == "all" ? new RetrievalScope.All() :
                new RetrievalScope.Selection(Ids(e, "sourceIds"), Ids(e, "folderIds"));
            Assert.Equal(expected, s.Resolved(sets));
        }
    }

    [Fact]
    public void StoreRejectsCrossNotebookIDs()
    {
        var cases = SharedFixtures.Json("contracts/ingestion-ui-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("operation").GetString() == "scope-store").ToArray();
        Assert.Equal(5, cases.Length);
        foreach (var c in cases)
        {
            var i = c.GetProperty("input");
            using var store = Seed(i.GetProperty("seed"));
            var sel = i.GetProperty("selection");
            var selection = new FolderScopeSelection(sel.GetProperty("wholeNotebook").GetBoolean(), Ids(sel, "sourceIds"),
                Ids(sel, "folderIds"), Ids(sel, "setIds"));
            var expected = c.GetProperty("expected");
            long notebook = i.GetProperty("notebookId").GetInt64();
            if (expected.TryGetProperty("error", out var error))
            {
                Assert.Equal(error.GetString(), Assert.Throws<StorageV19Exception>(() => store.ResolveFolderScope(notebook, selection)).Code);
                Assert.Equal(error.GetString(), Assert.Throws<StorageV19Exception>(() => store.SaveFolderScopeSet(notebook, "x", selection)).Code);
                continue;
            }
            var scope = expected.GetProperty("scope");
            Assert.Equal("selection", scope.GetProperty("kind").GetString());
            Assert.Equal(new RetrievalScope.Selection(Ids(scope, "sourceIds"), Ids(scope, "folderIds")), store.ResolveFolderScope(notebook, selection));
        }
        // Whole-notebook scopes are never saved as a permanent set; an explicit one persists sources and folders atomically.
        using var saved = Seed(cases[0].GetProperty("input").GetProperty("seed"));
        Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => saved.SaveFolderScopeSet(1, "all", FolderScopeSelection.Whole)).Code);
        var set = saved.SaveFolderScopeSet(1, " Mine ", new FolderScopeSelection(false, new HashSet<long> { 101 }, new HashSet<long>(), new HashSet<long> { 9 }));
        Assert.Equal("Mine", set.Name);
        Assert.Equal(new long[] { 101 }, saved.SourceSetMembers(set.Id));
        Assert.Equal(new long[] { 1 }, saved.SourceSetFolders(set.Id));
        // Membership changes apply on the next resolution.
        saved.SetSourceSetFolders(set.Id, []);
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long> { 101 }, new HashSet<long>()),
            saved.ResolveFolderScope(1, new FolderScopeSelection(false, new HashSet<long>(), new HashSet<long>(), new HashSet<long> { set.Id })));
    }

    [Fact]
    public void RemovedSelectedFolderStaysEmpty()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("scope").Id!.Value;
        var folder = store.CreateFolder(nb, new FolderDraft("/docs", "Docs", ["md"], [], "{}", "cp1250", true),
            new FixedIdentity(new FolderIdentity("v", ["docs"], "r")), 0);
        var selection = new FolderScopeSelection(false, new HashSet<long>(), new HashSet<long> { folder.Id }, new HashSet<long>());
        Assert.Equal(new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long> { folder.Id }), store.ResolveFolderScope(nb, selection));
        store.DeleteFolder(folder.Id);
        var resolved = store.ResolveFolderScope(nb, selection);
        Assert.True(resolved.IsEmptySelection);
        Assert.Empty(store.ChatSourceIds(nb, resolved)!);
        Assert.Equal("notFound", Assert.Throws<StorageV19Exception>(() => store.ResolveFolderScope(999, selection)).Code);
    }

    private static NotebookStore Seed(JsonElement seed)
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        foreach (var nb in seed.GetProperty("notebooks").EnumerateArray()) Assert.Equal(nb.GetProperty("id").GetInt64(), store.CreateNotebook("n").Id);
        lock (store.Gate)
        {
            var c = store.Connection;
            foreach (var f in seed.GetProperty("folders").EnumerateArray())
                c.Execute("""
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                    VALUES($id,$nb,$root,$identity,'F','["md"]','[]','{}','2026-01-01 00:00:00.000')
                    """, new
                {
                    id = f.GetProperty("id").GetInt64(), nb = f.GetProperty("notebookId").GetInt64(), root = $"/f{f.GetProperty("id").GetInt64()}",
                    identity = $$"""{"volumeId":"v","components":["f{{f.GetProperty("id").GetInt64()}}"],"rootFileId":"r"}"""
                });
            foreach (var s in seed.GetProperty("sources").EnumerateArray())
                c.Execute("""
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path)
                    VALUES($id,$nb,'text','s','ready','2026-01-01 00:00:00.000',$folder,$path)
                    """, new
                {
                    id = s.GetProperty("id").GetInt64(), nb = s.GetProperty("notebookId").GetInt64(),
                    folder = s.GetProperty("folderId").GetInt64(), path = $"s{s.GetProperty("id").GetInt64()}.md"
                });
            foreach (var set in seed.GetProperty("sets").EnumerateArray())
            {
                long id = set.GetProperty("id").GetInt64();
                c.Execute("INSERT INTO source_sets(id,notebook_id,name,created_at) VALUES($id,$nb,'set','2026-01-01 00:00:00.000')",
                    new { id, nb = set.GetProperty("notebookId").GetInt64() });
                foreach (var source in set.GetProperty("sourceIds").EnumerateArray())
                    c.Execute("INSERT INTO source_set_members(set_id,source_id) VALUES($id,$source)", new { id, source = source.GetInt64() });
                foreach (var folder in set.GetProperty("folderIds").EnumerateArray())
                    c.Execute("INSERT INTO source_set_folders(set_id,folder_id) VALUES($id,$folder)", new { id, folder = folder.GetInt64() });
            }
        }
        return store;
    }

    private sealed class FixedIdentity(FolderIdentity identity) : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => identity;
    }

    private static HashSet<long> Ids(JsonElement e, string key) => e.GetProperty(key).EnumerateArray().Select(x => x.GetInt64()).ToHashSet();
}
