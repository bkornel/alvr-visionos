# AR mode (alpha stream passthrough) on Apple Vision Pro — handoff

Branch: `ar_mode` on `bkornel/alvr-visionos`. Written 2026-09-01 on a Windows machine, so
**none of it has been compiled or run**. Everything below is either verified against the source
or explicitly flagged as an assumption.

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

The project is set up for the ALVR team, so a local build needs your own identity. `DEVELOPMENT_TEAM`
and `PRODUCT_BUNDLE_IDENTIFIER` are set **per target in the pbxproj**, which overrides
`ALVRClient.xcconfig`, so change them in Xcode's UI (Signing & Capabilities), not in an xcconfig:

| Target | Current | Change to something like |
|---|---|---|
| ALVRClient | `alvr.client` | `com.<you>.alvr.client` |
| ALVREyeBroadcast | `alvr.client.ALVREyeBroadcast` | `com.<you>.alvr.client.ALVREyeBroadcast` |

`alvr.client` belongs to the ALVR team's App Store record, so automatic signing cannot register it
for you.

Entitlements that commonly block a first local build:

- `com.apple.security.application-groups` = `group.alvr.client.ALVR`, in **both**
  [ALVRClient/ALVRClient.entitlements](ALVRClient/ALVRClient.entitlements) and
  `ALVREyeBroadcast/ALVREyeBroadcast.entitlements`. App groups require a **paid** Apple Developer
  membership and the id must be unique to your team — rename it to
  `group.com.<you>.alvr.client.ALVR` in both files, keeping them identical.
- `com.apple.developer.low-latency-streaming` — if provisioning refuses it, delete the key. It is a
  networking QoS hint; streaming works without it.
- On a **free** account, app groups are unavailable at all. Then remove the app group from both
  entitlements files and remove ALVREyeBroadcast from the app target's *Embed Foundation
  Extensions* phase. That loses ReplayKit-based eye tracking, which AR mode does not need. Free
  provisioning also expires after 7 days.

Deploying to the headset (`XROS_DEPLOYMENT_TARGET` is 2.0, `TARGETED_DEVICE_FAMILY = 7`):

1. On the Vision Pro: Settings → Privacy & Security → **Developer Mode** on, then reboot.
2. Pair it: connected by USB-C, or Xcode → Window → Devices and Simulators → pair over Wi-Fi
   (the headset must show under Settings → General → Remote Devices).
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
XCODE_BETA_27`. It also optionally includes a gitignored `Override.xcconfig`, included last, so if
the build fails on visionOS 26-only API (`frame.queryDrawables()`, `maxRenderQuality`), create:

```
// Override.xcconfig
SWIFT_ACTIVE_COMPILATION_CONDITIONS = XCODE_BETA_16
```

`XCODE_BETA_27` is referenced by no Swift code; `IS_ALVR_APPSTORE` gates nothing.

## 6. Running and verifying

Streamer: build from `ar_mode` (or `ar_mode_visionos` — identical protocol, the extra commit is
client-only), then in the dashboard set Settings → Video → **Passthrough → Alpha Stream (8 bit)**,
with its bitrate and `premultiplied_alpha`. The PC application has to actually author an alpha
channel; in this mode ALVR stops masking the base layer's alpha off and clears to transparent
instead of MidnightBlue.

Client: the "Enable Alpha Stream Passthrough" toggle in the entry UI must be on (it is by default).
It is read when `alvr_initialize` runs, so toggle it before connecting.

What correct looks like: opaque parts of the PC image render as usual, alpha-zero parts show the
room, semi-transparent parts blend. Logs worth grepping:

- `Alpha stream announced, decoder ready: true` — the config arrived and the session was built.
- `create decoder ... alpha: true` — the DecoderConfig event carried the alpha stream kind.
- The streamer warns `The alpha stream passthrough mode is not supported by the client` when the
  capability negotiation failed; it then falls back to no passthrough.

## 7. Open risks, in the order they are likely to bite

1. **Generated constant names** — see the grep in §4.
2. **Premultiplied vs straight alpha.** The shader premultiplies unless the streamer says the app
   already did. That the visionOS compositor wants premultiplied alpha was *inferred* from the
   existing chroma-key path (which multiplies rgb by its mask). If edges glow or colors wash out,
   flip `premultiplied_alpha` in the streamer settings; if that is wrong in both positions, the
   assumption itself is wrong and `videoFrameFragmentShader_common` needs revisiting.
3. **Two concurrent hardware decode sessions** at full stream resolution and 90–120 Hz is the real
   unknown on AVP. If frames drop, the fallback is a streamer-side change: pack alpha into the
   color frame (an extra strip) so one decoder does both. That is a different design, not a patch.
4. **Luma range.** The client expands video-range luma using the alpha stream's format description;
   the Android implementation skips range expansion entirely. If alpha reads grey or clipped
   (never fully opaque or never fully transparent), look at `alphaStreamLumaRange()`.
5. **Face/eye tracking**, because of the restored C API shim and the `eyes_combined` choice. It
   drives foveated encoding, so a regression shows up as wrong foveation, not just missing
   expressions.
6. **Audio after a crown double-tap** may be broken — svrc's CoreAudio workaround was not ported.

## 8. If you are a Claude session picking this up

The work above is committed and pushed; there is no work-in-progress state to reconstruct. Useful
context that is not in the diffs:

- The upstream v20 fork's patches were reviewed one by one and only the face-tracking C API was
  judged necessary; the rest is listed at the end of §2 with reasons.
- The Android implementation of this feature is the reference for every pairing/timing decision:
  `alvr/client_openxr/src/stream.rs` (`dequeue_alpha_frame`), `alvr/graphics/src/stream.rs` and
  `alvr/graphics/resources/stream.wgsl` in the submodule. Deviations from it in the Swift code are
  deliberate and commented.
- Nothing here has been compiled. Expect a first round of ordinary Swift/Metal compile errors, and
  treat any mismatch against the generated header as the most likely cause.
