import AppKit
import Foundation
import Testing
import WebKit
@testable import FrigateClient

@MainActor private func waitForPlayback(_ expected: WKMediaPlaybackState, in view: WKWebView) async throws {
    for _ in 0..<100 {
        if await view.requestMediaPlaybackState() == expected { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await view.requestMediaPlaybackState() == expected)
}

@MainActor @Test func hiddenBrowsersSuspendBeforeAutoplayAndPendingResourcesFinish() async throws {
    let video = try Data(contentsOf: #require(Bundle.module.url(forResource: "web-video", withExtension: "mp4", subdirectory: "Resources")))
    let fixture = try HTTPFixture { path in
        if path == "/video.mp4" { return .init(headers: ["Content-Type": "video/mp4"], body: video) }
        if path == "/pending.png" { return .init(hang: true) }
        return .init(body: Data("<html><body><video muted autoplay loop src='/video.mp4'></video><img src='/pending.png'></body></html>".utf8))
    }
    defer { fixture.stop() }
    try await waitUntil { (fixture.port ?? 0) > 0 }
    let suite = "HiddenMediaTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let wakeCenter = NotificationCenter()
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent(),
                                          wakeNotificationCenter: wakeCenter)
    controller.setViewVisible(false)
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { controller.setViewVisible(false); window.close() }
    try await waitUntil { controller.webView != nil && fixture.paths.contains("/pending.png") }
    var view = try #require(controller.webView)
    window.contentView = view
    window.orderOut(nil)
    #expect(view.isLoading)
    #expect(controller.state == .connecting)
    try await waitForPlayback(.suspended, in: view)

    // A terminated process is automatically replaced while the window remains hidden.
    controller.webViewWebContentProcessDidTerminate(view)
    try await waitUntil { controller.webView != nil && controller.webView !== view }
    view = try #require(controller.webView)
    window.contentView = view
    try await waitForPlayback(.suspended, in: view)
    #expect(view.isLoading)

    // Wake reloads are also suspended before navigation can finish.
    let rootRequests = fixture.paths.filter { $0 == "/" }.count
    wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await waitUntil { fixture.paths.filter { $0 == "/" }.count > rootRequests }
    try await waitForPlayback(.suspended, in: view)
    #expect(view.isLoading)

    // Showing the page resumes exactly once, despite reconnects and pending resources.
    window.makeKeyAndOrderFront(nil)
    controller.setViewVisible(true)
    try await waitForPlayback(.playing, in: view)
    controller.setViewVisible(true)
    #expect(await view.requestMediaPlaybackState() == .playing)
    controller.setViewVisible(false)
    try await waitForPlayback(.suspended, in: view)
}
