import Foundation
import AppKit
import SwiftUI
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

    var port: UInt16? {
        guard let port = listener.port?.rawValue, port > 0 else { return nil }
        return port
    }
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
            let payload: Data
            let contentType: String
            if text.hasPrefix("GET /video.mp4 ") {
                payload = (try? Data(contentsOf: Bundle.module.url(forResource: "web-video", withExtension: "mp4", subdirectory: "Resources")!)) ?? Data()
                contentType = "video/mp4"
            } else {
                let body = text.hasPrefix("GET /api/version ") ? "test-version" :
                    "<html><body><video muted autoplay loop src='/video.mp4'></video><button onclick='this.textContent=\"Responsive\"'>Check</button></body></html>"
                payload = Data(body.utf8)
                contentType = "text/html"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
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
    let oldView = try #require(connection.webView) // SwiftUI can retain the old view until its next update.
    let original = ObjectIdentifier(oldView)
    // Keep the page's JS thread busy while native watchdog deadlines continue firing.
    stallPage(oldView)
    connection.checkPageResponsiveness()
    try await Task.sleep(for: .milliseconds(5500))
    connection.checkPageResponsiveness()
    try await eventually { connection.webView.map { ObjectIdentifier($0) != original } == true && connection.state == .connected }
    let newView = try #require(connection.webView)
    #expect(newView.configuration.websiteDataStore === store)
    let cookies = await store.httpCookieStore.allCookies()
    #expect(cookies.contains { $0.name == "fixture-session" && $0.value == "preserved" })
    #expect(fixture.receivedSession)
    let result = try await newView.evaluateJavaScript("document.querySelector('button').click(); document.querySelector('button').textContent")
    #expect(result as? String == "Responsive")
    #expect(oldView !== newView)
    connection.setViewVisible(false)
}

@MainActor @Test func repeatedPageStallsUnloadThePageUntilManualReconnect() async throws {
    let fixture = try PageFixture()
    defer { fixture.stop() }
    try await eventually { fixture.port != nil }
    let suite = "PageRecoveryBudgetTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(connection.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { connection.setViewVisible(false) }
    try await eventually { connection.state == .connected }
    for _ in 0..<3 {
        connection.restoreUnresponsivePage()
        try await eventually { connection.state == .connected }
        #expect(!connection.pageRecoveryPaused)
    }
    connection.restoreUnresponsivePage()
    #expect(connection.pageRecoveryPaused)
    #expect(connection.webView == nil)
    #expect(connection.indicatorState == .reconnecting)
    connection.checkPageResponsiveness()
    try await Task.sleep(for: .milliseconds(200))
    #expect(connection.pageRecoveryPaused)
    connection.reconnect()
    try await eventually { connection.state == .connected && connection.webView?.url != nil }
    #expect(!connection.pageRecoveryPaused)
}

@MainActor @Test func existingNativePreferencesStillOpenTheFullWebDashboard() async throws {
    let fixture = try PageFixture()
    defer { fixture.stop() }
    try await eventually { fixture.port != nil }
    let suite = "WebMigrationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "nativeLiveEnabled")
    defaults.set(true, forKey: "nativeShowAllCameras")
    let connection = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(connection.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { connection.setViewVisible(false) }
    try await eventually { connection.state == .connected }
    let view = try #require(connection.webView)
    let result = try await view.evaluateJavaScript("document.querySelector('button').textContent")
    #expect(result as? String == "Check")
}

@MainActor @Test func hostedWebWindowSuspendsOnlyWhenHiddenMinimizedOrClosed() async throws {
    let fixture = try PageFixture()
    defer { fixture.stop() }
    try await eventually { fixture.port != nil }
    let suite = "WebWindowTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ContentView(connection: connection, showingSettings: .constant(false)))
    window.makeKeyAndOrderFront(nil)
    #expect(connection.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { connection.setViewVisible(false); window.close() }
    try await eventually { connection.state == .connected && connection.window === window }
    let view = try #require(connection.webView)
    for _ in 0..<100 {
        if await view.requestMediaPlaybackState() == .playing { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await view.requestMediaPlaybackState() == .playing)
    window.miniaturize(nil)
    try await eventually { window.isMiniaturized }
    #expect(await view.requestMediaPlaybackState() == .suspended)
    window.deminiaturize(nil)
    try await eventually { !window.isMiniaturized }
    #expect(await view.requestMediaPlaybackState() != .suspended)
    connection.hideWindow()
    #expect(await view.requestMediaPlaybackState() == .suspended)
    window.makeKeyAndOrderFront(nil)
    try await eventually { window.isVisible }
    // KVO and WebKit resume asynchronously when the window reappears.
    for _ in 0..<100 {
        if await view.requestMediaPlaybackState() != .suspended { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await view.requestMediaPlaybackState() != .suspended)
    window.close()
    #expect(await view.requestMediaPlaybackState() == .suspended)
}

@Test func pageRecoveryBudgetExpiresAndCanBeReset() {
    var budget = PageRecoveryBudget()
    let now = Date(timeIntervalSince1970: 1000)
    #expect(budget.retry(afterFailureAt: now) == 2)
    #expect(budget.retry(afterFailureAt: now) == 4)
    #expect(budget.retry(afterFailureAt: now) == 8)
    #expect(budget.retry(afterFailureAt: now) == nil)
    #expect(budget.retry(afterFailureAt: now.addingTimeInterval(300)) == 2)
    budget.reset()
    #expect(budget.retry(afterFailureAt: now.addingTimeInterval(301)) == 2)
}
