# fastlane setup — TileCam (CI + secrets)

`fastlane/README.md` is auto-generated (lane list). This file is the real setup
doc and fastlane won't overwrite it.

## Lanes
- `fastlane ios metadata` — push metadata + screenshots only (no binary, no submit)
- `fastlane ios build`    — build the App Store `.ipa`
- `fastlane ios beta`     — build + upload to TestFlight
- `fastlane ios release`  — build + upload binary + metadata + screenshots (no submit)
- `fastlane ios signing`  — sync certs/profiles via `match` (CI)

Run locally: `bundle exec fastlane ios <lane>` (or global `fastlane`).

## App Store Connect API key
- **Local:** falls back to pulling the `.p8` from the standard location
  `~/.appstoreconnect/private_keys/AuthKey_5WHJ3464D2.p8`, else from 1Password
  (`thenairn` account → `Private` → *"ASC API Key - TileCam Build Upload (RainnWorks)"*).
  Key ID `5WHJ3464D2`, Issuer `c73bbb08-c295-4f05-8941-061c35640941` (identifiers, not secret).
- **CI (GitHub Actions secrets):** `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_CONTENT` (base64 of the `.p8`), `ASC_KEY_CONTENT_BASE64=true`.
  Make the base64: `base64 -i AuthKey_5WHJ3464D2.p8 | pbcopy`.

## Signing in CI — `match` (the separate private repo)
Local dev uses Xcode **automatic** signing (nothing to set up). GHA runners have no
signed-in Apple ID, so they use `match`, which stores the App Store distribution
cert + profiles **AES-encrypted in a dedicated PRIVATE repo**.

Bootstrap once (locally, as Admin/Account Holder):
```
export MATCH_GIT_URL=git@github.com:rainnworks/ios-certificates.git   # a NEW private repo
export MATCH_PASSWORD=<strong passphrase → store in 1Password>
bundle exec fastlane match appstore
```
Then add GHA secrets: `MATCH_GIT_URL`, `MATCH_PASSWORD`, and
`MATCH_GIT_BASIC_AUTHORIZATION` (a PAT/token that can read the certs repo).

## Still do once in App Store Connect (not covered by `deliver`)
- **Age rating** questionnaire → 4+.
- **App Privacy** nutrition label → *Data Not Collected*.
- Select the build + attach the **Watch Unlock** IAP to the version.
- Replace `<DEMO_GO2RTC_URL>` in the review notes with the live demo server URL.
