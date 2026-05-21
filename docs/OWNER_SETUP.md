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
  - Status:

## DNS And Relay Hosting

- [ ] Choose the API subdomain.
  - Placeholder: `api.yourdomain.com`
  - Final subdomain:
  - Status:
- [ ] Set up local Docker relay for development.
  - Status: Docker CLI and Compose are installed, but on 2026-05-21 Docker daemon was not running and Docker reported it could not read `C:\Users\f927g\.docker\config.json`.
- [ ] Set up Linux laptop relay for private beta.
  - Docker installed:
  - Persistent storage path:
  - Automatic sleep disabled:
  - Status:
- [ ] Set up HTTPS tunnel for private beta.
  - Preferred: Cloudflare Tunnel or equivalent.
  - Public hostname:
  - Status:
- [ ] Decide if/when to move to DigitalOcean.
  - Default: defer until uptime or App Review needs require it.
  - Status:

## GitHub And CI

- [ ] Confirm GitHub repository access and CODEOWNERS review path.
  - Status:
- [ ] Choose CI provider.
  - Default: GitHub Actions macOS.
  - Alternative: Xcode Cloud after Apple enrollment.
  - Final choice:
  - Status:
- [ ] Add CI secrets only after the workflow exists.
  - Status:

## Privacy, Safety, And App Review

- [ ] Draft privacy policy.
  - Must disclose metadata and encrypted content storage accurately.
  - Status:
- [ ] Draft support URL/page.
  - Status:
- [ ] Add in-app account deletion before public review.
  - Status:
- [ ] Prepare App Privacy labels.
  - Status:
- [ ] Prepare encryption export compliance answers.
  - Status:
- [ ] Implement block/report controls.
  - Reports are metadata-only. Do not send decrypted videos to the operator.
  - Status:

## Later Google Play / Android V2

- [ ] Create Google Play Console developer account.
  - Status:
- [ ] Plan Android Kotlin client.
  - CameraX, Android Keystore, libsodium binding, FCM push.
  - Status:
- [ ] Prepare Play Data Safety and account deletion requirements.
  - Status:
- [ ] Plan closed testing requirements before production release.
  - Status:
