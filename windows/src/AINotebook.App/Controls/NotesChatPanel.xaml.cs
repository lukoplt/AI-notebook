using System;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
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
    private readonly ICitationOriginalResolver _originals;
    // WP8: the notebook the original resolver validates citations against.
    private long _notebookId;

    public NotesChatPanel()
    {
        ViewModel = App.Current.Services.GetRequiredService<NotesChatPanelViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        _originals = App.Current.Services.GetRequiredService<ICitationOriginalResolver>();
        InitializeComponent();

        PanelTitle.Text = _t.Get("notesChatPanelTitle");
        EmptyState.Text = _t.Get("notesChatPanelEmpty");
        InputBox.PlaceholderText = _t.Get("chatInputPlaceholder");

        ViewModel.Messages.CollectionChanged += (_, _) => ScrollToBottom();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotesChatPanelViewModel.StreamingDraft)) ScrollToBottom();
            if (e.PropertyName == nameof(NotesChatPanelViewModel.ErrorMessage))
                ErrorText.Text = ViewModel.ErrorMessage ?? "";
        };
    }

    // Called by the shell once the notebook is known.
    public async System.Threading.Tasks.Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        await ViewModel.LoadAsync(notebookId);
    }

    // The note document provides the live current note so chat context tracks the open note.
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

    /// <summary>Enter sends, Shift+Enter inserts a new line (same as the main composer).</summary>
    private void OnInputPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift);
        if (shift.HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) return;
        e.Handled = true;
        RefreshCurrentNoteHint();
        if (ViewModel.SendCommand.CanExecute(null)) ViewModel.SendCommand.Execute(null);
    }

    private void OnMessageAction(object? sender, MessageActionEventArgs e)
    {
        switch (e.Action)
        {
            case MessageAction.SaveAsNote:
                ViewModel.SaveAsNoteCommand.Execute(e.Message);
                break;
            case MessageAction.Copy:
                var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
                package.SetText(e.Message.Content);
                Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
                break;
        }
    }

    private void OnCitationTapped(object? sender, CitationTappedEventArgs e)
    {
        if (sender is not FrameworkElement anchor) return;
        var citation = e.Message.Citations.FirstOrDefault(c => c.Marker == e.Marker);
        if (citation is null) return;
        ShowCitationFlyout(anchor, ViewModel.BuildCitationViewModel(citation));
    }

    private void ShowCitationFlyout(FrameworkElement anchor, CitationViewModel cvm)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        header.Children.Add(new FontIcon { Glyph = "" }); // quote-ish glyph
        header.Children.Add(new TextBlock { Text = cvm.SourceTitle, Style = (Style)Application.Current.Resources["BaseTextBlockStyle"] });

        // WP8: no launch from a captured rawPath. "Open original" asks Core's resolver at
        // click time (live source, folder root, containment, revision) and launches only the
        // validated path; unsafe/unavailable keeps the saved snapshot text and shows why.
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Visibility = Visibility.Collapsed };
        if (cvm.NoteIdToOpen is null)
        {
            var openBtn = new HyperlinkButton { Content = _t.Get(StringKey.CitationOpenOriginal) };
            openBtn.Click += async (_, _) =>
            {
                string? message;
                try
                {
                    var resolved = await _originals.ResolveAsync(_notebookId, cvm.Citation);
                    message = resolved.Decision switch
                    {
                        CitationOriginalDecision.Changed => _t.Get(StringKey.CitationRevisionChanged),
                        CitationOriginalDecision.Unavailable => _t.Get(StringKey.CitationOriginalUnavailable),
                        CitationOriginalDecision.Unsafe => _t.Get(StringKey.CitationOriginalOutsideFolder),
                        _ => null
                    };
                    if (resolved.Path is { } path) await Launcher.LaunchUriAsync(new Uri(path));
                }
                catch (Exception) { message = _t.Get(StringKey.CitationOriginalUnavailable); }
                status.Text = message ?? "";
                status.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
            };
            header.Children.Add(openBtn);
        }

        var snippet = new ScrollViewer
        {
            MaxHeight = 240,
            Content = new TextBlock { Text = cvm.Snippet, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
        };
        var panel = new StackPanel { Width = 380, Spacing = 8 };
        panel.Children.Add(header);
        panel.Children.Add(status);
        panel.Children.Add(snippet);

        var flyout = new Flyout { Content = panel };
        flyout.ShowAt(anchor);
    }
}
