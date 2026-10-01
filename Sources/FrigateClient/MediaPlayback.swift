import Foundation

/// WebKit counts suspensions, so each app-owned suspension must have exactly one resume.
@MainActor
final class MediaPlayback {
    typealias Completion = @MainActor @Sendable () -> Void
    private let apply: @MainActor (Bool, Completion?) -> Void
    private(set) var isSuspended = false

    init(apply: @escaping @MainActor (Bool, Completion?) -> Void) { self.apply = apply }

    func update(isVisible: Bool, completion: Completion? = nil) {
        let suspended = !isVisible
        guard isSuspended != suspended else {
            completion?()
            return
        }
        isSuspended = suspended
        apply(suspended, completion)
    }
}

enum WindowPlaybackVisibility {
    /// Focus and occlusion are deliberately irrelevant: a window behind another app can keep playing.
    static func isVisible(windowIsVisible: Bool, isMiniaturized: Bool, appIsHidden: Bool) -> Bool {
        windowIsVisible && !isMiniaturized && !appIsHidden
    }
}
