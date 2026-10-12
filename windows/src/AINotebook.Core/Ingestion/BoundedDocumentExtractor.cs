using System.Text;
using AINotebook.Core.Models;
using UglyToad.PdfPig;

namespace AINotebook.Core.Ingestion;

/// <summary>Local document extraction with admission limits checked before accumulation.</summary>
public sealed class BoundedDocumentExtractor
{
    private readonly ExtractionDiagnostics? _diagnostics;
    public BoundedDocumentExtractor() { }
    internal BoundedDocumentExtractor(ExtractionDiagnostics diagnostics) => _diagnostics = diagnostics;

    /// <summary>Parsing is CPU-bound background work: it runs below normal thread priority (contract
    /// <c>ingestion-memory-pressure-v1</c> addendum A §A.5).</summary>
    public Task<CanonicalDocument> ExtractAsync(Uri url, SourceType kind, FolderRules rules,
        CancellationToken ct = default) => Task.Run(() => BackgroundPriority.Run(() => Extract(url, kind, rules, ct)), ct);

    private CanonicalDocument Extract(Uri url, SourceType kind, FolderRules rules, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!url.IsAbsoluteUri || !url.IsFile)
            throw new FolderIngestionException("outsideRoot");
        rules.Limits.Validate();
        if (rules.EncodingFallback is not ("cp1250" or "none"))
            throw new FolderIngestionException("unsupportedEncoding");
        using var file = new LimitedDocumentStream(url.LocalPath, rules.Limits.FileBytes, ct);
        if (kind is SourceType.Text or SourceType.Markdown)
        {
            var text = TextDecoding.Decode(file, rules.EncodingFallback, rules.Limits.TextScalars, ct);
            return new CanonicalDocument(text.Text, null, kind.RawValue(), Array.Empty<PageBoundary>(),
                Array.Empty<string>(), text.Encoding);
        }
        if (kind == SourceType.Pdf) return ExtractPdf(file, rules.Limits, ct);
        if (kind is SourceType.Docx or SourceType.Pptx or SourceType.Xlsx)
        {
            using var archive = new BoundedOfficeReader(url.LocalPath, rules.Limits, ct, _diagnostics);
            return archive.Read(kind);
        }
        if (kind == SourceType.Email)
        {
            // Bounded by FileBytes (the stream enforces it); the reader debits decoded bytes from OfficeBytes.
            using var buffer = new MemoryStream();
            file.CopyTo(buffer, 65536);
            return MailReader.Read(buffer.ToArray(), Path.GetExtension(url.LocalPath), rules.EncodingFallback, rules.Limits, ct);
        }
        throw new FolderIngestionException("unsupportedSyntax");
    }

    private CanonicalDocument ExtractPdf(Stream stream, IngestionLimits limits, CancellationToken ct)
    {
        try
        {
            using var pdf = PdfDocument.Open(stream);
            if (pdf.NumberOfPages > limits.PdfPages) throw new FolderIngestionException("pageLimit");
            var text = new ScalarTextBuilder(limits.TextScalars);
            var pages = new List<PageBoundary>();
            for (int number = 1; number <= pdf.NumberOfPages; number++)
            {
                ct.ThrowIfCancellationRequested();
                if (number > 1) text.Append("\n\n");
                int start = text.Count;
                _diagnostics?.PageTextReading?.Invoke();
                ct.ThrowIfCancellationRequested();
                // PdfPig materializes one page internally. The output cap cannot bound that
                // library allocation; the queue reserves a separate PDF parser allowance.
                string page = pdf.GetPage(number).Text;
                int lo = 0, hi = page.Length;
                while (lo < hi && Space(page[lo])) lo++;
                while (hi > lo && Space(page[hi - 1])) hi--;
                int count = 0;
                foreach (var _ in page.AsSpan(lo, hi - lo).EnumerateRunes())
                    if (++count > limits.TextScalars - text.Count) throw new FolderIngestionException("textLimit");
                text.Append(page[lo..hi]);
                pages.Add(new PageBoundary(number, start, text.Count));
            }
            ct.ThrowIfCancellationRequested();
            return new CanonicalDocument(text.ToString(), pdf.Information.Title, "pdf", pages, Array.Empty<string>(), null);
        }
        catch (Exception e) when (e is not (FolderIngestionException or OperationCanceledException or OutOfMemoryException))
        {
            throw new FolderIngestionException("corruptArchive");
        }
    }

    private static bool Space(int value) => value is >= 9 and <= 13 or 0x20 or 0x85 or 0xA0 or 0x1680
        or 0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000 or >= 0x2000 and <= 0x200A;
}

/// <summary>Test hooks count accesses after admission and before materialization.</summary>
internal sealed class ExtractionDiagnostics
{
    public Action? PageTextReading { get; init; }
    public Action? CellMaterializing { get; init; }
    public Action<int>? OfficeBytesAccepted { get; init; }
}

/// <summary>Seekable local input, bounded by file extent rather than cumulative rereads.</summary>
internal sealed class LimitedDocumentStream : Stream
{
    private readonly FileStream _file;
    private readonly long _maximum;
    private readonly CancellationToken _ct;
    public LimitedDocumentStream(string path, long maximum, CancellationToken ct)
    {
        _maximum = maximum;
        _ct = ct;
        _file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
        try { Check(); }
        catch { _file.Dispose(); throw; }
    }
    private void Check()
    {
        _ct.ThrowIfCancellationRequested();
        if (_file.Length > _maximum || _file.Position > _maximum) throw new FolderIngestionException("fileLimit");
    }
    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
    public override int Read(Span<byte> buffer)
    {
        Check();
        int count = _file.Read(buffer[..Math.Min(buffer.Length, 65536)]);
        Check();
        return count;
    }
    public override bool CanRead => _file.CanRead;
    public override bool CanSeek => _file.CanSeek;
    public override bool CanWrite => false;
    public override long Length { get { Check(); return _file.Length; } }
    public override long Position { get => _file.Position; set { _file.Position = value; Check(); } }
    public override long Seek(long offset, SeekOrigin origin) { long result = _file.Seek(offset, origin); Check(); return result; }
    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if (disposing) _file.Dispose(); base.Dispose(disposing); }
}
