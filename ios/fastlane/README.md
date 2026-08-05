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

The build number is one more than the maximum local project value and every
App Store Connect iOS reservation/upload for the exact marketing version.

### ios verify_beta

```sh
[bundle exec] fastlane ios verify_beta version:1.0 build_number:5
```

Resume verification and internal distribution for an uploaded Kithra build

Both `version` and `build_number` are required; this lane never selects the
current or latest build implicitly.

### ios public_candidate

```sh
KITHRA_PUBLIC_CANDIDATE_CONFIRM=I_CONFIRM_PUBLIC_ELIGIBLE_CANDIDATE \
  [bundle exec] fastlane ios public_candidate
```

Build and upload a public-eligible Kithra candidate without submitting it

This lane selects one more than the maximum of local `CURRENT_PROJECT_VERSION`
and every App Store Connect iOS reservation/upload for the exact marketing
version. It signs and uploads exactly once, deliberately omits
`testFlightInternalTestingOnly`, and keeps external distribution, beta-review
submission, App Review submission, and public release disabled. The
confirmation value is an owner gate, not a secret and not authorization to
submit or release the app.

### ios verify_public_candidate

```sh
KITHRA_PUBLIC_CANDIDATE_CONFIRM=I_CONFIRM_PUBLIC_ELIGIBLE_CANDIDATE \
  [bundle exec] fastlane ios verify_public_candidate \
  version:1.0 build_number:5
```

Resume exact-build compliance verification for a public-eligible candidate

Both `version` and `build_number` are mandatory so this lane cannot silently
select a different upload. It waits for the existing build, requires export
compliance to be resolved, and attaches only that build to `Kithra Internal`.
It never uploads another binary, distributes externally, submits, or releases.

If either upload lane fails before committing its build-number bump, do not
decrement or rerun blindly: inspect the exact version/build in App Store
Connect and `git status` first because the upload may have succeeded.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
