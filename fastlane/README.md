fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios gen

```sh
[bundle exec] fastlane ios gen
```

Regenerate the Xcode project from project.yml (xcodegen is the source of truth)

### ios signing

```sh
[bundle exec] fastlane ios signing
```

Sync App Store signing certs + profiles via match (CI). Needs MATCH_GIT_URL + MATCH_PASSWORD.

### ios build

```sh
[bundle exec] fastlane ios build
```

Build the App Store .ipa

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload metadata + screenshots only (no binary, no submit)

### ios release

```sh
[bundle exec] fastlane ios release
```

Build + upload binary + metadata + screenshots to App Store Connect (does NOT submit)

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build + upload to TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
