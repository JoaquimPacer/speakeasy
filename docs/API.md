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
  - `signingPublicKey` for authentication challenge verification.

## Auth

### `POST /auth/register`

Request:

```json
{
  "username": "joshua",
  "deviceName": "Joshua iPhone",
  "encryptionPublicKey": "base64-x25519-public-key",
  "signingPublicKey": "base64-ed25519-public-key"
}
```

Response:

```json
{
  "user": {
    "id": "uuid",
    "username": "joshua",
    "createdAt": "2026-05-14T00:00:00Z"
  },
  "device": {
    "id": "uuid",
    "userID": "uuid",
    "name": "Joshua iPhone",
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
  "username": "joshua",
  "nickname": "",
  "encryptionPublicKey": "base64-x25519-public-key",
  "signingPublicKey": "base64-ed25519-public-key",
  "createdAt": "2026-05-14T00:00:00Z"
}
```

### `GET /contacts`

Returns contacts and their current public device keys.

## Messages

### `POST /messages`

Uploads message metadata and an encrypted blob. The first scaffold may use a
multipart request with `metadata` JSON plus `blob` bytes. Later versions can add
chunked upload without changing the content-blind model.

Metadata:

```json
{
  "recipientId": "usr_...",
  "recipientDeviceId": "dev_...",
  "envelopeVersion": 1,
  "envelope": {
    "algorithm": "xchacha20poly1305",
    "encryptedContentKey": "base64-key-wrap",
    "nonce": "base64-nonce",
    "thumbnailEnvelope": null
  },
  "blobSize": 123456,
  "durationMs": 42000
}
```

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
