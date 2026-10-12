using System.Text;
namespace AINotebook.Core.Providers;

/// <summary>
/// Raw (non-catalog) embedding input formats, contract embedding-raw-format-v2
/// (docs/contracts/embedding-raw-format-v2.md, fixture embedding-raw-format-v2.json). <c>legacy</c> and
/// <c>1</c> embed text verbatim; <c>2</c> adds the model family's task prefixes and, for documents, a
/// one-line path header. A generation's stored format decides how its queries are embedded.
/// </summary>
public static class RawEmbeddingFormat
{
    public const string Current = "2";
    public const int HeaderMaxScalars = 200;

    private static bool AsciiSpace(int c) => c is 0x20 or 0x09 or 0x0A or 0x0B or 0x0C or 0x0D;

    /// <summary>ASCII-lowercased model name without surrounding ASCII whitespace, namespace and tag.</summary>
    internal static string Family(string model)
    {
        int start = 0, end = model.Length;
        while (start < end && AsciiSpace(model[start])) start++;
        while (end > start && AsciiSpace(model[end - 1])) end--;
        var lowered = new StringBuilder(end - start);
        for (int i = start; i < end; i++) lowered.Append(model[i] is >= 'A' and <= 'Z' ? (char)(model[i] + 32) : model[i]);
        string name = lowered.ToString();
        name = name[(name.LastIndexOf('/') + 1)..];
        int colon = name.IndexOf(':');
        return colon < 0 ? name : name[..colon];
    }

    public static (string Query, string Document) Prefixes(string model)
    {
        string name = Family(model);
        if (name.StartsWith("nomic-embed-text", StringComparison.Ordinal)) return ("search_query: ", "search_document: ");
        if (name.Replace('_', '-').Split('-').Contains("e5") && !name.Contains("instruct", StringComparison.Ordinal))
            return ("query: ", "passage: ");
        return ("", "");
    }

    /// <summary>The folder-relative path (or title for a loose source) as one line: runs of ASCII whitespace
    /// become one space, ends trimmed, at most 200 scalars, then "\n".</summary>
    public static string Header(string? relPath, string title)
    {
        string line = string.IsNullOrEmpty(relPath) ? title : relPath;
        var words = new List<string>();
        var current = new StringBuilder();
        foreach (var rune in line.EnumerateRunes())
        {
            if (AsciiSpace(rune.Value))
            {
                if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
            }
            else current.Append(rune.ToString());
        }
        if (current.Length > 0) words.Add(current.ToString());
        string joined = string.Join(' ', words);
        if (joined.Length == 0) return "";
        var cut = new StringBuilder();
        foreach (var rune in joined.EnumerateRunes().Take(HeaderMaxScalars)) cut.Append(rune.ToString());
        return cut.Append('\n').ToString();
    }

    public static string Query(string text, string model, string format) => format == "2" ? Prefixes(model).Query + text : text;

    /// <summary><paramref name="headed"/> is the chunk text already preceded by its <see cref="Header"/>.</summary>
    public static string Document(string headed, string model, string format) => format == "2" ? Prefixes(model).Document + headed : headed;
}
