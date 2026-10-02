import AppKit
import Foundation
import Observation
import WebKit
import Combine

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
    private(set) var downloadNotice: DownloadNotice?
    func dismissDownloadNotice() { downloadNotice = nil }
    @ObservationIgnored private(set) weak var window: NSWindow?
    @ObservationIgnored private var windowVisibility: NSKeyValueObservation?
    @ObservationIgnored private var appVisibility: AnyCancellable?
    @ObservationIgnored private var wakeEvents: AnyCancellable?
    private(set) var webView: WKWebView?

    @ObservationIgnored private let downloadDestination: DashboardDownloads.DestinationChooser?
    @ObservationIgnored private lazy var downloads = DashboardDownloads(
        window: { [weak self] in self?.window }, chooseDestination: downloadDestination,
        notify: { [weak self] in self?.downloadNotice = $0 })
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probeSessions = ProbeSessionPool()
    @ObservationIgnored private let healthProbe: HealthProbe
    @ObservationIgnored private let websiteDataStore: WKWebsiteDataStore
    @ObservationIgnored private var mediaPlayback: MediaPlayback?
    @ObservationIgnored private var pageMonitor: Task<Void, Never>?
    @ObservationIgnored private var pageRecoveryBudget = PageRecoveryBudget()
    @ObservationIgnored private lazy var pageWatchdog = PageWatchdog(probe: { [weak self] reply in
        self?.webView?.evaluateJavaScript("1", in: nil, in: .defaultClient) { result in
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
    @ObservationIgnored private var pageFailures = PageFailurePolicy()
    @ObservationIgnored private var finishTrust: ((Bool) -> Void)?
    @ObservationIgnored private let navigationDeadline: NavigationDeadline
    @ObservationIgnored private var viewIsVisible = true
    @ObservationIgnored private var hiddenSince: Date?
    @ObservationIgnored private var pageLoadedWhileHidden = false

    init(defaults: UserDefaults = .standard, websiteDataStore: WKWebsiteDataStore = .default(),
         wakeNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         navigationTimeout: Duration = .seconds(20),
         downloadDestination: DashboardDownloads.DestinationChooser? = nil) {
        self.downloadDestination = downloadDestination
        navigationDeadline = NavigationDeadline(timeout: navigationTimeout)
        self.defaults = defaults
        self.websiteDataStore = websiteDataStore
        primary = defaults.string(forKey: "primaryURL") ?? Self.defaultPrimary
        backup = defaults.string(forKey: "backupURL") ?? Self.defaultBackup
        healthProbe = HealthProbe(cookies: WebSessionCookies(store: websiteDataStore.httpCookieStore))
        super.init()
        appVisibility = Publishers.Merge(
            NotificationCenter.default.publisher(for: NSApplication.didHideNotification),
            NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)
        ).receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowVisibility() }
        }
        wakeEvents = wakeNotificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state != .idle else { return }
                    self.reconnect()
                }
            }
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

    private func makeBrowser() -> WKWebView {
        let view = Self.makeWebView(dataStore: websiteDataStore)
        webView = view
        mediaPlayback = MediaPlayback { suspended, completion in
            view.setAllMediaPlaybackSuspended(suspended, completionHandler: completion)
        }
        // Suspend before load can create autoplaying media, including reconnections while hidden.
        mediaPlayback?.update(isVisible: viewIsVisible)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        #if DEBUG
        view.isInspectable = true
        #endif
        return view
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
        if servers != settings { pageFailures = PageFailurePolicy() }
        servers = settings
        if resetPageRecovery { pageRecoveryBudget.reset() }
        pageRecoveryPaused = false
        pageWatchdog.reset()
        probeSessions.retainServers(settings.candidates)
        monitor?.cancel()
        runID = UUID()
        resolveCertificate(accept: false)
        rejectedServers.removeAll()
        webView?.stopLoading()
        navigation = nil
        activeServer = nil
        state = .connecting
        detail = "Looking for Frigate…"
        nextRetry = nil
        failures = 0
        navigationDeadline.cancel()
        let id = runID
        monitor = Task { [weak self] in await self?.watchConnection(id: id) }
        return nil
    }

    func reconnect() { _ = connect() }

    func hideWindow() {
        guard let window else { return }
        setViewVisible(false)
        window.orderOut(nil)
    }

    func attachWindow(_ newWindow: NSWindow?) {
        guard window !== newWindow else { return }
        windowVisibility?.invalidate()
        window = newWindow
        windowVisibility = newWindow?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshWindowVisibility() }
        }
        refreshWindowVisibility()
    }

    func refreshWindowVisibility() {
        guard let window else { setViewVisible(false); return }
        setViewVisible(WindowPlaybackVisibility.isVisible(
            windowIsVisible: window.isVisible, isMiniaturized: window.isMiniaturized, appIsHidden: NSApp.isHidden))
    }

    var routeName: String {
        activeServer == servers?.backup ? "Tailscale" : "Local"
    }

    var statusText: String {
        switch state {
        case .connected:
            if pageRecoveryPaused { return "Page recovery paused" }
            if requiresSignIn { return "Sign in required · \(routeName)" }
            return "Connected · \(routeName)"
        case .reconnecting: return "Reconnecting"
        case .idle: return "Not configured"
        case .connecting: return "Connecting"
        }
    }

    var indicatorState: ConnectionState {
        pageRecoveryPaused ? .reconnecting : state
    }

    func recoverIfNeeded() {
        if state == .reconnecting && certificate == nil { reconnect() }
    }

    func checkPageResponsiveness() {
        guard !pageRecoveryPaused, viewIsVisible, state == .connected, certificate == nil,
              let webView, !webView.isLoading else {
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
        releaseBrowser()
        guard pageRecoveryBudget.retry() != nil else {
            pageRecoveryPaused = true
            detail = "Page recovery paused after repeated stalls. Choose Reconnect to try again."
            return
        }
        _ = connect(resetPageRecovery: false)
    }

    private func releaseBrowser() {
        navigationDeadline.cancel()
        navigation = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
        mediaPlayback = nil
    }

    func setViewVisible(_ visible: Bool) {
        guard viewIsVisible != visible else { return }
        viewIsVisible = visible
        pageWatchdog.reset()
        let reload = visible && ViewRecoveryPolicy.needsReload(
            hiddenSince: hiddenSince, pageLoadedWhileHidden: pageLoadedWhileHidden)
        hiddenSince = visible ? nil : .now
        guard let mediaPlayback else {
            if visible { recoverIfNeeded() }
            return
        }
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
                        if let url = webView?.url, !activeServer.isRestorablePage(url) { reconnect() }
                    }
                }
            case .reconnecting:
                nextRetry = nil
                await attemptConnection(id: id)
            case .connecting: break
            case .idle: break
            }
        }
    }

    private func attemptConnection(id: UUID) async {
        guard let servers else { return }
        let selection = await healthProbe.selectServer(
            from: pageFailures.candidates(from: servers.candidates.filter { !rejectedServers.contains($0.origin) }),
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
        let page = lastPages[server.origin].flatMap { server.isRestorablePage($0) ? $0 : nil } ?? server.url
        let view = webView ?? makeBrowser()
        navigation = view.load(URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 12))
        startNavigationDeadline()
    }

    private func startNavigationDeadline() {
        guard certificate == nil, let view = webView, let navigation else { return }
        navigationDeadline.start { [weak self, weak view] in
            guard let self, let view, view === self.webView,
                  navigation === self.navigation, self.certificate == nil else { return }
            self.markOffline("Frigate took too long to respond.", pageFailed: true)
        }
    }

    private func probe(_ server: ServerAddress) async -> HealthProbe.Result {
        let session = probeSessions.session(for: server, fingerprint: trustedFingerprint(for: server))
        return await healthProbe.check(server, session: session)
    }

    private func markOffline(_ message: String, pageFailed: Bool = false) {
        if pageFailed, let activeServer { pageFailures.failed(activeServer) }
        rememberCurrentPage()
        state = .reconnecting
        releaseBrowser()
        detail = message
        navigationDeadline.cancel()
    }

    private func rememberCurrentPage() {
        if let server = activeServer, let url = webView?.url, server.isRestorablePage(url) {
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
        // Give navigation a fresh deadline after the user finishes reviewing trust.
        startNavigationDeadline()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, activeServer != nil else { return }
        pageWatchdog.reset()
        // Internal Frigate navigation has its own navigation object.
        self.navigation = navigation
        pageLoadedWhileHidden = !viewIsVisible
        state = .connecting
        detail = "Loading Frigate…"
        startNavigationDeadline()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === self.navigation, let server = activeServer else { return }
        if let url = webView.url, server.isRestorablePage(url) { lastPages[server.origin] = url }
        mediaPlayback?.update(isVisible: viewIsVisible)
        pageFailures.succeeded(server)
        state = .connected
        detail = ""
        failures = 0
        nextRetry = nil
        navigationDeadline.cancel()
        if viewIsVisible && pageLoadedWhileHidden {
            // Autoplay attempted while WebKit was suspended may never restart on resume.
            // Create the player while visible instead of leaving that page frozen.
            pageLoadedWhileHidden = false
            reconnect()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard navigation === self.navigation,
              (error as NSError).code != NSURLErrorCancelled else { return }
        markOffline("Could not load Frigate. Retrying automatically.", pageFailed: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        pageWatchdog.reset()
        markOffline("Restoring the Frigate view…")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload {
            let allowed = action.request.url.flatMap { url in activeServer.map { DownloadPolicy.allows(url, server: $0) } } ?? false
            decisionHandler(allowed ? .download : .cancel)
            return
        }
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
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if !DownloadPolicy.isAttachment(response.response), response.isForMainFrame,
           let http = response.response as? HTTPURLResponse,
           http.statusCode >= 500 {
            markOffline("Frigate returned error \(http.statusCode).", pageFailed: true)
            decisionHandler(.cancel)
        } else if !response.canShowMIMEType || DownloadPolicy.isAttachment(response.response) {
            let allowed = response.response.url.flatMap { url in activeServer.map { DownloadPolicy.allows(url, server: $0) } } ?? false
            decisionHandler(allowed ? .download : .cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        // Action conversion precedes provisional navigation, so it cannot finish a pending page load.
        beginDownload(download, in: webView, completesNavigation: false)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        beginDownload(download, in: webView, completesNavigation: navigationResponse.isForMainFrame)
    }

    private func beginDownload(_ download: WKDownload, in view: WKWebView, completesNavigation: Bool) {
        guard view === webView, let activeServer else { download.cancel { _ in }; return }
        if completesNavigation {
            navigationDeadline.cancel()
            navigation = nil
            state = .connected
            detail = ""
        }
        downloads.start(download, server: activeServer, fingerprint: trustedFingerprint(for: activeServer))
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
            navigationDeadline.cancel()
            certificate = CertificateRequest(server: server, fingerprint: fingerprint)
            finishTrust = { accept in
                completionHandler(accept ? .useCredential : .cancelAuthenticationChallenge,
                                  accept ? URLCredential(trust: trust) : nil)
            }
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
