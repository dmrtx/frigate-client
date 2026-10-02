# Playback architecture and verification

## Recommendation

For this macOS-only app, keep Swift and use Apple's native video renderer for live cameras. Removing dashboard JavaScript and its browser playback lifecycle is the useful architectural change. There is no measured evidence here that rewriting the networking or parser in Rust would reduce CPU use.

| Route | Video path | Assessment |
|---|---|---|
| Swift with native rendering | Authenticated go2rtc MSE WebSocket → bounded fragmented-MP4 parser → Apple sample-buffer renderer | Default on fresh installations; no external runtime dependencies or transcoding. |
| Rust with native rendering | Network/parser code → a bridge to Apple's media APIs | Viable, but not benchmarked. It would still rely on the same platform decoder; a language rewrite has no demonstrated benefit for this workload. |
| Rust with Tauri | macOS WKWebView | Tauri alone retains the browser playback path. |
| Native AVPlayer with HLS | HLS playlist → Apple player | Simpler playback integration if the server already exposes authenticated HLS. This app uses Frigate's existing authenticated MSE endpoint instead. |
| FFmpeg/libmpv client | Additional decoder/player libraries | Broader protocol support, with more packaging and integration work. Hardware decoding would still need to be enabled and verified. |

[Tauri documents its macOS WKWebView process](https://v2.tauri.app/concept/process-model/). Apple's [sample-buffer display layer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer) accepts compressed video, and [Video Toolbox](https://developer.apple.com/documentation/videotoolbox) provides platform video compression/decompression facilities. Native rendering lets macOS choose its supported decoding path; hardware acceleration is not guaranteed for every codec profile or Mac.

## Scope

Native mode displays an adaptive camera grid or one selected camera, without audio. There is no fixed three-camera limit. Each camera owns its stream, decoder, and recovery budget. Only video surfaces intersecting the AppKit scroll viewport are connected; offscreen tiles stop until they return to the viewport. The stream picker lists configured `live.streams` labels and remembers a choice for each camera. With no saved choice, it uses the first stream ordered by label, or the camera name when that mapping is absent. Duplicate stream values appear once. The app does not infer which feed has the lowest bitrate; choose a lower-bandwidth stream when one is configured. Cameras need an available go2rtc H.264 or H.265 stream. The full Frigate dashboard remains available by disabling **Native live view**. Existing explicit mode preferences are preserved.

Native playback uses the existing authenticated `/live/mse/api/ws` endpoint, matching session cookies and certificate approval. It does not expose go2rtc's management port or require server changes. A browser view is created only for sign-in or the full dashboard, and released during native playback. The persistent website data store retains the session cookies.

A single WebSocket receive loop transfers fragments to a separate actor for parsing and compressed-sample preparation. The UI actor only enqueues the prepared samples for native rendering. Per-frame counters are excluded from UI observation. The app has no growing frame queue. Input messages and copied sample payloads are limited to 8 MiB, with at most 4,096 samples per message. Enqueue waits for renderer capacity instead of immediately rejecting a burst of frames. Legacy renderers have a two-second capacity deadline; the modern receiver is interrupted by flushing when the stream watchdog expires. New connections wait for a keyframe before decoding. Recoverable decode errors on the modern receiver continue to the next frame; errors requiring a flush or terminating the receiver retry that camera independently.

Startup has a 30-second grace period for the first frame. Once receiving video, ten seconds without another frame triggers reconnection. Three automatic retries are allowed in five minutes; another failure pauses playback. Hiding, closing, or minimizing releases the stream and flushes the decoder state; the last displayed image can remain allocated. Restoring starts a fresh connection. Actual window visibility is observed, so recovery does not require a focus event. Wake events are received from the workspace notification center. Visible background windows continue playing.

## Resource sample

A synthetic H.264 test pattern at **2560 × 1440, 30 fps** was streamed over a local WebSocket and rendered in a native 1280 × 720 window on an Apple Silicon Mac. After startup, a 20-second sample produced:

| Measurement | Result |
|---|---|
| Samples accepted by the native renderer | 570, about 28.5 fps |
| Test-process CPU | 4.8% of one CPU core |
| Test-process peak resident memory | 108 MiB |
| Test-process CPU after stopping, over five seconds | 0.3% of one CPU core |

CPU was measured from process user/system CPU time divided by elapsed monotonic time. The test process includes the local stream fixture, Swift Testing, and the cookie store. The renderer also returned a decoded 2560 × 1440 pixel buffer. Accepted samples and a ready display layer do not constitute an independent frame-by-frame display count.

The separately packaged universal release app was also launched with an isolated settings domain and the same synthetic stream. A 20-second sample measured **3.5% of one CPU core**, **104 MiB resident memory**, and **29 MiB physical footprint** for the app process. The fixture observed one stream connection. These memory values are endpoint samples, not peak measurements. Process CPU was read with `proc_pid_rusage`, converting its Mach time units with `mach_timebase_info`; a busy-process calibration measured approximately one full CPU core. Apple's [task accounting implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c) supplies Mach time counters to [resource usage accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).

The installed grid was also configured through Computer Use against an isolated synthetic server, without changing the real app's server settings or session. Its window showed all three and then all eight native camera tiles. Each input was H.264 at 2560 × 1440 and 30 fps. Separately sampled app-process results over 20 seconds were:

| Simultaneous visible feeds | CPU, percent of one core | Resident memory | Physical footprint |
|---|---:|---:|---:|
| 3 | 8.9% | 126 MiB | 40 MiB |
| 8 | 19.5% | 144 MiB | 51 MiB |

The fixture confirmed all requested stream connections. A hosted three-camera test accepted 570 samples per camera over 20 seconds, with 10.8% test-process CPU and 131 MiB peak RSS. The corresponding eight-camera hosted test accepted 570 samples per camera, with 22.7% test-process CPU and 142 MiB peak RSS; stopped CPU was 0.9% of one core. These samples verify bounded short runs and visible decoded output, not an all-day or unlimited-camera guarantee. The temporary server was deliberately shut down after each acceptance run; resulting connection-error overlays were expected.

All figures exclude decoder helper processes, WindowServer, GPU activity, and energy usage. They are not whole-system resource totals or a comparison with Rust, Tauri, or the previous dashboard. Moving parsing off the UI actor is intended to improve responsiveness; these small CPU samples do not establish a throughput improvement over the previous native preview.

## Verification and limits

The regular suite passes **42 tests**, with four environment-dependent diagnostics skipped. Run `swift test --no-parallel`: AppKit window tests share application state and must run without unrelated UI tests interleaving. Controlled tests exercise H.264 and H.265 decoding, decoded pixel-buffer dimensions, disconnect/reconnect, stopping and restarting playback, hidden-window shutdown, primary-server failure and backup selection, malformed/truncated/oversized fragments, and the retry limit after repeated stalls. A hosted SwiftUI window is minimized, restored, hidden, shown, and closed through actual AppKit calls. Separate tests check remembered stream choices and simulated workspace wake recovery. Existing cookie-renewal, certificate/origin isolation, visibility, and real WebKit blocked-JavaScript recovery tests also run. Repeated browser-page recovery unloads the page after its budget is exhausted.

The app was installed locally, configured, and signed in through Computer Use. The three real camera tiles appeared. One real feed displayed advancing timestamps for several minutes, remained responsive to camera selection, and resumed after hiding and reopening without another sign-in. Testing found and corrected camera-grid visibility callbacks and a decoder path that treated recoverable damaged frames as fatal. Actual installed-app failure logs include transport status and counts, without server addresses, camera IDs, cookies, or media payloads.

The real-server check is **partial**, not an all-camera success. Other stream attempts completed the WebSocket handshake but sent only a 671-byte initialization header before timing out. An independent raw WebSocket check received video from two cameras and only the header from another; the server also reported zero incoming camera FPS for one camera. These observations show intermittent or unavailable upstream video, but do not establish a complete diagnosis of the server. Native playback cannot display frames that do not arrive. No server camera settings or credentials were changed.

Controlled grid tests cover three simultaneous feeds, independent reconnects, hidden/minimized/restored/closed windows, and scrolling a nine-camera grid so offscreen decoders stop and newly visible tiles start. A missing-initial-keyframe test checks that playback waits for a later keyframe without disconnecting a healthy stream. Certificate tests cover macOS reporting an untrusted peer certificate as a general TLS failure without weakening approval rules.

No all-day soak test, runtime test on Intel, or acceptance test on the Mac that originally froze has been completed. The native release remains a prerelease. A blocked native app main thread cannot be repaired by an in-process watchdog. Lower-bandwidth camera substreams and shorter keyframe intervals can reduce decode work and startup delay; [Frigate's live-view documentation](https://docs.frigate.video/configuration/live/) explains those settings.

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

To sample simultaneous synthetic feeds in the hosted grid:

```sh
FRIGATE_GRID_BENCHMARK_MP4=/tmp/frigate-synthetic-benchmark.mp4 \
  FRIGATE_GRID_BENCHMARK_COUNT=8 \
  swift test --filter simultaneousNativeGridResourceSample
```

The diagnostic accepts up to 16 generated streams; this is a test bound, not a limit in the app.
