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
        }
    }
}
