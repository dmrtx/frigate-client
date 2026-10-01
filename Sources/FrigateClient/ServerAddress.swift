import Foundation

struct ServerAddress: Equatable, Sendable {
    let url: URL

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AddressError.invalid }
        let value = text.contains("://") ? text : "https://\(text)"
        guard var parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true
        else { throw AddressError.invalid }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw AddressError.invalid }
        self.url = url
    }

    var healthURL: URL { url.appendingPathComponent("api/version") }

    var origin: String {
        "\(url.scheme!)://\(url.host!):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    func contains(_ other: URL) -> Bool {
        other.scheme?.lowercased() == url.scheme &&
            other.host?.lowercased() == url.host &&
            (other.port ?? (other.scheme == "https" ? 443 : 80)) ==
            (url.port ?? (url.scheme == "https" ? 443 : 80))
    }

    func isRestorablePage(_ other: URL) -> Bool {
        let base = url.path == "/" ? "" : url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = base.isEmpty ? "" : "/" + base
        guard contains(other), other.path == basePath || other.path.hasPrefix(basePath + "/") else { return false }
        let path = other.path.dropFirst(basePath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !["login", "logout", "api"].contains(String(path.split(separator: "/").first ?? ""))
    }
}

struct Servers: Equatable, Sendable {
    let primary: ServerAddress
    let backup: ServerAddress?

    init(primary: String, backup: String) throws {
        self.primary = try ServerAddress(primary)
        self.backup = backup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : try ServerAddress(backup)
    }

    var candidates: [ServerAddress] {
        guard let backup, backup != primary else { return [primary] }
        return [primary, backup]
    }
}

enum AddressError: LocalizedError {
    case invalid
    var errorDescription: String? {
        "Enter a server address such as https://frigate.example:8971."
    }
}

struct RetryPolicy {
    func delay(after failures: Int) -> TimeInterval {
        [2.0, 4.0, 8.0, 15.0, 30.0][min(max(failures, 0), 4)]
    }

    static func isReachable(status: Int) -> Bool {
        (200..<400).contains(status) || status == 401 || status == 403
    }
}
