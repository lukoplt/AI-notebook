using System.Collections.ObjectModel;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Language;

/// <summary>Offsets refer only to the normalized detector stream, never to canonical source spans.</summary>
public sealed record LanguageWindow(
    [property: JsonPropertyName("start")] int Start,
    [property: JsonPropertyName("end")] int End,
    [property: JsonPropertyName("expected")] LanguageTextResult Expected);

public sealed record LanguageDocumentResult(
    [property: JsonPropertyName("normalizedScalarCount")] int NormalizedScalarCount,
    [property: JsonPropertyName("windowCount")] int WindowCount,
    [property: JsonPropertyName("windowScalars")] int WindowScalars,
    [property: JsonPropertyName("windows")] LanguageWindow[] Windows,
    [property: JsonPropertyName("sampledLetters")] long SampledLetters,
    [property: JsonPropertyName("acceptedLetters")] IReadOnlyDictionary<string, long> AcceptedLetters,
    [property: JsonPropertyName("unknownLetters")] long UnknownLetters,
    [property: JsonPropertyName("sharesBp")] IReadOnlyDictionary<string, long> SharesBp,
    [property: JsonPropertyName("unknownShareBp")] long UnknownShareBp,
    [property: JsonPropertyName("langCoverageBp")] long LangCoverageBp,
    [property: JsonPropertyName("label")] string Label,
    [property: JsonPropertyName("reason")] string Reason);

internal sealed record LanguageAggregate(long SampledLetters, IReadOnlyDictionary<string, long> AcceptedLetters,
    long UnknownLetters, IReadOnlyDictionary<string, long> SharesBp, long UnknownShareBp, long LangCoverageBp,
    string Label, string Reason);

internal static class LanguageDocument
{
    internal static (int Start, int End)[] Ranges(int length, int count, int size)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(length);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(count);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(size);
        if (length == 0) return Array.Empty<(int, int)>();
        int k = (int)Math.Min(count, ((long)length + size - 1) / size);
        int w = Math.Min(size, length / k);
        return Enumerable.Range(0, k).Select(i =>
        {
            int start = k == 1 ? 0 : (int)((long)i * (length - w) / (k - 1));
            return (start, start + w);
        }).ToArray();
    }

    internal static LanguageDocumentResult Detect(IReadOnlyList<int> stream, LanguageScorer scorer)
    {
        var parameters = scorer.Model.Parameters;
        var ranges = Ranges(stream.Count, parameters.WindowCount, parameters.WindowScalars);
        var windows = ranges.Select(range =>
        {
            var slice = new int[range.End - range.Start];
            for (int i = 0; i < slice.Length; i++) slice[i] = stream[range.Start + i];
            // A window edge may split a combining sequence or a word. Do not normalize it again.
            return new LanguageWindow(range.Start, range.End, scorer.Score(slice));
        }).ToArray();
        var aggregate = Aggregate(scorer.Model.Targets.ToArray(), windows.Select(w => w.Expected.Label).ToArray(),
            windows.Select(w => w.Expected.LetterCount).ToArray());
        return new(stream.Count, windows.Length, windows.Length == 0 ? 0 : windows[0].End - windows[0].Start, windows,
            aggregate.SampledLetters, aggregate.AcceptedLetters, aggregate.UnknownLetters, aggregate.SharesBp,
            aggregate.UnknownShareBp, aggregate.LangCoverageBp, aggregate.Label, aggregate.Reason);
    }

    internal static LanguageAggregate Aggregate(string[] targets, string[] labels, long[] letters)
    {
        if (labels.Length != letters.Length || letters.Any(x => x < 0) || targets.Distinct(StringComparer.Ordinal).Count() != targets.Length)
            throw new ArgumentException("Invalid document aggregation inputs.");
        long total = 0, unknown = 0;
        var accepted = targets.ToDictionary(x => x, _ => 0L, StringComparer.Ordinal);
        for (int i = 0; i < labels.Length; i++)
        {
            total = checked(total + letters[i]);
            if (accepted.ContainsKey(labels[i])) accepted[labels[i]] = checked(accepted[labels[i]] + letters[i]);
            else unknown = checked(unknown + letters[i]);
        }
        long Share(long value) => total == 0 ? 0 : checked(10000 * value) / total;
        var shares = accepted.ToDictionary(x => x.Key, x => Share(x.Value), StringComparer.Ordinal);
        string? dominant = targets.FirstOrDefault(target => accepted[target] > 0 &&
            checked(10000 * accepted[target]) >= checked(7000 * total));
        int confidentTargets = accepted.Values.Count(x => x > 0);
        string label = dominant ?? (confidentTargets >= 2 ? "mixed" : "und");
        string reason = dominant is not null ? "dominant" : confidentTargets >= 2 ? "mixed" : "insufficientEvidence";
        return new(total, new ReadOnlyDictionary<string, long>(accepted), unknown,
            new ReadOnlyDictionary<string, long>(shares), Share(unknown), Share(total - unknown), label, reason);
    }
}
