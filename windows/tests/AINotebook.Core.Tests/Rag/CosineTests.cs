using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class CosineTests
{
    private const float Tol = 1e-5f;

    [Fact]
    public void IdenticalVectorsScoreOne()
    {
        float[] a = { 0.1f, 0.2f, 0.3f, 0.4f };
        Assert.Equal(1.0f, Cosine.Similarity(a, a), Tol);
    }

    [Fact]
    public void OrthogonalVectorsScoreZero()
    {
        float[] a = { 1, 0, 0, 0 };
        float[] b = { 0, 1, 0, 0 };
        Assert.Equal(0.0f, Cosine.Similarity(a, b), Tol);
    }

    [Fact]
    public void OppositeVectorsScoreMinusOne()
    {
        float[] a = { 1, 2, 3 };
        float[] b = { -1, -2, -3 };
        Assert.Equal(-1.0f, Cosine.Similarity(a, b), Tol);
    }

    [Fact]
    public void ZeroMagnitudeReturnsZero()
    {
        float[] a = { 0, 0, 0 };
        float[] b = { 1, 2, 3 };
        Assert.Equal(0.0f, Cosine.Similarity(a, b), Tol);
    }

    [Fact]
    public void MismatchedDimensionsReturnsZero()
    {
        float[] a = { 1, 2, 3 };
        float[] b = { 1, 2 };
        Assert.Equal(0.0f, Cosine.Similarity(a, b), Tol);
    }
}
