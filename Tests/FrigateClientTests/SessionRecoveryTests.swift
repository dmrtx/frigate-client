import Foundation
import Testing
import WebKit
@testable import FrigateClient

private func cookie(_ value: String = "old", domain: String = "refresh.example", path: String = "/",
                    secure: Bool = true, expires: Date = .now.addingTimeInterval(3600)) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
        .name: "test-session", .value: value, .domain: domain, .path: path, .expires: expires
    ]
    if secure { properties[.secure] = "TRUE" }
    return HTTPCookie(properties: properties)!
}

@Test func cookiesStayWithinTheirHostPathTransportAndLifetime() {
    let url = URL(string: "https://refresh.example/api/version")!
    #expect(CookiePolicy.matches(cookie(), url: url))
    #expect(!CookiePolicy.matches(cookie(domain: "other.example"), url: url))
    #expect(!CookiePolicy.matches(cookie(domain: "fresh.example"), url: url))
    #expect(!CookiePolicy.matches(cookie(), url: URL(string: "http://refresh.example/api/version")!))
    #expect(!CookiePolicy.matches(cookie(expires: .now.addingTimeInterval(-1)), url: url))
    #expect(CookiePolicy.matches(cookie(domain: ".example"), url: url))
    #expect(!CookiePolicy.matches(cookie(domain: ".example"), url: URL(string: "https://notexample/")!))
    #expect(CookiePolicy.matches(cookie(path: "/api"), url: url))
    #expect(!CookiePolicy.matches(cookie(path: "/ap"), url: url))
    #expect(!CookiePolicy.matches(cookie(path: "/login"), url: url))
}

@Test func cookieRefreshDoesNotUndoLogoutOrOverwriteANewerLogin() {
    let old = cookie()
    let renewed = cookie("renewed")
    #expect(CookiePolicy.canApply(renewed, sent: [old], current: [old]))
    #expect(!CookiePolicy.canApply(renewed, sent: [old], current: []))
    #expect(!CookiePolicy.canApply(renewed, sent: [old], current: [cookie("new-login")]))
    #expect(!CookiePolicy.canApply(cookie(domain: ".example"), sent: [old], current: [old]))
    #expect(!CookiePolicy.canApply(cookie(path: "/api"), sent: [old], current: [old]))
}

@Test func loginAndLogoutPagesAreNeverRestored() throws {
    let root = try ServerAddress("https://refresh.example")
    for path in ["/", "/review", "/recordings?camera=example"] {
        #expect(root.isRestorablePage(URL(string: "https://refresh.example\(path)")!))
    }
    for path in ["/login", "/login/", "/logout", "/api/login", "/api/logout", "/api/version"] {
        #expect(!root.isRestorablePage(URL(string: "https://refresh.example\(path)")!))
    }
    #expect(!root.isRestorablePage(URL(string: "https://other.example/review")!))
    let subpath = try ServerAddress("https://refresh.example/frigate/")
    #expect(subpath.isRestorablePage(subpath.url))
    #expect(subpath.isRestorablePage(URL(string: "https://refresh.example/frigate/review")!))
    #expect(!subpath.isRestorablePage(URL(string: "https://refresh.example/frigate/login")!))
    #expect(!subpath.isRestorablePage(URL(string: "https://refresh.example/frigate-other/review")!))
    #expect(!subpath.isRestorablePage(URL(string: "https://refresh.example/review")!))
}

@Test func reopeningAfterALongPauseReloadsEvenAReachablePage() {
    let now = Date()
    #expect(!ViewRecoveryPolicy.needsReload(hiddenSince: nil, now: now))
    #expect(!ViewRecoveryPolicy.needsReload(hiddenSince: now.addingTimeInterval(-10), now: now))
    #expect(ViewRecoveryPolicy.needsReload(hiddenSince: now.addingTimeInterval(-60), now: now))
    #expect(ViewRecoveryPolicy.needsReload(hiddenSince: now.addingTimeInterval(-86400), now: now))
}

/// Responses depend only on the request, so parallel tests need no shared mutable handlers.
private final class FrigateProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var status = 200
        var headers = ["Content-Type": "text/plain"]
        switch url.host {
        case "primary.example": status = 401
        case "offline.example": status = 503
        case "refresh.example":
            let value = request.value(forHTTPHeaderField: "Cookie")
            if value == "test-session=old" {
                headers["Set-Cookie"] = "test-session=renewed; Path=/; Max-Age=86400; HttpOnly; Secure"
            } else if value != "test-session=renewed" { status = 401 }
        default: break
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("test-version".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FrigateProtocol.self]
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration)
}

@MainActor @Test func authenticatedHealthChecksRenewTheActualWebKitCookie() async throws {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let store = dataStore.httpCookieStore
    let bridge = WebSessionCookies(store: store)
    let probe = HealthProbe(cookies: bridge)
    let session = mockSession()
    defer { session.invalidateAndCancel() }
    let server = try ServerAddress("https://refresh.example")
    #expect(await probe.check(server, session: session) == .available(authenticated: false))
    await store.setCookie(cookie())
    await store.setCookie(cookie("unrelated", domain: "other.example"))
    #expect(await probe.check(server, session: session) == .available(authenticated: true))
    let current = await bridge.cookies(for: server.healthURL)
    #expect(current.count == 1)
    #expect(current.first?.value == "renewed")
    #expect(current.first?.isHTTPOnly == true)
    #expect(current.first?.expiresDate.map { $0.timeIntervalSinceNow > 86000 } == true)
    #expect(await probe.check(server, session: session) == .available(authenticated: true))
}

@MainActor @Test func lateRefreshResponsesCannotRecreateALoggedOutSession() async throws {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let store = dataStore.httpCookieStore
    let bridge = WebSessionCookies(store: store)
    let server = try ServerAddress("https://refresh.example")
    let old = cookie()
    let response = HTTPURLResponse(url: server.healthURL, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Set-Cookie": "test-session=renewed; Path=/; Max-Age=86400; Secure"])!
    await store.setCookie(old)
    let sent = await bridge.cookies(for: server.healthURL)
    await store.deleteCookie(old)
    await bridge.acceptRefresh(from: response, for: server, sent: sent)
    #expect(await bridge.cookies(for: server.healthURL).isEmpty)
    await store.setCookie(cookie("new-login"))
    await bridge.acceptRefresh(from: response, for: server, sent: sent)
    #expect(await bridge.cookies(for: server.healthURL).first?.value == "new-login")
}

@MainActor @Test func reconnectPrefersASignedInBackupOverThePrimaryLoginPage() async throws {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let probe = HealthProbe(cookies: WebSessionCookies(store: dataStore.httpCookieStore))
    let session = mockSession()
    defer { session.invalidateAndCancel() }
    let primary = try ServerAddress("https://primary.example")
    let backup = try ServerAddress("https://backup.example")
    let offline = try ServerAddress("https://offline.example")
    let selection = await probe.selectServer(from: [primary, backup], session: { _ in session })
    #expect(selection.server == backup)
    #expect(selection.result == .available(authenticated: true))
    let login = await probe.selectServer(from: [primary, offline], session: { _ in session })
    #expect(login.server == primary)
    #expect(login.result == .available(authenticated: false))
    let failure = await probe.selectServer(from: [offline], session: { _ in session })
    #expect(failure.server == nil)
    #expect(failure.result == .unavailable("Frigate returned error 503."))
}

@Test func healthProbesDoNotForwardCookiesToRedirectTargets() throws {
    let server = try ServerAddress("https://refresh.example")
    let delegate = ProbeTrustDelegate(server: server, fingerprint: nil)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: server.healthURL)
    let response = HTTPURLResponse(url: server.healthURL, statusCode: 302, httpVersion: "HTTP/1.1",
                                   headerFields: ["Location": "https://other.example/"])!
    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                        newRequest: URLRequest(url: URL(string: "https://other.example/")!)) {
        #expect($0 == nil)
    }
}
