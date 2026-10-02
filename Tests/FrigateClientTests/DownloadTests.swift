import Foundation
import Testing
import WebKit
@testable import FrigateClient

@Test func downloadPoliciesHandleBlobsAttachmentsAndOriginBoundaries() throws {
    let server = try ServerAddress("https://frigate.example:8971")
    #expect(DownloadPolicy.allows(URL(string: "blob:https://frigate.example:8971/fixture")!, server: server))
    #expect(!DownloadPolicy.allows(URL(string: "blob:https://other.example:8971/fixture")!, server: server))
    #expect(!DownloadPolicy.allows(URL(string: "https://frigate.example/file")!, server: server))
    #expect(!DownloadPolicy.allows(URL(string: "file:///tmp/fixture")!, server: server))
    let response = HTTPURLResponse(url: server.url, statusCode: 200, httpVersion: "HTTP/1.1",
                                  headerFields: ["Content-Disposition": "ATTACHMENT; filename=fixture.txt"])!
    #expect(DownloadPolicy.isAttachment(response))
}

@Test func incompleteDownloadsPreserveExistingFilesAndCompletedOnesReplaceThem() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("export.bin")
    try Data("original".utf8).write(to: destination)
    let partial = try DownloadFile(destination: destination)
    try Data("partial".utf8).write(to: partial.temporaryURL)
    partial.cleanUp()
    #expect(try Data(contentsOf: destination) == Data("original".utf8))
    let complete = try DownloadFile(destination: destination)
    try Data("complete".utf8).write(to: complete.temporaryURL)
    try complete.commit()
    complete.cleanUp()
    #expect(try Data(contentsOf: destination) == Data("complete".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["export.bin"])
}

@MainActor @Test(arguments: ["http", "attachment", "mime", "blob", "cancel", "failure", "httpError", "attachmentError"])
func dashboardDownloadsSaveAllBytesWithoutDisconnecting(kind: String) async throws {
    let bytes = Data((0..<65536).map { UInt8($0 % 251) })
    let fixture = try HTTPFixture { path in
        if ["/download", "/attachment", "/mime", "/failure", "/httpError", "/attachmentError"].contains(path) {
            var headers = ["Content-Type": "application/octet-stream"]
            if path != "/mime" { headers["Content-Disposition"] = "attachment; filename=synthetic-export.bin" }
            if ["/attachment", "/attachmentError"].contains(path) { headers["Content-Type"] = "text/plain" }
            return .init(status: ["/httpError", "/attachmentError"].contains(path) ? 503 : 200, headers: headers,
                         body: bytes, reportedLength: path == "/failure" ? bytes.count * 2 : nil)
        }
        let html = """
        <html><body>
        <a id='http' href='/download' download='synthetic-export.bin'>HTTP</a>
        <a id='attachment' href='/attachment'>Attachment</a>
        <a id='mime' href='/mime'>MIME</a>
        <a id='cancel' href='/download' download>Cancel</a>
        <a id='failure' href='/failure' download>Failure</a>
        <a id='httpError' href='/httpError' download>HTTP error</a>
        <a id='attachmentError' href='/attachmentError'>Attachment error</a>
        <button id='blob' onclick="const a=document.createElement('a'); a.href=window.URL.createObjectURL(new Blob([Uint8Array.from({length:65536},(_,i)=>i%251)])); a.download='synthetic-export.bin'; document.body.appendChild(a); a.click();">Blob</button>
        </body></html>
        """
        return .init(body: Data(html.utf8))
    }
    defer { fixture.stop() }
    try await waitUntil { (fixture.port ?? 0) > 0 }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("saved.bin")
    let suite = "DownloadTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WKWebsiteDataStore.nonPersistent()
    await store.httpCookieStore.setCookie(HTTPCookie(properties: [.name: "synthetic-session", .value: "fixture",
        .domain: "127.0.0.1", .path: "/", .expires: Date.now.addingTimeInterval(3600)])!)
    var prompts = 0
    let controller = ConnectionController(defaults: defaults, websiteDataStore: store, navigationTimeout: .seconds(2),
                                          downloadDestination: { _, reply in
        prompts += 1
        reply(kind == "cancel" ? nil : destination)
    })
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { controller.setViewVisible(false) }
    try await waitUntil { controller.state == .connected }
    let view = try #require(controller.webView)
    _ = try await view.evaluateJavaScript("document.getElementById('\(kind)').click()")
    if kind == "httpError" || kind == "attachmentError" {
        try await waitUntil { controller.downloadNotice != nil }
        #expect(prompts == 0)
    } else { try await waitUntil { prompts == 1 } }
    if kind == "cancel" {
        try await Task.sleep(for: .milliseconds(2300)) // A converted navigation must also cancel its deadline.
        #expect(controller.downloadNotice == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    } else {
        try await waitUntil { controller.downloadNotice != nil }
        if kind == "failure" || kind == "httpError" || kind == "attachmentError" {
            #expect(controller.downloadNotice?.title == "Download failed")
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        } else {
            #expect(controller.downloadNotice?.title == "Download complete")
            #expect(try Data(contentsOf: destination) == bytes)
        }
    }
    #expect(controller.webView === view)
    #expect(controller.state == .connected)
    if kind != "blob" {
        #expect(fixture.receivedRequests.contains { $0.contains("GET /\(kind == "http" || kind == "cancel" ? "download" : kind) ") && $0.contains("synthetic-session=fixture") })
    }
}

@MainActor @Test func aDownloadInANewWindowDoesNotCancelAnotherNavigationsDeadline() async throws {
    let fixture = try HTTPFixture { path in
        if path == "/hang" { return .init(hang: true) }
        let html = """
        <html><body><button id='export' onclick="const a=document.createElement('a'); a.href=window.URL.createObjectURL(new Blob(['export'])); a.download='export.txt'; a.target='_blank'; document.body.appendChild(a); a.click();">Export</button></body></html>
        """
        return .init(body: Data(html.utf8))
    }
    defer { fixture.stop() }
    try await waitUntil { (fixture.port ?? 0) > 0 }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "ConcurrentDownloadTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent(), navigationTimeout: .seconds(2),
        downloadDestination: { _, reply in reply(directory.appendingPathComponent("export.txt")) })
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { controller.setViewVisible(false) }
    try await waitUntil { controller.state == .connected }
    let view = try #require(controller.webView)
    _ = try await view.evaluateJavaScript("window.location.href='/hang'")
    try await waitUntil { view.isLoading && fixture.paths.contains("/hang") }
    _ = try await view.evaluateJavaScript("document.getElementById('export').click()")
    try await waitUntil { controller.downloadNotice != nil }
    #expect(controller.downloadNotice?.title == "Download complete")
    #expect(try Data(contentsOf: directory.appendingPathComponent("export.txt")) == Data("export".utf8))
    #expect(controller.state == .connecting)
    try await waitUntil(timeout: 4) { controller.webView !== view }
    #expect(controller.detail == "Frigate took too long to respond.")
}

@MainActor @Test func simultaneousDownloadsPresentOnlyOneSaveDialogAtATime() async throws {
    let fixture = try HTTPFixture { path in
        if path.hasPrefix("/download") {
            return .init(headers: ["Content-Type": "application/octet-stream"], body: Data("export".utf8))
        }
        return .init(body: Data("<html><body><a id='export' href='/download' download='export.bin'>Export</a></body></html>".utf8))
    }
    defer { fixture.stop() }
    try await waitUntil { (fixture.port ?? 0) > 0 }
    let suite = "QueuedDownloadTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var replies: [DashboardDownloads.DestinationReply] = []
    let controller = ConnectionController(defaults: defaults, websiteDataStore: .nonPersistent(),
                                         downloadDestination: { _, reply in replies.append(reply) })
    #expect(controller.connect(primary: "http://127.0.0.1:\(fixture.port!)") == nil)
    defer { controller.setViewVisible(false) }
    try await waitUntil { controller.state == .connected }
    let view = try #require(controller.webView)
    _ = try await view.evaluateJavaScript("document.getElementById('export').click()")
    try await waitUntil { replies.count == 1 }
    _ = try await view.evaluateJavaScript("document.getElementById('export').href='/download?second=1'; document.getElementById('export').click()")
    try await waitUntil { fixture.paths.filter { $0.hasPrefix("/download") }.count == 2 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(replies.count == 1)
    replies[0](nil)
    try await waitUntil { replies.count == 2 }
    replies[1](nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(controller.downloadNotice == nil)
    #expect(controller.state == .connected)
    #expect(controller.webView === view)
}
