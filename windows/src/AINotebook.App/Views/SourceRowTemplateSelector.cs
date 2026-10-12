using AINotebook.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

/// <summary>Picks the row template for the grouped Sources list (folder header, source / member, folder footer).</summary>
public sealed partial class SourceRowTemplateSelector : DataTemplateSelector
{
    public DataTemplate? FolderTemplate { get; set; }
    public DataTemplate? SourceTemplate { get; set; }
    public DataTemplate? FooterTemplate { get; set; }

    protected override DataTemplate SelectTemplateCore(object item) => item switch
    {
        FolderRowViewModel => FolderTemplate!,
        FolderFooterRow => FooterTemplate!,
        _ => SourceTemplate!
    };

    protected override DataTemplate SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
