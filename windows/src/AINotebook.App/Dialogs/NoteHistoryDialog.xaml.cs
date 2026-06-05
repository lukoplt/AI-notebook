using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Dialogs;

public sealed partial class NoteHistoryDialog : ContentDialog
{
    public NoteHistoryViewModel ViewModel { get; }

    public NoteHistoryDialog(long noteId)
    {
        ViewModel = App.Current.Services.GetRequiredService<NoteHistoryViewModel>();
        var t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        Title = t.Get("historySheetTitle");
        CloseButtonText = t.Get("cancelButton");
        RestoreButton.Content = t.Get("historyRestoreButton");
        ViewModel.RequestClose += Hide;
        ViewModel.Load(noteId);
    }
}
