# Kithra App Store Release Plan

This file tracks the fastest low-cost path from the local vertical slice to
TestFlight and then App Store review. Do not put secrets, private keys, tunnel
tokens, Apple API keys, or server passwords in this file.

## Release Target

- Public app name: Kithra.
- Bundle ID: `com.joaquimpacer.speakeasy`.
- V1 device family: iPhone-only; iPad support is deferred.
- First milestone: internal TestFlight smoke testing of the exact
  public-eligible release candidate.
- External TestFlight is optional and is not required for the first public
  release.
- Public App Store review follows a two-iPhone smoke test of the beta relay,
  onboarding, mutual QR/safety-number verification, send/receive, key-change
  failure handling, account deletion, and the completed review package.
- Supply only required iPhone screenshots and confirm the archive reports
  `UIDeviceFamily = [1]` before upload.
- France must be excluded from public App Store sale availability. Internal
  TestFlight groups are not country-scoped, so the release lane checks App Store
  availability instead: it blocks if France is enabled and warns while sale
  availability has not yet been configured. Revisit export documentation before
  enabling France because Kithra bundles industry-standard libsodium encryption.

## Hosting Decision

The relay is a long-running Go service with SQLite and encrypted blob storage.
It should run on a small VPS or a machine reached through a tunnel, not on a
serverless function host.

Recommended cheapest serious beta path:

1. Use the existing DigitalOcean VPS if it has enough spare CPU, RAM, disk, and
   bandwidth.
2. Keep the relay behind `https://api.joaquimpacer.com`.
3. Use Docker Compose for the relay.
4. Use Cloudflare Tunnel if you want HTTPS without opening public inbound app
   ports on the VPS.

Vercel is useful for the privacy policy/support website, but not for the relay:

- Vercel Functions are not a good fit for durable SQLite and encrypted blob
  files.
- The relay will need long-lived notification connections later.
- Moving to Vercel would mean rewriting storage around external database/blob
  products, which adds more moving parts than it saves for this beta.

## Hostname

The app should talk to an HTTPS hostname, not a LAN IP. Options:

- Buy a domain and use `api.<domain>`.
- Use a subdomain of a domain already pointed at the existing website.
- Use a provider hostname for a short private test only, then move to your own
  domain before broader review.

The release iPhone build has a configurable default relay URL:

- Debug default: `http://localhost:8080`
- Release default: `https://api.joaquimpacer.com`

Do not change the Release value without coordinating the relay deployment and
re-running the complete release smoke test.

## What "Release Server Config" Means

Release server config means the app has different defaults depending on where it
is running:

- Simulator/dev builds can default to the local relay.
- Physical local tests can still manually enter a LAN relay in Settings.
- TestFlight/App Store builds should default to the HTTPS beta relay.

This keeps App Review and testers from needing to type a local IP address.

## TestFlight Notes

Internal TestFlight does not require 100 testers. Apple allows up to 100
internal testers who are App Store Connect users.

External TestFlight does not require 10,000 testers. Apple allows up to 10,000
external testers. For a private beta, one external tester is fine.

For a trusted tester:

- If they should only test the app, invite them as an external TestFlight tester.
- If they need App Store Connect access, invite them as an internal tester with an
  appropriate App Store Connect role.

## Immediate Checklist

Owner tasks:

- Restore and verify public DNS/TLS for the support and privacy URLs at
  `kithra.joaquimpacer.com`.
- Deploy the exact integrated relay version to the existing DigitalOcean host
  only after separate deployment approval.
- Add and validate the owner-approved privacy manifest, prepare iPhone
  screenshots, and verify the release archive advertises only iPhone support.
- On the next TestFlight upload, expect `Missing Compliance`: Joaquim selected
  the conservative `ITSAppUsesNonExemptEncryption = true` declaration so App
  Store Connect presents its export-compliance questionnaire instead of
  pre-answering it as exempt.
- In App Store Connect, open the uploaded iOS build and choose **Provide Export
  Compliance Information**. Do not invite testers or change the plist while the
  answer is pending. Record the non-secret outcome in `docs/OWNER_SETUP.md`.
- If Apple's outcome confirms that the bundled encryption is exempt, Joaquim can
  make the final call to set `ITSAppUsesNonExemptEncryption = false` for future
  builds. If Apple requires and approves documentation, keep the declaration
  `true` and add only the Apple-issued `ITSEncryptionExportComplianceCode`.
  Revisit the answer before adding France, proprietary cryptography, or changing
  the current crypto design.
- Keep all VPS, Cloudflare, DNS, and Apple secrets out of chat.

Codex tasks:

- Keep the Docker relay deployable with Compose.
- Finish the remaining public-release security gates in `docs/BUILD_PLAN.md`.
- Keep the privacy/support copy aligned with deployed behavior.
- Verify server tests, simulator tests, a signed archive, two physical iPhones,
  and `/healthz` before an owner-authorized candidate upload.

## One-Command Internal TestFlight Upload

Fastlane is configured under `ios/fastlane/`. From the repository root, ship a
new internal-only TestFlight build with:

```sh
cd ios && bundle exec fastlane beta
```

The lane reads the ignored App Store Connect Key ID from
`secrets/app-store-connect/key-id.txt`, its private key from
`secrets/app-store-connect/AuthKey_<KEY_ID>.p8`, and its Issuer ID from
`secrets/app-store-connect/issuer-id.txt`. The values can instead be supplied
with `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_API_KEY_PATH`, and
`APP_STORE_CONNECT_ISSUER_ID`.

The lane requires a clean working tree and selects one more than the maximum of
the local `CURRENT_PROJECT_VERSION` and every App Store Connect iOS build
reservation/upload for the exact marketing version. It uses API-key-backed
Xcode automatic signing, archives the Release configuration, and uploads the
binary exactly once. After App Store Connect accepts the upload, it creates a
local commit containing only the Xcode build-number bump; the lane never pushes
that commit, so the operator must push it normally.

Processing is checked separately from upload. Each check waits 30 minutes by
default and may safely retry once without re-uploading; override the per-attempt
limit with `TESTFLIGHT_PROCESSING_TIMEOUT_SECONDS`. A final timeout reports that
the upload succeeded and directs the operator to resume rather than rerun
`beta`.

The next build intentionally stops before tester attachment when App Store
Connect reports `Missing Compliance`. Joaquim must answer the build's export
questionnaire in App Store Connect. After the build is cleared, resume that same
upload with:

```sh
cd ios
bundle exec fastlane verify_beta \
  version:<version> build_number:<build-number>
```

`verify_beta` waits for the selected uploaded build, reports App Store Connect's
resolved `usesNonExemptEncryption` value, and only attaches the build to the
`Kithra Internal` group after the compliance gate is clear. Both values are
mandatory; the lane never selects the current or latest build implicitly. The
`beta`/`verify_beta` path remains internal-only: the exported build is marked
`testFlightInternalTestingOnly`, external distribution and beta-review
submission are disabled, and that binary cannot be the public App Store
candidate.

## Owner-Gated Public-Eligible Candidate

The separate `public_candidate` lane creates a TestFlight build that remains
eligible for a later App Review submission by deliberately omitting
`testFlightInternalTestingOnly`. It still disables external distribution and
beta-review submission, attaches only to `Kithra Internal` after export
compliance clears, and never submits for App Review or releases the app. It has
not been run from this integration branch.

Running it signs and uploads a binary, so do not invoke it without Joaquim's
separate approval. The explicit confirmation is an owner gate, not a secret:

```sh
cd ios
KITHRA_PUBLIC_CANDIDATE_CONFIRM=I_CONFIRM_PUBLIC_ELIGIBLE_CANDIDATE \
  bundle exec fastlane public_candidate
```

If processing or export compliance pauses the lane, resume the exact existing
build without uploading another binary:

```sh
cd ios
KITHRA_PUBLIC_CANDIDATE_CONFIRM=I_CONFIRM_PUBLIC_ELIGIBLE_CANDIDATE \
  bundle exec fastlane verify_public_candidate \
  version:<version> build_number:<build-number>
```

Public App Store submission and release remain separate manual owner actions.

Apple's references for this owner step are [Provide export compliance
information for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/)
and [Determine and upload app encryption
documentation](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/).
