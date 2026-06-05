using System;
using System.Collections.ObjectModel;
using System.Linq;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public sealed record TransformationRunRow(
    long Id, string TemplateName, string SourceTitle, long? NoteId, string NoteTitle, DateTime RanAt)
{
    public bool HasNote => NoteId is not null;
}

public partial class TransformationHistoryViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly TabSwitchCoordinator _tabSwitch;
    private long _notebookId;

    public ObservableCollection<TransformationRunRow> Rows { get; } = new();
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    public event Action? RequestClose;

    public TransformationHistoryViewModel(NotebookStore store, NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch)
    { _store = store; _noteJump = noteJump; _tabSwitch = tabSwitch; }

    public void Load(long notebookId)
    {
        _notebookId = notebookId;
        try
        {
            var runs = _store.TransformationRuns();
            var txById = _store.Transformations().Where(t => t.Id is not null).ToDictionary(t => t.Id!.Value);
            var notesById = _store.Notes(notebookId).Where(n => n.Id is not null).ToDictionary(n => n.Id!.Value);
            var srcById = _store.SourcesIncludingShadow(notebookId).Where(s => s.Id is not null).ToDictionary(s => s.Id!.Value);

            Rows.Clear();
            foreach (var run in runs)
            {
                if (run.Id is not { } runId) continue;
                Note? note = run.ResultNoteId is { } rid && notesById.TryGetValue(rid, out var nn) ? nn : null;
                Source? src = run.SourceId is { } sid && srcById.TryGetValue(sid, out var ss) ? ss : null;
                var belongs = note?.NotebookId == notebookId || src?.NotebookId == notebookId;
                if (!belongs) continue;
                var txName = txById.TryGetValue(run.TransformationId, out var tx) ? tx.Name : "(unknown)";
                var srcTitle = src?.Title ?? (run.SourceId is null ? "(notebook scope)" : "(deleted)");
                Rows.Add(new TransformationRunRow(runId, txName, srcTitle, note?.Id, note?.Title ?? "(deleted)", run.RanAt));
            }
            foreach (var r in Rows.OrderByDescending(r => r.RanAt).ToList())
            { Rows.Remove(r); Rows.Add(r); }   // stable newest-first
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    public async System.Threading.Tasks.Task JumpAsync(TransformationRunRow row)
    {
        if (row.NoteId is not { } nid) return;
        RequestClose?.Invoke();
        _tabSwitch.Request(TabSwitchCoordinator.Tab.Notes);
        await System.Threading.Tasks.Task.Delay(50);
        _noteJump.Request(nid);
    }
}
