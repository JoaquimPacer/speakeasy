# 🥃 Speakeasy

**E2E encrypted async video messaging. Self-hosted. Open source.**

Record a video, send it encrypted. Only the person you sent it to can watch it. Not us, not the server, not anyone.

## Why

[Marco Polo](https://marcopolo.me/) has a **WARNING** privacy rating. They don't offer E2E encryption, can access your video content, and profile your data. There is no open-source, self-hosted, E2E encrypted alternative for async video messaging.

**Nobody occupies this market square.** Until now.

| App | E2E | Self-hosted | Open Source | Async Video |
|-----|:---:|:-----------:|:-----------:|:-----------:|
| Marco Polo | ❌ | ❌ | ❌ | ✅ |
| Signal | ✅ | ❌ | ✅ | ❌ |
| Matrix/Element | ✅ | ✅ | ✅ | ⚠️ |
| Telegram | ❌* | ❌ | Partial | ❌ |
| **Speakeasy** | ✅ | ✅ | ✅ | ✅ |

## How It Works

1. You record a video on your phone
2. It's encrypted **on your device** with your recipient's public key
3. The encrypted blob uploads to the server
4. Your friend's device downloads and decrypts it with their private key
5. **The server never sees the video content. Ever.**

### What the server knows
- Who sent a message to whom (metadata)
- When messages were sent
- Size of encrypted blobs

### What the server does NOT know
- Video content, audio, thumbnails — anything useful

## Tech Stack

- **Server:** Node.js — lightweight encrypted blob relay
- **Client:** React Native (iOS first, Android to follow)
- **Crypto:** [libsodium](https://doc.libsodium.org/) — XChaCha20-Poly1305, per-message ephemeral keys
- **Deploy:** Docker + docker-compose (one-command self-host)
- **Storage:** Local filesystem + optional S3-compatible

## MVP Scope (V1)

**In:**
- 1:1 async video messaging
- E2E encryption (libsodium)
- Self-hosted server (Docker)
- iOS app (React Native)
- Push notifications
- Contact management (invite by link/code)
- Delivery receipts (sent/delivered/watched)

**Out (V2+):**
- Group conversations
- Android app
- Voice-only messages
- Text overlay, reactions
- Disappearing messages
- Web client
- Key backup/recovery

## Self-Host

```bash
docker-compose up -d
```

That's it. Your server, your data, your rules.

## Security

- **libsodium** — battle-tested, hard to misuse
- **Per-message ephemeral keys** — forward secrecy by default
- **No analytics, no tracking, no telemetry** — zero data collection
- **No phone number required** — usernames or invite codes
- **Open source** — verify everything yourself

## Project Status

🚧 **Early development** — spec complete, building MVP.

## License

MIT
