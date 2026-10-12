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
        case startUsingApp
        case addSourceButton
        case addSourceSheetTitle
        case addSourceFromFile
        case addSourceFromURL
        case addSourceFromText
        case addSourceURLPlaceholder
        case addSourceTitlePlaceholder
        case addSourceConfirm
        case cancelButton
        case sourceStatusPending
        case sourceStatusChunking
        case sourceStatusReady
        case sourceStatusError
        case noSourcesEmptyState
        case deleteButton
        case indexingComplete
        case chatNewSessionTitle
        case chatSendButton
        case chatCitationsSectionTitle
        case chatNewSessionButton
        case chatDeleteSessionButton
        case chatSaveAsNoteButton
        case notesEmptyState
        case notesNewButton
        case noteUntitled
        case noteTitlePlaceholder
        case noteOriginManual
        case noteOriginChat
        case noteOriginTransformation
        case transformationPickerLabel
        case transformationSourcePickerLabel
        case transformationRunButton
        case transformationRunningStatus
        case transformationEditButton
        case transformationEditorTitle
        case transformationEditorNew
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
        case providerPresetLabel
        case providerPresetCustom
        case providerPresetLocalHelp
        case providerPresetRemoteHelp
        case providerPresetCustomHelp
        case providerRefreshModels
        case providerManualModelId
        case providerApplyModel
        case providerListingVerified
        case providerListingUnsupported
        case providerRuntimeContext
        case providerMaxOutputTokens
        case providerContextWindow
        case providerContextUnknown
        case providerLimitsAssumption
        case providerLimitsUserOverride
        case providerLimitsSave
        case providerLimitsReset
        case providerLimitsInvalid
        case providerInvalidRoot
        case providerContextTooLong
        case providerEmbeddingSelectionConverted
        case providerConnectionFailed
        case providerResponseInvalid
        case providerRequestFailed
        case providerSelectionUnavailable
        case providerEndpointUnsupported
        case providerDeleteButton
        case providerDeleteConfirm
        case chatProviderPickerLabel
        case embeddingProviderPickerLabel
        case providerBadgeChat
        case providerBadgeEmbedding
        case privacyGateTitle
        case privacyGateMessage
        case privacyGateAccept
        case errorInvalidApiKey
        case errorRateLimited
        case errorModelRefusal
        case errorConsentRequired
        case doneButton
        case openNoteFromCitation
        case notesChatPanelEmpty
        case notesChatCurrentNoteHint
        case editorStatusSaved
        case editorStatusSaving
        case editorStatusUnsaved
        case editorStatusError
        case editorFailedToLoad
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
        case aiToolsResultSavedFormat
        case aiToolsOpenNoteButton
        case aiToolsRunningFormat
        case aiToolsBatchSavedFormat
        case aiToolsPromptPreviewTitle
        case aiToolsHistoryEmpty
        case aiToolsHistoryTitle
        case aiToolsDescriptionPlaceholder
        case chatFollowupsLabel
        case sourceSummarizeButton
        case sourceSummarizingStatus
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
        case sourceSetNamePlaceholder
        // Epic C3 — regenerate / edit
        case chatRegenerate
        case chatEdit
        // Epic E3 — web search
        case webSearchToggle
        // Epic E1/E2 — live sources
        case recrawlSourceButton
        // Epic C5 — personas
        case personaMenu
        case personaNone
        case personaNew
        case personaNamePlaceholder
        // WP6 — folder ingestion, scopes and re-index
        case addFolderButton
        case folderLastFullScan
        case folderNeverScanned
        case folderWatchEnabled
        case folderScanNow
        case folderVerifyAll
        case folderRulesTitle
        case folderIncludeExtensions
        case folderIgnoreGlobs
        case folderMaxFileBytes
        case folderMaxOfficeBytes
        case folderMaxTextScalars
        case folderMaxPdfPages
        case folderMaxChunks
        case folderMaxCells
        case folderEncodingFallback
        case folderEncodingNone
        case folderEncodingCp1250
        case folderEncodingUsed
        case folderRulesInvalid
        case folderRemoveButton
        case folderRemoveConfirm
        case folderRemoveKeepsFiles
        case folderSearchable
        case folderNotSearchable
        case folderCurrent
        case folderRefreshPending
        case folderRefreshError
        case folderSkipped
        case folderMissing
        case folderUnavailable
        case folderAtLeast
        case folderOverlapError
        case folderReadError
        case folderLimitError
        case folderEncodingError
        case folderDocumentError
        case sourceErrorMissingPart
        case sourceErrorDamaged
        case sourceErrorNotDownloaded
        case scopeWholeNotebook
        case scopeSelection
        case scopeFolders
        case scopeSourceSets
        case scopeSources
        case scopeEmpty
        case reindexButton
        case reindexProgress
        case reindexDiscovering
        case reindexPausedForChat
        case reindexFailed
        case reindexDualSpaceNote
        case reindexDiscard
        case reindexRetry
        case chatOverviewToggle
        case contextPreviewBeforeSend
        case contextPreviewSent
        case contextPreviewTitle
        case contextPreviewPreparing
        case contextPreviewUnavailable
        case contextPreviewEstimatedTokens
        case contextPreviewAssumedLimit
        case contextPreviewSetContextSize
        case contextPreviewMessages
        case contextPreviewWireOrder
        case contextPreviewOptions
        case contextPreviewIncluded
        case contextPreviewOmitted
        case contextPreviewCoverage
        case contextPreviewRecalculate
        case contextPreviewClose
        case contextTooSmall
        case citationOpenOriginal
        case citationRevisionChanged
        case citationOriginalUnavailable
        case citationOriginalOutsideFolder
        case contextOmittedEvidenceBudget
        case contextOmittedTopK
        case contextOmittedHistoryBudget
        case contextOmittedMapBudget
        case contextOmittedExternalBudget
        case contextOmittedTruncated
        case contextOmittedDuplicate
        case contextOmittedRevisionMismatch
        case contextOmittedNeighbourBudget
        case contextOmittedLegacyNoSpan
        case contextOmittedEmptySelection
        // Grouped Sources — expandable folders with lazily paged members
        case folderShowFiles
        case folderHideFiles
        case folderFilesCount
        case folderLoadMoreFiles
        case folderNoFiles
        case sourceLanguageLabel
        case sourceLanguageMixed
        case shellNewChat
        case shellSearch
        case shellNewNotebook
        case shellShowMore
        case shellShowLess
        case shellUpdateAvailable
        case shellMore
        case shellTogglePanel
        case shellEmptyAppTitle
        case shellBack
        case panelContext
        case panelNoteChat
        case chatEmptyTitle
        case composerPlaceholder
        case composerAdd
        case composerAddFile
        case composerAddUrl
        case composerWebSearch
        case composerOverviewMode
        case composerRunTool
        case composerPreviewContext
        case composerScope
        case composerModel
        case composerRegenerateWith
        case composerModelSettings
        case composerEditing
        case messageCopy
        case chatRetry
        case chatReplyNoteTitle
        case noteSavedNotice
        case openNote
        case openFolderAsNotebook
        case chooseNotebook
        case chatCitationsInline
        case sourcesAddText
        case folderSummaryFiles
        case folderSummaryErrors
        case notesSearchPlaceholder
        case toolHistory
        case contextPanelHint
        case contextPanelDraft
        case contextPanelBackToDraft
        case citationsPanelEmpty
        case citationPage
        case documentExport
        case documentExportPDF
        case settingsGeneral
        case settingsModelsLimits
        case settingsIndexing
        case settingsTools
        case settingsAbout
        case settingsUpdates
        case settingsLimits
        case aboutLicense
        case aboutNotice
        case aboutSourceCode
        case aboutCredits
        case toolScope
        case toolScopeSource
        case toolsPickTemplate
        case addSourceChooseFile
        case sourceMetaType
        case sourceMetaStatus
        case sourceMetaUri
        case sourceMetaIngested
        case toolHistoryDeleted
        case toolHistoryUnknown
        case toolHistoryNotebookScope
        case close
        // UI redesign C1: chat rename and Stop.
        case renameChat
        case renameChatTitle
        case chatStopButton
        case chatStopped
        case indexingScanning
        case indexingExtracting
        case indexingExtractingSlowed
        case indexingExtractingPaused
        case indexingWithScan
        case indexingEmbedding
        case indexingPreparing
        case indexingRetrying
        case indexingRetryNow
        case indexingBlockedNoModel
        case indexingBlockedProviderDisabled
        case indexingBlockedConsent
        case indexingBlockedCredential
        case indexingFailed
        case indexingRuntimeFailed
        case indexingOpenSettings
        case indexingReady
        case indexingLexicalOnly
        case indexingBuildIndex
        case indexingSourceErrors
        case indexingSourceErrorsGaveUp
        case indexingRetryAllFailed
        case sourceRetryButton
        case sourceGaveUp
        case folderChecking
        case folderNoChanges
        case folderChangedFiles
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
        case .startUsingApp:               "Start using the app"
        case .addSourceButton:             "Add source"
        case .addSourceSheetTitle:         "Add a source"
        case .addSourceFromFile:           "From file…"
        case .addSourceFromURL:            "From URL"
        case .addSourceFromText:           "Paste text"
        case .addSourceURLPlaceholder:     "https://example.com/article"
        case .addSourceTitlePlaceholder:   "Title"
        case .addSourceConfirm:            "Add"
        case .cancelButton:                "Cancel"
        case .sourceStatusPending:         "Pending"
        case .sourceStatusChunking:        "Processing"
        case .sourceStatusReady:           "Ready"
        case .sourceStatusError:           "Error"
        case .noSourcesEmptyState:         "No sources yet. Add one to get started."
        case .deleteButton:                "Delete"
        case .indexingComplete:            "Indexed"
        case .chatNewSessionTitle:         "New chat"
        case .chatSendButton:              "Send"
        case .chatCitationsSectionTitle:   "Citations"
        case .chatNewSessionButton:        "New session"
        case .chatDeleteSessionButton:     "Delete session"
        case .chatSaveAsNoteButton:        "Save as note"
        case .notesEmptyState:             "No notes yet. Create one or save from chat."
        case .notesNewButton:              "New note"
        case .noteUntitled:                "Untitled"
        case .noteTitlePlaceholder:        "Title"
        case .noteOriginManual:            "Manual"
        case .noteOriginChat:              "From chat"
        case .noteOriginTransformation:    "From transformation"
        case .transformationPickerLabel:   "Transformation"
        case .transformationSourcePickerLabel: "Source"
        case .transformationRunButton:     "Run"
        case .transformationRunningStatus: "Running…"
        case .transformationEditButton:    "Edit templates"
        case .transformationEditorTitle:   "Custom transformations"
        case .transformationEditorNew:     "New"
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
        case .providerPresetLabel: "Preset"
        case .providerPresetCustom: "Custom"
        case .providerPresetLocalHelp: "Start the local server, then check its API root. An API key is optional."
        case .providerPresetRemoteHelp: "Enter your API key and check the API root."
        case .providerPresetCustomHelp: "Enter the exact API root, including any version or proxy path."
        case .providerRefreshModels: "Refresh models"
        case .providerManualModelId: "Model ID"
        case .providerApplyModel: "Apply model ID"
        case .providerListingVerified: "Model listing verified. Generation has not been tested."
        case .providerListingUnsupported: "Model listing is unavailable; generation has not been verified. Enter a model ID manually."
        case .providerRuntimeContext: "Runtime context"
        case .providerMaxOutputTokens: "Maximum output tokens"
        case .providerContextWindow: "Model context limit"
        case .providerContextUnknown: "Unknown"
        case .providerLimitsAssumption: "Application assumption"
        case .providerLimitsUserOverride: "User override"
        case .providerLimitsSave: "Save limits"
        case .providerLimitsReset: "Reset to automatic"
        case .providerLimitsInvalid: "Enter positive whole numbers. Output must be smaller than runtime context, which must not exceed the known model limit."
        case .providerInvalidRoot: "Enter an HTTP or HTTPS API root without credentials, a query, or a fragment."
        case .providerContextTooLong: "The provider rejected the request length. Reduce runtime context."
        case .providerEmbeddingSelectionConverted: "The previous embedding provider supports chat only. Embeddings now use local Ollama (nomic-embed-text)."
        case .providerConnectionFailed: "The provider could not be reached."
        case .providerResponseInvalid: "The provider returned an unexpected response."
        case .providerRequestFailed: "The provider request failed."
        case .providerSelectionUnavailable: "Select an enabled provider in Settings."
        case .providerEndpointUnsupported: "This provider does not support the requested operation."
        case .providerDeleteButton:         "Delete provider"
        case .providerDeleteConfirm:        "Delete this provider? Its API key will be removed from the Keychain."
        case .chatProviderPickerLabel:      "Chat provider"
        case .embeddingProviderPickerLabel: "Embedding provider"
        case .providerBadgeChat:            "chat"
        case .providerBadgeEmbedding:       "embeddings"
        case .privacyGateTitle:             "Send data to this provider?"
        case .privacyGateMessage:           "Chat questions and the source/note excerpts selected as context will be sent to this provider's server. Your database and local embeddings stay on this Mac."
        case .privacyGateAccept:            "Enable provider"
        case .errorInvalidApiKey:           "Invalid API key"
        case .errorRateLimited:             "Too many requests (429)"
        case .errorModelRefusal:            "The model declined to answer"
        case .errorConsentRequired:         "Provider not enabled — confirm data sharing in Settings"
        case .doneButton:                   "Done"
        case .openNoteFromCitation:        "Open note"
        case .notesChatPanelEmpty:         "Start a question about this notebook…"
        case .notesChatCurrentNoteHint:    "Including the open note as bonus context"
        case .editorStatusSaved:           "Saved"
        case .editorStatusSaving:          "Saving…"
        case .editorStatusUnsaved:         "Unsaved changes"
        case .editorStatusError:           "Save failed"
        case .editorFailedToLoad:          "Editor failed to load. Reopen the note."
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
        case .aiToolsResultSavedFormat:    "Saved as note: %@"
        case .aiToolsOpenNoteButton:       "Open note"
        case .aiToolsRunningFormat:        "Running %d / %d…"
        case .aiToolsBatchSavedFormat:     "Saved %d notes"
        case .aiToolsPromptPreviewTitle:   "Prompt preview"
        case .aiToolsHistoryEmpty:         "No runs yet."
        case .aiToolsHistoryTitle:         "Run history"
        case .aiToolsDescriptionPlaceholder: "Short description (shown under the template name)"
        case .chatFollowupsLabel:          "Suggested follow-ups"
        case .sourceSummarizeButton:       "Summarize"
        case .sourceSummarizingStatus:     "Summarizing…"
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
        case .sourceSetNamePlaceholder:  "Set name"
        case .chatRegenerate:            "Regenerate"
        case .chatEdit:                  "Edit"
        case .webSearchToggle:           "Enable web search"
        case .recrawlSourceButton:       "Refresh"
        case .personaMenu:               "Persona"
        case .personaNone:               "None"
        case .personaNew:                "New persona…"
        case .personaNamePlaceholder:    "Persona name"
        case .addFolderButton: "Add folder…"
        case .folderLastFullScan: "Last full scan"
        case .folderNeverScanned: "Never scanned"
        case .folderWatchEnabled: "Watch for changes"
        case .folderScanNow: "Scan now"
        case .folderVerifyAll: "Verify all"
        case .folderRulesTitle: "Folder rules"
        case .folderIncludeExtensions: "Include extensions"
        case .folderIgnoreGlobs: "Ignore patterns (one per line)"
        case .folderMaxFileBytes: "Maximum file bytes"
        case .folderMaxOfficeBytes: "Maximum expanded Office bytes"
        case .folderMaxTextScalars: "Maximum text characters"
        case .folderMaxPdfPages: "Maximum PDF pages"
        case .folderMaxChunks: "Maximum passages per file"
        case .folderMaxCells: "Maximum spreadsheet cells"
        case .folderEncodingFallback: "Text encoding fallback"
        case .folderEncodingNone: "Strict UTF only"
        case .folderEncodingCp1250: "Windows-1250"
        case .folderEncodingUsed: "Encoding"
        case .folderRulesInvalid: "Check patterns, extensions and positive limits."
        case .folderRemoveButton: "Remove from notebook"
        case .folderRemoveConfirm: "Remove this folder from the notebook?"
        case .folderRemoveKeepsFiles: "Files on disk will be kept."
        case .folderSearchable: "Searchable"
        case .folderNotSearchable: "Not yet searchable"
        case .folderCurrent: "Current"
        case .folderRefreshPending: "Refresh pending"
        case .folderRefreshError: "Refresh failed"
        case .folderSkipped: "Skipped"
        case .folderMissing: "Missing"
        case .folderUnavailable: "Unavailable"
        case .folderAtLeast: "At least"
        case .folderOverlapError: "This folder overlaps a folder already in this notebook."
        case .folderReadError: "The folder or file could not be read."
        case .folderLimitError: "The extraction limit was exceeded."
        case .folderEncodingError: "The text encoding is not supported."
        case .folderDocumentError: "The document is damaged or unsupported."
        case .sourceErrorMissingPart: "The document is incomplete: a required part is missing."
        case .sourceErrorDamaged: "The file is damaged or is not a valid document."
        case .sourceErrorNotDownloaded: "The file is only in cloud storage and could not be downloaded."
        case .scopeWholeNotebook: "Whole notebook"
        case .scopeSelection: "Selected items"
        case .scopeFolders: "Folders"
        case .scopeSourceSets: "Source sets"
        case .scopeSources: "Individual sources"
        case .scopeEmpty: "No sources selected"
        case .reindexButton: "Re-index"
        case .reindexProgress: "Re-index progress"
        case .reindexDiscovering: "Preparing the new index"
        case .reindexPausedForChat: "Background indexing paused for chat"
        case .reindexFailed: "Re-indexing failed; existing search remains available."
        case .reindexDualSpaceNote: "The existing index stays available while the new index is built. Temporary extra disk space is required."
        case .reindexDiscard: "Discard new index"
        case .reindexRetry: "Retry re-indexing"
        case .chatOverviewToggle: "Overview"
        case .contextPreviewBeforeSend: "Show what will be sent"
        case .contextPreviewSent: "Show sent context"
        case .contextPreviewTitle: "Context preview"
        case .contextPreviewPreparing: "Preparing context…"
        case .contextPreviewUnavailable: "This context preview is no longer in memory."
        case .contextPreviewEstimatedTokens: "Estimated tokens"
        case .contextPreviewAssumedLimit: "Context size assumed by the app"
        case .contextPreviewSetContextSize: "Set context size"
        case .contextPreviewMessages: "Logical messages"
        case .contextPreviewWireOrder: "Sent message order"
        case .contextPreviewOptions: "Request options"
        case .contextPreviewIncluded: "Included content"
        case .contextPreviewOmitted: "Omitted content"
        case .contextPreviewCoverage: "Scope and turn coverage"
        case .contextPreviewRecalculate: "Recalculate preview"
        case .contextPreviewClose: "Close preview"
        case .contextTooSmall: "Context is too small. Increase its size or shorten the instructions."
        case .citationOpenOriginal: "Open original"
        case .citationRevisionChanged: "The original has changed since this answer."
        case .citationOriginalUnavailable: "The original is unavailable."
        case .citationOriginalOutsideFolder: "The original is outside the selected folder."
        case .contextOmittedEvidenceBudget: "Evidence budget exhausted"
        case .contextOmittedTopK: "Passage limit reached"
        case .contextOmittedHistoryBudget: "Complete conversation turn did not fit"
        case .contextOmittedMapBudget: "Map budget exhausted"
        case .contextOmittedExternalBudget: "Additional context did not fit"
        case .contextOmittedTruncated: "Excerpt shortened at a sentence boundary"
        case .contextOmittedDuplicate: "Duplicate excerpt"
        case .contextOmittedRevisionMismatch: "Different document revision"
        case .contextOmittedNeighbourBudget: "Neighbouring excerpt did not fit"
        case .contextOmittedLegacyNoSpan: "Legacy excerpt has no position data"
        case .contextOmittedEmptySelection: "No sources selected"
        case .folderShowFiles: "Show files"
        case .folderHideFiles: "Hide files"
        case .folderFilesCount: "Files: {shown} / {total}"
        case .folderLoadMoreFiles: "Load more files"
        case .folderNoFiles: "No files from this folder yet"
        case .sourceLanguageLabel: "Language"
        case .sourceLanguageMixed: "Mixed"
        case .shellNewChat: "New chat"
        case .shellSearch: "Search"
        case .shellNewNotebook: "New notebook"
        case .shellShowMore: "Show more (%d)"
        case .shellShowLess: "Show less"
        case .shellUpdateAvailable: "Update available"
        case .shellMore: "More"
        case .shellTogglePanel: "Show or hide panel"
        case .shellEmptyAppTitle: "Start by adding a folder or creating a notebook"
        case .shellBack: "Back"
        case .panelContext: "Context"
        case .panelNoteChat: "Note chat"
        case .chatEmptyTitle: "What are we working on?"
        case .composerPlaceholder: "Ask anything in this notebook…"
        case .composerAdd: "Add"
        case .composerAddFile: "Add file…"
        case .composerAddUrl: "Add URL…"
        case .composerWebSearch: "Web search"
        case .composerOverviewMode: "Overview mode"
        case .composerRunTool: "Run tool"
        case .composerPreviewContext: "Preview context"
        case .composerScope: "Scope"
        case .composerModel: "Model"
        case .composerRegenerateWith: "Regenerate with"
        case .composerModelSettings: "Model settings…"
        case .composerEditing: "Editing your last message"
        case .messageCopy: "Copy"
        case .chatRetry: "Try again"
        case .chatReplyNoteTitle: "Chat reply — %@"
        case .noteSavedNotice: "Saved as a note"
        case .openNote: "Open note"
        case .openFolderAsNotebook: "Open folder as notebook…"
        case .chooseNotebook: "Notebook"
        case .chatCitationsInline: "Sources"
        case .sourcesAddText: "Add text…"
        case .folderSummaryFiles: "Files: %@"
        case .folderSummaryErrors: "Errors: %d"
        case .notesSearchPlaceholder: "Search notes"
        case .toolHistory: "Tool history"
        case .contextPanelHint: "Write a question, then use the eye button to preview what will be sent."
        case .contextPanelDraft: "Next message"
        case .contextPanelBackToDraft: "Show next message"
        case .citationsPanelEmpty: "Click a citation number in an answer to see its source."
        case .citationPage: "p. %@"
        case .documentExport: "Export"
        case .documentExportPDF: "Export as PDF…"
        case .settingsGeneral: "General"
        case .settingsModelsLimits: "Models & limits"
        case .settingsIndexing: "Indexing"
        case .settingsTools: "Tools"
        case .settingsAbout: "About"
        case .settingsUpdates: "Updates"
        case .settingsLimits: "Context limits"
        case .aboutLicense: "License"
        case .aboutNotice: "Third-party notices"
        case .aboutSourceCode: "Source code"
        case .aboutCredits: "Made with ♥ by Lukáš Oplt"
        case .toolScope: "Scope"
        case .toolScopeSource: "One source"
        case .toolsPickTemplate: "Pick or create a custom template"
        case .addSourceChooseFile: "Choose file…"
        case .sourceMetaType: "Type"
        case .sourceMetaStatus: "Status"
        case .sourceMetaUri: "Address"
        case .sourceMetaIngested: "Added"
        case .toolHistoryDeleted: "(deleted)"
        case .toolHistoryUnknown: "(unknown template)"
        case .toolHistoryNotebookScope: "(whole notebook)"
        case .close: "Close"
        case .renameChat: "Rename"
        case .renameChatTitle: "Rename chat"
        case .chatStopButton: "Stop"
        case .chatStopped: "Stopped"
        case .indexingScanning: "Checking folder… {count} files"
        case .indexingExtracting: "Processing files {done} / {total}"
        case .indexingExtractingSlowed: "Processing files {done} / {total} · slowed, the system is low on memory"
        case .indexingExtractingPaused: "Paused: the system is low on memory · files {done} / {total}"
        case .indexingWithScan: "{status} · checking folder…"
        case .indexingEmbedding: "Indexing {done} / {total} chunks"
        case .indexingPreparing: "Preparing index…"
        case .indexingRetrying: "Embedding provider unavailable — retrying in {seconds} s"
        case .indexingRetryNow: "Retry now"
        case .indexingBlockedNoModel: "No embedding model is set up; only full-text search works."
        case .indexingBlockedProviderDisabled: "The embedding provider is turned off; only full-text search works."
        case .indexingBlockedConsent: "The embedding provider needs your consent before indexing."
        case .indexingBlockedCredential: "The embedding provider's API key could not be loaded."
        case .indexingFailed: "Indexing failed ({code})"
        case .indexingRuntimeFailed: "Background indexing could not start ({code})"
        case .indexingOpenSettings: "Open settings"
        case .indexingReady: "Searchable · {count} files"
        case .indexingLexicalOnly: "Full-text search only"
        case .indexingBuildIndex: "Build index"
        case .indexingSourceErrors: "{count} files couldn't be read"
        case .indexingSourceErrorsGaveUp: "{count} files couldn't be read (gave up after 3 attempts)"
        case .indexingRetryAllFailed: "Retry all failed"
        case .sourceRetryButton: "Retry"
        case .sourceGaveUp: "Gave up after 3 attempts"
        case .folderChecking: "Checking…"
        case .folderNoChanges: "No changes · {count} files up to date"
        case .folderChangedFiles: "{count} files changed"
        }
    }

    private func czech(_ key: Key) -> String {
        switch key {
        case .appName:           "AI Notebook"
        case .settings:          "Nastavení"
        case .language:          "Jazyk"
        case .version:           "Verze"
        case .notebooks:         "Notebooky"
        case .sources:           "Zdroje"
        case .chat:              "Chat"
        case .notes:             "Poznámky"
        case .transformations:   "Transformace"
        case .noNotebookSelected: "Žádný notebook není vybrán"
        case .createNotebook:    "Vytvořit notebook"
        case .renameNotebook:    "Přejmenovat notebook"
        case .deleteNotebook:    "Smazat notebook"
        case .notebookName:      "Název notebooku"
        case .notebookDescription: "Popis (volitelný)"
        case .cancel:            "Zrušit"
        case .create:            "Vytvořit"
        case .save:              "Uložit"
        case .delete:            "Smazat"
        case .confirmDeleteNotebook: "Opravdu smazat tento notebook? Akci nelze vrátit zpět."
        case .cannotBeEmpty:     "Název nesmí být prázdný."
        case .welcome:                     "Vítejte"
        case .welcomeBody:                 "AI Notebook udržuje vše lokálně. K AI použijeme Ollamu spuštěnou na vašem Macu."
        case .continueLabel:               "Pokračovat"
        case .onboardingDetectTitle:       "Kontrola Ollamy"
        case .onboardingDetectBody:        "Hledáme spuštěnou Ollamu na vašem Macu."
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
        case .onboardingDoneBody:          "Teď můžete vytvořit svůj první notebook."
        case .startUsingApp:               "Začít používat aplikaci"
        case .addSourceButton:             "Přidat zdroj"
        case .addSourceSheetTitle:         "Přidat zdroj"
        case .addSourceFromFile:           "Ze souboru…"
        case .addSourceFromURL:            "Z URL adresy"
        case .addSourceFromText:           "Vložit text"
        case .addSourceURLPlaceholder:     "https://example.com/clanek"
        case .addSourceTitlePlaceholder:   "Název"
        case .addSourceConfirm:            "Přidat"
        case .cancelButton:                "Zrušit"
        case .sourceStatusPending:         "Čeká"
        case .sourceStatusChunking:        "Zpracovává se"
        case .sourceStatusReady:           "Hotovo"
        case .sourceStatusError:           "Chyba"
        case .noSourcesEmptyState:         "Zatím žádné zdroje. Přidejte první, abyste mohli začít."
        case .deleteButton:                "Smazat"
        case .indexingComplete:            "Indexováno"
        case .chatNewSessionTitle:         "Nový chat"
        case .chatSendButton:              "Odeslat"
        case .chatCitationsSectionTitle:   "Citace"
        case .chatNewSessionButton:        "Nová konverzace"
        case .chatDeleteSessionButton:     "Smazat konverzaci"
        case .chatSaveAsNoteButton:        "Uložit jako poznámku"
        case .notesEmptyState:             "Zatím žádné poznámky. Vytvořte ji nebo uložte z chatu."
        case .notesNewButton:              "Nová poznámka"
        case .noteUntitled:                "Bez názvu"
        case .noteTitlePlaceholder:        "Název"
        case .noteOriginManual:            "Ruční"
        case .noteOriginChat:              "Z chatu"
        case .noteOriginTransformation:    "Z transformace"
        case .transformationPickerLabel:   "Transformace"
        case .transformationSourcePickerLabel: "Zdroj"
        case .transformationRunButton:     "Spustit"
        case .transformationRunningStatus: "Probíhá…"
        case .transformationEditButton:    "Upravit šablony"
        case .transformationEditorTitle:   "Vlastní transformace"
        case .transformationEditorNew:     "Nový"
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
        case .providerPresetLabel: "Předvolba"
        case .providerPresetCustom: "Vlastní"
        case .providerPresetLocalHelp: "Spusťte místní server a ověřte kořen API. Klíč API je volitelný."
        case .providerPresetRemoteHelp: "Zadejte klíč API a ověřte kořen API."
        case .providerPresetCustomHelp: "Zadejte přesný kořen API včetně verze a cesty proxy."
        case .providerRefreshModels: "Obnovit modely"
        case .providerManualModelId: "ID modelu"
        case .providerApplyModel: "Použít ID modelu"
        case .providerListingVerified: "Seznam modelů byl ověřen. Generování nebylo testováno."
        case .providerListingUnsupported: "Seznam modelů není dostupný; generování nebylo ověřeno. Zadejte ID modelu ručně."
        case .providerRuntimeContext: "Použitý kontext"
        case .providerMaxOutputTokens: "Maximum tokenů odpovědi"
        case .providerContextWindow: "Limit kontextu modelu"
        case .providerContextUnknown: "Neznámý"
        case .providerLimitsAssumption: "Předpoklad aplikace"
        case .providerLimitsUserOverride: "Uživatelské nastavení"
        case .providerLimitsSave: "Uložit limity"
        case .providerLimitsReset: "Obnovit automatické nastavení"
        case .providerLimitsInvalid: "Zadejte kladná celá čísla. Maximum odpovědi musí být menší než použitý kontext, který nesmí překročit známý limit modelu."
        case .providerInvalidRoot: "Zadejte kořen API HTTP nebo HTTPS bez přihlašovacích údajů, dotazu a fragmentu."
        case .providerContextTooLong: "Poskytovatel odmítl délku požadavku. Snižte použitý kontext."
        case .providerEmbeddingSelectionConverted: "Předchozí poskytovatel embeddingů podporuje pouze chat. Embeddingy nyní používají místní Ollamu (nomic-embed-text)."
        case .providerConnectionFailed: "K poskytovateli se nepodařilo připojit."
        case .providerResponseInvalid: "Poskytovatel vrátil neočekávanou odpověď."
        case .providerRequestFailed: "Požadavek poskytovateli selhal."
        case .providerSelectionUnavailable: "V Nastavení vyberte povoleného poskytovatele."
        case .providerEndpointUnsupported: "Tento poskytovatel nepodporuje požadovanou operaci."
        case .providerDeleteButton:         "Smazat providera"
        case .providerDeleteConfirm:        "Smazat tohoto providera? Jeho API klíč bude odstraněn z Klíčenky."
        case .chatProviderPickerLabel:      "Chat provider"
        case .embeddingProviderPickerLabel: "Provider pro vektorizaci"
        case .providerBadgeChat:            "chat"
        case .providerBadgeEmbedding:       "vektorizace"
        case .privacyGateTitle:             "Odesílat data tomuto providerovi?"
        case .privacyGateMessage:           "Dotazy v chatu a úryvky zdrojů/poznámek vybrané jako kontext budou odesílány na server tohoto providera. Vaše databáze a lokální vektorizace zůstávají na tomto Macu."
        case .privacyGateAccept:            "Povolit providera"
        case .errorInvalidApiKey:           "Neplatný API klíč"
        case .errorRateLimited:             "Příliš mnoho požadavků (429)"
        case .errorModelRefusal:            "Model odmítl odpovědět"
        case .errorConsentRequired:         "Provider není povolen — potvrďte sdílení dat v Nastavení"
        case .doneButton:                   "Hotovo"
        case .openNoteFromCitation:        "Otevřít poznámku"
        case .notesChatPanelEmpty:         "Zeptej se na něco z tohoto notebooku…"
        case .notesChatCurrentNoteHint:    "Aktuální poznámka přidána jako kontext"
        case .editorStatusSaved:           "Uloženo"
        case .editorStatusSaving:          "Ukládám…"
        case .editorStatusUnsaved:         "Neuložené změny"
        case .editorStatusError:           "Uložení selhalo"
        case .editorFailedToLoad:          "Editor se nepodařilo načíst. Otevřete poznámku znovu."
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
        case .aiToolsResultSavedFormat:    "Uloženo jako poznámka: %@"
        case .aiToolsOpenNoteButton:       "Otevřít poznámku"
        case .aiToolsRunningFormat:        "Probíhá %d / %d…"
        case .aiToolsBatchSavedFormat:     "Uloženo %d poznámek"
        case .aiToolsPromptPreviewTitle:   "Náhled promptu"
        case .aiToolsHistoryEmpty:         "Zatím žádné spuštění."
        case .aiToolsHistoryTitle:         "Historie spuštění"
        case .aiToolsDescriptionPlaceholder: "Krátký popis (zobrazí se pod názvem šablony)"
        case .chatFollowupsLabel:          "Návrhy navazujících otázek"
        case .sourceSummarizeButton:       "Shrnout"
        case .sourceSummarizingStatus:     "Shrnuji…"
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
        case .notebookInstructionsHint:  "Volitelné pokyny přidané do každého chatu v tomto notebooku."
        case .exportNoteMarkdown:        "Exportovat poznámku jako Markdown…"
        case .exportNotebookZip:         "Exportovat notebook jako ZIP…"
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
        case .sourceSetNamePlaceholder:  "Název sady"
        case .chatRegenerate:            "Přegenerovat"
        case .chatEdit:                  "Upravit"
        case .webSearchToggle:           "Povolit hledání na webu"
        case .recrawlSourceButton:       "Obnovit"
        case .personaMenu:               "Persona"
        case .personaNone:               "Žádná"
        case .personaNew:                "Nová persona…"
        case .personaNamePlaceholder:    "Název persony"
        case .addFolderButton: "Přidat složku…"
        case .folderLastFullScan: "Poslední úplný sken"
        case .folderNeverScanned: "Dosud neskenováno"
        case .folderWatchEnabled: "Sledovat změny"
        case .folderScanNow: "Skenovat teď"
        case .folderVerifyAll: "Ověřit vše"
        case .folderRulesTitle: "Pravidla složky"
        case .folderIncludeExtensions: "Zahrnuté přípony"
        case .folderIgnoreGlobs: "Ignorované vzory (jeden na řádek)"
        case .folderMaxFileBytes: "Nejvýše bajtů souboru"
        case .folderMaxOfficeBytes: "Nejvýše rozbalených bajtů Office"
        case .folderMaxTextScalars: "Nejvýše znaků textu"
        case .folderMaxPdfPages: "Nejvýše stran PDF"
        case .folderMaxChunks: "Nejvýše pasáží na soubor"
        case .folderMaxCells: "Nejvýše buněk tabulky"
        case .folderEncodingFallback: "Náhradní kódování textu"
        case .folderEncodingNone: "Pouze striktní UTF"
        case .folderEncodingCp1250: "Windows-1250"
        case .folderEncodingUsed: "Kódování"
        case .folderRulesInvalid: "Zkontrolujte vzory, přípony a kladné limity."
        case .folderRemoveButton: "Odebrat z notebooku"
        case .folderRemoveConfirm: "Odebrat tuto složku z notebooku?"
        case .folderRemoveKeepsFiles: "Soubory na disku zůstanou zachovány."
        case .folderSearchable: "Prohledatelné"
        case .folderNotSearchable: "Dosud neprohledatelné"
        case .folderCurrent: "Aktuální"
        case .folderRefreshPending: "Čeká na aktualizaci"
        case .folderRefreshError: "Aktualizace selhala"
        case .folderSkipped: "Přeskočené"
        case .folderMissing: "Chybějící"
        case .folderUnavailable: "Nedostupné"
        case .folderAtLeast: "Alespoň"
        case .folderOverlapError: "Tato složka se překrývá se složkou již přidanou do notebooku."
        case .folderReadError: "Složku nebo soubor se nepodařilo přečíst."
        case .folderLimitError: "Byl překročen limit extrakce."
        case .folderEncodingError: "Kódování textu není podporováno."
        case .folderDocumentError: "Dokument je poškozený nebo nepodporovaný."
        case .sourceErrorMissingPart: "Dokument je neúplný: chybí povinná část."
        case .sourceErrorDamaged: "Soubor je poškozený nebo nejde o platný dokument."
        case .sourceErrorNotDownloaded: "Soubor je jen v cloudovém úložišti a nepodařilo se ho stáhnout."
        case .scopeWholeNotebook: "Celý notebook"
        case .scopeSelection: "Vybrané položky"
        case .scopeFolders: "Složky"
        case .scopeSourceSets: "Sady zdrojů"
        case .scopeSources: "Jednotlivé zdroje"
        case .scopeEmpty: "Nejsou vybrány žádné zdroje"
        case .reindexButton: "Přeindexovat"
        case .reindexProgress: "Průběh přeindexování"
        case .reindexDiscovering: "Připravuje se nový index"
        case .reindexPausedForChat: "Indexování na pozadí je pozastaveno kvůli chatu"
        case .reindexFailed: "Přeindexování selhalo; stávající vyhledávání zůstává dostupné."
        case .reindexDualSpaceNote: "Stávající index zůstává dostupný během vytváření nového indexu. Dočasně je potřeba více místa na disku."
        case .reindexDiscard: "Zahodit nový index"
        case .reindexRetry: "Zkusit přeindexování znovu"
        case .chatOverviewToggle: "Přehled"
        case .contextPreviewBeforeSend: "Zobrazit, co se pošle"
        case .contextPreviewSent: "Zobrazit odeslaný kontext"
        case .contextPreviewTitle: "Náhled kontextu"
        case .contextPreviewPreparing: "Připravuji kontext…"
        case .contextPreviewUnavailable: "Tento náhled kontextu už není v paměti."
        case .contextPreviewEstimatedTokens: "Odhad tokenů"
        case .contextPreviewAssumedLimit: "Velikost kontextu předpokládaná aplikací"
        case .contextPreviewSetContextSize: "Nastavit velikost kontextu"
        case .contextPreviewMessages: "Logické zprávy"
        case .contextPreviewWireOrder: "Pořadí odeslaných zpráv"
        case .contextPreviewOptions: "Nastavení požadavku"
        case .contextPreviewIncluded: "Zahrnutý obsah"
        case .contextPreviewOmitted: "Vynechaný obsah"
        case .contextPreviewCoverage: "Pokrytí rozsahu a dotazu"
        case .contextPreviewRecalculate: "Přepočítat náhled"
        case .contextPreviewClose: "Zavřít náhled"
        case .contextTooSmall: "Kontext je příliš malý. Zvětšete ho nebo zkraťte instrukce."
        case .citationOpenOriginal: "Otevřít originál"
        case .citationRevisionChanged: "Originál se od této odpovědi změnil."
        case .citationOriginalUnavailable: "Originál není dostupný."
        case .citationOriginalOutsideFolder: "Originál je mimo vybranou složku."
        case .contextOmittedEvidenceBudget: "Vyčerpán rozpočet důkazů"
        case .contextOmittedTopK: "Dosažen limit pasáží"
        case .contextOmittedHistoryBudget: "Celý tah konverzace se nevešel"
        case .contextOmittedMapBudget: "Vyčerpán rozpočet mapy"
        case .contextOmittedExternalBudget: "Doplňující kontext se nevešel"
        case .contextOmittedTruncated: "Úryvek zkrácen na hranici věty"
        case .contextOmittedDuplicate: "Duplicitní úryvek"
        case .contextOmittedRevisionMismatch: "Jiná revize dokumentu"
        case .contextOmittedNeighbourBudget: "Sousední úryvek se nevešel"
        case .contextOmittedLegacyNoSpan: "Starší úryvek nemá údaje o pozici"
        case .contextOmittedEmptySelection: "Nejsou vybrány žádné zdroje"
        case .folderShowFiles: "Zobrazit soubory"
        case .folderHideFiles: "Skrýt soubory"
        case .folderFilesCount: "Soubory: {shown} / {total}"
        case .folderLoadMoreFiles: "Načíst další soubory"
        case .folderNoFiles: "Ze složky zatím nejsou žádné soubory"
        case .sourceLanguageLabel: "Jazyk"
        case .sourceLanguageMixed: "Více jazyků"
        case .shellNewChat: "Nový chat"
        case .shellSearch: "Hledat"
        case .shellNewNotebook: "Nový notebook"
        case .shellShowMore: "Zobrazit další (%d)"
        case .shellShowLess: "Zobrazit méně"
        case .shellUpdateAvailable: "Aktualizace k dispozici"
        case .shellMore: "Další"
        case .shellTogglePanel: "Zobrazit nebo skrýt panel"
        case .shellEmptyAppTitle: "Začni přidáním složky nebo vytvořením notebooku"
        case .shellBack: "Zpět"
        case .panelContext: "Kontext"
        case .panelNoteChat: "Chat k poznámce"
        case .chatEmptyTitle: "Na čem pracujeme?"
        case .composerPlaceholder: "Zeptej se na cokoliv v notebooku…"
        case .composerAdd: "Přidat"
        case .composerAddFile: "Přidat soubor…"
        case .composerAddUrl: "Přidat URL…"
        case .composerWebSearch: "Hledat na webu"
        case .composerOverviewMode: "Režim Přehled"
        case .composerRunTool: "Spustit nástroj"
        case .composerPreviewContext: "Náhled kontextu"
        case .composerScope: "Rozsah"
        case .composerModel: "Model"
        case .composerRegenerateWith: "Přegenerovat s"
        case .composerModelSettings: "Nastavení modelu…"
        case .composerEditing: "Upravuješ poslední zprávu"
        case .messageCopy: "Kopírovat"
        case .chatRetry: "Zkusit znovu"
        case .chatReplyNoteTitle: "Odpověď z chatu — %@"
        case .noteSavedNotice: "Uloženo jako poznámka"
        case .openNote: "Otevřít poznámku"
        case .openFolderAsNotebook: "Otevřít složku jako notebook…"
        case .chooseNotebook: "Notebook"
        case .chatCitationsInline: "Zdroje"
        case .sourcesAddText: "Přidat text…"
        case .folderSummaryFiles: "Soubory: %@"
        case .folderSummaryErrors: "Chyby: %d"
        case .notesSearchPlaceholder: "Hledat v poznámkách"
        case .toolHistory: "Historie nástrojů"
        case .contextPanelHint: "Napiš otázku a tlačítkem s okem zobraz, co se pošle."
        case .contextPanelDraft: "Další zpráva"
        case .contextPanelBackToDraft: "Zobrazit další zprávu"
        case .citationsPanelEmpty: "Klikni na číslo citace v odpovědi a uvidíš její zdroj."
        case .citationPage: "s. %@"
        case .documentExport: "Exportovat"
        case .documentExportPDF: "Exportovat jako PDF…"
        case .settingsGeneral: "Obecné"
        case .settingsModelsLimits: "Modely a limity"
        case .settingsIndexing: "Indexace"
        case .settingsTools: "Nástroje"
        case .settingsAbout: "O aplikaci"
        case .settingsUpdates: "Aktualizace"
        case .settingsLimits: "Limity kontextu"
        case .aboutLicense: "Licence"
        case .aboutNotice: "Licence třetích stran"
        case .aboutSourceCode: "Zdrojový kód"
        case .aboutCredits: "S ♥ vytvořil Lukáš Oplt"
        case .toolScope: "Rozsah"
        case .toolScopeSource: "Jeden zdroj"
        case .toolsPickTemplate: "Vyber nebo vytvoř vlastní šablonu"
        case .addSourceChooseFile: "Vybrat soubor…"
        case .sourceMetaType: "Typ"
        case .sourceMetaStatus: "Stav"
        case .sourceMetaUri: "Adresa"
        case .sourceMetaIngested: "Přidáno"
        case .toolHistoryDeleted: "(smazáno)"
        case .toolHistoryUnknown: "(neznámá šablona)"
        case .toolHistoryNotebookScope: "(celý notebook)"
        case .close: "Zavřít"
        case .renameChat: "Přejmenovat"
        case .renameChatTitle: "Přejmenovat chat"
        case .chatStopButton: "Zastavit"
        case .chatStopped: "Zastaveno"
        case .indexingScanning: "Kontroluji složku… nalezeno souborů: {count}"
        case .indexingExtracting: "Zpracovávám soubory {done} / {total}"
        case .indexingExtractingSlowed: "Zpracovávám soubory {done} / {total} · zpomaleno, systému dochází paměť"
        case .indexingExtractingPaused: "Pozastaveno: systému dochází paměť · soubory {done} / {total}"
        case .indexingWithScan: "{status} · kontroluji složku…"
        case .indexingEmbedding: "Indexuji úseky {done} / {total}"
        case .indexingPreparing: "Připravuji index…"
        case .indexingRetrying: "Poskytovatel embeddingů není dostupný — další pokus za {seconds} s"
        case .indexingRetryNow: "Zkusit hned"
        case .indexingBlockedNoModel: "Není nastavený model pro embeddingy; funguje jen fulltextové vyhledávání."
        case .indexingBlockedProviderDisabled: "Poskytovatel embeddingů je vypnutý; funguje jen fulltextové vyhledávání."
        case .indexingBlockedConsent: "Poskytovatel embeddingů potřebuje před indexováním váš souhlas."
        case .indexingBlockedCredential: "API klíč poskytovatele embeddingů se nepodařilo načíst."
        case .indexingFailed: "Indexování selhalo ({code})"
        case .indexingRuntimeFailed: "Indexování na pozadí se nepodařilo spustit ({code})"
        case .indexingOpenSettings: "Otevřít nastavení"
        case .indexingReady: "Prohledávatelné · souborů: {count}"
        case .indexingLexicalOnly: "Jen fulltextové vyhledávání"
        case .indexingBuildIndex: "Vytvořit index"
        case .indexingSourceErrors: "Nepodařilo se přečíst souborů: {count}"
        case .indexingSourceErrorsGaveUp: "Nepodařilo se přečíst souborů: {count} (vzdáno po 3 pokusech)"
        case .indexingRetryAllFailed: "Zkusit znovu vše neúspěšné"
        case .sourceRetryButton: "Zkusit znovu"
        case .sourceGaveUp: "Vzdáno po 3 pokusech"
        case .folderChecking: "Kontroluji…"
        case .folderNoChanges: "Beze změn · aktuálních souborů: {count}"
        case .folderChangedFiles: "Změněných souborů: {count}"
        }
    }

    /// "Files: shown / total" for an expanded folder; plain integers, same tokens as Windows.
    public func folderFilesCount(shown: Int, total: Int) -> String {
        string(.folderFilesCount)
            .replacingOccurrences(of: "{shown}", with: String(shown))
            .replacingOccurrences(of: "{total}", with: String(total))
    }

    /// Source language badge: cs/sk/en/de as an upper-case code, "mixed" localized,
    /// undetermined or unknown codes show nothing.
    public func languageBadge(_ lang: String?) -> String? {
        switch lang {
        case "cs", "sk", "en", "de": lang?.uppercased()
        case "mixed": string(.sourceLanguageMixed)
        default: nil
        }
    }

    /// Preview ledger labels for the frozen omission reason codes.
    public static func omissionReasonKey(_ code: String) -> Key? {
        switch code {
        case "evidenceBudget": .contextOmittedEvidenceBudget
        case "topK": .contextOmittedTopK
        case "historyBudget": .contextOmittedHistoryBudget
        case "mapBudget": .contextOmittedMapBudget
        case "externalBudget": .contextOmittedExternalBudget
        case "truncated": .contextOmittedTruncated
        case "duplicate": .contextOmittedDuplicate
        case "revisionMismatch": .contextOmittedRevisionMismatch
        case "neighbourBudget": .contextOmittedNeighbourBudget
        case "legacyNoSpan": .contextOmittedLegacyNoSpan
        case "emptySelection": .contextOmittedEmptySelection
        default: nil
        }
    }

    /// An unknown future code is shown verbatim rather than mislabelled.
    public func omissionReason(_ code: String) -> String {
        Self.omissionReasonKey(code).map(string) ?? code
    }
}
