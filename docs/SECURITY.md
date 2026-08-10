# Security Architecture

## Overview

Speakeasy uses end-to-end encryption for all video messages. The server acts as a dumb relay — it stores and delivers encrypted blobs but has zero ability to decrypt them.

## Cryptographic Primitives

All client-side content and identity cryptography uses
[libsodium](https://doc.libsodium.org/), a widely audited, misuse-resistant
library. The content-blind Go relay performs no message-content encryption or
decryption. The current public-release candidate proposes using Go's standard
`crypto/ed25519`, `crypto/rand`, and `crypto/sha256` implementations only for
login-proof verification, relay-generated high-entropy identifiers/tokens and
challenges, and hashing those high-entropy bearer tokens at rest. The Ed25519
verification is wire-compatible with signatures produced by libsodium, and the
three relay-only uses preserve the static CGO-free build. This narrow
C-CRYPTO-01 exception to the repository's literal libsodium-only rule still
requires Joaquim's approval before release.

| Purpose | Algorithm | Implementation |
|---------|-----------|----------------|
| Key exchange / key wrapping | X25519 | libsodium box/key-exchange APIs |
| Device signing | Ed25519 signatures | libsodium `crypto_sign_*` |
| Relay login-proof verification | Ed25519 verification | Go `crypto/ed25519` (pending C-CRYPTO-01) |
| Content encryption | XChaCha20-Poly1305 | libsodium AEAD APIs |
| Asymmetric key wrapping | X25519 + AEAD | libsodium `crypto_box_seal` |
| Key derivation / hashing | BLAKE2b | libsodium `crypto_generichash` |
| Client random bytes | OS CSPRNG | libsodium `randombytes_buf` |
| Relay challenges, identifiers, and bearer tokens | OS CSPRNG | Go `crypto/rand` (pending C-CRYPTO-01) |
| Bearer-token hashing at rest | SHA-256 | Go `crypto/sha256` (pending C-CRYPTO-01) |

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
  authenticated device. Reset and account deletion attempt remote revocation,
  then surface any incomplete local Keychain/media cleanup instead of silently
  reporting success.
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
