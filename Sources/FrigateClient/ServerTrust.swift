import CryptoKit
import Foundation
import Security

enum ServerTrust {
    static func fingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func accepts(_ trust: SecTrust, fingerprint: String?) -> Bool {
        if SecTrustEvaluateWithError(trust, nil) { return true }
        guard let fingerprint else { return false }
        return self.fingerprint(trust) == fingerprint
    }
}

/// A probe can reuse only the exact certificate approved for this server.
final class ProbeTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let server: ServerAddress
    let fingerprint: String?

    init(server: ServerAddress, fingerprint: String?) {
        self.server = server
        self.fingerprint = fingerprint
    }

    // A health probe carries origin-scoped browser cookies; never forward them on redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        let matchesServer = space.host.lowercased() == server.url.host?.lowercased() &&
            space.port == (server.url.port ?? 443)
        if matchesServer && ServerTrust.accepts(trust, fingerprint: fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
