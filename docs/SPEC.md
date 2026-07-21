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
- Key management (generate, exchange, store in Keychain / Keystore)
- Push notifications via server

### Why Native (Not React Native)
- **Camera access:** Direct AVFoundation/CameraX gives better quality, lower latency, finer control over recording
- **Crypto integration:** iOS Keychain and Android Keystore are first-class in native, bridged in RN
- **Simplicity:** The app has a small surface (record → encrypt → upload → download → decrypt → play) — doesn't benefit from cross-platform UI abstraction
- **Trust:** Native code is easier to audit for security-critical apps

### Why Go (Not Node.js) for the Server
- **Blob streaming:** Go handles concurrent large file I/O more efficiently than Node
- **Single binary:** Docker image is ~20MB vs ~200MB+ for Node
- **Crypto:** `golang.org/x/crypto/nacl` is stdlib-adjacent — no npm dependency tree
- **Simplicity:** The server is a dumb relay. Go's stdlib covers HTTP, WebSocket, and file handling without a framework

### Encryption
- **libsodium** only for message-content cryptography.
- Each device has separate keys for encryption and authentication.
- Each video gets a fresh random content key.
- Video payloads are encrypted on-device with XChaCha20-Poly1305.
- The content key is encrypted to the recipient device encryption public key.
- Login challenge responses are signed with the device signing private key.
- Device private keys are stored in iOS Keychain / Android Keystore. Use Secure Enclave only where the platform supports the key type and access-control policy.
- V1 provides end-to-end encryption and per-message blast-radius reduction. Full Signal-style forward secrecy with prekeys/ratcheting is a V2 goal, not a V1 claim.

---

## Message Encryption Flow

1. User A generates encryption and signing keypairs on device, registers public keys with server
2. User B generates encryption and signing keypairs on device, registers public keys with server
3. User A sends video:
   - Records a raw temporary camera file
   - Compresses/transcodes it into a delivery video
   - Generates a fresh random content key
   - Encrypts the compressed video locally
   - Encrypts the content key to B's device encryption public key
   - Saves an encrypted local sender copy
   - Deletes raw and plaintext temporary files after encryption succeeds
4. Server stores encrypted blob + envelope metadata
5. User B downloads:
   - Decrypts and verifies locally
   - Saves an encrypted local recipient copy
   - Acknowledges verified local cache to the server
6. Server deletes its encrypted blob after verified cache acknowledgement
7. **Server never sees plaintext video, plaintext thumbnails, content keys, or private keys**

---

## API Design

### Auth
- `POST /auth/register` — create account (username + device public key)
- `POST /auth/login` — authenticate (challenge-response with device key)
- `POST /auth/device` — register additional device

### Messages
- `POST /messages` — upload encrypted video blob and envelope metadata
- `GET /messages` — list messages for authenticated user
- `GET /messages/:id` — download encrypted blob
- `POST /messages/:id/delivered` — acknowledge recipient download verified into local cache; server deletes blob
- `PATCH /messages/:id/status` — update watched status and other metadata-only states
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
4. Generate thumbnail (also encrypted separately)
5. Delete raw and plaintext compressed temporary files after encrypted local save succeeds

### Upload
1. Generate fresh random content key
2. Encrypt compressed video + thumbnail locally with libsodium
3. Encrypt content key to recipient's device encryption public key
4. Save encrypted local sender copy for history and resend
5. Upload encrypted blob to server
6. Server stores blob, notifies recipient via WebSocket + push

### Download & Playback
1. Receive notification
2. Download encrypted blob
3. Decrypt and verify locally
4. Save encrypted local recipient copy
5. Acknowledge verified cache to server; server deletes relay blob
6. For playback, decrypt local encrypted package to a short-lived plaintext temp file
7. Play in-app and clean plaintext temp file after playback/background/cleanup timeout

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
- APNs (iOS) + FCM (Android) for V1
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
- **Key verification:** Safety numbers (like Signal) for verifying contacts. V2.
- **Server compromise:** Attacker gets encrypted blobs only. Useless without device keys.
- **Device compromise:** Standard mobile security applies. Keys are protected by Keychain / Keystore and optional local biometric access control.
- **Forward secrecy:** V1 uses fresh content keys per message but does not claim full Signal-style forward secrecy. True forward secrecy with prekeys/ratcheting is V2.

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
