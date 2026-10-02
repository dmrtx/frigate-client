import Foundation
import Observation
import WebKit

struct LiveCamera: Identifiable, Equatable {
    let name: String
    let streams: [String]
    var id: String { name }

    static func decode(_ data: Data) throws -> [LiveCamera] {
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cameras = config["cameras"] as? [String: [String: Any]] else { throw VideoStreamError.invalidData }
        return cameras.compactMap { name, camera in
            guard camera["enabled"] as? Bool != false else { return nil }
            let live = camera["live"] as? [String: Any]
            let streams = live?["streams"] as? [String: String]
            let configured = streams?.sorted(by: { $0.key < $1.key }).map(\.value).filter { !$0.isEmpty } ?? []
            return LiveCamera(name: name, streams: configured.isEmpty ? [name] : configured)
        }.sorted { $0.name < $1.name }
    }
}

struct StreamRetryBudget {
    private var failures: [Date] = []
    mutating func retry(afterFailureAt now: Date = .now) -> TimeInterval? {
        failures.removeAll { now.timeIntervalSince($0) >= 300 }
        failures.append(now)
        guard failures.count <= 3 else { return nil }
        return RetryPolicy().delay(after: failures.count - 1)
    }
    mutating func reset() { failures.removeAll() }
}

struct StreamTiming {
    var startup: TimeInterval = 30
    var stalled: TimeInterval = 10
    var checkInterval: TimeInterval = 2
    var retryScale: Double = 1
}

@MainActor @Observable
final class NativeLivePlayer {
    let renderer = NativeVideoRenderer()
    private(set) var message = "Choose a camera."
    private(set) var isPlaying = false
    private(set) var recoveryPaused = false
    private(set) var receivedFrames = 0
    private(set) var lastFailureCode = ""
    private(set) var lastHandshakeStatus = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var lastFrame: TimeInterval?
    @ObservationIgnored private var timedOut = false
    @ObservationIgnored private let timing: StreamTiming
    @ObservationIgnored private var retryBudget = StreamRetryBudget()
    @ObservationIgnored private let cookies: WebSessionCookies
    @ObservationIgnored private var generation = UUID()

    init(store: WKHTTPCookieStore, timing: StreamTiming = StreamTiming()) {
        cookies = WebSessionCookies(store: store)
        self.timing = timing
    }

    nonisolated static func streamURL(server: ServerAddress, stream: String) -> URL {
        var parts = URLComponents(url: server.url.appendingPathComponent("live/mse/api/ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = server.url.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "src", value: stream)]
        return parts.url!
    }

    func start(server: ServerAddress, stream: String, fingerprint: String?) {
        stop()
        retryBudget.reset()
        recoveryPaused = false
        receivedFrames = 0
        lastFailureCode = ""
        lastHandshakeStatus = 0
        let id = generation
        runner = Task { [weak self] in await self?.run(server: server, stream: stream, fingerprint: fingerprint, id: id) }
    }

    func stop() {
        generation = UUID()
        runner?.cancel(); runner = nil
        watchdog?.cancel(); watchdog = nil
        disconnect()
        isPlaying = false
        lastFrame = nil
        renderer.clear()
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }

    private func run(server: ServerAddress, stream: String, fingerprint: String?, id: UUID) async {
        while !Task.isCancelled, id == generation {
            message = "Connecting to camera…"
            isPlaying = false
            do { try await receive(server: server, stream: stream, fingerprint: fingerprint, id: id) }
            catch {
                guard !Task.isCancelled, id == generation else { return }
                let failure = error as NSError
                lastFailureCode = "\(failure.domain):\(failure.code)"
                lastHandshakeStatus = (socket?.response as? HTTPURLResponse)?.statusCode ?? 0
                message = timedOut ? VideoStreamError.stalled.localizedDescription :
                    (error as? VideoStreamError)?.localizedDescription ?? "Could not connect to the camera."
            }
            guard !Task.isCancelled, id == generation else { return }
            watchdog?.cancel(); watchdog = nil
            disconnect()
            renderer.clear()
            isPlaying = false
            guard let delay = retryBudget.retry() else {
                recoveryPaused = true
                message = "Playback paused after repeated failures. Choose Reconnect to try again."
                return
            }
            message += " Retrying in \(Int(delay)) s…"
            do { try await Task.sleep(for: .seconds(delay * timing.retryScale)) } catch { return }
        }
    }

    private func receive(server: ServerAddress, stream: String, fingerprint: String?, id: UUID) async throws {
        let url = Self.streamURL(server: server, stream: stream)
        // Match cookies against the HTTP origin before changing the scheme to WebSocket.
        var cookieURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        cookieURL.scheme = server.url.scheme
        let sent = await cookies.cookies(for: cookieURL.url!)
        guard !Task.isCancelled, id == generation else { return }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        for (name, value) in HTTPCookie.requestHeaderFields(with: sent) { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timing.startup
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration,
            delegate: ProbeTrustDelegate(server: server, fingerprint: fingerprint), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = FragmentedVideo.maximumMessageSize
        self.socket = socket
        var demuxer = FragmentedVideo()
        timedOut = false
        lastFrame = nil
        let started = ProcessInfo.processInfo.systemUptime
        watchdog = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                guard let interval = self?.timing.checkInterval else { return }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.generation == id else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - (self.lastFrame ?? started)
                if elapsed > (self.lastFrame == nil ? self.timing.startup : self.timing.stalled) {
                    self.timedOut = true
                    socket?.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        socket.resume()
        try await socket.send(.string("{\"type\":\"mse\",\"value\":\"avc1.640029,hvc1.1.6.L153.B0\"}"))
        while !Task.isCancelled, id == generation {
            let message = try await socket.receive()
            guard !Task.isCancelled, id == generation else { return }
            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8),
                      let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VideoStreamError.invalidData
                }
                if reply["type"] as? String == "error" {
                    let reason = (reply["value"] as? String)?.lowercased() ?? ""
                    throw reason.contains("codecs") ? VideoStreamError.unsupportedCodec : VideoStreamError.cameraUnavailable
                }
            case .data(let data):
                for packet in try demuxer.receive(data) {
                    try renderer.enqueue(demuxer.sampleBuffer(packet))
                    receivedFrames += 1
                    lastFrame = ProcessInfo.processInfo.systemUptime
                    if !isPlaying { isPlaying = true; self.message = "" }
                }
            @unknown default: throw VideoStreamError.invalidData
            }
        }
    }
}
