namespace AINotebook.Core.Ingestion;

/// <summary>
/// The bounded extractor's behavioural revision (contract <c>ingestion-reextract-v1</c>, same values as macOS
/// <c>ExtractorRevision</c>). Bump <see cref="Current"/> whenever an extractor fix may turn a former failure into a
/// publication for unchanged bytes, and adjust <see cref="RetryableCodes"/> to the failures that fix can resolve.
/// Revision 2: real-world OOXML packages and ZIP layouts are accepted.
/// </summary>
public static class ExtractorRevision
{
    public const int Current = 2;

    /// <summary><c>ingest_jobs.options_json</c> key recording the revision an upgrade requeue ran under.</summary>
    public const string OptionsKey = "extractorRevision";

    /// <summary>Terminal failure codes a newer extractor may resolve, in scalar order.</summary>
    public static readonly IReadOnlyList<string> RetryableCodes =
        ["corruptArchive", "invalidCell", "invalidRelationship", "missingMainPart", "unexpectedError"];

    /// <summary>Options of an upgrade-requeue extract job.</summary>
    internal static string OptionsJson => "{\"" + OptionsKey + "\":" + Current.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}";

    /// <summary><c>text_format_version</c> of the current spreadsheet canonical text (<c>ingestion-xlsx-v2</c>). Ready
    /// folder spreadsheets published under an older format are re-extracted once (<c>ingestion-reextract-v1</c> §7,
    /// fixture <c>ingestion-reextract-v2</c>).</summary>
    public const int SpreadsheetTextVersion = SpreadsheetText.FormatVersion;

    /// <summary><c>ingest_jobs.options_json</c> key recording the spreadsheet text version an upgrade job was queued for.</summary>
    public const string SpreadsheetOptionsKey = "spreadsheetTextVersion";

    /// <summary>At most this many spreadsheet upgrade jobs are unfinished at any time.</summary>
    public const int SpreadsheetBatchSize = 8;

    /// <summary>Options of a spreadsheet-upgrade extract job.</summary>
    internal static string SpreadsheetOptionsJson => "{\"" + SpreadsheetOptionsKey + "\":" +
        SpreadsheetTextVersion.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}";
}
