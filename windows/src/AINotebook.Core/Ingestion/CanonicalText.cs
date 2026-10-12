using System.Globalization;
using System.Text;

namespace AINotebook.Core.Ingestion;

/// <summary>Canonical format v1. Preserves the extractor's scalar sequence, including empty pages.</summary>
public static class CanonicalText
{
    public static CanonicalDocument Assemble(string kind, IReadOnlyList<string> parts,
        IReadOnlyList<string>? names, int maxScalars)
    {
        var builder = new ScalarTextBuilder(maxScalars);
        var pages = new List<PageBoundary>();
        names ??= Array.Empty<string>();
        if (kind == "xlsx" && names.Count != parts.Count)
            throw new FolderIngestionException("invalidRelationship");
        if (kind is not ("text" or "markdown" or "txt" or "md" or "pdf" or "docx" or "pptx" or "xlsx"))
            throw new FolderIngestionException("unsupportedSyntax");
        for (int index = 0; index < parts.Count; index++)
        {
            if (index > 0)
                builder.Append(kind switch { "pdf" or "pptx" or "xlsx" => "\n\n", "docx" => "\n", _ => "" });
            if (kind == "pptx")
                builder.Append("## Slide " + (index + 1).ToString(CultureInfo.InvariantCulture) + "\n");
            else if (kind == "xlsx")
            {
                builder.Append("## ");
                builder.Append(names[index]);
                builder.Append("\n");
            }
            int start = builder.Count;
            builder.Append(parts[index]);
            if (kind == "pdf") pages.Add(new PageBoundary(index + 1, start, builder.Count));
        }
        return new CanonicalDocument(builder.ToString(), null, kind, pages,
            kind == "xlsx" ? names : Array.Empty<string>(), null);
    }
}

/// <summary>Checks each scalar before appending. Shared by bounded document readers.</summary>
internal sealed class ScalarTextBuilder(int limit)
{
    private readonly StringBuilder _builder = new();
    public int Count { get; private set; }

    public void Append(string value)
    {
        // Count before allocating/appending this value, with early rejection for oversized input.
        int count = 0;
        foreach (var _ in value.EnumerateRunes())
        {
            if (count >= limit - Count) throw new FolderIngestionException("textLimit");
            count++;
        }
        _builder.Append(value);
        Count += count;
    }

    public override string ToString() => _builder.ToString();
}
