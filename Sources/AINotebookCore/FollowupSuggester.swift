import Foundation

/// Asks the chat model for up to 3 short follow-up questions a user might ask
/// next, given their question and the assistant's answer. Dependency-light:
/// reuses the same `ChatStreaming` abstraction the chat engine uses.
public actor FollowupSuggester {
    private let chat: ChatStreaming
    public let chatModel: String

    public init(chat: ChatStreaming, chatModel: String) {
        self.chat = chat
        self.chatModel = chatModel
    }

    /// Up to 3 trimmed, non-empty follow-up question strings, parsed from the
    /// model output (one per line, leading list markers stripped).
    public func generate(userText: String, answer: String) async throws -> [String] {
        let prompt = """
        Based on this question and answer, suggest 3 short, specific follow-up \
        questions the user might ask next. One question per line, no numbering.

        Question:
        \(userText)

        Answer:
        \(answer)
        """
        let turns: [ChatTurn] = [ChatTurn(role: .user, content: prompt)]
        var assembled = ""
        for try await token in chat.stream(model: chatModel, messages: turns) {
            assembled += token
        }
        return Self.parse(assembled)
    }

    /// Split into lines, strip leading list markers ("1.", "-", "•"), drop
    /// blanks, cap at 3.
    static func parse(_ raw: String) -> [String] {
        var out: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = stripMarker(String(line))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            out.append(stripped)
            if out.count == 3 { break }
        }
        return out
    }

    /// Remove a leading ordered/unordered list marker like "1.", "2)", "-",
    /// "*", or "•" from the start of a line.
    private static func stripMarker(_ line: String) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if let first = s.first, first == "-" || first == "*" || first == "•" {
            s = s.dropFirst()
            return String(s)
        }
        // Numbered markers: leading digits followed by "." or ")".
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
        if idx > s.startIndex, idx < s.endIndex, s[idx] == "." || s[idx] == ")" {
            return String(s[s.index(after: idx)...])
        }
        return String(s)
    }
}
