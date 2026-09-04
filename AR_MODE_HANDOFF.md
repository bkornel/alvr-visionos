# AR mode (alpha stream passthrough) on Apple Vision Pro — handoff

Branch: `ar_mode` on `bkornel/alvr-visionos`. First written 2026-09-01 on a Windows machine with
none of it compiled; **built, signed, deployed to an Apple Vision Pro and validated end to end on
2026-09-03**. AR mode works: opaque parts of the PC image render normally, alpha-zero parts show
the room. Sections below marked *Resolved* record what the first run settled; the remaining open
risks are in §7.

Goal: port axodox's `ar_mode` ALVR modification — full 8 bit alpha streamed as a second
monochrome video stream, so transparent parts of the PC image show real passthrough — from the
working Android/OpenXR client to a Vision Pro client. The streamer side already existed and is
unchanged by this work.

---

## 1. Repos, branches, remotes

| Repo | Branch | Remote layout | Contains |
|---|---|---|---|
| `bkornel/ALVR` | `ar_mode_visionos` | `origin` = bkornel/ALVR, `axodox` = axodox/ALVR | axodox `ar_mode` (server + Android client + protocol) **+ 1 commit** of client C API work |
| `bkornel/alvr-visionos` | `ar_mode` | `origin` = bkornel fork, `upstream` = alvr-org | **1 commit**: the visionOS client half |

Do **not** push to `alvr-org/alvr-visionos` or `axodox/ALVR`. Both upstreams are read-only here.

The client's `ALVR` submodule points at `bkornel/ALVR` @ `ar_mode_visionos`
(commit `a3aed5d3`), declared in [.gitmodules](.gitmodules).

## 2. Why the submodule had to move (read this before touching anything)

`alvr-visionos/main` pinned its `ALVR` submodule to **svrc's v20.14.1 fork**, not to ALVR master.
`ar_mode` is based on current master. ALVR's handshake compares `protocol_id_u64()`, a hash of the
major version, so a v20 client and a master-line streamer never connect — the alpha feature was
unreachable without bumping the core. Every alvr-visionos branch (`main`, `v20`, `appstore`,
`nightly-old`, …) pins a v20-era core, so there was no ready-made master-based client to start from.

The v20 → master C API drift turned out small, because the visionOS client already predicts poses
itself and calls `alvr_send_view_params` — exactly what master's core expects after prediction moved
out of `ClientCoreContext::send_tracking` into the clients. Four things actually changed:

1. `AlvrClientCapabilities` gained `max_view_width`/`max_view_height`, lost `prefer_full_range`.
2. `AlvrCodec` → `AlvrCodecType`, so the generated constants became `ALVR_CODEC_TYPE_*`.
3. `alvr_send_active_interaction_profile` gained an input-id array (the streamer builds its
   automatic button mapping from it).
4. `alvr_send_tracking_and_face_data` no longer exists on master — re-added, see below.

Deliberately **not** carried over from the v20 fork: svrc's CoreAudio visionOS workaround
(`412180f5`, ~160 lines in `alvr/audio`, fixes audio dying after a crown double-tap), the
`PSVR2Sense` controller-emulation settings variant, and two tuning hacks in `send_tracking`
(a 90 ms prediction clamp and disabled tracker prediction) that master's model makes moot.

## 3. What the change does

Streamer side (already in `ar_mode`, unchanged): the base layer's alpha survives compositing, is
extracted to its own texture after foveation but before YUV conversion, encoded by a second encoder
at a fixed bitrate, and sent on a new `VIDEO_ALPHA = 5` stream with the same timestamps and IDR
decisions as the color stream. Handshake negotiation is additive JSON: the client advertises
`alpha_stream`, the streamer replies `enable_alpha_stream`.

Core (`bkornel/ALVR` @ `ar_mode_visionos`, commit `a3aed5d3`) — the C API had no access to any of it:

- `AlvrEvent::DecoderConfig` now reports `stream` (`ALVR_VIDEO_STREAM_KIND_COLOR` / `_ALPHA`).
- Color and alpha decoder configs are held in **separate** buffers, because both are emitted
  back-to-back at stream start and a shared buffer loses one. New `alvr_get_alpha_decoder_config`.
- New `alvr_set_alpha_decoder_input_callback`. Setting it requests an IDR — the alpha encoder is
  created after the color one and misses the keyframe emitted at stream start, and a decoder emits
  nothing until it sees one. (The retry loop for that lives in the Rust alpha receive thread.)
- `alpha_stream` became a real `ClientCapabilities` field instead of the hardcoded `true` in
  `client_core/src/connection.rs`. The OpenXR client passes `true`, so Android is unchanged.
- `alvr_send_tracking_and_face_data` restored: two eye gaze poses + 70 Meta-style expression
  weights. Mapped onto master's `FaceData` as `eyes_social` for the pair and `eyes_combined` from
  the left eye (visionOS derives both from one ARKit gaze ray). The capi conversions it shares with
  `alvr_send_tracking` were factored into `device_motions_from_capi` / `hand_skeletons_from_capi`.

Client (this branch, 10 files):

- [ALVRClient/EventHandler.swift](ALVRClient/EventHandler.swift) — second `VTDecompressionSession`,
  fed by `handleAlphaNals`. Decoded frames go into `alphaFrameQueue` (capped at 4).
  `dequeueAlphaFrame(targetTimestamp:)` drops frames older than the color frame, holds back a frame
  that is genuinely ahead, and returns the previous alpha when nothing matches — alpha must never
  stall color presentation. A frame more than a second ahead is treated as a timestamp-domain
  mismatch and consumed rather than held forever (same rule as the Android implementation).
  `alphaStreamLumaRange()` derives the luma range correction from the alpha stream's own format
  description.
- [ALVRClient/Shaders.metal](ALVRClient/Shaders.metal) — `sampleStreamAlpha` samples the alpha
  plane with the **same FFR-corrected UV** as the color (both streams share the encoding layout),
  expands its range, and `videoFrameFragmentShader_common` returns premultiplied color plus that
  alpha. Gated by the `ALPHA_STREAM_ENABLED` function constant; takes precedence over chroma key.
- [ALVRClient/Renderer.swift](ALVRClient/Renderer.swift) — pairs the alpha frame in `renderFrame`,
  binds its luma plane at `TextureIndexAlpha` (always bound; a 1×1 opaque texture stands in when
  there is no frame, since sampling an unbound texture returns zero and would blank the image),
  clears the pass to transparent, and rebuilds the pipeline when the alpha stream appears.
- [ALVRClient/Settings.swift](ALVRClient/Settings.swift) — decodes `video.passthrough.AlphaStream`
  for `premultiplied_alpha`.
- [ALVRClient/GlobalSettings.swift](ALVRClient/GlobalSettings.swift) +
  [ALVRClient/Entry/Entry.swift](ALVRClient/Entry/Entry.swift) — "Enable Alpha Stream Passthrough"
  toggle, default on, fed into the advertised capability.
- [ALVRClient/ShaderTypes.h](ALVRClient/ShaderTypes.h) — `TextureIndexAlpha` + three function
  constants. Note `TextureIndexColor` doubles as the luma index; duplicate raw values in an
  `NS_ENUM` do not import cleanly into Swift, so no alias was added.
- [ALVRClient/VideoHandler.swift](ALVRClient/VideoHandler.swift),
  [ALVRClient/WorldTracker.swift](ALVRClient/WorldTracker.swift),
  [ALVRClient/Input/InputSink.swift](ALVRClient/Input/InputSink.swift) — the C API migration.

All three codecs work; the alpha stream reuses the color codec path. HEVC is the straightforward
one. AV1 is awkward: the streamer sends an empty alpha decoder config, so the session can only be
built from the first frame (`alphaAv1InstantiatedForReal`). **Test on HEVC first** to isolate the
alpha logic from that.

The RealityKit renderer is untouched and stays opaque — only the Metal renderer (the default,
`realityKitRenderer = false`) implements the alpha path. It shares the fragment shaders, so it
binds the opaque stand-in and behaves exactly as before.

## 4. Build on macOS

Prerequisites:

- Xcode with a visionOS SDK, plus command line tools (`xcode-select --install`).
  The project compiles `#if XCODE_BETA_26` code by default (see §5), so Xcode 26 or newer.
- The **Metal toolchain**. Xcode 26 no longer bundles the Metal compiler; it is a separate
  downloadable component, and without it
  [ALVRClient/Shaders.metal](ALVRClient/Shaders.metal) fails with
  `error: cannot execute tool 'metal' due to missing Metal Toolchain`. This has nothing to do with
  this branch — every fresh Xcode 26 machine hits it — but it surfaces late, after all the Swift
  targets have already compiled, so it reads like a shader problem. Install it once (~690 MB):

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
- Rust **1.92 or newer** — the ALVR workspace declares `edition = "2024"`,
  `rust-version = "1.92"`. `rustup update stable`.
- `cbindgen` (the build script installs it if missing).

```bash
git clone -b ar_mode https://github.com/bkornel/alvr-visionos.git
cd alvr-visionos
git submodule update --init --recursive     # pulls bkornel/ALVR @ ar_mode_visionos
./build_ar_mode.sh                          # Rust core -> xcframework -> app
```

[build_ar_mode.sh](build_ar_mode.sh) is a friendlier version of the repo's own
`build_and_repack.sh`: it does not wipe `ALVR/target` on every run, checks the toolchain, and can
build/install the app. `./build_ar_mode.sh core` does only the Rust half,
`./build_ar_mode.sh app` only the Xcode half, `CLEAN=1` forces a full Rust rebuild.
It was written without a Mac to test on — if it misbehaves, the original two-script flow
(`./build_and_repack.sh`) still works and is authoritative.

How the Rust half actually works, since it looks wrong at first glance: `alvr_client_core` is built
for **`aarch64-apple-ios`** as a `cdylib`, and `repack_alvr_client.sh` re-stamps the Mach-O platform
with `xcrun vtool -set-build-version visionos` before assembling
`ALVRClient/ALVRClientCore.xcframework` (ios / maccatalyst / xros / xrsimulator slices). There is no
visionOS Rust target involved. The generated header comes from cbindgen, at
`ALVR/build/alvr_client_core.h`.

**First thing to check after the first successful cbindgen run** — the generated constant names,
which this port assumed:

```bash
grep -nE 'ALVR_CODEC_TYPE_|ALVR_VIDEO_STREAM_KIND_|alvr_get_alpha_decoder_config|alvr_set_alpha_decoder_input_callback|alvr_send_tracking_and_face_data' ALVR/build/alvr_client_core.h
```

Expected: `ALVR_CODEC_TYPE_H264` / `_HEVC` / `_AV1`, `ALVR_VIDEO_STREAM_KIND_COLOR` / `_ALPHA`
(cbindgen's `rename_variants = "QualifiedScreamingSnakeCase"`). If they differ, it is a pure rename
across `EventHandler.swift` and `VideoHandler.swift`.

## 5. Signing and sideloading

A local build needs your own signing identity, and **`DEVELOPMENT_TEAM` is deliberately not in the
repo**. Put it in `Override.xcconfig`, which is gitignored and included last by
`ALVRClient.xcconfig`:

```
// Override.xcconfig
DEVELOPMENT_TEAM = <your 10-character team id>
```

Find the team id at developer.apple.com/account → Membership details, or let Xcode write it by
picking the team in Signing & Capabilities — but then move it out of the pbxproj again, so nobody
publishes their employer's team id by accident.

Both targets read that xcconfig. `DEVELOPMENT_TEAM` was removed from all four pbxproj build
configurations and the ALVREyeBroadcast configurations were given
`baseConfigurationReference = ALVRClient.xcconfig`; without that the extension fails with
*"Signing for ALVREyeBroadcast requires a development team"* while the app target builds fine.

The bundle ids are neutral placeholders and only need changing if they collide with something your
team has already registered — App IDs are unique across all Apple teams:

| Target | Bundle id |
|---|---|
| ALVRClient | `dev.alphastream.client` |
| ALVREyeBroadcast | `dev.alphastream.client.ALVREyeBroadcast` |
| App group (both entitlements) | `group.dev.alphastream.client` |

The extension's id must stay prefixed by the app's. The upstream ids (`alvr.client`) cannot be used
at all: they belong to the ALVR team's App Store record, so automatic signing cannot register them
for anyone else.

Entitlements that commonly block a first local build:

- `com.apple.security.application-groups` = `group.dev.alphastream.client`, in **both**
  [ALVRClient/ALVRClient.entitlements](ALVRClient/ALVRClient.entitlements) and
  `ALVREyeBroadcast/ALVREyeBroadcast.entitlements`. App groups require a **paid** membership and a
  globally unique id; if you rename it, keep both files identical.
- `com.apple.developer.low-latency-streaming` — if provisioning refuses it, delete the key. It is a
  networking QoS hint; streaming works without it.
- On a **free** account, app groups are unavailable at all. Then remove the app group from both
  entitlements files and remove ALVREyeBroadcast from the app target's *Embed Foundation
  Extensions* phase. That loses ReplayKit-based eye tracking, which AR mode does not need. Free
  provisioning also expires after 7 days.

Deploying to the headset (`XROS_DEPLOYMENT_TARGET` is 2.0, `TARGETED_DEVICE_FAMILY = 7`):

1. On the Vision Pro: Settings → Privacy & Security → **Developer Mode** on, then reboot.
2. Pair it over Wi-Fi. **There is no USB-C option**: the Vision Pro's built-in port is battery
   only, and wired development needs the separately sold Developer Strap.

   **Initiate the pairing from the headset**, not from the Mac: Settings → General →
   **Remote Devices**, with Xcode's Window → Devices and Simulators open on the Mac. On a
   corporate network the Mac←headset direction is often the broken one — mDNS from the headset
   never arrives, so it simply never appears in Xcode, while the Mac's own advertisement still
   reaches the headset. Verified on CAE's network: `ping` and ARP to the headset worked with 0%
   loss while `_remotepairing._tcp` and `_apple-mobdev2._tcp` returned nothing at all. Unicast
   forwarded, multicast filtered. If neither direction works, put both devices on a phone
   hotspot.
3. Xcode: select the ALVRClient scheme and the device, then Run. Approve the developer certificate
   on the device the first time (Settings → General → VPN & Device Management).
4. Headless equivalent:
   ```bash
   xcrun devicectl list devices                       # copy the identifier
   DEVICE_UDID=<identifier> ./build_ar_mode.sh install
   ```

The app asks for hands / world sensing / camera permissions on first launch
(`NSHandsTrackingUsageDescription` and friends in [ALVRClient/Info.plist](ALVRClient/Info.plist)).

`ALVRClient.xcconfig` optionally includes `AppStore.xcconfig`, which **is** present in the repo and
sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS = IS_ALVR_APPSTORE XCODE_BETA_16 XCODE_BETA_26
XCODE_BETA_27`. It also optionally includes a gitignored `Override.xcconfig`, included last.

**Do not drop `XCODE_BETA_26` to work around visionOS 26 API.** An earlier version of this document
suggested an `Override.xcconfig` setting `SWIFT_ACTIVE_COMPILATION_CONDITIONS = XCODE_BETA_16`.
That no longer compiles — `accessoryTracking` and `queuedFrame` are declared inside
`#if XCODE_BETA_26` blocks but referenced outside them (9 errors). It is also unnecessary: every
visionOS 26 call site is already guarded at runtime by `if #available(visionOS 26.0, *)` with a
pre-26 `else`, `accessoryTracking` is deliberately typed `(any DataProvider)?` rather than
`AccessoryTrackingProvider?`, and the `@available` on `WorldTracker` is commented out on purpose.
Verified running on **visionOS 2.3.2** with the stock `XCODE_BETA_26` build.

`XCODE_BETA_27` is referenced by no Swift code; `IS_ALVR_APPSTORE` gates nothing.

**Apple Developer Enterprise Program teams** cannot use `com.apple.developer.low-latency-streaming`
at all — provisioning refuses to create a profile while the key is present
(*"Enterprise development teams do not support the Low-Latency Streaming capability"*). Delete it.
App groups do work on an Enterprise team, and a plain Developer-role member was able to register
new bundle ids and the app group through automatic signing.

## 6. Running and verifying

Streamer: build from `ar_mode` (or `ar_mode_visionos` — identical protocol, the extra commit is
client-only), then in the dashboard set Settings → Video → **Passthrough → Alpha Stream (8 bit)**,
with its bitrate and `premultiplied_alpha`. The PC application has to actually author an alpha
channel; in this mode ALVR stops masking the base layer's alpha off and clears to transparent
instead of MidnightBlue.

Client: the "Enable Alpha Stream Passthrough" toggle in the entry UI must be on (it is by default).
It is read when `alvr_initialize` runs, so toggle it before connecting.

**Restart the streamer between test runs** if it predates commit `03135c66`. Before that fix the
alpha sender was never cleared on disconnect, so after any reconnect every `send_alpha_video_nal`
hit a dead channel and no alpha reached the client until the process restarted — a second
connection would look like a total alpha failure rather than a desync.

What correct looks like: opaque parts of the PC image render as usual, alpha-zero parts show the
room, semi-transparent parts blend. Logs worth grepping:

- `Alpha stream announced, decoder ready: true` — the config arrived and the session was built.
- `create decoder ... alpha: true` — the DecoderConfig event carried the alpha stream kind.
- The streamer warns `The alpha stream passthrough mode is not supported by the client` when the
  capability negotiation failed; it then falls back to no passthrough.

## 7. Risks, resolved and open

Resolved by the first device run (HEVC, visionOS 2.3.2, 90 Hz):

1. **Generated constant names** — *Resolved.* All five names this port assumed exist verbatim. The
   grep in §4 is now a regression check rather than a question.
2. **Premultiplied vs straight alpha** — *Resolved in practice.* Composition is correct with the
   streamer's default; no glowing edges or washed-out colour. The inference held.
3. **Two concurrent hardware decode sessions** — *Resolved, and it was the real bug, though not in
   the way this section predicted.* Two sessions at 90 Hz do keep up — no starvation, one dropped
   alpha frame in 28k — but the alpha frame for timestamp T **lands after the renderer has already
   committed colour T**. `dequeueAlphaFrame` then substituted the previous alpha, compositing
   colour T with the mask from T−1. Because AR mode clears the base layer to transparent, pixels
   where the stale mask said opaque but the new colour held background came out as **opaque black
   in the shape of the object's silhouette** — visible on every head movement, invisible while
   still, since consecutive frames are nearly identical.

   Measured: 27% of frames mispaired, lag quantised to exact frame periods (11.11 / 22.22 ms at
   90 Hz), alpha queue empty at dequeue. Fixed by holding each colour frame in a delay line for
   `EventHandler.alphaPairingDelayFrames` (default 2) so the matching alpha has time to arrive:
   **100% exact pairing, mean lag 0.00 ms**, at the cost of ~22 ms latency. Set it to 1 to halve
   the latency and recover roughly half the mispairs, or 0 for the old behaviour. The
   streamer-side fallback this section proposed — packing alpha into the colour frame — was not
   needed.
4. **Decoder frame identity** — *Was an unverified assumption, now fixed.* Sample buffers carried
   no PTS (`sampleTimingEntryCount: 0`) and the decoder's `presentationTimeStamp` was ignored, so a
   decoded frame was identified only by whichever timestamp the callback closure happened to
   capture. Measurement showed the decoders are in fact strictly in order (`out of sync 0` over
   28k frames on both streams), but nothing had verified that, and without a PTS VideoToolbox
   cannot reorder output at all. Frames are now stamped on input and identified by the PTS
   returned on output.

Still open:

5. **Luma range.** The client expands video-range luma using the alpha stream's format description;
   the Android implementation skips range expansion entirely. Nothing anomalous observed, but
   partial transparency was not deliberately tested. If alpha reads grey or clipped, look at
   `alphaStreamLumaRange()`.
6. **AV1 and H.264 are untested.** Only HEVC has been run. AV1 remains the awkward one — the
   streamer sends an empty alpha decoder config, so the session can only be built from the first
   frame (`alphaAv1InstantiatedForReal`).
7. **Face/eye tracking**, because of the restored C API shim and the `eyes_combined` choice. It
   drives foveated encoding, so a regression shows up as wrong foveation, not just missing
   expressions.
8. **Audio after a crown double-tap** may be broken — svrc's CoreAudio workaround was not ported.

## 8. If you are a Claude session picking this up

The work above is committed and pushed; there is no work-in-progress state to reconstruct. Useful
context that is not in the diffs:

- The upstream v20 fork's patches were reviewed one by one and only the face-tracking C API was
  judged necessary; the rest is listed at the end of §2 with reasons.
- The Android implementation of this feature is the reference for every pairing/timing decision:
  `alvr/client_openxr/src/stream.rs` (`dequeue_alpha_frame`), `alvr/graphics/src/stream.rs` and
  `alvr/graphics/resources/stream.wgsl` in the submodule. Deviations from it in the Swift code are
  deliberate and commented.
- It compiles clean and runs. Toolchain used: Xcode 26.6, visionOS 26.5 SDK, Rust 1.98, on
  visionOS 2.3.2. There were no Swift or Metal compile errors on the first attempt; the only build
  blocker was the missing Metal toolchain component (§4).
- **Client logging is filtered twice, and both defaults hide everything.** `env_logger` defaults to
  `Error` when `RUST_LOG` is unset — fixed on the submodule branch, since that filter also gated
  the `send_log` call that forwards to the streamer. Then, once connected, `send_log` consults the
  *streamer's* `client_log_report_level`, which also defaults to `Error`
  (`alvr/session/src/settings.rs`) and whose `false` return suppresses the stderr write as well.
  So `alvr_log` at Info or Warn reaches nowhere by default. Swift `print()` bypasses both and shows
  up reliably; raise the dashboard setting to Info if you want `alvr_log` in `session_log.txt`.
- **Reading logs off the headset**: `log stream` has no device option and `devicectl` cannot attach
  to a running process, so the only route is
  `xcrun devicectl device process launch --console dev.alphastream.client`, which relaunches the app.
- The pairing and decoder-identity diagnostics that produced the numbers in §7 are still in the
  code, switched on by the streamer's **Settings → Extra → Logging → client log report level**
  being `Info` or `Debug` (`Settings.verboseDiagnostics`). That is deliberately the same value
  that decides whether `alvr_log` survives the core's filter, so diagnostics cannot be "on" yet
  invisible.

  **The level is only picked up at stream start**, so change it in the dashboard and then
  reconnect. `alvr_get_settings_json` is written once per `StreamingStarted`
  (`client_core/src/c_api.rs`), and although `client_log_report_level` is flagged `real-time` in
  the schema it is not part of `RealTimeConfig`, whose payload the C API discards into an empty
  `AlvrEvent::RealTimeConfig {}` anyway. Making it live would mean adding the field to
  `RealTimeConfig::from_settings`, carrying the payload through the C API and refreshing
  `SETTINGS` — judged not worth the permanent protocol surface for a debugging toggle.
