# DigitalOcean Beta Relay

Target hostname: `https://api.joaquimpacer.com`

Current beta status:

- Droplet: `joaquimpacer-wp`
- Public IPv4: `137.184.80.178`
- Relay path: `/srv/speakeasy/current`
- Persistent data path: `/srv/speakeasy/data`
- Public health check: `https://api.joaquimpacer.com/healthz`
- TLS: Let's Encrypt through Certbot/Apache, auto-renewal scheduled by Certbot.

This deployment keeps the Go relay bound to localhost on the VPS and puts the
existing web server in front of it for HTTPS. It is designed to coexist with the existing
`joaquimpacer.com` website on the same Ubuntu Droplet.

## DNS

Create an `A` record in Network Solutions:

- Host/name: `api`
- Type: `A`
- Value: the existing DigitalOcean Droplet public IPv4 address
- TTL: default or 300 seconds

After DNS propagates:

```bash
dig +short api.joaquimpacer.com
```

## VPS Layout

```text
/srv/speakeasy/
  data/
  current/
    deploy/digitalocean/compose.yml
    server/
```

`data/` contains SQLite and encrypted relay blobs. Back it up with care.

## Install Docker

```bash
./install-docker-ubuntu.sh
```

## Deploy Relay

From `/srv/speakeasy/current` on the VPS:

```bash
docker compose -f deploy/digitalocean/compose.yml up --build -d
docker compose -f deploy/digitalocean/compose.yml ps
curl -fsS http://127.0.0.1:8080/healthz
```

## Apache

The current Droplet uses Apache. Copy `apache-api.joaquimpacer.com.conf` to:

```text
/etc/apache2/sites-available/api.joaquimpacer.com.conf
```

Enable it:

```bash
sudo a2enmod proxy proxy_http proxy_wstunnel headers rewrite ssl
sudo a2ensite api.joaquimpacer.com.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

## HTTPS

Use Certbot with the Apache plugin after DNS resolves:

```bash
sudo certbot --apache -d api.joaquimpacer.com
```

Then verify:

```bash
curl -fsS https://api.joaquimpacer.com/healthz
```

## iOS Release Config

The Release build default relay is set to:

```text
https://api.joaquimpacer.com
```

Debug remains local by default.
