import Foundation
import Testing
import WebKit
@testable import FrigateClient

@MainActor @Test func deadlineCancellationAndRestartAllowCertificateReview() async throws {
    let deadline = NavigationDeadline(timeout: .milliseconds(40))
    var expirations = 0
    deadline.start { expirations += 1 }
    deadline.cancel() // Review of a certificate pauses the deadline.
    try await Task.sleep(for: .milliseconds(100))
    #expect(expirations == 0)
    deadline.start { expirations += 1 } // Resolving trust gives a fresh deadline.
    try await waitUntil { expirations == 1 }
    deadline.start { expirations += 1 }
    deadline.cancel() // A successful page cancels recovery.
    try await Task.sleep(for: .milliseconds(100))
    #expect(expirations == 1)
}

@MainActor @Test func internalNavigationHasANativeDeadlineEvenWithAHealthyAPI() async throws {
    let fixture = try HTTPFixture { path in .init(hang: path == "/hang") }
    defer { fixture.stop() }
    try await waitUntil { fixture.port != nil }
    let suite = "NavigationDeadlineTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent(),
                                          navigationTimeout: .seconds(2))
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { controller.setViewVisible(false) }
    try await waitUntil { controller.state == .connected }
    let view = try #require(controller.webView)
    _ = try await view.evaluateJavaScript("window.location.href='/hang'")
    try await waitUntil { fixture.paths.contains("/hang") && controller.state == .connecting }
    try await waitUntil(timeout: 5) { controller.webView !== view }
    #expect(controller.state == .reconnecting)
    #expect(controller.detail == "Frigate took too long to respond.")
}
