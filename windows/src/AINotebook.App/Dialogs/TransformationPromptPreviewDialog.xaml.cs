using System.Linq;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Dialogs;

public sealed partial class TransformationPromptPreviewDialog : ContentDialog
{
    public TransformationPromptPreviewDialog(Transformation transformation, Source? source)
    {
        var store = App.Current.Services.GetRequiredService<NotebookStore>();
        var t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        Title = t.Get("aiToolsPromptPreviewTitle");
        CloseButtonText = t.Get("cancelButton");

        // render = source is null
        //   ? transformation.PromptTemplate
        //   : transformation.PromptTemplate.Replace("{{source_text}}",
        //       string.Join("\n\n", store.Chunks(source.Id!.Value).Select(c => c.Text)));
        var render = source is null
            ? transformation.PromptTemplate
            : transformation.PromptTemplate.Replace("{{source_text}}",
                string.Join("\n\n", store.Chunks(source.Id!.Value).Select(c => c.Text)));

        PreviewText.Text = render;
    }
}
