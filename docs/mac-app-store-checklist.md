# TileCam — Mac App Store release checklist

The Mac (Mac Catalyst) build is a **separate App Store submission surface** from iOS, even though it can share the same app record. This is what it takes to ship it. Items are grouped by who can do them.

## Status (as of this writing)

- ✅ **Builds** as Mac Catalyst (`xcodebuild … -destination 'platform=macOS,variant=Mac Catalyst'`). The watch app is correctly excluded from the Mac embed (`platformFilter: iOS`).
- ✅ **Runs and streams video** — verified on this Mac: connects to go2rtc, all cameras render video, the connection-churn fix holds, audio engine starts.
- ✅ **Catalyst-only** config (Designed-for-iPad turned off).
- ✅ **UI test suite** runs on the Catalyst destination (`scripts/run-mac-ui-tests.sh`) once the desktop session is unlocked.
- ⬜ Everything below.

## Engineering still needed (code/config — can be done without the store)

1. **App Sandbox + entitlements (REQUIRED for Mac App Store).** MAS apps must be sandboxed. Add a Mac entitlements file granting at minimum:
   - `com.apple.security.app-sandbox` = true
   - `com.apple.security.network.client` = true  ← without this the sandbox blocks all outbound connections to go2rtc; the app would silently fail to connect on a MAS build
   - `com.apple.security.device.audio-input` = true  ← if the mic (two-way audio) is used on Mac
   - Wire it via `CODE_SIGN_ENTITLEMENTS` for the Mac Catalyst variant only (the iOS build keeps its own entitlements).
   - **This is the highest-risk item** — sandbox misconfiguration breaks networking at runtime, and it must be tested on an unlocked Mac (ideally a real MAS-signed build), not just compiled.
2. **`ITSAppUsesNonExemptEncryption`** already set (false) — applies to Mac too. ✓
3. **Privacy manifest** (`PrivacyInfo.xcprivacy`) already present — applies to Mac. ✓ Confirm the local-network usage string surfaces correctly on macOS.
4. **Mac UX polish (recommended, not strictly required):** minimum window size (`UIWindowScene.sizeRestrictions.minimumSize`) so the grid can't collapse; a basic menu bar; confirm pointer/trackpad pinch-zoom and the existing keyboard shortcuts (space = toggle controls, esc = close panels) feel right. Best done with eyes on the screen.
5. **In-app purchase on Mac:** the watch unlock has no meaning on Mac (no paired watch). Confirm the paywall/Watch-settings entry point is hidden or inert on Catalyst so it isn't offered where it can't be used. (StoreKit IAP otherwise works on Mac, but this product shouldn't be sold there.)

## Signing & distribution (needs your Apple Developer account)

6. **Certificates/profiles:** a **Mac App Distribution** (3rd Party Mac Developer Application) cert + a **Mac App Store provisioning profile** for `works.rainn.tilecam` (or let Xcode manage automatically with your team `YK42U4LDMG`). Distinct from the iOS distribution cert.
7. **Hardened Runtime** is for Developer-ID (outside-store) distribution; the **Mac App Store** path uses the App Sandbox instead. Pick MAS (recommended for "all of it").
8. **Archive & upload:** `xcodebuild archive` for the Mac Catalyst destination → validate → upload to App Store Connect (or via Xcode Organizer).

## App Store Connect (your steps)

9. **App record:** add **macOS** as a supported platform on the existing `works.rainn.tilecam` record (universal purchase — one app, iPhone/iPad/Mac), rather than a separate record. (Catalyst keeps the iOS bundle id since `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: false`.)
10. **Mac screenshots** — required sizes: 1280×800, 1440×900, 2560×1600, or 2880×1800 (one set). The iOS screenshots don't carry over.
11. **Mac app category**, description (can reuse iOS copy), keywords, support URL, privacy-policy URL (same as iOS — see `docs/website-brief.md`).
12. **Age rating**, export compliance (encryption = exempt, already declared).
13. **Separate review:** Apple reviews the Mac build independently from iOS. Common Mac rejection causes to pre-empt: missing network-client entitlement (app can't connect), unsandboxed APIs, window can't resize sensibly, features that assume touch.

## Quick reference

- Build:  `xcodebuild -project TileCam.xcodeproj -scheme TileCam -destination 'platform=macOS,variant=Mac Catalyst' build`
- Run locally (unsigned): build, then `codesign --force --deep --sign - <TileCam.app>` and `open <TileCam.app>`
- UI tests: `./scripts/run-mac-ui-tests.sh` (needs an unlocked desktop session)
