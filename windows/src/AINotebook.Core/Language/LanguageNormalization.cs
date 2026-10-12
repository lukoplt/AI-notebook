using System.Text;

namespace AINotebook.Core.Language;

internal sealed record LanguageWords(string[] Words, int[][] WordScalars, int[][] BoundaryWords,
    long LetterCount, long WordCount);

internal static class LanguageNormalization
{
    internal static int[] Decode(IReadOnlyList<ushort> units, int cap) =>
        Decode(units.Count, index => units[index], cap);

    private static int[] Decode(int count, Func<int, ushort> unitAt, int cap)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(cap);
        var result = new List<int>(Math.Min(count, cap));
        int index = 0;
        while (index < count && result.Count < cap)
        {
            int first = unitAt(index);
            if (first is >= 0xD800 and <= 0xDBFF && index + 1 < count &&
                unitAt(index + 1) is >= 0xDC00 and <= 0xDFFF)
            {
                result.Add(0x10000 + (first - 0xD800) * 1024 + unitAt(index + 1) - 0xDC00);
                index += 2;
            }
            else
            {
                result.Add(first is >= 0xD800 and <= 0xDFFF ? 0xFFFD : first);
                index++;
            }
        }
        return result.ToArray();
    }

    internal static int[] Stream(string text, UnicodeTables tables, int cap) =>
        Normalize(Decode(text.Length, index => text[index], cap), tables, cap);

    internal static int[] Stream(IReadOnlyList<ushort> units, UnicodeTables tables, int cap) =>
        Normalize(Decode(units, cap), tables, cap);

    private static int[] Normalize(int[] decoded, UnicodeTables tables, int cap)
    {
        // The second cap follows the complete NFC -> fold -> NFC pipeline. Its
        // intermediate expansions must stay intact for canonical composition.
        var normalized = tables.Nfc(tables.FullCaseFold(tables.Nfc(decoded)));
        if (normalized.Length > cap) Array.Resize(ref normalized, cap);
        return normalized;
    }

    internal static LanguageWords Classify(IReadOnlyList<int> scalars, UnicodeTables tables)
    {
        var words = new List<string>();
        var wordScalars = new List<int[]>();
        var boundaryWords = new List<int[]>();
        var active = new List<int>();
        long letters = 0;

        void Flush()
        {
            if (active.Count == 0) return;
            var word = active.ToArray();
            var text = new StringBuilder(word.Length);
            foreach (int scalar in word) text.Append(char.ConvertFromUtf32(scalar));
            var boundary = new int[word.Length + 2];
            boundary[0] = -1;
            Array.Copy(word, 0, boundary, 1, word.Length);
            boundary[^1] = -2;
            words.Add(text.ToString());
            wordScalars.Add(word);
            boundaryWords.Add(boundary);
            active.Clear();
        }

        foreach (int scalar in scalars)
        {
            string category = tables.GeneralCategory(scalar);
            if (category[0] == 'L')
            {
                active.Add(scalar);
                letters++;
            }
            else if (category[0] == 'M')
            {
                if (active.Count != 0) active.Add(scalar);
            }
            else Flush();
        }
        Flush();
        return new(words.ToArray(), wordScalars.ToArray(), boundaryWords.ToArray(), letters, words.Count);
    }
}
