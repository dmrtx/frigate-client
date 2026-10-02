import AppKit
import AVFoundation
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

    func enqueue(_ sample: CMSampleBuffer) throws {
        #if compiler(>=6.4)
        if #available(macOS 27, *), let modern = modern as? ModernRenderer {
            try modern.enqueue(sample)
        } else { try enqueueLegacy(sample) }
        #else
        try enqueueLegacy(sample)
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
    private func enqueueLegacy(_ sample: CMSampleBuffer) throws {
        let renderer = layer.sampleBufferRenderer
        guard renderer.status != .failed, renderer.isReadyForMoreMediaData else {
            throw VideoStreamError.decoderBusy
        }
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
    init(layer: AVSampleBufferDisplayLayer) {
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.setRate(1, time: .zero)
    }
    func enqueue(_ sample: sending CMSampleBuffer) throws {
        let buffer = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)
        switch receiver.enqueueImmediately(buffer) {
        case .enqueued: break
        default: throw VideoStreamError.decoderBusy
        }
    }
}
#endif

struct NativeVideoSurface: NSViewRepresentable {
    let renderer: NativeVideoRenderer
    func makeNSView(context: Context) -> NativeVideoNSView { NativeVideoNSView(renderer: renderer) }
    func updateNSView(_ nsView: NativeVideoNSView, context: Context) { }
}

@MainActor
final class NativeVideoNSView: NSView {
    private let video: AVSampleBufferDisplayLayer
    init(renderer: NativeVideoRenderer) {
        video = renderer.layer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
}
