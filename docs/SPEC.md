# Speakeasy — Technical Specification

This document describes the target architecture. `docs/API.md` and working code
are the source of truth for currently implemented endpoints and behavior.

## Vision

An open-source, self-hosted, E2E encrypted async video messaging app. The private alternative to Marco Polo.

**One sentence:** "Record a video, send it encrypted. Only the person you sent it to can watch it. Not us, not the server, not anyone."

---

## Architecture

### Server (self-hosted relay)
- Lightweight relay — stores encrypted blobs, routes notifications
- Never has access to decryption keys
- Can run on a $5/mo VPS, a Raspberry Pi, anything
- REST API is implemented; WebSocket notifications are planned
- Storage: local disk in V1; S3-compatible storage is a later option

### Client (native mobile app — Swift for iPhone V1, Kotlin for Android later)
- V1 ships for iPhone only. iPad and Android clients are deferred.
- Records video via native camera APIs (AVFoundation / CameraX)
- Encrypts locally before upload
- Decrypts on download
- Key management (generate, exchange, store in Keychain / Keystore)
- Push notifications via server are a post-V1 follow-up

### Why Native (Not React Native)
- **Camera access:** Direct AVFoundation/CameraX gives better quality, lower latency, finer control over recording
- **Crypto integration:** iOS Keychain and Android Keystore are first-class in native, bridged in RN
- **Simplicity:** The app has a small surface (record → encrypt → upload → download → decrypt → play) — doesn't benefit from cross-platform UI abstraction
- **Trust:** Native code is easier to audit for security-critical apps

### Why Go (Not Node.js) for the Server
- **Blob streaming:** Go handles concurrent large file I/O more efficiently than Node
- **Single binary:** Docker image is ~20MB vs ~200MB+ for Node
- **Crypto:** the relay performs no message-content cryptography; its only
  asymmetric operation is standard-library Ed25519 login-proof verification
  that is wire-compatible with the client's libsodium signature
- **Simplicity:** The server is a dumb relay. Go's stdlib covers HTTP, WebSocket, and file handling without a framework

### Encryption
- **libsodium** only for message-content cryptography.
- Each device has separate keys for encryption and authentication.
- Each video gets a fresh random content key.
- Video payloads are encrypted on-device with XChaCha20-Poly1305.
- The content key is encrypted to the recipient device encryption public key.
- Login challenges, peer-specific contact-verification QR payloads, and Message
  Envelope v2 transcripts are signed with the device signing private key.
- Before messaging, users verify relay-scoped device identities with a 60-digit
  safety number or signed QR code; clients pin the result locally and fail
  closed on identity changes.
- Device private keys are stored in iOS Keychain / Android Keystore. Use Secure Enclave only where the platform supports the key type and access-control policy.
- V1 provides end-to-end encryption and per-message blast-radius reduction. Full Signal-style forward secrecy with prekeys/ratcheting is a V2 goal, not a V1 claim.

---

## Message Encryption Flow

1. User A generates encryption and signing keypairs on device, registers public keys with server
2. User B generates encryption and signing keypairs on device, registers public keys with server
3. User A sends video:
   - Confirms B's current relay-scoped identity exactly matches the local
     out-of-band verification pin
   - Records a raw temporary camera file
   - Compresses/transcodes it into a delivery video
   - Generates a fresh random content key
   - Encrypts the compressed video locally
   - Encrypts the content key to B's device encryption public key
   - Signs the canonical Message Envelope v2 transcript with A's Ed25519 key
   - Saves an encrypted local sender copy
   - Deletes raw and plaintext temporary files after encryption succeeds
4. Server stores encrypted blob + envelope metadata
5. User B downloads:
   - Confirms sender and recipient identities match its local verification pin
   - Verifies the Ed25519 envelope signature, signed ciphertext hash, and
     `clientMessageID` replay key
   - Stages the hash-verified ciphertext, reserves a signature-bound pending
     replay receipt, atomically saves the encrypted local recipient copy, and
     marks the receipt committed without replacing existing history
   - Decrypts and verifies locally only after that committed receipt
   - Acknowledges verified local cache to the server
6. Server deletes its encrypted blob after verified cache acknowledgement
7. **Server never sees plaintext video, plaintext thumbnails, content keys, or private keys**

---

## API Design

### Auth
- `POST /auth/register` — create account (username + device public key)
- `POST /auth/challenge` — issue a short-lived, single-use device challenge
- `POST /auth/login` — verify the signed challenge and create an expiring
  bearer session
- `POST /auth/logout` — revoke every session and outstanding challenge for the
  authenticated device
- `POST /auth/device` — planned later multi-device registration; V1 permits one
  active device per user

### Messages
- `POST /messages` — upload encrypted video blob and envelope metadata
- `GET /messages` — list messages for authenticated user
- `GET /messages/:id` — download encrypted blob
- `POST /messages/:id/delivered` — acknowledge recipient download verified into local cache; server deletes blob
- `PATCH /messages/:id/status` — let the recipient mark a locally cached,
  relay-deleted message watched
- `DELETE /messages/:id` — delete message

### Contacts
- `POST /contacts/invite` — generate invite link/code
- `POST /contacts/accept` — accept invite, exchange public keys
- `GET /contacts` — list contacts with public keys

### WebSocket
- Planned: `ws://server/ws` for real-time notifications. The current iPhone
  client polls while open.

---

## Data Model

### User
```
id: uuid
username: string (unique)
created_at: timestamp
```

### Device
```
id: uuid
user_id: uuid (FK -> User)
name: string
encryption_public_key: bytes (X25519)
signing_public_key: bytes (Ed25519)
created_at: timestamp
last_seen_at: timestamp (optional)
```

### Message
```
id: uuid
sender_id: uuid (FK → User)
recipient_id: uuid (FK → User)
envelope: json
encrypted_blob_path: string
blob_size: integer
status: enum (sent, delivered, watched, expired)
delivered_at: timestamp (optional)
blob_deleted_at: timestamp (optional)
created_at: timestamp
expires_at: timestamp (default: created_at + configured retention window)
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
2. Write raw camera output to a temporary file
3. Compress/transcode client-side before encryption
4. Encrypt the deliverable and persist only its encrypted local-history copy
5. Derive a local thumbnail for the UI in temporary storage; V1 does not upload
   thumbnails to the relay
6. Delete raw and plaintext compressed temporary files after encrypted local save succeeds

### Upload
1. Generate fresh random content key
2. Encrypt compressed video locally with libsodium
3. Encrypt content key to recipient's device encryption public key
4. Save encrypted local sender copy for history and resend
5. Upload encrypted blob to server
6. Server stores the blob; the current recipient discovers it by foreground
   polling. WebSocket and push notifications are follow-ups.

### Download & Playback
1. Receive notification
2. Download encrypted blob
3. Verify pinned direction/identities, signature, and ciphertext hash locally
4. Reserve the exact pending replay receipt, atomically save the encrypted
   local recipient copy without replacement, and mark the receipt committed
5. Decrypt only after the committed receipt, then acknowledge the verified
   cache; the server deletes its relay blob
6. For playback, decrypt the local encrypted package to a protected,
   short-lived plaintext temp file
7. Play in-app and clean plaintext after playback, backgrounding, or the cleanup timeout

---

## Challenges & Mitigations

### Video file sizes
- Client-side compression before encryption
- Chunked upload/download with resume
- Configurable quality settings
- Target: 480p default, 720p optional
- Local auto-delete controls for sent and received videos
- Store durable local history encrypted at rest; do not keep raw camera captures

### Push notifications
- APNs (iPhone) and FCM (Android) are post-V1 follow-ups
- Content-blind push ("You have a new message" — no preview)
- Future: UnifiedPush for fully self-hosted push

### Key loss/recovery
- V1: No recovery. Lose device = lose keys = lose access to old local encrypted messages.
- V2: Optional encrypted key backup (passphrase-derived key encrypts device key, stored on server)

### Group messaging
- Out of scope for V1
- V2 approach: Sender encrypts once per recipient (fan-out)
- Alternatively: MLS (Messaging Layer Security) protocol for efficient group crypto

---

## Security Considerations

- **Metadata:** Server knows who talks to whom. Onion routing is overkill for V1.
- **Key verification:** V1 uses relay-scoped safety numbers and signed,
  peer-specific QR codes. It pins one active device per user and requires fresh
  verification after identity changes.
- **Server compromise:** An attacker gets encrypted blobs plus relay-held
  account, session, contact, routing, status, block, and report metadata. The
  blobs do not reveal plaintext video without device keys, but the metadata and
  bearer sessions remain sensitive.
- **Device compromise:** Standard mobile security applies. Keys are protected by Keychain / Keystore and optional local biometric access control.
- **Forward secrecy:** V1 uses fresh content keys per message but does not claim full Signal-style forward secrecy. True forward secrecy with prekeys/ratcheting is V2.

---

## Trust Model

### How can users trust the app?

The same way you trust Signal — layers of verifiability:

1. **Open source** — all code is public. Encryption happens client-side, anyone can audit it.
2. **Reproducible-build goal** — deterministic verification of the App Store
   binary against public source is desirable but is not established for V1.
3. **No relay trust for verified content** — after both users verify their
   device identities, a compromised relay cannot decrypt content, substitute
   keys unnoticed, or forge authenticated envelopes. It still sees routing and
   timing metadata and can withhold, reorder, or replay ciphertext.
4. **Minimal permissions** — camera and microphone for recording, photo-library
   access for user-selected fallback video, local-network access for self-hosted
   relays, and network access. No Contacts or location permission; no analytics
   SDKs or tracking.
5. **Key verification (V1)** — safety numbers and signed QR codes let users
   authenticate the exact device keys over an independent channel.

### What verified users do not entrust to the relay
- Video confidentiality
- Sender/device authentication and signed-envelope integrity

The relay is still trusted for availability and necessarily observes routing
metadata. Reproducible-build and independent-audit claims apply only after the
documented build process is implemented and independently checked.

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
