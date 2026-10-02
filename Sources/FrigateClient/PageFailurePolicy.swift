import Foundation

/// A healthy API does not prove that the dashboard can load.
struct PageFailurePolicy {
    private var retryAfter: [String: Date] = [:]
    var cooldown: TimeInterval = 60

    mutating func failed(_ server: ServerAddress, now: Date = .now) {
        retryAfter[server.origin] = now.addingTimeInterval(cooldown)
    }

    mutating func succeeded(_ server: ServerAddress) { retryAfter.removeValue(forKey: server.origin) }

    func candidates(from servers: [ServerAddress], now: Date = .now) -> [ServerAddress] {
        let ready = servers.filter { (retryAfter[$0.origin] ?? .distantPast) <= now }
        if !ready.isEmpty { return ready }
        // If every page failed, retry only the oldest failure rather than starving the backup.
        return servers.min { (retryAfter[$0.origin] ?? .distantPast) < (retryAfter[$1.origin] ?? .distantPast) }
            .map { [$0] } ?? []
    }
}
