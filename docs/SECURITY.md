# Security Architecture

## Overview

Speakeasy uses end-to-end encryption for all video messages. The server acts as a dumb relay — it stores and delivers encrypted blobs but has zero ability to decrypt them.

## Cryptographic Primitives

All client-side content and identity cryptography uses
[libsodium](https://doc.libsodium.org/), a widely audited, misuse-resistant
library. The content-blind Go relay performs no message-content encryption or
decryption. C-CRYPTO-01 authorizes using Go's standard
`crypto/ed25519`, `crypto/rand`, and `crypto/sha256` implementations only for
login-proof verification, relay-generated high-entropy identifiers/tokens and
challenges, and hashing those high-entropy bearer tokens at rest. The Ed25519
verification is wire-compatible with signatures produced by libsodium, and the
three relay-only uses preserve the static CGO-free build. Joaquim approved this
narrow relay-authentication and session-recovery exception on 2026-08-22. It
does not authorize relay message-content cryptography or any broader departure
from libsodium-backed client cryptography.

| Purpose | Algorithm | Implementation |
|---------|-----------|----------------|
| Key exchange / key wrapping | X25519 | libsodium box/key-exchange APIs |
| Device signing | Ed25519 signatures | libsodium `crypto_sign_*` |
| Relay login-proof verification | Ed25519 verification | Go `crypto/ed25519` (C-CRYPTO-01) |
| Content encryption | XChaCha20-Poly1305 | libsodium AEAD APIs |
| Asymmetric key wrapping | X25519 + AEAD | libsodium `crypto_box_seal` |
| Key derivation / hashing | BLAKE2b | libsodium `crypto_generichash` |
| Client random bytes | OS CSPRNG | libsodium `randombytes_buf` |
| Relay challenges, identifiers, and bearer tokens | OS CSPRNG | Go `crypto/rand` (C-CRYPTO-01) |
| Bearer-token hashing at rest | SHA-256 | Go `crypto/sha256` (C-CRYPTO-01) |

## Key Management

### Identity Keys
Each device generates long-term encryption and signing keypairs on first launch:
- **Encryption private key** — stored in iOS Keychain / Android Keystore with the strongest available local protection. Never leaves the device.
- **Signing private key** — stored in iOS Keychain / Android Keystore and used
  to sign login challenges, contact-verification QR payloads, and authenticated
  message transcripts. Never leaves the device.
- **Public keys** — registered with the server. These are the device identity material the relay can use for routing and challenge verification.

### Relay Sessions

- Registration and successful challenge login return an opaque bearer session
  with a 30-day default lifetime.
- The relay stores only a lowercase SHA-256 digest of each bearer token. An
  in-place migration hashes legacy raw tokens transactionally and gives legacy
  sessions without an expiry one 7-day grace period.
- The iPhone stores the bearer authority in a
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` Keychain item, bound to the
  relay URL. It is never persisted in `UserDefaults`.
- Renewal signs the exact domain-separated, single-use relay challenge with the
  existing device signing key. A renewal response is accepted only if the user,
  device ID, encryption key, and signing key still match the protected local
  identity.
- Logout revokes every session and outstanding login challenge for the
  authenticated device. Account deletion first writes and reads back a
  device-bound deletion intent in the Keychain. While that intent is pending,
  the client hides authenticated UI, invalidates and removes plaintext media,
  and retains the exact bearer, signing identity, and encrypted local media
  needed to reconcile an interrupted request.
- Before that protected intent is persisted, the client closes a process-wide
  plaintext-production barrier shared by capture and media processing. New
  output reservations fail closed, while every already-started producer keeps
  its exact destination registered through its definitive completion or
  cancellation callback. Both the pre-request and final local sweeps fail and
  preserve the deletion intent while any producer or owned plaintext path
  remains; the barrier reopens only after the final sweep, protected-intent
  removal, and local cleanup marker all complete.
- The client accepts only an empty HTTP 204 response as definitive deletion.
  After an ambiguous 401, it requests a signed-login challenge for the exact
  username/device pair: an existing identity renews its session and retries
  deletion. Only the challenge endpoint's complete identity-miss tuple -- HTTP
  401, `Content-Type: text/plain; charset=utf-8`, and the exact body bytes
  `invalid login identity\n` -- confirms that a prior delete already removed
  the account. Every other 401 remains unresolved and preserves the protected
  deletion intent. The confirmed phase is itself written and read back before
  local authority is erased, so a crash or failed cleanup resumes without
  restoring signed-in state or creating replacement keys.
- Relay account deletion is serialized with ciphertext writes in the current
  single-process V1 server. It deletes every unique committed-message or
  pending-upload blob path where the account is sender or recipient. Any blob
  deletion failure preserves all database ownership and account/session rows
  for the same authenticated retry; only after all idempotent blob deletions
  succeed does one transaction remove pending-write rows and the user.
- Reset and confirmed account deletion surface any incomplete local
  Keychain/media cleanup instead of silently reporting success.
- V1 has no cross-device private-key backup or account recovery. Deleting the
  device identity is intentionally destructive.

### Message Encryption Flow

```
Sender                          Server                         Recipient
  │                               │                               │
  │  1. Generate fresh content    │                               │
  │     key (K)                   │                               │
  │  2. Encrypt video with K      │                               │
  │     (XChaCha20-Poly1305)      │                               │
  │  3. Seal K to the pinned      │                               │
  │     recipient X25519 key      │                               │
  │  4. Sign envelope transcript  │                               │
  │     (Ed25519)                 │                               │
  │  5. Upload ciphertext +       │                               │
  │     signed envelope           │                               │
  │ ─────────────────────────────▶│                               │
  │                               │  6. Store opaque bytes        │
  │                               │     + notify recipient        │
  │                               │ ─────────────────────────────▶│
  │                               │                               │  7. Download
  │                               │                               │  8. Verify pin,
  │                               │                               │     signature, hash,
  │                               │                               │     and replay ID
  │                               │                               │  9. Open K and decrypt
```

Identity Verification v1 authenticates the two long-term device keypairs by a
60-digit safety number or signed, peer-specific QR code. The resulting local
Keychain pin is fail-closed: an unverified or changed identity cannot be used for
new sends or accepted as an authenticated sender. Message Envelope v2 then signs
the complete canonical envelope transcript with the pinned sender Ed25519 key.
See `docs/IDENTITY_VERIFICATION.md` and `docs/MESSAGE_ENVELOPE_V2.md`.

### Forward Secrecy
V1 uses a fresh content key for each message, which limits the blast radius if a
single content key is exposed. V1 does not claim full Signal-style forward
secrecy: if an attacker later steals a recipient device private key and also has
old encrypted blobs/envelopes, old messages may be at risk. True forward secrecy
with prekeys/ratcheting is a V2 goal.

## Server Trust Model

The server is **untrusted by design**:
- It stores encrypted media blobs plus the operational and authentication
  metadata disclosed in the privacy policy, including usernames, public keys,
  bearer-token hashes, contacts, routing/status data, blocks, and reports
- It does not possess any private keys
- It cannot decrypt video content
- A full database and blob-store dump exposes ciphertext and that metadata, but
  not plaintext video or device private keys
- Server operators cannot access plaintext message content, though they can
  access operational metadata and disrupt availability
- Expiring sessions, single-use login challenges, upload/storage quotas, and
  rate limits reduce replay and resource-exhaustion risk but do not make the
  operator or relay a trust authority for contact identities

## Threat Model

### Protected Against
| Threat | Protection |
|--------|-----------|
| Network eavesdropping | TLS (transport) + E2E encryption (content) |
| Server compromise | Does not reveal plaintext video without device keys; does reveal relay metadata and bearer sessions |
| Curious server operators | Cannot decrypt verified content; still see routing metadata and ciphertext |
| Hosted-service compromise | Self-hosted instances are independent, but the default hosted relay remains a central metadata and availability dependency for its users |
| Relay key substitution | V1 out-of-band safety number / signed QR verification plus local key pinning |
| Envelope forgery/tampering | V2 Ed25519 transcript signature after identity verification |

### Not Protected Against (v1)
| Threat | Limitation |
|--------|-----------|
| Metadata analysis | Server sees who messages whom and when |
| Device compromise | Physical access to unlocked device = access to keys |
| Recipient screenshots | No DRM, no screenshot prevention |
| Targeted device exploits | Out of scope for application-level crypto |
| Full forward secrecy | V2; V1 uses per-message content keys without ratcheting |
| Relay metadata/availability attacks | Relay can observe routing, withhold, reorder, and replay unchanged signed envelopes; clients reject duplicate authenticated replay IDs |
| Unverified human identity | A safety number authenticates device keys, not a person's legal identity |

## Security Reporting

If you discover a security vulnerability, please **do not** open a public GitHub issue.

Contact: security@jqinnovation.com

Do not promise a response or remediation time in public copy until Joaquim has
approved and staffed that operating commitment.
