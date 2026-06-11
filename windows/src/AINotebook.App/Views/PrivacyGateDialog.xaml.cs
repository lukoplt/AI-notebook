using AINotebook.App.Services;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class PrivacyGateDialog : ContentDialog
{
    public PrivacyGateDialog(LocalizedStrings strings)
    {
        this.InitializeComponent();
        Title = strings.Get(StringKey.PrivacyGateTitle);
        BodyText.Text = strings.Get(StringKey.PrivacyGateBody);
        PrimaryButtonText = strings.Get(StringKey.PrivacyGateAcknowledge);
        CloseButtonText = strings.Get(StringKey.CancelButton);
        DefaultButton = ContentDialogButton.Close;
    }
}
