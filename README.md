# Frigate Client

A minimal macOS menu bar client for [Frigate](https://frigate.video/). A native window displays Frigate's web interface, including cameras, events, and recordings.

## Install

Requires **macOS 14 or later**. The universal release supports **Apple Silicon and Intel Macs**.

1. Download the latest `FrigateClient-<version>-universal.zip` from this repository's Releases page.
2. Extract it and move `FrigateClient.app` to Applications.
3. Open the app and enter your own Frigate server address.

The release is signed locally with an ad hoc signature and is not notarized. If macOS blocks opening, review the app under **System Settings → Privacy & Security**.

## Connect

Both address fields start empty. Use the menu bar's camera icon → **Server addresses…** to configure:

| Field | Example |
|---|---|
| Primary | `https://frigate.example:8971` |
| Backup (optional) | `https://backup.example:8971` |

These are placeholders. Replace them with your own server's local address and, optionally, its Tailscale address. Your Mac must be connected to the appropriate tailnet to use Tailscale.

The app tries the primary address first, then the backup. If the primary needs a login and the backup has a valid session, it uses the backup. Sign in through Frigate's interface. Each address has its own session, so you may need to sign in once at each address.

Frigate usually uses a [self-signed certificate on port 8971](https://docs.frigate.video/configuration/tls/). On first connection, the app asks you to approve its SHA-256 fingerprint. Only that exact certificate is remembered for that address and port. A changed self-signed certificate requires approval again. Valid certificates are verified by macOS.

## Use

- The app stays in the menu bar, without a Dock icon. Choose **Open Frigate** to show the window, or **Hide Frigate** (`⌘H`) to hide it and pause playback.
- The slim title bar shows a small connection dot at the right: green when connected and signed in, amber while reconnecting or when sign-in is required. Hover for details.
- Closing, minimizing, or explicitly hiding the app suspends media playback. A visible window keeps playing when another app is in front, including on another display. Reopening, restoring, or unhiding resumes it automatically; a minimized window stays paused when the app is unhidden. Background page reloads do not add extra playback suspensions. If a page loaded while hidden, restoring it reloads that page so blocked autoplay starts again. A pause of at least a minute also reloads the last camera page to recover stale streams. Login and logout pages are never saved as the page to restore.
- **Reconnect** or `⌘R` immediately retries both addresses. Automatic retries increase from 2 to 30 seconds.
- Health checks reuse network connections and run every 10 seconds while the window is open, or every 30 seconds while closed or minimized. They use the matching WebKit cookies and save Frigate's refreshed cookie back to WebKit without resuming video. Login responses (HTTP 401/403) are reachable but shown as requiring sign-in.
- Choose **Quit Frigate** to exit completely.

The inactive floating fullscreen control on Frigate's camera dashboard is hidden in the client. Use the green macOS window button for fullscreen.

Frigate's [default session expires after 24 hours](https://docs.frigate.video/configuration/authentication/) and renews through authenticated requests before expiry. The app keeps renewing while running and connected, including with its window closed. If you quit the app, your Mac sleeps, or the server stays unreachable until the session expires, Frigate requires another sign-in. The client cannot renew an already expired session. Signing out remains effective.

## Local data

Your server addresses and certificate approvals are stored in macOS preferences. WebKit stores browser cookies and site data locally between launches. The app has no custom password storage or analytics. Published source and packages contain no preconfigured servers, credentials, cookies, or browser profiles.

## Build

Requires Xcode with Swift 6.2 or later. There are no external package dependencies.

```sh
swift test
./Scripts/package_app.sh
open FrigateClient.app
```

Build a universal release ZIP and SHA-256 checksum:

```sh
./Scripts/package_release.sh
```

The package is written to `dist/`. Build caches, local app bundles, and release archives are excluded from Git. Release builds remap source paths and strip debug information before signing.

The custom icon is in `Assets/AppIcon.png`; its generation prompt is in `Assets/icon-prompt.txt`. The menu bar uses the native `camera.aperture` symbol.

## License

MIT. See [LICENSE](LICENSE).
