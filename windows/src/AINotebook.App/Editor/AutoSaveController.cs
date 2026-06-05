using System;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.Editor;

public enum SaveState { Saved, Unsaved, Saving, Error }

public partial class AutoSaveController : ObservableObject
{
    private readonly Action<string> _save;
    private readonly DispatcherQueueTimer _timer;
    private string? _pendingBody;

    [ObservableProperty] public partial SaveState Status { get; private set; } = SaveState.Saved;
    [ObservableProperty] public partial string? ErrorText { get; private set; }

    public AutoSaveController(DispatcherQueue dispatcher, Action<string> save, int debounceMillis = 2000)
    {
        _save = save;
        _timer = dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(debounceMillis);
        _timer.IsRepeating = false;
        _timer.Tick += (_, _) => Flush();
    }

    public void NoteDidChange(string markdown)
    {
        _pendingBody = markdown;       // last-write-wins
        Status = SaveState.Unsaved;
        _timer.Stop();
        _timer.Start();
    }

    public void ManualSave()
    {
        _timer.Stop();
        Flush();
    }

    private void Flush()
    {
        if (_pendingBody is not { } body) return;
        Status = SaveState.Saving;
        try
        {
            _save(body);
            _pendingBody = null;
            Status = SaveState.Saved;
            ErrorText = null;
        }
        catch (Exception ex)
        {
            ErrorText = ex.Message;
            Status = SaveState.Error;
        }
    }

    public bool HasUnsavedChanges => Status is SaveState.Unsaved or SaveState.Saving;
}
