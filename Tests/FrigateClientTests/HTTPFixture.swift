import Foundation
import Network
import Testing

/// Synthetic loopback HTTP server; never contacts a camera or uses a real session.
final class HTTPFixture: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var headers = ["Content-Type": "text/html"]
        var body = Data("<html><body>Fixture</body></html>".utf8)
        var hang = false
        var abort = false
        var reportedLength: Int?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "HTTPFixture")
    private let response: @Sendable (String) -> Response
    private var requests: [String] = []
    private var requestTexts: [String] = []
    private var connections: [NWConnection] = []

    init(response: @escaping @Sendable (String) -> Response = { _ in Response() }) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }

    var port: UInt16? {
        guard let port = listener.port?.rawValue, port > 0 else { return nil }
        return port
    }
    var paths: [String] { queue.sync { requests } }
    var receivedRequests: [String] { queue.sync { requestTexts } }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let request = buffered + data
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { connection.cancel() } else { self.receive(connection, buffered: request) }
                return
            }
            let path = String(text.split(separator: " ").dropFirst().first ?? "/")
            self.requests.append(path)
            self.requestTexts.append(text)
            let result = self.response(path)
            if result.abort { connection.cancel(); return }
            if result.hang { return }
            var headers = result.headers
            headers["Content-Length"] = String(result.reportedLength ?? result.body.count)
            headers["Connection"] = "close"
            let header = "HTTP/1.1 \(result.status) Fixture\r\n" + headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
            connection.send(content: Data(header.utf8) + result.body,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw NSError(domain: "FixtureTimeout", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Synthetic fixture timed out."])
}
