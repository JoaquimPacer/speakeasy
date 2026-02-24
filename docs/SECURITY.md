# Security Architecture

## Overview

Speakeasy uses end-to-end encryption for all video messages. The server acts as a dumb relay — it stores and delivers encrypted blobs but has zero ability to decrypt them.

## Cryptographic Primitives

All cryptography is provided by [libsodium](https://doc.libsodium.org/), a widely-audited, misuse-resistant cryptographic library.

| Purpose | Algorithm | libsodium Function |
|---------|-----------|-------------------|
| Key exchange | X25519 | `crypto_kx_*` |
| Symmetric encryption | XSalsa20-Poly1305 | `crypto_secretbox_*` |
| Asymmetric encryption | X25519 + XSalsa20-Poly1305 | `crypto_box_seal` |
| Key derivation | BLAKE2b | `crypto_generichash` |
| Random bytes | OS CSPRNG | `randombytes_buf` |

## Key Management

### Identity Keys
Each device generates a long-term X25519 keypair on first launch:
- **Private key** — stored in device secure enclave (iOS Keychain / Android Keystore). Never leaves the device.
- **Public key** — registered with the server. This is your "identity."

### Message Encryption Flow

```
Sender                          Server                         Recipient
  │                               │                               │
  │  1. Generate ephemeral        │                               │
  │     symmetric key (K)         │                               │
  │                               │                               │
  │  2. Encrypt video with K      │                               │
  │     (XChaCha20-Poly1305)      │                               │
  │                               │                               │
  │  3. Encrypt K with            │                               │
  │     recipient's public key    │                               │
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
Each message uses a fresh ephemeral symmetric key. Compromising one key reveals only that single message. Past and future messages remain secure.

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
| MITM (key exchange) | Key verification via safety numbers / QR codes |

### Not Protected Against (v1)
| Threat | Limitation |
|--------|-----------|
| Metadata analysis | Server sees who messages whom and when |
| Device compromise | Physical access to unlocked device = access to keys |
| Recipient screenshots | No DRM, no screenshot prevention |
| Targeted device exploits | Out of scope for application-level crypto |

## Security Reporting

If you discover a security vulnerability, please **do not** open a public GitHub issue.

Contact: security@ohanaindustries.com

We will acknowledge receipt within 48 hours and aim to provide a fix within 7 days for critical issues.
