# Changelog

## 0.3.0 — native playback by default

- Use native live view by default on fresh installations, preserving explicit existing mode preferences.
- Create a browser view only for login or the full dashboard; release it during native playback and when a server goes offline.
- Parse video fragments and prepare compressed samples in a separate actor, transferring ownership safely to the UI renderer.
- Keep per-frame diagnostics out of UI observation.
- Add labeled stream selection and remember each camera's chosen feed, allowing lower-bandwidth streams when configured.
- Observe actual window visibility so reopening a hidden window resumes playback even without a focus event.
- Listen for Mac wake events on the correct workspace notification center.
- Test the hosted SwiftUI window's minimize, restore, hide, show, and close behavior, along with stream selection and wake recovery.

Native mode displays one video-only camera. Disable **Native live view** in the menu bar for Frigate's full dashboard. Releases remain prereleases while live-server stability and runtime behavior on older macOS versions, Intel, and other Macs are not fully verified.

## 0.2.0 — native live-view preview

- Add optional video-only native playback for a selected camera, using Frigate's authenticated MSE stream and Apple's video renderer.
- Decode H.264 and H.265 without dashboard JavaScript, external dependencies, additional server ports, or client-side transcoding.
- Keep existing sign-in, cookie renewal, certificate approval, and primary/backup server selection.
- Close native streams when hidden, closed, or minimized, and reconnect when shown. Visible windows continue playing behind other apps.
- Allow time for the initial keyframe and bound recovery attempts after stalled or disconnected streams.
- Cap repeated dashboard-page rebuilds and unload a repeatedly stalled page until manual reconnection.
- Exercise native decode, stream disconnection, stalled-stream recovery limits, hide/resume, backup failover, and session-preserving browser recovery.
- Exclude test resource bundles from packaged apps.

Native mode is a preview and remains off until enabled from the menu bar. Live-server testing found intermittent missing video after a successful handshake; controlled playback passes, but all-day behavior on other Macs is not verified.

## 0.1.3

- Check that a visible Frigate page responds, independently of server health checks.
- Rebuild the embedded browser after two consecutive missed page responses, keeping the same website data store and login session.
- Cancel page checks while hidden or navigating, and ignore late replies from abandoned pages.

## 0.1.2

- Keep each WebKit playback suspension paired with exactly one resume, including when a page reloads while hidden.
- Pause only when the window is closed, minimized, or the app is explicitly hidden.
- Keep playback running when a visible window is behind another app or on another display.
- Handle Hide/Unhide without resuming windows that remain minimized.
- Provide a working **Hide Frigate** command (`⌘H`) for the menu bar app.
- Reload a page created while hidden when restoring it, so blocked autoplay starts automatically.

## 0.1.1

- Renew Frigate's browser session during background health checks while camera playback stays paused.
- Recover stale camera pages automatically after reopening a window closed or minimized for at least a minute.
- Prefer a signed-in backup when the primary address requires another login.
- Stop restoring login and logout pages, and show an amber dot when sign-in is required.
- Preserve logout and newer sign-ins when an older health-check response arrives.

## 0.1.0

- Minimal macOS menu bar app with a native window for Frigate's web interface.
- Configurable primary and optional backup server addresses, including Tailscale.
- Automatic reconnection, bounded retries, and recovery after Mac sleep.
- Persistent sign-in sessions and per-server certificate approval.
- Slim title bar with a connection dot and a custom camera icon.
- Automatic media pause when closed or minimized, and resume when restored.
- Reusable health-check connections with reduced background polling.
- Empty server fields on first launch and generic examples throughout.
- Universal ZIP package for Apple Silicon and Intel, with a SHA-256 checksum.
