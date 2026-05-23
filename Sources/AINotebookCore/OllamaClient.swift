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

    /// `POST /api/pull` — streams `OllamaPullEvent`s. Terminates when the
    /// server emits `{"status":"success"}` or closes the stream.
    public func pullModel(name: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("api/pull")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try encoder.encode(["name": name])

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 10_000 { break }
                        }
                        continuation.finish(throwing: OllamaError.httpStatus(
                            code: http.statusCode,
                            body: String(data: data, encoding: .utf8) ?? ""
                        ))
                        return
                    }

                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        guard let lineData = line.data(using: .utf8) else { continue }
                        do {
                            let event = try decoder.decode(OllamaPullEvent.self, from: lineData)
                            continuation.yield(event)
                            if event.isTerminalSuccess {
                                break
                            }
                        } catch {
                            continuation.finish(throwing: OllamaError.decoding(
                                message: String(describing: error)
                            ))
                            return
                        }
                    }
                    continuation.finish()
                } catch let urlError as URLError {
                    if urlError.code == .timedOut {
                        continuation.finish(throwing: OllamaError.timeout)
                    } else {
                        continuation.finish(throwing: OllamaError.notReachable)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `POST /api/embed` — returns one `[Double]` per input string.
    public func embed(model: String, input: [String]) async throws -> [[Double]] {
        let url = baseURL.appendingPathComponent("api/embed")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(OllamaEmbedRequest(model: model, input: input))

        let (data, response) = try await sendData(req)
        try ensureSuccess(response: response, body: data)
        do {
            let decoded = try decoder.decode(OllamaEmbedResponse.self, from: data)
            return decoded.embeddings
        } catch {
            throw OllamaError.decoding(message: String(describing: error))
        }
    }

    /// `POST /api/chat` — streams `OllamaChatChunk`s. Ends after the chunk
    /// with `done == true`.
    public func chat(
        model: String,
        messages: [OllamaChatMessage],
        options: OllamaChatRequest.Options? = nil
    ) -> AsyncThrowingStream<OllamaChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("api/chat")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try encoder.encode(OllamaChatRequest(
                        model: model,
                        messages: messages,
                        stream: true,
                        options: options
                    ))

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 10_000 { break }
                        }
                        continuation.finish(throwing: OllamaError.httpStatus(
                            code: http.statusCode,
                            body: String(data: data, encoding: .utf8) ?? ""
                        ))
                        return
                    }

                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        guard let lineData = line.data(using: .utf8) else { continue }
                        do {
                            let chunk = try decoder.decode(OllamaChatChunk.self, from: lineData)
                            continuation.yield(chunk)
                            if chunk.done { break }
                        } catch {
                            continuation.finish(throwing: OllamaError.decoding(
                                message: String(describing: error)
                            ))
                            return
                        }
                    }
                    continuation.finish()
                } catch let urlError as URLError {
                    if urlError.code == .timedOut {
                        continuation.finish(throwing: OllamaError.timeout)
                    } else {
                        continuation.finish(throwing: OllamaError.notReachable)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
