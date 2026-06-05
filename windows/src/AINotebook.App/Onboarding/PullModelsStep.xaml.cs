using System.ComponentModel;
using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class PullModelsStep : UserControl
{
    private readonly OnboardingViewModel _vm;
    private bool _started;

    public PullModelsStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        TitleText.Text = strings.Get(StringKey.OnboardingPullTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingPullBody);
        ChatTitle.Text = strings.Get(StringKey.OnboardingPullingChat);
        EmbedTitle.Text = strings.Get(StringKey.OnboardingPullingEmbedding);
        _vm.PropertyChanged += OnVmChanged;
        Apply();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_started) return;
        _started = true;
        await _vm.RunModelPullsAsync();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e) => Apply();

    private void Apply()
    {
        ChatBar.Value = _vm.ChatPullFraction;
        ChatStatus.Text = _vm.ChatPullStatus;
        EmbedBar.Value = _vm.EmbeddingPullFraction;
        EmbedStatus.Text = _vm.EmbeddingPullStatus;
        if (string.IsNullOrEmpty(_vm.PullError))
        {
            ErrorText.Visibility = Visibility.Collapsed;
        }
        else
        {
            ErrorText.Text = _vm.PullError;
            ErrorText.Visibility = Visibility.Visible;
        }
    }
}
