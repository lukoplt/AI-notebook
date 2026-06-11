using System.ComponentModel;
using AINotebook.Core;
using AINotebook.Core.Models;

namespace AINotebook.App.Services;

/// Port of the mac AppSettings (UserDefaults-backed) over ApplicationData.LocalSettings.
public interface ISettingsService : INotifyPropertyChanged
{
    AppLanguage Language { get; set; }
    bool HasCompletedOnboarding { get; set; }
    string SelectedChatModel { get; set; }           // model name within selected chat provider
    string SelectedEmbeddingModel { get; set; }      // model name within selected embedding provider
    string SelectedChatProviderId { get; set; }      // default = Ollama well-known ID
    string SelectedEmbeddingProviderId { get; set; } // default = Ollama well-known ID
}
