import AppKit
import Foundation
import Network
import WebKit

private final class LoopbackServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "PackageHTTPProbe")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard data != nil else { connection.cancel(); return }
                let body = "<html><body>package-fixture</body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }
}

@MainActor private final class PageLoader: NSObject, WKNavigationDelegate {
    var completion: CheckedContinuation<Void, Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume(); completion = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }
    func load(_ url: URL, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { completion in
            self.completion = completion
            view.load(URLRequest(url: url))
        }
    }
}

@main struct PackageNetworkProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let deadline = Task { try await Task.sleep(for: .seconds(30)); print("FAIL: package network probe timed out"); exit(1) }
        do {
            let fixture = try LoopbackServer()
            defer { fixture.listener.cancel(); deadline.cancel() }
            while (fixture.listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
            let port = fixture.listener.port!.rawValue
            let store = WKWebsiteDataStore.nonPersistent()
            let probe = HealthProbe(cookies: WebSessionCookies(store: store.httpCookieStore))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            let view = WKWebView(frame: .zero, configuration: configuration)
            let loader = PageLoader()
            view.navigationDelegate = loader
            // localtest.me is a public DNS name resolving to loopback, never a remote HTTP server.
            for host in ["localtest.me", "localhost", "127.0.0.1"] {
                let server = try ServerAddress("http://\(host):\(port)")
                guard await probe.check(server, session: session) == .available(authenticated: true) else {
                    throw NSError(domain: "PackageNetworkProbe", code: 1)
                }
                try await loader.load(server.url, in: view)
                let body = try await view.evaluateJavaScript("document.body.textContent")
                guard body as? String == "package-fixture" else { throw NSError(domain: "PackageNetworkProbe", code: 2) }
                print("PASS: native HealthProbe and WebKit over HTTP (\(host))")
            }
        } catch { print("FAIL: package network probe (\((error as NSError).domain), \((error as NSError).code))"); exit(1) }
    }
}
