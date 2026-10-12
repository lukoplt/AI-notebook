using AINotebook.Core.Language;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using System.Text.Json;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

public sealed class PathMatcherTests
{
    private static List<PathMatchFile> Files(JsonElement c) => c.GetProperty("files").EnumerateArray().Select(f => new PathMatchFile(
        f.GetProperty("sourceId").GetInt64(),
        f.GetProperty("relPath").ValueKind == JsonValueKind.Null ? null : f.GetProperty("relPath").GetString(),
        f.GetProperty("title").GetString()!,
        f.GetProperty("mtime").ValueKind == JsonValueKind.Null ? null : f.GetProperty("mtime").GetInt64())).ToList();

    /// <summary>v1 cases, with the v2 fixture's supersedes replacing the cases whose order changed.</summary>
    [Fact]
    public void SharedCases()
    {
        var fixture = SharedFixtures.Json("contracts/retrieval-paths-v1.json");
        var supersedes = SharedFixtures.Json("contracts/retrieval-paths-v2.json").GetProperty("supersedes")
            .GetProperty("retrieval-paths-v1.json").GetProperty("cases");
        Assert.Equal(PathMatcher.MaxMatchingFiles, fixture.GetProperty("maxMatchingFiles").GetInt32());
        var matcher = new PathMatcher(UnicodeTables.LoadBundled());
        var cases = fixture.GetProperty("cases").EnumerateArray().ToList();
        Assert.Equal(10, cases.Count);
        Assert.Empty(supersedes.EnumerateObject().Select(p => p.Name).Except(cases.Select(c => c.GetProperty("name").GetString())));
        foreach (var c in cases)
        {
            string name = c.GetProperty("name").GetString()!;
            var rows = supersedes.TryGetProperty(name, out var replaced) ? replaced : c.GetProperty("expected");
            var expected = rows.EnumerateArray().Select(e => (e.GetProperty("sourceId").GetInt64(),
                e.GetProperty("matched").GetInt32(), e.GetProperty("weight").GetInt32(), e.GetProperty("date").GetInt32())).ToList();
            var actual = matcher.Rank(c.GetProperty("query").GetString()!, Files(c)).Select(m => (m.SourceId, m.Matched, m.Weight, m.Date)).ToList();
            Assert.True(expected.SequenceEqual(actual), name);
        }
    }

    /// <summary>retrieval-paths v2 (§6): strengths, project directories and the inventory signal.</summary>
    [Fact]
    public void SharedV2Cases()
    {
        var fixture = SharedFixtures.Json("contracts/retrieval-paths-v2.json");
        var classes = fixture.GetProperty("typeClasses").EnumerateArray().ToList();
        Assert.Equal(PathMatcher.TypeClasses.Select(c => c.Name), classes.Select(c => c.GetProperty("name").GetString()));
        for (int i = 0; i < classes.Count; i++)
            Assert.Equal(PathMatcher.TypeClasses[i].Stems, classes[i].GetProperty("stems").EnumerateArray().Select(x => x.GetString()!));
        var inventory = fixture.GetProperty("inventory");
        Assert.Equal(ContextPackInventory.MapShareBp, inventory.GetProperty("mapShareBp").GetInt32());
        Assert.Equal(ContextPackInventory.FloorEntries, inventory.GetProperty("floorEntries").GetInt32());
        Assert.Equal(ContextPackInventory.FloorMaxShareBp, inventory.GetProperty("floorMaxShareBp").GetInt32());
        Assert.Equal(ContextPackInventory.FileLevelMax, inventory.GetProperty("fileLevelMax").GetInt32());
        var matcher = new PathMatcher(UnicodeTables.LoadBundled());
        var cases = fixture.GetProperty("cases").EnumerateArray().ToList();
        Assert.Equal(18, cases.Count);
        foreach (var c in cases)
        {
            string name = c.GetProperty("name").GetString()!;
            var expected = c.GetProperty("expected");
            var matches = expected.GetProperty("matches").EnumerateArray().Select(e => new PathMatch(e.GetProperty("sourceId").GetInt64(),
                e.GetProperty("matched").GetInt32(), e.GetProperty("score").GetInt32(), e.GetProperty("weight").GetInt32(),
                e.GetProperty("date").GetInt32(), e.GetProperty("project").GetString()!)).ToList();
            var actual = matcher.Ranking(c.GetProperty("query").GetString()!, Files(c));
            Assert.True(matches.SequenceEqual(actual.Matches), name);
            Assert.True(expected.GetProperty("inventory").GetBoolean() == actual.Inventory, name);
        }
    }

    [Fact]
    public void SharedV2MapCases()
    {
        var cases = SharedFixtures.Json("contracts/retrieval-paths-v2.json").GetProperty("mapCases").EnumerateArray().ToList();
        Assert.Equal(6, cases.Count);
        var template = ContextPackFixtures.Input("basic-cs");
        foreach (var c in cases)
        {
            string name = c.GetProperty("name").GetString()!;
            var input = template with { FolderMap = c.GetProperty("folderMap").Deserialize<PackFile[]>(ContextPackFixtures.Options)! };
            var raw = c.GetProperty("matchingBudget");
            var budget = raw.ValueKind == JsonValueKind.Null ? null
                : new MatchingBudget(raw.GetProperty("ceiling").GetInt64(), raw.GetProperty("floorLimit").GetInt64());
            var (section, included, omitted) = ContextPackRendering.RenderMap(input, c.GetProperty("ceiling").GetInt64(), [],
                new PlaceholderTokenEstimatorV1(), budget);
            var expected = c.GetProperty("expected");
            Assert.True((expected.GetProperty("text").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("text").GetString())
                == section?.Text, name);
            Assert.Equal(expected.GetProperty("included").EnumerateArray().Select(x => x.GetString()), included);
            Assert.Equal(expected.GetProperty("omitted").EnumerateArray().Select(x => x.GetString()), omitted);
        }
    }

    /// <summary>Whole packs: an inventory question keeps every project in the map even at 8 192 tokens.</summary>
    [Fact]
    public void SharedV2PackCases()
    {
        var cases = SharedFixtures.Json("contracts/retrieval-paths-v2.json").GetProperty("packCases").EnumerateArray().ToList();
        Assert.Equal(4, cases.Count);
        foreach (var c in cases)
        {
            string name = c.GetProperty("name").GetString()!;
            var input = c.GetProperty("input").Deserialize<ContextPackInput>(ContextPackFixtures.Options)!;
            var request = ContextPackBuilder.Build(input, new PlaceholderTokenEstimatorV1(), RagRuntimeTuning.V1);
            ContextPackBuilderTests.EqualJson(c.GetProperty("expected"), PreparedContextRequestJson.Element(request), name);
        }
    }

    /// <summary>retrieval-paths-v1 §5: the map lists the question's path matches first.</summary>
    [Fact]
    public void SharedMapCases()
    {
        var cases = SharedFixtures.Json("contracts/retrieval-paths-v1.json").GetProperty("mapCases").EnumerateArray().ToList();
        Assert.Equal(5, cases.Count);
        var template = ContextPackFixtures.Input("basic-cs");
        var passage = template.Candidates[0];
        foreach (var c in cases)
        {
            var input = template with
            {
                FolderMap = c.GetProperty("folderMap").Deserialize<PackFile[]>(ContextPackFixtures.Options)!
            };
            var direct = c.GetProperty("directSourceIds").EnumerateArray().Select(id => passage with { SourceId = id.GetInt64() }).ToArray();
            var (section, included, omitted) = ContextPackRendering.RenderMap(input, c.GetProperty("ceiling").GetInt64(), direct,
                new PlaceholderTokenEstimatorV1());
            var expected = c.GetProperty("expected");
            Assert.Equal(expected.GetProperty("text").ValueKind == System.Text.Json.JsonValueKind.Null ? null : expected.GetProperty("text").GetString(),
                section?.Text);
            Assert.Equal(expected.GetProperty("included").EnumerateArray().Select(x => x.GetString()), included);
            Assert.Equal(expected.GetProperty("omitted").EnumerateArray().Select(x => x.GetString()), omitted);
        }
    }
}

public sealed class PathBranchRetrievalTests
{
    private sealed class NoEmbedding : AINotebook.Core.Ollama.IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
            => throw new OperationCanceledException();
    }

    /// <summary>retrieval-paths-v1 §4: the best path-matching files' first chunks form a third RRF branch.</summary>
    [Fact]
    public async Task PathBranchFusesFirstChunksOfMatchingFiles()
    {
        using var store = new AINotebook.Core.Storage.NotebookStore(AINotebook.Core.Storage.StorePath.InMemory);
        long notebookId = store.CreateNotebook("paths", "").Id!.Value;
        string[] files =
        [
            "ACME/2026/P-0001 Portal/Nabidky/20260617_Migrace.xlsx",
            "ACME/2026/P-0001 Portal/Objednavky/objednavka.pdf",
            "ACMER/2026/P-0004 Cloud/Nabidky/20260201_Cloud.pdf",
            "ACME/2026/P-0002 Helpdesk/Nabidky/RE_ potvrzeni.msg",
        ];
        var heads = new List<long>();
        lock (store.Gate)
        {
            var c = store.Connection;
            long folder = Dapper.SqlMapper.ExecuteScalar<long>(c, """
                INSERT INTO folder_sources(notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                VALUES (@nb,'/r','{}','Archive','[]','[]','{}','2026-10-11') RETURNING id
                """, new { nb = notebookId });
            for (int i = 0; i < files.Length; i++)
            {
                long source = Dapper.SqlMapper.ExecuteScalar<long>(c, """
                    INSERT INTO sources(notebook_id,type,title,status,ingested_at,folder_id,rel_path)
                    VALUES (@nb,'text',@t,'ready','2026-10-11 00:00:00.000',@f,@p) RETURNING id
                    """, new { nb = notebookId, t = files[i].Split('/')[^1], f = folder, p = files[i] });
                long revision = Dapper.SqlMapper.ExecuteScalar<long>(c, """
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (@s,1,@h,'',1,2,'2026-10-11 00:00:00.000') RETURNING id
                    """, new { s = source, h = "h" + i });
                Dapper.SqlMapper.Execute(c, "UPDATE sources SET current_revision=@r,published_revision_id=@r WHERE id=@s", new { r = revision, s = source });
                for (int ord = 0; ord < 2; ord++)
                {
                    long chunk = Dapper.SqlMapper.ExecuteScalar<long>(c,
                        "INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id) VALUES (@s,@o,@t,2,@r) RETURNING id",
                        new { s = source, o = ord, t = $"cell {i} {ord}", r = revision });
                    if (ord == 0) heads.Add(chunk);
                }
            }
        }
        var retriever = new Retriever(store, new NoEmbedding(), () => "none", new VectorMatrixCache(), null);
        using var pool = await retriever.SearchAsync(notebookId, "jaké nabídky jsme poslali v 2026 pro ACME?",
            new RetrievalScope.All(), 8, includeVectors: false);
        // Files 1 and 4 match nabídky + 2026 + ACME; ACMER and the order folder do not reach the best tier.
        Assert.Equal(new long[] { 1, 4 }, pool.PathMatches.Select(m => m.SourceId).Order());
        Assert.Equal(new[] { heads[0], heads[3] }.Order(), pool.Path.Select(p => p.Reference.ChunkId).Order());
        Assert.Empty(pool.Lexical);
        Assert.Equal(pool.Path.Select(p => p.Reference.ChunkId), pool.Fused.Select(p => p.Reference.ChunkId));
    }
}
