using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Services;

public interface IDialogService
{
    Task<bool> ConfirmAsync(XamlRoot root, string title, string message,
                            string primaryText, string cancelText, bool destructive = false);
    Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot root);
}
