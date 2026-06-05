namespace AINotebook.Core;

// ----- StoreError (verbatim LocalizedError messages from Swift StoreError) -----
public abstract class StoreException : Exception
{
    protected StoreException(string message) : base(message) { }

    public sealed class NotebookNotFound : StoreException
    {
        public long Id { get; }
        public NotebookNotFound(long id) : base($"Notebook {id} not found.") => Id = id;
    }

    public sealed class InvalidNotebookName : StoreException
    {
        public string Name { get; }
        public InvalidNotebookName(string name) : base($"Invalid notebook name: \"{name}\".") => Name = name;
    }

    public sealed class SourceNotFound : StoreException
    {
        public long Id { get; }
        public SourceNotFound(long id) : base($"Source #{id} not found.") => Id = id;
    }

    public sealed class InvalidSourceTitle : StoreException
    {
        public string Title { get; }
        public InvalidSourceTitle(string title) : base($"Invalid source title: \"{title}\".") => Title = title;
    }
}

// Note: ExtractorException, IngestionException, OllamaException, and
// TransformationException are NOT defined here. They live in their own
// (sub-)namespaces alongside the code + tests that bind to them:
//   ExtractorException      -> Task 15 (AINotebook.Core.Extractors)
//   IngestionException      -> Task 18 (AINotebook.Core.Ingestion)
//   OllamaException         -> Task 19 (AINotebook.Core.Ollama)
//   TransformationException -> Task 25 (AINotebook.Core.Rag)
// Task 2's Errors.cs owns only the cross-cutting StoreException and EmbedderException.

// ----- Embedder errors -----
public abstract class EmbedderException : Exception
{
    protected EmbedderException(string message) : base(message) { }

    public sealed class ResponseSizeMismatch : EmbedderException
    {
        public int Expected { get; }
        public int Got { get; }
        public ResponseSizeMismatch(int expected, int got)
            : base($"Embedding response size mismatch: expected {expected}, got {got}.")
        { Expected = expected; Got = got; }
    }

    public sealed class MisalignedByteCount : EmbedderException
    {
        public int ByteCount { get; }
        public MisalignedByteCount(int byteCount)
            : base($"Embedding byte count {byteCount} is not a multiple of 4.") => ByteCount = byteCount;
    }
}
