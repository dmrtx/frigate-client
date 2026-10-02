# Web playback and verification

## Architecture

The app is a Swift menu bar shell around one persistent-store `WKWebView`. Frigate's own web interface handles cameras and playback. The former native grid, WebSocket video client, fragmented-MP4 parser, and sample-buffer decoder have been removed.

This restores the same dashboard workflow as Frigate in a browser. Camera compatibility, stream selection, and dashboard layout belong to Frigate's web interface. The client adds connection failover, certificate approval, window visibility handling, and bounded page recovery.

There is no fixed camera-count limit in the shell. Actual resource usage depends on Frigate's playback choices, stream resolution and codec, simultaneous feeds, and the Mac. Changing the shell language to Rust would not replace WebKit's video workload. Previous native-player benchmark figures do not describe this version.

## Background and recovery

A visible window continues playing when another app has focus. Hiding, minimizing, or closing the window suspends WebKit media playback, with each suspension paired with one resume. Showing the window resumes media; after at least 60 seconds hidden, or if the page loaded while hidden, the dashboard reloads to restore its players. Workspace wake events reconnect.

Health probes use the matching browser cookies and reuse sessions scoped to each server origin and certificate. They run every 10 seconds while visible and every 30 seconds while hidden. A reachable authenticated backup is preferred over an address that requires sign-in.

A separate JavaScript responsiveness check runs while the page is visible and loaded. Two consecutive unanswered checks cause the app to replace the web view while retaining its website data store. Three replacements are allowed within five minutes; another stall unloads the page and offers manual **Reconnect**. This bounds recovery loops. A blocked app main thread cannot be repaired by an in-process watchdog, and responsive JavaScript does not prove every video stream is moving.

## Automated verification

Run `swift test --no-parallel`; AppKit window tests share application state. Tests exercise address validation, primary/backup selection, cookies and session renewal, certificate isolation, balanced playback suspension, window visibility, blocked JavaScript recovery, and repeated-stall limits.

Migration coverage sets the old native-mode preferences and verifies that the production controller still loads an interactive web page. A hosted SwiftUI window checks real WebKit suspension when minimized, hidden, restored, and closed.

The installed web-only app has also been checked through Computer Use against a real Frigate server: the dashboard displayed three cameras, camera navigation worked, and the existing session remained usable. One individual camera showed advancing timestamps; another remained on its loading screen during the check. Continuous playback on all cameras is therefore not verified. Dashboard previews follow Frigate's own live/still behavior; displaying a tile alone is not proof of continuous video.

Controlled tests establish client behavior; they do not establish live-camera health or all-day reliability. Runtime camera verification must use the installed app and confirm advancing images, dashboard interaction, and recovery after hiding or minimizing. WebKit helpers, WindowServer, and GPU activity must be included when interpreting whole-app resource usage.

No all-day soak test or runtime test on Intel or the other Mac that originally froze has been completed. Do not interpret build success as proof of those cases.
