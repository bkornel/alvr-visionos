# AR mode setup checklist

Everything that has to be non-default for the alpha stream passthrough to work, on the PC side.
The client half is covered by [AR_MODE_HANDOFF.md](AR_MODE_HANDOFF.md); this is the streamer,
SteamVR and Ridge configuration that surrounds it.

Defaults quoted below are the ones in `alvr/session/src/settings.rs`, not the values that happen
to be in a given `session.json`.

## 1. ALVR dashboard

| Setting | Default | Set to | Why |
|---|---|---|---|
| Video → **Passthrough** | off, `Blend` | **on, `Alpha Stream (8 bit)`** | the feature itself |
| ↳ Premultiplied alpha | `false` | **`false`** | Ridge submits its layer with `XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT`, so the client does the premultiply |
| ↳ Alpha stream bitrate | `10` Mbps | `10` | raise only if the mask looks blocky or ringed |
| Video → **Preferred codec** | `H264` | **`HEVC`** | the AVP decodes it cleanly, and the AV1 alpha path needs the empty-decoder-config workaround |
| Video → **Foveated encoding** | **on** | **off** | alpha is extracted *after* FFR, so a 4-5x downsampled periphery bleeds opaque edges into the mask |
| Video → Preferred FPS | `72` | `90` | matches the headset; silences `Chosen refresh rate not supported` |
| Extra → Logging → **Log to disk** | `false` in release | **`true`** | without it there is no `session_log.txt` and the alpha warnings disappear with the dashboard window |
| Headset → **Controllers** | on | either | needs a **SteamVR restart** to take effect. Turning it off removes the emulated controllers, and with them the two-hand-pinch gesture that closes the SteamVR dashboard |

Leave at default: bitrate `ConstantMbps 30`, rate control `Cbr`, `use_10bit` off, colour correction
off, clientside foveation / post-processing / upscaling all off, view resolution `Absolute 2144`,
`max_buffering_frames 2`, `enforce_server_frame_pacing` on, `startup_video_recording` off.

`capture_frame_dir` does nothing on Windows — it is read only by the Linux encoder, and the
Debug tab's **Capture frame** button is an empty stub there (`platform/win32/CEncoder.cpp`).
Use Debug → **Start recording** / **Stop recording** instead: it writes `recording.<stamp>.h265`
and `recording.<stamp>.alpha.h265` side by side next to `ALVR Dashboard.exe`. The alpha file plays
as greyscale — white where the app is opaque, black where the room should show through.

## 2. SteamVR

| Item | Action |
|---|---|
| ALVR driver | registered in `openvrpaths.vrpath` (Dashboard → Installation) |
| Add-ons → `alvr_server` | **On** |
| Add-ons → **Gamepad Support** | **Off** — otherwise SteamVR claims the Xbox pad and Ridge never sees it through `Windows.Gaming.Input` |
| Add-ons → **varjo** | **Off** while testing — a competing HMD driver, and the source of the unknown-hardware prompts |
| **SteamVR Home** | **disabled** (`enableHomeApp: false`) — Home renders an opaque environment straight over passthrough |
| Advanced Settings | **Show**, to reach Manage Add-ons under Startup / Shutdown |
| **Firewall rules** | add them (Dashboard → Installation). Needs elevation, and domain policy can override locally added inbound rules |

Add-ons live under Settings → Startup / Shutdown → Manage Add-ons. Settings → Controllers has only
binding tools, no driver toggle.

## 3. Ridge

Both of these default to on and both make the frame fully opaque, so alpha never has anything to
carry:

- `Graphics.SkyRenderingMode` = **`Off`** (values: `Off` / `SkyOnly` / `SkyAndClouds`)
- deferred rendering **off**

Nothing switches these automatically. SteamVR only advertises
`XR_ENVIRONMENT_BLEND_MODE_OPAQUE`, so `XrEngine` never selects `ALPHA_BLEND` and Ridge never
learns it is in AR mode. Only `PresetKind::Hololens` turns the sky off, and that preset is chosen
solely for `device_class::hololens_1/2`.

## 4. Two rules that decide whether a test is valid

**Close the SteamVR dashboard before judging passthrough.** With no scene app attached the
compositor draws its own aurora/grid environment — fully opaque, and dark enough to be mistaken for
a dimly lit room. Overlay layers also replace destination alpha
(`SrcBlendAlpha = ONE, DestBlendAlpha = ZERO` in `FrameRender.cpp`), so anything SteamVR draws
blocks passthrough by construction.

**Confirm Ridge attached as a scene app** before trusting anything you see:

```powershell
Select-String "C:\Program Files (x86)\Steam\logs\vrserver.txt" -Pattern 'VRApplication_Scene|Holomaps|\[OpenXR\]'
```

All three empty means Ridge never connected and you are looking at SteamVR, not Ridge.

## 5. Log lines worth knowing

| Line | Meaning |
|---|---|
| `Alpha stream announced, decoder ready: true` | config arrived, client session built |
| `create decoder ... alpha: true` | the DecoderConfig event carried the alpha stream kind |
| `The alpha stream passthrough mode is not supported by the client` | capability negotiation failed, streamer fell back to no passthrough |
| `Dropping alpha video packet. Reason: Can't push to network` | alpha starving. Once per frame forever means the channel is disconnected; bursts mean congestion |
| `Latency is too high. Clamping prediction` | motion-to-photon above `max_prediction_ms` (100). Two concurrent decode sessions on the AVP are the prime suspect |

Nothing logs the colour/alpha timestamp relationship, so stream desync is silent on both sides.
