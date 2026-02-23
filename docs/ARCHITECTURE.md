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
├── server/          # Go relay server
│   ├── cmd/         # Entry point
│   ├── internal/
│   │   ├── api/     # REST API handlers
│   │   ├── ws/      # WebSocket notifications
│   │   ├── storage/ # Blob storage (local/S3)
│   │   ├── db/      # SQLite
│   │   └── push/    # Push notification service
│   ├── Dockerfile
│   └── go.mod
├── ios/             # Swift iOS app
│   ├── Speakeasy/
│   │   ├── Crypto/  # libsodium encryption
│   │   ├── API/     # Server communication
│   │   ├── Views/   # SwiftUI screens
│   │   └── Store/   # Local state
│   └── Speakeasy.xcodeproj
├── docker-compose.yml
└── docs/
    ├── SPEC.md
    └── ARCHITECTURE.md
```
