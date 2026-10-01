import Foundation
import WebKit

enum CookiePolicy {
    static func matches(_ cookie: HTTPCookie, url: URL, now: Date = .now) -> Bool {
        guard let host = url.host?.lowercased(),
              cookie.expiresDate.map({ $0 > now }) ?? true,
              !cookie.isSecure || url.scheme == "https" else { return false }
        let domain = cookie.domain.lowercased()
        let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bareDomain || (domain.hasPrefix(".") && host.hasSuffix("." + bareDomain)) else {
            return false
        }
        if let ports = cookie.portList, !ports.isEmpty,
           !ports.contains(NSNumber(value: url.port ?? (url.scheme == "https" ? 443 : 80))) {
            return false
        }
        let path = url.path.isEmpty ? "/" : url.path
        return path == cookie.path ||
            (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") ||
                                           path.dropFirst(cookie.path.count).hasPrefix("/")))
    }

    static func sameIdentity(_ lhs: HTTPCookie, _ rhs: HTTPCookie) -> Bool {
        lhs.name == rhs.name && lhs.domain.lowercased() == rhs.domain.lowercased() && lhs.path == rhs.path
    }

    /// Do not overwrite a newer sign-in or recreate a cookie removed by logout while the probe ran.
    static func canApply(_ replacement: HTTPCookie, sent: [HTTPCookie], current: [HTTPCookie]) -> Bool {
        guard let original = sent.first(where: { sameIdentity($0, replacement) }),
              let existing = current.first(where: { sameIdentity($0, replacement) }) else { return false }
        return existing.value == original.value
    }
}

@MainActor
final class WebSessionCookies {
    private let store: WKHTTPCookieStore

    init(store: WKHTTPCookieStore) { self.store = store }

    func cookies(for url: URL) async -> [HTTPCookie] {
        await store.allCookies().filter { CookiePolicy.matches($0, url: url) }
    }

    func acceptRefresh(from response: HTTPURLResponse, for server: ServerAddress,
                       sent: [HTTPCookie]) async {
        guard !sent.isEmpty, let url = response.url, server.contains(url) else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
        }
        let replacements = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        for replacement in replacements {
            // An expired replacement may delete an existing cookie, but cannot grant a wider scope.
            let scopeCookie = replacement.expiresDate.map({ $0 <= .now }) == true
                ? sent.first(where: { CookiePolicy.sameIdentity($0, replacement) }) : replacement
            guard let scopeCookie, CookiePolicy.matches(scopeCookie, url: url),
                  CookiePolicy.canApply(replacement, sent: sent, current: await store.allCookies()) else { continue }
            if replacement.expiresDate.map({ $0 <= .now }) == true {
                await store.deleteCookie(replacement)
            } else {
                await store.setCookie(replacement)
            }
        }
    }
}
