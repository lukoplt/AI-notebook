using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

/// <summary>
/// Add or edit an AI provider. Pass <paramref name="existing"/> to enter edit mode.
/// </summary>
public sealed partial class AddProviderDialog : ContentDialog
{
    public AddProviderViewModel ViewModel { get; }
    private readonly LocalizedStrings _strings;

    public AddProviderDialog(LocalizedStrings strings, ProviderConfig? existing = null)
    {
        this.InitializeComponent();
        _strings = strings;

        var sp = App.Current.Services;
        ViewModel = new AddProviderViewModel(
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<ISecretStore>(),
            existing);

        var isEdit = existing is not null;
        Title = _strings.Get(isEdit ? StringKey.EditProviderTitle : StringKey.AddProviderTitle);
        PrimaryButtonText = _strings.Get(StringKey.Save);
        CloseButtonText = _strings.Get(StringKey.CancelButton);
        DefaultButton = ContentDialogButton.Primary;

        // Type picker — Ollama can't be changed when editing
        TypeCombo.Header = _strings.Get(StringKey.ProviderTypeLabel);
        TypeCombo.ItemsSource = AddProviderViewModel.AllTypes.Select(TypeDisplayName).ToList();
        TypeCombo.SelectedIndex = Array.IndexOf(AddProviderViewModel.AllTypes, ViewModel.SelectedType);
        TypeCombo.IsEnabled = !ViewModel.IsOllamaProvider;

        NameBox.Header = _strings.Get(StringKey.ProviderNameLabel);
        NameBox.Text = ViewModel.Name;

        UrlBox.Header = _strings.Get(StringKey.ProviderUrlLabel);
        UrlBox.Text = ViewModel.BaseUrl;

        KeyBox.Header = _strings.Get(StringKey.ProviderApiKeyLabel);
        KeyBox.PlaceholderText = isEdit && !ViewModel.IsOllamaProvider
            ? "key saved — paste to replace"
            : _strings.Get(StringKey.ProviderApiKeyPlaceholder);

        TestButton.Content = _strings.Get(StringKey.ProviderTestButton);

        if (isEdit && !ViewModel.IsOllamaProvider)
        {
            DeleteButton.Content = _strings.Get(StringKey.ProviderDeleteTitle);
            DeleteButton.Visibility = Visibility.Visible;
        }

        ApplyTypeVisibility(ViewModel.SelectedType);
        UpdatePrimaryButton();

        Closing += OnClosing;
    }

    private static string TypeDisplayName(ProviderType t) => t switch
    {
        ProviderType.Anthropic => "Anthropic (Claude)",
        ProviderType.OpenAI => "OpenAI (ChatGPT)",
        ProviderType.OpenAICompatible => "OpenAI-compatible",
        _ => "Ollama (local)"
    };

    private void ApplyTypeVisibility(ProviderType t)
    {
        var isCloud = t != ProviderType.Ollama;
        KeyBox.Visibility = isCloud ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdatePrimaryButton()
        => IsPrimaryButtonEnabled = ViewModel.CanSave;

    private void OnTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        var idx = TypeCombo.SelectedIndex;
        if (idx < 0) return;
        var t = AddProviderViewModel.AllTypes[idx];
        ViewModel.SelectedType = t;
        UrlBox.Text = ViewModel.BaseUrl;
        ApplyTypeVisibility(t);
        UpdatePrimaryButton();
    }

    private void OnFieldChanged(object sender, object e)
    {
        ViewModel.Name = NameBox.Text;
        ViewModel.BaseUrl = UrlBox.Text;
        ViewModel.ApiKey = KeyBox.Password;
        UpdatePrimaryButton();
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        // Sync to VM before testing
        ViewModel.ApiKey = KeyBox.Password;
        ViewModel.BaseUrl = UrlBox.Text.Trim();
        TestSpinner.IsActive = true;
        TestButton.IsEnabled = false;
        await ViewModel.TestAsync();
        TestSpinner.IsActive = false;
        TestButton.IsEnabled = true;

        if (ViewModel.TestSucceeded)
        {
            TestSuccessBar.Message = _strings.Get(StringKey.ProviderTestSuccess);
            TestSuccessBar.IsOpen = true;
            TestStatusText.Text = "";
        }
        else
        {
            TestSuccessBar.IsOpen = false;
            TestStatusText.Text = ViewModel.TestStatus ?? "";
        }
    }

    private async void OnDelete(object sender, RoutedEventArgs e)
    {
        var confirm = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _strings.Get(StringKey.ProviderDeleteTitle),
            Content = _strings.Get(StringKey.ProviderDeleteConfirm),
            PrimaryButtonText = _strings.Get(StringKey.DeleteButton),
            CloseButtonText = _strings.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Close
        };
        this.Hide();
        var result = await confirm.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await ViewModel.DeleteAsync();
            // Signal deletion to caller via tag
            Tag = "deleted";
            // Don't reopen — close is final
            return;
        }
        await this.ShowAsync();
    }

    private async void OnClosing(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        if (args.Result != ContentDialogResult.Primary) return;

        // Sync VM fields from UI controls
        ViewModel.Name = NameBox.Text.Trim();
        ViewModel.BaseUrl = UrlBox.Text.Trim();
        ViewModel.ApiKey = KeyBox.Password;

        // Privacy gate for new cloud providers — defer close, show gate, then hide manually
        if (ViewModel.SelectedType != ProviderType.Ollama && ViewModel.EditingId is null)
        {
            args.Cancel = true; // keep dialog open while gate is shown
            this.Hide();        // hide this dialog so gate can appear
            var gate = new PrivacyGateDialog(_strings) { XamlRoot = this.XamlRoot };
            var gateResult = await gate.ShowAsync();
            if (gateResult == ContentDialogResult.Primary)
                Tag = await ViewModel.SaveConfirmedAsync();
            // If gate was cancelled, Tag stays null — caller reloads and nothing changed.
            return; // this.Hide() already closed us; don't proceed further
        }

        Tag = await ViewModel.SaveConfirmedAsync();
    }
}
