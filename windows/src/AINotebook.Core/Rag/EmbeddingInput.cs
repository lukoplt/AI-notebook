namespace AINotebook.Core.Rag;

/// <summary>Pure WP7 complete-input vector kernels (benchmark-v1 §2). Scalars are Unicode scalar values.</summary>
public static class EmbeddingInput
{
    /// <summary>Unpaired UTF-16 surrogates cannot be represented by Swift strings; reject them up front.</summary>
    public static void RequireValidText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!IsWellFormed(text))
            throw new EmbeddingProfileException("invalidText");
    }

    private static bool IsWellFormed(string text)
    {
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (char.IsHighSurrogate(c))
            {
                if (i + 1 >= text.Length || !char.IsLowSurrogate(text[i + 1])) return false;
                i++;
            }
            else if (char.IsLowSurrogate(c)) return false;
        }
        return true;
    }

    /// <summary>Number of Unicode scalar values (after validation).</summary>
    public static int ScalarCount(string text)
    {
        RequireValidText(text);
        int n = 0;
        foreach (var _ in text.EnumerateRunes()) n++;
        return n;
    }

    /// <summary>Split at <c>count/2</c> scalars; the left half is the shorter one for odd counts.</summary>
    public static (string Left, string Right) Bisect(string text)
    {
        RequireValidText(text);
        var s = text.EnumerateRunes().ToArray();
        if (s.Length < 2) throw new EmbeddingProfileException("inputCannotFit");
        int n = s.Length / 2;
        int utf16 = 0;
        for (int i = 0; i < n; i++) utf16 += s[i].Utf16SequenceLength;
        return (text[..utf16], text[utf16..]);
    }

    /// <summary>Prefix-project to <paramref name="dims"/> and L2-normalize in double.</summary>
    public static float[] Project(float[] vector, int nativeDims, int dims)
    {
        ArgumentNullException.ThrowIfNull(vector);
        if (vector.Length != nativeDims || dims <= 0 || dims > nativeDims || vector.Any(x => !float.IsFinite(x)))
            throw new EmbeddingProfileException("invalidEmbedding");
        double sum = 0;
        for (int i = 0; i < dims; i++) sum += (double)vector[i] * vector[i];
        double norm = Math.Sqrt(sum);
        if (!double.IsFinite(norm) || norm == 0) throw new EmbeddingProfileException("invalidEmbedding");
        var result = new float[dims];
        for (int i = 0; i < dims; i++) result[i] = (float)(vector[i] / norm);
        return result;
    }

    /// <summary>Scalar-length-weighted mean of accepted leaves, L2-normalized once.</summary>
    public static float[] Pool(IReadOnlyList<float[]> vectors, IReadOnlyList<int> scalarWeights)
    {
        ArgumentNullException.ThrowIfNull(vectors);
        ArgumentNullException.ThrowIfNull(scalarWeights);
        if (vectors.Count == 0 || vectors.Count != scalarWeights.Count || vectors[0] is null || vectors[0].Length == 0
            || scalarWeights.Any(x => x <= 0)
            || vectors.Any(v => v is null || v.Length != vectors[0].Length || v.Any(x => !float.IsFinite(x))))
            throw new EmbeddingProfileException("invalidEmbedding");
        var sum = new double[vectors[0].Length];
        for (int i = 0; i < vectors.Count; i++)
            for (int d = 0; d < sum.Length; d++) sum[d] += (double)vectors[i][d] * scalarWeights[i];
        double squares = 0;
        foreach (var x in sum) squares += x * x;
        double norm = Math.Sqrt(squares);
        if (!double.IsFinite(norm) || norm == 0) throw new EmbeddingProfileException("invalidEmbedding");
        return sum.Select(x => (float)(x / norm)).ToArray();
    }
}
