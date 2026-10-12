using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// Converts pinned chunk references into complete evidence. The whole batch runs
/// under one operation borrow, so closing the owning snapshot mid-hydration cannot
/// let WP3 GC remove revisions that are still being copied.
/// </summary>
public sealed class EvidenceHydrator(RetrievalReadStore reader)
{
    private const int SnippetScalars = 240;
    private readonly RetrievalReadStore _reader = reader ?? throw new ArgumentNullException(nameof(reader));

    /// <summary>
    /// Direct passages follow input order (deduplicated by chunk ID). Neighbours come
    /// from the captured published revision, follow their centers in input order and
    /// then ord/chunk order, are deduplicated, and never repeat a direct hit.
    /// </summary>
    public IReadOnlyList<EvidencePassage> Hydrate(ResolvedRetrievalScope snapshot,
        IReadOnlyList<ChunkReference> references, int neighborRadius = 1)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(references);
        if (neighborRadius < 0) throw new RetrievalException("invalidRadius");
        using var operation = snapshot.AcquireOperation();
        return Hydrate(operation, references, neighborRadius);
    }

    internal IReadOnlyList<EvidencePassage> Hydrate(RetrievalOperation operation,
        IReadOnlyList<ChunkReference> references, int neighborRadius)
    {
        if (neighborRadius < 0) throw new RetrievalException("invalidRadius");
        var direct = Deduplicate(references);
        if (direct.Count == 0) return Array.Empty<EvidencePassage>();
        // The reader validates every requested identity before returning any row;
        // revoked or unpinned sources simply produce no row.
        var directRows = _reader.EvidenceRows(operation, direct);
        var directIds = direct.Select(r => r.ChunkId).ToHashSet();
        var neighbours = new List<ChunkReference>();
        if (neighborRadius > 0)
        {
            var seen = new HashSet<long>(directIds);
            foreach (var row in directRows)
                foreach (var neighbour in _reader.NeighbourReferences(operation, row.Reference, neighborRadius))
                    if (seen.Add(neighbour.ChunkId)) neighbours.Add(neighbour);
        }
        var neighbourRows = neighbours.Count == 0 ? Array.Empty<ChunkEvidenceRow>() : _reader.EvidenceRows(operation, neighbours);
        // All text is sliced outside the store gate; one scalar index per revision text.
        var indexes = new Dictionary<long, int[]>();
        var result = new List<EvidencePassage>(directRows.Count + neighbourRows.Count);
        foreach (var row in directRows) result.Add(Passage(row, false, indexes));
        foreach (var row in neighbourRows) result.Add(Passage(row, true, indexes));
        return result;
    }

    public static EvidencePassage Passage(ChunkEvidenceRow row, bool isNeighbour)
    {
        ArgumentNullException.ThrowIfNull(row);
        return Passage(row, isNeighbour, null);
    }

    private static EvidencePassage Passage(ChunkEvidenceRow row, bool isNeighbour, Dictionary<long, int[]>? indexes)
    {
        string text;
        IReadOnlyList<CitationSpan> spans;
        if (row.ChunkerVersion == 1 && row.CharStart is null && row.CharEnd is null)
        {
            // Legacy chunks stay whole and carry no mergeable span.
            text = row.ChunkText;
            spans = Array.Empty<CitationSpan>();
        }
        else
        {
            int[] offsets;
            if (indexes is null) offsets = ScalarOffsets(row.CanonicalText);
            else if (!indexes.TryGetValue(row.Reference.RevisionId, out offsets!))
                indexes.Add(row.Reference.RevisionId, offsets = ScalarOffsets(row.CanonicalText));
            int scalarCount = offsets.Length - 1;
            if (row.CharStart is not int start || row.CharEnd is not int end || start < 0 || end <= start || end > scalarCount)
                throw new RetrievalException("invalidSpan");
            text = row.CanonicalText.Substring(offsets[start], offsets[end] - offsets[start]);
            // Page hints claim only the stored hint; never fabricate page ranges.
            spans = new[] { new CitationSpan(start, end, row.PageHint, row.PageHint) };
        }
        return new(row.Reference, text, Snippet(text), spans, isNeighbour);
    }

    /// <summary>UTF-16 offset of every Unicode scalar boundary (count + 1 entries).</summary>
    private static int[] ScalarOffsets(string text)
    {
        var offsets = new List<int>(text.Length + 1);
        int index = 0;
        while (index < text.Length)
        {
            offsets.Add(index);
            Rune.DecodeFromUtf16(text.AsSpan(index), out _, out int consumed);
            index += Math.Max(consumed, 1);
        }
        offsets.Add(text.Length);
        return offsets.ToArray();
    }

    private static string Snippet(string text)
    {
        int index = 0, scalars = 0;
        while (index < text.Length && scalars < SnippetScalars)
        {
            Rune.DecodeFromUtf16(text.AsSpan(index), out _, out int consumed);
            index += Math.Max(consumed, 1);
            scalars++;
        }
        return index == text.Length ? text : text[..index];
    }

    private static List<ChunkReference> Deduplicate(IReadOnlyList<ChunkReference> references)
    {
        var byId = new Dictionary<long, ChunkReference>();
        var ordered = new List<ChunkReference>(references.Count);
        foreach (var reference in references)
        {
            ArgumentNullException.ThrowIfNull(reference);
            if (byId.TryGetValue(reference.ChunkId, out var previous))
            {
                if (previous.SourceId != reference.SourceId || previous.RevisionId != reference.RevisionId)
                    throw new RetrievalException("revisionMismatch");
                continue;
            }
            byId.Add(reference.ChunkId, reference);
            ordered.Add(reference);
        }
        return ordered;
    }
}
