namespace AINotebook.Core.Extractors;

/// <summary>
/// Port of Sources/AINotebookCore/TextExtractor.swift ExtractorError. Each case
/// is a subclass carrying the associated data so tests assert on type + data.
/// </summary>
public abstract class ExtractorException : Exception
{
    protected ExtractorException(string message) : base(message) { }

    public sealed class FileNotReadable : ExtractorException
    {
        public Uri Url { get; }
        public FileNotReadable(Uri url) : base($"File not readable: {url}") => Url = url;
    }

    public sealed class UnsupportedEncoding : ExtractorException
    {
        public Uri Url { get; }
        public UnsupportedEncoding(Uri url) : base($"Unsupported encoding (UTF-8 only): {url}") => Url = url;
    }

    public sealed class EmptyContent : ExtractorException
    {
        public EmptyContent() : base("Extracted content is empty") { }
    }

    public sealed class PdfOpenFailed : ExtractorException
    {
        public Uri Url { get; }
        public PdfOpenFailed(Uri url) : base($"Failed to open PDF: {url}") => Url = url;
    }

    public sealed class OfficeArchiveCorrupt : ExtractorException
    {
        public Uri Url { get; }
        public OfficeArchiveCorrupt(Uri url) : base($"Office archive corrupt: {url}") => Url = url;
    }

    public sealed class WebFetchFailed : ExtractorException
    {
        public Uri Url { get; }
        public int Status { get; }
        public WebFetchFailed(Uri url, int status)
            : base($"Web fetch failed ({status}): {url}")
        {
            Url = url;
            Status = status;
        }
    }

    public sealed class WebResponseNotHtml : ExtractorException
    {
        public Uri Url { get; }
        public string? Mime { get; }
        public WebResponseNotHtml(Uri url, string? mime)
            : base($"Web response not HTML (mime={mime ?? "<none>"}): {url}")
        {
            Url = url;
            Mime = mime;
        }
    }
}
