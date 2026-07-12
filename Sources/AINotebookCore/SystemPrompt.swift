import Foundation

public enum SystemPrompt {

    public static func compose(
        hits: [RetrievalHit],
        currentNoteContent: String? = nil,
        notebookInstructions: String? = nil
    ) -> String {
        let header = """
        You are a helpful assistant answering questions about the user's notebook.
        Use ONLY the provided CONTEXT to answer. If the answer isn't in the
        context, say so plainly. When you use a fact from a context block,
        cite it inline as [N] where N is the block number. Multiple citations
        may appear in a single sentence: [1][3].
        """

        var sections: [String] = []
        // Per-notebook instructions lead so they frame everything below (FR-C1).
        if let instructions = notebookInstructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("NOTEBOOK INSTRUCTIONS:\n" + instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        sections.append(header)

        if hits.isEmpty {
            sections.append("CONTEXT:\n(none)")
        } else {
            let blocks = hits.enumerated().map { (i, hit) in
                "[\(i + 1)] \(hit.snippet)"
            }.joined(separator: "\n")
            sections.append("CONTEXT:\n" + blocks)
        }

        if let note = currentNoteContent,
           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(
                "CURRENTLY OPEN NOTE (additional context — user may be asking about this):\n"
                + note
            )
        }

        return sections.joined(separator: "\n\n")
    }
}
