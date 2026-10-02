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

@Test func pageFailureCooldownsAndRecoveryAreIsolatedByConfiguredBaseURL() throws {
    let primary = try ServerAddress("https://frigate.example/primary/")
    let backup = try ServerAddress("https://frigate.example/backup/")
    let candidates = [primary, backup]
    let now = Date(timeIntervalSince1970: 1000)
    #expect(primary.origin == backup.origin)
    var policy = PageFailurePolicy()
    policy.failed(primary, now: now)
    #expect(policy.candidates(from: candidates, now: now) == [backup])
    policy.failed(backup, now: now.addingTimeInterval(5))
    #expect(policy.candidates(from: candidates, now: now.addingTimeInterval(6)) == [primary])
    policy.succeeded(primary)
    #expect(policy.candidates(from: candidates, now: now.addingTimeInterval(6)) == [primary])
    policy.failed(primary, now: now.addingTimeInterval(7))
    #expect(policy.candidates(from: candidates, now: now.addingTimeInterval(65)) == [backup])
    policy.succeeded(backup)
    #expect(policy.candidates(from: candidates, now: now.addingTimeInterval(66)) == [backup])
    #expect(policy.candidates(from: candidates, now: now.addingTimeInterval(67)) == candidates)
}

@MainActor @Test(arguments: ["http503", "navigationFailure", "timeout"])
func failingPrimaryPageCanUseABackupPathOnTheSameOrigin(failure: String) async throws {
    let fixture = try HTTPFixture { path in
        if path == "/primary/" {
            return .init(status: 503, hang: failure == "timeout", abort: failure == "navigationFailure")
        }
        return .init()
    }
    defer { fixture.stop() }
    try await waitUntil { (fixture.port ?? 0) > 0 }
    let suite = "SameOriginFailoverTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent(),
                                          navigationTimeout: .seconds(2))
    let origin = "http://127.0.0.1:\(fixture.port!)"
    #expect(controller.connect(primary: origin + "/primary/", backup: origin + "/backup/") == nil)
    defer { controller.setViewVisible(false) }
    try await waitUntil(timeout: 8) { controller.state == .connected && controller.activeServer?.url.absoluteString == origin + "/backup/" }
    #expect(fixture.paths.contains("/primary/api/version"))
    #expect(fixture.paths.contains("/primary/"))
    #expect(fixture.paths.contains("/backup/api/version"))
    #expect(fixture.paths.contains("/backup/"))
    #expect(!controller.requiresSignIn)
}

@MainActor @Test func rememberedPagesRemainScopedToEachConfiguredBaseURL() async throws {
    let fixture = try HTTPFixture()
    defer { fixture.stop() }
    try await waitUntil { (fixture.port ?? 0) > 0 }
    let suite = "RememberedBasePagesTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent())
    let root = "http://127.0.0.1:\(fixture.port!)/"
    let backup = root + "backup/"
    #expect(controller.connect(primary: root, backup: backup) == nil)
    defer { controller.setViewVisible(false) }
    try await waitUntil { controller.state == .connected }
    let view = try #require(controller.webView)
    _ = try await view.evaluateJavaScript("window.location.href='/review'")
    try await waitUntil { controller.state == .connected && controller.webView?.url?.path == "/review" }
    #expect(controller.connect(primary: backup, backup: root) == nil)
    try await waitUntil { controller.state == .connected && controller.activeServer?.url.absoluteString == backup }
    _ = try await view.evaluateJavaScript("window.location.href='/backup/review'")
    try await waitUntil { controller.state == .connected && controller.webView?.url?.path == "/backup/review" }
    #expect(controller.connect(primary: root, backup: backup) == nil)
    try await waitUntil { controller.state == .connected }
    #expect(controller.activeServer?.url.path == "/")
    #expect(controller.webView?.url?.path == "/review")
}
