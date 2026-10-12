using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AINotebook.Core.Language;

/// <summary>Immutable Unicode 15.1 data. No operation depends on the host Unicode version.</summary>
public sealed class UnicodeTables
{
    internal const string NormalizationVersion = "ucd-15.1.0-default-full-v1";
    private readonly (int Start, int End, string Category)[] _categories;
    private readonly Dictionary<int, byte> _ccc;
    private readonly Dictionary<int, int[]> _decomposition, _fold;
    private readonly Dictionary<int, int> _lower;
    private readonly Dictionary<(int, int), int> _composition;
    /// <summary><see cref="WordClass"/> of every BMP scalar, precomputed from the categories.</summary>
    private readonly byte[] _wordClassBmp = new byte[0x10000];
    /// <summary>Canonical combining class of every BMP scalar (the <c>_ccc</c> values).</summary>
    private readonly byte[] _cccBmp = new byte[0x10000];
    /// <summary>Per BMP scalar: HasDecomposition, HasFold, ComposesAsSecond. The dictionaries stay authoritative; a clear
    /// bit only skips a lookup that would miss.</summary>
    private readonly byte[] _flagsBmp = new byte[0x10000];
    private const byte HasDecomposition = 1, HasFold = 2, ComposesAsSecond = 4;

    private UnicodeTables((int, int, string)[] categories, Dictionary<int, byte> ccc,
        Dictionary<int, int[]> decomposition, Dictionary<int, int[]> fold,
        Dictionary<int, int> lower, Dictionary<(int, int), int> composition)
    {
        _categories = categories;
        _ccc = ccc;
        _decomposition = decomposition;
        _fold = fold;
        _lower = lower;
        _composition = composition;
        foreach (var (start, end, category) in categories)
        {
            byte value = WordClassOf(category);
            if (value == OtherClass || start > 0xFFFF) continue;
            _wordClassBmp.AsSpan(start, Math.Min(end, 0xFFFF) - start + 1).Fill(value);
        }
        foreach (var (cp, value) in ccc) if (cp <= 0xFFFF) _cccBmp[cp] = value;
        foreach (int cp in decomposition.Keys) if (cp <= 0xFFFF) _flagsBmp[cp] |= HasDecomposition;
        foreach (int cp in fold.Keys) if (cp <= 0xFFFF) _flagsBmp[cp] |= HasFold;
        foreach (var (_, second) in composition.Keys) if (second <= 0xFFFF) _flagsBmp[second] |= ComposesAsSecond;
        for (int cp = 0x1161; cp < 0x1176; cp++) _flagsBmp[cp] |= ComposesAsSecond; // Hangul V
        for (int cp = 0x11A8; cp < 0x11C3; cp++) _flagsBmp[cp] |= ComposesAsSecond; // Hangul T
    }

    private byte Ccc(int cp) => (uint)cp <= 0xFFFF ? _cccBmp[cp] : _ccc.GetValueOrDefault(cp);
    private bool Lacks(byte flag, int cp) => (uint)cp <= 0xFFFF && (_flagsBmp[cp] & flag) == 0;

    internal const byte OtherClass = 0, LetterClass = 1, MarkClass = 2;
    private static byte WordClassOf(string category) =>
        category[0] == 'L' ? LetterClass : category[0] == 'M' ? MarkClass : OtherClass;

    /// <summary>The language detector's word class of <see cref="GeneralCategory"/> (letter, mark or other),
    /// without a string comparison for BMP scalars.</summary>
    internal byte WordClass(int scalar) =>
        (uint)scalar <= 0xFFFF ? _wordClassBmp[scalar] : WordClassOf(GeneralCategory(scalar));

    public static UnicodeTables LoadBundled()
    {
        byte[] Read(string name)
        {
            using var stream = typeof(UnicodeTables).Assembly.GetManifestResourceStream("AINotebook.Core.Language." + name)
                ?? throw new InvalidDataException("Missing Unicode resource: " + name);
            using var output = new MemoryStream();
            stream.CopyTo(output);
            return output.ToArray();
        }
        var sidecar = Read("unicode-15.1.0.json.sha256");
        if (sidecar.Length != 65 || sidecar[^1] != 10) throw new InvalidDataException("Invalid Unicode hash sidecar.");
        return Load(Read("unicode-15.1.0.json"), Encoding.ASCII.GetString(sidecar, 0, 64));
    }

    public static UnicodeTables Load(ReadOnlySpan<byte> data, string expectedSha256)
    {
        try
        {
            if (expectedSha256.Length != 64 || expectedSha256.Any(c => !(c is >= '0' and <= '9' or >= 'a' and <= 'f')) ||
                !CryptographicOperations.FixedTimeEquals(SHA256.HashData(data), Convert.FromHexString(expectedSha256)))
                throw new InvalidDataException("Unicode SHA-256 mismatch.");
            _ = new UTF8Encoding(false, true).GetCharCount(data);
            using var document = JsonDocument.Parse(data.ToArray(), new JsonDocumentOptions { MaxDepth = 64 });
            var root = document.RootElement;
            CheckKeys(root, "format", "unicodeVersion", "normalizationTablesVersion", "categories", "ccc", "decomposition",
                "compositionExclusions", "composition", "caseFold", "simpleLower");
            if (Integer(root.GetProperty("format")) != 1 || root.GetProperty("unicodeVersion").GetString() != "15.1.0" ||
                root.GetProperty("normalizationTablesVersion").GetString() != NormalizationVersion)
                throw new InvalidDataException("Incompatible Unicode table version.");
            var categories = new List<(int, int, string)>();
            var validCategories = new HashSet<string>("Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc Pd Ps Pe Pi Pf Po Sm Sc Sk So Zs Zl Zp Cc Cf Cs Co".Split(' '));
            int previous = -1;
            foreach (var row in root.GetProperty("categories").EnumerateArray())
            {
                Row(row, 3);
                int start = Integer(row[0]), end = Integer(row[1]);
                string category = row[2].GetString() ?? "";
                if (start <= previous || end < start || end > 0x10FFFF || !validCategories.Contains(category))
                    throw new InvalidDataException("Invalid category range.");
                categories.Add((start, end, category));
                previous = end;
            }
            var ccc = new Dictionary<int, byte>();
            previous = -1;
            foreach (var row in root.GetProperty("ccc").EnumerateArray())
            {
                Row(row, 2);
                int cp = OrderedScalar(row[0], ref previous), value = Integer(row[1]);
                if (value is < 1 or > 255) throw new InvalidDataException("Invalid combining class.");
                ccc.Add(cp, (byte)value);
            }
            var decomposition = Mappings(root.GetProperty("decomposition"));
            var fold = Mappings(root.GetProperty("caseFold"));
            var lower = new Dictionary<int, int>();
            previous = -1;
            foreach (var row in root.GetProperty("simpleLower").EnumerateArray())
            {
                Row(row, 2);
                int cp = OrderedScalar(row[0], ref previous), value = Scalar(row[1]);
                if (cp == value) throw new InvalidDataException("Redundant lowercase identity.");
                lower.Add(cp, value);
            }
            var exclusions = new HashSet<int>();
            previous = -1;
            foreach (var cp in root.GetProperty("compositionExclusions").EnumerateArray())
                exclusions.Add(OrderedScalar(cp, ref previous));
            var composition = new Dictionary<(int, int), int>();
            (int, int) lastPair = (-1, -1);
            foreach (var row in root.GetProperty("composition").EnumerateArray())
            {
                Row(row, 3);
                int first = Scalar(row[0]), second = Scalar(row[1]), result = Scalar(row[2]);
                var pair = (first, second);
                if (pair.CompareTo(lastPair) <= 0 || exclusions.Contains(result) ||
                    !decomposition.TryGetValue(result, out var parts) || !parts.SequenceEqual(new[] { first, second }) ||
                    ccc.GetValueOrDefault(first) != 0)
                    throw new InvalidDataException("Invalid composition mapping.");
                composition.Add(pair, result);
                lastPair = pair;
            }
            foreach (var (cp, parts) in decomposition)
                if (parts.Length == 2 && !exclusions.Contains(cp) &&
                    (!composition.TryGetValue((parts[0], parts[1]), out int composed) || composed != cp))
                    throw new InvalidDataException("Missing composition mapping.");
            ValidateAcyclic(decomposition);
            return new(categories.ToArray(), ccc, decomposition, fold, lower, composition);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or ArgumentException or FormatException or OverflowException)
        {
            throw new InvalidDataException("Malformed Unicode tables.", e);
        }
    }

    private static void CheckKeys(JsonElement value, params string[] keys)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Expected table object.");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var p in value.EnumerateObject())
            if (!keys.Contains(p.Name, StringComparer.Ordinal) || !seen.Add(p.Name)) throw new InvalidDataException("Invalid table key.");
        if (seen.Count != keys.Length) throw new InvalidDataException("Missing table key.");
    }
    private static void Row(JsonElement row, int length)
    {
        if (row.ValueKind != JsonValueKind.Array || row.GetArrayLength() != length) throw new InvalidDataException("Invalid table row.");
    }
    private static int Integer(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt32(out int n) ||
            element.GetRawText().Any(c => !(c is >= '0' and <= '9' or '-')))
            throw new InvalidDataException("Expected integer.");
        return n;
    }
    private static int Scalar(JsonElement element)
    {
        int cp = Integer(element);
        if (!IsScalar(cp)) throw new InvalidDataException("Invalid scalar.");
        return cp;
    }
    private static int OrderedScalar(JsonElement element, ref int previous)
    {
        int cp = Scalar(element);
        if (cp <= previous) throw new InvalidDataException("Unsorted or duplicate scalar.");
        return previous = cp;
    }
    private static Dictionary<int, int[]> Mappings(JsonElement rows)
    {
        var map = new Dictionary<int, int[]>();
        int previous = -1;
        foreach (var row in rows.EnumerateArray())
        {
            Row(row, 2);
            int cp = OrderedScalar(row[0], ref previous);
            int[] value = row[1].EnumerateArray().Select(Scalar).ToArray();
            if (value.Length == 0 || (value.Length == 1 && value[0] == cp)) throw new InvalidDataException("Invalid sparse mapping.");
            map.Add(cp, value);
        }
        return map;
    }
    private static void ValidateAcyclic(Dictionary<int, int[]> map)
    {
        var state = new Dictionary<int, byte>();
        foreach (int root in map.Keys)
        {
            var stack = new Stack<(int Cp, bool Exit)>();
            stack.Push((root, false));
            while (stack.TryPop(out var item))
            {
                if (item.Exit) { state[item.Cp] = 2; continue; }
                byte s = state.GetValueOrDefault(item.Cp);
                if (s == 1) throw new InvalidDataException("Canonical decomposition cycle.");
                if (s == 2 || !map.TryGetValue(item.Cp, out var children)) continue;
                state[item.Cp] = 1;
                stack.Push((item.Cp, true));
                for (int i = children.Length - 1; i >= 0; i--) stack.Push((children[i], false));
            }
        }
    }
    internal static bool IsScalar(int cp) => cp is >= 0 and <= 0x10FFFF and not (>= 0xD800 and <= 0xDFFF);
    private static void RequireScalar(int cp)
    {
        if (!IsScalar(cp)) throw new ArgumentOutOfRangeException(nameof(cp), "Expected a Unicode scalar.");
    }
    public string GeneralCategory(int scalar)
    {
        RequireScalar(scalar);
        int low = 0, high = _categories.Length - 1;
        while (low <= high)
        {
            int mid = low + (high - low) / 2;
            var range = _categories[mid];
            if (scalar < range.Start) high = mid - 1;
            else if (scalar > range.End) low = mid + 1;
            else return range.Category;
        }
        return "Cn";
    }
    public byte CombiningClass(int scalar) { RequireScalar(scalar); return _ccc.GetValueOrDefault(scalar); }
    public int SimpleLowercase(int scalar) { RequireScalar(scalar); return _lower.GetValueOrDefault(scalar, scalar); }
    public int[] FullCaseFold(IReadOnlyList<int> scalars)
    {
        var result = new List<int>(scalars.Count);
        foreach (int cp in scalars)
        {
            RequireScalar(cp);
            if (!Lacks(HasFold, cp) && _fold.TryGetValue(cp, out var mapped)) result.AddRange(mapped);
            else result.Add(cp);
        }
        return result.ToArray();
    }
    public int[] Nfd(IReadOnlyList<int> scalars)
    {
        var expanded = new List<int>(scalars.Count);
        var stack = new Stack<int>();
        foreach (int original in scalars)
        {
            RequireScalar(original);
            if (Lacks(HasDecomposition, original) && original - 0xAC00 is < 0 or >= 11172)
            {
                expanded.Add(original);
                continue;
            }
            stack.Push(original);
            while (stack.TryPop(out int cp))
            {
                int s = cp - 0xAC00;
                if (s is >= 0 and < 11172)
                {
                    expanded.Add(0x1100 + s / 588);
                    expanded.Add(0x1161 + s % 588 / 28);
                    if (s % 28 != 0) expanded.Add(0x11A7 + s % 28);
                }
                else if (!Lacks(HasDecomposition, cp) && _decomposition.TryGetValue(cp, out var parts))
                    for (int i = parts.Length - 1; i >= 0; i--) stack.Push(parts[i]);
                else expanded.Add(cp);
            }
        }
        // Counting buckets preserve equal-CCC order and bound work for long mark runs.
        var result = new List<int>(expanded.Count);
        var buckets = new List<int>?[256];
        for (int i = 0; i < expanded.Count;)
        {
            if (Ccc(expanded[i]) == 0) { result.Add(expanded[i++]); continue; }
            int min = 255, max = 1;
            while (i < expanded.Count && Ccc(expanded[i]) is byte cls && cls != 0)
            {
                (buckets[cls] ??= new List<int>()).Add(expanded[i++]);
                min = Math.Min(min, cls); max = Math.Max(max, cls);
            }
            for (int cls = min; cls <= max; cls++)
                if (buckets[cls] is { Count: > 0 } bucket) { result.AddRange(bucket); bucket.Clear(); }
        }
        return result.ToArray();
    }
    public int[] Nfc(IReadOnlyList<int> scalars)
    {
        // Compose (below) with direct calls: identical decisions without per-scalar delegate dispatch.
        var ordered = Nfd(scalars);
        var output = new List<int>(ordered.Length);
        int starter = -1;
        byte last = 0;
        foreach (int cp in ordered)
        {
            byte current = Ccc(cp);
            int? combined = starter >= 0 && (last == 0 || last < current) ? Pair(output[starter], cp) : null;
            if (combined is int replacement) output[starter] = replacement;
            else
            {
                if (current == 0) starter = output.Count;
                output.Add(cp);
                last = current;
            }
        }
        return output.ToArray();
    }
    private int? Pair(int first, int second)
    {
        if (Lacks(ComposesAsSecond, second)) return null;
        if (first is >= 0x1100 and < 0x1113 && second is >= 0x1161 and < 0x1176)
            return 0xAC00 + (first - 0x1100) * 588 + (second - 0x1161) * 28;
        if (first is >= 0xAC00 and < 0xD7A4 && (first - 0xAC00) % 28 == 0 && second is >= 0x11A8 and < 0x11C3)
            return first + second - 0x11A7;
        return _composition.TryGetValue((first, second), out int cp) ? cp : null;
    }
}
