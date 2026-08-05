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
      push/            APNs push notification service
    Dockerfile
    go.mod
  ios/                 Native Swift iOS app
    Speakeasy/
      API/             Server communication
      Crypto/          libsodium envelope and local encryption
      Media/           Recording, compression, playback temp files
      Store/           Local state and encrypted media cache
      Views/           SwiftUI screens
    Speakeasy.xcodeproj
  docker-compose.yml
  docs/
    BUILD_PLAN.md
    OWNER_SETUP.md
    SPEC.md
    SECURITY.md
    ARCHITECTURE.md
```

## Server Responsibilities

- Authenticate devices without passwords using challenge-response.
- Store public device keys and never store private keys.
- Create and accept contact invites.
- Store encrypted blobs only until verified recipient cache or expiry.
- Track metadata-only delivery and watched status.
- Support block/report metadata without receiving plaintext content.
- Provide content-blind push notifications when APNs is configured.

## iOS Responsibilities

- Generate and store private keys in Keychain.
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
