# Speakeasy Owner Setup Checklist

Use this file for account setup and non-secret status tracking. Do not paste
private keys, certificates, passwords, API keys, `.p8` contents, SSH keys, or
provisioning profiles into chat or commit them to the repo.

If you use a separate setup chat, start it with:

```text
I'm working on Speakeasy account setup. Read docs/OWNER_SETUP.md and help me
complete the next unchecked item. Do not ask for secrets in chat. Tell me where
to store each secret safely.
```

## Secret Handling Rules

- Local development secrets go in ignored `.env.local` files.
- CI secrets go in GitHub Actions secrets or Xcode Cloud secrets.
- Ignored repo-local `secrets/` may be used as owner-local script input, but it
  is not a cross-machine sync or backup mechanism. Keep durable copies in a
  password manager or a separate encrypted secrets store outside the clone.
- Never commit `.env`, `.env.local`, `.p8`, certificates, provisioning profiles,
  SSH private keys, or private API keys.
- Track setup status here using non-secret notes only.

## Apple Developer And App Store Connect

- [x] Enroll in the Apple Developer Program as an individual.
  - Status: Active enough to access App Store Connect on 2026-05-20.
  - Notes: Do not store Apple Account credentials, payment details, order details, or 2FA recovery material in this repo.
- [x] Create the Speakeasy app record in App Store Connect.
  - Public app name: `Kithra`
  - Bundle ID: `com.joaquimpacer.speakeasy`
  - SKU: `speakeasy-ios`
  - Status: Created in App Store Connect on 2026-05-20.
  - Notes: Public App Store name differs from the repo/internal project name.
- [x] Choose and create the iOS bundle ID.
  - Placeholder: `com.yourname.speakeasy`
  - Final bundle ID: `com.joaquimpacer.speakeasy`
  - Status: Created in Apple Developer Certificates, Identifiers & Profiles on 2026-05-20.
- [x] Choose the V1 Apple device family.
  - Decision: iPhone-only for the first public release; iPad support is deferred.
  - Status: The Kithra app and hosted test target use
    `TARGETED_DEVICE_FAMILY = 1`. Confirm the release archive reports
    `UIDeviceFamily = [1]` and provide only iPhone screenshots. The separate
    Designed-for-iPhone-on-Mac setting remains disabled.
- [x] Configure app capabilities.
  - Camera and microphone usage descriptions are required in the iOS app.
  - Push notifications can wait until after the local message flow works.
  - Status: V1 configuration complete with no Apple portal capabilities enabled. Camera and microphone usage descriptions are already present in `ios/Speakeasy/Resources/Info.plist`; push notifications remain deferred.
- [x] Restore App Store Connect API-key access for owner-run upload automation.
  - Store in GitHub Actions or Xcode Cloud secrets.
  - Owner-local `.p8` path: `secrets/app-store-connect/AuthKey_<KEY_ID>.p8`
  - Suggested secret names:
    - `ASC_KEY_ID`
    - `ASC_ISSUER_ID`
    - `ASC_KEY_P8_BASE64`
    - `APPLE_TEAM_ID`
    - `IOS_BUNDLE_ID`
  - Status: The ignored owner-local key, Key ID, and Issuer ID successfully
    authenticated the owner-authorized build-5 signing and upload on 2026-08-23.
    CI secret values remain unset; keep a durable encrypted backup outside this
    clone.
- [x] Install and verify Apple Distribution signing access on the release Mac.
  - Status: On 2026-08-09, Xcode created an Apple Distribution certificate for
    team `Y45XWD5PRV`. A read-only Keychain check outside the Codex sandbox
    reported valid Apple Development and Apple Distribution identities. The
    identity successfully signed the replacement build-5 archive on 2026-08-23.
- [x] Configure the App Store version and distribution shell.
  - Status: Live App Store Connect state verified through 2026-08-23: version `1.0`
    uses manual release; public distribution and the free price are saved;
    availability covers 174 storefronts with France explicitly **Not
    Available** under the completed no-France compliance scope; and Mac and
    Apple Vision Pro compatibility are disabled. These saved settings do not
    authorize App Review submission or release.
- [x] Select the eligible iPhone-only V1 build for version `1.0`.
  - Status: Kithra `1.0 (5)` is `VALID`, iPhone-only, and reports
    `usesNonExemptEncryption=false`. Build 5 is selected for version `1.0`. No
    TestFlight group is attached.
- [ ] Create APNs authentication key when push work starts.
  - Store in CI/server secret storage, not in the repo.
  - Suggested secret names:
    - `APNS_KEY_ID`
    - `APNS_TEAM_ID`
    - `APNS_KEY_P8_BASE64`
    - `APNS_BUNDLE_ID`
  - Status:
- [ ] Prepare TestFlight beta metadata.
  - Test account instructions:
  - Beta description:
  - Contact email: `support@jqinnovation.com`
  - Status: Draft beta description, tester checklist, and App Review notes are in `docs/TESTFLIGHT_NOTES.md`.

## DNS And Relay Hosting

- [x] Choose the API subdomain.
  - Placeholder: `api.yourdomain.com`
  - Final subdomain: `api.jqinnovation.com`
  - Status: Joaquim approved the hostname on 2026-08-22. The release defaults
    and deployment templates use it; DNS, TLS, and the public database/storage
    health check returned HTTP 200 on 2026-08-23. The public-candidate physical
    iPhone-to-simulator smoke also used this relay successfully. Record the exact
    deployed source revision separately and keep the previous beta hostname
    online during migration.
- [x] Set up local Docker relay for development.
  - Status: Verified on Mac on 2026-05-21 with Docker Desktop 4.74.0, Docker Engine 29.4.3, and Docker Compose v5.1.4. `docker compose up --build -d` starts the relay and `/healthz` returns `ok`.
- [ ] Set up Linux laptop relay for private beta.
  - Docker installed:
  - Persistent storage path:
  - Automatic sleep disabled:
  - Status: Skipped for now in favor of the existing DigitalOcean Droplet.
- [ ] Set up HTTPS tunnel for private beta.
  - Preferred: Cloudflare Tunnel or equivalent.
  - Public hostname:
  - Status: Skipped for now; Apache on the DigitalOcean Droplet will terminate HTTPS directly.
- [x] Use the existing DigitalOcean Droplet for the beta relay.
  - Status: `joaquimpacer-wp` is the relay host. The
    `https://api.jqinnovation.com/healthz` database/storage checks returned HTTP
    200 on 2026-08-23 and the public candidate completed its encrypted-video
    smoke through that endpoint. Exact deployed-revision and backup/restore
    evidence remain to be recorded.

## GitHub And CI

- [x] Confirm GitHub repository access and CODEOWNERS review path.
  - Status: Joaquim (`@JoaquimPacer`) is the sole code owner.
- [x] Connect `JoaquimPacer/speakeasy` to a Codex Cloud environment.
  - Status: Environment created with the universal image, post-setup caching,
    and agent internet access disabled. Repository guidance and the human-gated
    protocol are present in `AGENTS.md` and `docs/CODEX_REVIEW_LOOP.md`.
- [x] Choose the primary repository agent workflow.
  - Decision: Codex is the primary implementation and technical-review
    operator. Joaquim initiates/authorizes material scope and owns every merge
    and release decision. Optional outside reviews are advisory.
  - Status: Manual `@codex`/Codex task handoffs use the exact-head and
    idempotency protocol in `docs/CODEX_REVIEW_LOOP.md`.
- [ ] Enable unattended Codex PR processing only after safeguards are proven.
  - Status: Keep the current loop human-supervised. No GitHub Actions agent
    secret or write-capable comment workflow is required for manual operation.
- [ ] Lock down GitHub automation before adding a write-capable agent workflow.
  - Status: Repository Actions currently default to a write token and may
    approve pull-request reviews; `main` has no branch protection or ruleset.
    Joaquim must switch the default token to read-only, disable Action approval,
    and add a `main` ruleset requiring pull requests and relevant CI.
- [ ] Choose CI provider.
  - Default: GitHub Actions macOS.
  - Alternative: Xcode Cloud after Apple enrollment.
  - Final choice: GitHub Actions for secret-free PR checks; Xcode Cloud can be revisited for TestFlight upload/signing.
  - Status: Initial server and locally ad-hoc-signed iPhone simulator workflows
    exist and require no distribution credentials. The owner-run Fastlane lanes
    are not GitHub Actions workflows; signing/upload secrets remained local for
    the owner-authorized candidate upload, and CI signing secrets remain unset.
- [ ] Add CI secrets only after the workflow exists.
  - Status:

## Privacy, Safety, And App Review

- [x] Choose initial App Store distribution method.
  - Decision: Public, free distribution with no launch promotion. Joaquim
    accepts the small risk of organic discovery and may use a new app record in
    the future if early reviews make a clean relaunch preferable.

- [x] Draft and publish the privacy policy.
  - Must disclose metadata and encrypted content storage accurately.
  - Status: Joaquim approved `kithra.jqinnovation.com`; the static privacy page
    at `https://kithra.jqinnovation.com/privacy.html` returned HTTP 200 on
    2026-08-23.
- [x] Draft and publish the support URL/page.
  - Status: The public support page at
    `https://kithra.jqinnovation.com/support.html` includes
    `support@jqinnovation.com` and `security@jqinnovation.com` and returned HTTP
    200 on 2026-08-23.
- [ ] Verify in-app account deletion before public review.
  - Status: Authenticated, retry-safe account deletion and the iOS Settings flow
    are implemented. The exact processed build still needs an end-to-end
    real-device deletion test against the public HTTPS relay before App Review.
- [x] Prepare and publish App Privacy labels.
  - Status: An owner-reviewable `PrivacyInfo.xcprivacy` with the applicable
    first-party `UserDefaults` required-reason declaration is bundled in the
    app target. Validate the exact signed archive's privacy report, confirm the
    deployed proxy/log-retention behavior. App Store Connect was visually
    verified as published with no tracking on 2026-08-23. Revisit the labels if
    collection, tracking, or deployed logging behavior changes.
- [ ] Complete public App Store metadata and compliance owner decisions.
  - Status: The free price, public/manual distribution, France exclusion,
    disabled Mac/Vision compatibility, copyright, categories, content rights,
    13+ rating, messaging disclosure, DSA non-trader status, and English (U.S.)
    localization/support/privacy URLs are saved. Three `1284x2778` screenshots
    were visually validated and uploaded, build 5 was selected, and
    `Sign-In Required: No` plus the App Review contact and notes were saved and
    read back through the API. App Privacy is published with no tracking, the
    standard Apple EULA remains in use, and the no-push V1 limitation is in the
    review notes. The age rating's `userGeneratedContent=false` answer and final
    owner submission decision remain open. See
    `docs/APP_STORE_METADATA_DRAFT.md`.
- [x] Declare DSA trader or non-trader status in App Store Connect.
  - Decision: Joaquim selected and saved DSA non-trader status on 2026-08-21.
- [ ] Approve and staff the V1 user-content safety process.
  - Status: Blocking and metadata-only reporting are implemented, but public
    acceptable-use/community rules, report categories, operator response
    workflow, and final App Review explanation remain owner decisions. Review
    `docs/COMMUNITY_GUIDELINES.md` and
    `docs/ABUSE_RESPONSE_RUNBOOK_DRAFT.md`; publication and operational setup
    remain pending.
- [x] Complete encryption export compliance in App Store Connect.
  - Decision: On 2026-08-23 Joaquim answered Apple's app-level questionnaire for
    standard encryption algorithms, no proprietary algorithms, and no France
    availability. App Store Connect determined that no documentation is
    required. Joaquim approved `ITSAppUsesNonExemptEncryption = false` with no
    `ITSEncryptionExportComplianceCode` for the replacement build-5 archive.
    Revisit this decision before adding France or changing the crypto scope.
- [x] Run the owner-gated public-eligible candidate lane.
  - Status: The first build-5 upload failed with Apple error 90592. The guarded
    exact-build recovery rebuilt, signed, uploaded, and processed Kithra `1.0
    (5)` on 2026-08-23. App Store Connect reports `VALID`, ready for internal
    beta testing, and `usesNonExemptEncryption=false`. The lane did not attach
    testers, distribute externally, submit for App Review, or release the app.
- [x] Implement block/report controls.
  - Reports are metadata-only. Do not send decrypted videos to the operator.
  - Status: Initial iOS contact-row actions and relay endpoints added on 2026-05-27. Delete removes the contact from the current user's list, block removes the contact and prevents future uploads from the blocked user, and report stores metadata only.

## Later Google Play / Android V2

- [ ] Create Google Play Console developer account.
  - Status: Needed before a Google Play internal test upload.
- [x] Plan Android Kotlin client.
  - CameraX, Android Keystore, libsodium binding, FCM push.
  - Status: Native Android lane started on 2026-05-28. A Kotlin Android
    scaffold exists under `android/`, builds locally, and has Android CI. Full
    iOS feature parity is not implemented yet.
- [ ] Prepare Play Data Safety and account deletion requirements.
  - Status:
- [ ] Plan closed testing requirements before production release.
  - Status: Google Play internal testing can be used for early trusted testers;
    production access requirements depend on the Play Console account type and
    current Google policy.
