using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.App.Views;
using AINotebook.App.Views.Dialogs;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace AINotebook.App.Shell;

/// <summary>
/// Codex-style shell (spec §2): sidebar with notebooks → chats, main area, right panel. Replaces the
/// NavigationView + NotebookDetailPage tabs; every former tab/header action is reachable from the
/// sidebar menus, the top bar or the right panel (spec §2.7).
/// </summary>
public sealed partial class ShellPage : Page
{
    public ShellViewModel ViewModel { get; }
    private NavigationState Nav => ViewModel.Navigation;

    private readonly IServiceProvider _sp;
    private readonly ILocalizedStrings _l;
    private readonly NotebookStore _store;
    private readonly UpdateState _updateState;
    private readonly ISettingsService _settings;
    private readonly NoteEditorCoordinator _editor;

    // Long-lived surfaces: one chat surface whose view model the panels share.
    private Chat.ChatThreadPage? _chat;
    private Document.NoteDocumentPage? _document;
    private Settings.SettingsPage? _settingsPage;
    private long? _panelNotebookId;
    private PanelSegment? _panelContentSegment;
    private bool _syncingTabs;
    private bool _dialogOpen;
    // Right-panel toggle dot: the notebook in context's indexing status, watched only while the panel is closed.
    private readonly IndexingStatusWatcher _panelIndexing;

    public ShellPage()
    {
        _sp = App.Current.Services;
        ViewModel = _sp.GetRequiredService<ShellViewModel>();
        _l = _sp.GetRequiredService<ILocalizedStrings>();
        _store = _sp.GetRequiredService<NotebookStore>();
        _updateState = _sp.GetRequiredService<UpdateState>();
        _settings = _sp.GetRequiredService<ISettingsService>();
        _editor = _sp.GetRequiredService<NoteEditorCoordinator>();
        var runtime = _sp.GetRequiredService<FolderIngestionRuntime>();
        _panelIndexing = new IndexingStatusWatcher((nb, ct) => runtime.IndexingStatusAsync(nb, ct), _store,
            Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
        InitializeComponent();

        ApplyStrings();
        _l.PropertyChanged += (_, _) => { ApplyStrings(); ViewModel.Sidebar.Reload(); };

        PanelBody.Width = Math.Clamp(_settings.RightPanelWidth, PanelMin, PanelMax);
        Nav.LeaveGuard = ConfirmLeaveDocumentAsync;
        Nav.RunToolRequested += () => _ = ShowRunToolAsync();
        Nav.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NavigationState.Selection)) ShowMain();
            if (e.PropertyName == nameof(NavigationState.Panel) || e.PropertyName == nameof(NavigationState.Selection))
            {
                ShowPanel();
                SyncPanelIndexing();
            }
        };
        _panelIndexing.Refreshed += SyncPanelDot;
        Loaded += (_, _) => { _panelIndexing.Start(); SyncPanelIndexing(); };
        Unloaded += (_, _) => _panelIndexing.Stop();

        _updateState.PropertyChanged += (_, _) => SyncUpdateIndicator();
        SyncUpdateIndicator();

        // Ctrl+, opens Settings; VirtualKey has no named member for the comma key (VK_OEM_COMMA = 188).
        var settingsKey = new KeyboardAccelerator { Key = (VirtualKey)188, Modifiers = VirtualKeyModifiers.Control };
        settingsKey.Invoked += (sender, args) => { args.Handled = true; _ = ShowSettingsAsync(SettingsSection.General); };
        KeyboardAccelerators.Add(settingsKey);

        ShowMain();
        ShowPanel();
    }

    private static double Token(string key) => (double)Application.Current.Resources[key];
    private static double PanelMin => Token("SizePanelMin");
    private static double PanelMax => Token("SizePanelMax");

    private void ApplyStrings()
    {
        NewChatText.Text = _l.Get(StringKey.ShellNewChat);
        SearchText.Text = _l.Get(StringKey.ShellSearch);
        NewNotebookText.Text = _l.Get(StringKey.ShellNewNotebook);
        SettingsText.Text = _l.Get(StringKey.Settings);
        UpdateIndicatorText.Text = _l.Get(StringKey.ShellUpdateAvailable);
        AppEmptyTitle.Text = _l.Get(StringKey.ShellEmptyAppTitle);
        EmptyAddFolderButton.Content = _l.Get(StringKey.AddFolderButton);
        EmptyNewNotebookButton.Content = _l.Get(StringKey.ShellNewNotebook);
        TabSources.Text = _l.Get(StringKey.Sources);
        TabNotes.Text = _l.Get(StringKey.Notes);
        TabContext.Text = _l.Get(StringKey.PanelContext);
        TabCitations.Text = _l.Get(StringKey.CitationPanelTitle);
        TabNoteChat.Text = _l.Get(StringKey.PanelNoteChat);
        SetLabel(TogglePanelButton, _l.Get(StringKey.ShellTogglePanel));
        SetLabel(ThreadMoreButton, _l.Get(StringKey.ShellMore));
        SetLabel(ClosePanelButton, _l.Get(StringKey.Close));
        ToolTipService.SetToolTip(NewChatButton, _l.Get(StringKey.ShellNewChat) + " (Ctrl+N)");
    }

    private static void SetLabel(FrameworkElement element, string label)
    {
        AutomationProperties.SetName(element, label);
        ToolTipService.SetToolTip(element, label);
    }

    // ---------------------------------------------------------------- main area

    private void ShowMain()
    {
        var selection = Nav.Selection;
        bool thread = selection is ShellSelection.Chat or ShellSelection.NewChat;
        if (selection is not ShellSelection.Settings) _settingsPage = null; // rebuilt fresh next time
        TopBar.Visibility = thread ? Visibility.Visible : Visibility.Collapsed;
        AppEmptyState.Visibility = selection is ShellSelection.Empty ? Visibility.Visible : Visibility.Collapsed;
        MainHost.Visibility = selection is ShellSelection.Empty ? Visibility.Collapsed : Visibility.Visible;
        switch (selection)
        {
            case ShellSelection.Chat chat:
                _ = ShowChatAsync(chat.NotebookId, chat.SessionId);
                break;
            case ShellSelection.NewChat { NotebookId: long nb }:
                _ = ShowChatAsync(nb, null);
                break;
            case ShellSelection.Note note:
                _ = ShowNoteAsync(note.NotebookId, note.NoteId);
                break;
            case ShellSelection.Settings settings:
                ShowSettingsPage(settings.Section);
                break;
            default:
                MainHost.Children.Clear();
                break;
        }
        UpdateTopBar();
    }

    private Chat.ChatThreadPage EnsureChatSurface()
    {
        if (_chat is not null) return _chat;
        var chat = new Chat.ChatThreadPage();
        chat.ViewModel.SessionCreated += session =>
        {
            if (session.Id is long id) ViewModel.OnSessionCreated(session.NotebookId, id);
        };
        chat.ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ChatViewModel.SelectedSession)) UpdateTopBar();
        };
        // Citations and context previews open in the right panel (spec §2.2 / §2.3).
        chat.ViewModel.CitationsRequested += () => Nav.ShowPanel(PanelSegment.Citations);
        chat.ViewModel.ContextRequested += () => Nav.ShowPanel(PanelSegment.Context);
        chat.NotebookPickerRequested += anchor => NotebookPickerMenu().ShowAt(anchor);
        chat.RunToolRequested += templateId => _ = ShowRunToolAsync(templateId);
        chat.ModelSettingsRequested += () => _ = ShowSettingsAsync(SettingsSection.ModelsLimits);
        _chat = chat;
        return chat;
    }

    private async Task ShowChatAsync(long notebookId, long? sessionId)
    {
        var chat = EnsureChatSurface();
        Host(MainHost, chat);
        var name = ViewModel.Sidebar.Notebooks.FirstOrDefault(n => n.Id == notebookId)?.Name ?? "";
        await chat.ShowAsync(notebookId, sessionId, name);
        UpdateTopBar();
    }

    /// <summary>New-chat notebook picker (spec §2.2): notebooks · New notebook · Open folder as notebook.</summary>
    private MenuFlyout NotebookPickerMenu()
    {
        var menu = new MenuFlyout();
        foreach (var notebook in ViewModel.Sidebar.Notebooks)
        {
            if (notebook.Id is not long id) continue;
            var item = new MenuFlyoutItem { Text = notebook.Name, Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconNotebook"] } };
            item.Click += async (_, _) => await Nav.NavigateAsync(new ShellSelection.NewChat(id));
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var create = Item(StringKey.ShellNewNotebook, "IconAdd", () => { OnNewNotebook(this, new RoutedEventArgs()); return Task.CompletedTask; });
        menu.Items.Add(create);
        var open = Item(StringKey.OpenFolderAsNotebook, "IconAddFolder", () => { OnOpenFolderAsNotebook(this, new RoutedEventArgs()); return Task.CompletedTask; });
        menu.Items.Add(open);
        return menu;
    }

    private async Task ShowNoteAsync(long notebookId, long noteId)
    {
        _document ??= new Document.NoteDocumentPage(Nav);
        Host(MainHost, _document);
        await _document.OpenAsync(notebookId, noteId);
    }

    private void ShowSettingsPage(SettingsSection section)
    {
        if (_settingsPage is null)
        {
            _settingsPage = new Settings.SettingsPage(Nav, section);
            Host(MainHost, _settingsPage);
        }
        else _settingsPage.ShowSection(section);
    }

    private static void Host(Grid host, UIElement content)
    {
        if (host.Children.Count == 1 && ReferenceEquals(host.Children[0], content)) return;
        host.Children.Clear();
        host.Children.Add(content);
    }

    private void UpdateTopBar()
    {
        var nb = Nav.NotebookId is long id ? ViewModel.Sidebar.Notebooks.FirstOrDefault(n => n.Id == id) : null;
        NotebookLabelText.Text = nb?.Name ?? "";
        NotebookLabel.Visibility = nb is null ? Visibility.Collapsed : Visibility.Visible;
        ThreadTitle.Text = Nav.Selection is ShellSelection.Chat c
            ? ViewModel.Sidebar.Sessions(c.NotebookId).FirstOrDefault(s => s.Id == c.SessionId)?.Title ?? ""
            : _l.Get(StringKey.ShellNewChat);
        ThreadMoreButton.Visibility = Nav.Selection is ShellSelection.Chat ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---------------------------------------------------------------- right panel

    private void ShowPanel()
    {
        var segment = Nav.Panel;
        RightPanel.Visibility = segment is null ? Visibility.Collapsed : Visibility.Visible;
        // Note chat takes the Context slot while a note is open (spec §2.4).
        TabNoteChat.Visibility = Nav.IsDocument ? Visibility.Visible : Visibility.Collapsed;
        TabContext.Visibility = Nav.IsDocument ? Visibility.Collapsed : Visibility.Visible;
        if (segment is not { } s) return;

        _syncingTabs = true;
        PanelTabs.SelectedItem = s switch
        {
            PanelSegment.Sources => TabSources,
            PanelSegment.Notes => TabNotes,
            PanelSegment.Context => TabContext,
            PanelSegment.Citations => TabCitations,
            _ => TabNoteChat,
        };
        _syncingTabs = false;

        long? nb = Nav.NotebookId;
        if (_panelContentSegment == s && _panelNotebookId == nb) return;
        _panelContentSegment = s;
        _panelNotebookId = nb;
        PanelHost.Children.Clear();
        if (BuildPanelContent(s, nb) is { } content) PanelHost.Children.Add(content);
    }

    /// <summary>Panel segment content for the notebook in context (spec §2.3).</summary>
    private UIElement? BuildPanelContent(PanelSegment segment, long? notebookId)
    {
        // Context and Citations follow the chat surface (they describe its current answer/draft).
        if (segment == PanelSegment.Context)
        {
            var context = new Panels.ContextPanel(EnsureChatSurface().ViewModel);
            context.SettingsRequested += section => _ = ShowSettingsAsync(section);
            return context;
        }
        if (segment == PanelSegment.Citations) return new Panels.CitationsPanel(EnsureChatSurface().ViewModel);
        if (notebookId is not long nb) return null;
        var notebook = ViewModel.Sidebar.Notebooks.FirstOrDefault(n => n.Id == nb);
        if (notebook is null) return null;
        switch (segment)
        {
            case PanelSegment.Sources:
                var sources = new Panels.SourcesPanel(notebook);
                // Status strip "Open settings" (blocked indexing) → Settings › Providers / Indexing.
                sources.SettingsRequested += section => _ = ShowSettingsAsync(section);
                return sources;
            case PanelSegment.Notes: return new Panels.NotesPanel(nb, Nav);
            case PanelSegment.NoteChat:
                // "Chat k poznámce" (§2.4): the notes chat with the open note as context.
                var noteChat = new Controls.NotesChatPanel();
                noteChat.SetCurrentNoteProvider(() => _document?.CurrentNote);
                _ = noteChat.LoadAsync(nb);
                return noteChat;
            default: return null;
        }
    }

    private void OnPanelTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (_syncingTabs) return;
        var item = sender.SelectedItem;
        PanelSegment segment = item == TabNotes ? PanelSegment.Notes
            : item == TabContext ? PanelSegment.Context
            : item == TabCitations ? PanelSegment.Citations
            : item == TabNoteChat ? PanelSegment.NoteChat
            : PanelSegment.Sources;
        Nav.ShowPanel(segment);
    }

    private void OnTogglePanel(object sender, RoutedEventArgs e) => Nav.TogglePanel();

    /// <summary>Watch the notebook in context only while the panel is closed (the open Sources panel has its own strip).</summary>
    private void SyncPanelIndexing()
    {
        _panelIndexing.NotebookId = Nav.IsPanelOpen ? null : Nav.NotebookId;
        SyncPanelDot();
    }

    private void SyncPanelDot()
    {
        var status = Nav.IsPanelOpen ? null : _panelIndexing.Status;
        bool dot = IndexingStatusPresenter.ShowsPanelDot(status);
        bool blocked = dot && status!.Phase == IndexingPhase.Blocked;
        PanelActivityDot.Visibility = dot && !blocked ? Visibility.Visible : Visibility.Collapsed;
        PanelBlockedDot.Visibility = blocked ? Visibility.Visible : Visibility.Collapsed;
    }
    private void OnClosePanel(object sender, RoutedEventArgs e) => Nav.ClosePanel();

    private void OnPanelGripDelta(object sender, ManipulationDeltaRoutedEventArgs e)
    {
        // Dragging the grip left widens the panel.
        PanelBody.Width = Math.Clamp(PanelBody.Width - e.Delta.Translation.X, PanelMin, PanelMax);
        _settings.RightPanelWidth = PanelBody.Width;
    }

    // ---------------------------------------------------------------- sidebar

    private async void OnSidebarItemClick(object sender, ItemClickEventArgs e)
    {
        switch (e.ClickedItem)
        {
            case SidebarNotebookRow row:
                ViewModel.Sidebar.Toggle(row.NotebookId);
                break;
            case SidebarChatRow chat:
                await Nav.NavigateAsync(new ShellSelection.Chat(chat.NotebookId, chat.SessionId));
                break;
            case SidebarMoreRow more:
                ViewModel.Sidebar.ToggleShowAll(more.NotebookId);
                break;
        }
    }

    private async void OnNewChat(object sender, RoutedEventArgs e) => await ViewModel.NewChatAsync();

    private async void OnSearch(object sender, RoutedEventArgs e) => await ShowSearchAsync();

    private void OnSettings(object sender, RoutedEventArgs e) => _ = ShowSettingsAsync(SettingsSection.General);

    private async void OnNewNotebook(object sender, RoutedEventArgs e)
    {
        if (!BeginDialog()) return;
        try
        {
            var dialog = new NewNotebookDialog { XamlRoot = XamlRoot };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && dialog.Created?.Id is long id)
                await ViewModel.OnNotebookCreatedAsync(id);
        }
        finally { EndDialog(); }
    }

    /// <summary>"Open folder as notebook": a notebook named after the folder, with the folder watched.</summary>
    private async void OnOpenFolderAsNotebook(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        Notebook created;
        try { created = _store.CreateNotebook(folder.Name, ""); }
        catch (Exception) { await ShowMessageAsync(_l.Get(StringKey.ShellNewNotebook), _l.Get(StringKey.FolderReadError)); return; }
        if (created.Id is not long nb) return;
        try { await _sp.GetRequiredService<FolderIngestionRuntime>().AddFolderAsync(nb, folder.Path); }
        catch (Exception ex) { await ShowMessageAsync(_l.Get(StringKey.AddFolderButton), _l.Get(SourcesViewModel.FolderErrorKey(ex))); }
        await ViewModel.OnNotebookCreatedAsync(nb);
    }

    private void OnNotebookRowRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SidebarNotebookRow row } anchor)
        {
            NotebookMenu(row.Notebook).ShowAt(anchor, e.GetPosition(anchor));
            e.Handled = true;
        }
    }

    private void OnNotebookMoreClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SidebarNotebookRow row } anchor) NotebookMenu(row.Notebook).ShowAt(anchor);
    }

    private void OnChatRowRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SidebarChatRow row } anchor)
        {
            ChatMenu(row.NotebookId, row.Session).ShowAt(anchor, e.GetPosition(anchor));
            e.Handled = true;
        }
    }

    /// <summary>Notebook context menu (spec §2.1): the former notebook header / Settings tab actions.</summary>
    private MenuFlyout NotebookMenu(Notebook notebook)
    {
        var menu = new MenuFlyout();
        long id = notebook.Id ?? 0;
        menu.Items.Add(Item(StringKey.ShellNewChat, "IconNewChat", async () => await ViewModel.NewChatAsync(id)));
        menu.Items.Add(Item(StringKey.NotebookInstructionsMenu, "IconInstructions", async () => await EditInstructionsAsync(id)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(StringKey.ExportNotebookZip, "IconExport", async () => await ExportNotebookAsync(id)));
        menu.Items.Add(Item(StringKey.BackupButton, "IconBackup", async () => await BackupAsync()));
        menu.Items.Add(Item(StringKey.BackupRestoreButton, "IconRestore", async () => await RestoreAsync()));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(StringKey.RenameNotebook, "IconEdit", async () => await RenameNotebookAsync(notebook)));
        menu.Items.Add(Item(StringKey.DeleteNotebook, "IconDelete", async () => await DeleteNotebookAsync(id)));
        return menu;
    }

    /// <summary>Chat context menu (spec §2.1): Rename, Delete.</summary>
    private MenuFlyout ChatMenu(long notebookId, ChatSession session)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item(StringKey.RenameChat, "IconEdit", async () => await RenameChatAsync(notebookId, session.Id ?? 0)));
        menu.Items.Add(Item(StringKey.DeleteChat, "IconDelete", async () => await DeleteChatAsync(notebookId, session.Id ?? 0)));
        return menu;
    }

    private MenuFlyoutItem Item(StringKey text, string icon, Func<Task> action)
    {
        var item = new MenuFlyoutItem
        {
            Text = _l.Get(text),
            Icon = new FontIcon { Glyph = (string)Application.Current.Resources[icon] },
        };
        item.Click += async (_, _) => await action();
        return item;
    }

    private async Task EditInstructionsAsync(long notebookId)
    {
        var notebook = _store.Notebooks().FirstOrDefault(n => n.Id == notebookId);
        if (notebook is null || !BeginDialog()) return;
        try
        {
            var box = new TextBox
            {
                Text = notebook.Instructions,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 160,
                PlaceholderText = _l.Get(StringKey.NotebookInstructionsPlaceholder),
            };
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = _l.Get(StringKey.NotebookInstructionsLabel),
                Content = box,
                PrimaryButtonText = _l.Get(StringKey.Save),
                CloseButtonText = _l.Get(StringKey.Cancel),
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            try
            {
                await Task.Run(() => _store.UpdateNotebookInstructions(notebookId, box.Text));
                ViewModel.Sidebar.Reload();
            }
            catch (Exception) { await ShowMessageAsync(_l.Get(StringKey.NotebookInstructionsLabel), _l.Get(StringKey.ProviderRequestFailed)); }
        }
        finally { EndDialog(); }
    }

    private async Task ExportNotebookAsync(long notebookId)
    {
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.SuggestedFileName = "notebook";
        picker.DefaultFileExtension = ".zip";
        picker.FileTypeChoices.Add("ZIP", [".zip"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try
        {
            var stream = ExportService.ExportNotebookZip(notebookId, _store);
            using var outStream = await file.OpenStreamForWriteAsync();
            await stream.CopyToAsync(outStream);
        }
        catch (Exception ex) { await ShowMessageAsync(_l.Get(StringKey.ExportNotebookZip), ex.Message); }
    }

    private async Task BackupAsync()
    {
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.SuggestedFileName = "ainotebook-backup";
        picker.DefaultFileExtension = ".db";
        picker.FileTypeChoices.Add("SQLite database", [".db"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try
        {
            _store.BackupTo(file.Path);
            await ShowMessageAsync(_l.Get(StringKey.BackupButton), _l.Get(StringKey.ExportSuccess));
        }
        catch (Exception ex) { await ShowMessageAsync(_l.Get(StringKey.BackupButton), ex.Message); }
    }

    /// <summary>Restore replaces the database file (destructive — confirms first) and closes the app to reload it.</summary>
    private async Task RestoreAsync()
    {
        if (!BeginDialog()) return;
        try
        {
            var confirm = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = _l.Get(StringKey.BackupRestoreButton),
                Content = _l.Get(StringKey.BackupRestoreConfirm),
                PrimaryButtonText = _l.Get(StringKey.BackupRestoreButton),
                CloseButtonText = _l.Get(StringKey.Cancel),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        }
        finally { EndDialog(); }

        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.FileTypeFilter.Add(".db");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var dest = StorePath.Production().FilePath!;
            File.Copy(file.Path, dest, overwrite: true);
            App.MainWindow.Close(); // restart required to reload from the restored database
        }
        catch (Exception ex) { await ShowMessageAsync(_l.Get(StringKey.BackupRestoreButton), ex.Message); }
    }

    private async Task RenameNotebookAsync(Notebook notebook)
    {
        if (!BeginDialog()) return;
        try
        {
            var dialog = new RenameNotebookDialog(notebook) { XamlRoot = XamlRoot };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                ViewModel.Sidebar.Reload();
                UpdateTopBar();
            }
        }
        finally { EndDialog(); }
    }

    private async Task DeleteNotebookAsync(long notebookId)
    {
        if (!BeginDialog()) return;
        bool ok;
        try
        {
            ok = await new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = _l.Get(StringKey.DeleteNotebook),
                Content = _l.Get(StringKey.ConfirmDeleteNotebook),
                PrimaryButtonText = _l.Get(StringKey.Delete),
                CloseButtonText = _l.Get(StringKey.Cancel),
                DefaultButton = ContentDialogButton.Close,
            }.ShowAsync() == ContentDialogResult.Primary;
        }
        finally { EndDialog(); }
        if (!ok) return;
        try
        {
            if (Nav.NotebookId == notebookId) _editor.Reset(); // its open note is deleted with it
            await ViewModel.DeleteNotebookAsync(notebookId);
            _panelNotebookId = null;
            ShowPanel();
        }
        catch (StoreException) { /* mac keeps deleteError unrendered (non-blocking); mirror it */ }
    }

    /// <summary>Rename dialog with the current title prefilled; a blank or unchanged title keeps the stored one.</summary>
    private async Task RenameChatAsync(long notebookId, long sessionId)
    {
        var current = ViewModel.Sidebar.Sessions(notebookId).FirstOrDefault(s => s.Id == sessionId);
        if (current is null || !BeginDialog()) return;
        try
        {
            var box = new TextBox { Text = current.Title, AcceptsReturn = false };
            AutomationProperties.SetName(box, _l.Get(StringKey.RenameChatTitle));
            box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = _l.Get(StringKey.RenameChatTitle),
                Content = box,
                PrimaryButtonText = _l.Get(StringKey.Save),
                CloseButtonText = _l.Get(StringKey.Cancel),
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            try
            {
                if (ViewModel.Sidebar.RenameChat(notebookId, sessionId, box.Text)) UpdateTopBar();
            }
            catch (StoreException) { /* the chat was deleted meanwhile: the sidebar reloads on its next change */ }
        }
        finally { EndDialog(); }
    }

    /// <summary>Double-clicking the thread title renames the chat (spec §2.2).</summary>
    private async void OnThreadTitleDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (Nav.Selection is not ShellSelection.Chat chat) return;
        e.Handled = true;
        await RenameChatAsync(chat.NotebookId, chat.SessionId);
    }

    private async Task DeleteChatAsync(long notebookId, long sessionId)
    {
        if (!BeginDialog()) return;
        bool ok;
        try
        {
            ok = await new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = _l.Get(StringKey.DeleteChat),
                Content = _l.Get(StringKey.ConfirmDeleteChat),
                PrimaryButtonText = _l.Get(StringKey.Delete),
                CloseButtonText = _l.Get(StringKey.Cancel),
                DefaultButton = ContentDialogButton.Close,
            }.ShowAsync() == ContentDialogResult.Primary;
        }
        finally { EndDialog(); }
        if (!ok) return;
        await ViewModel.DeleteChatAsync(notebookId, sessionId, _sp.GetRequiredService<ChatEngineHolder>().Engine.Previews);
    }

    // ---------------------------------------------------------------- top bar

    /// <summary>Top bar "…": Sent context (of the latest answer), Rename chat, Delete chat.</summary>
    private void OnThreadMore(object sender, RoutedEventArgs e)
    {
        if (Nav.Selection is not ShellSelection.Chat chat || sender is not FrameworkElement anchor) return;
        var menu = new MenuFlyout();
        var last = _chat?.ViewModel.Messages.LastOrDefault(m => m.CanPreviewContext);
        if (last is not null)
        {
            menu.Items.Add(Item(StringKey.ContextPreviewSent, "IconSentContext", () =>
            {
                _chat!.ViewModel.ShowSentContextCommand.Execute(last);
                Nav.ShowPanel(PanelSegment.Context);
                return Task.CompletedTask;
            }));
            menu.Items.Add(new MenuFlyoutSeparator());
        }
        menu.Items.Add(Item(StringKey.RenameChat, "IconEdit", async () => await RenameChatAsync(chat.NotebookId, chat.SessionId)));
        menu.Items.Add(Item(StringKey.DeleteChat, "IconDelete", async () => await DeleteChatAsync(chat.NotebookId, chat.SessionId)));
        menu.ShowAt(anchor);
    }

    // ---------------------------------------------------------------- search, settings, tools, update

    private async Task ShowSearchAsync()
    {
        if (!BeginDialog()) return;
        try
        {
            var dialog = new GlobalSearchDialog { XamlRoot = XamlRoot };
            long? picked = null;
            dialog.ViewModel.NoteSelected += id => picked = id;
            await dialog.ShowAsync();
            if (picked is long noteId) await ViewModel.OpenNoteAsync(noteId);
        }
        finally { EndDialog(); }
    }

    /// <summary>Settings open in the main area (spec §2.5); Ctrl+, / sidebar / "Model settings…".</summary>
    private async Task ShowSettingsAsync(SettingsSection section)
    {
        if (Nav.Selection is ShellSelection.Settings) ShowSettingsPage(section);
        await Nav.NavigateAsync(new ShellSelection.Settings(section));
    }

    /// <summary>"+ › Run tool" / TabSwitch Transformations: the run-tool dialog (result → note document).</summary>
    private async Task ShowRunToolAsync(long? templateId = null)
    {
        if (Nav.NotebookId is not long nb || !BeginDialog()) return;
        try
        {
            var dialog = new Tools.RunToolDialog(nb, templateId) { XamlRoot = XamlRoot };
            await dialog.ShowAsync();
        }
        finally { EndDialog(); }
    }

    private void SyncUpdateIndicator()
    {
        var info = _updateState.Available;
        UpdateIndicator.Visibility = info is null ? Visibility.Collapsed : Visibility.Visible;
        if (info is not null)
            ToolTipService.SetToolTip(UpdateIndicator, string.Format(_l.Get(StringKey.UpdateBannerTitle), info.LatestVersion));
    }

    private async void OnUpdateIndicator(object sender, RoutedEventArgs e)
    {
        if (_updateState.Available is { } info) _ = await Launcher.LaunchUriAsync(new Uri(info.DownloadUrl));
    }

    // ---------------------------------------------------------------- keyboard

    private async void OnNewChatAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await ViewModel.NewChatAsync();
    }

    private void OnNewNotebookAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        OnNewNotebook(this, new RoutedEventArgs());
    }

    private async void OnSearchAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await ShowSearchAsync();
    }

    private void OnTogglePanelAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Nav.TogglePanel();
    }

    private async void OnBackAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = await Nav.GoBackAsync();
    }

    // ---------------------------------------------------------------- dialogs

    /// <summary>WinUI allows one ContentDialog at a time; ShowAsync throws when a second opens.</summary>
    private bool BeginDialog()
    {
        if (_dialogOpen) return false;
        _dialogOpen = true;
        return true;
    }

    private void EndDialog() => _dialogOpen = false;

    private async Task ShowMessageAsync(string title, string message)
    {
        if (!BeginDialog()) return;
        try
        {
            await new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = title,
                Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                CloseButtonText = _l.Get(StringKey.Close),
            }.ShowAsync();
        }
        finally { EndDialog(); }
    }

    /// <summary>Leaving an open note saves it immediately (no unsaved-changes dialog; macOS parity).</summary>
    private Task<bool> ConfirmLeaveDocumentAsync()
    {
        if (_editor.HasUnsavedChanges) _editor.FlushPendingSave?.Invoke();
        return Task.FromResult(true);
    }
}
