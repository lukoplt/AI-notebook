namespace AINotebook.Core.Ingestion;

/// <summary>
/// Maps a persisted ingestion error code (sources.error, ingest_jobs.error) to the camelCase resw key of
/// the localized explanation shown next to the "Error" status. Same table as macOS IngestionErrorText
/// (fixture: ingestion-ooxml-v1.json "error-text"). Null: no specific explanation.
/// </summary>
public static class IngestionErrorText
{
    public static string? KeyName(string? code) => code switch
    {
        "missingMainPart" or "invalidRelationship" => "sourceErrorMissingPart",
        "corruptArchive" => "sourceErrorDamaged",
        "notDownloaded" => "sourceErrorNotDownloaded",
        "fileLimit" or "officeLimit" or "textLimit" or "pageLimit" or "chunkLimit" or "cellLimit" => "folderLimitError",
        "unsupportedEncoding" => "folderEncodingError",
        "invalidCell" or "unsupportedSyntax" => "folderDocumentError",
        "outsideRoot" or "interiorLink" or "rootUnavailable" => "folderReadError",
        _ => null
    };
}
