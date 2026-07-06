# TileCam

**Every camera you own, tiled into one calm grid — on iPhone, iPad, Mac, and Apple Watch.**

TileCam is a native camera-wall app for Apple platforms. Point it at your own
[go2rtc](https://github.com/AlexxIT/go2rtc) server and it pulls all your cameras —
Tapo, Reolink, UniFi, Amcrest, Hikvision, or anything that speaks ONVIF / RTSP — into
a single adaptive grid that looks and feels like an Apple app, not a security panel.
Your video streams directly between your device and your own server over WebRTC; nothing
is routed through anyone else.

- **Platforms:** iOS 17+ (iPhone, iPad, Mac Catalyst), watchOS 10+. Dark mode only.
- **Stack:** SwiftUI (no UIKit), WebRTC ([stasel/WebRTC](https://github.com/stasel/WebRTC)) via SPM.
- **Backend:** your own go2rtc instance — free and open source.

## Features

- **One grid, not five apps** — an adaptive layout that reflows to fit however many cameras you point it at.
- **Zoom & pan** — pinch into any live feed to read a label or check a face; it remembers where you left each tile.
- **Motion visualization** — a breathing magnifier, directional motion flow, and an intensity heatmap, right on the feed.
- **Picture-in-Picture** — float a camera in the corner while you do everything else.
- **Live audio** — two-way audio on cameras that support it, with per-stream mute and level metering.
- **On your wrist** — a watchOS companion relays feeds from your iPhone over Bluetooth for a quick live look.

## Building it yourself

TileCam is **free** on the App Store for iPhone, iPad, and Mac. The Apple Watch companion
is unlocked by a single one-time in-app purchase — that's how the project keeps the lights on.

But it's all here in the open. If you'd rather build TileCam from source and run it on your
own devices, go right ahead — that's exactly why this is public. You'll need:

- Your own **Apple Developer account** to sign device builds.
- Your own **go2rtc server** with your cameras configured.

The Watch unlock is just a StoreKit product (see [`TileCam.storekit`](TileCam.storekit)) —
building from source, it's yours to flip on. Buying it on the App Store is a lovely way to
support the work, but if you're compiling it yourself, don't sweat the payment side.

## Build

The Xcode project is **generated** — [`project.yml`](project.yml) is the source of truth,
`TileCam.xcodeproj` is produced by [xcodegen](https://github.com/yonom/xcodegen). Don't
hand-edit the `.pbxproj`.

```sh
brew install xcodegen        # once
xcodegen generate            # regenerate the project after changing project.yml or adding files
```

Open `TileCam.xcodeproj` and build the `TileCam` scheme to a device or Mac. A signing-free
compile check (no device or Apple ID needed):

```sh
xcodebuild -project TileCam.xcodeproj -scheme TileCam \
  -sdk iphoneos -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Bundle IDs are `works.rainn.tilecam` and `works.rainn.tilecam.watchkitapp` — change these
to your own in `project.yml` for a personal build.

## Architecture

```
GlassView/
  App/        — app entry (TileCamApp.swift)
  Models/     — data models (Stream.swift)
  Services/   — session, WebRTC, go2rtc, audio, motion analytics
                (PhoneSessionManager, WebRTCClient, Go2RTCService, PiPManager,
                 EulerianMagnifier, MotionAnalyzer, MotionFlowAnalyzer, …)
  Views/      — SwiftUI UI (ContentView, StreamTileView, Components/…)
TileCamWatch/ — the watchOS app (WatchSessionManager handles iPhone↔Watch sync)
```

New source files are picked up by directory — drop them in the right folder and run
`xcodegen generate`.

## Design

The UI is dark-mode-only glassomorphism: opacity as hierarchy, spring-loaded interactions,
44pt touch targets, and a consistent set of spacing / radius / duration tokens. It aims to
feel like a native Apple app, not a security panel.

## Backend setup

You bring your own [go2rtc](https://github.com/AlexxIT/go2rtc) server. Add your cameras to its
`go2rtc.yaml` (RTSP / ONVIF / etc.), point the app at the server's URL, and the camera list
loads automatically. Video flows device ↔ server over WebRTC — it never leaves your network
unless you route it off yourself.

## Release automation

CI builds and ships to TestFlight via [fastlane](fastlane/) on a `v*` tag — see
[`fastlane/SETUP.md`](fastlane/SETUP.md). App Store signing for CI uses `match` with a
**separate private** certificates repo (signing material is never committed here).

## License

**Source-available** under the [PolyForm Noncommercial License 1.0.0](LICENSE). Build it,
modify it, run it, and share it for any **noncommercial** purpose — personal use, hobby
projects, study, research. Commercial use (reselling it, or shipping it for a fee) isn't
granted by the license; that's what the App Store build is for. Not affiliated with go2rtc.
