import Foundation

/// The bounded extractor's behavioural revision (contract `ingestion-reextract-v1`,
/// same values as Windows `ExtractorRevision`). Bump `current` whenever an
/// extractor fix may turn a former failure into a publication for unchanged
/// bytes, and adjust `retryableCodes` to the failures that fix can resolve.
/// Revision 2: real-world OOXML packages and ZIP layouts are accepted.
public enum ExtractorRevision {
    public static let current = 2
    /// `ingest_jobs.options_json` key recording the revision an upgrade requeue ran under.
    public static let optionsKey = "extractorRevision"
    /// Terminal failure codes a newer extractor may resolve, in scalar order.
    public static let retryableCodes = ["corruptArchive", "invalidCell", "invalidRelationship", "missingMainPart",
                                        "unexpectedError"]

    /// Options of an upgrade-requeue extract job.
    static var optionsJSON: String { "{\"\(optionsKey)\":\(current)}" }

    /// `text_format_version` of the current spreadsheet canonical text (`ingestion-xlsx-v2`).
    /// Ready folder spreadsheets published under an older format are re-extracted once
    /// (`ingestion-reextract-v1` §7, fixture `ingestion-reextract-v2`).
    public static let spreadsheetTextVersion = SpreadsheetText.formatVersion
    /// `ingest_jobs.options_json` key recording the spreadsheet text version an upgrade job was queued for.
    public static let spreadsheetOptionsKey = "spreadsheetTextVersion"
    /// At most this many spreadsheet upgrade jobs are unfinished at any time.
    public static let spreadsheetBatchSize = 8

    /// Options of a spreadsheet-upgrade extract job.
    static var spreadsheetOptionsJSON: String { "{\"\(spreadsheetOptionsKey)\":\(spreadsheetTextVersion)}" }
}
