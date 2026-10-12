using AINotebook.Core.Language;
namespace AINotebook.Core.Rag;

/// <summary>One in-scope file as the path matcher sees it (mtime in UTC seconds since 1970).</summary>
public sealed record PathMatchFile(long SourceId, string? RelPath, string Title, long? Mtime);

/// <summary>
/// Matched: query content tokens matched by path, title or date signals. Weight: Σ over matched
/// tokens of (files − files matching that token). Date: YYYYMMDD from the file name, else the
/// path, else mtime (UTC); 0 when unknown.
/// </summary>
/// <remarks>v2 (§6): Score is the Σ of matched terms' strengths (year segment 3, year key/date 2,
/// undated mtime 1; other terms 2 in a directory, 1 in the name only); Project is the file's project
/// directory ("" for top-level and loose files).</remarks>
public sealed record PathMatch(long SourceId, int Matched, int Score, int Weight, int Date, string Project);

/// <summary>The best path-matching tier and whether the question is an inventory question (a year or
/// document-type term matched): retrieval-paths v2 (§6).</summary>
public sealed record PathRanking(IReadOnlyList<PathMatch> Matches, bool Inventory)
{
    public static readonly PathRanking None = new([], false);
}

/// <summary>
/// retrieval-paths-v1 (docs/contracts/retrieval-paths-v1.md, fixture retrieval-paths-v1.json):
/// ranks files whose relative path and title match the question's fts-query-v2 content tokens.
/// </summary>
public sealed class PathMatcher(UnicodeTables tables)
{
    public const int MaxMatchingFiles = 30;
    private readonly FtsQueryBuilder _builder = new(tables);

    /// <summary>Token keys of a path/title are pure functions of the text: tokenizing thousands of paths per
    /// question dominated the query, so they are memoized process-wide (bounded).</summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, IReadOnlyList<string>> KeyCache = new(StringComparer.Ordinal);

    private IReadOnlyList<string> Keys(string text)
    {
        if (KeyCache.TryGetValue(text, out var hit)) return hit;
        var made = _builder.Keys(text);
        if (KeyCache.Count >= 200_000) KeyCache.Clear();
        KeyCache[text] = made;
        return made;
    }

    /// <summary>v2 (§6) document-type classes in key form; the first class whose stem prefixes a term wins.</summary>
    public static readonly IReadOnlyList<(string Name, string[] Stems)> TypeClasses =
    [
        ("offer", ["nabid", "ponuk", "offer", "proposal", "quotation", "angebot"]),
        ("order", ["objednav", "order", "bestell"]),
        ("contract", ["smlouv", "smluv", "zmluv", "contract", "agreement", "vertrag"]),
        ("invoice", ["faktur", "invoice", "rechnung"]),
        ("tender", ["vyberov", "tender", "ausschreib"]),
    ];

    internal static string[]? TypeStems(string key)
    {
        foreach (var (_, stems) in TypeClasses)
            if (stems.Any(stem => key.StartsWith(stem, StringComparison.Ordinal))) return stems;
        return null;
    }

    private sealed record Term(string Key, string? Stem, int? Year, string[]? Types);

    private static bool Digits(string key) => key.Length > 0 && key.All(c => c is >= '0' and <= '9');

    private static int? ValidDate(string key)
    {
        if (key.Length != 8 || !Digits(key)) return null;
        int value = int.Parse(key, System.Globalization.CultureInfo.InvariantCulture);
        int year = value / 10_000, month = value / 100 % 100, day = value % 100;
        return year is >= 1900 and <= 2099 && month is >= 1 and <= 12 && day is >= 1 and <= 31 ? value : null;
    }

    private static int UtcDate(long seconds)
    {
        var date = DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
        return date.Year * 10_000 + date.Month * 100 + date.Day;
    }

    internal static bool YearSegment(string segment) =>
        segment.Length == 4 && Digits(segment)
        && int.Parse(segment, System.Globalization.CultureInfo.InvariantCulture) is >= 1900 and <= 2099;

    private IReadOnlyList<Term> Terms(string query) => _builder.ContentTokens(query).Select(token =>
    {
        int? year = token.Key.Length == 4 && Digits(token.Key) && int.Parse(token.Key, System.Globalization.CultureInfo.InvariantCulture) is var y
            && y is >= 1900 and <= 2099 ? y : null;
        return new Term(token.Key, token.Stem, year, year is null ? TypeStems(token.Key) : null);
    }).ToList();

    private static bool Hit(Term term, IReadOnlyList<string> keys, HashSet<string> keySet)
    {
        if (term.Stem is string stem && keys.Any(k => k.StartsWith(stem, StringComparison.Ordinal))) return true;
        if (term.Types is string[] types && keys.Any(k => types.Any(t => k.StartsWith(t, StringComparison.Ordinal)))) return true;
        return term.Stem is null && keySet.Contains(term.Key);
    }

    /// <summary>0 = no match. Year: 3 when a directory segment is the year, 2 when a key is the year or a
    /// date of that year, 1 when only the mtime of a file without any path/name year has it. Other terms:
    /// 2 when a directory key matches, 1 when only the name or title does.</summary>
    private static int Strength(Term term, PathMatchFile file, string[] segments, IReadOnlyList<string> dirKeys,
        HashSet<string> dirSet, IReadOnlyList<string> nameKeys, HashSet<string> nameSet)
    {
        if (term.Year is int year)
        {
            string text = year.ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (segments.Contains(text, StringComparer.Ordinal)) return 3;
            var keys = dirKeys.Concat(nameKeys).ToList();
            if (dirSet.Contains(text) || nameSet.Contains(text) || keys.Any(k => (ValidDate(k) ?? 0) / 10_000 == year)) return 2;
            bool dated = segments.Any(YearSegment) || keys.Any(k => ValidDate(k) is not null);
            if (dated || file.Mtime is not long mtime) return 0;
            return UtcDate(mtime) / 10_000 == year ? 1 : 0;
        }
        if (Hit(term, dirKeys, dirSet)) return 2;
        return Hit(term, nameKeys, nameSet) ? 1 : 0;
    }

    /// <summary>The directory below the last year segment, else the parent of the first type folder (below
    /// the top level), else the file's own directory.</summary>
    private string Project(string[] segments)
    {
        int year = Array.FindLastIndex(segments, YearSegment);
        if (year >= 0) return string.Join('/', segments.Take(Math.Min(year + 2, segments.Length)));
        for (int i = 1; i < segments.Length; i++)
            if (Keys(segments[i]).Any(k => TypeStems(k) is not null)) return string.Join('/', segments.Take(i));
        return string.Join('/', segments);
    }

    /// <summary>Files of the best match tier (most matched tokens, at least ⌈tokens / 2⌉), ordered by
    /// score, weight, date (newest first) and source id.</summary>
    public IReadOnlyList<PathMatch> Rank(string query, IReadOnlyList<PathMatchFile> files) => Ranking(query, files).Matches;

    public PathRanking Ranking(string query, IReadOnlyList<PathMatchFile> files)
    {
        var terms = Terms(query);
        if (terms.Count == 0 || files.Count == 0) return PathRanking.None;
        var rows = new List<(PathMatchFile File, List<int> Hits, int Score, int Date, string[] Segments)>(files.Count);
        foreach (var file in files)
        {
            string path = file.RelPath ?? "";
            string[] components = path.Length == 0 ? [] : path.Split('/');
            string[] segments = components.Length == 0 ? [] : components[..^1];
            string name = file.RelPath is null ? file.Title : file.RelPath.Split('/')[^1];
            // "/" always ends a token, so the keys of relPath/title are the directory keys followed by the
            // name/title keys; files of one directory share its (memoized) directory keys.
            var dirKeys = Keys(string.Join('/', segments));
            var tailKeys = Keys((components.Length == 0 ? "" : components[^1]) + "/" + file.Title);
            var keys = dirKeys.Concat(tailKeys).ToList();
            var dirSet = new HashSet<string>(dirKeys, StringComparer.Ordinal);
            var tailSet = new HashSet<string>(tailKeys, StringComparer.Ordinal);
            var strengths = terms.Select(t => Strength(t, file, segments, dirKeys, dirSet, tailKeys, tailSet)).ToArray();
            var nameKeys = Keys(name);
            int date = nameKeys.Select(ValidDate).LastOrDefault(d => d is not null)
                ?? keys.Select(ValidDate).LastOrDefault(d => d is not null) ?? 0;
            if (date == 0 && file.Mtime is long mtime) date = UtcDate(mtime);
            rows.Add((file, Enumerable.Range(0, terms.Count).Where(i => strengths[i] > 0).ToList(), strengths.Sum(), date, segments));
        }
        var df = new int[terms.Count];
        foreach (var row in rows) foreach (int hit in row.Hits) df[hit]++;
        int best = rows.Max(r => r.Hits.Count);
        if (best < Math.Max(1, (terms.Count + 1) / 2)) return PathRanking.None;
        var tier = rows.Where(r => r.Hits.Count == best).ToList();
        var matches = tier
            .Select(r => new PathMatch(r.File.SourceId, best, r.Score, r.Hits.Sum(h => files.Count - df[h]), r.Date, Project(r.Segments)))
            .OrderByDescending(m => m.Score).ThenByDescending(m => m.Weight).ThenByDescending(m => m.Date).ThenBy(m => m.SourceId)
            .ToList();
        bool inventory = tier.Any(r => r.Hits.Any(i => terms[i].Year is not null || terms[i].Types is not null));
        return new PathRanking(matches, inventory);
    }
}
