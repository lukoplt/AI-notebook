using System.Collections.Generic;
using System.Linq;
using AINotebook.Core.Models;

namespace AINotebook.App.ViewModels;

public sealed class MessageViewModel
{
    public required ChatMessage Message { get; init; }
    public bool IsUser => Message.Role == ChatRole.User;
    public bool IsAssistant => Message.Role == ChatRole.Assistant;
    public string Content => Message.Content;
    public IReadOnlyList<Citation> Citations => Message.Citations;
    public bool HasCitations => Message.Citations.Count > 0;
    // streaming placeholder bubbles have no real id -> no "save as note"
    public bool CanSaveAsNote => IsAssistant && Message.Id is not null;
}
