using AINotebook.App.Services;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;

namespace AINotebook.App.Onboarding;

public sealed partial class PickModelsStep : UserControl
{
    private static readonly string[] ChatChoices = { "llama3.2:3b", "llama3.1:8b", "mistral:7b" };
    private static readonly string[] EmbedChoices = { "nomic-embed-text", "mxbai-embed-large" };

    private readonly OnboardingViewModel _vm;
    private readonly ISettingsService _settings;

    public PickModelsStep(OnboardingViewModel vm, ISettingsService settings, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        _settings = settings;

        TitleText.Text = strings.Get(StringKey.OnboardingPickModelsTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingPickModelsBody);
        ChatCombo.Header = strings.Get(StringKey.ChatModel);
        EmbedCombo.Header = strings.Get(StringKey.EmbeddingModel);
        ContinueButton.Content = strings.Get(StringKey.ContinueLabel);

        ChatCombo.ItemsSource = ChatChoices;
        EmbedCombo.ItemsSource = EmbedChoices;
        ChatCombo.SelectedItem = ChatChoices.Contains(settings.SelectedChatModel)
            ? settings.SelectedChatModel : ChatChoices[0];
        EmbedCombo.SelectedItem = EmbedChoices.Contains(settings.SelectedEmbeddingModel)
            ? settings.SelectedEmbeddingModel : EmbedChoices[0];
    }

    private void OnChatChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ChatCombo.SelectedItem is string s) _settings.SelectedChatModel = s;
    }

    private void OnEmbedChanged(object sender, SelectionChangedEventArgs e)
    {
        if (EmbedCombo.SelectedItem is string s) _settings.SelectedEmbeddingModel = s;
    }

    private void OnContinue(object sender, RoutedEventArgs e) => _vm.Advance();
}
