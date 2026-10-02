import AVFoundation
import Foundation
import Testing
import WebKit
import AppKit
import Darwin
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
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("Synthetic native sample: \(frames) frames in \(String(format: "%.1f", elapsed)) s; app-process CPU \(String(format: "%.1f", cpu))% of one core; test-process peak RSS \(usage.ru_maxrss / (1024 * 1024)) MiB.")
    player.stop()
    let stoppedFrames = player.receivedFrames, stoppedCPU = cpuSeconds(), stopped = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(for: .seconds(5))
    #expect(player.receivedFrames == stoppedFrames)
    print("Stopped native sample: app-process CPU \(String(format: "%.1f", 100 * (cpuSeconds() - stoppedCPU) / (ProcessInfo.processInfo.systemUptime - stopped)))% of one core.")
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
    #expect(cameras[1].streams == ["fallback"])
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
            try renderer.enqueue(parser.sampleBuffer(packet))
            count += 1
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    #expect(count == 20)
    try await awaitNative { renderer.layer.isReadyForDisplay }
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
    print("Native video acceptance: \(player.receivedFrames - framesBefore) frames; app-process CPU \(String(format: "%.1f", cpu))% of one core over 30 seconds.")
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
    #expect(controller.webView.url == nil) // Dashboard JavaScript is absent during native playback.
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
