import Foundation

/// Thread-safe queue of stubbed responses. Each `URLProtocol` start dequeues
/// one stub and serves it. Tests call `StubURLProtocol.enqueue(...)` before
/// invoking the client.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let bodyChunks: [Data]

        static func json(_ data: Data, status: Int = 200) -> Stub {
            Stub(
                statusCode: status,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [data]
            )
        }

        static func ndjson(_ lines: [Data], status: Int = 200) -> Stub {
            Stub(
                statusCode: status,
                headers: ["Content-Type": "application/x-ndjson"],
                bodyChunks: lines.map { line in
                    var d = line
                    d.append(0x0A) // newline
                    return d
                }
            )
        }

        static func connectionRefused() -> Stub {
            Stub(statusCode: -1, headers: [:], bodyChunks: [])
        }
    }

    private static let lock = NSLock()
    private static nonisolated(unsafe) var stubs: [Stub] = []

    static func enqueue(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(stub)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
    }

    private static func dequeue() -> Stub? {
        lock.lock(); defer { lock.unlock() }
        return stubs.isEmpty ? nil : stubs.removeFirst()
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = StubURLProtocol.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        if stub.statusCode == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.bodyChunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
