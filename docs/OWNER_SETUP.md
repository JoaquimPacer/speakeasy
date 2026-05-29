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
- Owner-local secrets may be stored under ignored `secrets/` for OneDrive sync
  across the owner's machines. Treat this as private workspace state, not source
  code or team sharing.
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
- [x] Configure app capabilities.
  - Camera and microphone usage descriptions are required in the iOS app.
  - Push notifications can wait until after the local message flow works.
  - Status: V1 configuration complete with no Apple portal capabilities enabled. Camera and microphone usage descriptions are already present in `ios/Speakeasy/Resources/Info.plist`; push notifications remain deferred.
- [x] Create App Store Connect API key for CI upload.
  - Store in GitHub Actions or Xcode Cloud secrets.
  - Owner-local `.p8` path: `secrets/app-store-connect/AuthKey_<KEY_ID>.p8`
  - Suggested secret names:
    - `ASC_KEY_ID`
    - `ASC_ISSUER_ID`
    - `ASC_KEY_P8_BASE64`
    - `APPLE_TEAM_ID`
    - `IOS_BUNDLE_ID`
  - Status: Created and downloaded to ignored owner-local `secrets/app-store-connect/` on 2026-05-21. CI secret values are not added yet because no upload workflow consumes them yet.
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
  - Contact email:
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
- [ ] Decide if/when to move to DigitalOcean.
  - Default: defer until uptime or App Review needs require it.
  - Status: Existing DigitalOcean Droplet `joaquimpacer-wp` is now the beta relay host. Relay is running locally behind Apache and public HTTPS health checks pass at `https://api.joaquimpacer.com/healthz`.

## GitHub And CI

- [ ] Confirm GitHub repository access and CODEOWNERS review path.
  - Status:
- [ ] Choose CI provider.
  - Default: GitHub Actions macOS.
  - Alternative: Xcode Cloud after Apple enrollment.
  - Final choice: GitHub Actions for secret-free PR checks; Xcode Cloud can be revisited for TestFlight upload/signing.
  - Status: Initial server and unsigned iOS simulator workflows exist; upload/signing workflows remain deferred until they consume stored CI secrets.
- [ ] Add CI secrets only after the workflow exists.
  - Status:

## Privacy, Safety, And App Review

- [ ] Draft privacy policy.
  - Must disclose metadata and encrypted content storage accurately.
  - Status: Draft is in `docs/PRIVACY_POLICY_DRAFT.md`.
- [ ] Draft support URL/page.
  - Status: Draft is in `docs/SUPPORT_PAGE_DRAFT.md`.
- [ ] Add in-app account deletion before public review.
  - Status: Initial authenticated delete-account endpoint and iOS Settings flow added on 2026-05-27. Needs end-to-end real-device verification against the beta HTTPS relay before App Review.
- [ ] Prepare App Privacy labels.
  - Status:
- [ ] Prepare encryption export compliance answers.
  - Status:
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
