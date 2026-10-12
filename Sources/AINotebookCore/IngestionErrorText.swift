/// Maps a persisted ingestion error code (`sources.error`, `ingest_jobs.error`)
/// to the localized explanation shown next to the "Error" status. Same table as
/// Windows `IngestionErrorText` (fixture: ingestion-ooxml-v1.json "error-text").
/// Nil: no specific explanation; the row shows the plain status.
public enum IngestionErrorText {
    public static func key(for code: String?) -> AppText.Key? {
        switch code {
        case "missingMainPart", "invalidRelationship": return .sourceErrorMissingPart
        case "corruptArchive": return .sourceErrorDamaged
        case "notDownloaded": return .sourceErrorNotDownloaded
        case "fileLimit", "officeLimit", "textLimit", "pageLimit", "chunkLimit", "cellLimit": return .folderLimitError
        case "unsupportedEncoding": return .folderEncodingError
        case "invalidCell", "unsupportedSyntax": return .folderDocumentError
        case "outsideRoot", "interiorLink", "rootUnavailable": return .folderReadError
        default: return nil
        }
    }
}
