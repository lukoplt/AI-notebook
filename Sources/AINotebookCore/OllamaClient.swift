import Foundation

/// Typed wrapper around the Ollama HTTP API. Lives in `AINotebookCore`
/// and is the ONLY file in `AINotebookCore` allowed to import URLSession.
/// All other Core files stay offline (enforced by CI grep gate).
public final class OllamaClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// Best-effort 1.5s probe of `/api/tags`. Returns `true` if reachable.
    public func detect(timeout: TimeInterval = 1.5) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// `GET /api/tags` — returns the locally-installed models.
    public func listModels() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await sendData(req)
        try ensureSuccess(response: response, body: data)
        do {
            let list = try decoder.decode(OllamaModelList.self, from: data)
            return list.models
        } catch {
            throw OllamaError.decoding(message: String(describing: error))
        }
    }

    // MARK: - Helpers

    private func sendData(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .timedOut { throw OllamaError.timeout }
            throw OllamaError.notReachable
        } catch {
            throw OllamaError.notReachable
        }
    }

    private func ensureSuccess(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.notReachable
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            throw OllamaError.httpStatus(code: http.statusCode, body: bodyString)
        }
    }
}
