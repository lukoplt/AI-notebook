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
        case chatSessionsLabel
        case chatNewSessionButton
        case chatDeleteSessionButton
        case chatSaveAsNoteButton
        case notesSectionTitle
        case notesEmptyState
        case notesNewButton
        case noteUntitled
        case noteTitlePlaceholder
        case noteBodyPlaceholder
        case noteOriginManual
        case noteOriginChat
        case noteOriginTransformation
        case transformationsSectionTitle
        case transformationPickerLabel
        case transformationSourcePickerLabel
        case transformationRunButton
        case transformationResultTitle
        case transformationRunningStatus
        case transformationEditButton
        case transformationEditorTitle
        case transformationEditorNew
        case transformationEditorDelete
        case transformationEditorNamePlaceholder
        case transformationEditorTemplatePlaceholder
        case reembedButton
        case reembedConfirm
        case reembedConfirmYes
        case embeddingSectionTitle
        case currentModelLabel
        case manageModelsButton
        case manageModelsTitle
        case manageModelsPullPlaceholder
        case manageModelsPullButton
        case manageModelsRefreshButton
        case chatModelPickerLabel
        case embeddingModelPickerLabel
        case providersSectionTitle
        case addProviderButton
        case addProviderTitle
        case editProviderTitle
        case providerTypeLabel
        case providerNameLabel
        case providerUrlLabel
        case providerApiKeyLabel
        case providerKeySavedLabel
        case providerTestButton
        case providerTestSuccess
        case providerDeleteButton
        case providerDeleteConfirm
        case chatProviderPickerLabel
        case embeddingProviderPickerLabel
        case customModelFieldLabel
        case providerBadgeChat
        case providerBadgeEmbedding
        case privacyGateTitle
        case privacyGateMessage
        case privacyGateAccept
        case errorInvalidApiKey
        case errorRateLimited
        case errorModelRefusal
        case errorConsentRequired
        case modelsUnavailableCaption
        case doneButton
        case openNoteFromCitation
        case notesChatPanelTitle
        case notesChatPanelEmpty
        case notesChatCurrentNoteHint
        case editorStatusSaved
        case editorStatusSaving
        case editorStatusUnsaved
        case editorStatusError
        case editorFailedToLoad
        case attachmentBrokenLink
        case attachmentSaveFailed
        case attachmentOpenButton
        case historyButton
        case historySheetTitle
        case historyEmpty
        case historyRestoreButton
        case historyReasonAutosave
        case historyReasonRestore
        case aiToolsSectionTitle
        case aiToolsEmptyTitle
        case aiToolsEmptyBody
        case aiToolsScopeAllSources
        case aiToolsScopeHint
        case aiToolsPreviewButton
        case aiToolsHistoryButton
        case aiToolsResultSavedFormat
        case aiToolsOpenNoteButton
        case aiToolsRunningFormat
        case aiToolsBatchSavedFormat
        case aiToolsPromptPreviewTitle
        case aiToolsHistoryEmpty
        case aiToolsHistoryTitle
        case aiToolsDescriptionPlaceholder
        case unsavedChangesTitle
        case unsavedChangesMessage
        case unsavedSaveButton
        case unsavedDiscardButton
        case chatFollowupsLabel
        case sourceSummaryLabel
        case sourceSummarizeButton
        case sourceSummarizingStatus
        case chatScopeButton
        case chatScopeAllSources
        case chatScopeTitle
        case updateBannerTitle
        case updateDownloadButton
        case updateLaterButton
        case updateAutoCheckToggle
        case updateCheckNowButton
        case updateStatusChecking
        case updateStatusUpToDate
        case updateStatusAvailable
        case updateStatusFailed
        // Epic C1 — per-notebook chat instructions
        case notebookInstructions
        case notebookInstructionsHint
        // Epic B1/B2/B3 — export & backup
        case exportBackupMenu
        case exportNoteMarkdown
        case exportNotebookZip
        case backupDatabase
        case restoreDatabase
        case restoreConfirm
        case exportDone
        // Epic B4 — global search
        case globalSearchTitle
        case globalSearchPlaceholder
        case globalSearchNotesSection
        case globalSearchSourcesSection
        case globalSearchEmpty
        // Epic B7 — source preview
        case sourcePreviewTitle
        case sourcePreviewChunksHeader
        case sourcePreviewOpenOriginal
        case sourcePreviewNoChunks
        // Epic B8 — tags
        case tagsLabel
        case tagAddPlaceholder
        case tagFilterAll
        case tagFilterMenu
        // Epic B6 — bulk operations
        case bulkSelect
        case bulkDone
        case bulkDelete
        case bulkSummarize
        // Epic C2 — source sets
        case sourceSetsLabel
        case sourceSetSaveCurrent
        case sourceSetNamePlaceholder
        // Epic C3 — regenerate / edit
        case chatRegenerate
        case chatEdit
        // Epic E3 — web search
        case webSearchToggle
        case webSearchChatToggle
        // Epic E1/E2 — live sources
        case watchFolderButton
        case recrawlSourceButton
        // Epic C5 — personas
        case personaMenu
        case personaNone
        case personaNew
        case personaNamePlaceholder
        case personaInstructionsPlaceholder
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
        case .chatSessionsLabel:           "Sessions"
        case .chatNewSessionButton:        "New session"
        case .chatDeleteSessionButton:     "Delete session"
        case .chatSaveAsNoteButton:        "Save as note"
        case .notesSectionTitle:           "Notes"
        case .notesEmptyState:             "No notes yet. Create one or save from chat."
        case .notesNewButton:              "New note"
        case .noteUntitled:                "Untitled"
        case .noteTitlePlaceholder:        "Title"
        case .noteBodyPlaceholder:         "Write Markdown here…"
        case .noteOriginManual:            "Manual"
        case .noteOriginChat:              "From chat"
        case .noteOriginTransformation:    "From transformation"
        case .transformationsSectionTitle: "Transformations"
        case .transformationPickerLabel:   "Transformation"
        case .transformationSourcePickerLabel: "Source"
        case .transformationRunButton:     "Run"
        case .transformationResultTitle:   "Result"
        case .transformationRunningStatus: "Running…"
        case .transformationEditButton:    "Edit templates"
        case .transformationEditorTitle:   "Custom transformations"
        case .transformationEditorNew:     "New"
        case .transformationEditorDelete:  "Delete"
        case .transformationEditorNamePlaceholder:     "Template name"
        case .transformationEditorTemplatePlaceholder: "Prompt template (use {{source_text}})"
        case .reembedButton:               "Re-embed all sources"
        case .reembedConfirm:              "This deletes existing embeddings and re-runs them with the current model. Continue?"
        case .reembedConfirmYes:           "Re-embed"
        case .embeddingSectionTitle:       "Embedding"
        case .currentModelLabel:           "Current model"
        case .manageModelsButton:          "Manage models…"
        case .manageModelsTitle:           "Installed Ollama models"
        case .manageModelsPullPlaceholder: "Pull model name (e.g. mistral:7b)"
        case .manageModelsPullButton:      "Pull"
        case .manageModelsRefreshButton:   "Refresh list"
        case .chatModelPickerLabel:        "Chat model"
        case .embeddingModelPickerLabel:   "Embedding model"
        case .providersSectionTitle:        "AI providers"
        case .addProviderButton:            "Add provider…"
        case .addProviderTitle:             "Add provider"
        case .editProviderTitle:            "Edit provider"
        case .providerTypeLabel:            "Type"
        case .providerNameLabel:            "Name"
        case .providerUrlLabel:             "Base URL"
        case .providerApiKeyLabel:          "API key"
        case .providerKeySavedLabel:        "Key saved ✓ — paste to replace"
        case .providerTestButton:           "Test connection"
        case .providerTestSuccess:          "Connection OK"
        case .providerDeleteButton:         "Delete provider"
        case .providerDeleteConfirm:        "Delete this provider? Its API key will be removed from the Keychain."
        case .chatProviderPickerLabel:      "Chat provider"
        case .embeddingProviderPickerLabel: "Embedding provider"
        case .customModelFieldLabel:        "Custom model ID"
        case .providerBadgeChat:            "chat"
        case .providerBadgeEmbedding:       "embeddings"
        case .privacyGateTitle:             "Send data to this provider?"
        case .privacyGateMessage:           "Chat questions and the source/note excerpts selected as context will be sent to this provider's server. Your database and local embeddings stay on this Mac."
        case .privacyGateAccept:            "Enable provider"
        case .errorInvalidApiKey:           "Invalid API key"
        case .errorRateLimited:             "Too many requests (429)"
        case .errorModelRefusal:            "The model declined to answer"
        case .errorConsentRequired:         "Provider not enabled — confirm data sharing in Settings"
        case .modelsUnavailableCaption:     "Models unavailable — start Ollama or refresh in Manage models."
        case .doneButton:                   "Done"
        case .openNoteFromCitation:        "Open note"
        case .notesChatPanelTitle:         "Chat"
        case .notesChatPanelEmpty:         "Start a question about this notebook…"
        case .notesChatCurrentNoteHint:    "Including the open note as bonus context"
        case .editorStatusSaved:           "Saved"
        case .editorStatusSaving:          "Saving…"
        case .editorStatusUnsaved:         "Unsaved changes"
        case .editorStatusError:           "Save failed"
        case .editorFailedToLoad:          "Editor failed to load. Reopen the note."
        case .attachmentBrokenLink:        "Attachment missing"
        case .attachmentSaveFailed:        "Couldn't save attachment"
        case .attachmentOpenButton:        "Open"
        case .historyButton:               "History"
        case .historySheetTitle:           "Version history"
        case .historyEmpty:                "No earlier versions yet."
        case .historyRestoreButton:        "Restore this version"
        case .historyReasonAutosave:       "Auto-save"
        case .historyReasonRestore:        "Restored"
        case .aiToolsSectionTitle:         "AI tools"
        case .aiToolsEmptyTitle:           "What are AI tools?"
        case .aiToolsEmptyBody:            "Pick a template, pick a source, click Run. The output is saved as a new note in this notebook."
        case .aiToolsScopeAllSources:      "All sources"
        case .aiToolsScopeHint:            "Source = one item · Notebook = combined · All sources = one note per source"
        case .aiToolsPreviewButton:        "Preview prompt"
        case .aiToolsHistoryButton:        "History"
        case .aiToolsResultSavedFormat:    "Saved as note: %@"
        case .aiToolsOpenNoteButton:       "Open note"
        case .aiToolsRunningFormat:        "Running %d / %d…"
        case .aiToolsBatchSavedFormat:     "Saved %d notes"
        case .aiToolsPromptPreviewTitle:   "Prompt preview"
        case .aiToolsHistoryEmpty:         "No runs yet."
        case .aiToolsHistoryTitle:         "Run history"
        case .aiToolsDescriptionPlaceholder: "Short description (shown under the template name)"
        case .unsavedChangesTitle: "Unsaved changes"
        case .unsavedChangesMessage: "This note has unsaved edits. Save them before switching?"
        case .unsavedSaveButton: "Save"
        case .unsavedDiscardButton: "Discard"
        case .chatFollowupsLabel:          "Suggested follow-ups"
        case .sourceSummaryLabel:          "Summary"
        case .sourceSummarizeButton:       "Summarize"
        case .sourceSummarizingStatus:     "Summarizing…"
        case .chatScopeButton:             "Sources"
        case .chatScopeAllSources:         "All sources"
        case .chatScopeTitle:              "Limit chat to sources"
        case .updateBannerTitle:      "A new version (%@) is available."
        case .updateDownloadButton:   "Download"
        case .updateLaterButton:      "Later"
        case .updateAutoCheckToggle:  "Automatically check for updates"
        case .updateCheckNowButton:   "Check for updates now"
        case .updateStatusChecking:   "Checking…"
        case .updateStatusUpToDate:   "You're up to date"
        case .updateStatusAvailable:  "Update available (%@)"
        case .updateStatusFailed:     "Couldn't check for updates."
        case .notebookInstructions:      "Chat instructions"
        case .notebookInstructionsHint:  "Optional guidance added to every chat in this notebook."
        case .exportBackupMenu:          "Export / Backup"
        case .exportNoteMarkdown:        "Export note as Markdown…"
        case .exportNotebookZip:         "Export notebook as ZIP…"
        case .backupDatabase:            "Back up database…"
        case .restoreDatabase:           "Restore from backup…"
        case .restoreConfirm:            "Replace all current data with this backup? This cannot be undone."
        case .exportDone:                "Done"
        case .globalSearchTitle:         "Search everything"
        case .globalSearchPlaceholder:   "Search notes and sources…"
        case .globalSearchNotesSection:  "Notes"
        case .globalSearchSourcesSection: "Sources"
        case .globalSearchEmpty:         "No matches"
        case .sourcePreviewTitle:        "Source preview"
        case .sourcePreviewChunksHeader: "Chunks"
        case .sourcePreviewOpenOriginal: "Open original"
        case .sourcePreviewNoChunks:     "No chunks yet"
        case .tagsLabel:                 "Tags"
        case .tagAddPlaceholder:         "Add tag…"
        case .tagFilterAll:              "All tags"
        case .tagFilterMenu:             "Filter by tag"
        case .bulkSelect:                "Select"
        case .bulkDone:                  "Done"
        case .bulkDelete:                "Delete selected"
        case .bulkSummarize:             "Summarize selected"
        case .sourceSetsLabel:           "Source sets"
        case .sourceSetSaveCurrent:      "Save current selection as set…"
        case .sourceSetNamePlaceholder:  "Set name"
        case .chatRegenerate:            "Regenerate"
        case .chatEdit:                  "Edit"
        case .webSearchToggle:           "Enable web search"
        case .webSearchChatToggle:       "Search the web for this message"
        case .watchFolderButton:         "Sync folder…"
        case .recrawlSourceButton:       "Refresh"
        case .personaMenu:               "Persona"
        case .personaNone:               "None"
        case .personaNew:                "New persona…"
        case .personaNamePlaceholder:    "Persona name"
        case .personaInstructionsPlaceholder: "Instructions for this persona"
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
        case .chatSessionsLabel:           "Konverzace"
        case .chatNewSessionButton:        "Nová konverzace"
        case .chatDeleteSessionButton:     "Smazat konverzaci"
        case .chatSaveAsNoteButton:        "Uložit jako poznámku"
        case .notesSectionTitle:           "Poznámky"
        case .notesEmptyState:             "Zatím žádné poznámky. Vytvořte ji nebo uložte z chatu."
        case .notesNewButton:              "Nová poznámka"
        case .noteUntitled:                "Bez názvu"
        case .noteTitlePlaceholder:        "Název"
        case .noteBodyPlaceholder:         "Zde pište Markdown…"
        case .noteOriginManual:            "Ruční"
        case .noteOriginChat:              "Z chatu"
        case .noteOriginTransformation:    "Z transformace"
        case .transformationsSectionTitle: "Transformace"
        case .transformationPickerLabel:   "Transformace"
        case .transformationSourcePickerLabel: "Zdroj"
        case .transformationRunButton:     "Spustit"
        case .transformationResultTitle:   "Výsledek"
        case .transformationRunningStatus: "Probíhá…"
        case .transformationEditButton:    "Upravit šablony"
        case .transformationEditorTitle:   "Vlastní transformace"
        case .transformationEditorNew:     "Nový"
        case .transformationEditorDelete:  "Smazat"
        case .transformationEditorNamePlaceholder:     "Název šablony"
        case .transformationEditorTemplatePlaceholder: "Šablona promptu (použijte {{source_text}})"
        case .reembedButton:               "Přeindexovat všechny zdroje"
        case .reembedConfirm:              "Smaže stávající vektory a přepočte je aktuálním modelem. Pokračovat?"
        case .reembedConfirmYes:           "Přeindexovat"
        case .embeddingSectionTitle:       "Vektorizace"
        case .currentModelLabel:           "Aktuální model"
        case .manageModelsButton:          "Spravovat modely…"
        case .manageModelsTitle:           "Nainstalované Ollama modely"
        case .manageModelsPullPlaceholder: "Stáhnout model (např. mistral:7b)"
        case .manageModelsPullButton:      "Stáhnout"
        case .manageModelsRefreshButton:   "Obnovit seznam"
        case .chatModelPickerLabel:        "Chatovací model"
        case .embeddingModelPickerLabel:   "Model pro vektorizaci"
        case .providersSectionTitle:        "AI provideři"
        case .addProviderButton:            "Přidat providera…"
        case .addProviderTitle:             "Přidat providera"
        case .editProviderTitle:            "Upravit providera"
        case .providerTypeLabel:            "Typ"
        case .providerNameLabel:            "Název"
        case .providerUrlLabel:             "Base URL"
        case .providerApiKeyLabel:          "API klíč"
        case .providerKeySavedLabel:        "Klíč uložen ✓ — vložením nahradíte"
        case .providerTestButton:           "Otestovat připojení"
        case .providerTestSuccess:          "Připojení OK"
        case .providerDeleteButton:         "Smazat providera"
        case .providerDeleteConfirm:        "Smazat tohoto providera? Jeho API klíč bude odstraněn z Klíčenky."
        case .chatProviderPickerLabel:      "Chat provider"
        case .embeddingProviderPickerLabel: "Provider pro vektorizaci"
        case .customModelFieldLabel:        "Vlastní ID modelu"
        case .providerBadgeChat:            "chat"
        case .providerBadgeEmbedding:       "vektorizace"
        case .privacyGateTitle:             "Odesílat data tomuto providerovi?"
        case .privacyGateMessage:           "Dotazy v chatu a úryvky zdrojů/poznámek vybrané jako kontext budou odesílány na server tohoto providera. Vaše databáze a lokální vektorizace zůstávají na tomto Macu."
        case .privacyGateAccept:            "Povolit providera"
        case .errorInvalidApiKey:           "Neplatný API klíč"
        case .errorRateLimited:             "Příliš mnoho požadavků (429)"
        case .errorModelRefusal:            "Model odmítl odpovědět"
        case .errorConsentRequired:         "Provider není povolen — potvrďte sdílení dat v Nastavení"
        case .modelsUnavailableCaption:     "Modely nedostupné — spusťte Ollamu nebo obnovte ve Správě modelů."
        case .doneButton:                   "Hotovo"
        case .openNoteFromCitation:        "Otevřít poznámku"
        case .notesChatPanelTitle:         "Chat"
        case .notesChatPanelEmpty:         "Zeptej se na něco z tohoto notebooku…"
        case .notesChatCurrentNoteHint:    "Aktuální poznámka přidána jako kontext"
        case .editorStatusSaved:           "Uloženo"
        case .editorStatusSaving:          "Ukládám…"
        case .editorStatusUnsaved:         "Neuložené změny"
        case .editorStatusError:           "Uložení selhalo"
        case .editorFailedToLoad:          "Editor se nepodařilo načíst. Otevřete poznámku znovu."
        case .attachmentBrokenLink:        "Příloha chybí"
        case .attachmentSaveFailed:        "Nepodařilo se uložit přílohu"
        case .attachmentOpenButton:        "Otevřít"
        case .historyButton:               "Historie"
        case .historySheetTitle:           "Historie verzí"
        case .historyEmpty:                "Žádné dřívější verze."
        case .historyRestoreButton:        "Obnovit tuto verzi"
        case .historyReasonAutosave:       "Auto-uložení"
        case .historyReasonRestore:        "Obnoveno"
        case .aiToolsSectionTitle:         "AI nástroje"
        case .aiToolsEmptyTitle:           "Co jsou AI nástroje?"
        case .aiToolsEmptyBody:            "Vyber šablonu, vyber zdroj, klikni Spustit. Výstup se uloží jako nová poznámka v tomto notebooku."
        case .aiToolsScopeAllSources:      "Všechny zdroje"
        case .aiToolsScopeHint:            "Zdroj = jedna položka · Notebook = vše dohromady · Všechny zdroje = poznámka na každý zdroj"
        case .aiToolsPreviewButton:        "Náhled promptu"
        case .aiToolsHistoryButton:        "Historie"
        case .aiToolsResultSavedFormat:    "Uloženo jako poznámka: %@"
        case .aiToolsOpenNoteButton:       "Otevřít poznámku"
        case .aiToolsRunningFormat:        "Probíhá %d / %d…"
        case .aiToolsBatchSavedFormat:     "Uloženo %d poznámek"
        case .aiToolsPromptPreviewTitle:   "Náhled promptu"
        case .aiToolsHistoryEmpty:         "Zatím žádné spuštění."
        case .aiToolsHistoryTitle:         "Historie spuštění"
        case .aiToolsDescriptionPlaceholder: "Krátký popis (zobrazí se pod názvem šablony)"
        case .unsavedChangesTitle: "Neuložené změny"
        case .unsavedChangesMessage: "Tato poznámka má neuložené úpravy. Uložit před přepnutím?"
        case .unsavedSaveButton: "Uložit"
        case .unsavedDiscardButton: "Zahodit"
        case .chatFollowupsLabel:          "Návrhy navazujících otázek"
        case .sourceSummaryLabel:          "Shrnutí"
        case .sourceSummarizeButton:       "Shrnout"
        case .sourceSummarizingStatus:     "Shrnuji…"
        case .chatScopeButton:             "Zdroje"
        case .chatScopeAllSources:         "Všechny zdroje"
        case .chatScopeTitle:              "Omezit chat na zdroje"
        case .updateBannerTitle:      "Je k dispozici nová verze (%@)."
        case .updateDownloadButton:   "Stáhnout"
        case .updateLaterButton:      "Později"
        case .updateAutoCheckToggle:  "Automaticky kontrolovat aktualizace"
        case .updateCheckNowButton:   "Zkontrolovat aktualizace"
        case .updateStatusChecking:   "Kontroluji…"
        case .updateStatusUpToDate:   "Máte aktuální verzi"
        case .updateStatusAvailable:  "Dostupná aktualizace (%@)"
        case .updateStatusFailed:     "Kontrola aktualizací se nezdařila."
        case .notebookInstructions:      "Instrukce pro chat"
        case .notebookInstructionsHint:  "Volitelné pokyny přidané do každého chatu v tomto bloku."
        case .exportBackupMenu:          "Export / Záloha"
        case .exportNoteMarkdown:        "Exportovat poznámku jako Markdown…"
        case .exportNotebookZip:         "Exportovat blok jako ZIP…"
        case .backupDatabase:            "Zálohovat databázi…"
        case .restoreDatabase:           "Obnovit ze zálohy…"
        case .restoreConfirm:            "Nahradit všechna současná data touto zálohou? Tuto akci nelze vzít zpět."
        case .exportDone:                "Hotovo"
        case .globalSearchTitle:         "Hledat všude"
        case .globalSearchPlaceholder:   "Hledat v poznámkách a zdrojích…"
        case .globalSearchNotesSection:  "Poznámky"
        case .globalSearchSourcesSection: "Zdroje"
        case .globalSearchEmpty:         "Žádné výsledky"
        case .sourcePreviewTitle:        "Náhled zdroje"
        case .sourcePreviewChunksHeader: "Části"
        case .sourcePreviewOpenOriginal: "Otevřít originál"
        case .sourcePreviewNoChunks:     "Zatím žádné části"
        case .tagsLabel:                 "Štítky"
        case .tagAddPlaceholder:         "Přidat štítek…"
        case .tagFilterAll:              "Všechny štítky"
        case .tagFilterMenu:             "Filtrovat podle štítku"
        case .bulkSelect:                "Vybrat"
        case .bulkDone:                  "Hotovo"
        case .bulkDelete:                "Smazat vybrané"
        case .bulkSummarize:             "Shrnout vybrané"
        case .sourceSetsLabel:           "Sady zdrojů"
        case .sourceSetSaveCurrent:      "Uložit výběr jako sadu…"
        case .sourceSetNamePlaceholder:  "Název sady"
        case .chatRegenerate:            "Přegenerovat"
        case .chatEdit:                  "Upravit"
        case .webSearchToggle:           "Povolit hledání na webu"
        case .webSearchChatToggle:       "Hledat na webu pro tuto zprávu"
        case .watchFolderButton:         "Synchronizovat složku…"
        case .recrawlSourceButton:       "Obnovit"
        case .personaMenu:               "Persona"
        case .personaNone:               "Žádná"
        case .personaNew:                "Nová persona…"
        case .personaNamePlaceholder:    "Název persony"
        case .personaInstructionsPlaceholder: "Instrukce pro tuto personu"
        }
    }
}
