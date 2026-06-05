namespace AINotebook.App.Services;

/// Holds the current TransformationEngine so it can be swapped (e.g. when the
/// chat model changes in Settings) without re-resolving consumers.
public sealed class TransformationEngineHolder
{
    public AINotebook.Core.Rag.TransformationEngine Engine { get; set; }
    public TransformationEngineHolder(AINotebook.Core.Rag.TransformationEngine engine) => Engine = engine;
}
