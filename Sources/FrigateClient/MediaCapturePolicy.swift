import Foundation
import WebKit

struct CaptureOrigin {
    let scheme: String
    let host: String
    let port: Int

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port == 0 ? (self.scheme == "https" ? 443 : 80) : port
    }

    @MainActor init(_ origin: WKSecurityOrigin) {
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    func matches(_ server: ServerAddress) -> Bool {
        let configured = CaptureOrigin(scheme: server.url.scheme!, host: server.url.host!,
                                       port: server.url.port ?? 0)
        return scheme == configured.scheme && host == configured.host && port == configured.port
    }
}

enum MediaCapturePolicy {
    static func decision(server: ServerAddress?, origin: CaptureOrigin, frameOrigin: CaptureOrigin,
                         type: WKMediaCaptureType) -> WKPermissionDecision {
        guard type == .microphone, let server, origin.matches(server), frameOrigin.matches(server) else { return .deny }
        // WebKit prompts the user; never grant capture automatically. It also enforces secure contexts.
        return .prompt
    }
}
