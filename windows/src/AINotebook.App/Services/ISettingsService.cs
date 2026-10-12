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
    bool AutoCheckUpdates { get; set; }
    DateTimeOffset? LastUpdateCheckUtc { get; set; }
    /// Shows the per-message web search toggle in the composer "+" menu (macOS AppSettings.webSearchEnabled).
    bool WebSearchEnabled { get; set; }
    /// Remembered right panel segment name; empty = collapsed (UI redesign §2.3).
    string RightPanel { get; set; }
    /// Remembered right panel width in epx (clamped to tokens panelMin…panelMax by the shell).
    double RightPanelWidth { get; set; }
}
