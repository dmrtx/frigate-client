import AppKit
import Foundation
import Testing
import WebKit
@testable import FrigateClient

@Test func microphoneRequestsPromptTheUserOnlyForTheConfiguredOrigin() throws {
    let server = try ServerAddress("https://frigate.example")
    let same = CaptureOrigin(scheme: "HTTPS", host: "FRIGATE.EXAMPLE", port: 0)
    let other = CaptureOrigin(scheme: "https", host: "other.example", port: 443)
    let wrongPort = CaptureOrigin(scheme: "https", host: "frigate.example", port: 8971)
    let insecure = CaptureOrigin(scheme: "http", host: "frigate.example", port: 80)
    #expect(MediaCapturePolicy.decision(server: server, origin: same, frameOrigin: same, type: .microphone) == .prompt)
    for origin in [other, wrongPort, insecure] {
        #expect(MediaCapturePolicy.decision(server: server, origin: origin, frameOrigin: same, type: .microphone) == .deny)
        #expect(MediaCapturePolicy.decision(server: server, origin: same, frameOrigin: origin, type: .microphone) == .deny)
    }
    #expect(MediaCapturePolicy.decision(server: nil, origin: same, frameOrigin: same, type: .microphone) == .deny)
    #expect(MediaCapturePolicy.decision(server: server, origin: same, frameOrigin: same, type: .camera) == .deny)
    #expect(MediaCapturePolicy.decision(server: server, origin: same, frameOrigin: same, type: .cameraAndMicrophone) == .deny)
    let ipv6 = try ServerAddress("http://[::1]:5000")
    #expect(CaptureOrigin(scheme: "http", host: "::1", port: 5000).matches(ipv6))
}

@MainActor private final class CaptureRequests: NSObject, WKUIDelegate {
    var count = 0
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        count += 1
        decisionHandler(.deny)
    }
}

@MainActor @Test func receivingVideoDoesNotRequestMicrophoneCapture() async throws {
    let video = try Data(contentsOf: #require(Bundle.module.url(forResource: "web-video", withExtension: "mp4", subdirectory: "Resources")))
    let fixture = try HTTPFixture { path in
        if path == "/video.mp4" { return .init(headers: ["Content-Type": "video/mp4"], body: video) }
        return .init(body: Data("<html><body><video muted autoplay loop src='/video.mp4'></video></body></html>".utf8))
    }
    defer { fixture.stop() }
    try await waitUntil { (fixture.port ?? 0) > 0 }
    let suite = "CapturePlaybackTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    try await waitUntil { controller.webView != nil }
    let view = try #require(controller.webView)
    let capture = CaptureRequests()
    view.uiDelegate = capture
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    defer { controller.setViewVisible(false); window.close() }
    try await waitUntil { controller.state == .connected }
    for _ in 0..<100 {
        if await view.requestMediaPlaybackState() == .playing { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await view.requestMediaPlaybackState() == .playing)
    #expect(capture.count == 0)
}
