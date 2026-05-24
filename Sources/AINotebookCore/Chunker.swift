import Foundation

/// Pure, deterministic text splitter. Produces overlapping windows of
/// approximately `windowChars` characters (≈ `windowChars / 4` tokens).
/// Always breaks on whitespace boundaries so words are never split.
public enum Chunker {

    /// Defaults: 512-token window, 64-token overlap, with the 1 token ≈ 4 char
    /// rule of thumb used industry-wide for sizing prompts.
    public static func chunk(
        _ raw: String,
        windowChars: Int = 2048,
        overlapChars: Int = 256
    ) -> [ChunkDraft] {
        precondition(windowChars > overlapChars, "overlap must be smaller than window")
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        if cleaned.count <= windowChars {
            return [ChunkDraft(text: cleaned, tokenCount: estimateTokens(cleaned))]
        }

        var drafts: [ChunkDraft] = []
        let chars = Array(cleaned)
        var start = 0
        while start < chars.count {
            var end = min(start + windowChars, chars.count)
            // Avoid splitting mid-word: scan backwards to the previous
            // whitespace, but only up to 200 chars to bound the search.
            if end < chars.count {
                var probe = end
                let floor = max(end - 200, start + 1)
                while probe > floor, !chars[probe - 1].isWhitespace {
                    probe -= 1
                }
                if probe > floor { end = probe }
            }
            let slice = String(chars[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty {
                drafts.append(ChunkDraft(text: slice, tokenCount: estimateTokens(slice)))
            }
            if end >= chars.count { break }
            start = max(end - overlapChars, start + 1)
        }
        return drafts
    }

    /// 1 token ≈ 4 chars, with a minimum of 1.
    public static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }
}
