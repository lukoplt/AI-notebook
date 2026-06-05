using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public enum BatchScope { Source, Notebook, AllSources }

public partial class TransformationsViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly TransformationEngineHolder _engineHolder;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly ILocalizedStrings _t;
    private readonly DispatcherQueue _dispatcher;
    private long _notebookId;

    public ObservableCollection<Transformation> Transformations { get; } = new();
    public ObservableCollection<Source> Sources { get; } = new();

    [ObservableProperty] public partial Transformation? SelectedTransformation { get; set; }
    [ObservableProperty] public partial Source? SelectedSource { get; set; }
    [ObservableProperty] public partial BatchScope Scope { get; set; } = BatchScope.Source;
    [ObservableProperty] public partial string ResultBody { get; set; } = "";
    [ObservableProperty] public partial long? ResultNoteId { get; set; }
    [ObservableProperty] public partial int BatchCompleted { get; set; }
    [ObservableProperty] public partial int BatchTotal { get; set; }
    [ObservableProperty] public partial int? BatchSavedCount { get; set; }
    [ObservableProperty] public partial bool Running { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public TransformationsViewModel(
        NotebookStore store, TransformationEngineHolder engineHolder,
        NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch,
        ILocalizedStrings t, DispatcherQueue dispatcher)
    {
        _store = store; _engineHolder = engineHolder;
        _noteJump = noteJump; _tabSwitch = tabSwitch; _t = t; _dispatcher = dispatcher;
    }

    public string? SelectedTransformationDescription =>
        string.IsNullOrEmpty(SelectedTransformation?.Description) ? null : SelectedTransformation!.Description;

    partial void OnSelectedTransformationChanged(Transformation? value)
    {
        if (value is { } tx) Scope = tx.Scope == TransformationScope.Notebook ? BatchScope.Notebook : BatchScope.Source;
        RunCommand.NotifyCanExecuteChanged();
    }
    partial void OnSelectedSourceChanged(Source? v) => RunCommand.NotifyCanExecuteChanged();
    partial void OnScopeChanged(BatchScope v) => RunCommand.NotifyCanExecuteChanged();
    partial void OnRunningChanged(bool v) => RunCommand.NotifyCanExecuteChanged();

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        await ReloadAsync();
    }

    public async Task ReloadAsync()
    {
        try
        {
            var prevTx = SelectedTransformation?.Id;
            var prevSrc = SelectedSource?.Id;
            Transformations.Clear();
            foreach (var tx in _store.Transformations()) Transformations.Add(tx);
            Sources.Clear();
            foreach (var s in _store.Sources(_notebookId)) Sources.Add(s);

            SelectedTransformation = Transformations.FirstOrDefault(x => x.Id == prevTx)
                ?? Transformations.FirstOrDefault();
            SelectedSource = Sources.FirstOrDefault(x => x.Id == prevSrc) ?? Sources.FirstOrDefault();
            if (SelectedTransformation?.Scope == TransformationScope.Notebook) Scope = BatchScope.Notebook;
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        await Task.CompletedTask;
    }

    private bool CanRun =>
        !Running
        && SelectedTransformation is not null
        && !(Scope == BatchScope.Source && SelectedSource is null)
        && !(Scope == BatchScope.AllSources && Sources.Count == 0);

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task RunAsync()
    {
        if (SelectedTransformation?.Id is not { } tid) return;
        Running = true; ErrorMessage = null;
        ResultBody = ""; ResultNoteId = null;
        BatchSavedCount = null; BatchCompleted = 0; BatchTotal = 0;
        var engine = _engineHolder.Engine;
        try
        {
            switch (Scope)
            {
                case BatchScope.Source:
                    if (SelectedSource?.Id is not { } sid) return;
                    var note = await engine.RunAsync(tid, sid,
                        onToken: tok => _dispatcher.TryEnqueue(() => ResultBody += tok));
                    ResultNoteId = note.Id;
                    break;
                case BatchScope.Notebook:
                    var nbNote = await engine.RunNotebookScopeAsync(tid, _notebookId,
                        onToken: tok => _dispatcher.TryEnqueue(() => ResultBody += tok));
                    ResultNoteId = nbNote.Id;
                    break;
                case BatchScope.AllSources:
                    BatchTotal = Sources.Count;
                    var notes = await engine.RunOnAllSourcesAsync(tid, _notebookId,
                        onProgress: (done, total) => _dispatcher.TryEnqueue(() =>
                        {
                            BatchCompleted = done; BatchTotal = total;
                        }));
                    BatchSavedCount = notes.Count;
                    break;
            }
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        finally { Running = false; }
    }

    // Open the resulting note: switch to Notes tab then jump (mirrors the 50ms delay).
    [RelayCommand]
    private async Task OpenResultNoteAsync()
    {
        _tabSwitch.Request(TabSwitchCoordinator.Tab.Notes);
        if (ResultNoteId is { } nid)
        {
            await Task.Delay(50);
            _noteJump.Request(nid);
        }
    }

    public string ResultSavedTitle()
    {
        if (ResultNoteId is { } nid)
        {
            var title = _store.Note(nid)?.Title ?? "";
            return string.Format(_t.Get("aiToolsResultSavedFormat"), title);
        }
        return "";
    }

    public string RunningFormat() => string.Format(_t.Get("aiToolsRunningFormat"), BatchCompleted, BatchTotal);
    public string BatchSavedFormat() => string.Format(_t.Get("aiToolsBatchSavedFormat"), BatchSavedCount ?? 0);
}
