# Playback architecture and verification

## Recommendation

For this macOS-only app, keep Swift and use Apple's native video renderer for live cameras. Removing dashboard JavaScript and its browser playback lifecycle is the useful architectural change. There is no measured evidence here that rewriting the networking or parser in Rust would reduce CPU use.

| Route | Video path | Assessment |
|---|---|---|
| Swift with native rendering | Authenticated go2rtc MSE WebSocket → bounded fragmented-MP4 parser → Apple sample-buffer renderer | Implemented as an optional preview; no external runtime dependencies or transcoding. |
| Rust with native rendering | Network/parser code → a bridge to Apple's media APIs | Viable, but not benchmarked. It would still rely on the same platform decoder; a language rewrite has no demonstrated benefit for this workload. |
| Rust with Tauri | macOS WKWebView | Tauri alone retains the browser playback path. |
| Native AVPlayer with HLS | HLS playlist → Apple player | Simpler playback integration if the server already exposes authenticated HLS. This app uses Frigate's existing authenticated MSE endpoint instead. |
| FFmpeg/libmpv client | Additional decoder/player libraries | Broader protocol support, with more packaging and integration work. Hardware decoding would still need to be enabled and verified. |

[Tauri documents its macOS WKWebView process](https://v2.tauri.app/concept/process-model/). Apple's [sample-buffer display layer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer) accepts compressed video, and [Video Toolbox](https://developer.apple.com/documentation/videotoolbox) provides platform video compression/decompression facilities. Native rendering lets macOS choose its supported decoding path; hardware acceleration is not guaranteed for every codec profile or Mac.

## Scope

The preview displays one selected camera, without audio. It uses the first configured `live.streams` value, ordered by its label, or the camera name when that mapping is absent. Cameras need an available go2rtc H.264 or H.265 stream. The full Frigate dashboard remains available by disabling **Native live view (preview)**.

Native playback uses the existing authenticated `/live/mse/api/ws` endpoint, matching session cookies and certificate approval. It does not expose go2rtc's management port or require server changes. A single WebSocket receive loop feeds compressed samples to the renderer; the app has no growing frame queue. Input messages and copied sample payloads are limited to 8 MiB, with at most 4,096 samples per message. Renderer backpressure fails the attempt instead of buffering indefinitely.

Startup has a 30-second grace period for the first frame. Once receiving video, ten seconds without another frame triggers reconnection. Three automatic retries are allowed in five minutes; another failure pauses playback. Hiding, closing, or minimizing releases the stream and flushes the renderer. Restoring starts a fresh connection. Visible background windows continue playing.

## Resource sample

A synthetic H.264 test pattern at **2560 × 1440, 30 fps** was streamed over a local WebSocket and rendered in a native 1280 × 720 window on an Apple Silicon Mac. After startup, a 20-second sample produced:

| Measurement | Result |
|---|---|
| Samples accepted by the native renderer | 571, about 28.6 fps |
| Test-process CPU | 4.9% of one CPU core |
| Test-process peak resident memory | 108 MiB |
| Test-process CPU after stopping, over five seconds | 0.3% of one CPU core |

CPU was measured from process user/system CPU time divided by elapsed monotonic time. The test process includes the local stream fixture, Swift Testing, and the cookie store. These figures exclude decoder helper processes, WindowServer, GPU activity, and energy usage. They are not whole-system resource totals or a comparison with Rust, Tauri, or the previous dashboard. Peak memory is for the test process, not the packaged app. Accepted samples and a ready display layer establish playback, not an independent frame-by-frame display count.

## Verification and limits

Controlled tests exercise H.264 and H.265 decoding, disconnect/reconnect, stopping and restarting playback, hidden-window shutdown, primary-server failure and backup selection, malformed/truncated/oversized fragments, and the retry limit after repeated stalls. Existing cookie-renewal, certificate/origin isolation, visibility, and real WebKit blocked-JavaScript recovery tests also run. Repeated browser-page recovery now unloads the page after its budget is exhausted.

One authenticated live-camera attempt displayed video successfully. Subsequent live startup/resume acceptance attempts failed while waiting for frames. A separate raw WebSocket check received the initialization segment but no video fragments for over a minute after a successful handshake, independently of the native decoder. Live-server stability therefore remains unverified; native mode is opt-in and published as a preview.

No all-day soak test, runtime test on Intel, or acceptance test on the Mac that originally froze has been completed. A blocked native app main thread cannot be repaired by an in-process watchdog. Lower-bandwidth camera substreams and shorter keyframe intervals can also reduce decode work and startup delay; [Frigate's live-view documentation](https://docs.frigate.video/configuration/live/) explains those settings.

## Reproduce the synthetic resource sample

Generate a test pattern outside the repository (FFmpeg is only needed for this diagnostic):

```sh
ffmpeg -f lavfi -i testsrc2=size=2560x1440:rate=30 -t 4 -an \
  -c:v libx264 -threads 2 -preset ultrafast -tune zerolatency \
  -g 30 -keyint_min 30 -sc_threshold 0 \
  -movflags empty_moov+default_base_moof+frag_keyframe \
  /tmp/frigate-synthetic-benchmark.mp4
FRIGATE_BENCHMARK_MP4=/tmp/frigate-synthetic-benchmark.mp4 \
  swift test --filter syntheticNativePlaybackResourceSample
```

The live-server acceptance test is disabled unless `FRIGATE_PRIVATE_TEST_SESSION` names a private JSON file outside the repository. Its required fields are `base`, `fingerprint`, `cookie` (a name/value pair), and `cameras` (an array with `streams`). Never commit that file or private camera footage. Ordinary tests use generated patterns bundled only with the test target; those resources are excluded from the app package.
