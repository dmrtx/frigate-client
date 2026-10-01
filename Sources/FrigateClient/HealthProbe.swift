import Foundation

/// A lightweight authenticated request renews Frigate's cookie without resuming video playback.
@MainActor
final class HealthProbe {
    enum Result: Equatable {
        case available(authenticated: Bool), needsTrust, unavailable(String)
    }

    struct Selection {
        let server: ServerAddress?
        let result: Result
    }

    private let cookies: WebSessionCookies

    init(cookies: WebSessionCookies) { self.cookies = cookies }

    func check(_ server: ServerAddress, session: URLSession) async -> Result {
        let sent = await cookies.cookies(for: server.healthURL)
        guard !Task.isCancelled else { return .unavailable("Connection cancelled.") }
        var request = URLRequest(url: server.healthURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        for (name, value) in HTTPCookie.requestHeaderFields(with: sent) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, let url = http.url, server.contains(url) else {
                return .unavailable("The server returned an invalid response.")
            }
            guard !Task.isCancelled else { return .unavailable("Connection cancelled.") }
            await cookies.acceptRefresh(from: http, for: server, sent: sent)
            return RetryPolicy.isReachable(status: http.statusCode)
                ? .available(authenticated: (200..<300).contains(http.statusCode))
                : .unavailable("Frigate returned error \(http.statusCode).")
        } catch {
            let error = error as NSError
            let trustErrors = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                               NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid]
            if error.domain == NSURLErrorDomain && trustErrors.contains(error.code) { return .needsTrust }
            return .unavailable("Could not connect to Frigate.")
        }
    }

    /// Prefer an existing signed-in session before falling back to a reachable login page.
    func selectServer(from servers: [ServerAddress],
                      session: (ServerAddress) -> URLSession) async -> Selection {
        var fallback: Selection?
        var failure: Result = .unavailable("Frigate is unavailable.")
        for server in servers {
            let result = await check(server, session: session(server))
            guard !Task.isCancelled else { return Selection(server: nil, result: result) }
            switch result {
            case .available(authenticated: true): return Selection(server: server, result: result)
            case .available, .needsTrust:
                if fallback == nil { fallback = Selection(server: server, result: result) }
            case .unavailable: failure = result
            }
        }
        return fallback ?? Selection(server: nil, result: failure)
    }
}

enum ViewRecoveryPolicy {
    static func needsReload(hiddenSince: Date?, now: Date = .now) -> Bool {
        guard let hiddenSince else { return false }
        return now.timeIntervalSince(hiddenSince) >= 60
    }
}
