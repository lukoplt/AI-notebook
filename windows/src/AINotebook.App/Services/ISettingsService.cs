using System.ComponentModel;
using AINotebook.Core;

namespace AINotebook.App.Services;

/// Port of the mac AppSettings (UserDefaults-backed) over ApplicationData.LocalSettings.
public interface ISettingsService : INotifyPropertyChanged
{
    AppLanguage Language { get; set; }
    bool HasCompletedOnboarding { get; set; }
    string SelectedChatModel { get; set; }      // default "llama3.2:3b"
    string SelectedEmbeddingModel { get; set; } // default "nomic-embed-text"
}
