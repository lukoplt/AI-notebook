using System.Text;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>Chunker v2: scalar spans into the unchanged canonical text.</summary>
public static class ScalarChunker
{
    public static IReadOnlyList<RevisionChunkDraft> Chunk(string text,
        IReadOnlyList<(int Offset, int Page)>? pageStarts = null, int window = 2048, int overlap = 256)
        => ChunkCore(text, pageStarts, null, int.MaxValue, window, overlap);

    public static IReadOnlyList<RevisionChunkDraft> Bounded(string text, IReadOnlyList<PageBoundary> pages,
        int maxChunks, int window = 2048, int overlap = 256)
    {
        if (maxChunks < 0) throw new FolderIngestionException("chunkLimit");
        return ChunkCore(text, null, pages, maxChunks, window, overlap);
    }

    private static IReadOnlyList<RevisionChunkDraft> ChunkCore(string text,
        IReadOnlyList<(int Offset, int Page)>? pageStarts, IReadOnlyList<PageBoundary>? pages,
        int maxChunks, int window, int overlap)
    {
        if (window <= overlap || overlap < 0) throw new ArgumentOutOfRangeException(nameof(window));
        var scalars = text.EnumerateRunes().ToArray();
        static bool Space(int value) => value is >= 9 and <= 13 or 0x20 or 0x85 or 0xA0 or 0x1680
            or 0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000 or >= 0x2000 and <= 0x200A;
        var result = new List<RevisionChunkDraft>();
        int start = 0;
        while (start < scalars.Length)
        {
            int end = (int)Math.Min((long)start + window, scalars.Length);
            if (end < scalars.Length)
            {
                int probe = end, floor = Math.Max(end - 200, start + 1);
                while (probe > floor && !Space(scalars[probe - 1].Value)) probe--;
                if (probe > floor) end = probe;
            }
            int lo = start, hi = end;
            while (lo < hi && Space(scalars[lo].Value)) lo++;
            while (hi > lo && Space(scalars[hi - 1].Value)) hi--;
            if (lo < hi)
            {
                // Reject before constructing the next chunk; never return a partial revision.
                if (result.Count == maxChunks) throw new FolderIngestionException("chunkLimit");
                int? page = null;
                if (pageStarts is not null)
                    foreach (var candidate in pageStarts)
                        if (candidate.Offset <= lo) page = candidate.Page;
                if (pages is not null)
                    foreach (var candidate in pages)
                        if (candidate.Start < candidate.End && candidate.Start < hi && candidate.End > lo)
                        {
                            page = candidate.Page;
                            break;
                        }
                string slice = string.Concat(scalars.Skip(lo).Take(hi - lo).Select(rune => rune.ToString()));
                result.Add(new(slice, Math.Max(1, (hi - lo + 3) / 4), page, lo, hi, null, false));
            }
            if (end == scalars.Length) break;
            start = Math.Max(end - overlap, start + 1);
        }
        return result;
    }
}
