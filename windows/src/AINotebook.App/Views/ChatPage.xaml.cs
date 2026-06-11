using System;
using AINotebook.App.ViewModels;
using AINotebook.App.Controls;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace AINotebook.App.Views;

public sealed partial class ChatPage : Page
{
    public ChatViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public string CitationPanelWidth =>
        ViewModel.IsCitationPanelOpen ? "300" : "0";

    public ChatPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<ChatViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        SessionsLabel.Text = _t.Get("chatSessionsLabel");
        EmptyState.Text = _t.Get("chatEmptyState");
        InputBox.PlaceholderText = _t.Get("chatInputPlaceholder");
        ToolTipService.SetToolTip(NewSessionButton, _t.Get("chatNewSessionButton"));
        FollowupsLabel.Text = _t.Get("chatFollowupsLabel");
        ScopeTitle.Text = _t.Get("chatScopeTitle");
        CitationPanelTitle.Text = _t.Get(StringKey.CitationPanelTitle);
        ToolTipService.SetToolTip(EditLastButton, _t.Get(StringKey.ChatEditButton));
        ToolTipService.SetToolTip(RegenerateButton, _t.Get(StringKey.ChatRegenerateButton));
        CommitEditButton.Content = _t.Get(StringKey.UnsavedSaveButton);
        CancelEditButton.Content = _t.Get(StringKey.CancelButton);
        SourceSetsLabel.Text = _t.Get(StringKey.SourceSetsSectionTitle);
        ToolTipService.SetToolTip(WebSearchToggle, _t.Get(StringKey.WebSearchToggleLabel));
        ViewModel.Messages.CollectionChanged += (_, _) => ScrollToBottom();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ChatViewModel.StreamingDraft)) ScrollToBottom();
            if (e.PropertyName == nameof(ChatViewModel.IsCitationPanelOpen)) Bindings.Update();
            if (e.PropertyName == nameof(ChatViewModel.ErrorMessage))
                ErrorText.Text = (ViewModel.ErrorMessage is null) ? "" : _t.Get("chatErrorPrefix") + ViewModel.ErrorMessage;
        };
    }

    // Called by the shell when the notebook changes (mirrors .task(id: notebook.id)).
    public async void Load(long notebookId) => await ViewModel.LoadAsync(notebookId);

    private void ScrollToBottom() => MessagesScroller.ChangeView(null, MessagesScroller.ScrollableHeight, null);

    private void OnSendAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ViewModel.SendCommand.CanExecute(null)) ViewModel.SendCommand.Execute(null);
        args.Handled = true;
    }

    private void OnFollowupTapped(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string question })
            ViewModel.UseFollowupCommand.Execute(question);
    }

    private void OnDeleteSession(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ChatSession session })
            ViewModel.DeleteSessionCommand.Execute(session);
    }

    private void OnCitationTapped(object? sender, Citation c)
    {
        if (sender is not FrameworkElement anchor) return;
        var cvm = ViewModel.BuildCitationViewModel(c);
        ShowCitationFlyout(anchor, cvm);
    }

    private void OnSaveAsNote(object? sender, MessageViewModel vm) =>
        ViewModel.SaveAsNoteCommand.Execute(vm);

    // C2: apply a source set as the chat scope preset.
    private void OnApplySourceSet(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceSet set })
            ViewModel.ApplySourceSetCommand.Execute(set);
    }

    private void OnToggleCitationPanel(object sender, RoutedEventArgs e)
    {
        if (ViewModel.IsCitationPanelOpen)
            ViewModel.CloseCitationPanelCommand.Execute(null);
        else
            ViewModel.IsCitationPanelOpen = true;
        Bindings.Update();
    }

    private void ShowCitationFlyout(FrameworkElement anchor, CitationViewModel cvm)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        header.Children.Add(new FontIcon { Glyph = "\uE9D2" }); // quote-ish glyph
        header.Children.Add(new TextBlock { Text = cvm.SourceTitle, Style = (Style)Resources["BaseTextBlockStyle"] });

        // "Open page N" for a PDF source with a page hint.
        if (cvm.PageHint is int page && cvm.PdfFilePath is { } path)
        {
            var openBtn = new HyperlinkButton { Content = $"Open page {page}" };
            openBtn.Click += async (_, _) =>
                await Launcher.LaunchUriAsync(new Uri(new Uri("file://"), path));
            header.Children.Add(openBtn);
        }
        // "Open note" for a note source -> jump via coordinator.
        if (cvm.NoteIdToOpen is long nid)
        {
            var noteBtn = new HyperlinkButton { Content = _t.Get("openNoteFromCitation") };
            noteBtn.Click += (_, _) => ViewModel.RequestOpenNote(nid);
            header.Children.Add(noteBtn);
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
