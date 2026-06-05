using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class WelcomeStep : UserControl
{
    private readonly OnboardingViewModel _vm;

    public WelcomeStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        TitleText.Text = strings.Get(StringKey.Welcome);
        BodyText.Text = strings.Get(StringKey.WelcomeBody);
        ContinueButton.Content = strings.Get(StringKey.ContinueLabel);
    }

    private void OnContinue(object sender, RoutedEventArgs e) => _vm.Advance();
}
