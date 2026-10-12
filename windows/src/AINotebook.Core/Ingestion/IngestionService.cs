using System.Security.Cryptography;
using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Dapper;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Extracts and publishes complete revisions under a renewable worker lease. Loose PDF/Office/text files go through
/// the bounded canonical extractor and scalar chunker v2 with fenced metadata (unless a legacy extractor double is
/// injected for that kind). Web and raw text publish the canonical extractor output unchanged. Folder sources are
/// never opened here: re-ingesting one queues durable extraction for the folder runtime.
/// </summary>
public sealed class IngestionService
{
    private readonly NotebookStore _store;
    private readonly ITextExtractor? _plain;
    private readonly ITextExtractor? _pdf;
    private readonly ITextExtractor _web;
    private readonly ITextExtractor? _office;
    private readonly Func<Task>? _onChunksWritten;
    private readonly IIngestLeaseClock _leaseClock;
    private readonly BoundedDocumentExtractor _bounded = new();
    private readonly LanguageDetector _detector;
    private readonly Func<long, Task<EmbeddingSelection?>>? _embeddingSelection;

    public IngestionService(NotebookStore store, ITextExtractor? plain = null, ITextExtractor? pdf = null,
        ITextExtractor? web = null, ITextExtractor? office = null, Func<Task>? onChunksWritten = null,
        IIngestLeaseClock? leaseClock = null, LanguageDetector? detector = null,
        Func<long, Task<EmbeddingSelection?>>? embeddingSelection = null)
    {
        _store = store;
        _plain = plain;
        _pdf = pdf;
        _web = web ?? new WebTextExtractor();
        _office = office;
        _onChunksWritten = onChunksWritten;
        _leaseClock = leaseClock ?? new SystemIngestLeaseClock();
        _detector = detector ?? LoadDetector();
        _embeddingSelection = embeddingSelection;
    }

    public async Task<Source> IngestFileAsync(Uri url, long notebookId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        string filename = Path.GetFileName(url.LocalPath);
        SourceType kind = SourceTypeExtensions.Detect(filename)
            ?? throw new IngestionException.UnsupportedExtension(Path.GetExtension(url.LocalPath).TrimStart('.'));
        var source = _store.CreateSource(notebookId, kind, Path.GetFileNameWithoutExtension(url.LocalPath),
            uri: null, rawPath: url.LocalPath);
        return await RunPipelineAsync(source, token => PrepareFileAsync(url, kind, token), ct).ConfigureAwait(false);
    }

    public async Task<Source> IngestRawTextAsync(string title, string text, long notebookId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var source = _store.CreateSource(notebookId, SourceType.Text, title, uri: null, rawPath: null);
        return await RunPipelineAsync(source, _ => Task.FromResult(Legacy(new ExtractedText(title, text), SourceType.Text)), ct)
            .ConfigureAwait(false);
    }

    /// <summary>Re-extracts the source without changing its published revision until completion.</summary>
    public async Task<Source> ReIngestAsync(long sourceId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var source = _store.Source(sourceId)
            ?? throw new IngestionException.UnsupportedExtension("(unknown — source not found)");
        if (source.FolderId is not null)
        {
            // A folder source refreshes through durable, fenced folder extraction, never by reopening its path here.
            _store.RequestFolderExtraction(sourceId, _leaseClock.Now);
            return _store.Source(sourceId) ?? source;
        }
        if (source.RawPath is not null)
        {
            var file = new Uri(source.RawPath);
            return await RunPipelineAsync(source, token => PrepareFileAsync(file, source.Type, token), ct).ConfigureAwait(false);
        }
        if (source.Uri is null) throw new InvalidOperationException($"Source {sourceId} has no URI or path to re-ingest.");
        var url = new Uri(source.Uri);
        return await RunPipelineAsync(source, async _ => Legacy(await _web.ExtractAsync(url, source.Type).ConfigureAwait(false), source.Type), ct)
            .ConfigureAwait(false);
    }

    public async Task<Source> IngestUrlAsync(Uri url, long notebookId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        string title = url.Host.Length != 0 ? url.Host : url.AbsoluteUri;
        var source = _store.CreateSource(notebookId, SourceType.Web, title, uri: url.AbsoluteUri, rawPath: null);
        return await RunPipelineAsync(source, async _ => Legacy(await _web.ExtractAsync(url, SourceType.Web).ConfigureAwait(false), SourceType.Web), ct)
            .ConfigureAwait(false);
    }

    private sealed record Prepared(RevisionDraft Draft, IReadOnlyList<RevisionChunkDraft> Chunks, PublicationMetadata? Metadata);

    private async Task<Prepared> PrepareFileAsync(Uri url, SourceType kind, CancellationToken ct)
    {
        // An injected extractor for this kind is an explicit legacy double; production uses the bounded path.
        ITextExtractor? legacy = kind switch
        {
            SourceType.Pdf => _pdf,
            SourceType.Web => _web,
            SourceType.Docx or SourceType.Pptx or SourceType.Xlsx => _office,
            SourceType.Email => null,
            _ => _plain
        };
        if (legacy is not null) return Legacy(await legacy.ExtractAsync(url, kind).ConfigureAwait(false), kind);
        var rules = FolderRules.Defaults;
        var document = await _bounded.ExtractAsync(url, kind, rules, ct).ConfigureAwait(false);
        string hash;
        long size;
        await using (var file = new FileStream(url.LocalPath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true))
        {
            size = file.Length;
            hash = Convert.ToHexString(await SHA256.HashDataAsync(file, ct).ConfigureAwait(false)).ToLowerInvariant();
        }
        var draft = FolderExtractionWorker.Prepare(document, hash, size, Path.GetFileName(url.LocalPath), _detector, rules.Limits);
        return new Prepared(draft.Revision, draft.Chunks, draft.Metadata);
    }

    private static Prepared Legacy(ExtractedText extracted, SourceType type)
    {
        var (draft, chunks) = PrepareRevision(extracted, type);
        return new Prepared(draft, chunks, null);
    }

    private async Task<Source> RunPipelineAsync(Source source, Func<CancellationToken, Task<Prepared>> prepare, CancellationToken ct)
    {
        long sourceId = source.Id!.Value;
        var fence = _store.BeginExtraction(sourceId, _leaseClock.Now, Guid.NewGuid().ToString("N"));
        await using var renewal = new ExtractionLeaseRenewal(_store, fence, _leaseClock, ct);
        bool published;
        try
        {
            ct.ThrowIfCancellationRequested();
            // Legacy extractors lack a cancellation argument. Stop waiting and fence their
            // eventual result out when the caller cancels.
            var prepared = await prepare(ct).WaitAsync(ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var selection = prepared.Metadata is not null && _embeddingSelection is not null
                ? await FolderExtractionWorker.PublishableSelectionAsync(source.NotebookId, _embeddingSelection, ct).ConfigureAwait(false)
                : null;
            await renewal.StopAsync().ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (prepared.Metadata is not null)
            {
                published = _store.PublishLooseExtraction(sourceId, prepared.Draft, prepared.Chunks, prepared.Metadata, selection,
                    fence, _leaseClock.Now) is not null;
            }
            else
            {
                lock (_store.Gate)
                {
                    using var tx = _store.Connection.BeginTransaction(deferred: false);
                    long now = _leaseClock.Now;
                    var revision = RevisionJobSQL.CommitExtraction(_store.Connection, tx, sourceId, prepared.Draft, prepared.Chunks, fence, now);
                    published = revision is not null;
                    if (published)
                        _store.Connection.Execute("UPDATE sources SET last_synced_at=$at WHERE id=$sourceId",
                            new { sourceId, at = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime) }, tx);
                    tx.Commit();
                }
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            _store.CancelIngestJob(fence.JobId, fence, _leaseClock.Now);
            throw;
        }
        catch (Exception error)
        {
            _store.FailJob(fence, error is FolderIngestionException ingestion ? ingestion.Code : error.ToString(), _leaseClock.Now);
            throw;
        }

        if (published && _onChunksWritten is not null) await _onChunksWritten().ConfigureAwait(false);
        return _store.Source(sourceId) ?? throw new StoreException.SourceNotFound(sourceId);
    }

    private static LanguageDetector LoadDetector()
    {
        try { return LanguageDetector.LoadBundled(); }
        catch (Exception) { return LanguageDetector.Unavailable; }
    }

    internal static (RevisionDraft Draft, IReadOnlyList<RevisionChunkDraft> Chunks) PrepareRevision(ExtractedText extracted, SourceType type)
    {
        string canonical = extracted.Text;
        if (type is SourceType.Docx or SourceType.Pptx or SourceType.Xlsx)
        {
            var legacy = Chunker.Chunk(canonical).Select(chunk => new RevisionChunkDraft(chunk.Text,
                chunk.TokenCount, chunk.PageHint, null, null, null, false)).ToArray();
            return (new(ContentHash(canonical), canonical, 1, 1), legacy);
        }

        List<(int Offset, int Page)>? pageStarts = null;
        if (type == SourceType.Pdf)
        {
            string[] pages = canonical.Split('\f');
            pageStarts = new(pages.Length);
            int offset = 0;
            for (int i = 0; i < pages.Length; i++)
            {
                int page = extracted.PageHints is { } hints && i < hints.Length ? hints[i] : i + 1;
                pageStarts.Add((offset, page));
                offset += pages[i].EnumerateRunes().Count() + 2;
            }
            canonical = string.Join("\n\n", pages);
        }
        return (new(ContentHash(canonical), canonical, 1, 2), ScalarChunker.Chunk(canonical, pageStarts));
    }

    internal static string ContentHash(string text)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
}

/// <summary>One extraction's renewal loop; its lifetime never holds a database lock across an await.</summary>
internal sealed class ExtractionLeaseRenewal : IAsyncDisposable
{
    private readonly CancellationTokenSource _stop;
    private readonly Task _task;

    internal ExtractionLeaseRenewal(NotebookStore store, JobFence fence, IIngestLeaseClock clock, CancellationToken ct)
    {
        _stop = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _task = RenewAsync(store, fence, clock);
    }

    private async Task RenewAsync(NotebookStore store, JobFence fence, IIngestLeaseClock clock)
    {
        while (true)
        {
            await clock.WaitUntilAsync(checked(clock.Now + 60), _stop.Token).ConfigureAwait(false);
            _stop.Token.ThrowIfCancellationRequested();
            if (!store.RenewJob(fence, clock.Now)) return;
        }
    }

    internal async Task StopAsync()
    {
        _stop.Cancel();
        try { await _task.ConfigureAwait(false); }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
    }

    public async ValueTask DisposeAsync()
    {
        try { await StopAsync().ConfigureAwait(false); }
        finally { _stop.Dispose(); }
    }
}
