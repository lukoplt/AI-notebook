using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Orchestrates: type-detect -> text-extract -> chunk -> persist, updating the
/// source's status row at every stage. 1:1 port of Sources/AINotebookCore/IngestionService.swift.
/// Embedding is NOT enqueued inline: after ReplaceChunks + status Ready, the
/// onChunksWritten callback fires; a separate Embedder/EmbeddingWorker drains
/// the unembedded-chunks queue.
/// </summary>
public sealed class IngestionService
{
    private const char FormFeed = '\u000C';

    private readonly NotebookStore _store;
    private readonly ITextExtractor _plain;
    private readonly ITextExtractor _pdf;
    private readonly ITextExtractor _web;
    private readonly ITextExtractor _office;
    private readonly Func<Task>? _onChunksWritten;

    public IngestionService(
        NotebookStore store,
        ITextExtractor? plain = null,
        ITextExtractor? pdf = null,
        ITextExtractor? web = null,
        ITextExtractor? office = null,
        Func<Task>? onChunksWritten = null)
    {
        _store = store;
        _plain = plain ?? new PlainTextExtractor();
        _pdf = pdf ?? new PdfTextExtractor();
        _web = web ?? new WebTextExtractor();
        _office = office ?? new OfficeTextExtractor();
        _onChunksWritten = onChunksWritten;
    }

    public async Task<Source> IngestFileAsync(Uri url, long notebookId)
    {
        string filename = Path.GetFileName(url.LocalPath);
        SourceType? kind = SourceTypeExtensions.Detect(filename);
        if (kind == null)
        {
            // Throw BEFORE creating any source row.
            throw new IngestionException.UnsupportedExtension(
                Path.GetExtension(url.LocalPath).TrimStart('.'));
        }

        string title = Path.GetFileNameWithoutExtension(url.LocalPath);
        var source = _store.CreateSource(notebookId, kind.Value, title, uri: null, rawPath: url.LocalPath);

        return await RunPipelineAsync(source, async () =>
        {
            switch (kind.Value)
            {
                case SourceType.Pdf:
                {
                    var extracted = await _pdf.ExtractAsync(url, kind.Value);
                    List<(string text, int pageHint)> pages;
                    if (extracted.PageHints != null)
                    {
                        // Split on form feed, keeping empty segments, then zip with hints (shorter wins).
                        var split = extracted.Text.Split(FormFeed);
                        var hints = extracted.PageHints;
                        int n = Math.Min(split.Length, hints.Length);
                        pages = new List<(string, int)>(n);
                        for (int i = 0; i < n; i++)
                        {
                            pages.Add((split[i], hints[i]));
                        }
                    }
                    else
                    {
                        pages = new List<(string, int)> { (extracted.Text, 0) };
                    }
                    return (extracted, Chunker.ChunkPaged(pages));
                }
                case SourceType.Text:
                case SourceType.Markdown:
                {
                    var e = await _plain.ExtractAsync(url, kind.Value);
                    return (e, Chunker.Chunk(e.Text));
                }
                case SourceType.Docx:
                case SourceType.Pptx:
                case SourceType.Xlsx:
                {
                    var e = await _office.ExtractAsync(url, kind.Value);
                    return (e, Chunker.Chunk(e.Text));
                }
                case SourceType.Web:
                {
                    var e = await _web.ExtractAsync(url, kind.Value);
                    return (e, Chunker.Chunk(e.Text));
                }
                default: // Note: managed via Notebook notes, not file ingestion.
                    throw new IngestionException.UnsupportedExtension(
                        Path.GetExtension(url.LocalPath).TrimStart('.'));
            }
        });
    }

    public async Task<Source> IngestRawTextAsync(string title, string text, long notebookId)
    {
        var source = _store.CreateSource(notebookId, SourceType.Text, title, uri: null, rawPath: null);
        return await RunPipelineAsync(source, () =>
        {
            var e = new ExtractedText(title, text);
            return Task.FromResult((e, Chunker.Chunk(text)));
        });
    }

    /// <summary>Re-ingests an existing source from its stored raw path (for folder watch / URL refresh).</summary>
    public async Task<Source> ReIngestAsync(long sourceId, CancellationToken ct = default)
    {
        var source = _store.Source(sourceId)
            ?? throw new IngestionException.UnsupportedExtension("(unknown — source not found)");
        var url = source.RawPath is not null
            ? new Uri(source.RawPath)
            : source.Uri is not null ? new Uri(source.Uri) : null;
        if (url is null) throw new InvalidOperationException($"Source {sourceId} has no URI or path to re-ingest.");

        return await RunPipelineAsync(source, async () =>
        {
            switch (source.Type)
            {
                case SourceType.Pdf:
                {
                    var extracted = await _pdf.ExtractAsync(url, source.Type);
                    List<(string text, int pageHint)> pages;
                    if (extracted.PageHints != null)
                    {
                        var split = extracted.Text.Split(FormFeed);
                        var hints = extracted.PageHints;
                        int n = Math.Min(split.Length, hints.Length);
                        pages = new List<(string, int)>(n);
                        for (int i = 0; i < n; i++) pages.Add((split[i], hints[i]));
                    }
                    else
                    {
                        pages = new List<(string, int)> { (extracted.Text, 0) };
                    }
                    return (extracted, Chunker.ChunkPaged(pages));
                }
                case SourceType.Web:
                {
                    var e = await _web.ExtractAsync(url, source.Type);
                    return (e, Chunker.Chunk(e.Text));
                }
                default:
                {
                    var e = source.Type is SourceType.Docx or SourceType.Pptx or SourceType.Xlsx
                        ? await _office.ExtractAsync(url, source.Type)
                        : await _plain.ExtractAsync(url, source.Type);
                    return (e, Chunker.Chunk(e.Text));
                }
            }
        });
    }

    public async Task<Source> IngestUrlAsync(Uri url, long notebookId)
    {
        string title = url.Host.Length != 0 ? url.Host : url.AbsoluteUri;
        var source = _store.CreateSource(notebookId, SourceType.Web, title, uri: url.AbsoluteUri, rawPath: null);
        return await RunPipelineAsync(source, async () =>
        {
            var e = await _web.ExtractAsync(url, SourceType.Web);
            return (e, Chunker.Chunk(e.Text));
        });
    }

    private async Task<Source> RunPipelineAsync(
        Source sourceIn,
        Func<Task<(ExtractedText, List<ChunkDraft>)>> extract)
    {
        var source = sourceIn;
        try
        {
            _store.UpdateSourceStatus(source.Id!.Value, SourceStatus.Chunking, error: null);
            var (_, chunks) = await extract();
            _store.ReplaceChunks(source.Id!.Value, chunks);
            _store.UpdateSourceStatus(source.Id!.Value, SourceStatus.Ready, error: null);
            if (_onChunksWritten != null)
            {
                await _onChunksWritten();
            }
            return source with { Status = SourceStatus.Ready };
        }
        catch (Exception ex)
        {
            string message = ex.ToString();
            try
            {
                _store.UpdateSourceStatus(source.Id!.Value, SourceStatus.Error, error: message);
            }
            catch
            {
                // best-effort: mirror Swift `try?`
            }
            throw;
        }
    }
}
