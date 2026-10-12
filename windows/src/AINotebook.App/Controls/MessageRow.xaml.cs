using AINotebook.App.Chat;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace AINotebook.App.Controls;

/// <summary>What a message's hover action asked for; the hosting page performs it.</summary>
public enum MessageAction { Copy, Regenerate, SaveAsNote, SentContext, Edit }

public sealed class MessageActionEventArgs(MessageViewModel message, MessageAction action, FrameworkElement anchor) : EventArgs
{
    public MessageViewModel Message { get; } = message;
    public MessageAction Action { get; } = action;
    /// <summary>The button pressed (regenerate opens its "with provider…" menu here).</summary>
    public FrameworkElement Anchor { get; } = anchor;
}

public sealed class CitationTappedEventArgs(MessageViewModel message, int marker) : EventArgs
{
    public MessageViewModel Message { get; } = message;
    public int Marker { get; } = marker;
}

/// <summary>Replaces MessageBubble: user block / Markdown answer / hover actions (spec §2.2).</summary>
public sealed partial class MessageRow : UserControl
{
    public static readonly DependencyProperty ViewModelProperty =
        DependencyProperty.Register(nameof(ViewModel), typeof(MessageViewModel), typeof(MessageRow),
            new PropertyMetadata(null, (d, _) => ((MessageRow)d).Apply()));

    /// <summary>Regenerate / Edit / Sent context belong to the main thread; the note chat hides them.</summary>
    public static readonly DependencyProperty ShowThreadActionsProperty =
        DependencyProperty.Register(nameof(ShowThreadActions), typeof(bool), typeof(MessageRow),
            new PropertyMetadata(true, (d, _) => ((MessageRow)d).Apply()));

    public MessageViewModel? ViewModel
    {
        get => (MessageViewModel?)GetValue(ViewModelProperty);
        set => SetValue(ViewModelProperty, value);
    }

    public bool ShowThreadActions
    {
        get => (bool)GetValue(ShowThreadActionsProperty);
        set => SetValue(ShowThreadActionsProperty, value);
    }

    public event EventHandler<CitationTappedEventArgs>? CitationTapped;
    public event EventHandler<MessageActionEventArgs>? ActionRequested;

    private bool _hovered, _focused;

    public MessageRow()
    {
        InitializeComponent();
        var l = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        Label(CopyButton, l.Get(StringKey.MessageCopy));
        Label(RegenerateButton, l.Get(StringKey.ChatRegenerateButton));
        Label(SaveAsNoteButton, l.Get(StringKey.ChatSaveAsNoteButton));
        Label(SentContextButton, l.Get(StringKey.ContextPreviewSent));
        Label(EditButton, l.Get(StringKey.ChatEditButton));
        StoppedText.Text = l.Get(StringKey.ChatStopped);
        UserBlock.Padding = new Thickness(Token("SizeUserMessagePadH"), Token("SizeUserMessagePadV"),
            Token("SizeUserMessagePadH"), Token("SizeUserMessagePadV"));
        SizeChanged += (_, e) =>
            UserBlock.MaxWidth = Math.Max(0, e.NewSize.Width * Token("SizeUserMessageMaxPercent") / 100);
    }

    private static double Token(string key) => (double)Application.Current.Resources[key];

    private static void Label(FrameworkElement element, string text)
    {
        AutomationProperties.SetName(element, text);
        ToolTipService.SetToolTip(element, text);
    }

    private void Apply()
    {
        if (ViewModel is not { } vm) return;
        bool user = vm.IsUser;
        UserBlock.Visibility = user ? Visibility.Visible : Visibility.Collapsed;
        AnswerHost.Visibility = user ? Visibility.Collapsed : Visibility.Visible;
        Actions.HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        if (user) UserText.Text = vm.Content;
        else MarkdownRenderer.Render(AnswerHost, vm.Content, n => CitationTapped?.Invoke(this, new CitationTappedEventArgs(vm, n)));

        StoppedLabel.Visibility = Show(vm.IsStopped);
        RegenerateButton.Visibility = Show(ShowThreadActions && vm.IsLatestAssistant);
        SaveAsNoteButton.Visibility = Show(vm.CanSaveAsNote);
        SentContextButton.Visibility = Show(ShowThreadActions && vm.CanPreviewContext);
        EditButton.Visibility = Show(ShowThreadActions && vm.IsLatestUser);
        UpdateActionsOpacity();
    }

    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    private void UpdateActionsOpacity() =>
        Actions.Opacity = _hovered || _focused || ViewModel?.IsLatestAssistant == true ? 1 : 0;

    private void OnPointerEntered(object sender, PointerRoutedEventArgs e) { _hovered = true; UpdateActionsOpacity(); }
    private void OnPointerExited(object sender, PointerRoutedEventArgs e) { _hovered = false; UpdateActionsOpacity(); }
    private void OnGotFocus(object sender, RoutedEventArgs e) { _focused = true; UpdateActionsOpacity(); }
    private void OnLostFocus(object sender, RoutedEventArgs e) { _focused = false; UpdateActionsOpacity(); }

    private void Raise(MessageAction action, object sender)
    {
        if (ViewModel is { } vm && sender is FrameworkElement anchor)
            ActionRequested?.Invoke(this, new MessageActionEventArgs(vm, action, anchor));
    }

    private void OnCopy(object sender, RoutedEventArgs e) => Raise(MessageAction.Copy, sender);
    private void OnRegenerate(object sender, RoutedEventArgs e) => Raise(MessageAction.Regenerate, sender);
    private void OnSaveAsNote(object sender, RoutedEventArgs e) => Raise(MessageAction.SaveAsNote, sender);
    private void OnSentContext(object sender, RoutedEventArgs e) => Raise(MessageAction.SentContext, sender);
    private void OnEdit(object sender, RoutedEventArgs e) => Raise(MessageAction.Edit, sender);
}
