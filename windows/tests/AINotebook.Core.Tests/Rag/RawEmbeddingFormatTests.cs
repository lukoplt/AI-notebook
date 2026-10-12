using AINotebook.Core.Ingestion;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Ingestion;
using Dapper;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

public sealed class RawEmbeddingFormatTests
{
    private sealed class Recording : IEmbeddingProducing
    {
        public List<string> Inputs { get; } = [];
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        {
            lock (Inputs) Inputs.AddRange(inputs);
            return Task.FromResult(inputs.Select(_ => new float[] { 1, 0, 0, 0 }).ToArray());
        }
    }

    [Fact]
    public void SharedCases()
    {
        var fixture = SharedFixtures.Json("contracts/embedding-raw-format-v2.json");
        Assert.Equal(RawEmbeddingFormat.Current, fixture.GetProperty("current").GetString());
        Assert.Equal(RawEmbeddingFormat.HeaderMaxScalars, fixture.GetProperty("headerMaxScalars").GetInt32());
        var cases = fixture.GetProperty("cases").EnumerateArray().ToList();
        Assert.Equal(13, cases.Count);
        foreach (var c in cases)
        {
            string model = c.GetProperty("model").GetString()!, format = c.GetProperty("format").GetString()!, text = c.GetProperty("text").GetString()!;
            string? relPath = c.GetProperty("relPath").ValueKind == System.Text.Json.JsonValueKind.Null ? null : c.GetProperty("relPath").GetString();
            string actual = c.GetProperty("purpose").GetString() == "query"
                ? RawEmbeddingFormat.Query(text, model, format)
                : RawEmbeddingFormat.Document((format == "2" ? RawEmbeddingFormat.Header(relPath, c.GetProperty("title").GetString()!) : "") + text,
                    model, format);
            Assert.Equal(c.GetProperty("expected").GetString(), actual);
        }
    }

    /// <summary>Queries of a format-2 generation carry the query prefix; format 1 stays verbatim.</summary>
    [Theory]
    [InlineData("2", "search_query: Kdy končí smlouva?")]
    [InlineData("1", "Kdy končí smlouva?")]
    [InlineData("legacy", "Kdy končí smlouva?")]
    public async Task QuerySessionsFollowTheGenerationFormat(string format, string expected)
    {
        var client = new Recording();
        var session = new ProviderEmbeddingSession(client, "nomic-embed-text", "local:nomic-embed-text", "e", rawFormat: format);
        await session.EmbedAsync(["Kdy končí smlouva?"]);
        Assert.Equal([expected], client.Inputs);
    }

    /// <summary>A format-2 build sends "&lt;document prefix&gt;&lt;path line&gt;\n&lt;chunk text&gt;"; a complete
    /// format-1 index is rebuilt once at format 2 while the old one keeps serving.</summary>
    [Fact]
    public async Task FormatTwoBuildSendsPrefixAndPathHeaderAndUpgradesOnce()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("f", "").Id!.Value;
        lock (store.Gate)
        {
            var c = store.Connection;
            long folder = c.ExecuteScalar<long>("""
                INSERT INTO folder_sources(notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                VALUES (@nb,'/r','{}','Archive','[]','[]','{}','2026-10-11') RETURNING id
                """, new { nb = notebookId });
            long source = c.ExecuteScalar<long>("""
                INSERT INTO sources(notebook_id,type,title,status,ingested_at,folder_id,rel_path)
                VALUES (@nb,'text','Nabidka.pdf','ready','2026-10-11 00:00:00.000',@f,'Klient/2026/Nabidky/Nabidka.pdf') RETURNING id
                """, new { nb = notebookId, f = folder });
            long revision = c.ExecuteScalar<long>("""
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES (@s,1,'h','',1,2,'2026-10-11 00:00:00.000') RETURNING id
                """, new { s = source });
            c.Execute("UPDATE sources SET current_revision=@r,published_revision_id=@r WHERE id=@s", new { r = revision, s = source });
            c.Execute("INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id) VALUES (@s,0,'Cena 15 000 Kč',4,@r)", new { s = source, r = revision });
        }
        var config = new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434", true, false, DateTime.UnixEpoch);
        foreach (string format in new[] { "1", "2" })
        {
            var handler = new EmbeddingPlanContractTests.RecordingOllama();
            using var http = new HttpClient(handler);
            var session = new FolderEmbeddingSession(config, "nomic-embed-text:latest", null, null, format, format, http);
            var selection = session.Selection;
            var active = store.ActiveGeneration(notebookId);
            if (format == "2")
            {
                Assert.True(FolderIngestionRuntime.RawFormatUpgradeDue(active, selection with { Dims = active!.Identity.Dims }));
                Assert.Equal("1", active.Identity.DocFormatVersion);
            }
            long jobId = store.RequestEmbeddingBuild(notebookId, selection, copyExisting: true, 1);
            var job = store.ClaimJob(1, "t" + format, jobId)!;
            var coordinator = new FolderIndexCoordinator(store, new IngestionAdmission(), new EmbeddingPlanContractTests.PlanClock(),
                (_, _) => Task.FromResult<FolderEmbeddingSession?>(session), _ => Task.FromResult<EmbeddingSelection?>(selection));
            await coordinator.ExecuteAsync(job, new JobFence(jobId, "t" + format));
            Assert.Equal(format == "2" ? ["search_document: Klient/2026/Nabidky/Nabidka.pdf\nCena 15 000 Kč"] : ["Cena 15 000 Kč"],
                handler.Calls.SelectMany(x => x));
            Assert.Equal(format, store.ActiveGeneration(notebookId)!.Identity.DocFormatVersion);
        }
        var upgraded = store.ActiveGeneration(notebookId)!;
        Assert.False(FolderIngestionRuntime.RawFormatUpgradeDue(upgraded, new EmbeddingSelection(upgraded.Identity.ProviderId,
            upgraded.Identity.EndpointRevision, upgraded.Identity.Model, null, null, "l2", "2", "2", "2")), "the upgrade happens once");
    }
}
