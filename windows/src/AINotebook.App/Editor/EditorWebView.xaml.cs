using System;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace AINotebook.App.Editor;

public sealed partial class EditorWebView : UserControl
{
    private AttachmentStore? _attachments;
    private AutoSaveController? _autoSave;
    private NoteEditorCoordinator? _coordinator;
    private ILocalizedStrings _t = null!;
    private DispatcherQueue _dispatcher = null!;
    private bool _initialized;
    private string _initialMarkdown = "";

    public Action<string>? OnSaveRequested { get; set; }   // -> NotesViewModel.Save(id, body)
    public Action? OnShowHistory { get; set; }
    public Action<string>? OnChange { get; set; }          // pushes md into NotesViewModel.DraftBody

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }
    public static readonly DependencyProperty TitleProperty =
        DependencyProperty.Register(nameof(Title), typeof(string), typeof(EditorWebView), new PropertyMetadata(""));

    public long NoteId { get; private set; }
    public string NoteUuid { get; private set; } = "";

    public EditorWebView()
    {
        InitializeComponent();
        _dispatcher = DispatcherQueue.GetForCurrentThread();
    }

    // Called once per note open. `initialMarkdown` seeds the editor; `onSave` is the autosave sink.
    public async void Configure(
        long noteId, string noteUuid, string initialMarkdown,
        AttachmentStore attachments, NoteEditorCoordinator coordinator,
        ILocalizedStrings t)
    {
        NoteId = noteId; NoteUuid = noteUuid; _initialMarkdown = initialMarkdown;
        _attachments = attachments; _coordinator = coordinator; _t = t;

        SaveButton.Content = "Save";
        HistoryButton.Content = _t.Get("historyButton");

        _autoSave = new AutoSaveController(_dispatcher, body =>
        {
            OnSaveRequested?.Invoke(body);
        });
        _autoSave.PropertyChanged += (_, _) => ApplyStatus();
        ApplyStatus();

        await InitWebAsync();
    }

    private async Task InitWebAsync()
    {
        try
        {
            await Web.EnsureCoreWebView2Async();
            var core = Web.CoreWebView2;

            // Editor assets served over https://appassets (folder copied at build, see M7).
            // AppContext.BaseDirectory + "Resources\editor".
            var editorFolder = System.IO.Path.Combine(AppContext.BaseDirectory, "Resources", "editor");
            if (!System.IO.File.Exists(System.IO.Path.Combine(editorFolder, "editor.html")))
            {
                ShowLoadFailed();
                return;
            }
            core.SetVirtualHostNameToFolderMapping(
                "appassets", editorFolder, CoreWebView2HostResourceAccessKind.Deny);

            // attachment://<noteUuid>/<filename> served from AttachmentStore (mirrors WKURLSchemeHandler).
            core.AddWebResourceRequestedFilter("attachment://*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += OnWebResourceRequested;

            core.WebMessageReceived += OnWebMessageReceived;

            // Block external navigation (mirrors mac decidePolicyFor: allow file/other, cancel else).
            core.NavigationStarting += (s, e) =>
            {
                if (!e.Uri.StartsWith("https://appassets/", StringComparison.OrdinalIgnoreCase) &&
                    !e.Uri.StartsWith("about:", StringComparison.OrdinalIgnoreCase))
                    e.Cancel = true;
            };

            _initialized = true;
            Web.Source = new Uri("https://appassets/editor.html");
        }
        catch (Exception)
        {
            ShowLoadFailed();
        }
    }

    private void ShowLoadFailed()
    {
        Web.Visibility = Visibility.Collapsed;
        LoadFailed.Visibility = Visibility.Visible;
        LoadFailed.Text = _t.Get("editorFailedToLoad");
    }

    private void OnWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        var msg = MarkdownHtmlBridge.Decode(e.WebMessageAsJson);
        switch (msg)
        {
            case EditorMessage.Ready:
                var escaped = MarkdownHtmlBridge.EscapeForTemplateLiteral(_initialMarkdown);
                _ = Web.CoreWebView2.ExecuteScriptAsync(
                    $"window.aino && window.aino.setContent(`{escaped}`)");
                break;
            case EditorMessage.Change c:
                OnChange?.Invoke(c.Markdown);
                _autoSave?.NoteDidChange(c.Markdown);
                break;
            case EditorMessage.Save s:
                OnChange?.Invoke(s.Markdown);
                _autoSave?.NoteDidChange(s.Markdown);
                break;
            case EditorMessage.AttachmentRequest a:
                HandleAttachment(a);
                break;
        }
    }

    private void HandleAttachment(EditorMessage.AttachmentRequest a)
    {
        if (_attachments is null) { Deny(a.RequestId); return; }
        byte[] bytes;
        try { bytes = Convert.FromBase64String(a.Base64); }
        catch { Deny(a.RequestId); return; }

        try
        {
            var att = _attachments.Save(NoteId, NoteUuid, a.Filename, a.Mime, bytes);
            var url = $"attachment://{NoteUuid}/{att.Filename}";
            var js = $"window.aino && window.aino.attachmentSaved && window.aino.attachmentSaved('{a.RequestId}', '{JsEscape(url)}', '{JsEscape(a.Mime)}')";
            _ = Web.CoreWebView2.ExecuteScriptAsync(js);
        }
        catch
        {
            Deny(a.RequestId);
        }
    }

    private void Deny(string requestId) =>
        _ = Web.CoreWebView2.ExecuteScriptAsync(
            $"window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied('{requestId}')");

    private static string JsEscape(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'");

    private void OnWebResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        try
        {
            var uri = new Uri(e.Request.Uri);
            if (uri.Scheme != "attachment") return;
            var host = uri.Host;                       // noteUuid
            var filename = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/'));
            if (host.Length == 0 || filename.Length == 0) return;

            var bytes = _attachments!.Read(host, filename);
            var mime = GuessMime(System.IO.Path.GetExtension(filename));
            var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                writer.StoreAsync().AsTask().Wait();
                writer.FlushAsync().AsTask().Wait();
                writer.DetachStream();
            }
            stream.Seek(0);
            e.Response = sender.Environment.CreateWebResourceResponse(
                stream, 200, "OK",
                $"Content-Type: {mime}\r\nContent-Length: {bytes.Length}");
        }
        catch
        {
            // leave e.Response null -> WebView2 fails the request (mirrors didFailWithError).
        }
    }

    private static string GuessMime(string ext) => ext.ToLowerInvariant() switch
    {
        ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".pdf" => "application/pdf",
        ".txt" => "text/plain",
        ".md" => "text/markdown",
        _ => "application/octet-stream"
    };

    private void ApplyStatus()
    {
        if (_autoSave is null) return;
        (StatusIcon.Glyph, StatusText.Text) = _autoSave.Status switch
        {
            SaveState.Saved   => ("\uE73E", _t.Get("editorStatusSaved")),
            SaveState.Saving  => ("\uE895", _t.Get("editorStatusSaving")),
            SaveState.Unsaved => ("\uE70F", _t.Get("editorStatusUnsaved")),
            SaveState.Error   => ("\uE783", $"{_t.Get("editorStatusError")} — {_autoSave.ErrorText}"),
            _ => ("\uE73E", _t.Get("editorStatusSaved"))
        };
        // Drive the unsaved gate consumed by NotesViewModel (mirrors coordinator wiring).
        if (_coordinator is not null) _coordinator.HasUnsavedChanges = _autoSave.HasUnsavedChanges;
    }

    private void OnSaveClick(object sender, RoutedEventArgs e) => _autoSave?.ManualSave();
    private void OnHistoryClick(object sender, RoutedEventArgs e) => OnShowHistory?.Invoke();

    // Mirrors coordinator.flushPendingSave wiring: NotesViewModel calls this to flush before switching.
    public void FlushPendingSave() => _autoSave?.ManualSave();
}
