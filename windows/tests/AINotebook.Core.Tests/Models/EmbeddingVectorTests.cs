using Xunit;
using AINotebook.Core;
using AINotebook.Core.Models;

namespace AINotebook.Core.Tests.Models;

public class EmbeddingVectorTests
{
    // EmbeddingVector: testRoundTripsThroughData
    [Fact]
    public void RoundTrips_Through_Bytes()
    {
        var values = new float[] { 0.1f, -0.2f, 3.14f, -42.0f };
        var vec = new EmbeddingVector(values);

        byte[] bytes = vec.ToBytes();
        Assert.Equal(16, bytes.Length); // 4 floats x 4 bytes

        var decoded = EmbeddingVector.FromBytes(bytes);
        Assert.Equal(values, decoded.Values);
        Assert.Equal(4, decoded.Dim);
    }

    // EmbeddingVector: testRejectsMisalignedData
    [Fact]
    public void Rejects_Misaligned_Bytes()
    {
        var ex = Assert.Throws<EmbedderException.MisalignedByteCount>(
            () => EmbeddingVector.FromBytes(new byte[] { 0, 1, 2 }));
        Assert.Equal(3, ex.ByteCount);
    }

    // EmbeddingVector: testDimReportsCount
    [Fact]
    public void Dim_Reports_Count()
    {
        var values = new float[768];
        var vec = new EmbeddingVector(values);
        Assert.Equal(768, vec.Dim);
    }

    [Fact]
    public void ToBytes_Is_LittleEndian_Float32()
    {
        // 1.0f in IEEE-754 little-endian is 00 00 80 3F.
        var vec = new EmbeddingVector(new[] { 1.0f });
        byte[] bytes = vec.ToBytes();
        Assert.Equal(new byte[] { 0x00, 0x00, 0x80, 0x3F }, bytes);
    }

    [Fact]
    public void FromBytes_Reads_LittleEndian_Float32()
    {
        // Bytes for -0.0506f (approx) come from the production sample "715D4FBD".
        var bytes = new byte[] { 0x71, 0x5D, 0x4F, 0xBD };
        var vec = EmbeddingVector.FromBytes(bytes);
        Assert.Single(vec.Values);
        Assert.Equal(-0.0506f, vec.Values[0], 3); // 3 decimal places of tolerance
    }
}
