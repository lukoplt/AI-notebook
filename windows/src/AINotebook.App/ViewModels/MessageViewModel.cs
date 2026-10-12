using System.Collections.Generic;
using System.Linq;
using AINotebook.Core.Models;

namespace AINotebook.App.ViewModels;

public sealed class MessageViewModel
{
    // Not 'required': the WinUI XamlTypeInfo generator emits a parameterless
    // activator for every app type used as an x:DataType, and a required member
    // makes that generated 'new MessageViewModel()' fail to compile (CS9035).
    // The activator is never actually invoked for a data-template DataType; our
    // own call sites always set Message via the object initializer.
    public ChatMessage Message { get; init; } = null!;
    /// <summary>The thread's latest user message (offers "Edit").</summary>
    public bool IsLatestUser { get; init; }
    /// <summary>The thread's latest answer (offers "Regenerate"; its actions stay visible).</summary>
    public bool IsLatestAssistant { get; init; }
    /// <summary>An answer the user stopped mid-stream (shows "Stopped" under it).</summary>
    public bool IsStopped { get; init; }
    public bool IsUser => Message.Role == ChatRole.User;
    public bool IsAssistant => Message.Role == ChatRole.Assistant;
    public string Content => Message.Content;
    public IReadOnlyList<Citation> Citations => Message.Citations;
    public bool HasCitations => Message.Citations.Count > 0;
    // streaming placeholder bubbles have no real id -> no "save as note"
    public bool CanSaveAsNote => IsAssistant && Message.Id is not null;
    // WP8: sent previews are retained in memory by the persisted assistant ID only.
    public bool CanPreviewContext => IsAssistant && Message.Id is not null;
}
