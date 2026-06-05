using System.Runtime.InteropServices;

namespace AINotebook.Core.Models;

/// <summary>
/// A float32 embedding vector. ToBytes/FromBytes reproduce Swift
/// EmbeddingVector.asData()/init(data:) exactly: a raw contiguous little-endian
/// IEEE-754 float32 blob with no header, no length prefix, and no dimension field.
/// byte_count == Dim * 4; FromBytes requires byte_count % 4 == 0.
/// </summary>
public sealed class EmbeddingVector : IEquatable<EmbeddingVector>
{
    public float[] Values { get; }

    public int Dim => Values.Length;

    public EmbeddingVector(float[] values)
    {
        Values = values ?? throw new ArgumentNullException(nameof(values));
    }

    public byte[] ToBytes()
    {
        var bytes = new byte[Values.Length * sizeof(float)];
        MemoryMarshal.AsBytes(Values.AsSpan()).CopyTo(bytes);
        if (!BitConverter.IsLittleEndian)
        {
            for (int i = 0; i < bytes.Length; i += sizeof(float))
                Array.Reverse(bytes, i, sizeof(float));
        }
        return bytes;
    }

    public static EmbeddingVector FromBytes(byte[] data)
    {
        if (data is null) throw new ArgumentNullException(nameof(data));
        if (data.Length % sizeof(float) != 0)
            throw new EmbedderException.MisalignedByteCount(data.Length);

        int count = data.Length / sizeof(float);
        var values = new float[count];

        if (BitConverter.IsLittleEndian)
        {
            MemoryMarshal.Cast<byte, float>(data).CopyTo(values);
        }
        else
        {
            for (int i = 0; i < count; i++)
            {
                int offset = i * sizeof(float);
                values[i] = BitConverter.Int32BitsToSingle(
                    BitConverter.ToInt32(new[]
                    {
                        data[offset + 3], data[offset + 2], data[offset + 1], data[offset]
                    }, 0));
            }
        }

        return new EmbeddingVector(values);
    }

    public bool Equals(EmbeddingVector? other) =>
        other is not null && Values.AsSpan().SequenceEqual(other.Values);

    public override bool Equals(object? obj) => Equals(obj as EmbeddingVector);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var v in Values) hash.Add(v);
        return hash.ToHashCode();
    }
}

public record StoredEmbedding(
    long ChunkId,
    long SourceId,
    EmbeddingVector Vector);
