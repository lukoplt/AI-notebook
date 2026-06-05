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
    public bool IsUser => Message.Role == ChatRole.User;
    public bool IsAssistant => Message.Role == ChatRole.Assistant;
    public string Content => Message.Content;
    public IReadOnlyList<Citation> Citations => Message.Citations;
    public bool HasCitations => Message.Citations.Count > 0;
    // streaming placeholder bubbles have no real id -> no "save as note"
    public bool CanSaveAsNote => IsAssistant && Message.Id is not null;
}
