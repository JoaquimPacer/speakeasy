# Speakeasy — Technical Specification

## Vision

An open-source, self-hosted, E2E encrypted async video messaging app. The private alternative to Marco Polo.

**One sentence:** "Record a video, send it encrypted. Only the person you sent it to can watch it. Not us, not the server, not anyone."

---

## Architecture

### Server (self-hosted relay)
- Lightweight relay — stores encrypted blobs, routes notifications
- Never has access to decryption keys
- Can run on a $5/mo VPS, a Raspberry Pi, anything
- REST API + WebSocket for real-time notifications
- Storage: local disk or S3-compatible

### Client (native mobile app — Swift for iOS, Kotlin for Android)
- Records video via native camera APIs (AVFoundation / CameraX)
- Encrypts locally before upload
- Decrypts on download
- Key management (generate, exchange, store in Secure Enclave / Keystore)
- Push notifications via server

### Why Native (Not React Native)
- **Camera access:** Direct AVFoundation/CameraX gives better quality, lower latency, finer control over recording
- **Crypto integration:** iOS Keychain/Secure Enclave and Android Keystore are first-class in native, bridged in RN
- **Simplicity:** The app has a small surface (record → encrypt → upload → download → decrypt → play) — doesn't benefit from cross-platform UI abstraction
- **Trust:** Native code is easier to audit for security-critical apps

### Why Go (Not Node.js) for the Server
- **Blob streaming:** Go handles concurrent large file I/O more efficiently than Node
- **Single binary:** Docker image is ~20MB vs ~200MB+ for Node
- **Crypto:** `golang.org/x/crypto/nacl` is stdlib-adjacent — no npm dependency tree
- **Simplicity:** The server is a dumb relay. Go's stdlib covers HTTP, WebSocket, and file handling without a framework

### Encryption
- **libsodium** (NaCl) — battle-tested, hard to misuse
- `crypto_box_seal` for initial key exchange (asymmetric)
- `crypto_secretbox` for video encryption (symmetric, XChaCha20-Poly1305)
- Per-message ephemeral keys for forward secrecy
- Device-side key storage in iOS Keychain / Android Keystore

---

## Key Exchange Flow

1. User A generates keypair on device, registers public key with server
2. User B generates keypair on device, registers public key with server
3. User A sends video:
   - Generates ephemeral keypair
   - Derives shared secret: `crypto_box_beforenm(ephemeral_secret, B_public)`
   - Encrypts video with shared secret using `crypto_secretbox`
   - Sends: encrypted blob + ephemeral public key
4. Server stores encrypted blob + ephemeral public key
5. User B downloads:
   - Derives shared secret: `crypto_box_beforenm(B_secret, ephemeral_public)`
   - Decrypts video
6. **Server never sees plaintext video or private keys**

---

## API Design

### Auth
- `POST /auth/register` — create account (username + device public key)
- `POST /auth/login` — authenticate (challenge-response with device key)
- `POST /auth/device` — register additional device

### Messages
- `POST /messages` — upload encrypted video blob
- `GET /messages` — list messages for authenticated user
- `GET /messages/:id` — download encrypted blob
- `PATCH /messages/:id/status` — update delivery status (delivered/watched)
- `DELETE /messages/:id` — delete message

### Contacts
- `POST /contacts/invite` — generate invite link/code
- `POST /contacts/accept` — accept invite, exchange public keys
- `GET /contacts` — list contacts with public keys

### WebSocket
- `ws://server/ws` — real-time notifications (new message, status updates)

---

## Data Model

### User
```
id: uuid
username: string (unique)
public_key: bytes (X25519)
created_at: timestamp
```

### Message
```
id: uuid
sender_id: uuid (FK → User)
recipient_id: uuid (FK → User)
ephemeral_public_key: bytes
encrypted_blob_path: string
blob_size: integer
status: enum (sent, delivered, watched)
created_at: timestamp
expires_at: timestamp (optional)
```

### Contact
```
user_id: uuid (FK → User)
contact_id: uuid (FK → User)
nickname: string (optional)
created_at: timestamp
```

---

## Video Pipeline

### Recording
1. Capture video via device camera (AVFoundation / CameraX)
2. Compress client-side (target: ~2MB/min at 480p, configurable)
3. Generate thumbnail (also encrypted separately)

### Upload
1. Generate ephemeral keypair
2. Derive shared secret with recipient's public key
3. Encrypt video + thumbnail with `crypto_secretbox`
4. Chunked upload to server (5MB chunks for reliability)
5. Server stores blob, notifies recipient via WebSocket + push

### Download & Playback
1. Receive notification
2. Download encrypted blob (chunked)
3. Decrypt with device private key + ephemeral public key
4. Cache decrypted video locally (auto-delete configurable)
5. Play in-app

---

## Challenges & Mitigations

### Video file sizes
- Client-side compression before encryption
- Chunked upload/download with resume
- Configurable quality settings
- Target: 480p default, 720p optional

### Push notifications
- APNs (iOS) + FCM (Android) for V1
- Content-blind push ("You have a new message" — no preview)
- Future: UnifiedPush for fully self-hosted push

### Key loss/recovery
- V1: No recovery. Lose device = lose keys = lose access to old messages.
- V2: Optional encrypted key backup (passphrase-derived key encrypts device key, stored on server)

### Group messaging
- Out of scope for V1
- V2 approach: Sender encrypts once per recipient (fan-out)
- Alternatively: MLS (Messaging Layer Security) protocol for efficient group crypto

---

## Security Considerations

- **Metadata:** Server knows who talks to whom. Onion routing is overkill for V1.
- **Key verification:** Safety numbers (like Signal) for verifying contacts. V2.
- **Server compromise:** Attacker gets encrypted blobs only. Useless without device keys.
- **Device compromise:** Standard mobile security applies. Keys in secure enclave.
- **Forward secrecy:** Ephemeral keys per message = past messages safe if current key compromised.

---

## Trust Model

### How can users trust the app?

The same way you trust Signal — layers of verifiability:

1. **Open source** — all code is public. Encryption happens client-side, anyone can audit it.
2. **Reproducible builds** — deterministic builds let users verify the App Store binary matches the public source code.
3. **No server trust required** — the server only stores encrypted blobs. Even a compromised server reveals nothing.
4. **Minimal permissions** — camera + network only. No contacts, no location, no analytics SDKs, no tracking.
5. **Key verification (V2)** — safety numbers (like Signal) so users can verify they're talking to who they think.

### What you don't have to trust
- The server operator (they can't see your videos)
- The App Store (reproducible builds verify the binary)
- Us (the code is open — verify it yourself)

---

## Deployment

### Docker (primary)
```yaml
version: '3.8'
services:
  speakeasy:
    image: speakeasy/server:latest
    ports:
      - "8080:8080"
    volumes:
      - ./data:/data
    environment:
      - STORAGE_PATH=/data/blobs
      - DB_PATH=/data/speakeasy.db
      - PUSH_APNS_KEY=...  # optional
      - PUSH_FCM_KEY=...   # optional
```

### Requirements
- Any machine that runs Docker
- Disk space for encrypted blobs
- A domain + TLS cert (Let's Encrypt) for production use
