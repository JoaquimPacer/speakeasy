# DigitalOcean Beta Relay

Relay hostname: `https://api.joaquimpacer.com`
Target app/support hostname: `https://kithra.jqinnovation.com`

Current beta status:

- Droplet: `joaquimpacer-wp`
- Public IPv4: `137.184.80.178`
- Relay path: `/srv/speakeasy/current`
- Persistent data path: `/srv/speakeasy/data`
- Public health check: `https://api.joaquimpacer.com/healthz`; last verified
  healthy on 2026-08-04. The deployed process predates the integrated release
  branch and must not be treated as the release candidate.
- Public site: deployment pending. DNS, TLS, site deployment, and public
  reachability for `kithra.jqinnovation.com` must be verified before App Store
  submission.
- TLS: valid for the API hostname on 2026-08-04. Support-site TLS remains
  pending until DNS and the virtual host are configured and verified.

This deployment keeps the Go relay bound to localhost on the VPS and puts the
existing web server in front of it for HTTPS. It is designed to coexist with
the other Apache virtual hosts on the same Ubuntu Droplet.

## DNS

Create or verify these `A` records with each domain's authoritative DNS
provider:

- Hostname: `api.joaquimpacer.com`
- Type: `A`
- Value: the existing DigitalOcean Droplet public IPv4 address
- TTL: default or 300 seconds

- Hostname: `kithra.jqinnovation.com`
- Type: `A`
- Value: the existing DigitalOcean Droplet public IPv4 address
- TTL: default or 300 seconds

After DNS propagates:

```bash
dig +short api.joaquimpacer.com
dig +short kithra.jqinnovation.com
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

## Static Kithra Site

The app/support/privacy site is static HTML and can be served by Apache on the
same Droplet as the relay and the existing website.

Copy the site files to:

```text
/var/www/kithra
```

Copy `apache-kithra.jqinnovation.com.conf` to:

```text
/etc/apache2/sites-available/kithra.jqinnovation.com.conf
```

Enable it:

```bash
sudo mkdir -p /var/www/kithra
sudo rsync -a deploy/digitalocean/kithra-site/ /var/www/kithra/
sudo chown -R www-data:www-data /var/www/kithra
sudo a2ensite kithra.jqinnovation.com.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

## HTTPS

Use Certbot with the Apache plugin after DNS resolves:

```bash
sudo certbot --apache -d api.joaquimpacer.com
sudo certbot --apache -d kithra.jqinnovation.com
```

Then verify:

```bash
curl -fsS https://api.joaquimpacer.com/healthz
curl -fsS https://kithra.jqinnovation.com/
curl -fsS https://kithra.jqinnovation.com/support.html
curl -fsS https://kithra.jqinnovation.com/privacy.html
curl -fsS https://kithra.jqinnovation.com/community-guidelines.html
```

## iOS Release Config

The Release build default relay is set to:

```text
https://api.joaquimpacer.com
```

Debug remains local by default.
