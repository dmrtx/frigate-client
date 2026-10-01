# Changelog

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
