import Foundation

/// Reuse health-check connections without sharing certificate approvals across origins.
@MainActor
final class ProbeSessionPool {
    private var sessions: [String: URLSession] = [:]

    deinit {
        for session in sessions.values { session.invalidateAndCancel() }
    }

    func session(for server: ServerAddress, fingerprint: String?) -> URLSession {
        if let session = sessions[server.origin],
           let delegate = session.delegate as? ProbeTrustDelegate,
           delegate.fingerprint == fingerprint {
            return session
        }

        sessions.removeValue(forKey: server.origin)?.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let delegate = ProbeTrustDelegate(server: server, fingerprint: fingerprint)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessions[server.origin] = session
        return session
    }

    func retainServers(_ servers: [ServerAddress]) {
        let origins = Set(servers.map(\.origin))
        for origin in Array(sessions.keys) where !origins.contains(origin) {
            sessions.removeValue(forKey: origin)?.invalidateAndCancel()
        }
    }
}
