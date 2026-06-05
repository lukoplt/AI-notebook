using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class DoneStep : UserControl
{
    private readonly OnboardingViewModel _vm;

    public DoneStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        TitleText.Text = strings.Get(StringKey.OnboardingDoneTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingDoneBody);
        StartButton.Content = strings.Get(StringKey.StartUsingApp);
    }

    private void OnStart(object sender, RoutedEventArgs e) => _vm.MarkCompleted();
}
