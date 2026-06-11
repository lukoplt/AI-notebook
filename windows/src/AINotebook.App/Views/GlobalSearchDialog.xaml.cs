using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace AINotebook.App.Views;

public sealed partial class GlobalSearchDialog : ContentDialog
{
    public GlobalSearchViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public string SearchPlaceholder => _t.Get(StringKey.GlobalSearchPlaceholder);

    public GlobalSearchDialog()
    {
        var sp = App.Current.Services;
        ViewModel = sp.GetRequiredService<GlobalSearchViewModel>();
        _t = sp.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        Title = _t.Get(StringKey.GlobalSearchTitle);
        SearchButton.Content = _t.Get(StringKey.GlobalSearchTitle);
        NotesSectionLabel.Text = _t.Get(StringKey.GlobalSearchSectionNotes);
        SourcesSectionLabel.Text = _t.Get(StringKey.GlobalSearchSectionSources);
        EmptyHint.Text = _t.Get(StringKey.GlobalSearchEmpty);
    }

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            ViewModel.SearchCommand.Execute(null);
            e.Handled = true;
        }
    }

    private void OnNoteHitClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: NoteSearchHit hit })
        {
            ViewModel.OpenNoteCommand.Execute(hit);
            Hide();
        }
    }
}
