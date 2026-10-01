import Foundation
import Testing
@testable import FrigateClient

@MainActor @Test func reloadingWhileHiddenDoesNotLeaveWebKitSuspendedAfterRestoring() {
    var suspensionDepth = 0
    var calls: [Bool] = []
    let playback = MediaPlayback { suspended, completion in
        calls.append(suspended)
        suspensionDepth += suspended ? 1 : -1
        completion?()
    }
    playback.update(isVisible: true) // Initial page load must not issue an unpaired resume.
    #expect(calls.isEmpty)
    playback.update(isVisible: false) // Minimize or close.
    playback.update(isVisible: false) // Navigation finishes while hidden.
    playback.update(isVisible: false) // Another reconnect or wake reload finishes while hidden.
    #expect(suspensionDepth == 1)
    playback.update(isVisible: true) // Restore.
    #expect(suspensionDepth == 0)
    #expect(!playback.isSuspended)
    #expect(calls == [true, false])
    playback.update(isVisible: true) // Becoming key again must not change playback.
    #expect(calls == [true, false])
    playback.update(isVisible: false)
    playback.update(isVisible: true)
    #expect(suspensionDepth == 0)
    #expect(calls == [true, false, true, false])
}

@Test func onlyClosedMinimizedOrExplicitlyHiddenWindowsPausePlayback() {
    // A visible window is playable regardless of which app is active or covers it.
    #expect(WindowPlaybackVisibility.isVisible(windowIsVisible: true, isMiniaturized: false, appIsHidden: false))
    #expect(!WindowPlaybackVisibility.isVisible(windowIsVisible: true, isMiniaturized: true, appIsHidden: false))
    #expect(!WindowPlaybackVisibility.isVisible(windowIsVisible: true, isMiniaturized: false, appIsHidden: true))
    #expect(!WindowPlaybackVisibility.isVisible(windowIsVisible: false, isMiniaturized: false, appIsHidden: false))
    // Unhiding the app must not resume a window that is still minimized.
    #expect(!WindowPlaybackVisibility.isVisible(windowIsVisible: true, isMiniaturized: true, appIsHidden: true))
}

@Test func aPageLoadedWhileHiddenGetsFreshPlayersEvenAfterABriefPause() {
    let now = Date()
    let hiddenSince = now.addingTimeInterval(-3)
    #expect(!ViewRecoveryPolicy.needsReload(hiddenSince: hiddenSince, now: now))
    #expect(ViewRecoveryPolicy.needsReload(hiddenSince: hiddenSince, pageLoadedWhileHidden: true, now: now))
    #expect(!ViewRecoveryPolicy.needsReload(hiddenSince: nil, pageLoadedWhileHidden: true, now: now))
}
