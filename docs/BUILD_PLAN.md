# Speakeasy Build Plan

This is the durable project handoff file for Speakeasy. New agents and new chat
threads should read this file before making changes.

## New Chat Bootstrap

```text
Read AGENTS.md, CLAUDE.md, docs/BUILD_PLAN.md, docs/WORKFLOW.md,
docs/OWNER_SETUP.md, and git status. Continue from the next unchecked task. Do
not assume unstated decisions; preserve the existing constraints.
```

## Current Decisions

- Product: Speakeasy, an open-source, self-hosted async video messaging app.
- Public iOS app name: Kithra.
- Internal repo/project name: Speakeasy.
- iOS bundle ID: `com.joaquimpacer.speakeasy`.
- V1 target: iOS TestFlight MVP before public App Store release.
- V1 client: native Swift/SwiftUI, AVFoundation, Keychain, libsodium.
- V1 server: Go relay, SQLite, local filesystem blob storage, Docker Compose.
- V1 scope: 1:1 video messaging, invite-code contacts, delivery/watch status,
  optional Face ID/passcode gate, metadata-only block/report controls.
- Out of V1: Android, groups, monetization, web client, key backup/recovery,
  full Signal-style forward secrecy.
- Android is a V2 client; keep API and crypto envelope platform-neutral.
- Collaboration: small PRs with Joshua credited and CODEOWNERS review preserved.
- Local dev relay: Docker on local machine or Linux laptop.
- Private beta relay: Linux laptop through Cloudflare Tunnel or equivalent HTTPS
  tunnel, then DigitalOcean if uptime or review needs require it.
- Undelivered server blob expiry: configurable, default 7 days.
- Server deletion: delete encrypted blob after recipient download is verified
  into local cache. Watched status does not control blob deletion.
- Local media: keep sent and received history on-device as encrypted packages;
  use short-lived plaintext temp files only for playback.
- Device identity: separate encryption keypair for content-key wrapping and
  signing keypair for auth challenges.

## Architecture Summary

Speakeasy is store-and-forward, not peer-to-peer. The iOS app records, compresses,
encrypts, uploads, downloads, decrypts, and plays videos. The server stores only
encrypted blobs plus routing metadata and cannot decrypt user content.

Server responsibilities:
- User/device registration and challenge-response login.
- Contact invite creation and acceptance.
- Message metadata, encrypted blob upload/download, delivery acknowledgement,
  watched status, block/report metadata, retention cleanup.
- Optional APNs push notification dispatch with content-blind payloads.

iOS responsibilities:
- Generate and store device keys in Keychain.
- Record with AVFoundation.
- Compress/transcode raw camera output before encryption.
- Encrypt compressed media with libsodium before upload.
- Store encrypted local sender and recipient copies.
- Decrypt to temporary plaintext playback files only when needed, then clean up.

## Crypto And Media Lifecycle

V1 uses honest MVP E2E encryption, not full Signal-style forward secrecy.

Message send lifecycle:
1. Record raw temporary camera file.
2. Transcode to a compressed delivery video.
3. Generate a fresh random content key.
4. Encrypt the compressed video locally with libsodium.
5. Encrypt the content key to the recipient device public key.
6. Save an encrypted local sender copy for history/resend.
7. Upload encrypted blob and envelope metadata to the relay.
8. Delete raw camera and plaintext compressed temporary files after encryption
   and local encrypted save succeed.

Message receive lifecycle:
1. Download encrypted blob and envelope metadata.
2. Decrypt and verify locally.
3. Save verified encrypted local recipient copy.
4. Acknowledge delivery to the relay.
5. Relay deletes its encrypted blob.

Playback lifecycle:
1. User opens a sent or received video.
2. App decrypts the local encrypted package to a short-lived plaintext file.
3. AVPlayer plays the temporary plaintext file.
4. App deletes the temporary plaintext file after playback, backgrounding, or
   cleanup timeout.

## Subagent Policy

Use selective workers only after docs and interfaces are locked.

Before spawning workers, the main agent must state:
- Worker split.
- File ownership.
- Expected output.
- Verification required.

Default split:
- Server worker owns `server/`.
- iOS worker owns `ios/`.
- Infra worker owns deployment, CI docs, and workflow files.
- Main agent owns crypto/API decisions, review, integration, and final tests.

Workers must not edit overlapping files unless explicitly assigned a shared
integration point. Worker final reports must include changed files, tests run,
blockers, and unverified assumptions.

## PR Roadmap

- [x] Planning docs and spec corrections.
- [x] Initial API contract for local vertical slice.
- [x] Go server scaffold with health endpoint, development API, config, SQLite, local blob store,
      and Docker Compose.
- [x] iOS SwiftUI scaffold with permissions, Keychain key generation, and API
      client shell.
- [ ] Local vertical slice: register, invite, record, compress, encrypt, upload,
      download, verify, local-cache acknowledge, relay-delete.
- [ ] Private beta relay deployment using Linux laptop plus HTTPS tunnel.
- [ ] CI/TestFlight setup after Apple Developer enrollment.
- [ ] External beta hardening: privacy policy, support URL, account deletion,
      block/report flow, App Privacy labels.

## Current Status Log

- 2026-05-14: Build plan created and specs corrected for V1 E2E claims,
  server blob deletion after verified local cache, and separate device
  encryption/signing keys.
- 2026-05-14: Initial server, iOS, CI, deployment, and API scaffolds added.
  Local builds are unverified on this Windows environment because Go, Swift,
  Xcode, and the Docker daemon are unavailable.
- 2026-05-21: Public iOS app name set to Kithra in App Store Connect; bundle ID
  set to `com.joaquimpacer.speakeasy`; operator workflow documented in
  `docs/WORKFLOW.md`.
- 2026-05-21: App Store Connect API key created and stored in ignored
  owner-local `secrets/app-store-connect/`; CI secret wiring remains deferred
  until an upload workflow exists.

## Open Placeholders

- Public subdomain: choose during DNS setup.
- CI provider: default GitHub Actions macOS unless Xcode Cloud is clearly easier.
- APNs key: create after core local message flow works.
- DigitalOcean deployment: defer until laptop tunnel is insufficient.
