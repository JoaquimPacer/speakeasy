# Speakeasy Deployment

Speakeasy is designed to be self-hosted. The relay is untrusted by design, but
deployment still matters: TLS, stable storage, clean secret handling, and basic
host hardening protect availability and metadata.

The current server scaffold lives in `server/` and is wired into
`docker-compose.yml`. It is suitable for local development only until
challenge-response auth, real crypto bindings, and upload limits are hardened.

## Deployment Principles

- Store only encrypted blobs and routing metadata on the relay.
- Keep local environment files and all private credentials out of git.
- Bind development services locally unless they intentionally need public
  access.
- Use HTTPS and WSS for any iOS build that talks to a non-local relay.
- Treat APNs, S3, Cloudflare, SSH, and App Store Connect material as secrets.
- Prefer boring Docker Compose deployment before adding orchestration.

## Local Docker Development

Local Docker is the default development path for the Go relay.

Expected target flow:

```bash
docker compose up --build
curl http://localhost:8080/healthz
```

Expected local environment values:

```dotenv
SPEAKEASY_ADDR=:8080
STORAGE_PATH=/data/blobs
DB_PATH=/data/speakeasy.db
UNDELIVERED_RETENTION_DAYS=7
```

`STORAGE_PATH` and `DB_PATH` mirror the names in `docs/SPEC.md`. The scaffold
also accepts `SPEAKEASY_DB_PATH`, `SPEAKEASY_STORAGE_PATH`, and
`SPEAKEASY_UNDELIVERED_RETENTION_DAYS`.

Expected Compose shape:

```yaml
services:
  speakeasy:
    build:
      context: ./server
    ports:
      - "8080:8080"
    environment:
      SPEAKEASY_ADDR: ":8080"
      DB_PATH: /data/speakeasy.db
      STORAGE_PATH: /data/blobs
      UNDELIVERED_RETENTION_DAYS: "7"
    volumes:
      - speakeasy-data:/data

volumes:
  speakeasy-data:
```

Local notes:

- The current Compose shape uses a named `speakeasy-data` volume.
- If you switch to a bind mount such as `./data:/data`, `./data` is ignored and
  can be deleted to reset local relay state.
- For named volumes, use `docker compose down -v` only when you intentionally
  want to delete local relay state.
- `.env.local` is ignored and should hold only local development values.
- APNs should stay disabled until push work starts.
- Local tests should use temporary directories, not checked-in fixtures with
  private data.

## Linux Laptop Private Beta

Use this for early TestFlight/private beta when the relay needs a stable HTTPS
URL but a VPS is not justified yet.

Host checklist:

- Dedicated Linux user for Speakeasy.
- Docker and Docker Compose installed.
- Persistent storage path chosen, for example `/srv/speakeasy/data`.
- Automatic sleep disabled.
- Full-disk encryption enabled if practical.
- OS security updates enabled.
- SSH access limited to trusted keys.
- Firewall denies inbound application traffic unless explicitly needed.
- Backups cover the SQLite database and encrypted blob directory.

Recommended layout:

```text
/srv/speakeasy/
  compose.yml
  .env.local
  data/
    blobs/
    speakeasy.db
```

Example environment values:

```dotenv
STORAGE_PATH=/data/blobs
DB_PATH=/data/speakeasy.db
UNDELIVERED_RETENTION_DAYS=7
```

Run the relay with Compose:

```bash
cd /srv/speakeasy
docker compose up -d
docker compose logs -f speakeasy
```

### Cloudflare Tunnel

Cloudflare Tunnel is a good private beta default because it can publish the
local relay over HTTPS without opening inbound ports on the laptop. Cloudflare's
current docs describe public hostname routing to a local service such as
`http://localhost:8080`.

Local-managed tunnel outline:

```bash
cloudflared tunnel login
cloudflared tunnel create speakeasy-beta
cloudflared tunnel route dns speakeasy-beta api.example.com
```

Keep the generated credentials under the service user's home directory, not in
the repository. A local-managed `cloudflared` config should look like:

```yaml
tunnel: speakeasy-beta
credentials-file: /home/speakeasy/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: api.example.com
    service: http://localhost:8080
  - service: http_status:404
```

Operational notes:

- The iOS app should use `https://api.example.com` and `wss://api.example.com`.
- Do not expose plaintext health or debug endpoints with sensitive metadata.
- Keep Cloudflare credentials, tunnel tokens, and origin certificates out of git.
- If the tunnel credential file is exposed, rotate the tunnel.
- If uptime becomes important, move to a VPS instead of relying on a laptop.

Cloudflare references:

- [Cloudflare Tunnel overview](https://developers.cloudflare.com/tunnel/)
- [Cloudflare Tunnel routing](https://developers.cloudflare.com/tunnel/routing/)
- [Locally-managed tunnel setup](https://developers.cloudflare.com/tunnel/advanced/local-management/create-local-tunnel/)

## Later DigitalOcean Deployment

Move to DigitalOcean when laptop uptime, bandwidth, App Review, or beta
reliability require it.

Initial target:

- Small Ubuntu Droplet.
- Docker Compose deployment.
- Persistent volume or explicit backup path for `/srv/speakeasy/data`.
- DigitalOcean Cloud Firewall.
- SSH restricted to trusted IPs where practical.
- Inbound `80/443` only if terminating TLS directly on the Droplet.
- If using Cloudflare Tunnel on the Droplet, keep application ports closed to
  the public internet.

Deployment outline:

```bash
sudo mkdir -p /srv/speakeasy/data
sudo chown -R speakeasy:speakeasy /srv/speakeasy
cd /srv/speakeasy
docker compose pull
docker compose up -d
```

Backups:

- Snapshot the Droplet before upgrades.
- Back up SQLite and encrypted blobs together so metadata and blob files stay in
  sync.
- Test restore into a separate host before depending on backups.
- Do not back up `.env.local` into shared or public storage unless it is
  encrypted with owner-controlled keys.

DigitalOcean references:

- [DigitalOcean Firewalls overview](https://docs.digitalocean.com/products/networking/firewalls/how-to/)
- [Configure DigitalOcean firewall rules](https://docs.digitalocean.com/products/networking/firewalls/how-to/configure-rules/index.html)

## Deployment Readiness Checklist

- `docker compose up --build` works locally.
- `/healthz` returns success without exposing secrets or user metadata.
- Relay storage survives container restart.
- Retention cleanup is configured and tested.
- Upload size limits match the iOS compression target.
- HTTPS and WSS work from a real device on cellular data.
- APNs is disabled until keys are available and push payloads are content-blind.
- Restore from backup has been tested.
- No `.env.local`, tunnel credentials, SSH keys, certificates, or provisioning
  profiles are in git.
