import AppKit
import Foundation
import Observation
import WebKit

enum ConnectionState: Equatable {
    case idle, connecting, connected, reconnecting
}

struct CertificateRequest: Identifiable {
    let id = UUID()
    let server: ServerAddress
    let fingerprint: String
}

@MainActor @Observable
final class ConnectionController: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let defaultPrimary = ""
    static let defaultBackup = ""
    var primary: String
    var backup: String
    private(set) var state: ConnectionState = .idle
    private(set) var activeServer: ServerAddress?
    private(set) var detail = "Add your Frigate server address to get started."
    private(set) var nextRetry: Date?
    private(set) var certificate: CertificateRequest?
    private(set) var requiresSignIn = false
    private(set) var pageRecoveryPaused = false
    private(set) var nativeEnabled: Bool
    private(set) var cameras: [LiveCamera] = []
    private(set) var selectedCamera = ""
    let nativePlayer: NativeLivePlayer
    @ObservationIgnored weak var window: NSWindow?
    private(set) var webView: WKWebView

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probeSessions = ProbeSessionPool()
    @ObservationIgnored private let healthProbe: HealthProbe
    @ObservationIgnored private let websiteDataStore: WKWebsiteDataStore
    @ObservationIgnored private var mediaPlayback: MediaPlayback
    @ObservationIgnored private var pageMonitor: Task<Void, Never>?
    @ObservationIgnored private var pageRecoveryBudget = StreamRetryBudget()
    @ObservationIgnored private lazy var pageWatchdog = PageWatchdog(probe: { [weak self] reply in
        self?.webView.evaluateJavaScript("1", in: nil, in: .defaultClient) { result in
            if case .success(let value) = result { reply((value as? Int) == 1) }
            else { reply(false) }
        }
    }, recover: { [weak self] in self?.restoreUnresponsivePage() })
    @ObservationIgnored private var servers: Servers?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastPages: [String: URL] = [:]
    @ObservationIgnored private var rejectedServers: Set<String> = []
    @ObservationIgnored private var finishTrust: ((Bool) -> Void)?
    @ObservationIgnored private var loadStarted: Date?
    @ObservationIgnored private var viewIsVisible = true
    @ObservationIgnored private var hiddenSince: Date?
    @ObservationIgnored private var pageLoadedWhileHidden = false

    init(defaults: UserDefaults = .standard, websiteDataStore: WKWebsiteDataStore = .default()) {
        self.defaults = defaults
        self.websiteDataStore = websiteDataStore
        nativeEnabled = defaults.object(forKey: "nativeLiveEnabled") as? Bool ?? false
        nativePlayer = NativeLivePlayer(store: websiteDataStore.httpCookieStore)
        primary = defaults.string(forKey: "primaryURL") ?? Self.defaultPrimary
        backup = defaults.string(forKey: "backupURL") ?? Self.defaultBackup
        let view = Self.makeWebView(dataStore: websiteDataStore)
        webView = view
        mediaPlayback = MediaPlayback { suspended, completion in
            view.setAllMediaPlaybackSuspended(suspended, completionHandler: completion)
        }
        healthProbe = HealthProbe(cookies: WebSessionCookies(store: view.configuration.websiteDataStore.httpCookieStore))
        super.init()
        configureWebView()
        pageMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.checkPageResponsiveness()
            }
        }
    }

    private static func makeWebView(dataStore: WKWebsiteDataStore) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Frigate's floating dashboard fullscreen control is inactive in this embedded view.
        // CSS also applies when React recreates the control during in-page navigation.
        configuration.userContentController.addUserScript(WKUserScript(source: """
            const style = document.createElement("style");
            style.textContent = '.fixed.bottom-12[class~="lg:bottom-9"] .cursor-pointer:has(> svg) { display: none !important; }';
            document.head.appendChild(style);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func configureWebView() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    @discardableResult
    func connect(primary: String? = nil, backup: String? = nil, resetPageRecovery: Bool = true) -> String? {
        let settings: Servers
        do {
            settings = try Servers(primary: primary ?? self.primary, backup: backup ?? self.backup)
        } catch { return error.localizedDescription }
        self.primary = settings.primary.url.absoluteString
        self.backup = settings.backup?.url.absoluteString ?? ""
        rememberCurrentPage()
        defaults.set(self.primary, forKey: "primaryURL")
        defaults.set(self.backup, forKey: "backupURL")
        servers = settings
        if resetPageRecovery { pageRecoveryBudget.reset() }
        pageRecoveryPaused = false
        nativePlayer.stop()
        pageWatchdog.reset()
        probeSessions.retainServers(settings.candidates)
        monitor?.cancel()
        runID = UUID()
        resolveCertificate(accept: false)
        rejectedServers.removeAll()
        webView.stopLoading()
        navigation = nil
        activeServer = nil
        state = .connecting
        detail = "Looking for Frigate…"
        nextRetry = nil
        failures = 0
        loadStarted = nil
        let id = runID
        monitor = Task { [weak self] in await self?.watchConnection(id: id) }
        return nil
    }

    func reconnect() { _ = connect() }

    func setNativeEnabled(_ enabled: Bool) {
        guard nativeEnabled != enabled else { return }
        nativeEnabled = enabled
        defaults.set(enabled, forKey: "nativeLiveEnabled")
        replaceWebView()
        if state != .idle { reconnect() }
    }

    func selectCamera(_ name: String) {
        guard cameras.contains(where: { $0.name == name }) else { return }
        selectedCamera = name
        defaults.set(name, forKey: "nativeCamera")
        startNativePlayback()
    }

    private func startNativePlayback() {
        guard nativeEnabled, !requiresSignIn, viewIsVisible, let activeServer,
              let camera = cameras.first(where: { $0.name == selectedCamera }), let stream = camera.streams.first else { return }
        nativePlayer.start(server: activeServer, stream: stream, fingerprint: trustedFingerprint(for: activeServer))
    }

    func hideWindow() {
        guard let window else { return }
        setViewVisible(false)
        window.orderOut(nil)
    }

    var routeName: String {
        activeServer == servers?.backup ? "Tailscale" : "Local"
    }

    var statusText: String {
        switch state {
        case .connected:
            if pageRecoveryPaused { return "Page recovery paused" }
            if requiresSignIn { return "Sign in required · \(routeName)" }
            if nativeEnabled { return nativePlayer.isPlaying ? "Live · \(routeName)" : nativePlayer.message }
            return "Connected · \(routeName)"
        case .reconnecting: return "Reconnecting"
        case .idle: return "Not configured"
        case .connecting: return "Connecting"
        }
    }

    var indicatorState: ConnectionState {
        pageRecoveryPaused || (state == .connected && nativeEnabled && !requiresSignIn && !nativePlayer.isPlaying) ? .reconnecting : state
    }

    func recoverIfNeeded() {
        if state == .reconnecting && certificate == nil { reconnect() }
    }

    func checkPageResponsiveness() {
        guard !pageRecoveryPaused, (!nativeEnabled || requiresSignIn), viewIsVisible, state == .connected, certificate == nil, !webView.isLoading else {
            pageWatchdog.reset()
            return
        }
        pageWatchdog.check()
    }

    /// Reloading alone can keep using the process that stopped answering.
    func restoreUnresponsivePage() {
        guard !pageRecoveryPaused, viewIsVisible, state == .connected, certificate == nil else { return }
        rememberCurrentPage()
        pageWatchdog.reset()
        replaceWebView()
        guard pageRecoveryBudget.retry() != nil else {
            pageRecoveryPaused = true
            detail = "Page recovery paused after repeated stalls. Choose Reconnect to try again."
            return
        }
        _ = connect(resetPageRecovery: false)
    }

    private func replaceWebView() {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView = Self.makeWebView(dataStore: websiteDataStore)
        let view = webView
        mediaPlayback = MediaPlayback { suspended, completion in
            view.setAllMediaPlaybackSuspended(suspended, completionHandler: completion)
        }
        configureWebView()
    }

    func setViewVisible(_ visible: Bool) {
        guard viewIsVisible != visible else { return }
        viewIsVisible = visible
        pageWatchdog.reset()
        if nativeEnabled && !requiresSignIn {
            if visible { startNativePlayback(); recoverIfNeeded() }
            else { nativePlayer.stop() }
            hiddenSince = visible ? nil : .now
            return
        }
        let reload = visible && ViewRecoveryPolicy.needsReload(
            hiddenSince: hiddenSince, pageLoadedWhileHidden: pageLoadedWhileHidden)
        hiddenSince = visible ? nil : .now
        mediaPlayback.update(isVisible: visible) { [weak self] in
            guard visible, let self, self.viewIsVisible else { return }
            if reload && self.state != .idle && self.certificate == nil { self.reconnect() }
            else { self.recoverIfNeeded() }
        }
    }

    private func watchConnection(id: UUID) async {
        await attemptConnection(id: id)
        while !Task.isCancelled && id == runID {
            let delay: TimeInterval
            if certificate != nil { delay = 1 }
            else { switch state {
            case .connected: delay = viewIsVisible ? 10 : 30
            case .reconnecting:
                delay = RetryPolicy().delay(after: failures - 1)
                nextRetry = Date().addingTimeInterval(delay)
            case .connecting, .idle: delay = 1
            } }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, id == runID else { return }
            guard certificate == nil else { continue }
            switch state {
            case .connected:
                guard let activeServer else { continue }
                let result = await probe(activeServer)
                guard !Task.isCancelled, id == runID else { return }
                if case .unavailable(let message) = result { markOffline(message) }
                else if case .needsTrust = result { markOffline("The server certificate changed.") }
                else if case .available(let authenticated) = result {
                    if !authenticated && !requiresSignIn {
                        // An expired session can leave React displaying stale camera content.
                        // Try another signed-in address, or show Frigate's login page once.
                        reconnect()
                    } else if authenticated && requiresSignIn {
                        requiresSignIn = false
                        if nativeEnabled { reconnect() }
                        else if let url = webView.url, !activeServer.isRestorablePage(url) { reconnect() }
                    }
                }
            case .reconnecting:
                nextRetry = nil
                await attemptConnection(id: id)
            case .connecting:
                if certificate == nil, let loadStarted, Date().timeIntervalSince(loadStarted) > 20 {
                    webView.stopLoading()
                    navigation = nil
                    markOffline("Frigate took too long to respond.")
                }
            case .idle: break
            }
        }
    }

    private func attemptConnection(id: UUID) async {
        guard let servers else { return }
        let selection = await healthProbe.selectServer(
            from: servers.candidates.filter { !rejectedServers.contains($0.origin) },
            session: { probeSessions.session(for: $0, fingerprint: trustedFingerprint(for: $0)) })
        guard !Task.isCancelled, id == runID else { return }
        guard let server = selection.server else {
            if case .unavailable(let message) = selection.result { markOffline(message) }
            failures += 1
            return
        }
        activeServer = server
        requiresSignIn = selection.result == .available(authenticated: false) || selection.result == .needsTrust
        state = .connecting
        detail = server == servers.primary ? "Connecting over the local network…" : "Connecting over Tailscale…"
        nextRetry = nil
        loadStarted = Date()
        if nativeEnabled && !requiresSignIn {
            do {
                let cookieBridge = WebSessionCookies(store: websiteDataStore.httpCookieStore)
                let url = server.url.appendingPathComponent("api/config")
                let sent = await cookieBridge.cookies(for: url)
                guard !Task.isCancelled, id == runID else { return }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.httpShouldHandleCookies = false
                for (name, value) in HTTPCookie.requestHeaderFields(with: sent) { request.setValue(value, forHTTPHeaderField: name) }
                let session = probeSessions.session(for: server, fingerprint: trustedFingerprint(for: server))
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled, id == runID else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw VideoStreamError.invalidData
                }
                cameras = try LiveCamera.decode(data)
                let saved = defaults.string(forKey: "nativeCamera") ?? selectedCamera
                selectedCamera = cameras.first(where: { $0.name == saved })?.name ?? cameras.first?.name ?? ""
                replaceWebView() // Release the login/dashboard page; retain its cookie store only.
                state = .connected
                loadStarted = nil
                detail = ""
                failures = 0
                startNativePlayback()
                return
            } catch {
                guard !Task.isCancelled, id == runID else { return }
                markOffline("Could not load the camera list. Retrying automatically.")
                failures += 1
                return
            }
        }
        let page = lastPages[server.origin].flatMap { server.isRestorablePage($0) ? $0 : nil } ?? server.url
        navigation = webView.load(URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 12))
    }

    private func probe(_ server: ServerAddress) async -> HealthProbe.Result {
        let session = probeSessions.session(for: server, fingerprint: trustedFingerprint(for: server))
        return await healthProbe.check(server, session: session)
    }

    private func markOffline(_ message: String) {
        rememberCurrentPage()
        state = .reconnecting
        nativePlayer.stop()
        detail = message
        loadStarted = nil
    }

    private func rememberCurrentPage() {
        if let server = activeServer, let url = webView.url, server.isRestorablePage(url) {
            lastPages[server.origin] = url
        }
    }

    private func trustedFingerprint(for server: ServerAddress) -> String? {
        (defaults.dictionary(forKey: "trustedCertificates") as? [String: String])?[server.origin]
    }

    func resolveCertificate(accept: Bool) {
        guard let request = certificate else { return }
        if accept {
            var trusted = defaults.dictionary(forKey: "trustedCertificates") as? [String: String] ?? [:]
            trusted[request.server.origin] = request.fingerprint
            defaults.set(trusted, forKey: "trustedCertificates")
        } else { rejectedServers.insert(request.server.origin) }
        let completion = finishTrust
        certificate = nil
        finishTrust = nil
        completion?(accept)
        // Time spent reviewing a certificate is not a navigation timeout.
        loadStarted = Date()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, activeServer != nil else { return }
        pageWatchdog.reset()
        // Internal Frigate navigation has its own navigation object.
        self.navigation = navigation
        pageLoadedWhileHidden = !viewIsVisible
        loadStarted = Date()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, let server = activeServer else { return }
        if let url = webView.url, server.isRestorablePage(url) { lastPages[server.origin] = url }
        mediaPlayback.update(isVisible: viewIsVisible)
        state = .connected
        detail = ""
        failures = 0
        nextRetry = nil
        loadStarted = nil
        if viewIsVisible && pageLoadedWhileHidden {
            // Autoplay attempted while WebKit was suspended may never restart on resume.
            // Create the player while visible instead of leaving that page frozen.
            pageLoadedWhileHidden = false
            reconnect()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard navigation === self.navigation,
              (error as NSError).code != NSURLErrorCancelled else { return }
        markOffline("Could not load Frigate. Retrying automatically.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        pageWatchdog.reset()
        markOffline("Restoring the Frigate view…")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false, let url = action.request.url,
              ["http", "https"].contains(url.scheme) else {
            decisionHandler(.allow)
            return
        }
        if activeServer?.contains(url) == true { decisionHandler(.allow) }
        else {
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
           http.statusCode >= 500 {
            markOffline("Frigate returned error \(http.statusCode).")
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let server = activeServer else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        guard space.host.lowercased() == server.url.host?.lowercased(),
              space.port == (server.url.port ?? 443) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if ServerTrust.accepts(trust, fingerprint: trustedFingerprint(for: server)) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else if let fingerprint = ServerTrust.fingerprint(trust), !rejectedServers.contains(server.origin) {
            resolveCertificate(accept: false)
            certificate = CertificateRequest(server: server, fingerprint: fingerprint)
            finishTrust = { accept in
                completionHandler(accept ? .useCredential : .cancelAuthenticationChallenge,
                                  accept ? URLCredential(trust: trust) : nil)
            }
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
