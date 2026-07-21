# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Speakeasy is an end-to-end encrypted async video messaging app. Self-hosted, open source, zero-knowledge server design. The server is a "dumb relay" that never sees plaintext content.

**Current phase:** Specification and documentation complete; implementation has not started. All design decisions, API contracts, and security architecture are documented in `docs/`.

## Planned Tech Stack

- **Server:** Go — single-binary relay, REST API + WebSocket, ~20MB Docker image
- **iOS client:** Swift — native camera, crypto, Keychain access (SwiftUI)
- **Cryptography:** libsodium — X25519 key exchange, XChaCha20-Poly1305 AEAD, BLAKE2b hashing
- **Storage:** Local filesystem + optional S3-compatible
- **Deployment:** Docker + docker-compose (one-command self-host)

## Architecture

The server is intentionally untrusted. All encryption/decryption happens on-device.

**Flow:** Device A encrypts video → uploads ciphertext blob to server → server stores & relays → Device B downloads & decrypts

**Planned server structure:**
```
server/
  cmd/           # entry point
  internal/
    api/         # REST handlers
    ws/          # WebSocket notifications
    storage/     # blob storage (local FS / S3)
    db/          # SQLite or Postgres
    push/        # APNs push notifications
```

## Key Design Constraints

- **Per-message ephemeral keys** for forward secrecy — every message uses a fresh X25519 keypair
- **libsodium only** for all cryptographic operations — no custom crypto, no other libraries
- **No analytics, tracking, or telemetry** — privacy is a core requirement
- **Native clients only** — no React Native or cross-platform frameworks (performance and crypto access)
- **MVP (V1) scope:** 1:1 messaging, iOS only, self-hosted Docker deployment

## API Contracts

Defined in `docs/SPEC.md`. Key endpoint groups:
- `POST /auth/register` — account creation with public key
- `POST /auth/login` — challenge-response (no passwords)
- `POST /messages` / `GET /messages/:id` — upload/download encrypted blobs
- `POST /contacts/invite` / `POST /contacts/accept` — contact exchange with key sharing
- `ws://server/ws` — real-time delivery notifications

## Documentation Map

- `docs/SPEC.md` — full technical specification (API, data model, video pipeline, key exchange flow)
- `docs/ARCHITECTURE.md` — system diagram and component layout
- `docs/SECURITY.md` — cryptographic primitives, threat model, key management

## Development Workflow

- Feature branches with pull request merges to `main`
- Single code owner: `@joshuaohana`
