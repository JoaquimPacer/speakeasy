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
- [ ] Restore App Store Connect API-key access for owner-run upload automation.
  - Store in GitHub Actions or Xcode Cloud secrets.
  - Owner-local `.p8` path: `secrets/app-store-connect/AuthKey_<KEY_ID>.p8`
  - Suggested secret names:
    - `ASC_KEY_ID`
    - `ASC_ISSUER_ID`
    - `ASC_KEY_P8_BASE64`
    - `APPLE_TEAM_ID`
    - `IOS_BUNDLE_ID`
  - Status: App Store Connect showed one active Admin team key named
    `Kithra Fastlane` on 2026-08-09, but its one-time-download `.p8` private-key
    file was not present in the ignored repository secrets directory or found
    elsewhere on the release Mac. Joaquim must either restore that exact private
    key from secure storage or explicitly authorize creating an App Manager
    replacement and revoking the unusable Admin key. CI secret values remain
    unset.
- [x] Install and verify Apple Distribution signing access on the release Mac.
  - Status: On 2026-08-09, Xcode created an Apple Distribution certificate for
    team `Y45XWD5PRV`. A read-only Keychain check outside the Codex sandbox
    reported valid Apple Development and Apple Distribution identities. No
    archive was signed or uploaded during this verification.
- [x] Configure the App Store version and distribution shell.
  - Status: Live App Store Connect state verified on 2026-08-09: version `1.0`
    uses manual release; public distribution and the free price are saved;
    availability covers 174 storefronts with France explicitly **Not
    Available** pending encryption clearance; and Mac and Apple Vision Pro
    compatibility are disabled. These saved settings do not authorize upload,
    App Review submission, or release.
- [ ] Attach an eligible iPhone-only V1 build to App Store version `1.0`.
  - Status: Builds 1 through 4 exist, but no build is attached. Build 4 reports
    non-exempt encryption as `No` and supports iPhone and iPad, so it cannot be
    the iPhone-only V1 candidate that presents the export-compliance
    questionnaire. No existing build is the V1 candidate.
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

- [ ] Choose the API subdomain.
  - Placeholder: `api.yourdomain.com`
  - Final subdomain: `api.joaquimpacer.com`
  - Status: Chosen on 2026-05-27. DigitalOcean DNS `A` record points to `137.184.80.178`.
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
  - Status: `joaquimpacer-wp` is the beta relay host. The public HTTPS health
    check passed on 2026-08-04, but the deployed process predates the integrated
    release branch and must be updated only after separate deployment approval.

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
    are not GitHub Actions workflows; signing/upload secrets remain local until
    Joaquim separately authorizes a candidate upload.
- [ ] Add CI secrets only after the workflow exists.
  - Status:

## Privacy, Safety, And App Review

- [x] Choose initial App Store distribution method.
  - Decision: Public, free distribution with no launch promotion. Joaquim
    accepts the small risk of organic discovery and may use a new app record in
    the future if early reviews make a clean relaunch preferable.

- [ ] Draft privacy policy.
  - Must disclose metadata and encrypted content storage accurately.
  - Status: Joaquim approved `kithra.jqinnovation.com`; the draft and static
    page use that hostname. DNS, TLS, deployment, and public reachability remain
    to be completed and verified before submission.
- [ ] Draft support URL/page.
  - Status: Draft and static page exist with `support@jqinnovation.com` and
    `security@jqinnovation.com` on the approved `kithra.jqinnovation.com`
    hostname. Publish over HTTPS and verify the public support URL before
    submission.
- [ ] Add in-app account deletion before public review.
  - Status: Initial authenticated delete-account endpoint and iOS Settings flow added on 2026-05-27. Needs end-to-end real-device verification against the beta HTTPS relay before App Review.
- [ ] Prepare App Privacy labels.
  - Status: An owner-reviewable `PrivacyInfo.xcprivacy` with the applicable
    first-party `UserDefaults` required-reason declaration is bundled in the
    app target. Validate the exact signed archive's privacy report, confirm the
    deployed proxy/log-retention behavior, and then complete the App Store
    Connect labels.
- [ ] Complete public App Store metadata and compliance owner decisions.
  - Status: Working copy, screenshot plan, conservative privacy-label answers,
    and review notes are in `docs/APP_STORE_METADATA_DRAFT.md`. The free price,
    public distribution, manual release, 174-storefront availability with
    France excluded, and disabled Mac/Vision compatibility are saved. Joaquim
    must still approve the App Review contact, copyright, categories,
    standard/custom EULA, content rights, age rating, privacy labels, English
    localization, no-push V1, final copy, and final screenshots.
- [x] Declare DSA trader or non-trader status in App Store Connect.
  - Decision: Joaquim selected and saved DSA non-trader status on 2026-08-21.
- [ ] Approve and staff the V1 user-content safety process.
  - Status: Blocking and metadata-only reporting are implemented, but public
    acceptable-use/community rules, report categories, operator response
    workflow, and final App Review explanation remain owner decisions. Review
    `docs/COMMUNITY_GUIDELINES.md` and
    `docs/ABUSE_RESPONSE_RUNBOOK_DRAFT.md`; publication and operational setup
    remain pending.
- [ ] Complete encryption export compliance in App Store Connect.
  - Decision: Option B selected by Joaquim on 2026-07-20. The next upload declares
    `ITSAppUsesNonExemptEncryption = true` so App Store Connect presents the
    questionnaire; tester attachment remains blocked until it is resolved.
  - Status: After the upload, record the non-secret questionnaire outcome here.
    If Apple confirms exemption, Joaquim decides whether to set the plist value
    to `false`. If Apple requires documentation, keep it `true` and add only an
    Apple-issued `ITSEncryptionExportComplianceCode`.
- [ ] Run the owner-gated public-eligible candidate lane.
  - Status: `fastlane public_candidate` is implemented but has not been run. It
    signs and uploads only after an exact local confirmation, does not distribute
    externally, submit for App Review, or release, and must wait for separate
    owner approval plus the remaining public-release blockers.
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
