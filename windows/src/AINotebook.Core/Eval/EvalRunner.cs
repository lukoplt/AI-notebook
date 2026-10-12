using System.Globalization;
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Eval;

public sealed record EvalOptions(string Root, string Mode, string? Model, string Host,
    int TopK, int FetchK, string? JsonPath, string? MarkdownPath, bool ValidateOnly)
{
    public static EvalOptions Parse(IReadOnlyList<string> args)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var flags = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < args.Count; i++)
        {
            var flag = args[i];
            if (flag is not ("--dataset" or "--root" or "--mode" or "--model" or "--host" or
                "--top-k" or "--fetch-k" or "--json" or "--out" or "--validate-only") || !flags.Add(flag))
                throw new EvalFailure("usage");
            if (flag == "--validate-only") continue;
            if (++i == args.Count || string.IsNullOrWhiteSpace(args[i]) || args[i].StartsWith("--", StringComparison.Ordinal))
                throw new EvalFailure("usage");
            values.Add(flag, args[i]);
        }
        if (values.GetValueOrDefault("--dataset") != "multilingual") throw new EvalFailure("usage");
        static int Positive(string value)
        {
            if (value.Length == 0 || value.Any(c => c is < '0' or > '9') ||
                !int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number <= 0)
                throw new EvalFailure("usage");
            return number;
        }
        string host;
        try { host = ProviderApiRoot.Normalize(values.GetValueOrDefault("--host", "http://127.0.0.1:11434")); }
        catch (ProviderConfigurationException) { throw new EvalFailure("usage"); }
        var result = new EvalOptions(values.GetValueOrDefault("--root", "eval/multilingual"),
            values.GetValueOrDefault("--mode", "lexical"), values.GetValueOrDefault("--model"), host,
            Positive(values.GetValueOrDefault("--top-k", "16")), Positive(values.GetValueOrDefault("--fetch-k", "32")),
            values.GetValueOrDefault("--json"), values.GetValueOrDefault("--out"), flags.Contains("--validate-only"));
        result.Validate();
        return result;
    }

    internal void Validate()
    {
        if (Mode is not ("lexical" or "ollama") || TopK <= 0 || FetchK < TopK ||
            Mode == "lexical" && Model is not null || Mode == "ollama" && string.IsNullOrWhiteSpace(Model) ||
            string.IsNullOrWhiteSpace(Root) || JsonPath is not null && string.IsNullOrWhiteSpace(JsonPath) ||
            MarkdownPath is not null && string.IsNullOrWhiteSpace(MarkdownPath))
            throw new EvalFailure("usage");
    }
}

/// <summary>Portable eval orchestration over immutable canonical text and a disposable store.</summary>
public static class EvalRunner
{
    public static (EvalCorpus Corpus, string Hash) Load(string root)
    {
        var fullRoot = Path.GetFullPath(root);
        byte[] Read(string relative)
        {
            if (!EvalCorpus.SafeRelativePath(relative)) throw new EvalFailure("invalid_path");
            try
            {
                // The caller may explicitly select a symlink root; links below it are forbidden.
                var path = fullRoot;
                foreach (var component in relative.Split('/'))
                {
                    path = Path.Combine(path, component);
                    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                        throw new EvalFailure("invalid_path");
                }
                return File.ReadAllBytes(path);
            }
            catch (IOException) { throw new EvalFailure("missing_file"); }
            catch (UnauthorizedAccessException) { throw new EvalFailure("missing_file"); }
        }
        var manifest = Read("manifest.json");
        var queries = Read("queries.json");
        var corpus = EvalCorpus.Load(manifest, queries, Read);
        var hash = EvalCorpus.Sha256(manifest.Concat(new byte[] { 0 }).Concat(queries).ToArray());
        return (corpus, hash);
    }

    public static async Task<EvalReportV1> RunAsync(EvalCorpus corpus, string corpusHash,
        EvalOptions options, IEmbeddingProducing? embedder = null, EvalPackHook? pack = null,
        CancellationToken ct = default)
    {
        options.Validate();
        ct.ThrowIfCancellationRequested();
        var includeVectors = options.Mode == "ollama";
        var client = includeVectors ? embedder ?? throw new EvalFailure("missing_embedder") : new NoEvalEmbedding();
        var model = options.Model ?? "eval-lexical";
        using var store = new NotebookStore(StorePath.InMemory);
        var notebookMap = new Dictionary<long, long>();
        foreach (var id in corpus.Documents.Select(d => d.Metadata.NotebookId).Distinct().Order())
            notebookMap[id] = store.CreateNotebook("eval-" + id.ToString(CultureInfo.InvariantCulture)).Id!.Value;
        var sourceMap = new Dictionary<long, long>();
        var evidenceByChunk = new Dictionary<long, EvalEvidence>();
        foreach (var loaded in corpus.Documents.OrderBy(d => d.Metadata.DocumentId, StringComparer.Ordinal))
        {
            ct.ThrowIfCancellationRequested();
            var d = loaded.Metadata;
            var source = store.CreateSource(notebookMap[d.NotebookId],
                d.Path.EndsWith(".txt", StringComparison.Ordinal) ? SourceType.Text : SourceType.Markdown,
                d.DocumentId, null, null);
            var sourceId = source.Id!.Value;
            sourceMap[d.SourceId] = sourceId;
            var windows = EvalCorpus.Windows(loaded.Text);
            store.ReplaceChunks(sourceId, windows.Select(w =>
                new ChunkDraft(w.Text, Math.Max(1, (w.End - w.Start + 3) / 4))).ToArray());
            var persisted = store.Chunks(sourceId);
            if (persisted.Count != windows.Count) throw new EvalFailure("chunk_mapping");
            for (var i = 0; i < persisted.Count; i++)
            {
                var chunkId = persisted[i].Id!.Value;
                var w = windows[i];
                evidenceByChunk[chunkId] = new EvalEvidence(chunkId,
                    new EvalSpan(d.DocumentId, d.ContentHash, w.Start, w.End), w.Text);
            }
        }

        int? dimensions = null;
        if (includeVectors)
        {
            // Create all chunks before vectors: v19 activates only a complete generation.
            foreach (var batch in evidenceByChunk.Values.OrderBy(e => e.ChunkId).Chunk(16))
            {
                ct.ThrowIfCancellationRequested();
                var vectors = await client.EmbedAsync(model, batch.Select(e => e.Text).ToArray(), ct);
                ct.ThrowIfCancellationRequested();
                if (vectors.Length != batch.Length) throw new EvalFailure("invalid_embedding");
                foreach (var vector in vectors)
                {
                    if (vector.Length == 0 || vector.Any(v => !float.IsFinite(v)) || vector.All(v => v == 0))
                        throw new EvalFailure("invalid_embedding");
                    dimensions ??= vector.Length;
                    if (vector.Length != dimensions) throw new EvalFailure("invalid_embedding");
                }
                for (var i = 0; i < batch.Length; i++)
                    store.StoreEmbedding(batch[i].ChunkId, model, new EmbeddingVector(vectors[i]));
            }
        }

        var retriever = new Retriever(store, client, model);
        var rows = new List<EvalQueryRow>();
        foreach (var q in corpus.Questions)
        {
            ct.ThrowIfCancellationRequested();
            var selected = corpus.SelectedDocuments(q);
            var filesInScope = selected.Count;
            var candidatesWithChunks = selected.Count(d => d.Text.Length > 0);
            if (q.CaseType == "overview")
            {
                rows.Add(new(q.QueryId, q.Text, q.Language, q.CaseType, "deferred_overview_wp8",
                    filesInScope, candidatesWithChunks, [], [], [], EvalMetrics.Names.ToDictionary(
                        name => name, _ => EvalMetric.NotApplicable, StringComparer.Ordinal)));
                continue;
            }
            var ids = selected.Select(d => sourceMap[d.Metadata.SourceId]).ToArray();
            if (ids.Distinct().Count() != selected.Count || !notebookMap.TryGetValue(q.NotebookId, out var notebookId))
                throw new EvalFailure("source_mapping");
            var hits = await retriever.CandidatesAsync(notebookId, q.Text, options.FetchK, ids, includeVectors, ct);
            IReadOnlyList<EvalEvidence> Hydrate(IReadOnlyList<RetrievalHit> list) => list.Select(h =>
            {
                if (!evidenceByChunk.TryGetValue(h.ChunkId, out var evidence) || !ids.Contains(h.SourceId))
                    throw new EvalFailure("evidence_mapping");
                return evidence;
            }).ToArray();
            var lexical = Hydrate(hits.Lexical).Select(e => e.Span).ToArray();
            var vector = Hydrate(hits.Vector).Select(e => e.Span).ToArray();
            var fusedEvidence = Hydrate(hits.Fused);
            var fused = fusedEvidence.Select(e => e.Span).ToArray();
            IReadOnlyList<EvalSpan>? packed = pack is null ? null : ids.Length == 0
                ? [] : await pack(q, fusedEvidence, ct);
            ct.ThrowIfCancellationRequested();
            if (packed is not null)
            {
                var byId = selected.ToDictionary(d => d.Metadata.DocumentId, StringComparer.Ordinal);
                foreach (var span in packed)
                    if (!byId.TryGetValue(span.DocumentId, out var document) ||
                        span.ContentHash != document.Metadata.ContentHash || span.Start < 0 ||
                        span.End <= span.Start || span.End > document.Text.EnumerateRunes().Count())
                        throw new EvalFailure("invalid_packed_span");
            }
            var metrics = EvalMetrics.Measure(corpus.Gold[q.QueryId], lexical, fused,
                options.TopK, includeVectors, packed);
            rows.Add(new(q.QueryId, q.Text, q.Language, q.CaseType, "measured", filesInScope,
                candidatesWithChunks, lexical, vector, fused, metrics));
        }
        return EvalReportV1.Assemble(corpus, corpusHash, "windows", options.Mode, options.Model,
            dimensions, options.TopK, options.FetchK, rows, pack is not null);
    }

    private sealed class NoEvalEmbedding : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
            => throw new EvalFailure("unexpected_embedding");
    }
}
