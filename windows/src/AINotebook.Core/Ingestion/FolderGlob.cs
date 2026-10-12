using System.Text;
using AINotebook.Core.Language;

namespace AINotebook.Core.Ingestion;

/// <summary>The normalized, scalar-based glob grammar from folder-rag-v1.</summary>
public sealed class FolderGlob
{
    private readonly bool _anchored;
    private readonly bool _caseSensitive;
    private readonly UnicodeTables _tables;
    private readonly int[][] _components;

    public FolderGlob(string pattern, bool caseSensitive, UnicodeTables tables)
    {
        ArgumentNullException.ThrowIfNull(tables);
        if (string.IsNullOrEmpty(pattern) || pattern[0] == '!' || pattern.IndexOfAny(['[', ']', '{', '}', '\\']) >= 0)
            throw new FolderIngestionException("unsupportedSyntax");
        string normalized = pattern.Trim('/');
        if (normalized.Length == 0) throw new FolderIngestionException("unsupportedSyntax");
        _anchored = pattern[0] == '/' || normalized.Contains('/');
        _caseSensitive = caseSensitive;
        _tables = tables;
        _components = normalized.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Scalars).ToArray();
    }

    public bool Matches(string relativePath)
    {
        ArgumentNullException.ThrowIfNull(relativePath);
        // The filesystem boundary supplies canonical '/'-separated relative paths.
        // Do not reinterpret backslashes or apply native filesystem casing here.
        if (relativePath.Length == 0 || relativePath[0] == '/') return false;
        int[][] path = relativePath.Split('/').Select(Scalars).ToArray();
        if (!_anchored) return path.Any(component => ComponentMatches(_components[0], component));

        var previous = new bool[path.Length + 1];
        previous[0] = true;
        foreach (int[] pattern in _components)
        {
            var next = new bool[path.Length + 1];
            if (pattern is [42, 42])
            {
                next[0] = previous[0];
                for (int j = 1; j <= path.Length; j++)
                    next[j] = previous[j] || next[j - 1];
            }
            else
            {
                for (int j = 1; j <= path.Length; j++)
                    next[j] = previous[j - 1] && ComponentMatches(pattern, path[j - 1]);
            }
            previous = next;
        }
        // A match against an ancestor excludes all of that directory's descendants.
        return previous.Any(matched => matched);
    }

    private int[] Scalars(string value) => value.EnumerateRunes()
        .Select(rune => _caseSensitive ? rune.Value : _tables.SimpleLowercase(rune.Value)).ToArray();

    private static bool ComponentMatches(int[] pattern, int[] text)
    {
        var previous = new bool[text.Length + 1];
        previous[0] = true;
        foreach (int scalar in pattern)
        {
            var next = new bool[text.Length + 1];
            if (scalar == '*')
            {
                next[0] = previous[0];
                for (int j = 1; j <= text.Length; j++)
                    next[j] = previous[j] || next[j - 1];
            }
            else
            {
                for (int j = 1; j <= text.Length; j++)
                    next[j] = previous[j - 1] && (scalar == '?' || scalar == text[j - 1]);
            }
            previous = next;
        }
        return previous[text.Length];
    }
}
