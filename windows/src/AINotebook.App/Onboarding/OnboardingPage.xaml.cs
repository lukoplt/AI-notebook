using System.ComponentModel;
using AINotebook.App.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class OnboardingPage : Page
{
    public OnboardingViewModel ViewModel { get; }
    private readonly ISettingsService _settings;
    private readonly LocalizedStrings _strings;

    public event EventHandler? CompletedRequested;

    public OnboardingPage()
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        ViewModel = sp.GetRequiredService<OnboardingViewModel>();
        _settings = sp.GetRequiredService<ISettingsService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();

        ViewModel.PropertyChanged += OnVmChanged;
        _settings.PropertyChanged += OnSettingsChanged;
        ShowStep(ViewModel.Step);
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingViewModel.Step))
            ShowStep(ViewModel.Step);
    }

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ISettingsService.HasCompletedOnboarding)
            && _settings.HasCompletedOnboarding)
        {
            CompletedRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void ShowStep(OnboardingStep step)
    {
        StepHost.Content = step switch
        {
            OnboardingStep.Welcome => new WelcomeStep(ViewModel, _strings),
            OnboardingStep.DetectOllama => new DetectOllamaStep(ViewModel, _strings),
            OnboardingStep.PickModels => new PickModelsStep(ViewModel, _settings, _strings),
            OnboardingStep.PullModels => new PullModelsStep(ViewModel, _strings),
            OnboardingStep.Done => new DoneStep(ViewModel, _strings),
            _ => new WelcomeStep(ViewModel, _strings)
        };
    }
}
