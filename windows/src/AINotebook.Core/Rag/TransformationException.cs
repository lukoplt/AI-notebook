namespace AINotebook.Core.Rag;

public abstract class TransformationException : Exception
{
    protected TransformationException(string message) : base(message) { }

    public sealed class SourceNotFound : TransformationException
    {
        public long Id { get; }
        public SourceNotFound(long id) : base($"Source {id} not found.") => Id = id;
    }

    public sealed class TransformationNotFound : TransformationException
    {
        public long Id { get; }
        public TransformationNotFound(long id) : base($"Transformation {id} not found.") => Id = id;
    }

    public sealed class NoChunks : TransformationException
    {
        public long Id { get; }
        public NoChunks(long id) : base($"No chunks for {id}.") => Id = id;
    }
}
