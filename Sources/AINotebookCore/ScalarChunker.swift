import CryptoKit
import Foundation

/// Windows are measured in Unicode scalars of the unchanged canonical text.
public enum ScalarChunker {
    public static func chunk(
        _ text: String,
        pageStarts: [(offset: Int, page: Int)] = [],
        window: Int = 2048,
        overlap: Int = 256
    ) -> [RevisionChunkDraft] {
        precondition(window > overlap && overlap >= 0)
        return try! chunks(text, pageStarts: pageStarts, pages: nil, window: window, overlap: overlap, maxChunks: nil)
    }

    public static func bounded(
        _ text: String, pages: [PageBoundary], window: Int = 2048,
        overlap: Int = 256, maxChunks: Int
    ) throws -> [RevisionChunkDraft] {
        guard window > overlap, overlap >= 0, maxChunks >= 0 else {
            throw IngestionError(code: "chunkLimit")
        }
        return try chunks(text, pageStarts: [], pages: pages, window: window, overlap: overlap, maxChunks: maxChunks)
    }

    static func isWhitespace(_ value: UInt32) -> Bool {
        (9...13).contains(value)
            || [0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000].contains(value)
            || (0x2000...0x200A).contains(value)
    }

    private static func chunks(
        _ text: String, pageStarts: [(offset: Int, page: Int)], pages: [PageBoundary]?,
        window: Int, overlap: Int, maxChunks: Int?
    ) throws -> [RevisionChunkDraft] {
        let scalars = Array(text.unicodeScalars)
        let space = isWhitespace
        var result: [RevisionChunkDraft] = []
        var start = 0
        while start < scalars.count {
            var end = start + min(window, scalars.count - start)
            if end < scalars.count {
                var probe = end
                let floor = max(end - 200, start + 1)
                while probe > floor && !space(scalars[probe - 1].value) { probe -= 1 }
                if probe > floor { end = probe }
            }
            var lo = start, hi = end
            while lo < hi && space(scalars[lo].value) { lo += 1 }
            while hi > lo && space(scalars[hi - 1].value) { hi -= 1 }
            if lo < hi {
                if let maxChunks, result.count >= maxChunks { throw IngestionError(code: "chunkLimit") }
                let hint: Int?
                if let pages {
                    hint = pages.first { $0.start < $0.end && $0.start < hi && $0.end > lo }?.page
                } else {
                    hint = pageStarts.last(where: { $0.offset <= lo })?.page
                }
                result.append(RevisionChunkDraft(
                    text: String(String.UnicodeScalarView(scalars[lo..<hi])),
                    tokenCount: max(1, (hi - lo + 3) / 4),
                    pageHint: hint,
                    charStart: lo,
                    charEnd: hi,
                    lang: nil,
                    langInherited: false
                ))
            }
            if end == scalars.count { break }
            start = max(end - overlap, start + 1)
        }
        return result
    }
}

/// Keeps the extractor compatibility boundary shared by imports and note snapshots.
enum ExtractedRevisionAssembly {
    static func make(
        extracted: ExtractedText,
        kind: SourceType
    ) -> (draft: RevisionDraft, chunks: [RevisionChunkDraft], pageStarts: [(offset: Int, page: Int)]) {
        let canonicalText: String
        var pageStarts: [(offset: Int, page: Int)] = []
        if kind == .pdf {
            let pages = extracted.text.components(separatedBy: "\u{0C}")
            var offset = 0
            for (index, page) in pages.enumerated() {
                let hint = extracted.pageHints.flatMap { index < $0.count ? $0[index] : nil } ?? index + 1
                pageStarts.append((offset, hint))
                offset += page.unicodeScalars.count + 2
            }
            canonicalText = pages.joined(separator: "\n\n")
        } else {
            canonicalText = extracted.text
        }

        // Existing Office streams are not the normative paragraph/slide/sheet assembly.
        let legacy = kind == .docx || kind == .pptx || kind == .xlsx
        let chunks: [RevisionChunkDraft]
        if legacy {
            chunks = Chunker.chunk(canonicalText).map {
                RevisionChunkDraft(text: $0.text, tokenCount: $0.tokenCount, pageHint: $0.pageHint,
                                   charStart: nil, charEnd: nil, lang: nil, langInherited: false)
            }
        } else {
            chunks = ScalarChunker.chunk(canonicalText, pageStarts: pageStarts)
        }
        let hash = SHA256.hash(data: Data(canonicalText.utf8)).map { String(format: "%02x", $0) }.joined()
        return (RevisionDraft(contentHash: hash, canonicalText: canonicalText,
                              textFormatVersion: 1, chunkerVersion: legacy ? 1 : 2), chunks, pageStarts)
    }
}

/// Renewal never owns a SQLite transaction while waiting on the clock.
enum ExtractionLeaseRenewal {
    static func start(store: NotebookStore, fence: JobFence, clock: any IngestLeaseClock) -> Task<Void, Never> {
        Task {
            do {
                while !Task.isCancelled {
                    let (deadline, overflow) = clock.now().addingReportingOverflow(60)
                    guard !overflow else { return }
                    try await clock.wait(until: deadline)
                    try Task.checkCancellation()
                    let renewed = try await MainActor.run {
                        try store.renewJob(fence: fence, now: clock.now())
                    }
                    if !renewed { return }
                }
            } catch {
                // Publication still validates ownership and expiration after extraction.
            }
        }
    }
}
