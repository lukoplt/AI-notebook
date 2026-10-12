using System.Security.Cryptography;
using System.Text;
using AINotebook.Core.Models;

namespace AINotebook.Core.Ingestion;

/// <summary>Which chunks a background build embeds, in which order (contract <c>embedding-plan-v1</c>).</summary>
public static class EmbeddingPlan
{
    /// <summary>Stored source types embedded last and capped (<c>.xlsx</c> and <c>.xlsm</c> both store <c>xlsx</c>).</summary>
    public static readonly IReadOnlyList<SourceType> SpreadsheetTypes = [SourceType.Xlsx];

    /// <summary>A spreadsheet source embeds only its chunks with <c>ord</c> below this; the rest stay full-text only.</summary>
    public const int SpreadsheetChunkCap = 64;

    /// <summary>A round examines at most <c>RoundScanFactor × batchSize</c> candidates.</summary>
    public const int RoundScanFactor = 16;

    public static int PriorityClass(SourceType type) => SpreadsheetTypes.Contains(type) ? 1 : 0;

    /// <summary>The embed cap of a source type, null when every chunk is embedded.</summary>
    public static int? EmbedCap(SourceType type) => SpreadsheetTypes.Contains(type) ? SpreadsheetChunkCap : null;

    /// <summary>Lowercase hex SHA-256 of the exact UTF-8 bytes (no normalization): the dedup key within a generation.</summary>
    public static string TextHash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    /// <summary><c>c.ord</c> below the source's cap (aliases <c>s</c>, <c>c</c>); index-friendly on idx_chunks_revision_ord.</summary>
    internal const string EmbeddableSql = "c.ord<(CASE WHEN s.type='xlsx' THEN 64 ELSE 9223372036854775807 END)";

    /// <summary>The priority class of source row <c>s</c> as 0/1.</summary>
    internal const string ClassSql = "(s.type='xlsx')";
}

/// <summary>Keyset position of the last consumed candidate: (priority class, source id, ord).</summary>
public sealed record EmbeddingCursor(int PriorityClass, long SourceId, long Ord);

/// <summary>A captured chunk whose text equals the input <paramref name="OfChunkId"/>: it receives that vector at commit.</summary>
public sealed record EmbeddingDuplicate(long ChunkId, long RevisionId, long OfChunkId);
