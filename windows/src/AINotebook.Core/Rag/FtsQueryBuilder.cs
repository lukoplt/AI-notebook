using System.Text;
using AINotebook.Core.Language;
namespace AINotebook.Core.Rag;

/// <summary>
/// FTS5 MATCH expressions for chunks_fts (and the path index), contract fts-query-v2
/// (docs/contracts/fts-query-v2.md, fixture fts-query-v2.json): the v1 tokenizer and exact
/// phrases, minus cs/sk/en/de function words, plus one stem-prefix phrase per inflectable
/// word. <see cref="MatchExpressionV1"/> is the frozen folder-rag-v1 §7 builder.
/// </summary>
public sealed class FtsQueryBuilder(UnicodeTables tables)
{
    public const int MinStem = 4;

    /// <summary>Function words in key form (simple lowercase of the NFD base scalars).</summary>
    public static readonly IReadOnlyDictionary<string, string[]> Stopwords = new Dictionary<string, string>
    {
        ["cs"] = """
            a aby ale ani asi az bez bude budou by byl byla byli bylo co coz do i jak jaka jake
            jaky jakou jakym je jeho jeji jejich jen jsem jsi jsme jsou jste k kam kde kdo kdy kdyz ke
            kolik ktera ktere kteri kterou ktery kterym ma maji mame mate me mezi mi mit mu muze my na
            nad nam nas ne nebo neni nez o od ode on ona oni ono pod podle pokud po pro proc protoze
            pri s se si sve ta tak take tam te ten tedy tento teto tim to tom tomu toto tu ty u uz v
            ve vsak z za ze zda najdi najit ukaz rekni vypis uved
            """,
        ["sk"] = """
            a aby aj ak ako aka ake aky akym ale alebo ani bez bol bola boli bolo by co do este i
            ich je jeho jej k kde kedy kolko kto ktora ktore ktori ktory ku lebo ma maju na nad nie o
            od po pod podla pre preco pri s sa si so som sme ste su ta tak tam to tu uz v vo z za ze
            zo
            """,
        ["en"] = """
            a about an and are as at be been by can could did do does find for from had has have
            how i in is it its me my of on or our please should show tell that the their there these
            this those to was were what when where which who whom why will with would you your
            """,
        ["de"] = """
            aber als am an auch auf aus bei bin bis bitte das dass dem der des die ein eine einem
            einen einer eines er es fur gibt hat haben ich im in ist mit nach nicht oder sein sich sie
            sind so um und uns uber von vom was wann warum welche welcher welches wer wie wir wo zu
            zum zur
            """,
    }.ToDictionary(p => p.Key, p => p.Value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
        .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray());

    /// <summary>Inflectional endings in key form, longest first (ties in ordinal order).</summary>
    public static readonly string[] Suffixes = """
        ami emi ech ich ych ach ove ovi ova ovy ovu ost osti eho emu imu ymu ymi imi ou em om um am im
        ym ho mu ej ia ie iu a e i o u y en es s ing ed ungen ung
        """.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.Ordinal)
        .OrderByDescending(s => s.Length).ThenBy(s => s, StringComparer.Ordinal).ToArray();

    private static readonly HashSet<string> StopKeys = new(Stopwords.Values.SelectMany(x => x), StringComparer.Ordinal);

    private sealed record Token(int[] Scalars, List<List<int>> Groups, int[] Key);

    /// <summary>v1 tokenization (§7.1–2): NFC, then maximal L/N/Co runs continued by marks.</summary>
    private List<int[]> Runs(string query)
    {
        var result = new List<int[]>();
        var run = new List<int>();
        foreach (int cp in tables.Nfc(query.EnumerateRunes().Select(r => r.Value).ToArray()))
        {
            string category = tables.GeneralCategory(cp);
            bool start = category[0] is 'L' or 'N' || category == "Co";
            if (start || (run.Count != 0 && category[0] == 'M')) run.Add(cp);
            else if (run.Count != 0) { result.Add(run.ToArray()); run.Clear(); }
        }
        if (run.Count != 0) result.Add(run.ToArray());
        return result;
    }

    private static string Text(IEnumerable<int> scalars)
    {
        var builder = new StringBuilder();
        foreach (int cp in scalars) builder.Append(new Rune(cp).ToString());
        return builder.ToString();
    }

    private static string Phrase(IEnumerable<int> scalars) => "\"" + Text(scalars).Replace("\"", "\"\"") + "\"";

    private Token MakeToken(int[] scalars)
    {
        var groups = new List<List<int>>();
        foreach (int cp in tables.Nfd(scalars))
        {
            if (tables.GeneralCategory(cp)[0] == 'M' && groups.Count != 0) groups[^1].Add(cp);
            else groups.Add(new List<int> { cp });
        }
        return new Token(scalars, groups, groups.Select(g => tables.SimpleLowercase(g[0])).ToArray());
    }

    private bool Prefixable(Token token)
    {
        if (token.Groups.Count < MinStem || token.Groups.Any(g => tables.GeneralCategory(g[0])[0] != 'L')) return false;
        // Acronyms and camel case stay exact (ZXQV must not match ZXQVR).
        return !token.Groups.Skip(1).Any(g => tables.GeneralCategory(g[0]) is "Lu" or "Lt");
    }

    private static readonly int[][] SuffixKeys = Suffixes.Select(s => s.EnumerateRunes().Select(r => r.Value).ToArray()).ToArray();

    private static int StemLength(int[] key)
    {
        foreach (int[] suffix in SuffixKeys)
            if (key.Length - suffix.Length >= MinStem && key.AsSpan(key.Length - suffix.Length).SequenceEqual(suffix))
                return key.Length - suffix.Length;
        return key.Length;
    }

    /// <summary>Keys of every token of a text (fts-query-v2 steps 1–2), in order; for path matching.</summary>
    internal IReadOnlyList<string> Keys(string text) => Runs(text).Select(run => Text(MakeToken(run).Key)).ToList();

    private IEnumerable<Token> Content(string query)
    {
        var unique = new List<Token>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var run in Runs(query))
        {
            var token = MakeToken(run);
            if (seen.Add(Text(token.Key))) unique.Add(token);
        }
        var content = unique.Where(t => !StopKeys.Contains(Text(t.Key))).ToList();
        return (content.Count == 0 ? unique : content).Take(RagContractV1.Retrieval.MaxFtsTokens);
    }

    /// <summary>The content tokens (fts-query-v2 steps 1–4) with their key and optional stem key.</summary>
    internal IReadOnlyList<(string Text, string Key, string? Stem)> ContentTokens(string query)
        => Content(query).Select(t => (Text(t.Scalars), Text(t.Key),
            Prefixable(t) ? Text(t.Key.Take(StemLength(t.Key))) : null)).ToList();

    /// <summary>fts-query-v2. Null when the query has no token (lexical branch empty).</summary>
    public string? MatchExpression(string query)
    {
        var phrases = new List<string>();
        foreach (var token in Content(query))
        {
            phrases.Add(Phrase(token.Scalars));
            if (!Prefixable(token)) continue;
            var stem = tables.Nfc(token.Groups.Take(StemLength(token.Key)).SelectMany(g => g).ToArray());
            string prefix = Phrase(stem) + "*";
            if (!phrases.Contains(prefix, StringComparer.Ordinal)) phrases.Add(prefix);
        }
        return phrases.Count == 0 ? null : string.Join(" OR ", phrases);
    }

    /// <summary>Frozen folder-rag-v1 §7 builder (fts-query-v1.json): every token exact, OR-joined.</summary>
    public string? MatchExpressionV1(string query)
    {
        var tokens = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var run in Runs(query))
        {
            if (tokens.Count < RagContractV1.Retrieval.MaxFtsTokens && seen.Add(Text(run))) tokens.Add(Phrase(run));
        }
        return tokens.Count == 0 ? null : string.Join(" OR ", tokens);
    }
}
