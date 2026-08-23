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

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload an internal-only Kithra build to TestFlight

### ios public_candidate

```sh
[bundle exec] fastlane ios public_candidate
```

Build and upload a public-eligible Kithra candidate without submitting it

### ios retry_public_candidate_upload

```sh
[bundle exec] fastlane ios retry_public_candidate_upload
```

Rebuild and upload one exact reserved public candidate without incrementing

### ios verify_public_candidate

```sh
[bundle exec] fastlane ios verify_public_candidate
```

Resume exact-build compliance verification for a public-eligible candidate

### ios verify_beta

```sh
[bundle exec] fastlane ios verify_beta
```

Resume verification and internal distribution for an uploaded Kithra build

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
