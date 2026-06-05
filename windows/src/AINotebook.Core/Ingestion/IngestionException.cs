namespace AINotebook.Core.Ingestion;

/// <summary>Port of IngestionService.IngestionError.</summary>
public abstract class IngestionException : Exception
{
    protected IngestionException(string message) : base(message) { }

    public sealed class UnsupportedExtension : IngestionException
    {
        public string Extension { get; }
        public UnsupportedExtension(string extension)
            : base($"Unsupported extension: {extension}") => Extension = extension;
    }
}
