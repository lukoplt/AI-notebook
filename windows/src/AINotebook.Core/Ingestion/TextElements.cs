using System.Globalization;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Splits a string into Swift-`Character`-equivalent units (extended grapheme
/// clusters) using <see cref="StringInfo"/>, so chunk window/overlap offsets
/// match the macOS implementation for non-ASCII / emoji / combining marks.
/// Do NOT use string.Length (UTF-16 code units) for chunk math.
/// </summary>
public static class TextElements
{
    /// <summary>Enumerate the grapheme clusters of <paramref name="s"/> as substrings.</summary>
    public static List<string> Split(string s)
    {
        var result = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext())
        {
            result.Add((string)e.Current);
        }
        return result;
    }

    /// <summary>Count of grapheme clusters (Swift `String.count`).</summary>
    public static int Count(string s)
    {
        int n = 0;
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext())
        {
            n++;
        }
        return n;
    }
}
