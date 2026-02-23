# Architecture

```
┌─────────────┐         ┌─────────────────┐         ┌─────────────┐
│   Device A  │         │     Server      │         │   Device B  │
│             │         │  (dumb relay)   │         │             │
│  Record     │         │                 │         │             │
│  Encrypt ─────────────▶ Store blob     │         │             │
│  Upload     │  HTTPS  │  Notify ────────────────▶ Download     │
│             │         │                 │  WS/Push│  Decrypt    │
│             │         │                 │         │  Play       │
└─────────────┘         └─────────────────┘         └─────────────┘

Keys never leave the device.
Server only sees encrypted blobs.
```

## Components

```
speakeasy/
├── server/          # Node.js relay server
│   ├── src/
│   │   ├── routes/  # REST API handlers
│   │   ├── ws/      # WebSocket notifications
│   │   ├── storage/ # Blob storage (local/S3)
│   │   ├── db/      # SQLite via better-sqlite3
│   │   └── push/    # Push notification service
│   ├── Dockerfile
│   └── package.json
├── app/             # React Native mobile app
│   ├── src/
│   │   ├── crypto/  # libsodium encryption
│   │   ├── api/     # Server communication
│   │   ├── screens/ # UI screens
│   │   └── store/   # Local state
│   └── package.json
├── docker-compose.yml
└── docs/
    ├── SPEC.md
    └── ARCHITECTURE.md
```
