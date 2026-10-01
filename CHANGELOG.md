# Changelog

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
