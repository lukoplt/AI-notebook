using System;
using System.Collections.Generic;
using System.Linq;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace AINotebook.App.Controls;

public sealed record CitationChip(Citation Citation)
{
    public string Marker => $"[{Citation.Marker}]";
}

public sealed partial class MessageBubble : UserControl
{
    public static readonly DependencyProperty ViewModelProperty =
        DependencyProperty.Register(nameof(ViewModel), typeof(MessageViewModel),
            typeof(MessageBubble), new PropertyMetadata(null, OnViewModelChanged));

    public MessageViewModel? ViewModel
    {
        get => (MessageViewModel?)GetValue(ViewModelProperty);
        set => SetValue(ViewModelProperty, value);
    }

    public HorizontalAlignment UserAlignment =>
        ViewModel?.IsUser == true ? HorizontalAlignment.Right : HorizontalAlignment.Left;

    public IReadOnlyList<CitationChip> Chips =>
        ViewModel?.Citations.Select(c => new CitationChip(c)).ToList() ?? new();

    public event EventHandler<Citation>? CitationTapped;
    public event EventHandler<MessageViewModel>? SaveAsNoteRequested;

    public MessageBubble()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            ApplyStyle();
            // Localize the per-bubble "Save as note" label from LocalizedStrings.
            var t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
            SaveAsNoteButton.Content = t.Get("chatSaveAsNoteButton");
        };
    }

    private static void OnViewModelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((MessageBubble)d).ApplyStyle();

    private void ApplyStyle()
    {
        if (ViewModel is null) return;
        BubbleBack.Background = new SolidColorBrush(
            ViewModel.IsUser ? Color.FromArgb(46, 0, 120, 215)   // accent @ ~0.18
                             : Color.FromArgb(26, 128, 128, 128)); // secondary @ ~0.10
        Bubble.HorizontalAlignment = UserAlignment;
    }

    private void OnCitationClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is Citation c)
            CitationTapped?.Invoke(this, c);
    }

    private void OnSaveAsNoteClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) SaveAsNoteRequested?.Invoke(this, ViewModel);
    }
}
