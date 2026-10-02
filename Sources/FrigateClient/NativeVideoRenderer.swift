import AppKit
import AVFoundation
import Combine
import OSLog
import SwiftUI

/// Native decode and display; no browser, JavaScript, or unbounded frame queue.
@MainActor
final class NativeVideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    private var modern: Any?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        #if compiler(>=6.4)
        if #available(macOS 27, *) { modern = ModernRenderer(layer: layer) }
        #endif
    }

    func enqueue(_ sample: sending CMSampleBuffer) async throws {
        #if compiler(>=6.4)
        if #available(macOS 27, *), let modern = modern as? ModernRenderer {
            try await modern.enqueue(sample)
        } else { try await enqueueLegacy(sample) }
        #else
        try await enqueueLegacy(sample)
        #endif
    }

    func clear() {
        #if compiler(>=6.4)
        if #available(macOS 27, *), let modern = modern as? ModernRenderer {
            modern.receiver.flush()
        } else { clearLegacy() }
        #else
        clearLegacy()
        #endif
    }

    @available(macOS, introduced: 14, deprecated: 27)
    private func enqueueLegacy(_ sample: CMSampleBuffer) async throws {
        let renderer = layer.sampleBufferRenderer
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !renderer.isReadyForMoreMediaData {
            guard renderer.status != .failed, ProcessInfo.processInfo.systemUptime < deadline else {
                throw VideoStreamError.decoderBusy
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard renderer.status != .failed else { throw VideoStreamError.decoderBusy }
        renderer.enqueue(sample)
    }

    @available(macOS, introduced: 14, deprecated: 27)
    private func clearLegacy() { layer.sampleBufferRenderer.flush() }
}

#if compiler(>=6.4)
@available(macOS 27, *)
@MainActor
private final class ModernRenderer {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let receiver: AVSampleBufferVideoRenderer.Receiver
    private let logger = Logger(subsystem: "app.frigateclient.desktop", category: "NativePlayback")
    private var lastDecodeWarning: TimeInterval = 0
    init(layer: AVSampleBufferDisplayLayer) {
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.setRate(1, time: .zero)
    }
    func enqueue(_ sample: sending CMSampleBuffer) async throws {
        let buffer = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)
        switch try await receiver.enqueue(buffer) {
        case .enqueued: break
        case .enqueuedWithDecodeFailures(let errors):
            // The current sample was admitted. A damaged earlier frame can recover at the next keyframe.
            // Only results requiring a flush or ending the receiver terminate this stream attempt.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDecodeWarning >= 10, let error = errors.first as NSError? {
                lastDecodeWarning = now
                logger.warning("Recoverable video decode failure: \(error.domain, privacy: .public):\(error.code); affected samples \(errors.count)")
            }
        case .cancelledDueToError(let error), .cancelledDueToFlushRequiredToResume(let error): throw error
        default: throw VideoStreamError.decoderBusy
        }
    }
}
#endif

struct NativeVideoSurface: NSViewRepresentable {
    let renderer: NativeVideoRenderer
    var visibilityChanged: ((Bool) -> Void)? = nil
    func makeNSView(context: Context) -> NativeVideoNSView {
        NativeVideoNSView(renderer: renderer, visibilityChanged: visibilityChanged)
    }
    func updateNSView(_ nsView: NativeVideoNSView, context: Context) {
        nsView.visibilityChanged = visibilityChanged
    }
}

@MainActor
final class NativeVideoNSView: NSView {
    private let video: AVSampleBufferDisplayLayer
    var visibilityChanged: ((Bool) -> Void)?
    private weak var observedClip: NSClipView?
    private var boundsChanges: AnyCancellable?
    private var wasVisible = false
    init(renderer: NativeVideoRenderer, visibilityChanged: ((Bool) -> Void)? = nil) {
        video = renderer.layer
        self.visibilityChanged = visibilityChanged
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshViewportVisibility()
    }
    private func refreshViewportVisibility() {
        let clip = enclosingScrollView?.contentView
        if observedClip !== clip {
            boundsChanges = nil
            observedClip = clip
            if let clip {
                clip.postsBoundsChangedNotifications = true
                boundsChanges = NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip)
                    .receive(on: DispatchQueue.main).sink { [weak self] _ in
                        MainActor.assumeIsolated { self?.refreshViewportVisibility() }
                    }
            }
        }
        let visible = window != nil && !isHiddenOrHasHiddenAncestor && visibleRect.width > 0 && visibleRect.height > 0
        guard visible != wasVisible else { return }
        wasVisible = visible
        // AppKit can lay out inside a SwiftUI update; publish the visibility on the next turn.
        Task { @MainActor [weak self] in
            guard let self, self.wasVisible == visible else { return }
            self.visibilityChanged?(visible)
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
        refreshViewportVisibility()
    }
}
