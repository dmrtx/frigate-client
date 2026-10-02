import AVFoundation
import Foundation
import Testing
import WebKit
import AppKit
import Darwin
import SwiftUI
import CoreVideo
@testable import FrigateClient

func videoFixture(_ name: String = "video-h264") throws -> (Data, [Data]) {
    let url = Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Resources")!
    return try fragmentedFixture(Data(contentsOf: url))
}

func fragmentedFixture(_ data: Data) throws -> (Data, [Data]) {
    let boxes = try MP4Box.read(data)
    let moov = try #require(boxes.first(where: { $0.type == "moov" }))
    let initialize = Data(data[0..<moov.body.upperBound])
    let fragments = try boxes.filter { $0.type == "moof" }.map { box in
        let mdat = try #require(boxes.first(where: { $0.type == "mdat" && $0.start > box.start }))
        return Data(data[box.start..<mdat.body.upperBound])
    }
    return (initialize, fragments)
}

@Suite(.serialized)
struct NativeVideoTests {

/// Use a generated test pattern, never private camera footage, for repeatable throughput checks.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["FRIGATE_BENCHMARK_MP4"] != nil))
func syntheticNativePlaybackResourceSample() async throws {
    guard #available(macOS 14.4, *) else { return }
    let path = ProcessInfo.processInfo.environment["FRIGATE_BENCHMARK_MP4"]!
    let fixture = try LiveStreamFixture(videoData: Data(contentsOf: URL(fileURLWithPath: path)))
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let player = NativeLivePlayer(store: WKWebsiteDataStore.nonPersistent().httpCookieStore)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NativeVideoNSView(renderer: player.renderer)
    window.orderFront(nil)
    defer { player.stop(); window.orderOut(nil) }
    player.start(server: try ServerAddress("http://127.0.0.1:\(fixture.port!)"), stream: "example", fingerprint: nil)
    try await awaitNative { player.receivedFrames >= 30 && player.renderer.layer.isReadyForDisplay }
    let startCPU = cpuSeconds(), start = ProcessInfo.processInfo.systemUptime, framesBefore = player.receivedFrames
    try await Task.sleep(for: .seconds(20))
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let cpu = 100 * (cpuSeconds() - startCPU) / elapsed
    let frames = player.receivedFrames - framesBefore
    #expect(frames >= 500)
    #expect(player.isPlaying)
    #expect(fixture.opened == 1)
    let displayed = try #require(player.renderer.layer.sampleBufferRenderer.displayedPixelBuffer())
    print("Native displayed pixel buffer: \(CVPixelBufferGetWidth(displayed)) × \(CVPixelBufferGetHeight(displayed)).")
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("Synthetic native sample: \(frames) frames in \(String(format: "%.1f", elapsed)) s; test-process CPU \(String(format: "%.1f", cpu))% of one core; test-process peak RSS \(usage.ru_maxrss / (1024 * 1024)) MiB.")
    player.stop()
    let stoppedFrames = player.receivedFrames, stoppedCPU = cpuSeconds(), stopped = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(for: .seconds(5))
    #expect(player.receivedFrames == stoppedFrames)
    print("Stopped native sample: test-process CPU \(String(format: "%.1f", 100 * (cpuSeconds() - stoppedCPU) / (ProcessInfo.processInfo.systemUptime - stopped)))% of one core.")
}

@Test func nativeStreamURLsPreserveSubpathsAndEncodeCameraNames() throws {
    let server = try ServerAddress("https://frigate.example:8971/frigate")
    let url = NativeLivePlayer.streamURL(server: server, stream: "camera / main&extra")
    #expect(url.scheme == "wss")
    #expect(url.path == "/frigate/live/mse/api/ws")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "src", value: "camera / main&extra")])
}

@Test func nativeCameraListIgnoresDisabledCamerasAndUsesConfiguredStreams() throws {
    let data = Data(#"{"cameras":{"example":{"enabled":true,"live":{"streams":{"Main":"stream_main"}}},"disabled":{"enabled":false},"fallback":{"live":{"streams":{}}}}}"#.utf8)
    let cameras = try LiveCamera.decode(data)
    #expect(cameras.map(\.name) == ["example", "fallback"])
    #expect(cameras[0].streams == ["stream_main"])
    #expect(cameras[0].streamOptions[0].label == "Main")
    #expect(cameras[1].streams == ["fallback"])
}

@MainActor @Test func streamSelectionIsValidatedAndRememberedForEachCamera() async throws {
    let fixture = try LiveStreamFixture(config: #"{"cameras":{"example":{"live":{"streams":{"High":"main","Low":"sub","Duplicate":"sub"}}},"other":{}}}"#)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let suite = "StreamSelectionTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: preferences, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { controller.setViewVisible(false) }
    try await awaitNative { controller.state == .connected }
    controller.selectCamera("example")
    try await awaitNative { controller.nativePlayer.isPlaying }
    #expect(controller.activeCamera?.streamOptions.count == 2)
    controller.selectStream("not-configured")
    #expect(controller.selectedStream != "not-configured")
    controller.selectStream("main")
    try await awaitNative { fixture.requestedStreams.last == "main" && controller.nativePlayer.isPlaying }
    controller.selectStream("sub")
    try await awaitNative { fixture.requestedStreams.last == "sub" && controller.nativePlayer.isPlaying }
    controller.selectCamera("other")
    try await awaitNative { fixture.requestedStreams.last == "other" && controller.nativePlayer.isPlaying }
    controller.selectCamera("example")
    try await awaitNative { fixture.requestedStreams.last == "sub" && controller.nativePlayer.isPlaying }
    controller.reconnect()
    try await awaitNative { controller.state == .connected && controller.nativePlayer.isPlaying }
    #expect(controller.selectedStream == "sub")
    #expect(controller.webView == nil)
}

@MainActor @Test func nativeWindowNotificationsPauseAndResumeTheHostedInterface() async throws {
    let fixture = try LiveStreamFixture()
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let suite = "NativeWindowTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ContentView(connection: controller, showingSettings: .constant(false)))
    window.makeKeyAndOrderFront(nil)
    defer { controller.setViewVisible(false); window.orderOut(nil) }
    try await awaitNative { controller.window === window && controller.nativePlayer.receivedFrames >= 10 }
    print("Native window: initial playback ready")
    window.miniaturize(nil)
    try await awaitNative { !controller.nativePlayer.isPlaying }
    print("Native window: minimized playback stopped")
    let frames = controller.nativePlayer.receivedFrames
    try await Task.sleep(for: .milliseconds(500))
    #expect(controller.nativePlayer.receivedFrames == frames)
    window.deminiaturize(nil)
    try await awaitNative { controller.nativePlayer.isPlaying }
    print("Native window: restored playback ready")
    controller.hideWindow()
    #expect(!controller.nativePlayer.isPlaying)
    #expect(!window.isVisible)
    window.makeKeyAndOrderFront(nil)
    try await awaitNative { controller.nativePlayer.isPlaying }
    print("Native window: shown playback ready")
    window.close()
    try await awaitNative { !controller.nativePlayer.isPlaying }
    print("Native window: closed playback stopped")
    #expect(controller.webView == nil)
}

@MainActor @Test func threeCameraGridDisplaysAndRecoversEveryVisibleFeed() async throws {
    guard #available(macOS 14.4, *) else { return }
    let fixture = try LiveStreamFixture(closeFirst: true, config: #"{"cameras":{"camera1":{},"camera2":{},"camera3":{}}}"#)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let suite = "NativeGridTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ContentView(connection: controller, showingSettings: .constant(false)))
    window.makeKeyAndOrderFront(nil)
    defer { controller.setViewVisible(false); window.orderOut(nil) }
    try await awaitNative {
        controller.nativeFeeds.count == 3 && controller.nativeFeeds.allSatisfy {
            $0.player.receivedFrames >= 20 && $0.player.isPlaying && $0.player.renderer.layer.isReadyForDisplay
        }
    }
    #expect(fixture.opened == 4)
    #expect(Set(fixture.requestedStreams).count == 3)
    let identities = controller.nativeFeeds.map { ObjectIdentifier($0.player) }
    controller.reconnectCamera("camera2")
    try await awaitNative { fixture.opened == 5 && controller.nativeFeeds.allSatisfy { $0.player.isPlaying } }
    #expect(controller.nativeFeeds.map { ObjectIdentifier($0.player) } == identities)
    controller.hideWindow()
    #expect(controller.nativeFeeds.allSatisfy { !$0.player.isPlaying })
    let counts = controller.nativeFeeds.map { $0.player.receivedFrames }, opened = fixture.opened
    try await Task.sleep(for: .milliseconds(500))
    #expect(controller.nativeFeeds.map { $0.player.receivedFrames } == counts)
    #expect(fixture.opened == opened)
    window.makeKeyAndOrderFront(nil)
    try await awaitNative { controller.nativeFeeds.allSatisfy { $0.player.isPlaying && $0.player.receivedFrames >= 5 } }
    window.miniaturize(nil)
    try await awaitNative { controller.nativeFeeds.allSatisfy { !$0.player.isPlaying } }
    window.deminiaturize(nil)
    try await awaitNative { controller.nativeFeeds.allSatisfy { $0.player.isPlaying } }
    window.close()
    try await awaitNative { controller.nativeFeeds.allSatisfy { !$0.player.isPlaying } }
    #expect(controller.webView == nil)
}

@MainActor @Test func switchingSingleCamerasReplacesTheDisplayedRenderer() async throws {
    let fixture = try LiveStreamFixture(config: #"{"cameras":{"camera1":{},"camera2":{}}}"#)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let suite = "NativeCameraSwitchTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
    let hosting = NSHostingView(rootView: ContentView(connection: controller, showingSettings: .constant(false)))
    window.contentView = hosting
    window.orderFront(nil)
    defer { controller.setViewVisible(false); window.orderOut(nil) }
    try await awaitNative { controller.nativeFeeds.count == 2 }
    func displays(_ renderer: NativeVideoRenderer, in view: NSView) -> Bool {
        if view is NativeVideoNSView, view.layer?.sublayers?.contains(where: { $0 === renderer.layer }) == true { return true }
        return view.subviews.contains { displays(renderer, in: $0) }
    }
    controller.selectCamera("camera1")
    let first = controller.nativePlayer.renderer
    try await awaitNative { controller.nativePlayer.receivedFrames >= 5 && displays(first, in: hosting) }
    controller.selectCamera("camera2")
    let second = controller.nativePlayer.renderer
    try await awaitNative { controller.nativePlayer.receivedFrames >= 5 && displays(second, in: hosting) }
    #expect(!displays(first, in: hosting))
}

@MainActor @Test func scrollingTheGridStopsOffscreenDecodersAndStartsNewTiles() async throws {
    let cameras = Dictionary(uniqueKeysWithValues: (1...9).map { ("camera\($0)", [String: String]()) })
    let config = String(data: try JSONSerialization.data(withJSONObject: ["cameras": cameras]), encoding: .utf8)!
    let fixture = try LiveStreamFixture(config: config)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let suite = "NativeViewportTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let hosting = NSHostingView(rootView: ContentView(connection: controller, showingSettings: .constant(false)))
    window.contentView = hosting
    window.orderFront(nil)
    defer { controller.setViewVisible(false); window.orderOut(nil) }
    try await awaitNative { controller.nativeFeeds.count == 9 && controller.nativeFeeds.first?.player.isPlaying == true }
    print("Grid viewport: initial top tile playing")
    #expect(controller.nativeFeeds.last?.player.isPlaying == false)
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
    let scroll = try #require(scrollView(in: hosting))
    let document = try #require(scroll.documentView)
    print("Grid viewport sizes: document \(document.bounds.size), clip \(scroll.contentView.bounds.size)")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await awaitNative { controller.nativeFeeds.last?.player.isPlaying == true && controller.nativeFeeds.first?.player.isPlaying == false }
    print("Grid viewport: bottom tile playing, top stopped")
    let pausedFrames = controller.nativeFeeds.first!.player.receivedFrames
    try await Task.sleep(for: .milliseconds(500))
    #expect(controller.nativeFeeds.first?.player.receivedFrames == pausedFrames)
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    try await awaitNative { controller.nativeFeeds.first?.player.isPlaying == true && controller.nativeFeeds.last?.player.isPlaying == false }
    print("Grid viewport: top tile restored, bottom stopped")
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["FRIGATE_GRID_BENCHMARK_MP4"] != nil))
func simultaneousNativeGridResourceSample() async throws {
    guard #available(macOS 14.4, *) else { return }
    let environment = ProcessInfo.processInfo.environment
    let count = max(1, min(16, Int(environment["FRIGATE_GRID_BENCHMARK_COUNT"] ?? "3") ?? 3))
    let cameras = Dictionary(uniqueKeysWithValues: (1...count).map { ("camera\($0)", [String: String]()) })
    let config = String(data: try JSONSerialization.data(withJSONObject: ["cameras": cameras]), encoding: .utf8)!
    let fixture = try LiveStreamFixture(videoData: Data(contentsOf: URL(fileURLWithPath: environment["FRIGATE_GRID_BENCHMARK_MP4"]!)), config: config)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let suite = "NativeGridBenchmark.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: ContentView(connection: controller, showingSettings: .constant(false)))
    window.orderFront(nil)
    defer { controller.setViewVisible(false); window.orderOut(nil) }
    try await awaitNative {
        controller.nativeFeeds.count == count && controller.nativeFeeds.allSatisfy { $0.player.receivedFrames >= 30 && $0.player.renderer.layer.isReadyForDisplay }
    }
    let startCPU = cpuSeconds(), start = ProcessInfo.processInfo.systemUptime
    let before = controller.nativeFeeds.map { $0.player.receivedFrames }
    try await Task.sleep(for: .seconds(20))
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let frames = zip(controller.nativeFeeds, before).map { $0.0.player.receivedFrames - $0.1 }
    #expect(frames.allSatisfy { $0 >= 500 })
    #expect(controller.nativeFeeds.allSatisfy { $0.player.isPlaying })
    #expect(fixture.opened == count)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("Native grid sample: \(count) simultaneous 1440p streams; frames per camera \(frames); \(String(format: "%.1f", elapsed)) s; test-process CPU \(String(format: "%.1f", 100 * (cpuSeconds() - startCPU) / elapsed))% of one core; peak RSS \(usage.ru_maxrss / (1024 * 1024)) MiB.")
    controller.setViewVisible(false)
    let stoppedCPU = cpuSeconds(), stopped = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(for: .seconds(5))
    print("Stopped grid sample: test-process CPU \(String(format: "%.1f", 100 * (cpuSeconds() - stoppedCPU) / (ProcessInfo.processInfo.systemUptime - stopped)))% of one core.")
}

@MainActor @Test func aWorkspaceWakeRestartsNativePlaybackWithoutAWindowFocusEvent() async throws {
    let fixture = try LiveStreamFixture()
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let suite = "NativeWakeTests.\(UUID().uuidString)", wakeCenter = NotificationCenter()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent(), wakeNotificationCenter: wakeCenter)
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { controller.setViewVisible(false) }
    try await awaitNative { controller.nativePlayer.isPlaying }
    let opened = fixture.opened
    wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await awaitNative { fixture.opened > opened && controller.nativePlayer.isPlaying }
    #expect(controller.webView == nil)
}

/// Holds a synthetic server open for an external, separately packaged acceptance app.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["FRIGATE_PACKAGE_TEST_PORT_FILE"] != nil && ProcessInfo.processInfo.environment["FRIGATE_BENCHMARK_MP4"] != nil))
func packagedAppSyntheticStreamFixture() async throws {
    let portFile = ProcessInfo.processInfo.environment["FRIGATE_PACKAGE_TEST_PORT_FILE"]!
    let video = ProcessInfo.processInfo.environment["FRIGATE_BENCHMARK_MP4"]!
    let count = max(1, min(16, Int(ProcessInfo.processInfo.environment["FRIGATE_PACKAGE_TEST_CAMERA_COUNT"] ?? "1") ?? 1))
    let cameras = Dictionary(uniqueKeysWithValues: (1...count).map { ("camera\($0)", [String: String]()) })
    let config = String(data: try JSONSerialization.data(withJSONObject: ["cameras": cameras]), encoding: .utf8)!
    let fixture = try LiveStreamFixture(videoData: Data(contentsOf: URL(fileURLWithPath: video)), config: config)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    try String(fixture.port!).write(toFile: portFile, atomically: true, encoding: .utf8)
    let seconds = Double(ProcessInfo.processInfo.environment["FRIGATE_PACKAGE_TEST_SECONDS"] ?? "90") ?? 90
    try await Task.sleep(for: .seconds(seconds))
    #expect(Set(fixture.requestedStreams).count == count)
    print("Packaged acceptance: \(fixture.opened) stream connections.")
}

@Test func repeatedStreamFailuresStopAutomaticRecoveryInsteadOfSpinning() {
    var budget = StreamRetryBudget()
    let now = Date()
    #expect(budget.retry(afterFailureAt: now) == 2)
    #expect(budget.retry(afterFailureAt: now.addingTimeInterval(10)) == 4)
    #expect(budget.retry(afterFailureAt: now.addingTimeInterval(20)) == 8)
    #expect(budget.retry(afterFailureAt: now.addingTimeInterval(30)) == nil)
    #expect(budget.retry(afterFailureAt: now.addingTimeInterval(301)) == nil)
    #expect(budget.retry(afterFailureAt: now.addingTimeInterval(602)) == 2)
    budget.reset()
    #expect(budget.retry(afterFailureAt: now) == 2)
}

@Test func fragmentedVideoPreservesSamplesAndRejectsTruncatedOrOversizedData() throws {
    let (initialize, fragments) = try videoFixture()
    var demuxer = FragmentedVideo()
    #expect(try demuxer.receive(initialize).isEmpty)
    #expect(demuxer.timescale > 0)
    #expect(CMFormatDescriptionGetMediaSubType(try #require(demuxer.format)) == kCMVideoCodecType_H264)
    var count = 0
    var lastTime: Int64 = -1
    for fragment in fragments {
        for packet in try demuxer.receive(fragment) {
            #expect(packet.decodeTime > lastTime)
            #expect(!packet.bytes.isEmpty)
            #expect(CMSampleBufferGetNumSamples(try demuxer.sampleBuffer(packet)) == 1)
            lastTime = packet.decodeTime
            count += 1
        }
    }
    #expect(count == 40)
    #expect(throws: VideoStreamError.self) { try demuxer.receive(Data(initialize.dropLast())) }
    #expect(throws: VideoStreamError.self) { try demuxer.receive(Data(repeating: 0, count: FragmentedVideo.maximumMessageSize + 1)) }
    for length in 0..<min(initialize.count, 512) {
        // Malformed network input must throw or return, never trap.
        var parser = FragmentedVideo()
        _ = try? parser.receive(Data(initialize.prefix(length)))
    }
}

@MainActor @Test func nativeRendererDisplaysHEVCWithoutBrowserOrTranscoding() async throws {
    guard #available(macOS 14.4, *) else { return }
    let (initialize, fragments) = try videoFixture("video-hevc")
    var parser = FragmentedVideo()
    _ = try parser.receive(initialize)
    #expect(CMFormatDescriptionGetMediaSubType(try #require(parser.format)) == kCMVideoCodecType_HEVC)
    let renderer = NativeVideoRenderer()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NativeVideoNSView(renderer: renderer)
    window.orderFront(nil)
    defer { renderer.clear(); window.orderOut(nil) }
    var count = 0
    for fragment in fragments {
        for packet in try parser.receive(fragment) {
            try await renderer.enqueue(parser.sampleBuffer(packet))
            count += 1
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    #expect(count == 20)
    try await awaitNative { renderer.layer.isReadyForDisplay }
    let displayed = try #require(renderer.layer.sampleBufferRenderer.displayedPixelBuffer())
    #expect(CVPixelBufferGetWidth(displayed) == 160)
    #expect(CVPixelBufferGetHeight(displayed) == 90)
}

@MainActor @Test func stoppingNativePlaybackReleasesItsConnectionAndResetsState() {
    let player = NativeLivePlayer(store: WKWebsiteDataStore.nonPersistent().httpCookieStore)
    player.stop()
    #expect(!player.isPlaying)
    #expect(player.receivedFrames == 0)
}

@Test func repeatedMP4DataOffsetsCannotExpandAnInputIntoAnUnboundedSampleQueue() throws {
    func word(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    func box(_ name: String, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + Data(name.utf8) + payload }
    var parser = FragmentedVideo()
    let (initialize, _) = try videoFixture()
    _ = try parser.receive(initialize)
    let payload = Data(repeating: 0, count: 3 * 1024 * 1024)
    let tfhd = box("tfhd", word(0x20038) + word(parser.trackID) + word(1000) + word(UInt32(payload.count)) + word(0))
    let tfdt = box("tfdt", word(0x01000000) + word(0) + word(0))
    func fragment(_ offset: UInt32) -> Data {
        let run = box("trun", word(1) + word(1) + word(offset))
        return box("moof", box("traf", tfhd + tfdt + run + run + run + run))
    }
    let moof = fragment(UInt32(fragment(0).count + 8))
    #expect(throws: VideoStreamError.self) { try parser.receive(moof + box("mdat", payload)) }
}

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
        Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

@MainActor
private func awaitNative(_ condition: () -> Bool, seconds: Double = 15) async throws {
    let end = Date.now.addingTimeInterval(seconds)
    while Date.now < end {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw VideoStreamError.stalled
}

/// Optional live-server acceptance test. Its private input stays outside the repository.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["FRIGATE_PRIVATE_TEST_SESSION"] != nil))
func privateNativeCameraPlaybackAndResume() async throws {
    guard #available(macOS 14.4, *) else { return }
    let path = ProcessInfo.processInfo.environment["FRIGATE_PRIVATE_TEST_SESSION"]!
    let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    let server = try ServerAddress(try #require(settings["base"] as? String))
    let fingerprint = try #require(settings["fingerprint"] as? String)
    let pair = try #require(settings["cookie"] as? String).split(separator: "=", maxSplits: 1).map(String.init)
    let cookie = try #require(HTTPCookie(properties: [.name: pair[0], .value: pair[1],
        .domain: server.url.host!, .path: "/", .secure: "TRUE", .expires: Date.now.addingTimeInterval(3600)]))
    let cameras = try #require(settings["cameras"] as? [[String: Any]])
    let stream = try #require(cameras.first?["streams"] as? [String]).first!
    let store = WKWebsiteDataStore.nonPersistent()
    await store.httpCookieStore.setCookie(cookie)
    let player = NativeLivePlayer(store: store.httpCookieStore)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Native video acceptance test"
    window.contentView = NativeVideoNSView(renderer: player.renderer)
    window.orderFront(nil)
    defer { player.stop(); window.orderOut(nil) }
    player.start(server: server, stream: stream, fingerprint: fingerprint)
    do {
        try await awaitNative({ player.receivedFrames >= 20 }, seconds: 45)
        try await awaitNative { player.renderer.layer.isReadyForDisplay }
    } catch {
        print("Native acceptance failure: frames=\(player.receivedFrames), ready=\(player.renderer.layer.isReadyForDisplay), status=\(player.message), code=\(player.lastFailureCode), HTTP=\(player.lastHandshakeStatus)")
        throw error
    }
    let startCPU = cpuSeconds(), start = ProcessInfo.processInfo.systemUptime
    let framesBefore = player.receivedFrames
    try await Task.sleep(for: .seconds(30))
    let cpu = 100 * (cpuSeconds() - startCPU) / (ProcessInfo.processInfo.systemUptime - start)
    #expect(player.isPlaying)
    #expect(player.receivedFrames > framesBefore)
    print("Native video acceptance: \(player.receivedFrames - framesBefore) frames; test-process CPU \(String(format: "%.1f", cpu))% of one core over 30 seconds.")
    player.stop()
    let stoppedAt = player.receivedFrames
    try await Task.sleep(for: .seconds(2))
    #expect(player.receivedFrames == stoppedAt)
    #expect(!player.isPlaying)
    player.start(server: server, stream: stream, fingerprint: fingerprint)
    try await awaitNative({ player.receivedFrames >= 20 && player.renderer.layer.isReadyForDisplay }, seconds: 45)
    #expect(player.isPlaying)
}

@MainActor @Test func nativePlaybackReconnectsAfterDisconnectAndStopsWhileHidden() async throws {
    guard #available(macOS 14.4, *) else { return }
    let fixture = try LiveStreamFixture(closeFirst: true)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let store = WKWebsiteDataStore.nonPersistent()
    let player = NativeLivePlayer(store: store.httpCookieStore)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NativeVideoNSView(renderer: player.renderer)
    window.orderFront(nil)
    defer { player.stop(); window.orderOut(nil) }
    let server = try ServerAddress("http://127.0.0.1:\(fixture.port!)")
    player.start(server: server, stream: "example", fingerprint: nil)
    try await awaitNative { player.receivedFrames >= 20 && fixture.opened >= 2 }
    #expect(player.renderer.layer.isReadyForDisplay)
    player.stop()
    let frames = player.receivedFrames, opened = fixture.opened
    try await Task.sleep(for: .seconds(2))
    #expect(player.receivedFrames == frames)
    #expect(fixture.opened == opened)
    player.start(server: server, stream: "example", fingerprint: nil)
    try await awaitNative { player.receivedFrames >= 10 && player.renderer.layer.isReadyForDisplay }
}

@MainActor @Test func joiningBetweenKeyframesDoesNotDisconnectAnOtherwiseHealthyStream() async throws {
    guard #available(macOS 14.4, *) else { return }
    let fixture = try LiveStreamFixture(skipInitialKeyframe: true)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let player = NativeLivePlayer(store: WKWebsiteDataStore.nonPersistent().httpCookieStore)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NativeVideoNSView(renderer: player.renderer)
    window.orderFront(nil)
    defer { player.stop(); window.orderOut(nil) }
    player.start(server: try ServerAddress("http://127.0.0.1:\(fixture.port!)"), stream: "example", fingerprint: nil)
    try await awaitNative { player.receivedFrames >= 50 && player.renderer.layer.isReadyForDisplay }
    #expect(player.isPlaying)
    #expect(!player.recoveryPaused)
    #expect(fixture.opened == 1)
}

@MainActor @Test func aStalledNativeStreamStopsAfterItsRecoveryBudgetIsExhausted() async throws {
    let fixture = try LiveStreamFixture(stall: true)
    defer { fixture.stop() }
    try await awaitNative { fixture.port != nil }
    let timing = StreamTiming(startup: 0.5, stalled: 0.25, checkInterval: 0.1, retryScale: 0.01)
    let player = NativeLivePlayer(store: WKWebsiteDataStore.nonPersistent().httpCookieStore, timing: timing)
    defer { player.stop() }
    player.start(server: try ServerAddress("http://127.0.0.1:\(fixture.port!)"), stream: "example", fingerprint: nil)
    try await awaitNative { player.recoveryPaused }
    #expect(fixture.opened == 4)
    #expect(!player.isPlaying)
    #expect(player.receivedFrames == 4)
    let opened = fixture.opened
    try await Task.sleep(for: .milliseconds(500))
    #expect(fixture.opened == opened)
}

@MainActor @Test func nativeControllerResumesWhenShownAndFailsOverToBackup() async throws {
    let primary = try LiveStreamFixture(), backup = try LiveStreamFixture()
    defer { primary.stop(); backup.stop() }
    try await awaitNative { primary.port != nil && backup.port != nil }
    let suite = "NativeControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    controller.setNativeEnabled(true)
    let local = "http://127.0.0.1:\(primary.port!)", fallback = "http://127.0.0.1:\(backup.port!)"
    let backupAddress = try ServerAddress(fallback)
    #expect(controller.connect(primary: local, backup: fallback) == nil)
    defer { controller.setViewVisible(false) }
    try await awaitNative { controller.state == .connected && controller.nativePlayer.receivedFrames >= 10 }
    #expect(controller.nativeEnabled)
    #expect(controller.webView == nil) // No browser view exists during native playback.
    controller.setViewVisible(false)
    let paused = controller.nativePlayer.receivedFrames, opened = primary.opened
    try await Task.sleep(for: .seconds(1))
    #expect(controller.nativePlayer.receivedFrames == paused)
    #expect(primary.opened == opened)
    controller.setViewVisible(true)
    try await awaitNative { controller.nativePlayer.isPlaying && primary.opened > opened }
    primary.setUnavailable()
    try await awaitNative({ controller.activeServer == backupAddress && controller.nativePlayer.receivedFrames >= 10 }, seconds: 25)
    #expect(backup.opened >= 1)
    #expect(controller.state == .connected)
}

}
