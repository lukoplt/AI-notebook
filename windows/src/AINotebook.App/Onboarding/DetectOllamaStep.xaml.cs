using System.ComponentModel;
using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI;
using Windows.UI;

namespace AINotebook.App.Onboarding;

public sealed partial class DetectOllamaStep : UserControl
{
    private readonly OnboardingViewModel _vm;
    private readonly LocalizedStrings _strings;

    public DetectOllamaStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        _strings = strings;
        TitleText.Text = strings.Get(StringKey.OnboardingDetectTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingDetectBody);
        FoundText.Text = strings.Get(StringKey.OnboardingDetectFound);
        ContinueButton.Content = strings.Get(StringKey.ContinueLabel);
        WaitingText.Text = strings.Get(StringKey.OnboardingDetectWaiting);
        DownloadButton.Content = strings.Get(StringKey.OpenOllamaDownload);
        _vm.PropertyChanged += OnVmChanged;
        Apply();
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _vm.StartDetectionPolling();
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _vm.StopDetectionPolling();
        _vm.PropertyChanged -= OnVmChanged;
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingViewModel.IsOllamaReachable)) Apply();
    }

    private void Apply()
    {
        var up = _vm.IsOllamaReachable;
        FoundPanel.Visibility = up ? Visibility.Visible : Visibility.Collapsed;
        WaitingPanel.Visibility = up ? Visibility.Collapsed : Visibility.Visible;
        StatusIcon.Glyph = up ? "\uE73E" : "\uE9A9"; // check vs cloud
        StatusIcon.Foreground = up
            ? new SolidColorBrush(Color.FromArgb(255, 16, 124, 16))
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
    }

    private void OnContinue(object sender, RoutedEventArgs e)
    {
        _vm.StopDetectionPolling();
        _vm.Advance();
    }

    private async void OnOpenDownload(object sender, RoutedEventArgs e)
        => await _vm.OpenOllamaDownloadAsync();
}
