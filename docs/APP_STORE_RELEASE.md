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

## Verified App Store Connect State (through 2026-08-23)

- The local Apple Distribution identity is valid and signed the replacement
  build-5 archive. Recheck it immediately before a future signed archive.
- App Store version `1.0` is configured for manual release with public
  distribution. The free price is saved.
- Availability is configured for 174 storefronts. France is explicitly **Not
  Available** and remains outside the encryption-questionnaire scope recorded
  on 2026-08-23.
- Designed-for-iPhone-on-Mac and Apple Vision Pro compatibility are disabled.
- Kithra `1.0 (5)` is the processed iPhone-only candidate. It is `VALID`, reports
  `usesNonExemptEncryption=false`, and is not attached to a TestFlight group.
  Build 5 is selected for version `1.0`.
- Three `1284x2778` iPhone screenshots are uploaded. Copyright, categories,
  content rights, the 13+ age rating, messaging disclosure, DSA non-trader
  status, and the English (U.S.) localization, support URL, and privacy-policy
  URL are saved.
- `Sign-In Required: No`, the App Review contact, and the review notes are saved
  and were independently read back through the App Store Connect API. The App
  Privacy page was visually verified as published with no tracking. The package
  is assembled but remains in `PREPARE_FOR_SUBMISSION`; the age-rating
  `userGeneratedContent=false` answer and owner submission decision remain open.

## Hosting Decision

The relay is a long-running Go service with SQLite and encrypted blob storage.
It should run on a small VPS or a machine reached through a tunnel, not on a
serverless function host.

Recommended cheapest serious beta path:

1. Use the existing DigitalOcean VPS if it has enough spare CPU, RAM, disk, and
   bandwidth.
2. Keep the relay behind `https://api.jqinnovation.com`.
3. Use Docker Compose for the relay.
4. Under the current trusted-proxy design, use a Cloudflare DNS-only record and
   terminate HTTPS through Apache and Certbot on the VPS. Cloudflare proxying or
   Tunnel requires a separately reviewed client-IP trust and origin-access
   design.

Vercel can continue serving the main JQ Innovation website, but it should not
host the relay. The explicit DNS-only `api.jqinnovation.com` record points
directly to DigitalOcean, so relay requests do not consume Vercel traffic or
function allowance:

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
- Release default: `https://api.jqinnovation.com`

Do not change the Release value without coordinating the relay deployment and
re-running the complete release smoke test.

The repository and release build use the new hostname. Its DNS, TLS, and public
database/storage health checks returned HTTP 200 on 2026-08-23, and the physical
iPhone-to-simulator encrypted-video smoke used this relay successfully. Recheck
health immediately before submission. Existing beta devices that used the
previous hostname must reset their local registration, register again, and
mutually reverify safety numbers because relay identity is scoped to the
hostname.

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

- The approved support and privacy pages are live at
  `https://kithra.jqinnovation.com/support.html` and
  `https://kithra.jqinnovation.com/privacy.html`; both returned HTTP 200 on
  2026-08-23.
- The approved relay hostname is live and passed its public health check and the
  physical-iPhone-to-simulator encrypted-video smoke. Record the exact deployed
  source revision and backup/restore evidence separately.
- Three `1284x2778` iPhone screenshots are uploaded. Review their final order and
  validate the exact signed archive's privacy report.
- Apple Distribution signing and the App Store Connect API key are available on
  the release Mac. The first build-5 archive was signed, but its upload was
  rejected with Apple error 90592 and was not reused. A fresh replacement
  archive was signed and uploaded on 2026-08-23; App Store Connect processed
  Kithra `1.0 (5)` as `VALID` with `usesNonExemptEncryption=false`.
- On 2026-08-23 Joaquim completed Apple's app-level encryption questionnaire
  using the current factual scope: Kithra uses standard encryption algorithms,
  no proprietary algorithms, and is not available in France. App Store Connect
  determined that no export-compliance documentation is required.
- Joaquim approved `ITSAppUsesNonExemptEncryption = false` and no
  `ITSEncryptionExportComplianceCode` for the replacement build-5 archive. The
  archive validator enforces both facts. Revisit the questionnaire and plist
  before adding France, proprietary cryptography, or changing the current crypto
  design.
- Reconfirm the age-rating UGC answer before submission. The saved App Review
  fields, selected build, screenshots, and published App Privacy answers require
  no further entry unless the app or deployed behavior changes.
- Keep all VPS, Cloudflare, DNS, and Apple secrets out of chat.

Codex tasks:

- Keep the Docker relay deployable with Compose.
- Finish the remaining public-release security gates in `docs/BUILD_PLAN.md`.
- Keep the privacy/support copy aligned with deployed behavior.
- Preserve the completed server/simulator checks, signed archive,
  physical-iPhone-to-simulator smoke, and `/healthz` evidence. Before submission,
  run the exact processed TestFlight build on two iPhones, including account
  deletion and identity-verification failure handling.

## One-Command Internal TestFlight Upload

Fastlane is configured under `ios/fastlane/`. From the repository root, ship a
new internal-only TestFlight build with:

```sh
cd ios
KITHRA_INTERNAL_TESTFLIGHT_CONFIRM=I_CONFIRM_INTERNAL_TESTFLIGHT_ACTION \
  bundle exec fastlane beta
```

The confirmation is an owner gate for internal TestFlight signing, upload, and
group attachment. It does not authorize a public-eligible candidate, external
distribution, App Review submission, or public release.

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

Processing is checked separately from upload. Each lane invocation makes one
bounded polling attempt of 30 minutes by default; override that per-invocation
limit with `TESTFLIGHT_PROCESSING_TIMEOUT_SECONDS`. A timeout never re-uploads
the binary: it reports the exact existing version/build and directs the operator
to run the matching verification lane instead of rerunning `beta`.

If App Store Connect unexpectedly reports `Missing Compliance`, do not attach
testers and do not upload another binary. Inspect the exact build's compliance
state first. After Apple clears that same upload, resume it with:

```sh
cd ios
KITHRA_INTERNAL_TESTFLIGHT_CONFIRM=I_CONFIRM_INTERNAL_TESTFLIGHT_ACTION \
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
compliance clears, and never submits for App Review or releases the app. The
first build-5 upload attempt failed with Apple error 90592 and left one exact
`AWAITING_UPLOAD` reservation. The targeted recovery consumed that reservation
successfully on 2026-08-23; the processed build was selected for version `1.0`
but was not attached to testers or submitted for review. Before upload, the lane
inspects the built archive and fails closed unless the app is iPhone-only,
contains
`PrivacyInfo.xcprivacy`, resolves the production HTTPS relay, declares
`ITSAppUsesNonExemptEncryption = false`, omits
`ITSEncryptionExportComplianceCode`, and has the selected version/build.

Running it signs and uploads a binary, so do not invoke it without Joaquim's
separate approval. The explicit confirmation is an owner gate, not a secret:

```sh
cd ios
KITHRA_PUBLIC_CANDIDATE_CONFIRM=I_CONFIRM_PUBLIC_ELIGIBLE_CANDIDATE \
  bundle exec fastlane public_candidate
```

Do not rerun `public_candidate` for a reserved build because it intentionally
selects a new number. The exact-build recovery lane consumes only one existing
`AWAITING_UPLOAD` reservation and never increments, commits, distributes, or
submits the binary:

```sh
cd ios
KITHRA_PUBLIC_CANDIDATE_CONFIRM=I_CONFIRM_PUBLIC_ELIGIBLE_CANDIDATE \
  bundle exec fastlane retry_public_candidate_upload \
  version:<version> build_number:<build-number>
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
