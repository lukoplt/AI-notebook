namespace AINotebook.Core.Rag;

/// <summary>
/// Cosine similarity in [-1, 1]. Returns 0 when either input is zero-magnitude
/// or the dimensions don't match. 1:1 port of Sources/AINotebookCore/Cosine.swift.
/// </summary>
public static class Cosine
{
    public static float Similarity(float[] a, float[] b)
    {
        if (a.Length != b.Length || a.Length == 0)
        {
            return 0f;
        }

        float dot = 0f;
        float magA = 0f;
        float magB = 0f;
        for (int i = 0; i < a.Length; i++)
        {
            dot += a[i] * b[i];
            magA += a[i] * a[i];
            magB += b[i] * b[i];
        }

        float denom = MathF.Sqrt(magA) * MathF.Sqrt(magB);
        if (denom <= 0f)
        {
            return 0f;
        }

        return dot / denom;
    }
}
