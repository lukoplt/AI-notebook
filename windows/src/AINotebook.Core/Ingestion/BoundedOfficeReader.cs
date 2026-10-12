using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml;
using AINotebook.Core.Models;

namespace AINotebook.Core.Ingestion;

internal sealed record OfficeRelationship(string Type, string Target);

/// <summary>One expansion budget shared by every opened member, including repeated reads.</summary>
internal sealed class OfficeExpansionBudget(long maximum, Action<int>? accepted = null)
{
    public long AcceptedBytes { get; private set; }

    public static void Preflight(IEnumerable<long> declared, long maximum)
    {
        long total = 0;
        foreach (long length in declared)
        {
            if (length < 0 || length > maximum - total) throw new FolderIngestionException("officeLimit");
            total += length;
        }
    }

    public Stream Wrap(Stream stream, bool leaveOpen = false) => new CountedStream(this, stream, leaveOpen);

    private void Account(int incoming)
    {
        if (incoming < 0 || incoming > maximum - AcceptedBytes) throw new FolderIngestionException("officeLimit");
        AcceptedBytes += incoming;
        if (incoming != 0) accepted?.Invoke(incoming);
    }

    private sealed class CountedStream(OfficeExpansionBudget budget, Stream inner, bool leaveOpen) : Stream
    {
        private readonly byte[] _buffer = new byte[65_536];
        private bool _disposed;
        public override bool CanRead => !_disposed && inner.CanRead;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
        public override int Read(Span<byte> buffer)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (buffer.Length == 0) return 0;
            int count = inner.Read(_buffer, 0, Math.Min(buffer.Length, _buffer.Length));
            // The overflow block remains private: the XML consumer receives none of it.
            budget.Account(count);
            _buffer.AsSpan(0, count).CopyTo(buffer);
            return count;
        }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(Read(buffer.Span));
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        protected override void Dispose(bool disposing)
        {
            if (!_disposed && disposing && !leaveOpen) inner.Dispose();
            _disposed = true;
            base.Dispose(disposing);
        }
    }
}

/// <summary>Local bounded ZIP/XML reader. No relationship is followed outside the package.</summary>
internal sealed class BoundedOfficeReader : IDisposable
{
    private const string PackageRelations = "http://schemas.openxmlformats.org/package/2006/relationships";
    private const string OfficeRelations = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string StrictRelations = "http://purl.oclc.org/ooxml/officeDocument/relationships";
    private const string Compatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006";
    private readonly ZipArchive _archive;
    private readonly Dictionary<string, ZipArchiveEntry> _entries;
    // ASCII-case-folded member name -> the unique actual member name (null when two
    // members fold to the same name). OPC part names are case-insensitive.
    private readonly Dictionary<string, string?> _folded = new(StringComparer.Ordinal);
    private readonly Dictionary<string, IReadOnlyDictionary<string, OfficeRelationship>> _relations = new(StringComparer.Ordinal);
    private readonly OfficeExpansionBudget _budget;
    public IngestionLimits Limits { get; }
    public CancellationToken CancellationToken { get; }
    public ExtractionDiagnostics? Diagnostics { get; }

    public BoundedOfficeReader(string path, IngestionLimits limits, CancellationToken ct = default,
        ExtractionDiagnostics? diagnostics = null)
    {
        limits.Validate();
        ct.ThrowIfCancellationRequested();
        Limits = limits;
        CancellationToken = ct;
        Diagnostics = diagnostics;
        var file = new LimitedDocumentStream(path, limits.FileBytes, ct);
        ZipArchive? archive = null;
        try
        {
            if (file.Length > limits.FileBytes) throw new FolderIngestionException("fileLimit");
            archive = new ZipArchive(file, ZipArchiveMode.Read, leaveOpen: false);
            var entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.Ordinal);
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in archive.Entries)
            {
                ct.ThrowIfCancellationRequested();
                string name = NormalizePartName(entry.FullName);
                if (entry.IsEncrypted || !names.Add(name)) throw new FolderIngestionException("corruptArchive");
                if (!entry.FullName.EndsWith('/')) entries.Add(name, entry);
            }
            OfficeExpansionBudget.Preflight(archive.Entries.Select(entry => entry.Length), limits.OfficeBytes);
            foreach (string name in entries.Keys)
            {
                string folded = AsciiFolded(name);
                _folded[folded] = _folded.ContainsKey(folded) ? null : name;
            }
            _entries = entries;
            _archive = archive;
            _budget = new OfficeExpansionBudget(limits.OfficeBytes, bytes =>
            {
                ct.ThrowIfCancellationRequested();
                diagnostics?.OfficeBytesAccepted?.Invoke(bytes);
                ct.ThrowIfCancellationRequested();
            });
        }
        catch (Exception error)
        {
            archive?.Dispose();
            file.Dispose();
            if (error is InvalidDataException) throw new FolderIngestionException("corruptArchive");
            throw;
        }
    }

    public bool Contains(string part) => _entries.ContainsKey(part);

    /// <summary>The member named <paramref name="part"/>, or the unique member equal to it ignoring ASCII case.</summary>
    public string? ResolvePart(string part) =>
        Contains(part) ? part : _folded.TryGetValue(AsciiFolded(part), out var match) ? match : null;

    private static string AsciiFolded(string value) =>
        string.Create(value.Length, value, (span, source) =>
        {
            for (int i = 0; i < source.Length; i++)
                span[i] = source[i] is >= 'A' and <= 'Z' ? (char)(source[i] + 32) : source[i];
        });

    /// <summary>The package's main part: the single officeDocument relationship target, else the
    /// conventional part when the package relationships are missing, malformed or name no usable
    /// target. Neither -> <c>missingMainPart</c>.</summary>
    public string MainPart(string conventional)
    {
        IReadOnlyDictionary<string, OfficeRelationship> relations;
        try { relations = Relationships(""); }
        catch (FolderIngestionException error) when (error.Code is "invalidRelationship" or "corruptArchive")
        { relations = new Dictionary<string, OfficeRelationship>(); }
        catch (Exception error) when (error is XmlException or InvalidDataException)
        { relations = new Dictionary<string, OfficeRelationship>(); }
        var documents = relations.Values.Where(relation => RelationIs(relation.Type, "officeDocument")).Take(2).ToArray();
        if (documents.Length > 1) throw new FolderIngestionException("invalidRelationship");
        if (documents.Length == 1 && Contains(documents[0].Target)) return documents[0].Target;
        return ResolvePart(conventional) ?? throw new FolderIngestionException("missingMainPart");
    }

    public XmlReader OpenXml(string part)
    {
        CancellationToken.ThrowIfCancellationRequested();
        if (!_entries.TryGetValue(part, out var entry)) throw new FolderIngestionException("invalidRelationship");
        Stream? stream = null;
        try
        {
            stream = _budget.Wrap(entry.Open());
            return XmlReader.Create(stream, new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null,
                MaxCharactersInDocument = Limits.OfficeBytes,
                IgnoreComments = true,
                IgnoreProcessingInstructions = true,
                CloseInput = true
            });
        }
        catch
        {
            stream?.Dispose();
            throw;
        }
    }

    public IReadOnlyDictionary<string, OfficeRelationship> Relationships(string ownerPart)
    {
        if (_relations.TryGetValue(ownerPart, out var cached)) return cached;
        string directory = DirectoryPart(ownerPart);
        string filename = ownerPart[(directory.Length == 0 ? 0 : directory.Length + 1)..];
        string? relationPart = ResolvePart(ownerPart.Length == 0 ? "_rels/.rels" :
            (directory.Length == 0 ? "" : directory + "/") + "_rels/" + filename + ".rels");
        var relations = new Dictionary<string, OfficeRelationship>(StringComparer.Ordinal);
        var rejected = new HashSet<string>(StringComparer.Ordinal);
        if (relationPart is not null)
        {
            using var reader = OpenXml(relationPart);
            if (reader.MoveToContent() != XmlNodeType.Element || reader.LocalName != "Relationships" || reader.NamespaceURI != PackageRelations)
                throw new FolderIngestionException("invalidRelationship");
            int rootDepth = reader.Depth;
            while (reader.Read())
            {
                CancellationToken.ThrowIfCancellationRequested();
                if (reader.NodeType != XmlNodeType.Element || reader.Depth != rootDepth + 1 ||
                    reader.LocalName != "Relationship" || reader.NamespaceURI != PackageRelations) continue;
                string? id = reader.GetAttribute("Id"), type = reader.GetAttribute("Type"), target = reader.GetAttribute("Target");
                string? mode = reader.GetAttribute("TargetMode");
                // External targets (hyperlinks, linked files) are never followed. A duplicate Id or an
                // unusable internal target only invalidates that Id: it fails extraction solely when a
                // required part needs it.
                if (string.IsNullOrEmpty(id) || mode == "External") continue;
                if (rejected.Contains(id) || relations.Remove(id))
                {
                    rejected.Add(id);
                    continue;
                }
                string? resolved = mode is null or "Internal" && !string.IsNullOrEmpty(type) && target is not null
                    ? ResolveTarget(directory, target) : null;
                if (resolved is null) rejected.Add(id);
                else relations.Add(id, new(type!, ResolvePart(resolved) ?? resolved));
            }
        }
        var snapshot = new System.Collections.ObjectModel.ReadOnlyDictionary<string, OfficeRelationship>(relations);
        _relations.Add(ownerPart, snapshot);
        return snapshot;
    }

    /// <summary>Reads only an element subtree and caps decoded scalars before text accumulation.</summary>
    public string ReadText(XmlReader reader, int? maxScalars = null)
    {
        var result = new ScalarTextBuilder(Math.Min(maxScalars ?? Limits.TextScalars, Limits.TextScalars));
        using var subtree = reader.ReadSubtree();
        while (subtree.Read())
        {
            CancellationToken.ThrowIfCancellationRequested();
            if (subtree.NodeType is not (XmlNodeType.Text or XmlNodeType.CDATA or XmlNodeType.Whitespace or XmlNodeType.SignificantWhitespace))
                continue;
            AppendValue(subtree, result);
        }
        return result.ToString();
    }

    /// <summary>Caps the caller's attribute string before accumulation. XmlReader may itself
    /// buffer attribute data; its separate document/stream ceiling remains OfficeBytes.</summary>
    public string? ReadAttribute(XmlReader reader, string name, int? maxScalars = null)
    {
        try
        {
            CancellationToken.ThrowIfCancellationRequested();
            if (!reader.MoveToAttribute(name)) return null;
            var result = new ScalarTextBuilder(Math.Min(maxScalars ?? Limits.TextScalars, Limits.TextScalars));
            AppendValue(reader, result);
            return result.ToString();
        }
        finally { reader.MoveToElement(); }
    }

    private void AppendValue(XmlReader reader, ScalarTextBuilder result)
    {
        char[] buffer = new char[4096];
        char? high = null;
        int read;
        while ((read = reader.ReadValueChunk(buffer, 0, buffer.Length)) != 0)
        {
            CancellationToken.ThrowIfCancellationRequested();
            int offset = 0;
            if (high is char pending)
            {
                if (!char.IsLowSurrogate(buffer[0])) throw new FolderIngestionException("corruptArchive");
                result.Append(new string([pending, buffer[0]]));
                high = null;
                offset = 1;
            }
            int end = read;
            if (end > offset && char.IsHighSurrogate(buffer[end - 1])) high = buffer[--end];
            if (end > offset) result.Append(new string(buffer, offset, end - offset));
        }
        if (high is not null) throw new FolderIngestionException("corruptArchive");
    }

    public CanonicalDocument Read(SourceType kind)
    {
        try
        {
            CancellationToken.ThrowIfCancellationRequested();
            CanonicalDocument document = kind switch
            {
                SourceType.Docx => ReadDocx(),
                SourceType.Pptx => ReadPptx(),
                SourceType.Xlsx => XlsxReader.Read(this),
                _ => throw new FolderIngestionException("unsupportedSyntax")
            };
            return document with { Title = ReadTitle() };
        }
        catch (Exception error) when (error is XmlException or InvalidDataException)
        {
            throw new FolderIngestionException("corruptArchive");
        }
    }

    private CanonicalDocument ReadDocx()
    {
        var result = new ScalarTextBuilder(Limits.TextScalars);
        using var reader = OpenXml(MainPart("word/document.xml"));
        if (reader.MoveToContent() != XmlNodeType.Element || reader.LocalName != "document" || !Word(reader.NamespaceURI))
            throw new FolderIngestionException("corruptArchive");
        ReadParagraphFlow(reader, result, word: true);
        return new(result.ToString(), null, "docx", Array.Empty<PageBoundary>(), Array.Empty<string>(), null);
    }

    private CanonicalDocument ReadPptx()
    {
        string part = MainPart("ppt/presentation.xml");
        var relations = Relationships(part);
        var result = new ScalarTextBuilder(Limits.TextScalars);
        using var reader = OpenXml(part);
        if (reader.MoveToContent() != XmlNodeType.Element || reader.LocalName != "presentation" || !Presentation(reader.NamespaceURI))
            throw new FolderIngestionException("corruptArchive");
        int rootDepth = reader.Depth, listDepth = -1, slide = 0;
        while (reader.Read())
        {
            CancellationToken.ThrowIfCancellationRequested();
            if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "sldIdLst" && Presentation(reader.NamespaceURI) && reader.Depth == rootDepth + 1)
                listDepth = reader.IsEmptyElement ? -1 : reader.Depth;
            else if (reader.NodeType == XmlNodeType.EndElement && reader.Depth == listDepth)
                listDepth = -1;
            else if (listDepth >= 0 && reader.NodeType == XmlNodeType.Element && reader.Depth == listDepth + 1 &&
                reader.LocalName == "sldId" && Presentation(reader.NamespaceURI))
            {
                string? id = reader.GetAttribute("id", OfficeRelations) ?? reader.GetAttribute("id", StrictRelations);
                if (id is null || !relations.TryGetValue(id, out var relation) || !RelationIs(relation.Type, "slide") || !Contains(relation.Target))
                    throw new FolderIngestionException("invalidRelationship");
                if (slide > 0) result.Append("\n\n");
                result.Append("## Slide " + (++slide).ToString(CultureInfo.InvariantCulture) + "\n");
                AppendSlide(relation.Target, result);
            }
        }
        return new(result.ToString(), null, "pptx", Array.Empty<PageBoundary>(), Array.Empty<string>(), null);
    }

    private void AppendSlide(string part, ScalarTextBuilder result)
    {
        using var reader = OpenXml(part);
        if (reader.MoveToContent() != XmlNodeType.Element || reader.LocalName != "sld" || !Presentation(reader.NamespaceURI))
            throw new FolderIngestionException("corruptArchive");
        ReadParagraphFlow(reader, result, word: false);
    }

    /// <summary>
    /// Paragraph text in document order, shared by Word bodies and slides (same rules as the
    /// macOS OfficeParagraphFlow): every paragraph start after the first begins a new line,
    /// including paragraphs nested in text boxes; text that continues an outer paragraph after a
    /// nested one starts a new line too. Only text/tab/break elements that are direct children of a
    /// run (Word: w:r; slides: a:r/a:fld; slide breaks: a:p) count, so tab-stop definitions in
    /// paragraph properties are not text. mc:Fallback duplicates its mc:Choice and is skipped.
    /// The reader is positioned on the root element.
    /// </summary>
    private void ReadParagraphFlow(XmlReader reader, ScalarTextBuilder result, bool word)
    {
        if (reader.IsEmptyElement) return;
        Func<string, bool> own = word ? Word : Drawing;
        int rootDepth = reader.Depth;
        // Own-namespace local name per open element depth ("" for foreign elements); "t*" marks a text target.
        var path = new List<string> { "" };
        var paragraphs = new Stack<int>();
        int skipBelow = int.MaxValue, bodyDepth = word ? -1 : rootDepth, count = 0;
        bool pending = false;
        void Emit(string text)
        {
            if (pending) { result.Append("\n"); pending = false; }
            result.Append(text);
        }
        while (reader.Read())
        {
            CancellationToken.ThrowIfCancellationRequested();
            int depth = reader.Depth - rootDepth;
            if (depth <= 0) break; // the root closed: trailing misc nodes are not content
            if (depth > skipBelow) continue;
            skipBelow = int.MaxValue;
            switch (reader.NodeType)
            {
                case XmlNodeType.Element:
                {
                    string name = own(reader.NamespaceURI) ? reader.LocalName : "";
                    string parent = path[depth - 1];
                    path.RemoveRange(depth, path.Count - depth);
                    path.Add(name);
                    bool empty = reader.IsEmptyElement;
                    if (word && depth == 1 && name == "body") { bodyDepth = empty ? -1 : depth; break; }
                    if (bodyDepth < 0) break;
                    if (reader.LocalName == "Fallback" && reader.NamespaceURI == Compatibility)
                    {
                        if (!empty) skipBelow = depth;
                        break;
                    }
                    if (name == "p")
                    {
                        if (count++ > 0) result.Append("\n");
                        pending = false;
                        if (empty) pending = true; else paragraphs.Push(depth);
                    }
                    else if (name == "t" && (parent == "r" || !word && parent == "fld") && !empty) path[depth] = "t*";
                    else if (name == "tab" && word && parent == "r") Emit("\t");
                    else if (name == "br" && (word ? parent == "r" : parent == "p")) Emit("\n");
                    break;
                }
                case XmlNodeType.EndElement:
                    if (paragraphs.Count > 0 && paragraphs.Peek() == depth) { paragraphs.Pop(); pending = true; }
                    if (word && depth == bodyDepth) bodyDepth = -1;
                    break;
                case XmlNodeType.Text or XmlNodeType.CDATA or XmlNodeType.Whitespace or XmlNodeType.SignificantWhitespace:
                    if (bodyDepth >= 0 && path[depth - 1] == "t*")
                    {
                        if (pending) { result.Append("\n"); pending = false; }
                        AppendValue(reader, result);
                    }
                    break;
            }
        }
    }

    /// <summary>Best effort: a missing, ambiguous or unreadable core-properties part leaves the
    /// title empty instead of failing the whole document (same as macOS).</summary>
    private string? ReadTitle()
    {
        try
        {
            IReadOnlyDictionary<string, OfficeRelationship> root;
            try { root = Relationships(""); }
            catch (FolderIngestionException error) when (error.Code is "invalidRelationship" or "corruptArchive")
            { root = new Dictionary<string, OfficeRelationship>(); }
            var properties = root.Values.Where(relation =>
                relation.Type == "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties").Take(2).ToArray();
            if (properties.Length > 1) return null;
            string? part = properties.Length == 1 && Contains(properties[0].Target) ? properties[0].Target : ResolvePart("docProps/core.xml");
            if (part is null) return null;
            using var reader = OpenXml(part);
            var title = new ScalarTextBuilder(Limits.TextScalars);
            while (reader.Read())
            {
                CancellationToken.ThrowIfCancellationRequested();
                if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "title" && reader.NamespaceURI == "http://purl.org/dc/elements/1.1/")
                    title.Append(ReadText(reader));
            }
            string text = title.ToString();
            return text.EnumerateRunes().Any(rune => !Space(rune.Value)) ? text : null;
        }
        catch (FolderIngestionException error) when (error.Code is "invalidRelationship" or "corruptArchive") { return null; }
        catch (Exception error) when (error is XmlException or InvalidDataException) { return null; }
    }

    private static bool Space(int value) => value is >= 9 and <= 13 or 0x20 or 0x85 or 0xA0 or 0x1680
        or 0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000 or >= 0x2000 and <= 0x200A;
    private static bool RelationIs(string type, string kind) => type == OfficeRelations + "/" + kind || type == StrictRelations + "/" + kind;
    private static bool Word(string ns) => ns is "http://schemas.openxmlformats.org/wordprocessingml/2006/main" or "http://purl.oclc.org/ooxml/wordprocessingml/main";
    private static bool Presentation(string ns) => ns is "http://schemas.openxmlformats.org/presentationml/2006/main" or "http://purl.oclc.org/ooxml/presentationml/main";
    private static bool Drawing(string ns) => ns is "http://schemas.openxmlformats.org/drawingml/2006/main" or "http://purl.oclc.org/ooxml/drawingml/main";
    private static string DirectoryPart(string part) => part.LastIndexOf('/') is int slash && slash >= 0 ? part[..slash] : "";

    private static string NormalizePartName(string name)
    {
        if (string.IsNullOrEmpty(name) || name[0] == '/' || name.Contains('\\') || name.Contains(':') || name.Any(char.IsControl))
            throw new FolderIngestionException("corruptArchive");
        var components = new List<string>();
        foreach (string component in name.Split('/'))
        {
            if (component == "..") throw new FolderIngestionException("corruptArchive");
            if (component.Length > 0 && component != ".") components.Add(component);
        }
        if (components.Count == 0) throw new FolderIngestionException("corruptArchive");
        return string.Join('/', components);
    }

    /// <summary>Resolves an internal relationship target against its source directory. A leading
    /// "/" is package-absolute. Null for targets that are not a plain in-package part name
    /// (traversal above the root, control characters, backslash, ':', '?', '#', bad
    /// percent-encoding or non-UTF-8 escapes) — identical to the macOS reader.</summary>
    internal static string? ResolveTarget(string directory, string target)
    {
        string? value = PercentDecode(target);
        if (string.IsNullOrEmpty(value)) return null;
        bool absolute = value[0] == '/';
        if (absolute) value = value[1..];
        if (value.Length == 0 || value[0] == '/' || value.Contains('\\') || value.Contains(':') || value.Contains('?') ||
            value.Contains('#') || value.Any(c => c < ' ')) return null;
        var components = absolute || directory.Length == 0 ? new List<string>() : directory.Split('/').ToList();
        foreach (string component in value.Split('/'))
        {
            if (component == "..")
            {
                if (components.Count == 0) return null;
                components.RemoveAt(components.Count - 1);
            }
            else if (component.Length > 0 && component != ".") components.Add(component);
        }
        return components.Count == 0 ? null : string.Join('/', components);
    }

    /// <summary>Strict RFC 3986 percent-decoding to UTF-8 (Foundation's removingPercentEncoding).</summary>
    private static string? PercentDecode(string value)
    {
        if (!value.Contains('%')) return value;
        var bytes = new List<byte>(value.Length);
        for (int i = 0; i < value.Length;)
        {
            if (value[i] != '%')
            {
                int next = value.IndexOf('%', i);
                if (next < 0) next = value.Length;
                bytes.AddRange(Encoding.UTF8.GetBytes(value[i..next]));
                i = next;
                continue;
            }
            if (i + 2 >= value.Length || !Uri.IsHexDigit(value[i + 1]) || !Uri.IsHexDigit(value[i + 2])) return null;
            bytes.Add((byte)Convert.ToInt32(value.Substring(i + 1, 2), 16));
            i += 3;
        }
        try { return new UTF8Encoding(false, true).GetString(bytes.ToArray()); }
        catch (DecoderFallbackException) { return null; }
    }

    public void Dispose() => _archive.Dispose();
}
