import Foundation
import Network
import Testing
import WebKit
@testable import FrigateClient

@MainActor @Test func aMissingJavaScriptCallbackCannotBlockPageRecovery() async throws {
    var replies: [PageWatchdog.Reply] = []
    var recoveries = 0
    let watchdog = PageWatchdog(timeout: .milliseconds(20), probe: { replies.append($0) },
                                recover: { recoveries += 1 })
    watchdog.check()
    watchdog.check() // No overlapping JavaScript requests.
    #expect(replies.count == 1)
    try await eventually { !watchdog.isChecking }
    #expect(recoveries == 0) // One missed reply is insufficient.
    watchdog.check()
    try await eventually { recoveries == 1 }
    try #require(replies.count == 2)
    #expect(recoveries == 1)
    replies[0](true) // A late reply from the abandoned page is ignored.
    replies[1](false)
    #expect(recoveries == 1)
}

@MainActor @Test func responsivePagesAndNavigationBreakConsecutiveFailures() {
    var replies: [PageWatchdog.Reply] = []
    var recoveries = 0
    let watchdog = PageWatchdog(probe: { replies.append($0) }, recover: { recoveries += 1 })
    watchdog.check(); replies[0](false)
    watchdog.check(); replies[1](true)
    watchdog.check(); replies[2](false)
    #expect(recoveries == 0)
    watchdog.reset() // Navigation or hiding clears failures.
    watchdog.check(); replies[3](false)
    #expect(recoveries == 0)
    watchdog.check(); replies[4](false)
    #expect(recoveries == 1)
}

@MainActor @Test func hidingCancelsTheDeadlineAndIgnoresOldPageReplies() async throws {
    var replies: [PageWatchdog.Reply] = []
    var recoveries = 0
    let watchdog = PageWatchdog(timeout: .milliseconds(20), probe: { replies.append($0) },
                                recover: { recoveries += 1 })
    watchdog.check()
    watchdog.reset()
    replies[0](false)
    watchdog.check()
    try await eventually { !watchdog.isChecking }
    #expect(recoveries == 0)
    watchdog.reset()
}

/// A local HTTP fixture exercises the production controller and real WebKit processes.
private final class PageFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PageFixture")
    private var sawSession = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }

    var port: UInt16? { listener.port?.rawValue }
    var receivedSession: Bool { queue.sync { sawSession } }
    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let request = buffered + data
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { connection.cancel() }
                else { self.receive(connection, buffered: request) }
                return
            }
            if text.contains("fixture-session=preserved") { self.sawSession = true }
            let body = text.hasPrefix("GET /api/version ") ? "test-version" :
                "<html><body><button onclick='this.textContent=\"Responsive\"'>Check</button></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw NSError(domain: "PageWatchdogTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recovery timed out."])
}

@MainActor
private func stallPage(_ view: WKWebView) {
    view.evaluateJavaScript("const until = Date.now() + 25000; while (Date.now() < until) {}") { _, _ in }
}

@MainActor @Test func aStalledWebKitPageIsReplacedWithoutLosingItsSession() async throws {
    let fixture = try PageFixture()
    defer { fixture.stop() }
    try await eventually { fixture.port != nil }
    let suite = "PageWatchdogTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WKWebsiteDataStore.nonPersistent()
    let session = HTTPCookie(properties: [.name: "fixture-session", .value: "preserved",
        .domain: "127.0.0.1", .path: "/", .expires: Date.now.addingTimeInterval(3600)])!
    await store.httpCookieStore.setCookie(session)
    let connection = ConnectionController(defaults: defaults, websiteDataStore: store)
    #expect(connection.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    try await eventually { connection.state == .connected }
    let oldView = connection.webView // SwiftUI can retain the old view until its next update.
    let original = ObjectIdentifier(oldView)
    // Keep the page's JS thread busy while native watchdog deadlines continue firing.
    stallPage(oldView)
    connection.checkPageResponsiveness()
    try await Task.sleep(for: .milliseconds(5500))
    connection.checkPageResponsiveness()
    try await eventually { ObjectIdentifier(connection.webView) != original && connection.state == .connected }
    #expect(connection.webView.configuration.websiteDataStore === store)
    let cookies = await store.httpCookieStore.allCookies()
    #expect(cookies.contains { $0.name == "fixture-session" && $0.value == "preserved" })
    #expect(fixture.receivedSession)
    let result = try await connection.webView.evaluateJavaScript("document.querySelector('button').click(); document.querySelector('button').textContent")
    #expect(result as? String == "Responsive")
    #expect(oldView !== connection.webView)
    connection.setViewVisible(false)
}
