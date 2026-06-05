using System.Text.RegularExpressions;

namespace AINotebook.Core.Rag;

public static class CitationParser
{
    private static readonly Regex Pattern = new(@"\[(\d+)\]", RegexOptions.Compiled);

    /// Returns 1-based citation numbers in match order, WITH duplicates,
    /// keeping only positive integers.
    public static List<int> Markers(string text)
    {
        var results = new List<int>();
        foreach (Match m in Pattern.Matches(text))
        {
            if (int.TryParse(m.Groups[1].Value, out var n) && n > 0)
                results.Add(n);
        }
        return results;
    }
}
