import Foundation

/// A healthy API does not prove that the dashboard can load.
struct PageFailurePolicy {
    // Page availability belongs to a configured base URL, including its path.
    private var retryAfter: [URL: Date] = [:]
    var cooldown: TimeInterval = 60

    mutating func failed(_ server: ServerAddress, now: Date = .now) {
        retryAfter[server.url] = now.addingTimeInterval(cooldown)
    }

    mutating func succeeded(_ server: ServerAddress) { retryAfter.removeValue(forKey: server.url) }

    func candidates(from servers: [ServerAddress], now: Date = .now) -> [ServerAddress] {
        let ready = servers.filter { (retryAfter[$0.url] ?? .distantPast) <= now }
        if !ready.isEmpty { return ready }
        // If every page failed, retry only the oldest failure rather than starving the backup.
        return servers.min { (retryAfter[$0.url] ?? .distantPast) < (retryAfter[$1.url] ?? .distantPast) }
            .map { [$0] } ?? []
    }
}
