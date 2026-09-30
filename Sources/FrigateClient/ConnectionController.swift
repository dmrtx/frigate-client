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
    let webView: WKWebView

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probeSessions = ProbeSessionPool()
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        primary = defaults.string(forKey: "primaryURL") ?? Self.defaultPrimary
        backup = defaults.string(forKey: "backupURL") ?? Self.defaultBackup
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Frigate's floating dashboard fullscreen control is inactive in this embedded view.
        // CSS also applies when React recreates the control during in-page navigation.
        configuration.userContentController.addUserScript(WKUserScript(source: """
            const style = document.createElement("style");
            style.textContent = '.fixed.bottom-12[class~="lg:bottom-9"] .cursor-pointer:has(> svg) { display: none !important; }';
            document.head.appendChild(style);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    @discardableResult
    func connect(primary: String? = nil, backup: String? = nil) -> String? {
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

    var routeName: String {
        activeServer == servers?.backup ? "Tailscale" : "Local"
    }

    func recoverIfNeeded() {
        if state == .reconnecting && certificate == nil { reconnect() }
    }

    func setViewVisible(_ visible: Bool) {
        guard viewIsVisible != visible else { return }
        viewIsVisible = visible
        webView.setAllMediaPlaybackSuspended(!visible) { [weak self] in
            guard visible, let self, self.viewIsVisible else { return }
            self.recoverIfNeeded()
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
        var message = "Frigate is unavailable."
        for server in servers.candidates where !rejectedServers.contains(server.origin) {
            let result = await probe(server)
            guard !Task.isCancelled, id == runID else { return }
            switch result {
            case .available, .needsTrust:
                activeServer = server
                state = .connecting
                detail = server == servers.primary ? "Connecting over the local network…" : "Connecting over Tailscale…"
                nextRetry = nil
                loadStarted = Date()
                let page = lastPages[server.origin] ?? server.url
                navigation = webView.load(URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData,
                                                     timeoutInterval: 12))
                return
            case .unavailable(let error): message = error
            }
        }
        markOffline(message)
        failures += 1
    }

    private enum ProbeResult { case available, needsTrust, unavailable(String) }

    private func probe(_ server: ServerAddress) async -> ProbeResult {
        let session = probeSessions.session(for: server, fingerprint: trustedFingerprint(for: server))
        do {
            let (_, response) = try await session.data(for: URLRequest(url: server.healthURL,
                                                                      cachePolicy: .reloadIgnoringLocalCacheData))
            guard let http = response as? HTTPURLResponse else {
                return .unavailable("The server returned an invalid response.")
            }
            return RetryPolicy.isReachable(status: http.statusCode)
                ? .available : .unavailable("Frigate returned error \(http.statusCode).")
        } catch {
            let code = (error as NSError).code
            let trustErrors = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                               NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid]
            if (error as NSError).domain == NSURLErrorDomain && trustErrors.contains(code) { return .needsTrust }
            return .unavailable("Could not connect to Frigate.")
        }
    }

    private func markOffline(_ message: String) {
        rememberCurrentPage()
        state = .reconnecting
        detail = message
        loadStarted = nil
    }

    private func rememberCurrentPage() {
        if let server = activeServer, let url = webView.url, server.contains(url) {
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
        guard activeServer != nil else { return }
        // Internal Frigate navigation has its own navigation object.
        self.navigation = navigation
        loadStarted = Date()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, let server = activeServer else { return }
        if let url = webView.url, server.contains(url) { lastPages[server.origin] = url }
        state = .connected
        detail = ""
        failures = 0
        nextRetry = nil
        loadStarted = nil
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
