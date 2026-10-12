using System.Net;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Shared <c>embedding-plan-v1</c> cases: priority order, spreadsheet cap and dedup through the real coordinator.</summary>
public sealed class EmbeddingPlanContractTests
{
    private static IEnumerable<JsonElement> Cases(string operation)
    {
        var root = SharedFixtures.Json("contracts/embedding-plan-v1.json");
        var constants = root.GetProperty("constants");
        Assert.Equal(EmbeddingPlan.SpreadsheetChunkCap, constants.GetProperty("spreadsheetChunkCap").GetInt32());
        Assert.Equal(EmbeddingPlan.RoundScanFactor, constants.GetProperty("roundScanFactor").GetInt32());
        Assert.Equal(EmbeddingPlan.SpreadsheetTypes.Select(t => t.RawValue()),
            constants.GetProperty("spreadsheetTypes").EnumerateArray().Select(t => t.GetString()!));
        return root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("operation").GetString() == operation).ToArray();
    }

    [Fact]
    public void ClassifyAndTextHash()
    {
        var classify = Cases("classify").ToArray();
        Assert.Equal(Enum.GetValues<SourceType>().Length, classify.Length);
        foreach (var c in classify)
        {
            var type = SourceTypeExtensions.FromRawValue(c.GetProperty("input").GetProperty("sourceType").GetString()!);
            var expected = c.GetProperty("expected");
            Assert.Equal(expected.GetProperty("priorityClass").GetInt32(), EmbeddingPlan.PriorityClass(type));
            var cap = expected.GetProperty("embedCap");
            Assert.Equal(cap.ValueKind == JsonValueKind.Null ? null : cap.GetInt32(), EmbeddingPlan.EmbedCap(type));
        }
        var hashes = Cases("textHash").ToArray();
        Assert.NotEmpty(hashes);
        foreach (var c in hashes)
            Assert.Equal(c.GetProperty("expected").GetProperty("hash").GetString(),
                EmbeddingPlan.TextHash(c.GetProperty("input").GetProperty("text").GetString()!));
    }

    [Fact]
    public async Task BuildCasesThroughTheCoordinator()
    {
        var builds = Cases("build").ToArray();
        Assert.True(builds.Length >= 6);
        foreach (var c in builds)
            foreach (int? dims in new int?[] { 3, null })
                await RunBuild(c, dims);
    }

    private static async Task RunBuild(JsonElement c, int? dims)
    {
        string name = c.GetProperty("name").GetString()! + (dims is null ? " (bootstrap)" : "");
        var input = c.GetProperty("input");
        var expected = c.GetProperty("expected");
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("plan").Id!.Value;
        Seed(store, notebookId, input.GetProperty("sources"));
        var handler = new RecordingOllama();
        using var http = new HttpClient(handler);
        var session = new FolderEmbeddingSession(new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434",
            true, false, DateTime.UnixEpoch), "m", null, null, "1", "1", http);
        var selection = session.Selection with { Dims = dims };
        long jobId = store.RequestEmbeddingBuild(notebookId, selection, copyExisting: false, 1);
        var job = store.ClaimJob(1, "plan", jobId)!;
        var coordinator = new FolderIndexCoordinator(store, new IngestionAdmission(), new PlanClock(),
            (_, _) => Task.FromResult<FolderEmbeddingSession?>(session), _ => Task.FromResult<EmbeddingSelection?>(selection))
        { BatchSize = input.GetProperty("batchSize").GetInt32() };
        await coordinator.ExecuteAsync(job, new JobFence(jobId, "plan"));

        var expectedCalls = expected.GetProperty("calls").EnumerateArray()
            .Select(call => call.EnumerateArray().Select(t => t.GetString()!).ToArray()).ToArray();
        Assert.True(expectedCalls.Length == handler.Calls.Count &&
                    expectedCalls.Zip(handler.Calls).All(p => p.First.SequenceEqual(p.Second, StringComparer.Ordinal)),
            $"{name}: calls {JsonSerializer.Serialize(handler.Calls)}");
        long active = store.Connection.ExecuteScalar<long>(
            "SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='active'", new { notebookId });
        var progress = store.Connection.QuerySingle(NotebookStore.ChunkProgressSql, new { generationId = active });
        Assert.Equal(expected.GetProperty("chunkProgress").GetProperty("done").GetInt64(), (long)progress.done);
        Assert.Equal(expected.GetProperty("chunkProgress").GetProperty("total").GetInt64(), (long)progress.total);
        var manifest = store.Manifest(active);
        Assert.Equal(expected.GetProperty("sourceProgress").GetProperty("done").GetInt32(), manifest.Count(e => e.State == "done"));
        Assert.Equal(expected.GetProperty("sourceProgress").GetProperty("total").GetInt32(), manifest.Count);
        Assert.Equal(expected.GetProperty("copied").GetInt64(), store.Connection.ExecuteScalar<long>(
            "SELECT count(*) FROM generation_text_hashes WHERE generation_id=$active AND copied=1", new { active }));
        var rows = store.Connection.Query("""
            SELECT c.source_id,c.ord,c.text,e.embedding FROM source_chunks c
            LEFT JOIN chunk_embeddings e ON e.chunk_id=c.id AND e.generation_id=$active
            ORDER BY c.source_id,c.ord
            """, new { active }).ToArray();
        var unembedded = rows.Where(r => r.embedding is null).Select(r => new[] { (long)r.source_id, (long)r.ord }).ToArray();
        var expectedUnembedded = expected.GetProperty("unembedded").EnumerateArray()
            .Select(p => p.EnumerateArray().Select(v => v.GetInt64()).ToArray()).ToArray();
        Assert.True(expectedUnembedded.Length == unembedded.Length && expectedUnembedded.Zip(unembedded).All(p => p.First.SequenceEqual(p.Second)), name);
        var byText = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var row in rows.Where(r => r.embedding is not null))
        {
            string text = (string)row.text;
            byte[] bytes = (byte[])row.embedding;
            if (byText.TryGetValue(text, out var first)) Assert.Equal(first, bytes);
            else byText[text] = bytes;
        }
        Assert.Equal((long)progress.done, store.Connection.ExecuteScalar<long>(
            "SELECT count(*) FROM generation_text_hashes WHERE generation_id=$active", new { active }));
    }

    /// <summary>One published revision per source; chunk <c>ord</c> = index in the case.</summary>
    internal static void Seed(NotebookStore store, long notebookId, JsonElement sources)
    {
        lock (store.Gate)
        {
            var c = store.Connection;
            foreach (var source in sources.EnumerateArray())
            {
                long id = source.GetProperty("id").GetInt64();
                string type = source.GetProperty("type").GetString()!;
                var chunks = source.GetProperty("chunks").EnumerateArray().Select(t => t.GetString()!).ToArray();
                c.Execute("INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES ($id,$notebookId,$type,$title,'ready','2026-10-11 00:00:00.000')",
                    new { id, notebookId, type, title = $"source {id}" });
                long revision = c.ExecuteScalar<long>("""
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES ($id,1,$hash,$text,1,2,'2026-10-11 00:00:00.000'); SELECT last_insert_rowid();
                    """, new { id, hash = $"hash-{id}", text = string.Join("\n\n", chunks) });
                c.Execute("UPDATE sources SET current_revision=$revision,published_revision_id=$revision WHERE id=$id", new { revision, id });
                for (int ord = 0; ord < chunks.Length; ord++)
                    c.Execute("INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end) VALUES ($id,$ord,$text,1,$revision,0,0)",
                        new { id, ord, text = chunks[ord], revision });
            }
        }
    }

    internal sealed class PlanClock : IIngestLeaseClock
    {
        public long Now => 2;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.Delay(1, ct);
    }

    /// <summary>Fake /api/embed: records each request's inputs and answers a deterministic nonzero vector per text.</summary>
    internal sealed class RecordingOllama : HttpMessageHandler
    {
        private readonly List<string[]> _calls = [];
        public IReadOnlyList<string[]> Calls { get { lock (_calls) return _calls.ToArray(); } }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            var inputs = body.RootElement.GetProperty("input").EnumerateArray().Select(t => t.GetString()!).ToArray();
            lock (_calls) _calls.Add(inputs);
            var vectors = inputs.Select(text =>
            {
                var scalars = text.EnumerateRunes().Select(r => r.Value).ToArray();
                return new double[] { scalars.Length + 1, scalars.Sum() % 997 + 1, scalars.Length > 0 ? scalars[0] : 7 };
            }).ToArray();
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(new { embeddings = vectors }), Encoding.UTF8, "application/json")
            };
        }
    }
}
