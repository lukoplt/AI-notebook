namespace AINotebook.Core.Ollama;

public abstract class OllamaException : Exception
{
    protected OllamaException(string message) : base(message) { }

    public sealed class NotReachable : OllamaException
    {
        public NotReachable() : base("Ollama daemon is not reachable on localhost:11434.") { }
    }

    public sealed class Timeout : OllamaException
    {
        public Timeout() : base("Ollama request timed out.") { }
    }

    public sealed class HttpStatus : OllamaException
    {
        public int Code { get; }
        public string Body { get; }
        public HttpStatus(int code, string body) : base($"Ollama returned HTTP {code}.")
        {
            Code = code;
            Body = body;
        }
    }

    public sealed class Decoding : OllamaException
    {
        public string DecodeMessage { get; }
        public Decoding(string message) : base($"Failed to decode Ollama response: {message}.")
        {
            DecodeMessage = message;
        }
    }

    public sealed class ModelNotFound : OllamaException
    {
        public string Name { get; }
        public ModelNotFound(string name) : base($"Ollama model \"{name}\" is not pulled.")
        {
            Name = name;
        }
    }

    public sealed class UnexpectedEndOfStream : OllamaException
    {
        public UnexpectedEndOfStream() : base("Ollama stream ended before completion.") { }
    }

    public sealed class Cancelled : OllamaException
    {
        public Cancelled() : base("Ollama request was cancelled.") { }
    }
}
