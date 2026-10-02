# Frigate Client for macOS

A minimal menu bar app for Frigate's full web interface. Open your cameras, recordings, and dashboard in a slim macOS window, with configurable local and backup connections.

Requires macOS 14 or later. Universal releases support Apple Silicon and Intel.

## Setup

1. Open **FrigateClient.app** and enter your primary Frigate address, such as `https://frigate.example:8971`.
2. Optionally add a backup address, such as `https://frigate-backup.example:8971`. A Tailscale hostname works here too.
3. Review the server certificate if it is self-signed, then sign in through Frigate's own login page.

Both addresses remain editable through **Server addresses…** in the menu bar. There are no preconfigured servers or credentials. Self-signed certificate approvals apply only to the approved certificate and server origin.

## Behavior

- Frigate's web dashboard handles camera layout, stream selection, and playback. The app has no separate native camera player or camera-count limit.
- The app stays in the menu bar and has no Dock icon. **Open Frigate** shows its window; **Quit Frigate** exits completely.
- The slim title bar has a connection indicator on the right. The inactive floating dashboard fullscreen control is hidden; use the green macOS window button for fullscreen.
- Playback pauses when the window is hidden, closed, or minimized. Visible windows keep playing behind other apps and on other displays.
- Showing the window resumes playback automatically. After a longer hidden interval, the dashboard reloads to restore its players. Mac wake events reconnect automatically.
- Connection checks run every 10 seconds while visible, or every 30 seconds while hidden. They prefer a reachable signed-in address and retry failures automatically.
- Two consecutive missed JavaScript responses replace a stalled browser view while retaining its website data store. Repeated stalls pause automatic page replacement until you choose **Reconnect**.
- Existing installations switch to the web dashboard automatically. Saved addresses, certificate approvals, and browser sessions are preserved.

The app retains Frigate cookies between launches and accepts refreshed cookies from authenticated health checks. Frigate may require another sign-in after a session expires while the app is quit, the Mac sleeps, or the server is unreachable. The app does not store your password.

## Local data

Server addresses and certificate approvals live in macOS preferences. WebKit stores cookies and site data locally. There is no analytics. Published source and packages contain no private addresses, credentials, cookies, footage, or browser profiles.

## Build

Requires Xcode with Swift 6.2 or later. There are no external package dependencies.

```sh
swift test --no-parallel
./Scripts/package_app.sh
./Scripts/verify_package.sh
open FrigateClient.app
```

Build a universal ZIP and checksum:

```sh
./Scripts/package_release.sh
```

Packages are written to `dist/`. Build caches, local app bundles, and release archives are excluded from Git. Release builds remap source paths and strip debug information before signing. Public builds are ad hoc signed and are not notarized.

See [PERFORMANCE.md](PERFORMANCE.md) for playback behavior and verification limits. The custom icon is in `Assets/AppIcon.png`; its generation prompt is in `Assets/icon-prompt.txt`.

## License

MIT. See [LICENSE](LICENSE).
