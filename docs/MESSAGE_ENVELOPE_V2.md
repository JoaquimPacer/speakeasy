# Authenticated Message Envelope v2

## Goal

Message Envelope v2 adds sender authentication and binds every existing
envelope field to the two identities verified by
`docs/IDENTITY_VERIFICATION.md`. The relay carries the JSON and ciphertext but
does not sign, cryptographically verify, decrypt, or rewrite the authenticated
envelope. It does enforce the bounded version-2 transport schema before storing
an upload so every accepted envelope is decodable by the official client.

The signature proves that the holder of the pinned sender device's Ed25519
private key authorized the exact transcript for the pinned recipient device. It
does not authenticate relay-created status, paths, timestamps, or message IDs,
and it does not provide forward secrecy.

## Transport model

The Swift model for a version-2 envelope adds these fields to the version-1
shape:

```text
version: 2
clientMessageID: UUID
senderIdentityDigest: 32 bytes
recipientIdentityDigest: 32 bytes
authenticationAlgorithm: "Ed25519"
signature: 64 bytes
```

It retains `senderDeviceID`, `recipientDeviceID`, `media`, recipient
`contentKey`, optional `senderContentKey`, and `createdAt`. Binary JSON values
remain standard padded base64. UUIDs use their normal hyphenated string form.
`createdAt` uses exact UTC ISO 8601 whole-second form
`YYYY-MM-DDTHH:MM:SSZ` on the wire. A v2 sender must first set `createdAt` to
`floor(unixSeconds)` and sign that exact whole-second `Date`. Fractional seconds
and numeric offsets are rejected. A future protocol revision or explicitly
lossless date codec is required before signing fractional seconds.

The raw envelope is limited to 48 KiB and its containing upload metadata JSON to
64 KiB. A present protocol string must be nonempty, valid UTF-8, and contain no
Unicode control characters. `media.mimeType` is limited to 255 UTF-8 bytes,
`recipientPublicKeyFingerprint` to 256 UTF-8 bytes, and a thumbnail encrypted
blob path to 2,048 UTF-8 bytes. Unknown version-2 envelope fields are rejected.

The authenticated API upload context supplies `senderUserID` from the bearer
session and `recipientUserID` from the upload metadata. These values are inputs
to the transcript even though they are not duplicated inside the envelope JSON.
On download, the client must use the message's authenticated sender/recipient
metadata and reject any mismatch with the envelope's device IDs or local
conversation.

## Primitive encoding

- `raw(s)` is an exact byte sequence without a prefix.
- `u16be(n)`, `u32be(n)`, and `u64be(n)` are unsigned, fixed-width big-endian
  integers.
- `lp(b)` is `u32be(len(b)) || b`, with byte length.
- `uuid(u)` is the 16 RFC 4122/network-order bytes obtained by removing hyphens
  from the canonical UUID text and decoding hexadecimal. It is not a platform
  UUID struct's memory layout.
- Strings are exact, case-sensitive UTF-8 without a byte-order mark. Transcript
  strings are not Unicode-normalized.
- A data/string optional is `0x00` when absent or `0x01 || lp(value)` when
  present.
- A structured optional is `0x00` when absent or `0x01 || fields` when present.
- No other optional marker value is valid.

Every length and semantic fixed size must be validated before allocating or
verifying. Version-2 identity digests and ciphertext hashes are 32 bytes,
XChaCha20-Poly1305 nonces are 24 bytes, Ed25519 signatures are 64 bytes, and
the literal algorithm strings below are case-sensitive.

The media and any thumbnail algorithm must be exactly
`XChaCha20-Poly1305`. `contentKey` and an optional `senderContentKey` must use
exactly `crypto_box_seal`; sealing a 32-byte content key produces exactly 80
bytes. When a thumbnail structure is present, its encrypted blob path and
32-byte ciphertext hash are required even though the shared Swift transport
model represents those fields as optional for decoding older data.

## Numeric normalization

`durationSeconds`, when present, must be finite and nonnegative. Convert it to
milliseconds as:

```text
durationMilliseconds = floor(durationSeconds * 1000 + 0.5)
```

Reject overflow above `u64`. Encode the result as `u64be`. This definition
avoids language-specific tie-breaking rules.

For a new v2 envelope, first compute `floor(currentUnixSeconds)` and construct
the wire `createdAt` from that integral value. Convert that value to signed Unix
epoch milliseconds (therefore always divisible by 1,000) and encode the signed
64-bit integer as its two's-complement bit pattern in `u64be`. Dates outside
signed 64-bit millisecond range are invalid. Verifiers encode the parsed wire
date by rounding to its nearest millisecond, but a conforming current sender
never relies on fractional precision.

## Content-key sub-transcript

Encode a `ContentKeyEnvelope` as:

```text
lp(algorithm UTF-8)
|| lp(encryptedContentKey raw bytes)
|| optional(recipientPublicKeyFingerprint UTF-8)
```

`recipientPublicKeyFingerprint` is retained only to encode the optional legacy
model field unambiguously. New version-2 senders should omit it because
`recipientIdentityDigest` binds the full recipient identity and keys. When
present, it must satisfy the nonempty 256-byte protocol-string bound above.

## Canonical signing transcript

Build the transcript in this exact order:

```text
raw("KITHRA-MESSAGE-AUTH-v2\0")
|| u16be(version)
|| uuid(clientMessageID)
|| uuid(senderUserID)
|| uuid(senderDeviceID)
|| senderIdentityDigest[32]
|| uuid(recipientUserID)
|| uuid(recipientDeviceID)
|| recipientIdentityDigest[32]
|| lp(authenticationAlgorithm UTF-8)
|| lp(media.algorithm UTF-8)
|| lp(media.nonce raw bytes)
|| optional(media.ciphertextHash raw bytes)
|| lp(media.mimeType UTF-8)
|| optional-duration marker:
     0x00, or 0x01 || u64be(durationMilliseconds)
|| optional-thumbnail marker:
     0x00, or
     0x01
     || lp(thumbnail.algorithm UTF-8)
     || lp(thumbnail.nonce raw bytes)
     || optional(thumbnail.encryptedBlobPath UTF-8)
     || optional(thumbnail.ciphertextHash raw bytes)
|| recipient content-key sub-transcript
|| optional-sender-content-key marker:
     0x00, or 0x01 || sender content-key sub-transcript
|| createdAt signed epoch milliseconds as a u64be two's-complement bit pattern
```

For v2, `version` must be 2, `authenticationAlgorithm` must be exactly
`Ed25519`, and `media.ciphertextHash` must be present and exactly 32 bytes even
though the current Swift property is optional. The optional marker remains in
the transcript so absent and present values can never share an encoding.

The signature field itself is the only envelope field excluded from the
transcript, because including it would be circular:

```text
signature = Ed25519-detached-sign(transcript, senderSigningPrivateKey)
```

Sign the raw transcript directly with libsodium `crypto_sign_detached`; do not
prehash it, sign its hexadecimal representation, or use Ed25519ph. Verification
uses `crypto_sign_verify_detached` and the exact pinned sender signing public
key.

## Sender requirements

Before encrypting or signing, the sender must:

1. Require a `verified` trust record and confirm current local/contact identity
   material exactly matches it.
2. Generate a fresh random `clientMessageID` UUID. It is independent of the
   relay-created message ID.
3. Use the pinned recipient X25519 public key to seal the content key.
4. Compute the 32-byte BLAKE2b ciphertext hash over the exact uploaded encrypted
   blob bytes.
5. Populate both identity digests from the verified pin, canonicalize the
   transcript, and sign it with the local Ed25519 key.
6. Persist the encrypted sender-history copy under the signed, locally generated
   `clientMessageID` before upload. Do not make a relay-created message ID or a
   post-upload filesystem operation a prerequisite for recovering that copy.
7. Recheck the exact verified identities after persistence, then upload version
   2. A later relay refresh may bind an authenticated outgoing record to the
   sender copy only by its signed `clientMessageID`.

Retries of one logical upload retain the same envelope, signature, ciphertext,
and `clientMessageID`. A new recording/send creates a new ID.

Local plaintext thumbnails are keyed by direction-specific authoritative ID
(outgoing `clientMessageID` or incoming relay message ID) plus the complete
authenticated envelope signature. Fetched relay metadata must authenticate
before it can select a local thumbnail, and thumbnail creation never replaces
an existing authenticated-identifier path.

## Recipient requirements

Before decrypting or acknowledging delivery, the recipient must:

1. Require a `verified` pin for the sender and an exact match for its own local
   identity.
2. Require envelope version 2 and all fixed lengths and algorithm literals.
3. Confirm API sender/recipient user IDs and device IDs match the transcript
   inputs and the verified pair.
4. Confirm both envelope identity digests match the pinned digests.
5. Reconstruct the transcript and verify the detached signature with the pinned
   sender Ed25519 key.
6. Recompute BLAKE2b-256 over the downloaded encrypted blob and compare it in
   constant time with the signed `media.ciphertextHash`.
7. Reserve a `pending` replay receipt keyed by relay scope, local device,
   `senderIdentityDigest`, and `clientMessageID`, and bind it to the exact relay
   message ID and 64-byte envelope signature. Reject a committed tuple or a
   pending tuple with different bindings as a replay.
8. Atomically promote the staged ciphertext without replacing any existing
   local history, then mark the exact pending receipt `committed`.
9. Only then unwrap the content key, perform XChaCha20-Poly1305 authenticated
   decryption, generate plaintext presentation artifacts, and acknowledge
   delivery.

If the process stops after reservation but before promotion, the same signed
message and server ID may resume that pending receipt. If it stops after file
promotion but before the receipt state update, exact local validation promotes
the pending receipt before playback. This recovery is not available to a
committed duplicate or any changed server ID/signature. A failed attempt keeps
its pending receipt so that only that exact authenticated message can resume;
its uniquely named staging file is discarded when control returns to the app.

Any failure is fail-closed: do not play, show as authenticated, acknowledge,
or silently fall back to relay-provided keys.

## Migration from unsigned envelope v1

Envelope v1 has authenticated encryption of media bytes but no sender signature
over the envelope and no out-of-band identity binding. It must never be labeled
or handled as an authenticated message.

- Once v2 ships, clients upload version 2 only. There is no per-contact
  relay-advertised downgrade switch because the relay is not trusted to
  negotiate authentication.
- This first public client uses a strict cutoff: version 1 packages, including
  old local incoming packages, are not played or labeled authenticated. The
  existing pre-release beta did not promise durable history, so the safer
  migration intentionally breaks that beta history instead of adding an
  unsigned fallback.
- Version 1 received from the network is rejected and never
  delivery-acknowledged.
- Never convert a v1 envelope to v2 at the relay or client; only the original
  sender device can create the v2 signature.
- Deploy the v2-capable client before, or atomically with, the relay rule that
  rejects v1 uploads. Deploying the strict relay first will break older
  TestFlight senders. Public-release clients and relays require v2 for every
  upload and download.

Fixed signatures and canonical transcript bytes for absent and present optional
fields are in `testdata/protocol/kithra-identity-v1-message-v2.json`.
