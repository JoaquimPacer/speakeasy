# Architecture

Speakeasy is a store-and-forward async video messaging system. The server is an
untrusted relay: it stores encrypted blobs and metadata, but it never receives
plaintext video, plaintext thumbnails, content keys, or private keys.

## Message Flow

```text
Device A                         Relay Server                    Device B
--------                         ------------                    --------
Record raw temp video
Compress/transcode
Encrypt locally
Save encrypted local copy
Upload encrypted blob      -->   Store encrypted blob
                                  Notify recipient          -->   Download blob
                                                                 Decrypt/verify
                                                                 Save encrypted
                                                                 local copy
Delivery ack               <--   Delete relay blob          <--   Ack verified
```

Watched status is metadata only. The relay deletes the server-side encrypted
blob after the recipient has downloaded, decrypted, verified, and saved the
message into local encrypted cache.

## Components

```text
speakeasy/
  server/              Go relay server
    cmd/               Entry points
    internal/
      api/             REST handlers
      db/              SQLite access and migrations
      storage/         Local encrypted blob storage
      # push/APNs is a planned follow-up; no push package exists yet
    Dockerfile
    go.mod
  ios/                 Native Swift iPhone app (V1)
    Speakeasy/
      API/             Server communication
      Crypto/          libsodium envelope and local encryption
      Media/           Recording, compression, playback temp files
      Store/           Local state and encrypted media cache
      Views/           SwiftUI screens
    Kithra.xcodeproj
  docker-compose.yml
  docs/
    BUILD_PLAN.md
    OWNER_SETUP.md
    SPEC.md
    SECURITY.md
    ARCHITECTURE.md
```

## Server Responsibilities

- Register devices, issue expiring bearer sessions, and verify single-use
  device-signed login challenges without receiving a private key.
- Store public device keys and never store private keys.
- Create and accept contact invites.
- Store encrypted blobs until verified recipient cache; each blob also records
  an expiry. The candidate runs retry-safe cleanup at startup and hourly.
  Deploying that candidate, which activates deletion on the live relay, remains
  an explicit owner-gated action.
- Track metadata-only delivery and watched status.
- Support block/report metadata without receiving plaintext content.
- Support foreground polling today; content-blind APNs is a post-V1 follow-up.

## iOS Responsibilities

- Generate and store private keys and relay bearer authority in separate,
  device-bound Keychain items.
- Renew rejected or nearly expired sessions with the protected signing key and
  reject any response whose user, device ID, or public keys changed.
- Record video with AVFoundation.
- Compress/transcode before encryption.
- Encrypt media with libsodium before upload.
- Keep sent and received history as encrypted local packages.
- Decrypt to short-lived plaintext temp files only for playback.
- Clean raw capture files, plaintext intermediates, and playback temp files.

## Trust Boundaries

- TLS protects network transport to the relay.
- E2E encryption protects message content from the relay.
- The relay still sees metadata: user IDs, IP addresses, timestamps, blob sizes,
  delivery state, and retention state.
- V1 does not claim full Signal-style forward secrecy. True prekey/ratchet
  forward secrecy is a V2 goal.
