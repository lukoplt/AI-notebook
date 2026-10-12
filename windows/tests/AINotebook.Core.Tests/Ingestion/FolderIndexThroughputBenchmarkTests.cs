using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// Opt-in synthetic large-folder benchmark (AINOTEBOOK_IDX_BENCH=1): one notebook, many published sources and
/// chunks in a file-backed database, a fresh building generation, and the real <see cref="FolderIndexCoordinator"/>
/// loop against a fixed-latency fake Ollama endpoint. Reports steady-state chunks/s; without the variable it
/// returns immediately (xunit 2 has no dynamic skip).
/// </summary>
[Trait("Category", "Benchmark")]
public sealed class FolderIndexThroughputBenchmarkTests(ITestOutputHelper output)
{
    private static int Setting(string name, int fallback) =>
        int.TryParse(Environment.GetEnvironmentVariable("AINOTEBOOK_IDX_BENCH_" + name), NumberStyles.Integer,
            CultureInfo.InvariantCulture, out int value) ? value : fallback;

    [Fact]
    public async Task BackgroundEmbeddingThroughput()
    {
        if (Environment.GetEnvironmentVariable("AINOTEBOOK_IDX_BENCH") != "1") return;
        int sources = Setting("SOURCES", 5_000), perSource = Setting("CHUNKS", 80), textLength = Setting("TEXT", 1_500);
        int dims = Setting("DIMS", 768), latencyMs = Setting("LATENCY_MS", 0), batches = Setting("BATCHES", 40);
        var probe = new FolderIndexCoordinator(new NotebookStore(StorePath.InMemory), new IngestionAdmission(), new FixedClock(),
            (_, _) => Task.FromResult<FolderEmbeddingSession?>(null), _ => Task.FromResult<EmbeddingSelection?>(null));
        int batchSize = Setting("BATCH_SIZE", probe.BatchSize);
        string seed = Template(sources, perSource, textLength);
        string work = Path.Combine(Path.GetDirectoryName(seed)!, $"idx-bench-run-{Guid.NewGuid():N}.sqlite");
        File.Copy(seed, work);
        try
        {
            using var store = new NotebookStore(new StorePath(work), configuredEmbeddingModelKey: null);
            long notebookId = store.Notebooks().Single().Id!.Value;
            using var cancel = new CancellationTokenSource();
            var handler = new TimedOllama(dims, latencyMs, batches, cancel);
            using var http = new HttpClient(handler);
            var session = new FolderEmbeddingSession(new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434",
                true, false, DateTime.UnixEpoch), "nomic-embed-text", null, null, "1", "1", http);
            var selection = session.Selection with { Dims = dims };
            long jobId = store.RequestEmbeddingBuild(notebookId, selection, copyExisting: false, 1);
            var job = store.ClaimJob(1, "bench", jobId)!;
            var coordinator = new FolderIndexCoordinator(store, new IngestionAdmission(), new FixedClock(),
                (_, _) => Task.FromResult<FolderEmbeddingSession?>(session), _ => Task.FromResult<EmbeddingSelection?>(selection))
            { BatchSize = batchSize };
            try { await coordinator.ExecuteAsync(job, new JobFence(jobId, "bench"), cancel.Token); }
            catch (OperationCanceledException) { }
            var calls = handler.Calls;
            Assert.True(batches >= 3);
            Assert.Equal(batches, calls.Count);
            // Steady state: the first interval (cold page cache, first reconcile) is excluded.
            int chunks = calls.Skip(1).Take(calls.Count - 2).Sum(c => c.Size);
            double seconds = (calls[^1].Start - calls[1].Start) / (double)Stopwatch.Frequency;
            long stored;
            using (var count = store.Connection.CreateCommand())
            {
                count.CommandText = "SELECT count(*) FROM chunk_embeddings";
                stored = (long)count.ExecuteScalar()!;
            }
            Assert.Equal(calls.Sum(c => c.Size), stored); // the stopping call never reaches the store
            double perBatch = seconds * 1000 / (calls.Count - 2);
            output.WriteLine(string.Format(CultureInfo.InvariantCulture,
                "IDX-BENCH dotnet sources={0} chunks={1} text={2} dims={3} batch={4} latencyMs={5}: {6:F1} chunks/s, {7:F1} ms/batch ({8:F1} ms non-provider)",
                sources, sources * perSource, textLength, dims, batchSize, latencyMs, chunks / seconds, perBatch, perBatch - latencyMs));
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            File.Delete(work);
        }
    }

    /// <summary>Seeds once per shape into a template file; each run works on a fresh copy.</summary>
    private static string Template(int sources, int perSource, int textLength)
    {
        string directory = Environment.GetEnvironmentVariable("AINOTEBOOK_IDX_BENCH_DIR") ?? Path.GetTempPath();
        string path = Path.Combine(directory, $"idx-bench-cs-{sources}x{perSource}x{textLength}.sqlite");
        if (File.Exists(path)) return path;
        string building = Path.Combine(directory, $"idx-bench-building-{Guid.NewGuid():N}.sqlite");
        using (var store = new NotebookStore(new StorePath(building), configuredEmbeddingModelKey: null))
        {
            long notebookId = store.CreateNotebook("bench").Id!.Value;
            var c = store.Connection;
            using var tx = c.BeginTransaction();
            Exec(c, tx, "DROP TRIGGER chunks_ai"); // The per-batch path never reads FTS.
            using var source = Command(c, tx, "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES ($nb,'text',$title,'ready','2026-10-10 00:00:00.000'); SELECT last_insert_rowid();", "$nb", "$title");
            using var revision = Command(c, tx, "INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at) VALUES ($s,1,$h,'',1,2,'2026-10-10 00:00:00.000'); SELECT last_insert_rowid();", "$s", "$h");
            using var publish = Command(c, tx, "UPDATE sources SET current_revision=$r,published_revision_id=$r WHERE id=$s", "$r", "$s");
            using var chunk = Command(c, tx, "INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang) VALUES ($s,$o,$t,$n,$r,$a,$b,'cs')", "$s", "$o", "$t", "$n", "$r", "$a", "$b");
            string[] words = ["dokument", "smlouva", "faktura", "report", "analysis", "vertrag", "projekt", "zmluva", "budget", "plan"];
            for (int s = 0; s < sources; s++)
            {
                source.Parameters["$nb"].Value = notebookId;
                source.Parameters["$title"].Value = $"file-{s}.txt";
                long sourceId = (long)source.ExecuteScalar()!;
                revision.Parameters["$s"].Value = sourceId;
                revision.Parameters["$h"].Value = $"hash-{s}";
                long revisionId = (long)revision.ExecuteScalar()!;
                publish.Parameters["$r"].Value = revisionId;
                publish.Parameters["$s"].Value = sourceId;
                publish.ExecuteNonQuery();
                for (int ord = 0; ord < perSource; ord++)
                {
                    var text = new StringBuilder($"source {s} chunk {ord} ");
                    int w = s + ord;
                    while (text.Length < textLength) { text.Append(words[w % words.Length]).Append(' '); w += 7; }
                    chunk.Parameters["$s"].Value = sourceId;
                    chunk.Parameters["$o"].Value = ord;
                    chunk.Parameters["$t"].Value = text.ToString();
                    chunk.Parameters["$n"].Value = textLength / 4;
                    chunk.Parameters["$r"].Value = revisionId;
                    chunk.Parameters["$a"].Value = ord * textLength;
                    chunk.Parameters["$b"].Value = (ord + 1) * textLength;
                    chunk.ExecuteNonQuery();
                }
            }
            Exec(c, tx, "CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN INSERT INTO chunks_fts(rowid,text,chunk_id) VALUES(new.id,new.text,new.id); END");
            tx.Commit();
        }
        SqliteConnection.ClearAllPools();
        File.Move(building, path);
        return path;
    }

    private static void Exec(SqliteConnection c, SqliteTransaction tx, string sql)
    {
        using var command = Command(c, tx, sql);
        command.ExecuteNonQuery();
    }

    private static SqliteCommand Command(SqliteConnection c, SqliteTransaction tx, string sql, params string[] parameters)
    {
        var command = c.CreateCommand();
        command.Transaction = tx;
        command.CommandText = sql;
        foreach (string name in parameters) command.Parameters.Add(new SqliteParameter(name, null));
        return command;
    }

    private sealed class FixedClock : IIngestLeaseClock
    {
        public long Now => 2;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.Delay(1000, ct);
    }

    /// <summary>Fake /api/embed with fixed latency; cancels the run after <c>limit</c> calls.</summary>
    private sealed class TimedOllama(int dims, int latencyMs, int limit, CancellationTokenSource cancel) : HttpMessageHandler
    {
        private readonly List<(long Start, int Size)> _calls = [];
        public IReadOnlyList<(long Start, int Size)> Calls { get { lock (_calls) return _calls.ToArray(); } }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            long start = Stopwatch.GetTimestamp();
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            int size = body.RootElement.GetProperty("input").GetArrayLength();
            lock (_calls)
            {
                if (_calls.Count >= limit)
                {
                    cancel.Cancel();
                    throw new OperationCanceledException(cancel.Token);
                }
                _calls.Add((start, size));
            }
            if (latencyMs > 0) await Task.Delay(latencyMs, ct);
            var vectors = Enumerable.Range(0, size).Select(i => Enumerable.Range(0, dims).Select(d => (double)((d + i) % 7 + 1)).ToArray()).ToArray();
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(new { embeddings = vectors }), Encoding.UTF8, "application/json")
            };
        }
    }
}
