using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Services;

public sealed class DialogService : IDialogService
{
    public async Task<bool> ConfirmAsync(XamlRoot root, string title, string message,
                                         string primaryText, string cancelText, bool destructive = false)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = message,
            PrimaryButtonText = primaryText,
            CloseButtonText = cancelText,
            DefaultButton = ContentDialogButton.Close
        };
        if (destructive)
            dialog.PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    public async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot root)
    {
        dialog.XamlRoot = root;
        return await dialog.ShowAsync();
    }
}
