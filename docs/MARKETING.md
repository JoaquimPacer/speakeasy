# Kithra talking points

> Unpublished internal working notes. Re-check every third-party comparison,
> product-status statement, and community rule immediately before publishing.

The repository behind Kithra is mapped in [REPO_MAP.md](REPO_MAP.md).

## One-line description

Kithra is a native iPhone app for private asynchronous video messages: the
phones encrypt and authenticate each video, while a relay you can self-host
stores and routes ciphertext it cannot decrypt.

## Thirty-second description

Kithra aims for the easy back-and-forth rhythm of an asynchronous video app
without asking the relay operator to safeguard readable family videos. The
sender's iPhone encrypts locally to a verified contact key, the Go relay stores
and forwards ciphertext, and the recipient's iPhone verifies and decrypts
locally. The code is open source, the relay can be run with Docker Compose, and
the product has no analytics, advertising, tracking, or telemetry.

## Accurate technical points

- Kithra uses libsodium-backed X25519, Ed25519, and XChaCha20-Poly1305
  primitives; it does not implement custom cryptographic algorithms.
- Each video uses a fresh random content key. This reduces the blast radius of
  one exposed content key, but V1 has no prekey ratchet and must not be marketed
  as providing Signal-style forward secrecy.
- Contacts can verify device keys with a 60-digit safety number or a signed,
  peer-specific QR code. Signed envelopes bind the ciphertext and message
  metadata to the verified sender key.
- The relay cannot decrypt verified message content. It still sees routing,
  timing, IP-address, and blob-size metadata and can deny or delay service.
- Self-hosting means running the Go relay. It does not provide an alternate way
  to install the native iPhone client.
- The implemented relay uses SQLite and local-filesystem blob storage.
  S3-compatible storage is not implemented.

## Current release status

- Kithra V1 is iPhone-only. The Android directory is a future-client scaffold,
  not a usable Android app.
- The app is pre-submission. It is not currently in App Store review and has no
  public App Store URL.
- Internal TestFlight is reserved for smoke-testing the exact release candidate
  before Joaquim authorizes submission.
- Do not publish launch posts until the public install link, support/privacy
  pages, clean-host relay test, two-device security smoke test, and final
  technical review are complete.

## Honest answers to fair questions

- **Why not Signal?** Signal is the right answer for many people. Kithra is
  focused specifically on the asynchronous video-journal rhythm and a
  self-hostable relay.
- **Do users have to trust the hosted relay?** Verified users do not have to
  trust it for message-content confidentiality, authenticity, or integrity.
  They still rely on it for availability and expose routing metadata to it.
- **Is it fully forward-secret?** No. Fresh content keys isolate messages from
  one another, but compromise of a long-term device key plus retained old
  ciphertext may put old messages at risk. A ratcheting protocol is outside V1.
- **Can someone self-host everything?** The relay can be self-hosted. The V1
  client is still distributed as a native iPhone app.
