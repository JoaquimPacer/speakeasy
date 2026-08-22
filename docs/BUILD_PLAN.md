# Speakeasy Build Plan

This is the durable project handoff file for Speakeasy. New agents and new chat
threads should read this file before making changes.

## New Chat Bootstrap

```text
Read AGENTS.md, docs/BUILD_PLAN.md, docs/WORKFLOW.md, docs/OWNER_SETUP.md,
docs/MAC_SETUP.md, and git status. For PR work, also read
docs/CODEX_REVIEW_LOOP.md. Continue from the next unchecked task. Do not assume
unstated decisions; preserve the existing constraints.
```

## Current Decisions

- Product: Speakeasy, an open-source, self-hosted async video messaging app.
- Public iOS app name: Kithra.
- Internal repo/project name: Speakeasy.
- iOS bundle ID: `com.joaquimpacer.speakeasy`.
- V1 target: public iPhone App Store release. Use internal TestFlight to
  smoke-test the exact public-eligible release-candidate build before
  submission. iPad support is deferred.
- V1 client: native Swift/SwiftUI, AVFoundation, Keychain, libsodium.
- V1 server: Go relay, SQLite, local filesystem blob storage, Docker Compose.
- V1 scope: 1:1 video messaging, invite-code contacts, delivery/watch status,
  optional Face ID/passcode gate, metadata-only block/report controls,
  relay-scoped safety-number/signed-QR verification, and authenticated Message
  Envelope v2.
- Out of V1: iPad, Android, groups, monetization, web client, key
  backup/recovery, full Signal-style forward secrecy.
- Android is a V2 client; keep API and crypto envelope platform-neutral.
- Android lane has started as a native Kotlin client under `android/`; maintain
  cross-platform parity with iOS by sharing API/crypto contracts and test
  checklists, not by sharing UI code.
- Collaboration: small PRs with Joaquim as the sole code owner and required
  human decision-maker for merge and release actions.
- PR loop: Codex is the primary implementation and technical-review operator;
  Joaquim authorizes scope and owns merge/release decisions. Optional outside
  reviews are advisory. See `docs/CODEX_REVIEW_LOOP.md`.
- Local dev relay: Docker on local machine or Linux laptop.
- Beta relay host: existing DigitalOcean Droplet behind HTTPS.
- Undelivered server blob expiry: configurable, default 7 days.
- Server deletion: delete encrypted blob after recipient download is verified
  into local cache. Watched status does not control blob deletion.
- Local media: keep sent and received history on-device as encrypted packages;
  use short-lived plaintext temp files for playback and local-only thumbnail
  caches. V1 does not upload thumbnails to the relay.
- Device identity: separate encryption keypair for content-key wrapping and
  signing keypair for auth challenges.
- V1 device trust: one active device per user. Users verify a 60-digit safety
  number or signed peer-specific QR out of band; clients pin both identities in
  Keychain and fail closed on changes.
- New messages use signed Message Envelope v2. The first public client uses a
  strict cutoff and will not play unsigned incoming envelope-v1 history. Roll
  out the v2-capable client before or together with the relay's v1 rejection so
  older TestFlight clients are not broken by a server-first deployment.

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
5. Confirm the recipient identity matches the local out-of-band verification
   pin and encrypt the content key to that pinned device public key.
6. Sign the canonical Message Envelope v2 transcript with the sender device key.
7. Save an encrypted local sender copy for history/resend.
8. Upload encrypted blob and opaque signed envelope metadata to the relay.
9. Delete raw camera and plaintext compressed temporary files after encryption
   and local encrypted save succeed.

Message receive lifecycle:
1. Download encrypted blob and envelope metadata.
2. Confirm both identities match the local pin and verify the envelope signature,
   ciphertext hash, and replay key.
3. Decrypt and verify locally.
4. Save verified encrypted local recipient copy.
5. Acknowledge delivery to the relay.
6. Relay deletes its encrypted blob.

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
- [x] Local vertical slice: register, invite, record, compress, encrypt, upload,
      download, verify, local-cache acknowledge, relay-delete.
- [x] HTTPS beta relay deployment on the existing DigitalOcean host.
- [x] Secret-free CI plus an owner-run internal TestFlight lane.
- [ ] Public-release hardening: expiring challenge-response auth with Keychain
      session storage, relay retention enforcement, upload quotas/rate limits,
      failure-safe ciphertext/account deletion, executed XCTest coverage,
      two-iPhone security smoke test, a valid bundled privacy manifest, App
      Privacy labels, metadata, screenshots, and review notes.

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
- 2026-05-21: `ios/Kithra.xcodeproj` and the shared `Kithra` scheme added;
  unsigned local generic iOS and iOS Simulator builds verified on macOS with
  Xcode 16.2. Server relay vertical-slice integration test added.
- 2026-05-21: Mac toolchain setup completed with macOS 26.5, Command Line Tools
  26.5, Homebrew 5.1.12, Go 1.26.3, and Docker Desktop 4.74.0. Server tests,
  Docker Compose build/start, and relay `/healthz` verified locally.
- 2026-05-21: Local vertical slice advanced: server upload now requires a
  recipient device ID, validates contact/device ownership before blob storage,
  returns device IDs in contacts/messages, and has an in-memory relay test plus
  live Docker API smoke test covering register, invite, upload, download,
  delivery acknowledge, and relay blob delete.
- 2026-05-21: iOS app now pins Swift-Sodium 0.9.1, generates/stores X25519 and
  Ed25519 device keys in Keychain, signs challenges, wraps content keys with
  `crypto_box_seal`, encrypts compressed media with XChaCha20-Poly1305, hashes
  ciphertext with BLAKE2b, registers against the local relay, creates/accepts
  invite codes, refreshes contacts/messages, and sends captured videos through
  the encrypted upload path.
- 2026-05-21: Recipient-side iOS path added for downloaded messages: tap a
  received video to download the ciphertext, verify the BLAKE2b hash when
  present, save an encrypted local copy, acknowledge delivery so the relay
  deletes its blob, decrypt to a short-lived playback file, and play it.
- 2026-05-21: Sent-message local playback path corrected by adding an optional
  sender-sealed content-key envelope. Outgoing media remains relay-opaque while
  the sender can still decrypt the local encrypted history copy.
- 2026-05-26: iOS live refresh tightened by moving polling ownership to
  `AppState`/`RootView`, refreshing immediately when the app returns active, and
  cleaning temporary playback files on background. Inline camera now supports a
  pragmatic recording-time camera switch: tapping flip stops and sends the
  current clip, switches cameras, and leaves recording ready for the next clip.
  Verification passed for server tests, simulator build/install/launch, physical
  iPhone build/install on JQv3, `git diff --check`, and relay `/healthz`.
  Physical launch was blocked only because the device was locked.
- 2026-05-27: Simulator receive bug traced to installing an unsigned simulator
  build, which let the app list and cache messages but blocked Keychain unwraps
  with `errSecMissingEntitlement` (`-34018`). The signed simulator build now
  decrypts received messages, generates local thumbnail JPEGs for the bottom
  strip, and plays received videos. Incoming refresh now auto-caches pending
  received blobs, acknowledges delivery only after a decryptable local cache, and
  keeps local encrypted-package/thumbnail URLs hydrated across refreshes. Inline
  camera switching during recording now keeps the recording UI active, records
  camera segments, and merges them before auto-send on stop. Verification passed
  for server tests, signed simulator build/install/launch/playback, physical
  iPhone build/install/launch on JQv3, `git diff --check`, and relay `/healthz`.
- 2026-05-27: Conversation playback polished toward Marco Polo-style behavior:
  the bottom thumbnail carousel now runs oldest-to-newest from left to right and
  auto-scrolls the newest video into the right edge, tapped history videos play
  inline on the primary conversation surface instead of opening a full-screen
  sheet, and the selected thumbnail is outlined. Mid-record camera flip merge now
  applies each segment's own video orientation transform through an
  `AVMutableVideoComposition`, preventing flipped-camera segments from exporting
  sideways.
- 2026-05-27: Thumbnail playback now auto-advances through newer videos after
  the selected video ends, keeping the selected thumbnail centered in the
  carousel. Camera switching now swaps only the video input and preserves the
  existing audio input/output pipeline, reducing microphone gain changes when
  recording across front/back camera flips.
- 2026-05-27: App Store/TestFlight preparation started. Added a build-configured
  default relay URL so Debug can stay local while Release can point at the HTTPS
  beta relay. Added a basic authenticated account deletion path that removes the
  relay account and clears local device/media state from the iOS app. Drafted
  release plan, privacy policy, support page, and TestFlight/App Review notes in
  `docs/APP_STORE_RELEASE.md`, `docs/PRIVACY_POLICY_DRAFT.md`,
  `docs/SUPPORT_PAGE_DRAFT.md`, and `docs/TESTFLIGHT_NOTES.md`. Verification
  passed for server tests, simulator build, physical iPhone build,
  `plutil -lint`, and `git diff --check`.
- 2026-05-27: Existing DigitalOcean Ubuntu Droplet `joaquimpacer-wp`
  (`137.184.80.178`) prepared for the beta relay. Docker and Compose were
  installed, the relay was deployed under `/srv/speakeasy/current`, persistent
  data was created at `/srv/speakeasy/data`, Apache was configured to proxy
  `api.joaquimpacer.com` to the relay on `127.0.0.1:8080`, DigitalOcean DNS was
  updated with an `A` record for `api.joaquimpacer.com`, and Certbot installed a
  Let's Encrypt certificate. Public HTTPS verification passed for
  `https://api.joaquimpacer.com/healthz`; the relay container reports healthy.
- 2026-05-27: Switching from the local/LAN relay to the new HTTPS beta relay
  exposed stale saved-session tokens as expected (`HTTP 401: invalid bearer
  token`). iOS now awaits relay URL Apply actions and includes a Settings
  "Reset local registration" action that preserves the relay URL while clearing
  the saved account token, local media, invite state, and device keys so the
  device can register fresh on the new relay. Updated builds were installed and
  launched on the physical iPhone and simulator; Release simulator build also
  passed.
- 2026-05-27: Contact management moved into the beta slice. The relay now
  supports `DELETE /contacts/{contactID}` for one-sided contact removal, block
  now removes the blocked contact from the blocker contact list and rejects
  future uploads from that user, and metadata-only report submission is wired
  from iOS. Conversation rows now have swipe/context actions for More, Delete,
  Block, and Report. Settings now puts invite controls above account/device
  details so simulator testing can reach create/copy/accept without fighting
  the tab bar. The DigitalOcean beta relay was rebuilt and verified healthy.
- 2026-05-27: Invite entry polished for tester usability. The Settings invite
  field now formats typed codes as `SPEAK-XXXX-XXXX-XXXX`, disables accept until
  the code is complete, dismisses the keyboard on accept, and returns to the
  Videos tab after a successful contact acceptance. Invite codes can also be
  shared from the generated-code row. Added a first Kithra app icon asset
  catalog so installed builds no longer show the placeholder black icon.
- 2026-05-27: Removed the decorative play badge from the Kithra app icon,
  archived a Release iOS build, and uploaded the first Kithra package to App
  Store Connect for TestFlight processing. Verification passed for server tests,
  public beta relay `/healthz`, icon asset dimensions, `git diff --check`, and
  installing/launching the refreshed no-play-button build on the physical iPhone.
- 2026-05-28: Android/Google Play lane started while iOS TestFlight review is
  pending. Installed JDK 21, Android command-line tools, Android SDK API 36, and
  Gradle on the Mac. Added a native Kotlin Android scaffold under `android/`
  with package `com.joaquimpacer.kithra`, a release plan in
  `docs/GOOGLE_PLAY_RELEASE.md`, and Android CI. Local Android debug APK and
  release `.aab` bundle builds passed.
- 2026-07-26: Public iOS distribution selected and an initial human-gated PR
  protocol was added with exact-SHA/idempotency guards and human-only merge,
  release, privacy, and export-compliance decisions.
- 2026-08-04: Joaquim selected a Codex-led implementation/review workflow,
  retained all owner-only release gates, and selected iPhone-only for V1.
- 2026-08-09: Live App Store Connect state was verified. The local Apple
  Distribution identity is valid; version `1.0` uses manual release; public
  distribution and the free price are saved; availability covers 174
  storefronts with France explicitly unavailable pending encryption clearance;
  and Mac and Apple Vision Pro compatibility are disabled. Builds 1 through 4
  exist, but build 4 reports non-exempt encryption as `No` and supports both
  iPhone and iPad. No existing build is the V1 candidate, and no build is
  attached to version `1.0`. Screenshots, metadata, privacy, age rating,
  content rights, trader status, and App Review contact remain incomplete.

## Open Placeholders

- Public relay: `api.joaquimpacer.com`; the previously deployed HTTPS relay must
  be updated to the exact integrated release candidate before submission.
- Public support/privacy hostname: Joaquim approved
  `kithra.jqinnovation.com` on 2026-08-22. The repository configuration is
  migrated; DNS, TLS, deployment, and public reachability are not yet verified.
- CI provider: default GitHub Actions macOS unless Xcode Cloud is clearly easier.
- APNs key: create after core local message flow works.
- DigitalOcean deployment: active, but the integrated relay version is not yet
  deployed.
- Auth after app restart: the public-release candidate implements expiring,
  single-use Ed25519 login challenges, 30-day sessions, proactive/401 renewal,
  and device-bound iOS Keychain storage. Unsigned app/test builds and the relay
  tests pass. Joaquim approved C-REG on 2026-08-22: first registration now
  persists an exact pre-request intent and client-generated device ID, retries
  that same identity after an ambiguous response, and recovers a committed
  registration only through the existing signed-login challenge. The relay
  returns a generic conflict without a token for every duplicate username or
  device ID. Client-side fail-closed bootstrap/recovery UI and one-flight
  serialized registration have focused XCTest coverage; the relay path has
  focused concurrency and race coverage. Two disposable simulators completed
  registration, invite acceptance, reciprocal contacts, matching full safety
  numbers, and verification on 2026-08-22. Public release still requires the
  physical-device video smoke test and the owner-gated relay rollout, signing,
  upload, and submission decisions.
