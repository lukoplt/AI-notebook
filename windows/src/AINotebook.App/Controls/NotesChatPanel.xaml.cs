using System;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace AINotebook.App.Controls;

public sealed partial class NotesChatPanel : UserControl
{
    public NotesChatPanelViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public NotesChatPanel()
    {
        ViewModel = App.Current.Services.GetRequiredService<NotesChatPanelViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        PanelTitle.Text = _t.Get("notesChatPanelTitle");
        EmptyState.Text = _t.Get("notesChatPanelEmpty");
        InputBox.PlaceholderText = _t.Get("chatInputPlaceholder");

        ViewModel.Messages.CollectionChanged += (_, _) => ScrollToBottom();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotesChatPanelViewModel.StreamingDraft)) ScrollToBottom();
            if (e.PropertyName == nameof(NotesChatPanelViewModel.ErrorMessage))
                ErrorText.Text = (ViewModel.ErrorMessage is null) ? "" : _t.Get("chatErrorPrefix") + ViewModel.ErrorMessage;
        };
    }

    // Called by NotesPage once the notebook is known.
    public async System.Threading.Tasks.Task LoadAsync(long notebookId) => await ViewModel.LoadAsync(notebookId);

    // NotesPage pushes the live current note so chat context tracks the open note.
    public void SetCurrentNoteProvider(Func<Note?> provider)
    {
        ViewModel.CurrentNoteProvider = provider;
        RefreshCurrentNoteHint();
    }

    private void RefreshCurrentNoteHint()
    {
        if (ViewModel.HasCurrentNote)
        {
            CurrentNoteHint.Text = _t.Get("notesChatCurrentNoteHint");
            CurrentNoteHint.Visibility = Visibility.Visible;
        }
        else
        {
            CurrentNoteHint.Visibility = Visibility.Collapsed;
        }
    }

    private void ScrollToBottom() => MessagesScroller.ChangeView(null, MessagesScroller.ScrollableHeight, null);

    private void OnSendAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        RefreshCurrentNoteHint();
        if (ViewModel.SendCommand.CanExecute(null)) ViewModel.SendCommand.Execute(null);
        args.Handled = true;
    }

    private void OnSaveAsNote(object? sender, MessageViewModel vm) =>
        ViewModel.SaveAsNoteCommand.Execute(vm);

    private void OnCitationTapped(object? sender, Citation c)
    {
        if (sender is not FrameworkElement anchor) return;
        var cvm = ViewModel.BuildCitationViewModel(c);
        ShowCitationFlyout(anchor, cvm);
    }

    private void ShowCitationFlyout(FrameworkElement anchor, CitationViewModel cvm)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        header.Children.Add(new FontIcon { Glyph = "" }); // quote-ish glyph
        header.Children.Add(new TextBlock { Text = cvm.SourceTitle, Style = (Style)Application.Current.Resources["BaseTextBlockStyle"] });

        if (cvm.PageHint is int page && cvm.PdfFilePath is { } path)
        {
            var openBtn = new HyperlinkButton { Content = $"Open page {page}" };
            openBtn.Click += async (_, _) =>
                await Launcher.LaunchUriAsync(new Uri(new Uri("file://"), path));
            header.Children.Add(openBtn);
        }

        var snippet = new ScrollViewer
        {
            MaxHeight = 240,
            Content = new TextBlock { Text = cvm.Snippet, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
        };
        var panel = new StackPanel { Width = 380, Spacing = 8 };
        panel.Children.Add(header);
        panel.Children.Add(snippet);

        var flyout = new Flyout { Content = panel };
        flyout.ShowAt(anchor);
    }
}
