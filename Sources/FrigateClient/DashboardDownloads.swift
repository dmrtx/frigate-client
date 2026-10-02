import AppKit
import Foundation
import WebKit

struct DownloadNotice {
    let title: String
    let message: String
    static let failure = DownloadNotice(title: "Download failed", message: "The file could not be saved. Try the download again.")
}

enum DownloadPolicy {
    static func allows(_ url: URL, server: ServerAddress) -> Bool {
        if url.scheme == "blob", let origin = URL(string: String(url.absoluteString.dropFirst(5))) {
            return server.contains(origin)
        }
        return server.contains(url)
    }

    static func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }
}

/// WebKit requires a nonexistent destination; staging also preserves existing files on failure.
final class DownloadFile {
    let destination: URL
    let directory: URL
    var temporaryURL: URL { directory.appendingPathComponent("download") }

    init(destination: URL) throws {
        self.destination = destination
        directory = destination.deletingLastPathComponent().appendingPathComponent(".frigate-download-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func commit() throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
        } else { try FileManager.default.moveItem(at: temporaryURL, to: destination) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class DashboardDownloads: NSObject, WKDownloadDelegate {
    typealias DestinationReply = @MainActor @Sendable (URL?) -> Void
    typealias DestinationChooser = @MainActor (String, @escaping DestinationReply) -> Void
    private struct Entry {
        let download: WKDownload
        let server: ServerAddress
        let fingerprint: String?
        var file: DownloadFile?
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var destinationRequests: [(String, DestinationReply)] = []
    private var choosingDestination = false
    private let window: () -> NSWindow?
    private let chooseDestination: DestinationChooser?
    private let notify: (DownloadNotice) -> Void

    init(window: @escaping () -> NSWindow?, chooseDestination: DestinationChooser? = nil,
         notify: @escaping (DownloadNotice) -> Void) {
        self.window = window
        self.chooseDestination = chooseDestination
        self.notify = notify
    }

    func start(_ download: WKDownload, server: ServerAddress, fingerprint: String?) {
        entries[ObjectIdentifier(download)] = Entry(download: download, server: server, fingerprint: fingerprint)
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        guard entries[id] != nil else { completionHandler(nil); return }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            entries.removeValue(forKey: id)
            notify(.failure)
            completionHandler(nil)
            return
        }
        let reply: DestinationReply = { [weak self] destination in
            guard let self, self.entries[id] != nil, let destination else {
                self?.entries.removeValue(forKey: id)
                completionHandler(nil)
                return
            }
            do {
                let file = try DownloadFile(destination: destination)
                self.entries[id]?.file = file
                completionHandler(file.temporaryURL)
            } catch {
                self.entries.removeValue(forKey: id)
                self.notify(.failure)
                completionHandler(nil)
            }
        }
        let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        destinationRequests.append((name, reply))
        presentNextDestination()
    }

    private func presentNextDestination() {
        guard !choosingDestination, !destinationRequests.isEmpty else { return }
        choosingDestination = true
        let (name, reply) = destinationRequests.removeFirst()
        let finish: DestinationReply = { [weak self] destination in
            reply(destination)
            // Allow AppKit to finish removing the current sheet before attaching the next one.
            Task { @MainActor [weak self] in
                self?.choosingDestination = false
                self?.presentNextDestination()
            }
        }
        if let chooseDestination { chooseDestination(name, finish); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let finished: @MainActor (NSApplication.ModalResponse) -> Void = { result in
            finish(result == .OK ? panel.url : nil)
        }
        NSApp.activate()
        if let window = window(), window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: finished)
        }
        else { panel.begin(completionHandler: finished) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(download)), let file = entry.file else { return }
        defer { file.cleanUp() }
        do {
            try file.commit()
            notify(DownloadNotice(title: "Download complete", message: "Saved \(file.destination.lastPathComponent)."))
        } catch { notify(.failure) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.file?.cleanUp()
        // Do not display WebKit error text, which can contain URLs or credentials.
        notify(.failure)
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        guard let entry = entries[ObjectIdentifier(download)], let url = request.url else { decisionHandler(.cancel); return }
        decisionHandler(entry.server.contains(url) ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let entry = entries[ObjectIdentifier(download)],
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let space = challenge.protectionSpace
        if space.host.lowercased() == entry.server.url.host?.lowercased(),
           space.port == (entry.server.url.port ?? 443),
           ServerTrust.accepts(trust, fingerprint: entry.fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
