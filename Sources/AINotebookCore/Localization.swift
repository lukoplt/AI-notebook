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
        }
    }
}
