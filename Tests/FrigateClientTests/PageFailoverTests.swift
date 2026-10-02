import Foundation
import Testing
import WebKit
@testable import FrigateClient

@Test func pageFailuresGiveTheBackupATurnAndExpire() throws {
    let servers = try Servers(primary: "https://primary.example", backup: "https://backup.example")
    let now = Date(timeIntervalSince1970: 1000)
    var policy = PageFailurePolicy()
    policy.failed(servers.primary, now: now)
    #expect(policy.candidates(from: servers.candidates, now: now) == [servers.backup!])
    policy.failed(servers.backup!, now: now.addingTimeInterval(1))
    #expect(policy.candidates(from: servers.candidates, now: now.addingTimeInterval(2)) == [servers.primary])
    #expect(policy.candidates(from: servers.candidates, now: now.addingTimeInterval(61)) == servers.candidates)
    policy.succeeded(servers.primary)
    #expect(policy.candidates(from: [servers.primary], now: now) == [servers.primary])
    #expect(policy.candidates(from: [], now: now).isEmpty)
}

@MainActor @Test(arguments: ["http503", "navigationFailure", "timeout"])
func healthyPrimaryAPIWithAFailingPageConnectsToBackup(failure: String) async throws {
    let primary = try HTTPFixture { path in
        if path == "/api/version" { return .init() }
        return .init(status: 503, hang: failure == "timeout", abort: failure == "navigationFailure")
    }
    let backup = try HTTPFixture()
    defer { primary.stop(); backup.stop() }
    try await waitUntil { primary.port != nil && backup.port != nil }
    let suite = "FailoverTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    #expect(controller.connect(primary: "http://127.0.0.1:\(primary.port!)",
                               backup: "http://127.0.0.1:\(backup.port!)") == nil)
    defer { controller.setViewVisible(false) }
    try await waitUntil(timeout: 35) { controller.state == .connected && controller.activeServer?.url.port == Int(backup.port!) }
    #expect(primary.paths.contains("/api/version"))
    #expect(primary.paths.contains("/"))
    #expect(backup.paths.contains("/"))
    #expect(!controller.requiresSignIn)
}
