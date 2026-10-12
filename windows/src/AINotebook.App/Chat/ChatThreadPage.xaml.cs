using System.ComponentModel;
using System.Numerics;
using AINotebook.App.Controls;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Views;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace AINotebook.App.Chat;

/// <summary>
/// Chat thread + composer (spec §2.2). The shell decides which thread is shown (<see cref="ShowAsync"/>)
/// and owns the right panel; this page raises requests for what lives outside it.
/// </summary>
public sealed partial class ChatThreadPage : Page
{
    public ChatViewModel ViewModel { get; }

    /// <summary>New-chat notebook picker: the shell shows its notebook menu at the anchor.</summary>
    public event Action<FrameworkElement>? NotebookPickerRequested;
    /// <summary>"+ › Run tool": a template id, or null for the tool chooser.</summary>
    public event Action<long?>? RunToolRequested;
    /// <summary>Model chip "Model settings…".</summary>
    public event Action? ModelSettingsRequested;

    private readonly IServiceProvider _sp;
    private readonly ILocalizedStrings _t;
    private readonly NotebookStore _store;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _streamTimer;
    private bool _streamDirty;

    public ChatThreadPage()
    {
        _sp = App.Current.Services;
        ViewModel = _sp.GetRequiredService<ChatViewModel>();
        _t = _sp.GetRequiredService<ILocalizedStrings>();
        _store = _sp.GetRequiredService<NotebookStore>();
        InitializeComponent();
        ApplyStrings();
        _t.PropertyChanged += (_, _) => ApplyStrings();

        // Composer grows from 1 to 8 lines (tokens composerMinLines / composerMaxLines), then scrolls.
        InputBox.MaxHeight = Token("SizeComposerMaxLines") * Token("LineHeightBody") + Token("Space16");

        // Streaming: re-render the Markdown at most every 120 ms (tokens motion fastMs), not per token.
        _streamTimer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _streamTimer.Interval = TimeSpan.FromMilliseconds((int)Application.Current.Resources["MotionFastMs"]);
        _streamTimer.Tick += (_, _) => FlushStreaming();
        _streamTimer.Start();

        PendingUserBlock.Padding = new Thickness(Token("SizeUserMessagePadH"), Token("SizeUserMessagePadV"),
            Token("SizeUserMessagePadH"), Token("SizeUserMessagePadV"));
        MessagesScroller.SizeChanged += (_, e) => PendingUserBlock.MaxWidth =
            Math.Min(e.NewSize.Width, Token("SizeConversationMax")) * Token("SizeUserMessageMaxPercent") / 100;
        ViewModel.Messages.CollectionChanged += (_, _) => ScrollToBottom();
        ViewModel.PropertyChanged += OnViewModelChanged;
        ApplyEmptyLayout();
    }

    private static double Token(string key) => (double)Application.Current.Resources[key];

    private void ApplyStrings()
    {
        InputBox.PlaceholderText = _t.Get(StringKey.ComposerPlaceholder);
        NewChatHeading.Text = _t.Get(StringKey.ChatEmptyTitle);
        RetryText.Text = _t.Get(StringKey.ChatRetry);
        EditingLabel.Text = _t.Get(StringKey.ComposerEditing);
        CommitEditButton.Content = _t.Get(StringKey.Save);
        CancelEditButton.Content = _t.Get(StringKey.CancelButton);
        SavedNoteText.Text = _t.Get(StringKey.NoteSavedNotice);
        OpenSavedNoteButton.Content = _t.Get(StringKey.OpenNote);

        AddFileItem.Text = _t.Get(StringKey.ComposerAddFile);
        AddFolderItem.Text = _t.Get(StringKey.AddFolderButton);
        AddUrlItem.Text = _t.Get(StringKey.ComposerAddUrl);
        WebSearchItem.Text = _t.Get(StringKey.ComposerWebSearch);
        OverviewItem.Text = _t.Get(StringKey.ComposerOverviewMode);
        RunToolSubItem.Text = _t.Get(StringKey.ComposerRunTool);
        NewNoteItem.Text = _t.Get(StringKey.NotesNewButton);
        NewPersonaItem.Text = _t.Get(StringKey.PersonaNew);
        QuietAddFolderText.Text = _t.Get(StringKey.AddFolderButton);
        QuietAddFileText.Text = _t.Get(StringKey.ComposerAddFile);
        QuietNewNoteText.Text = _t.Get(StringKey.NotesNewButton);

        ScopeTitle.Text = _t.Get("chatScopeTitle");
        WholeNotebookRadio.Content = _t.Get(StringKey.ScopeWholeNotebook);
        SelectedItemsRadio.Content = _t.Get(StringKey.ScopeSelection);
        EmptyScopeText.Text = _t.Get(StringKey.ScopeEmpty);
        ScopeFoldersLabel.Text = _t.Get(StringKey.ScopeFolders);
        ScopeSetsLabel.Text = _t.Get(StringKey.ScopeSourceSets);
        ScopeSourcesLabel.Text = _t.Get(StringKey.ScopeSources);
        SourceSetsLabel.Text = _t.Get(StringKey.SourceSetsSectionTitle);
        AddSourceSetButton.Content = _t.Get(StringKey.AddSourceSetButton);

        PersonaNoneButton.Content = _t.Get(StringKey.PersonaChipNone);
        PersonaNewLabel.Text = _t.Get(StringKey.PersonaNew);
        PersonaNameBox.PlaceholderText = _t.Get(StringKey.PersonaNamePlaceholder);
        PersonaInstructionsBox.PlaceholderText = _t.Get(StringKey.PersonaInstructionsPlaceholder);
        PersonaSaveButton.Content = _t.Get(StringKey.Save);

        Label(AddMenuButton, _t.Get(StringKey.ComposerAdd));
        Label(ScopeButton, _t.Get(StringKey.ComposerScope));
        Label(PersonaButton, _t.Get(StringKey.PersonaMenu));
        Label(ModelButton, _t.Get(StringKey.ComposerModel));
        Label(PreviewContextButton, _t.Get(StringKey.ComposerPreviewContext));
        Label(SendButton, _t.Get(StringKey.ChatSendButton) + " (Enter)");
        Label(StopButton, _t.Get(StringKey.ChatStopButton));
        Label(NotebookPickerButton, _t.Get(StringKey.ChooseNotebook));
    }

    private static void Label(FrameworkElement element, string text)
    {
        AutomationProperties.SetName(element, text);
        ToolTipService.SetToolTip(element, text);
    }

    /// <summary>Shows a thread (or the new-chat state when <paramref name="sessionId"/> is null).</summary>
    public async Task ShowAsync(long notebookId, long? sessionId, string notebookName)
    {
        NotebookPickerText.Text = string.IsNullOrEmpty(notebookName) ? _t.Get(StringKey.ChooseNotebook) : notebookName;
        SavedNoteRow.Visibility = Visibility.Collapsed;
        await ViewModel.ShowAsync(notebookId, sessionId);
        ApplyEmptyLayout();
        if (sessionId is null) InputBox.Focus(FocusState.Programmatic);
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ChatViewModel.StreamingDraft):
                _streamDirty = true;
                if (string.IsNullOrEmpty(ViewModel.StreamingDraft)) FlushStreaming();
                break;
            case nameof(ChatViewModel.ShowEmptyState):
                ApplyEmptyLayout();
                break;
            case nameof(ChatViewModel.Sending):
                ThinkingRing.IsActive = ViewModel.Sending;
                ThinkingRing.Visibility = ViewModel.Sending && string.IsNullOrEmpty(ViewModel.StreamingDraft)
                    ? Visibility.Visible : Visibility.Collapsed;
                break;
            case nameof(ChatViewModel.SavedNoteId):
                SavedNoteRow.Visibility = ViewModel.SavedNoteId is null ? Visibility.Collapsed : Visibility.Visible;
                break;
        }
    }

    private void FlushStreaming()
    {
        if (!_streamDirty) return;
        _streamDirty = false;
        string draft = ViewModel.StreamingDraft;
        if (draft.Length > 0) ThinkingRing.Visibility = Visibility.Collapsed;
        MarkdownRenderer.Render(StreamingHost, draft, onCite: null);
        ScrollToBottom();
    }

    /// <summary>New chat: heading, notebook picker, composer and quiet actions sit centred together.</summary>
    private void ApplyEmptyLayout()
    {
        bool empty = ViewModel.ShowEmptyState;
        ContentGrid.VerticalAlignment = empty ? VerticalAlignment.Center : VerticalAlignment.Stretch;
        ConversationRow.Height = empty ? GridLength.Auto : new GridLength(1, GridUnitType.Star);
    }

    private void ScrollToBottom() => MessagesScroller.ChangeView(null, MessagesScroller.ScrollableHeight, null);

    // ---------------------------------------------------------------- composer

    /// <summary>Enter sends, Shift+Enter inserts a new line, Ctrl+Enter also sends.</summary>
    private void OnInputPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift);
        if (shift.HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) return;
        e.Handled = true;
        if (ViewModel.SendCommand.CanExecute(null)) ViewModel.SendCommand.Execute(null);
    }

    /// <summary>The composer card shows a soft shadow and a stronger edge only while focused (spec §2.2).</summary>
    private void OnInputFocusChanged(object sender, RoutedEventArgs e)
    {
        bool focused = InputBox.FocusState != FocusState.Unfocused;
        ComposerCard.BorderBrush = (Brush)Application.Current.Resources[focused ? "Text3Brush" : "BorderBrush"];
        ComposerCard.Shadow = focused ? new ThemeShadow() : null;
        ComposerCard.Translation = focused ? new Vector3(0, 0, (float)Token("Space16")) : Vector3.Zero;
    }

    private void OnAddMenuOpening(object sender, object e)
    {
        // "Run tool…" (no preselected template) first, then each template, listed fresh
        // each time (templates can change in Settings › Tools).
        RunToolSubItem.Items.Clear();
        var chooser = new MenuFlyoutItem { Text = _t.Get(StringKey.ComposerRunTool) + "…" };
        chooser.Click += (_, _) => RunToolRequested?.Invoke(null);
        RunToolSubItem.Items.Add(chooser);
        RunToolSubItem.Items.Add(new MenuFlyoutSeparator());
        try
        {
            foreach (var tx in _store.Transformations())
            {
                var item = new MenuFlyoutItem { Text = tx.Name, Tag = tx.Id };
                item.Click += (s, _) => RunToolRequested?.Invoke((s as FrameworkElement)?.Tag as long?);
                RunToolSubItem.Items.Add(item);
            }
        }
        catch (Exception) { }
    }

    private async void OnAddFile(object sender, RoutedEventArgs e) => await AddSourceAsync(AddSourceKind.File);
    private async void OnAddUrl(object sender, RoutedEventArgs e) => await AddSourceAsync(AddSourceKind.Url);

    private async Task AddSourceAsync(AddSourceKind kind)
    {
        if (ViewModel.NotebookId == 0) return;
        var dialog = new AddSourceDialog(_sp.GetRequiredService<IngestionService>(), ViewModel.NotebookId,
            _sp.GetRequiredService<LocalizedStrings>(), kind) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        if (dialog.DidIngest) await ViewModel.ShowAsync(ViewModel.NotebookId, ViewModel.SelectedSession?.Id);
    }

    private async void OnAddFolder(object sender, RoutedEventArgs e)
    {
        if (ViewModel.NotebookId == 0) return;
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        try { await _sp.GetRequiredService<FolderIngestionRuntime>().AddFolderAsync(ViewModel.NotebookId, folder.Path); }
        catch (Exception ex) { ViewModel.ErrorMessage = _t.Get(SourcesViewModel.FolderErrorKey(ex)); }
    }

    /// <summary>"+ › New note": an untitled note opens as a document.</summary>
    private void OnNewNote(object sender, RoutedEventArgs e)
    {
        if (ViewModel.NotebookId == 0) return;
        try
        {
            var note = _store.CreateNote(ViewModel.NotebookId, _t.Get(StringKey.NoteUntitled), "");
            if (note.Id is long id) _sp.GetRequiredService<NoteJumpCoordinator>().Request(id);
        }
        catch (Exception ex) { ViewModel.ErrorMessage = ViewModel.ChatErrorText(ex); }
    }

    /// <summary>"+ › New persona…" (the persona chip appears once a persona exists).</summary>
    private async void OnNewPersona(object sender, RoutedEventArgs e)
    {
        var name = new TextBox { PlaceholderText = _t.Get(StringKey.PersonaNamePlaceholder) };
        var instructions = new TextBox
        {
            PlaceholderText = _t.Get(StringKey.PersonaInstructionsPlaceholder),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = Token("SizeTopBar") * 2,
        };
        var panel = new StackPanel { Spacing = Token("Space8") };
        panel.Children.Add(name);
        panel.Children.Add(instructions);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _t.Get(StringKey.PersonaNew),
            Content = panel,
            PrimaryButtonText = _t.Get(StringKey.Save),
            CloseButtonText = _t.Get(StringKey.Cancel),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        ViewModel.NewPersonaName = name.Text;
        ViewModel.NewPersonaInstructions = instructions.Text;
        ViewModel.CreatePersonaCommand.Execute(null);
    }

    /// <summary>Model chip: current model, "Regenerate with" a provider, "Model settings…".</summary>
    private void OnModelChip(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.TopEdgeAlignedLeft };
        menu.Items.Add(new MenuFlyoutItem { Text = ViewModel.ModelChipText, IsEnabled = false });
        if (ViewModel.CanEditLast && ViewModel.HasChatProviders && !ViewModel.Sending)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(RegenerateWithSubMenu());
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var settings = new MenuFlyoutItem { Text = _t.Get(StringKey.ComposerModelSettings) };
        settings.Click += (_, _) => ModelSettingsRequested?.Invoke();
        menu.Items.Add(settings);
        menu.ShowAt((FrameworkElement)sender);
    }

    private MenuFlyoutSubItem RegenerateWithSubMenu()
    {
        var sub = new MenuFlyoutSubItem { Text = _t.Get(StringKey.ComposerRegenerateWith) };
        foreach (var provider in ViewModel.ChatProviders)
            sub.Items.Add(new MenuFlyoutItem
            {
                Text = provider.Name,
                Command = ViewModel.RegenerateWithCommand,
                CommandParameter = provider,
            });
        return sub;
    }

    private void OnNotebookPicker(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement anchor) NotebookPickerRequested?.Invoke(anchor);
    }

    // ---------------------------------------------------------------- messages

    private void OnCitationTapped(object? sender, CitationTappedEventArgs e) => ViewModel.ShowCitation(e.Message, e.Marker);

    private void OnMessageAction(object? sender, MessageActionEventArgs e)
    {
        switch (e.Action)
        {
            case MessageAction.Copy:
                var package = new DataPackage();
                package.SetText(e.Message.Content);
                Clipboard.SetContent(package);
                break;
            case MessageAction.Regenerate:
                var menu = new MenuFlyout();
                var plain = new MenuFlyoutItem { Text = _t.Get(StringKey.ChatRegenerateButton), Command = ViewModel.RegenerateCommand };
                menu.Items.Add(plain);
                if (ViewModel.HasChatProviders) menu.Items.Add(RegenerateWithSubMenu());
                menu.ShowAt(e.Anchor);
                break;
            case MessageAction.SaveAsNote:
                ViewModel.SaveAsNoteCommand.Execute(e.Message);
                break;
            case MessageAction.SentContext:
                ViewModel.ShowSentContextCommand.Execute(e.Message);
                break;
            case MessageAction.Edit:
                ViewModel.EditLastCommand.Execute(null);
                EditInputBox.Focus(FocusState.Programmatic);
                break;
        }
    }

    private void OnOpenSavedNote(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SavedNoteId is long id) _sp.GetRequiredService<NoteJumpCoordinator>().Request(id);
    }

    private void OnFollowupTapped(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string question })
        {
            ViewModel.UseFollowupCommand.Execute(question);
            InputBox.Focus(FocusState.Programmatic);
        }
    }

    // ---------------------------------------------------------------- scope (C2 source sets) and personas (C5)

    private void OnApplyPersona(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Persona persona })
        {
            ViewModel.ApplyPersonaCommand.Execute(persona);
            PersonaFlyout.Hide();
        }
    }

    private void OnApplySourceSet(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceSet set })
            ViewModel.ApplySourceSetCommand.Execute(set);
    }

    private void OnDeleteSourceSet(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceSet set })
            ViewModel.DeleteSourceSetCommand.Execute(set);
    }

    private void OnDeleteSetLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement element) Label(element, _t.Get(StringKey.DeleteSourceSetTitle));
    }

    private async void OnCreateSourceSet(object sender, RoutedEventArgs e)
    {
        var input = new TextBox { PlaceholderText = _t.Get(StringKey.SourceSetNamePlaceholder) };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _t.Get(StringKey.AddSourceSetButton),
            Content = input,
            PrimaryButtonText = _t.Get(StringKey.Save),
            CloseButtonText = _t.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            ViewModel.CreateSourceSetCommand.Execute(input.Text);
    }
}
