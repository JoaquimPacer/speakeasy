# Security Architecture

## Overview

Speakeasy uses end-to-end encryption for all video messages. The server acts as a dumb relay — it stores and delivers encrypted blobs but has zero ability to decrypt them.

## Cryptographic Primitives

All cryptography is provided by [libsodium](https://doc.libsodium.org/), a widely-audited, misuse-resistant cryptographic library.

| Purpose | Algorithm | libsodium Function |
|---------|-----------|-------------------|
| Key exchange / key wrapping | X25519 | libsodium box/key-exchange APIs |
| Device authentication | Ed25519 signatures | `crypto_sign_*` |
| Content encryption | XChaCha20-Poly1305 | libsodium secretstream or AEAD APIs |
| Asymmetric key wrapping | X25519 + AEAD | `crypto_box_seal` or equivalent envelope |
| Key derivation | BLAKE2b | `crypto_generichash` |
| Random bytes | OS CSPRNG | `randombytes_buf` |

## Key Management

### Identity Keys
Each device generates long-term encryption and signing keypairs on first launch:
- **Encryption private key** — stored in iOS Keychain / Android Keystore with the strongest available local protection. Never leaves the device.
- **Signing private key** — stored in iOS Keychain / Android Keystore and used only to sign login challenges. Never leaves the device.
- **Public keys** — registered with the server. These are the device identity material the relay can use for routing and challenge verification.

### Message Encryption Flow

```
Sender                          Server                         Recipient
  │                               │                               │
  │  1. Generate fresh content    │                               │
  │     key (K)                   │                               │
  │                               │                               │
  │  2. Encrypt video with K      │                               │
  │     (XChaCha20-Poly1305)      │                               │
  │                               │                               │
  │  3. Encrypt K with            │                               │
  │     recipient encryption key  │                               │
  │     (crypto_box_seal)         │                               │
  │                               │                               │
  │  4. Upload encrypted video    │                               │
  │     + encrypted K             │                               │
  │ ─────────────────────────────▶│                               │
  │                               │  5. Store encrypted blob      │
  │                               │     + notify recipient        │
  │                               │ ─────────────────────────────▶│
  │                               │                               │
  │                               │                               │  6. Download encrypted
  │                               │                               │     blob + encrypted K
  │                               │                               │
  │                               │                               │  7. Decrypt K with
  │                               │                               │     private key
  │                               │                               │
  │                               │                               │  8. Decrypt video with K
```

### Forward Secrecy
V1 uses a fresh content key for each message, which limits the blast radius if a
single content key is exposed. V1 does not claim full Signal-style forward
secrecy: if an attacker later steals a recipient device private key and also has
old encrypted blobs/envelopes, old messages may be at risk. True forward secrecy
with prekeys/ratcheting is a V2 goal.

## Server Trust Model

The server is **untrusted by design**:
- It stores only ciphertext
- It does not possess any private keys
- It cannot decrypt any content
- A full database dump yields only encrypted blobs and public keys
- Server operators cannot access message content even if compelled

## Threat Model

### Protected Against
| Threat | Protection |
|--------|-----------|
| Network eavesdropping | TLS (transport) + E2E encryption (content) |
| Server compromise | Encrypted blobs are useless without device keys |
| Curious server operators | Zero-knowledge design — nothing to see |
| Mass surveillance | No central service — each instance is independent |
| MITM (key exchange) | V2 key verification via safety numbers / QR codes |

### Not Protected Against (v1)
| Threat | Limitation |
|--------|-----------|
| Metadata analysis | Server sees who messages whom and when |
| Device compromise | Physical access to unlocked device = access to keys |
| Recipient screenshots | No DRM, no screenshot prevention |
| Targeted device exploits | Out of scope for application-level crypto |
| Full forward secrecy | V2; V1 uses per-message content keys without ratcheting |

## Security Reporting

If you discover a security vulnerability, please **do not** open a public GitHub issue.

Contact: security@ohanaindustries.com

We will acknowledge receipt within 48 hours and aim to provide a fix within 7 days for critical issues.
