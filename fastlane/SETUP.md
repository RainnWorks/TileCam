# fastlane setup — TileCam (CI + secrets)

`fastlane/README.md` is auto-generated (lane list). This file is the real setup
doc and fastlane won't overwrite it.

## Lanes
- `fastlane ios metadata` — push metadata + screenshots only (no binary, no submit)
- `fastlane ios build`    — build the App Store `.ipa`
- `fastlane ios beta`     — build + upload to TestFlight
- `fastlane ios release`  — build + upload binary + metadata + screenshots (no submit)
- `fastlane ios signing`  — install the App Store certificate + profiles on this Mac (`rw-apple sync tilecam`)

Run locally through `rw-apple`, which supplies the App Store Connect key:

```
rw-apple exec -- bundle exec fastlane ios <lane>
```

## Signing and secrets
TileCam signs through [RainnWorks/apple-signing](https://github.com/RainnWorks/apple-signing).
Its README covers setting up a Mac, the CI secrets and rotating keys.

- Lanes read the App Store Connect key only from `RW_ASC_KEY_ID`,
  `RW_ASC_ISSUER_ID` and `RW_ASC_KEY_P8`.
- Local builds keep Xcode automatic signing.
- CI checks out apple-signing and runs `sync tilecam --ci` before fastlane, then
  archives with manual signing and the `RW AppStore <bundle id>` profiles.
- CI needs the organization secrets `RW_SIGNING_DEPLOY_KEY`, `RW_SIGNING_PASSWORD`,
  `RW_ASC_KEY_ID`, `RW_ASC_ISSUER_ID` and `RW_ASC_KEY_P8`.

## Still do once in App Store Connect (not covered by `deliver`)
- **Age rating** questionnaire → 4+.
- **App Privacy** nutrition label → *Data Not Collected*.
- Select the build + attach the **Watch Unlock** IAP to the version.
- Replace `<DEMO_GO2RTC_URL>` in the review notes with the live demo server URL.
