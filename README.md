# 🥃 Speakeasy

**E2E encrypted async video messaging. Self-hosted. Open source.**

Record a video, send it encrypted. Only the sender's and intended recipient's
devices can decrypt it; the relay cannot view the plaintext.

## Why

Speakeasy explores a privacy-first approach to asynchronous video messaging:
native clients encrypt video before upload, and the relay can be self-hosted.
Competitive comparisons are intentionally kept out of this pre-release README
until they are re-verified for publication.

## How It Works

1. You record a video on your phone
2. It's encrypted **on your device** with your recipient's public key
3. The encrypted blob uploads to the server
4. Your friend's device downloads and decrypts it with their private key
5. **The server never sees plaintext video content.**

### What the server knows
- Who sent a message to whom (metadata)
- When messages were sent
- Size of encrypted blobs

### What the server does NOT know
- Plaintext video, audio, or thumbnail content
- Device private encryption and signing keys

## Tech Stack

- **Server:** Go — lightweight encrypted blob relay, single binary, tiny Docker image
- **Client:** Swift (iPhone V1) — native camera/crypto/Keychain access. iPad and Kotlin/Android clients follow later.
- **Crypto:** [libsodium](https://doc.libsodium.org/) — XChaCha20-Poly1305, per-message encrypted content keys
- **Deploy:** Docker + docker-compose (one-command self-host)
- **Storage:** Local filesystem (S3-compatible storage is not implemented yet)

## MVP Scope (V1)

**In:**
- 1:1 async video messaging
- E2E encryption (libsodium)
- Self-hosted server (Docker)
- iPhone app (native Swift)
- Contact management (invite by link/code)
- Delivery receipts (sent/delivered/watched)

**Out (V2+):**
- Group conversations
- iPad support
- Android app
- Push notifications
- Voice-only messages
- Text overlay, reactions
- Disappearing messages
- Web client
- Key backup/recovery

## Self-Host

```bash
docker-compose up -d
```

This starts the development relay over plaintext HTTP. Before exposing it to a
network, follow `docs/DEPLOYMENT.md` to add TLS, persistent storage, access
controls, and host hardening. Self-hosting the relay does not install the native
iPhone app.

## Security

- **libsodium** — battle-tested, hard to misuse
- **Per-message content keys** — each video is encrypted independently; full Signal-style forward secrecy is a V2 goal
- **No analytics, no tracking, no telemetry** — the relay processes only the
  operational metadata disclosed above and in the privacy policy
- **No phone number required** — usernames or invite codes
- **Open source** — verify everything yourself

## Project Status

🚧 **Pre-release** — the Go relay and native iPhone app are implemented and
under release hardening. Kithra is not yet submitted for public App Store
review.

## Planning Docs

- `docs/BUILD_PLAN.md` — active build plan, agent handoff, roadmap, and status log
- `docs/OWNER_SETUP.md` — owner checklist for Apple, DNS, CI secrets, APNs, and later Google Play
- `docs/API.md` — first local vertical-slice API contract
- `docs/CODEX_REVIEW_LOOP.md` — Codex-led, human-gated PR workflow

## License

MIT
