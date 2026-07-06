# App Store Connect — TileCam metadata (v1.0)

App: **TileCam · Camera Wall** · Apple ID 6787999557 · bundle `works.rainn.tilecam`
Provider: RainnWorks (team 53W966FBFP)

## Listing fields

**Name** (30): `TileCam · Camera Wall`
**Subtitle** (30): `Every camera, one calm grid`
**Primary category:** Photo & Video   **Secondary:** Utilities
**Age rating:** 4+

**Support URL:** https://rainn.works/tilecam/support.html
**Marketing URL:** https://rainn.works/tilecam/
**Privacy Policy URL:** https://rainn.works/tilecam/privacy.html

**Promotional text** (170, editable anytime):
> Pull every camera you own into one calm grid on iPhone, iPad, Mac, and Apple Watch. Point your own go2rtc server at any RTSP/ONVIF camera — your video stays on your network.

**Keywords** (100, comma-separated, no spaces):
`camera,cctv,rtsp,onvif,go2rtc,webrtc,security,nanny,ip camera,viewer,grid,nvr,live,monitor`

**Description** (4000):
```
Every camera, tiled. On every Apple device.

TileCam pulls all your cameras into one calm grid that looks and feels like an Apple app — not a security panel. Point your own go2rtc server at whatever cameras you already own and watch them all at once on iPhone, iPad, Mac, and Apple Watch.

WORKS WITH THE CAMERAS YOU HAVE
Tapo, Reolink, UniFi, Amcrest, Hikvision — or any ONVIF / RTSP camera. If go2rtc can see it, TileCam can tile it. Mix a €200 pro camera with an €18 budget one; it all lands in the same grid.

YOUR VIDEO, YOUR NETWORK
TileCam connects to your own go2rtc server over WebRTC. Your footage never leaves your network and nothing is routed through us. Block a cheap camera from the internet and still watch it beautifully.

ONE GRID, NOT FIVE APPS
• Tile them all — an adaptive grid that reflows to fit: one full-screen, four in a 2×2, however many you point it at.
• Zoom & pan — pinch into any live feed to read a label, check a face, or watch the cot. It remembers where you left each one.
• Motion visualization — spot subtle movement at a glance with a breathing magnifier, directional motion flow, and an intensity heatmap, right on the feed.
• Picture-in-Picture — float a camera in the corner and keep half an eye on it while you do everything else.
• Live audio — two-way audio on cameras that support it, with per-stream mute and clean level metering.
• Everywhere you are — iPhone, iPad, and Mac, the same calm grid, in sync.

ON YOUR WRIST
Raise your Apple Watch for a live look at any camera — the cot, the front door, the driveway — without reaching for a phone. Your iPhone relays the feeds over Bluetooth to keep the Watch light on battery.

FREE, WITH ONE OPTIONAL UNLOCK
The iPhone, iPad, and Mac apps are completely free. The Apple Watch companion is a single one-time unlock — buy it once, keep it forever, shareable with Family Sharing. No subscriptions, ever.

Requires your own go2rtc server (free, open-source). Dark mode only.
```

**What's New** (v1.0): `First release of TileCam.`

## App Review Information

- **Sign-in required:** No account/login in the app.
- **Notes to reviewer:**
```
TileCam is a viewer for your own cameras via a go2rtc server (github.com/AlexxIT/go2rtc); it ships with no cameras of its own.

TO TEST:
1. Launch the app. On first run it asks for a server URL — enter:  <DEMO_GO2RTC_URL>
2. The camera list loads automatically; tap the tokens at the bottom to add tiles to the grid. Tiles begin streaming live over WebRTC within a few seconds.
3. Pinch any tile to zoom; tap a tile for full-screen.

IN-APP PURCHASE: "Watch Unlock" (works.rainn.tilecam.watch.unlock, $4.99 non-consumable, Family Shareable) unlocks the Apple Watch app only. The iPhone/iPad/Mac apps are fully functional without it. The purchase UI is reached via the Apple Watch (watch) button in the top bar.

The demo server above is a temporary go2rtc instance with sample public feeds, provided for review.
```
> Replace `<DEMO_GO2RTC_URL>` with the temporary demo server URL once it's live.

## App Privacy (nutrition label)
**Data Not Collected.** TileCam collects no data. Video/audio flows directly between the device and the user's own go2rtc server; nothing is sent to RainnWorks. No analytics, no tracking, no accounts. (Matches privacy.html.)

## Export compliance
Uses only standard encryption (HTTPS/TLS + WebRTC/DTLS-SRTP) → exempt. Set `ITSAppUsesNonExemptEncryption = false` in Info.plist (or answer "No" to the encryption question) to skip the per-build prompt.

## Screenshots required
- iPhone 6.9" (1320×2868 or 2868×1320) — REQUIRED.
- iPad 13" (2064×2752 / 2752×2064) — required if iPad is enabled (it is).
- (Apple Watch screenshots optional but nice for the Watch story.)
