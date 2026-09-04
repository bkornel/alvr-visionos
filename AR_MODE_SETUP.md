# AR mode setup checklist

Defaults quoted below are the ones in `alvr/session/src/settings.rs`, not the values that happen to be in a given `session.json`.

## 1. ALVR dashboard

| Setting | Default | Set to | Why |
|---|---|---|---|
| Video → **Passthrough** | off, `Blend` | **on, `Alpha Stream (8 bit)`** | the feature itself |
| ↳ Premultiplied alpha | `false` | **`false`** | Ridge submits its layer with `XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT`, so the client does the premultiply |
| ↳ Alpha stream bitrate | `10` Mbps | `10` | raise only if the mask looks blocky or ringed |
| Video → **Preferred codec** | `H264` | **`HEVC`** | the AVP decodes it cleanly, and the AV1 alpha path needs the empty-decoder-config workaround |
| Headset → **Controllers** | on | either | needs a **SteamVR restart** to take effect. Turning it off removes the emulated controllers, and with them the two-hand-pinch gesture that closes the SteamVR dashboard |

Use Debug → **Start recording** / **Stop recording**: it writes `recording.<stamp>.h265` and `recording.<stamp>.alpha.h265` side by side next to `ALVR Dashboard.exe`. The alpha file plays as greyscale — white where the app is opaque, black where the room should show through.

## 2. SteamVR

| Item | Action |
|---|---|
| ALVR driver | registered in `openvrpaths.vrpath` (Dashboard → Installation) |
| Add-ons → `alvr_server` | **On** |
| Add-ons → **Gamepad Support** | **Off** — otherwise SteamVR claims the Xbox pad |
| **SteamVR Home** or **Dashboard** | **disabled** — Home renders an opaque environment straight over passthrough |
