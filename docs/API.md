# Speakeasy API Contract

This contract is intentionally small for the first local vertical slice. Payloads
may grow, but the relay must stay content-blind: no endpoint accepts plaintext
video, plaintext thumbnails, content keys, private keys, or decrypted report
attachments.

## Conventions

- JSON request and response bodies unless an endpoint explicitly transfers a
  binary encrypted blob.
- IDs are server-generated strings.
- Timestamps are RFC 3339 strings.
- Binary keys and envelope fields are standard base64 strings in JSON. This
  matches Swift `Data` and Go `[]byte` JSON defaults.
- Authentication is device-token based for the first scaffold and must move to
  challenge-response before public beta.
- Each device has separate public keys:
  - `encryptionPublicKey` for message content-key wrapping.
  - `signingPublicKey` for authentication challenges, signed contact-verification
    QR payloads, and authenticated message envelopes.
- Public-release clients use one active device per user in Identity Verification
  v1. Contact keys must be verified and pinned locally before messaging; the
  relay is not a trust authority for key changes.

## Auth

### `POST /auth/register`

Request:

```json
{
  "username": "alex",
  "deviceName": "Alex iPhone",
  "encryptionPublicKey": "base64-x25519-public-key",
  "signingPublicKey": "base64-ed25519-public-key"
}
```

Response:

```json
{
  "user": {
    "id": "uuid",
    "username": "alex",
    "createdAt": "2026-05-14T00:00:00Z"
  },
  "device": {
    "id": "uuid",
    "userID": "uuid",
    "name": "Alex iPhone",
    "encryptionPublicKey": "base64-x25519-public-key",
    "signingPublicKey": "base64-ed25519-public-key",
    "createdAt": "2026-05-14T00:00:00Z"
  },
  "bearerToken": "development-token"
}
```

## Contacts

### `POST /contacts/invite`

Creates a single-use invite code for the authenticated user.

Response:

```json
{
  "inviteId": "inv_...",
  "code": "SPEAK-ABCD-EFGH",
  "expiresAt": "2026-05-21T00:00:00Z"
}
```

### `POST /contacts/accept`

Request:

```json
{
  "code": "SPEAK-ABCD-EFGH"
}
```

Response:

```json
{
  "userID": "uuid",
  "contactID": "uuid",
  "username": "alex",
  "nickname": "",
  "encryptionPublicKey": "base64-x25519-public-key",
  "signingPublicKey": "base64-ed25519-public-key",
  "createdAt": "2026-05-14T00:00:00Z"
}
```

### `GET /contacts`

Returns contacts and their current public device keys.

The returned keys are untrusted candidates. Clients compare them with the local
Keychain pin and enter `keyChanged` instead of silently replacing a verified
identity. QR/safety-number verification is client-to-client and requires no
relay endpoint. See `docs/IDENTITY_VERIFICATION.md`.

## Messages

### `POST /messages`

Uploads message metadata and an encrypted blob. The first scaffold may use a
multipart request with `metadata` JSON plus `blob` bytes. Later versions can add
chunked upload without changing the content-blind model.

Metadata:

```json
{
  "recipientID": "usr_...",
  "recipientDeviceID": "dev_...",
  "envelope": {
    "version": 2,
    "senderDeviceID": "uuid",
    "recipientDeviceID": "uuid",
    "media": {
      "algorithm": "XChaCha20-Poly1305",
      "nonce": "base64-24-byte-nonce",
      "ciphertextHash": "base64-32-byte-blake2b-hash",
      "mimeType": "video/mp4",
      "durationSeconds": 42.125,
      "thumbnail": null
    },
    "contentKey": {
      "algorithm": "crypto_box_seal",
      "encryptedContentKey": "base64-sealed-content-key",
      "recipientPublicKeyFingerprint": null
    },
    "senderContentKey": null,
    "createdAt": "2026-08-02T17:18:32Z",
    "clientMessageID": "uuid",
    "senderIdentityDigest": "base64-32-byte-identity-digest",
    "recipientIdentityDigest": "base64-32-byte-identity-digest",
    "authenticationAlgorithm": "Ed25519",
    "signature": "base64-64-byte-signature"
  },
  "blobSize": 123456,
  "durationMs": 42000
}
```

The bearer session supplies the sender user ID and upload metadata supplies the
recipient user ID to the signed canonical transcript. New clients upload version
2 only. The relay validates the v2 shape, literal algorithms, and fixed lengths
before writing a blob, then stores it opaquely; it does not verify the signature,
create, rewrite, or downgrade the envelope. Exact signing bytes and the strict
v1 cutoff/deployment order are in
`docs/MESSAGE_ENVELOPE_V2.md`.

The metadata JSON is capped at 64 KiB and its nested envelope at 48 KiB.
Unknown envelope/metadata fields and values the Swift client cannot decode are
rejected. Version 2 uses exact UTC whole-second `createdAt`; bounded nonempty
MIME/fingerprint/thumbnail-path strings; finite nonnegative duration; and the
fixed binary sizes documented in the protocol.

Response:

```json
{
  "messageId": "msg_...",
  "status": "sent",
  "expiresAt": "2026-05-21T00:00:00Z"
}
```

### `GET /messages`

Lists metadata for messages sent by or addressed to the authenticated user.

### `GET /messages/{messageId}`

Returns encrypted blob bytes plus envelope metadata for an authorized sender or
recipient.

Before decrypting a new version-2 message, the recipient verifies its pinned
identities, signed transcript, ciphertext hash, and replay key. An unsigned
version-1 envelope must never be represented as authenticated.

### `POST /messages/{messageId}/delivered`

Recipient acknowledges that the encrypted blob was downloaded, decrypted,
verified, and saved into local encrypted cache. The relay deletes its encrypted
blob after this acknowledgement.

Response:

```json
{
  "messageId": "msg_...",
  "status": "delivered",
  "blobDeleted": true
}
```

### `PATCH /messages/{messageId}/status`

Updates metadata-only status such as `watched`.

Request:

```json
{
  "status": "watched"
}
```

## Safety

### `POST /blocks`

Blocks another user from sending future messages to the authenticated user.

### `POST /reports`

Creates a metadata-only abuse report. The request must not include decrypted
video content.
