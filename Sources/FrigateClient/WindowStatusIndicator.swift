import AppKit
import SwiftUI

/// A title-bar accessory keeps the status visible without adding a toolbar row.
struct WindowStatusIndicator: NSViewRepresentable {
    let state: ConnectionState
    let detail: String
    let requiresSignIn: Bool
    var onWindowChanged: (NSWindow?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowAnchor {
        let anchor = WindowAnchor()
        anchor.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
            onWindowChanged(window)
        }
        return anchor
    }

    func updateNSView(_ nsView: WindowAnchor, context: Context) {
        context.coordinator.update(state: state, detail: detail, requiresSignIn: requiresSignIn)
        context.coordinator.attach(to: nsView.window)
        onWindowChanged(nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowAnchor, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.attach(to: nil)
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private let accessory = NSTitlebarAccessoryViewController()
        private let dot = StatusDot(frame: NSRect(x: 0, y: 0, width: 28, height: 22))

        init() {
            accessory.layoutAttribute = .right
            accessory.view = dot
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            if let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            window = newWindow
            newWindow?.addTitlebarAccessoryViewController(accessory)
        }

        func update(state: ConnectionState, detail: String, requiresSignIn: Bool) {
            switch state {
            case .connected: dot.color = requiresSignIn ? .systemOrange : .systemGreen
            case .reconnecting: dot.color = .systemOrange
            case .idle, .connecting: dot.color = .secondaryLabelColor
            }
            dot.toolTip = detail
            dot.setAccessibilityElement(true)
            dot.setAccessibilityRole(.image)
            dot.setAccessibilityLabel(state == .connected ? (requiresSignIn ? "Sign in required" : "Connected") :
                                      state == .reconnecting ? "Reconnecting" : "Connecting")
        }
    }
}

final class WindowAnchor: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

private final class StatusDot: NSView {
    var color: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6)).fill()
    }
}
