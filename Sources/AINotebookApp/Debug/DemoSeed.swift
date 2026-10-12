#if DEBUG
import AINotebookCore
import Foundation

/// Debug-only demo profile for visual QA and screenshots.
///
/// `-AINotebookDemoSeed <dir>` fills an EMPTY store (never touches existing
/// data) with three notebooks: one folder source per directory in
/// `<dir>/folders` (e.g. copies of eval/multilingual/documents/cs), loose files from
/// `<dir>/loose`, pasted-text sources, notes, a persona and chats whose
/// assistant answers (Markdown + citations) are stored directly — no provider
/// is needed. Launch with an isolated HOME.
@MainActor
enum DemoSeed {
    static let argument = "AINotebookDemoSeed"

    static var requestedDirectory: URL? {
        UserDefaults.standard.string(forKey: argument).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func runIfRequested(store: NotebookStore, ingestion: IngestionService,
                               runtime: FolderIngestionRuntime?) async {
        guard let dir = requestedDirectory, store.notebooks.isEmpty else { return }
        do {
            try await seed(dir: dir, store: store, ingestion: ingestion, runtime: runtime)
        } catch {
            FileHandle.standardError.write("DemoSeed failed: \(error)\n".data(using: .utf8)!)
        }
    }

    private static func seed(dir: URL, store: NotebookStore, ingestion: IngestionService,
                             runtime: FolderIngestionRuntime?) async throws {
        let fm = FileManager.default

        // 1 — Czech project notebook: folder + loose files + notes + chat.
        let alfa = try store.createNotebook(name: "Projekt Alfa", description: "Smlouvy, porady a provoz")
        guard let alfaId = alfa.id else { return }
        let folders = dir.appendingPathComponent("folders", isDirectory: true)
        if let runtime, let roots = try? fm.contentsOfDirectory(at: folders, includingPropertiesForKeys: nil) {
            for root in roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where root.hasDirectoryPath {
                _ = try? await runtime.addFolder(notebookId: alfaId, url: root)
            }
        }
        var looseSources: [Source] = []
        let loose = dir.appendingPathComponent("loose", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: loose, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let source = try? await ingestion.ingestFile(file, into: alfaId) { looseSources.append(source) }
            }
        }
        let pasted = try await ingestion.ingestRawText(
            title: "Zápis z kick-offu",
            text: """
            Kick-off projektu Alfa proběhl 6. října. Dohodli jsme harmonogram ve třech fázích:
            analýza (do konce října), pilotní provoz (listopad) a ostré spuštění v prosinci.
            Hlavní rizika: zpoždění dodávek hardwaru, rozpočet a dostupnost klíčových lidí.
            Odpovědnost za komunikaci s dodavatelem má Jana Nováková.
            """,
            into: alfaId)
        looseSources.insert(pasted, at: 0)

        _ = try store.createNote(notebookId: alfaId, title: "Shrnutí rizik", bodyMd: """
            # Shrnutí rizik

            - **Dodávky** — zpoždění hardwaru až o 3 týdny
            - **Rozpočet** — rezerva 12 %
            - **Lidé** — dva klíčoví specialisté sdílení s jiným projektem
            """)
        _ = try store.createNote(notebookId: alfaId, title: "Otázky na dodavatele", bodyMd: """
            1. Jaká je výpovědní lhůta servisní smlouvy?
            2. Kdo hradí náklady na migraci dat?
            """)
        _ = try store.createPersona(notebookId: alfaId, name: "Právník",
                                    instructions: "Odpovídej stručně a cituj konkrétní články smluv.")

        let citations = try makeCitations(sources: looseSources, store: store)
        for (index, title) in ["Harmonogram pilotu", "Migrace dat", "Kontakty dodavatele"].enumerated() {
            let s = try store.createChatSession(notebookId: alfaId, title: title)
            try conversation(store: store, sessionId: s.id, question: title + "?",
                             answer: "Krátká odpověď č. \(index + 1).", citations: [])
        }

        let summary = try store.createChatSession(notebookId: alfaId, title: "Shrnutí servisní smlouvy")
        try conversation(store: store, sessionId: summary.id, question: "Shrň servisní smlouvu ve třech bodech.",
                         answer: """
            - Smlouva je uzavřena na **24 měsíců** s automatickým prodloužením [1].
            - Výpovědní lhůta je *tři měsíce*.
            - Reakční doba na kritické incidenty je 4 hodiny.
            """, citations: Array(citations.prefix(1)))
        let risk = try store.createChatSession(notebookId: alfaId, title: "Jaká jsou hlavní rizika projektu?")
        try conversation(store: store, sessionId: risk.id, question: "Jaká jsou hlavní rizika projektu?", answer: """
            ## Hlavní rizika

            Podle zápisu z kick-offu a smluv jsou **tři hlavní rizika** [1]:

            1. **Zpoždění dodávek** hardwaru — dodavatel garantuje termín jen s výhradou [2].
            2. **Rozpočet** — rezerva je *pouze* `12 %`.
            3. **Dostupnost lidí** — klíčoví specialisté jsou sdílení.

            > Projekt je realizovatelný, pokud se zajistí financování pilotního provozu.

            Doporučuji domluvit s dodavatelem smluvní pokutu za zpoždění a vést [registr rizik](https://example.com/rizika).
            """, citations: citations)
        // 2 — English research notebook.
        let research = try store.createNotebook(name: "Product research", description: "Interviews and market notes")
        if let id = research.id {
            _ = try await ingestion.ingestRawText(title: "Interview — logistics lead", text: """
                The biggest pain point is reconciling delivery notes with invoices. Today this takes two \
                people half a day every week. A searchable archive with citations would save most of it.
                """, into: id)
            _ = try store.createNote(notebookId: id, title: "Interview themes", bodyMd: "- Reconciliation\n- Search\n- Trust in citations")
            let s = try store.createChatSession(notebookId: id, title: "What do customers struggle with?")
            try conversation(store: store, sessionId: s.id, question: "What do customers struggle with?",
                             answer: "Mostly **reconciliation** of delivery notes and invoices.", citations: [])
        }

        // 3 — Small empty-ish notebook (new chat state).
        _ = try store.createNotebook(name: "Osobní", description: "")
    }

    private static func conversation(store: NotebookStore, sessionId: Int64?, question: String,
                                     answer: String, citations: [Citation]) throws {
        guard let sessionId else { return }
        let now = Date()
        try store.appendMessage(ChatMessage(sessionId: sessionId, role: .user, content: question,
                                            createdAt: now.addingTimeInterval(-60)))
        try store.appendMessage(ChatMessage(sessionId: sessionId, role: .assistant, content: answer,
                                            citations: citations, model: "ollama:llama3.1", createdAt: now))
    }

    /// Snapshot citations (v2 fields) pointing at real sources and chunks.
    private static func makeCitations(sources: [Source], store: NotebookStore) throws -> [Citation] {
        var result: [Citation] = []
        for (index, source) in sources.prefix(2).enumerated() {
            guard let sourceId = source.id,
                  let chunk = try store.chunks(sourceId: sourceId).first, let chunkId = chunk.id else { continue }
            var c = Citation(marker: index + 1, chunkId: chunkId, sourceId: sourceId,
                             snippet: String(chunk.text.prefix(160)))
            c.displayName = source.title
            c.relPath = source.rawPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            c.text = chunk.text
            c.chunkIds = [chunkId]
            c.spans = [CitationSpan(start: 0, end: chunk.text.count, pageFrom: index == 0 ? nil : 2, pageTo: nil)]
            result.append(c)
        }
        return result
    }
}
#endif
