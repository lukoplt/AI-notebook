namespace AINotebook.App.Services;

/// Holds the current ChatEngine so it can be swapped (e.g. when the chat model
/// changes in Settings) without re-resolving consumers.
public sealed class ChatEngineHolder
{
    public AINotebook.Core.Rag.ChatEngine Engine { get; set; }
    public ChatEngineHolder(AINotebook.Core.Rag.ChatEngine engine) => Engine = engine;
}
