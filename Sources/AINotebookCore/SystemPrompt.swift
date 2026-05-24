import Foundation

public enum SystemPrompt {

    public static func compose(hits: [RetrievalHit]) -> String {
        let header = """
        You are a helpful assistant answering questions about the user's notebook.
        Use ONLY the provided CONTEXT to answer. If the answer isn't in the
        context, say so plainly. When you use a fact from a context block,
        cite it inline as [N] where N is the block number. Multiple citations
        may appear in a single sentence: [1][3].
        """

        if hits.isEmpty {
            return header + "\n\nCONTEXT:\n(none)"
        }

        let blocks = hits.enumerated().map { (i, hit) in
            "[\(i + 1)] \(hit.snippet)"
        }.joined(separator: "\n")

        return header + "\n\nCONTEXT:\n" + blocks
    }
}
