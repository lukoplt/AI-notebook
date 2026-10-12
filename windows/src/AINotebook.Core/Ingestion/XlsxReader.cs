using System.Globalization;
using System.Text;
using System.Xml;

namespace AINotebook.Core.Ingestion;

/// <summary>Relationship-driven XLSX extraction rendering the compact spreadsheet canonical text v2
/// (<c>ingestion-xlsx-v2</c>, <c>text_format_version</c> 2; same as macOS <c>XlsxReader</c>).
/// Formula expressions are never evaluated.</summary>
internal static class XlsxReader
{
    private const string SpreadsheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string StrictSpreadsheetNamespace = "http://purl.oclc.org/ooxml/spreadsheetml/main";
    private const string RelationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string StrictRelationshipNamespace = "http://purl.oclc.org/ooxml/officeDocument/relationships";
    private sealed record Sheet(string Name, string Part, List<Cell> Cells);
    private sealed record Cell(string Reference, int Row, int Column, string Kind, string Value,
        int? SharedIndex, int StyleIndex, bool ExplicitStyle, bool Formula);

    public static CanonicalDocument Read(BoundedOfficeReader archive)
    {
        archive.CancellationToken.ThrowIfCancellationRequested();
        string workbook = archive.MainPart("xl/workbook.xml");
        var relationships = archive.Relationships(workbook);
        var retained = new RetainedTextBudget(archive.Limits.TextScalars);
        var (sheets, date1904) = ReadWorkbook(archive, workbook, relationships, retained);
        int cellCount = 0;
        var sharedIndices = new HashSet<int>();
        var styleIndices = new HashSet<int>();
        bool explicitStyles = false;
        foreach (var sheet in sheets)
        {
            ReadSheet(archive, sheet, retained, ref cellCount, ref explicitStyles);
            foreach (var cell in sheet.Cells)
            {
                if (cell.SharedIndex is { } shared) sharedIndices.Add(shared);
                // Only numeric values can render as dates; a missing `s` is style 0.
                if (cell.Kind == "n" && cell.Value.Length != 0) styleIndices.Add(cell.StyleIndex);
            }
        }

        // Some writers omit the sharedStrings relationship; use the conventional sibling part.
        string? sharedFallback = archive.ResolvePart(
            (workbook.LastIndexOf('/') is int slash && slash >= 0 ? workbook[..(slash + 1)] : "") + "sharedStrings.xml");
        var sharedStrings = ReadSharedStrings(archive, relationships.Values, sharedIndices, retained, sharedFallback);
        var dateStyles = ReadDateStyles(archive, relationships.Values, styleIndices, explicitStyles);
        var output = new ScalarTextBuilder(archive.Limits.TextScalars);
        for (int sheetIndex = 0; sheetIndex < sheets.Count; sheetIndex++)
        {
            archive.CancellationToken.ThrowIfCancellationRequested();
            var sheet = sheets[sheetIndex];
            if (sheetIndex != 0) output.Append("\n\n");
            output.Append("## ");
            output.Append(sheet.Name);
            output.Append("\n");
            var rendered = new List<SpreadsheetText.RenderedCell>();
            foreach (var cell in sheet.Cells.OrderBy(c => c.Row).ThenBy(c => c.Column))
            {
                archive.CancellationToken.ThrowIfCancellationRequested();
                string value = Render(cell, sharedStrings, dateStyles, date1904);
                if (value.Length != 0) rendered.Add(new SpreadsheetText.RenderedCell(cell.Row, cell.Column, value));
            }
            SpreadsheetText.AppendRows(rendered, output);
        }
        return new CanonicalDocument(output.ToString(), null, "xlsx", Array.Empty<PageBoundary>(),
            sheets.Select(s => s.Name).ToArray(), null);
    }

    /// <summary>§3: the normalized value of one cell, or "" when the cell is omitted (empty, error value, or
    /// formula without a cached value).</summary>
    private static string Render(Cell cell, Dictionary<int, string> sharedStrings, HashSet<int> dateStyles, bool date1904)
    {
        string value = cell.SharedIndex is { } shared ? sharedStrings[shared] : cell.Value;
        switch (cell.Kind)
        {
            case "e":
                return "";
            case "b":
                if (value.Length != 0) value = value == "1" ? "TRUE" : "FALSE";
                break;
            case "n" when value.Length != 0:
                string? date = dateStyles.Contains(cell.StyleIndex) ? SpreadsheetText.Date(value, date1904) : null;
                value = date ?? SpreadsheetText.Number(value) ?? value;
                break;
        }
        return SpreadsheetText.Normalize(value);
    }

    /// <summary>Hidden and very hidden sheets are not user-visible content and are skipped like chart sheets.</summary>
    private static readonly string[] HiddenStates = ["hidden", "veryHidden"];

    /// <summary>Visible worksheets in workbook order, and whether the workbook uses the 1904 date system.</summary>
    private static (List<Sheet> Sheets, bool Date1904) ReadWorkbook(BoundedOfficeReader archive, string workbook,
        IReadOnlyDictionary<string, OfficeRelationship> relationships, RetainedTextBudget retained)
    {
        using var reader = archive.OpenXml(workbook);
        RequireRoot(reader, "workbook");
        var result = new List<Sheet>();
        bool date1904 = false;
        var usedIds = new HashSet<string>(StringComparer.Ordinal);
        var usedNames = new HashSet<string>(StringComparer.Ordinal);
        while (reader.Read())
        {
            archive.CancellationToken.ThrowIfCancellationRequested();
            if (IsElement(reader, "workbookPr") && reader.Depth == 1)
                date1904 = reader.GetAttribute("date1904") is "1" or "true";
            if (!IsElement(reader, "sheets") || reader.Depth != 1) continue;
            using var sheets = reader.ReadSubtree();
            while (sheets.Read())
            {
                if (!IsElement(sheets, "sheet") || sheets.Depth != 1) continue;
                string? name = sheets.GetAttribute("name");
                string? id = sheets.GetAttribute("id", RelationshipNamespace) ??
                    sheets.GetAttribute("id", StrictRelationshipNamespace);
                if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(id) || !usedIds.Add(id))
                    throw new FolderIngestionException("invalidRelationship");
                // Chart, dialog and macro sheets carry no cell text and are skipped (same as macOS).
                if (relationships.TryGetValue(id, out var other) &&
                    NonWorksheetKinds.Any(kind => IsRelationship(other.Type, kind))) continue;
                if (HiddenStates.Contains(sheets.GetAttribute("state"), StringComparer.Ordinal)) continue;
                if (!usedNames.Add(name) || !relationships.TryGetValue(id, out var relation) ||
                    !IsRelationship(relation.Type, "worksheet") || !archive.Contains(relation.Target))
                    throw new FolderIngestionException("invalidRelationship");
                // Each sheet contributes its header, even if all its cells are empty.
                retained.Add(result.Count == 0 ? "## \n" : "\n\n## \n");
                retained.Add(name);
                result.Add(new Sheet(name, relation.Target, []));
            }
        }
        return (result, date1904);
    }

    private static void ReadSheet(BoundedOfficeReader archive, Sheet sheet,
        RetainedTextBudget retained, ref int cellCount, ref bool explicitStyles)
    {
        using var reader = archive.OpenXml(sheet.Part);
        RequireRoot(reader, "worksheet");
        var coordinates = new HashSet<(int Row, int Column)>();
        while (reader.Read())
        {
            archive.CancellationToken.ThrowIfCancellationRequested();
            if (!IsElement(reader, "sheetData") || reader.Depth != 1) continue;
            using var data = reader.ReadSubtree();
            while (data.Read())
            {
                if (!IsElement(data, "row") || data.Depth != 1) continue;
                string? rowAttribute = data.GetAttribute("r");
                int? rowNumber = rowAttribute is null ? null : PositiveNumber(rowAttribute, 1_048_576);
                using var row = data.ReadSubtree();
                while (row.Read())
                {
                    archive.CancellationToken.ThrowIfCancellationRequested();
                    if (!IsElement(row, "c") || row.Depth != 1) continue;
                    if (cellCount >= archive.Limits.Cells) throw new FolderIngestionException("cellLimit");
                    cellCount++;
                    archive.Diagnostics?.CellMaterializing?.Invoke();
                    archive.CancellationToken.ThrowIfCancellationRequested();
                    string reference = row.GetAttribute("r") ?? throw new FolderIngestionException("invalidCell");
                    var (rowIndex, columnIndex) = Coordinate(reference);
                    if (rowNumber.HasValue && rowNumber.Value != rowIndex ||
                        !coordinates.Add((rowIndex, columnIndex))) throw new FolderIngestionException("invalidCell");
                    rowNumber ??= rowIndex;
                    var cell = ReadCell(archive, row, reference, rowIndex, columnIndex, retained);
                    explicitStyles |= cell.ExplicitStyle;
                    if (cell.Formula || cell.SharedIndex.HasValue || cell.Value.Length != 0) sheet.Cells.Add(cell);
                }
            }
        }
    }

    private static Cell ReadCell(BoundedOfficeReader archive, XmlReader element, string reference,
        int row, int column, RetainedTextBudget retained)
    {
        string kind = element.GetAttribute("t") ?? "n";
        if (kind is not ("n" or "s" or "inlineStr" or "str" or "b" or "e" or "d"))
            throw new FolderIngestionException("invalidCell");
        string? style = element.GetAttribute("s");
        int styleIndex = style is null ? 0 : NonnegativeNumber(style);
        bool formula = false, sawValue = false, sawInline = false;
        string value = "";
        using var reader = element.ReadSubtree();
        while (reader.Read())
        {
            archive.CancellationToken.ThrowIfCancellationRequested();
            if (reader.NodeType != XmlNodeType.Element || reader.Depth != 1 || !Spreadsheet(reader.NamespaceURI)) continue;
            if (reader.LocalName == "f")
            {
                if (formula) throw new FolderIngestionException("invalidCell");
                formula = true;
                // Parsing the XML still rejects malformed input; formula text never becomes executable input.
                using var ignoredFormula = reader.ReadSubtree();
                while (ignoredFormula.Read()) archive.CancellationToken.ThrowIfCancellationRequested();
            }
            else if (reader.LocalName == "v")
            {
                if (sawValue || sawInline) throw new FolderIngestionException("invalidCell");
                sawValue = true;
                value = archive.ReadText(reader, kind == "s" ? archive.Limits.TextScalars : retained.Remaining);
            }
            else if (reader.LocalName == "is")
            {
                if (sawValue || sawInline || kind != "inlineStr") throw new FolderIngestionException("invalidCell");
                sawInline = true;
                value = RichText(archive, reader, retained.Remaining);
            }
        }
        if (kind == "inlineStr" && sawValue) throw new FolderIngestionException("invalidCell");
        int? sharedIndex = null;
        if (kind == "s" && value.Length != 0)
        {
            sharedIndex = NonnegativeNumber(value);
            value = "";
        }
        else if (value.Length != 0)
        {
            // A non-numeric t="n" value renders as its raw text (ingestion-xlsx-v2 §3).
            if (kind == "b" && value is not ("0" or "1")) throw new FolderIngestionException("invalidCell");
            retained.Add(value);
        }
        return new Cell(reference, row, column, kind, value, sharedIndex, styleIndex, style is not null, formula);
    }

    private static Dictionary<int, string> ReadSharedStrings(BoundedOfficeReader archive,
        IEnumerable<OfficeRelationship> relationships, HashSet<int> wanted, RetainedTextBudget retained, string? fallback)
    {
        var result = new Dictionary<int, string>();
        if (wanted.Count == 0) return result;
        string part = fallback is not null && !relationships.Any(r => IsRelationship(r.Type, "sharedStrings"))
            ? fallback : RequiredPart(archive, relationships, "sharedStrings");
        using var reader = archive.OpenXml(part);
        RequireRoot(reader, "sst");
        int index = 0;
        while (reader.Read())
        {
            archive.CancellationToken.ThrowIfCancellationRequested();
            if (!IsElement(reader, "si") || reader.Depth != 1) continue;
            if (wanted.Contains(index))
            {
                string text = RichText(archive, reader, retained.Remaining);
                retained.Add(text);
                result.Add(index, text);
            }
            index++;
        }
        if (result.Count != wanted.Count) throw new FolderIngestionException("invalidCell");
        return result;
    }

    private static string RichText(BoundedOfficeReader archive, XmlReader element, int maximum)
    {
        var output = new ScalarTextBuilder(maximum);
        using var reader = element.ReadSubtree();
        while (reader.Read())
        {
            archive.CancellationToken.ThrowIfCancellationRequested();
            if (IsElement(reader, "t") && reader.Depth == 1)
                output.Append(archive.ReadText(reader, maximum - output.Count));
            else if (IsElement(reader, "r") && reader.Depth == 1)
            {
                using var run = reader.ReadSubtree();
                while (run.Read())
                    if (IsElement(run, "t") && run.Depth == 1)
                        output.Append(archive.ReadText(run, maximum - output.Count));
            }
        }
        return output.ToString();
    }

    private static HashSet<int> ReadDateStyles(BoundedOfficeReader archive,
        IEnumerable<OfficeRelationship> relationships, HashSet<int> wanted, bool explicitStyles)
    {
        var result = new HashSet<int>();
        if (wanted.Count == 0) return result;
        var candidates = relationships.Where(r => IsRelationship(r.Type, "styles")).ToArray();
        if (candidates.Length == 0 && !explicitStyles) return result;
        string part = RequiredPart(archive, candidates, "styles");
        var formatsByStyle = new Dictionary<int, int>();
        using (var reader = archive.OpenXml(part))
        {
            RequireRoot(reader, "styleSheet");
            int index = 0;
            while (reader.Read())
            {
                archive.CancellationToken.ThrowIfCancellationRequested();
                if (!IsElement(reader, "cellXfs") || reader.Depth != 1) continue;
                using var xfs = reader.ReadSubtree();
                while (xfs.Read())
                {
                    if (!IsElement(xfs, "xf") || xfs.Depth != 1) continue;
                    if (wanted.Contains(index)) formatsByStyle.Add(index,
                        NonnegativeNumber(xfs.GetAttribute("numFmtId") ?? "0"));
                    index++;
                }
            }
        }
        if (formatsByStyle.Count != wanted.Count) throw new FolderIngestionException("invalidCell");
        var wantedCustom = formatsByStyle.Values.Where(id => id >= 164).ToHashSet();
        var dateFormats = new HashSet<int>();
        if (wantedCustom.Count != 0)
        {
            // The second bounded pass avoids retaining every attacker-supplied format string.
            // Both passes consume the archive's shared actual-expanded-byte allowance.
            using var reader = archive.OpenXml(part);
            RequireRoot(reader, "styleSheet");
            var found = new HashSet<int>();
            while (reader.Read())
            {
                archive.CancellationToken.ThrowIfCancellationRequested();
                if (!IsElement(reader, "numFmts") || reader.Depth != 1) continue;
                using var formats = reader.ReadSubtree();
                while (formats.Read())
                {
                    if (!IsElement(formats, "numFmt") || formats.Depth != 1) continue;
                    int id = NonnegativeNumber(formats.GetAttribute("numFmtId") ?? "");
                    if (!wantedCustom.Contains(id)) continue;
                    if (!found.Add(id)) throw new FolderIngestionException("invalidCell");
                    string code = archive.ReadAttribute(formats, "formatCode") ??
                        throw new FolderIngestionException("invalidCell");
                    if (SpreadsheetText.IsDateFormat(code)) dateFormats.Add(id);
                }
            }
            if (found.Count != wantedCustom.Count) throw new FolderIngestionException("invalidCell");
        }
        foreach (var (style, format) in formatsByStyle)
            if (format < 164 ? SpreadsheetText.IsBuiltInDate(format) : dateFormats.Contains(format)) result.Add(style);
        return result;
    }

    private static (int Row, int Column) Coordinate(string reference)
    {
        int offset = 0, column = 0;
        while (offset < reference.Length && reference[offset] is >= 'A' and <= 'Z')
        {
            column = checked(column * 26 + reference[offset++] - 'A' + 1);
            if (column > 16_384) throw new FolderIngestionException("invalidCell");
        }
        if (column == 0 || offset == reference.Length) throw new FolderIngestionException("invalidCell");
        int row = PositiveNumber(reference[offset..], 1_048_576);
        if (reference[offset] == '0') throw new FolderIngestionException("invalidCell");
        return (row, column);
    }

    private static int NonnegativeNumber(string value)
    {
        if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int number) || number < 0)
            throw new FolderIngestionException("invalidCell");
        return number;
    }

    private static int PositiveNumber(string value, int maximum)
    {
        int number = NonnegativeNumber(value);
        if (number == 0 || number > maximum) throw new FolderIngestionException("invalidCell");
        return number;
    }

    private static string RequiredPart(BoundedOfficeReader archive,
        IEnumerable<OfficeRelationship> relationships, string kind)
    {
        var matches = relationships.Where(r => IsRelationship(r.Type, kind)).Take(2).ToArray();
        if (matches.Length != 1 || !archive.Contains(matches[0].Target))
            throw new FolderIngestionException("invalidRelationship");
        return matches[0].Target;
    }

    private static readonly string[] NonWorksheetKinds = ["chartsheet", "dialogsheet", "macrosheet"];

    private static bool IsRelationship(string type, string role) =>
        type == RelationshipNamespace + "/" + role || type == StrictRelationshipNamespace + "/" + role;
    private static bool Spreadsheet(string value) => value is SpreadsheetNamespace or StrictSpreadsheetNamespace;
    private static bool IsElement(XmlReader reader, string name) => reader.NodeType == XmlNodeType.Element &&
        reader.LocalName == name && Spreadsheet(reader.NamespaceURI);
    private static void RequireRoot(XmlReader reader, string name)
    {
        reader.MoveToContent();
        if (!IsElement(reader, name)) throw new FolderIngestionException("corruptArchive");
    }

    private sealed class RetainedTextBudget(int maximum)
    {
        private int _count;
        public int Remaining => maximum - _count;
        public void Add(string value)
        {
            foreach (var _ in value.EnumerateRunes())
            {
                if (_count == maximum) throw new FolderIngestionException("textLimit");
                _count++;
            }
        }
    }
}
