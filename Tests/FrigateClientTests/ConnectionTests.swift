import Foundation
import Testing
@testable import FrigateClient

@Test func addressesSupportLocalTailscaleAndSubpaths() throws {
    let local = try ServerAddress(" frigate.example:8971 ")
    #expect(local.url.absoluteString == "https://frigate.example:8971/")
    #expect(local.healthURL.absoluteString == "https://frigate.example:8971/api/version")
    let remote = try ServerAddress("HTTPS://BACKUP.EXAMPLE:8971/frigate")
    #expect(remote.healthURL.absoluteString == "https://backup.example:8971/frigate/api/version")
    #expect(try ServerAddress("http://localhost:5000").url.scheme == "http")
    #expect(try ServerAddress("http://[::1]:5000").url.port == 5000)
}

@Test(arguments: ["", "file:///tmp/test", "ftp://host", "https://host:0", "https://host:65536", "https://user:password@host", "https://host?token=secret", "https://host/#fragment", "https://bad host"])
func invalidAddressesAreRejected(_ value: String) {
    #expect(throws: AddressError.self) { try ServerAddress(value) }
}

@Test func serverOriginDoesNotIncludePagesOrConfusePorts() throws {
    let server = try ServerAddress("https://frigate.example:8971")
    #expect(server.contains(URL(string: "https://frigate.example:8971/login")!))
    #expect(!server.contains(URL(string: "https://frigate.example/login")!))
    #expect(!server.contains(URL(string: "http://frigate.example:8971/")!))
    #expect(!server.contains(URL(string: "https://other:8971/")!))
    #expect(try ServerAddress("https://frigate.example").origin == ServerAddress("https://frigate.example:443").origin)
}

@Test func backupIsOptionalOrderedAndDeduplicated() throws {
    let servers = try Servers(primary: "frigate.example:8971", backup: "backup.example:8971")
    #expect(servers.candidates.map(\.url.host) == ["frigate.example", "backup.example"])
    #expect(try Servers(primary: "frigate.example:8971", backup: " ").candidates.count == 1)
    #expect(try Servers(primary: "frigate.example:8971", backup: "https://frigate.example:8971/").candidates.count == 1)
}

@MainActor @Test func freshInstallRequiresTheUsersOwnServerAddresses() {
    let suite = "FrigateClientTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = ConnectionController(defaults: defaults)
    #expect(connection.primary.isEmpty)
    #expect(connection.backup.isEmpty)
    #expect(connection.state == .idle)
    #expect(connection.activeServer == nil)
    #expect(connection.webView == nil)
}

@Test func retryBackoffIsBoundedAndLoginIsReachable() {
    #expect([0, 1, 2, 3, 4, 100].map { RetryPolicy().delay(after: $0) } == [2, 4, 8, 15, 30, 30])
    #expect(RetryPolicy().delay(after: -1) == 2)
    #expect(RetryPolicy.isReachable(status: 200))
    #expect(RetryPolicy.isReachable(status: 302))
    #expect(RetryPolicy.isReachable(status: 401))
    #expect(RetryPolicy.isReachable(status: 403))
    #expect(!RetryPolicy.isReachable(status: 404))
    #expect(!RetryPolicy.isReachable(status: 503))
}

@MainActor @Test func healthCheckConnectionsRemainScopedToTheirCertificateAndOrigin() throws {
    let pool = ProbeSessionPool()
    let local = try ServerAddress("https://frigate.example:8971")
    let remote = try ServerAddress("https://backup.example:8971")
    let first = pool.session(for: local, fingerprint: "first-certificate")
    #expect(pool.session(for: local, fingerprint: "first-certificate") === first)
    let backup = pool.session(for: remote, fingerprint: "first-certificate")
    #expect(backup !== first)

    let changed = pool.session(for: local, fingerprint: "new-certificate")
    #expect(changed !== first)
    #expect((changed.delegate as? ProbeTrustDelegate)?.fingerprint == "new-certificate")
    #expect(pool.session(for: local, fingerprint: nil) !== changed)

    pool.retainServers([local])
    #expect(pool.session(for: remote, fingerprint: "first-certificate") !== backup)
}
