using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Xml;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class BoundedDocumentExtractorTests
{
    [Fact]
    public async Task WorkbookRelationshipOrderAndValues()
    {
        var row = Cases().Single(c => c.GetProperty("name").GetString() == "workbook-order");
        var result = await new BoundedDocumentExtractor().ExtractAsync(
            new Uri(SharedFixtures.Path(row.GetProperty("input").GetProperty("asset").GetString()!)),
            SourceType.Xlsx, FolderRules.Defaults);
        Assert.Equal(row.GetProperty("expected").GetProperty("text").GetString(), result.Text);
        Assert.Equal(new[] { "Zeta", "Alpha" }, result.SheetNames);
    }

    [Fact]
    public async Task PageLimitBeforeTextRead()
    {
        int calls = 0;
        var reader = new BoundedDocumentExtractor(new ExtractionDiagnostics { PageTextReading = () => calls++ });
        var rules = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { PdfPages = 1 } };
        await Error("pageLimit", () => reader.ExtractAsync(new Uri(SharedFixtures.Path("ingestion/pages.pdf")), SourceType.Pdf, rules));
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task AllOfficeCases()
    {
        var rows = Cases();
        var visited = new HashSet<string>();
        foreach (var row in rows)
        {
            Assert.True(visited.Add(row.GetProperty("name").GetString()!));
            switch (row.GetProperty("operation").GetString())
            {
                case "bounded-stream": RunStreamCase(row); break;
                case "extract": await RunExtractCase(row); break;
                default: Assert.Fail("Unknown office operation: " + row.GetProperty("operation").GetString()); break;
            }
        }
        Assert.Equal(rows.Length, visited.Count);
        Assert.Equal(29, visited.Count);
    }

    /// <summary>Compact spreadsheet canonical text v2 (ingestion-xlsx-v2), shared with macOS.</summary>
    [Fact]
    public async Task SpreadsheetTextV2Cases()
    {
        var rows = SharedFixtures.Json("contracts/ingestion-xlsx-v2.json").GetProperty("cases").EnumerateArray()
            .Where(r => r.GetProperty("operation").GetString() == "extract").ToArray();
        Assert.True(rows.Length >= 25);
        foreach (var row in rows) await RunExtractCase(row);
    }

    /// <summary>Real-world OPC packaging (absolute/relative/encoded/case-folded targets, external
    /// relationships, main-part fallback, text boxes) — shared with macOS.</summary>
    [Fact]
    public async Task AllOoxmlPackagingCases()
    {
        var all = SharedFixtures.Json("contracts/ingestion-ooxml-v1.json").GetProperty("cases").EnumerateArray()
            .Select(row => SpreadsheetSupersession.Apply(row, "ingestion-ooxml-v1.json")).ToArray();
        Assert.Equal(all.Length, all.Select(r => r.GetProperty("name").GetString()).Distinct().Count());
        var rows = all.Where(r => r.GetProperty("operation").GetString() == "extract").ToArray();
        Assert.Equal(20, rows.Length);
        foreach (var row in rows) await RunExtractCase(row);
    }

    /// <summary>Persisted error code -> localized explanation key (shared with macOS; the copy itself
    /// is checked against resw by tools/ui/check_strings_parity.py).</summary>
    [Fact]
    public void OoxmlErrorTexts()
    {
        var rows = SharedFixtures.Json("contracts/ingestion-ooxml-v1.json").GetProperty("cases").EnumerateArray()
            .Where(r => r.GetProperty("operation").GetString() == "error-text").ToArray();
        Assert.Equal(18, rows.Length);
        foreach (var row in rows)
        {
            string code = row.GetProperty("input").GetProperty("code").GetString()!;
            var key = row.GetProperty("expected").GetProperty("key");
            Assert.True((key.ValueKind == JsonValueKind.Null ? null : key.GetString()) == IngestionErrorText.KeyName(code), code);
        }
        Assert.Null(IngestionErrorText.KeyName(null));
    }

    /// <summary>Same ZIP layouts as the macOS test (descriptor with/without signature, descriptor flag
    /// only in the local header, trailing bytes after the end record) must not be corrupt.</summary>
    [Fact]
    public async Task RealWorldZipLayoutsAreNotCorrupt()
    {
        const string rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>";
        const string xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>A</w:t></w:r></w:p></w:body></w:document>";
        var parts = new[] { ("_rels/.rels", Encoding.UTF8.GetBytes(rels)), ("word/document.xml", Encoding.UTF8.GetBytes(xml)) };
        foreach (var (descriptor, version, signature, centralFlag, trailing) in new[]
        {
            (4, 20, true, true, 0), (8, 45, true, true, 0), (4, 20, false, true, 0), (4, 20, true, false, 0), (0, 20, true, true, 7)
        })
        {
            using var file = new TempFile(".docx", ZipLayout(parts, descriptor, version, signature, centralFlag, trailing));
            var result = await new BoundedDocumentExtractor().ExtractAsync(new Uri(file.Path), SourceType.Docx, FolderRules.Defaults);
            Assert.Equal("A", result.Text);
        }
    }

    private static uint Crc32(byte[] data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (byte b in data)
        {
            crc ^= b;
            for (int k = 0; k < 8; k++) crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
        }
        return ~crc;
    }

    private static byte[] ZipLayout((string Name, byte[] Body)[] parts, int descriptor, int version, bool signature,
        bool centralFlag, int trailing)
    {
        var output = new MemoryStream();
        var central = new MemoryStream();
        static void Le(Stream stream, ulong value, int width)
        {
            for (int i = 0; i < width; i++) stream.WriteByte((byte)(value >> (8 * i)));
        }
        foreach (var (name, body) in parts)
        {
            ulong crc = Crc32(body);
            ulong offset = (ulong)output.Length, size = (ulong)body.Length, flags = descriptor > 0 ? 8UL : 0UL;
            byte[] nameBytes = Encoding.UTF8.GetBytes(name);
            Le(output, 0x04034B50, 4); Le(output, (ulong)version, 2); Le(output, flags, 2); Le(output, 0, 2);
            Le(output, 0, 2); Le(output, 0x21, 2); Le(output, descriptor > 0 ? 0 : crc, 4);
            Le(output, descriptor > 0 ? 0 : size, 4); Le(output, descriptor > 0 ? 0 : size, 4);
            Le(output, (ulong)nameBytes.Length, 2); Le(output, 0, 2); output.Write(nameBytes); output.Write(body);
            if (descriptor > 0)
            {
                if (signature) Le(output, 0x08074B50, 4);
                Le(output, crc, 4); Le(output, size, descriptor); Le(output, size, descriptor);
            }
            Le(central, 0x02014B50, 4); Le(central, 20, 2); Le(central, (ulong)version, 2); Le(central, centralFlag ? flags : 0, 2);
            Le(central, 0, 2); Le(central, 0, 2); Le(central, 0x21, 2); Le(central, crc, 4); Le(central, size, 4); Le(central, size, 4);
            Le(central, (ulong)nameBytes.Length, 2); Le(central, 0, 2); Le(central, 0, 2); Le(central, 0, 2); Le(central, 0, 2);
            Le(central, 0, 4); Le(central, offset, 4); central.Write(nameBytes);
        }
        ulong directoryOffset = (ulong)output.Length;
        central.Position = 0;
        central.CopyTo(output);
        Le(output, 0x06054B50, 4); Le(output, 0, 2); Le(output, 0, 2); Le(output, (ulong)parts.Length, 2); Le(output, (ulong)parts.Length, 2);
        Le(output, (ulong)central.Length, 4); Le(output, directoryOffset, 4); Le(output, 0, 2);
        output.Write(Encoding.ASCII.GetBytes(new string('g', trailing)));
        return output.ToArray();
    }

    [Fact]
    public async Task CanonicalTextAndPDF()
    {
        var reader = new BoundedDocumentExtractor();
        var pdf = await reader.ExtractAsync(new Uri(SharedFixtures.Path("ingestion/pages.pdf")), SourceType.Pdf, FolderRules.Defaults);
        Assert.Equal("A\n\n\n\nB", pdf.Text);
        Assert.Equal(new[] { new PageBoundary(1, 0, 1), new PageBoundary(2, 3, 3), new PageBoundary(3, 5, 6) }, pdf.Pages);
        using var file = new TempFile(".txt", Encoding.UTF8.GetBytes("  A😀e\u0301Z\r\n"));
        var plain = await reader.ExtractAsync(new Uri(file.Path), SourceType.Text, FolderRules.Defaults);
        Assert.Equal("  A😀e\u0301Z\r\n", plain.Text);
        Assert.Equal("utf-8", plain.Encoding);
        using var empty = new TempFile(".md", Array.Empty<byte>());
        Assert.Equal("", (await reader.ExtractAsync(new Uri(empty.Path), SourceType.Markdown, FolderRules.Defaults)).Text);
        var small = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { FileBytes = 1 } };
        await Error("fileLimit", () => reader.ExtractAsync(new Uri(file.Path), SourceType.Text, small));
        // Local-only reader must reject a network URI before any file or network access.
        await Error("outsideRoot", () => reader.ExtractAsync(new Uri("https://example.invalid/document.txt"), SourceType.Text, FolderRules.Defaults));
    }

    [Fact]
    public async Task ExpandedBytesActualCount()
    {
        foreach (var row in Cases().Where(c => c.GetProperty("operation").GetString() == "bounded-stream")) RunStreamCase(row);
        var rules = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { OfficeBytes = 1 } };
        int accepted = 0;
        var reader = new BoundedDocumentExtractor(new ExtractionDiagnostics { OfficeBytesAccepted = n => accepted += n });
        await Error("officeLimit", () => reader.ExtractAsync(new Uri(SharedFixtures.Path("ingestion/paragraphs.docx")), SourceType.Docx, rules));
        Assert.Equal(0, accepted);
        using (var unused = ArchiveWith("unused.xml", new string('x', 1024)))
        {
            var unusedRules = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { OfficeBytes = 512 } };
            await Error("officeLimit", () => reader.ExtractAsync(new Uri(unused.Path), SourceType.Docx, unusedRules));
            Assert.Equal(0, accepted);
        }
        foreach (string name in new[] { "../escape.xml", "/absolute.xml", "word/../word/document.xml" })
        {
            using var zip = ArchiveWith(name);
            await Error("corruptArchive", () => reader.ExtractAsync(new Uri(zip.Path), SourceType.Docx, FolderRules.Defaults));
        }
    }

    [Fact]
    public async Task CellAndScalarBounds()
    {
        int cells = 0;
        var reader = new BoundedDocumentExtractor(new ExtractionDiagnostics { CellMaterializing = () => cells++ });
        var rules = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { Cells = 2 } };
        await Error("cellLimit", () => reader.ExtractAsync(new Uri(SharedFixtures.Path("ingestion/workbook.xlsx")), SourceType.Xlsx, rules));
        Assert.Equal(2, cells);
        rules = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { TextScalars = 4 } };
        await Error("textLimit", () => reader.ExtractAsync(new Uri(SharedFixtures.Path("ingestion/paragraphs.docx")), SourceType.Docx, rules));
        // Cap a single XML text node, including text later referenced from a shared string.
        string xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>" +
            new string('x', 65536) + "</w:t></w:r></w:p></w:body></w:document>";
        using var zip = ArchiveWith("word/document.xml", xml, false);
        await Error("textLimit", () => reader.ExtractAsync(new Uri(zip.Path), SourceType.Docx, rules));
        int pages = 0;
        reader = new BoundedDocumentExtractor(new ExtractionDiagnostics { PageTextReading = () => pages++ });
        rules = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { TextScalars = 3 } };
        await Error("textLimit", () => reader.ExtractAsync(new Uri(SharedFixtures.Path("ingestion/pages.pdf")), SourceType.Pdf, rules));
        Assert.Equal(2, pages);
        using var office = new BoundedOfficeReader(SharedFixtures.Path("ingestion/workbook.xlsx"), IngestionLimits.Defaults);
        using var attribute = XmlReader.Create(new StringReader("<format code=\"😀xx\"/>"));
        attribute.MoveToContent();
        Assert.Equal("textLimit", Assert.Throws<FolderIngestionException>(() => office.ReadAttribute(attribute, "code", 1)).Code);
        Assert.Equal(XmlNodeType.Element, attribute.NodeType);
        using var hugeFormat = new Asset(JsonSerializer.SerializeToElement(new
        {
            asset = "ingestion/workbook.xlsx",
            mutations = new[] { new
            {
                entry = "xl/styles.xml", operation = "replace-entry",
                text = "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts><numFmt numFmtId=\"164\" formatCode=\"" +
                    new string('y', 65536) + "\"/></numFmts><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"164\"/></cellXfs></styleSheet>"
            } }
        }));
        rules = FolderRules.Defaults with { Limits = IngestionLimits.Defaults with { TextScalars = 1000 } };
        await Error("textLimit", () => reader.ExtractAsync(new Uri(hugeFormat.Path), SourceType.Xlsx, rules));
    }

    [Fact]
    public async Task CancellationClosesReaders()
    {
        using var source = new TempFile(".xlsx", File.ReadAllBytes(SharedFixtures.Path("ingestion/workbook.xlsx")));
        using var cancellation = new CancellationTokenSource();
        int cells = 0;
        var reader = new BoundedDocumentExtractor(new ExtractionDiagnostics
        {
            CellMaterializing = () => { if (++cells == 2) cancellation.Cancel(); }
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => reader.ExtractAsync(new Uri(source.Path),
            SourceType.Xlsx, FolderRules.Defaults, cancellation.Token));
        Assert.Equal(2, cells);
        using (File.Open(source.Path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => reader.ExtractAsync(new Uri(source.Path),
            SourceType.Xlsx, FolderRules.Defaults, cancelled.Token));
    }

    private static async Task RunExtractCase(JsonElement row)
    {
        using var asset = new Asset(row.GetProperty("input"));
        int cells = 0, pageReads = 0;
        var reader = new BoundedDocumentExtractor(new ExtractionDiagnostics
        {
            CellMaterializing = () => cells++, PageTextReading = () => pageReads++
        });
        var input = row.GetProperty("input"); var expected = row.GetProperty("expected");
        string name = row.GetProperty("name").GetString()!;
        var rules = FolderRules.Defaults with { Limits = IngestionLimits.FromJson(input.GetProperty("limits").GetRawText()) };
        Func<Task<CanonicalDocument>> extract = () => reader.ExtractAsync(new Uri(asset.Path),
            SourceTypeExtensions.FromRawValue(input.GetProperty("kind").GetString()!), rules);
        if (expected.TryGetProperty("error", out var error))
        {
            var thrown = await Record.ExceptionAsync(extract);
            Assert.True(thrown is FolderIngestionException f && f.Code == error.GetString(),
                $"{name}: expected {error.GetString()}, got {thrown}");
        }
        else
        {
            CanonicalDocument result;
            try { result = await extract(); }
            catch (Exception e) { throw new Xunit.Sdk.XunitException($"{name}: unexpected {e}"); }
            Assert.True(expected.GetProperty("text").GetString() == result.Text,
                $"{name}: expected {JsonSerializer.Serialize(expected.GetProperty("text").GetString())}, got {JsonSerializer.Serialize(result.Text)}");
            if (expected.TryGetProperty("sheetNames", out var names))
                Assert.Equal(names.EnumerateArray().Select(x => x.GetString()), result.SheetNames);
            if (expected.TryGetProperty("pages", out var pages))
                Assert.Equal(pages.EnumerateArray().Select(p => new PageBoundary(p.GetProperty("page").GetInt32(),
                    p.GetProperty("start").GetInt32(), p.GetProperty("end").GetInt32())), result.Pages);
        }
        if (expected.TryGetProperty("cellsMaterialized", out var count)) Assert.Equal(count.GetInt32(), cells);
        if (expected.TryGetProperty("pageTextReads", out count)) Assert.Equal(count.GetInt32(), pageReads);
    }

    private static void RunStreamCase(JsonElement row)
    {
        var input = row.GetProperty("input"); var expected = row.GetProperty("expected");
        using var stream = new Blocks(input.GetProperty("blocks").EnumerateArray()
            .Select(b => b.EnumerateArray().Select(x => x.GetByte()).ToArray()).ToArray());
        long maximum = input.GetProperty("maxOfficeDecompressedBytes").GetInt64();
        var budget = new OfficeExpansionBudget(maximum);
        void Run()
        {
            OfficeExpansionBudget.Preflight(input.GetProperty("declaredBytes").EnumerateArray().Select(x => x.GetInt64()), maximum);
            using var counted = budget.Wrap(stream, leaveOpen: true);
            byte[] block = new byte[64];
            while (counted.Read(block, 0, block.Length) != 0) { }
        }
        if (expected.TryGetProperty("error", out var error))
            Assert.Equal(error.GetString(), Assert.Throws<FolderIngestionException>(Run).Code);
        else Run();
        Assert.Equal(expected.GetProperty("acceptedBytes").GetInt64(), budget.AcceptedBytes);
        Assert.Equal(expected.GetProperty("readCalls").GetInt32(), stream.ReadCalls);
    }

    /// <summary>Office v1 cases; XLSX text cases superseded by ingestion-xlsx-v2 carry their v2 expectation.</summary>
    private static JsonElement[] Cases() => SharedFixtures.Json("contracts/ingestion-office-v1.json")
        .GetProperty("cases").EnumerateArray()
        .Select(row => SpreadsheetSupersession.Apply(row, "ingestion-office-v1.json")).ToArray();
    private static async Task Error(string code, Func<Task<CanonicalDocument>> action) =>
        Assert.Equal(code, (await Assert.ThrowsAsync<FolderIngestionException>(action)).Code);

    private sealed class TempFile : IDisposable
    {
        public string Path { get; }
        public TempFile(string extension, byte[] bytes)
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "wp6-win-" + Guid.NewGuid() + extension);
            File.WriteAllBytes(Path, bytes);
        }
        public void Dispose() => File.Delete(Path);
    }

    private sealed class Asset : IDisposable
    {
        private readonly TempFile _file;
        public string Path => _file.Path;
        public Asset(JsonElement input)
        {
            string original = SharedFixtures.Path(input.GetProperty("asset").GetString()!);
            _file = new TempFile(System.IO.Path.GetExtension(original), File.ReadAllBytes(original));
            var mutations = input.GetProperty("mutations").EnumerateArray().ToArray();
            if (mutations.Length == 0) return;
            using var archive = ZipFile.Open(Path, ZipArchiveMode.Update);
            foreach (var mutation in mutations)
            {
                string part = mutation.GetProperty("entry").GetString()!;
                archive.GetEntry(part)?.Delete();
                switch (mutation.GetProperty("operation").GetString())
                {
                    case "replace-entry":
                        using (var writer = new StreamWriter(archive.CreateEntry(part).Open(), new UTF8Encoding(false)))
                            writer.Write(mutation.GetProperty("text").GetString());
                        break;
                    case "remove-entry": break;
                    default: Assert.Fail("Unknown asset mutation"); break;
                }
            }
        }
        public void Dispose() => _file.Dispose();
    }

    private static TempFile ArchiveWith(string part, string? text = null, bool includeDocument = true)
    {
        var file = new TempFile(".docx", Array.Empty<byte>());
        using (var archive = new ZipArchive(File.Open(file.Path, FileMode.Create), ZipArchiveMode.Create))
        {
            using (var root = new StreamWriter(archive.CreateEntry("_rels/.rels").Open()))
                root.Write("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>");
            if (includeDocument)
            {
                using var writer = new StreamWriter(archive.CreateEntry("word/document.xml").Open());
                writer.Write("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body/></w:document>");
            }
            using var extra = new StreamWriter(archive.CreateEntry(part).Open());
            extra.Write(text ?? "<empty/>");
        }
        return file;
    }

    private sealed class Blocks(byte[][] blocks) : Stream
    {
        private int _index, _offset;
        public int ReadCalls { get; private set; }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_index == blocks.Length) return 0;
            ReadCalls++;
            int n = Math.Min(count, blocks[_index].Length - _offset);
            blocks[_index].AsSpan(_offset, n).CopyTo(buffer.AsSpan(offset));
            _offset += n;
            if (_offset == blocks[_index].Length) { _index++; _offset = 0; }
            return n;
        }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
