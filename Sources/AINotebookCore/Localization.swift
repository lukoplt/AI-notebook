public struct AppText: Sendable {
    public enum Key: CaseIterable, Sendable {
        case appName
        case settings
        case language
        case version
        case notebooks
        case sources
        case chat
        case notes
        case transformations
        case noNotebookSelected
        case createNotebook
        case renameNotebook
        case deleteNotebook
        case notebookName
        case notebookDescription
        case cancel
        case create
        case save
        case delete
        case confirmDeleteNotebook
        case cannotBeEmpty
        case comingSoon
        case sourcesTabComingSoon
        case chatTabComingSoon
        case notesTabComingSoon
        case transformationsTabComingSoon
        case welcome
        case welcomeBody
        case continueLabel
        case onboardingDetectTitle
        case onboardingDetectBody
        case onboardingDetectChecking
        case onboardingDetectFound
        case openOllamaDownload
        case onboardingDetectWaiting
        case onboardingPickModelsTitle
        case onboardingPickModelsBody
        case chatModel
        case embeddingModel
        case onboardingPullTitle
        case onboardingPullBody
        case onboardingPullingChat
        case onboardingPullingEmbedding
        case onboardingDoneTitle
        case onboardingDoneBody
        case ollamaUnreachable
        case startUsingApp
        case sourcesSectionTitle
        case addSourceButton
        case addSourceSheetTitle
        case addSourceFromFile
        case addSourceFromURL
        case addSourceFromText
        case addSourceURLPlaceholder
        case addSourceTitlePlaceholder
        case addSourceTextPlaceholder
        case addSourceConfirm
        case cancelButton
        case sourceStatusPending
        case sourceStatusChunking
        case sourceStatusReady
        case sourceStatusError
        case noSourcesEmptyState
        case deleteSourceConfirm
        case deleteButton
        case indexingInProgress
        case indexingProgressFormat
        case indexingComplete
        case indexingError
        case indexingPaused
        case indexingIdle
        case chatNewSessionTitle
        case chatInputPlaceholder
        case chatSendButton
        case chatEmptyState
        case chatErrorPrefix
        case chatCitationsSectionTitle
        case chatNoCitationsForMessage
        case chatRegenerateButton
    }

    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }

    public func string(_ key: Key) -> String {
        switch language {
        case .english:
            english(key)
        case .czech:
            czech(key)
        }
    }

    private func english(_ key: Key) -> String {
        switch key {
        case .appName:           "AI Notebook"
        case .settings:          "Settings"
        case .language:          "Language"
        case .version:           "Version"
        case .notebooks:         "Notebooks"
        case .sources:           "Sources"
        case .chat:              "Chat"
        case .notes:             "Notes"
        case .transformations:   "Transformations"
        case .noNotebookSelected: "No notebook selected"
        case .createNotebook:    "Create notebook"
        case .renameNotebook:    "Rename notebook"
        case .deleteNotebook:    "Delete notebook"
        case .notebookName:      "Notebook name"
        case .notebookDescription: "Description (optional)"
        case .cancel:            "Cancel"
        case .create:            "Create"
        case .save:              "Save"
        case .delete:            "Delete"
        case .confirmDeleteNotebook: "Delete this notebook? This cannot be undone."
        case .cannotBeEmpty:     "Name cannot be empty."
        case .comingSoon:        "Coming soon"
        case .sourcesTabComingSoon: "Source ingestion arrives in milestone M3."
        case .chatTabComingSoon:    "Chat arrives in milestone M5."
        case .notesTabComingSoon:   "Notes arrive in milestone M6."
        case .transformationsTabComingSoon: "Transformations arrive in milestone M6."
        case .welcome:                     "Welcome"
        case .welcomeBody:                 "AI Notebook keeps everything local. To run AI, we'll use Ollama on your Mac."
        case .continueLabel:               "Continue"
        case .onboardingDetectTitle:       "Check Ollama"
        case .onboardingDetectBody:        "We're looking for a running Ollama on your Mac."
        case .onboardingDetectChecking:    "Checking…"
        case .onboardingDetectFound:       "Ollama is running."
        case .openOllamaDownload:          "Open download page"
        case .onboardingDetectWaiting:     "Waiting for Ollama to start…"
        case .onboardingPickModelsTitle:   "Pick models"
        case .onboardingPickModelsBody:    "Defaults are fine for most people. You can change them later in Settings."
        case .chatModel:                   "Chat model"
        case .embeddingModel:              "Embedding model"
        case .onboardingPullTitle:         "Downloading models"
        case .onboardingPullBody:          "This is a one-time download. Keep the app open."
        case .onboardingPullingChat:       "Chat model"
        case .onboardingPullingEmbedding:  "Embedding model"
        case .onboardingDoneTitle:         "All set"
        case .onboardingDoneBody:          "You can now create your first notebook."
        case .ollamaUnreachable:           "Cannot reach Ollama. Is it running?"
        case .startUsingApp:               "Start using the app"
        case .sourcesSectionTitle:         "Sources"
        case .addSourceButton:             "Add source"
        case .addSourceSheetTitle:         "Add a source"
        case .addSourceFromFile:           "From file…"
        case .addSourceFromURL:            "From URL"
        case .addSourceFromText:           "Paste text"
        case .addSourceURLPlaceholder:     "https://example.com/article"
        case .addSourceTitlePlaceholder:   "Title"
        case .addSourceTextPlaceholder:    "Paste content here"
        case .addSourceConfirm:            "Add"
        case .cancelButton:                "Cancel"
        case .sourceStatusPending:         "Pending"
        case .sourceStatusChunking:        "Processing"
        case .sourceStatusReady:           "Ready"
        case .sourceStatusError:           "Error"
        case .noSourcesEmptyState:         "No sources yet. Add one to get started."
        case .deleteSourceConfirm:         "Delete this source?"
        case .deleteButton:                "Delete"
        case .indexingInProgress:          "Indexing %@…"
        case .indexingProgressFormat:      "%d / %d chunks"
        case .indexingComplete:            "Indexed"
        case .indexingError:               "Indexing error"
        case .indexingPaused:              "Indexing paused"
        case .indexingIdle:                "Idle"
        case .chatNewSessionTitle:         "New chat"
        case .chatInputPlaceholder:        "Ask anything about your sources…"
        case .chatSendButton:              "Send"
        case .chatEmptyState:              "Start by asking a question."
        case .chatErrorPrefix:             "Chat error: "
        case .chatCitationsSectionTitle:   "Citations"
        case .chatNoCitationsForMessage:   "No citations"
        case .chatRegenerateButton:        "Regenerate"
        }
    }

    private func czech(_ key: Key) -> String {
        switch key {
        case .appName:           "AI Notebook"
        case .settings:          "Nastavení"
        case .language:          "Jazyk"
        case .version:           "Verze"
        case .notebooks:         "Poznámkové bloky"
        case .sources:           "Zdroje"
        case .chat:              "Chat"
        case .notes:             "Poznámky"
        case .transformations:   "Transformace"
        case .noNotebookSelected: "Žádný blok není vybrán"
        case .createNotebook:    "Vytvořit blok"
        case .renameNotebook:    "Přejmenovat blok"
        case .deleteNotebook:    "Smazat blok"
        case .notebookName:      "Název bloku"
        case .notebookDescription: "Popis (volitelný)"
        case .cancel:            "Zrušit"
        case .create:            "Vytvořit"
        case .save:              "Uložit"
        case .delete:            "Smazat"
        case .confirmDeleteNotebook: "Opravdu smazat tento blok? Akci nelze vrátit zpět."
        case .cannotBeEmpty:     "Název nesmí být prázdný."
        case .comingSoon:        "Brzy"
        case .sourcesTabComingSoon: "Načítání zdrojů přijde v milníku M3."
        case .chatTabComingSoon:    "Chat přijde v milníku M5."
        case .notesTabComingSoon:   "Poznámky přijdou v milníku M6."
        case .transformationsTabComingSoon: "Transformace přijdou v milníku M6."
        case .welcome:                     "Vítejte"
        case .welcomeBody:                 "AI Notebook udržuje vše lokálně. K AI použijeme Ollamu spuštěnou na vašem Macu."
        case .continueLabel:               "Pokračovat"
        case .onboardingDetectTitle:       "Kontrola Ollamy"
        case .onboardingDetectBody:        "Hledáme spuštěnou Ollamu na vašem Macu."
        case .onboardingDetectChecking:    "Hledám…"
        case .onboardingDetectFound:       "Ollama běží."
        case .openOllamaDownload:          "Otevřít stránku ke stažení"
        case .onboardingDetectWaiting:     "Čekám, až se Ollama spustí…"
        case .onboardingPickModelsTitle:   "Vyberte modely"
        case .onboardingPickModelsBody:    "Výchozí hodnoty vyhovují většině uživatelů. Změnit je můžete později v Nastavení."
        case .chatModel:                   "Model pro chat"
        case .embeddingModel:              "Model pro embeddingy"
        case .onboardingPullTitle:         "Stahuji modely"
        case .onboardingPullBody:          "Tohle je jednorázové stažení. Nechte aplikaci spuštěnou."
        case .onboardingPullingChat:       "Model pro chat"
        case .onboardingPullingEmbedding:  "Model pro embeddingy"
        case .onboardingDoneTitle:         "Hotovo"
        case .onboardingDoneBody:          "Teď můžete vytvořit svůj první poznámkový blok."
        case .ollamaUnreachable:           "Nelze se připojit k Ollamě. Je spuštěná?"
        case .startUsingApp:               "Začít používat aplikaci"
        case .sourcesSectionTitle:         "Zdroje"
        case .addSourceButton:             "Přidat zdroj"
        case .addSourceSheetTitle:         "Přidat zdroj"
        case .addSourceFromFile:           "Ze souboru…"
        case .addSourceFromURL:            "Z URL adresy"
        case .addSourceFromText:           "Vložit text"
        case .addSourceURLPlaceholder:     "https://example.com/clanek"
        case .addSourceTitlePlaceholder:   "Název"
        case .addSourceTextPlaceholder:    "Vložte obsah sem"
        case .addSourceConfirm:            "Přidat"
        case .cancelButton:                "Zrušit"
        case .sourceStatusPending:         "Čeká"
        case .sourceStatusChunking:        "Zpracovává se"
        case .sourceStatusReady:           "Hotovo"
        case .sourceStatusError:           "Chyba"
        case .noSourcesEmptyState:         "Zatím žádné zdroje. Přidejte první, abyste mohli začít."
        case .deleteSourceConfirm:         "Smazat tento zdroj?"
        case .deleteButton:                "Smazat"
        case .indexingInProgress:          "Indexuji %@…"
        case .indexingProgressFormat:      "%d / %d částí"
        case .indexingComplete:            "Indexováno"
        case .indexingError:               "Chyba při indexaci"
        case .indexingPaused:              "Indexace pozastavena"
        case .indexingIdle:                "Nečinné"
        case .chatNewSessionTitle:         "Nový chat"
        case .chatInputPlaceholder:        "Zeptej se na cokoli ze svých zdrojů…"
        case .chatSendButton:              "Odeslat"
        case .chatEmptyState:              "Začněte položením otázky."
        case .chatErrorPrefix:             "Chyba chatu: "
        case .chatCitationsSectionTitle:   "Citace"
        case .chatNoCitationsForMessage:   "Žádné citace"
        case .chatRegenerateButton:        "Znovu vygenerovat"
        }
    }
}
