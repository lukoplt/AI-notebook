using System;
using System.Collections.ObjectModel;
using System.Linq;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public partial class TransformationEditorViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _t;
    public event Action? Changed;   // host reloads the parent list

    public ObservableCollection<Transformation> Customs { get; } = new();
    [ObservableProperty] public partial Transformation? Selected { get; set; }
    [ObservableProperty] public partial string DraftName { get; set; } = "";
    [ObservableProperty] public partial string DraftDescription { get; set; } = "";
    [ObservableProperty] public partial string DraftTemplate { get; set; } = "";
    [ObservableProperty] public partial TransformationScope DraftScope { get; set; } = TransformationScope.Source;
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public TransformationEditorViewModel(NotebookStore store, ILocalizedStrings t) { _store = store; _t = t; }

    public void Reload()
    {
        try
        {
            var prev = Selected?.Id;
            Customs.Clear();
            foreach (var tx in _store.Transformations().Where(x => !x.IsBuiltin)) Customs.Add(tx);
            Selected = Customs.FirstOrDefault(x => x.Id == prev) ?? Customs.FirstOrDefault();
            SyncDraft();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    partial void OnSelectedChanged(Transformation? v) => SyncDraft();

    private void SyncDraft()
    {
        DraftName = Selected?.Name ?? "";
        DraftTemplate = Selected?.PromptTemplate ?? "";
        DraftScope = Selected?.Scope ?? TransformationScope.Source;
        DraftDescription = Selected?.Description ?? "";
    }

    [RelayCommand]
    private void CreateBlank()
    {
        try
        {
            var tx = _store.CreateTransformation("Untitled", "{{source_text}}", TransformationScope.Source, false);
            Reload();
            Selected = Customs.FirstOrDefault(x => x.Id == tx.Id);
            Changed?.Invoke();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    [RelayCommand]
    private void Save()
    {
        if (Selected?.Id is not { } id) return;
        try
        {
            _store.UpdateTransformation(id, DraftName, DraftTemplate, DraftDescription);
            _store.UpdateTransformationScope(id, DraftScope);
            Reload();
            Changed?.Invoke();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    [RelayCommand]
    private void Delete()
    {
        if (Selected?.Id is not { } id) return;
        try { _store.DeleteTransformation(id); Selected = null; Reload(); Changed?.Invoke(); }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }
}
