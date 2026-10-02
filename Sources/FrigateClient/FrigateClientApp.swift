import AppKit
import SwiftUI
import WebKit

@main
struct FrigateClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var connection = ConnectionController()
    @State private var showingSettings = false

    var body: some Scene {
        Window("Frigate", id: "main") {
            ContentView(connection: connection, showingSettings: $showingSettings)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            // macOS disables its normal Hide action for accessory (menu-bar-only) apps.
            CommandGroup(replacing: .appVisibility) {
                Button("Hide Frigate") { connection.hideWindow() }
                    .keyboardShortcut("h", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Reconnect") { connection.reconnect() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(connection.primary.isEmpty)
            }
        }

        MenuBarExtra("Frigate", systemImage: "camera.aperture") {
            FrigateMenu(connection: connection, showingSettings: $showingSettings)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

private struct FrigateMenu: View {
    let connection: ConnectionController
    @Binding var showingSettings: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(connection.statusText)
        Divider()
        Button("Open Frigate", action: showWindow)
        .keyboardShortcut("o", modifiers: .command)
        Button("Hide Frigate") { connection.hideWindow() }
        Button("Server addresses…") {
            showWindow()
            showingSettings = true
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Reconnect") { connection.reconnect() }
            .disabled(connection.primary.isEmpty)
        Divider()
        Button("Quit Frigate") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

struct ContentView: View {
    @Bindable var connection: ConnectionController
    @Binding var showingSettings: Bool

    var body: some View {
        ZStack {
            if let webView = connection.webView {
                FrigateWebView(webView: webView)
                    .id(ObjectIdentifier(webView))
                    .opacity(connection.state == .connected ? 1 : 0.15)
            }
            if connection.state != .connected || connection.pageRecoveryPaused {
                VStack(spacing: 16) {
                    Image(systemName: "video")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(connection.pageRecoveryPaused ? "Page recovery paused" : connection.state == .idle ? "Set up Frigate" :
                         connection.state == .reconnecting ? "Waiting for Frigate" : "Connecting to Frigate")
                        .font(.title2.weight(.medium))
                    Text(connection.detail).foregroundStyle(.secondary)
                    if connection.state == .reconnecting {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let retry = connection.nextRetry {
                                Text("Retrying automatically in \(max(0, Int(ceil(retry.timeIntervalSince(context.date))))) s")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("Trying server addresses…").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    } else if connection.state == .connecting { ProgressView().controlSize(.small) }
                    HStack(spacing: 12) {
                        Button("Server addresses…") { showingSettings = true }
                        if connection.state != .idle {
                            Button("Reconnect") { connection.reconnect() }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(32)
            }
        }
        .background(.background)
        .background {
            WindowStatusIndicator(state: connection.indicatorState, detail: connection.state == .connected
                                  ? connection.statusText : connection.detail, requiresSignIn: connection.requiresSignIn,
                                  onWindowChanged: { connection.attachWindow($0) })
                .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $showingSettings) { ServerSettingsView(connection: connection) }
        .alert("Trust this server?", isPresented: Binding(
            get: { connection.certificate != nil },
            set: { if !$0 { connection.resolveCertificate(accept: false) } }
        ), presenting: connection.certificate) { _ in
            Button("Cancel", role: .cancel) { connection.resolveCertificate(accept: false) }
            Button("Trust") { connection.resolveCertificate(accept: true) }
        } message: { certificate in
            Text("\(certificate.server.url.absoluteString) uses a certificate that macOS does not recognize. Frigate usually generates its own certificate. Only this exact certificate will be remembered for this address.\n\nSHA-256: \(certificate.fingerprint)")
        }
        .alert(connection.downloadNotice?.title ?? "Download", isPresented: Binding(
            get: { connection.downloadNotice != nil },
            set: { if !$0 { connection.dismissDownloadNotice() } }
        )) {
            Button("OK") { connection.dismissDownloadNotice() }
        } message: {
            Text(connection.downloadNotice?.message ?? "")
        }
        .task {
            refreshWindowVisibility()
            if connection.state == .idle {
                if connection.primary.isEmpty { showingSettings = true }
                else { _ = connection.connect() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
            updateWindowVisibility($0, visible: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) {
            updateWindowVisibility($0, visible: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) {
            updateWindowVisibility($0, visible: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            updateWindowVisibility($0, visible: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) {
            updateWindowVisibility($0, visible: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshWindowVisibility()
            connection.recoverIfNeeded()
        }
    }

    private func updateWindowVisibility(_ notification: Notification, visible: Bool) {
        guard let window = notification.object as? NSWindow,
              window === connection.window else { return }
        if visible { refreshWindowVisibility() }
        else { connection.setViewVisible(false) }
    }

    private func refreshWindowVisibility() {
        connection.refreshWindowVisibility()
    }
}

private struct FrigateWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

private struct ServerSettingsView: View {
    let connection: ConnectionController
    @Environment(\.dismiss) private var dismiss
    @State private var primary: String
    @State private var backup: String
    @State private var error: String?

    init(connection: ConnectionController) {
        self.connection = connection
        _primary = State(initialValue: connection.primary)
        _backup = State(initialValue: connection.backup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Server addresses").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Primary · local network").font(.callout)
                TextField("https://frigate.example:8971", text: $primary)
                    .accessibilityLabel("Primary address")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Backup · Tailscale (optional)").font(.callout)
                TextField("https://backup.example:8971", text: $backup)
                    .accessibilityLabel("Backup address")
            }
            Text("Try the primary address first, then the backup if it is unavailable.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and connect") {
                    error = connection.connect(primary: primary, backup: backup)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 480)
    }
}
