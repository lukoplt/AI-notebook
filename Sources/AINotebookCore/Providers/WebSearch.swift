import Foundation

/// A single web-search hit (Epic E3). Kept out of the system prompt and
/// injected as user-message context to limit prompt-injection surface, matching
/// the Windows behavior.
public struct WebSearchResult: Equatable, Hashable, Sendable, Codable {
    public let title: String
    public let snippet: String
    public let url: String

    public init(title: String, snippet: String, url: String) {
        self.title = title
        self.snippet = snippet
        self.url = url
    }
}

public protocol WebSearch: Sendable {
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

/// E3: opt-in web search via the DuckDuckGo Instant Answer API. Returns the
/// abstract plus related topics as snippets. Ported from the Windows
/// `DuckDuckGoWebSearch`.
public struct DuckDuckGoWebSearch: WebSearch {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: String, maxResults: Int = 5) async throws -> [WebSearchResult] {
        var comps = URLComponents(string: "https://api.duckduckgo.com/")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        let (data, _) = try await session.data(from: comps.url!)
        let doc = try JSONDecoder().decode(DdgResponse.self, from: data)
        return Self.parse(doc, query: query, maxResults: maxResults)
    }

    /// Pure mapping from the DDG payload to results, factored out for testing.
    static func parse(_ doc: DdgResponse, query: String, maxResults: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        if let abstract = doc.AbstractText, !abstract.trimmingCharacters(in: .whitespaces).isEmpty {
            results.append(WebSearchResult(title: doc.Heading ?? query, snippet: abstract, url: doc.AbstractURL ?? ""))
        }
        for topic in doc.RelatedTopics ?? [] {
            if results.count >= maxResults { break }
            guard let text = topic.Text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            results.append(WebSearchResult(title: String(text.prefix(80)), snippet: text, url: topic.FirstURL ?? ""))
        }
        return results
    }

    public struct DdgResponse: Codable, Sendable {
        public var AbstractText: String?
        public var AbstractURL: String?
        public var Heading: String?
        public var RelatedTopics: [DdgTopic]?
    }

    public struct DdgTopic: Codable, Sendable {
        public var Text: String?
        public var FirstURL: String?
    }
}

/// Renders web results as a user-message context block (never the system
/// prompt) so the model can cite them alongside local sources.
public enum WebSearchContext {
    public static func render(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "" }
        let blocks = results.enumerated().map { (i, r) in
            "[W\(i + 1)] \(r.title)\n\(r.snippet)\n\(r.url)"
        }.joined(separator: "\n\n")
        return "WEB SEARCH RESULTS (cite as [W1], [W2]…):\n" + blocks
    }
}
