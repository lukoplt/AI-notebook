using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class SourcePreviewDialog : ContentDialog
{
    public SourcePreviewViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public SourcePreviewDialog(Source source)
    {
        var sp = App.Current.Services;
        ViewModel = sp.GetRequiredService<SourcePreviewViewModel>();
        _t = sp.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        Title = _t.Get(StringKey.SourcePreviewTitle);

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SourcePreviewViewModel.ChunkCount))
                ChunkCountLabel.Text = $"{ViewModel.ChunkCount} {_t.Get(StringKey.SourcePreviewChunksLabel)}";
        };

        _ = ViewModel.LoadAsync(source);
    }
}
