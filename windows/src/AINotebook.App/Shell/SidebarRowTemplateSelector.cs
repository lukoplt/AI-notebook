using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Shell;

/// <summary>Picks the sidebar row template: notebook header, chat thread or "Show more".</summary>
public sealed partial class SidebarRowTemplateSelector : DataTemplateSelector
{
    public DataTemplate? NotebookTemplate { get; set; }
    public DataTemplate? ChatTemplate { get; set; }
    public DataTemplate? MoreTemplate { get; set; }

    protected override DataTemplate SelectTemplateCore(object item) => item switch
    {
        SidebarNotebookRow => NotebookTemplate!,
        SidebarMoreRow => MoreTemplate!,
        _ => ChatTemplate!,
    };

    protected override DataTemplate SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
