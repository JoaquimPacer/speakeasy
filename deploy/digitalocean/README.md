# DigitalOcean Relay

Target relay hostname: `https://api.jqinnovation.com`
Target app/support hostname: `https://kithra.jqinnovation.com`

Current status:

- Droplet: `joaquimpacer-wp`
- Public IPv4: `137.184.80.178`
- Relay path: `/srv/speakeasy/current`
- Persistent data path: `/srv/speakeasy/data`
- Previous beta health check: `https://api.joaquimpacer.com/healthz`; last
  verified healthy on 2026-08-04. The deployed process predates the integrated
  release branch and must not be treated as the release candidate.
- Target API: repository configuration uses `api.jqinnovation.com`; its DNS,
  TLS, active VPS virtual hosts, exact relay deployment, and public health check
  remain pending separate deployment approval and verification.
- Public site: deployment pending. DNS, TLS, site deployment, and public
  reachability for `kithra.jqinnovation.com` must be verified before App Store
  submission.
- TLS: valid for the previous beta API hostname on 2026-08-04. Target API and
  support-site TLS remain pending until DNS and the virtual hosts are configured
  and verified.

This deployment keeps the Go relay bound to localhost on the VPS and puts the
existing web server in front of it for HTTPS. It is designed to coexist with
the other Apache virtual hosts on the same Ubuntu Droplet.

`TRUST_PROXY_HEADERS=true` is safe here only because Compose publishes port
8080 on host loopback and Apache replaces, rather than appends to, both
`X-Real-IP` and `X-Forwarded-Proto`. Do not expose port 8080 on a public host
interface while that setting is enabled.

## DNS

Create or verify these `A` records with each domain's authoritative DNS
provider only after the corresponding HTTP virtual host is installed and
passes `apache2ctl configtest`:

- Hostname: `api.jqinnovation.com`
- Type: `A`
- Value: `137.184.80.178`
- Cloudflare proxy status: **DNS only**
- TTL: Auto

- Hostname: `kithra.jqinnovation.com`
- Type: `A`
- Value: the existing DigitalOcean Droplet public IPv4 address
- TTL: default or 300 seconds

After DNS propagates:

```bash
dig +short api.jqinnovation.com
dig +short kithra.jqinnovation.com
```

Keep the previous beta hostname and virtual host available during the
transition. DNS-only is required for the API under the current trusted-proxy
design: enabling Cloudflare proxying would hide the direct client address from
Apache and would also put Cloudflare request-size and connection-time limits in
the encrypted video-upload path. Orange-cloud proxying requires a separately
reviewed client-IP trust and origin-access design.

This explicit API record bypasses Vercel; existing apex and `www` records can
continue routing the main website to Vercel independently.

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

The current Droplet uses Apache. Copy `apache-api.jqinnovation.com.conf` to:

```text
/etc/apache2/sites-available/api.jqinnovation.com.conf
```

Enable it:

```bash
sudo a2enmod proxy proxy_http proxy_wstunnel headers rewrite ssl
sudo a2ensite api.jqinnovation.com.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

The API virtual host must contain these directives in both its HTTP (`*:80`)
and active HTTPS/Certbot (`*:443`, commonly `*-le-ssl.conf`) definitions:

```apache
RequestHeader set X-Real-IP "expr=%{REMOTE_ADDR}"
RequestHeader set X-Forwarded-Proto "expr=%{REQUEST_SCHEME}"
```

`set` intentionally overwrites spoofable values supplied by the client. Check
the generated Certbot virtual host after every certificate reconfiguration,
then run `sudo apache2ctl configtest` before reloading Apache. Repository
configuration does not prove that the active VPS configuration has been
updated; verify it during the separately approved deployment.

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
sudo certbot --apache -d api.jqinnovation.com
sudo certbot --apache -d kithra.jqinnovation.com
```

After Certbot changes the API site, confirm its active `*:443` virtual host
still overwrites `X-Real-IP` and derives `X-Forwarded-Proto` from
`REQUEST_SCHEME`. Do not enable `TRUST_PROXY_HEADERS` on the relay until both
the HTTP and HTTPS virtual hosts satisfy that invariant.

Then verify:

```bash
curl -fsS https://api.jqinnovation.com/healthz
curl -fsS https://kithra.jqinnovation.com/
curl -fsS https://kithra.jqinnovation.com/support.html
curl -fsS https://kithra.jqinnovation.com/privacy.html
curl -fsS https://kithra.jqinnovation.com/community-guidelines.html
```

## iOS Release Config

The Release build default relay is set to:

```text
https://api.jqinnovation.com
```

Debug remains local by default.

Do not sign or upload a release build with this default until DNS, TLS, the
active HTTP and HTTPS virtual hosts, `/healthz`, client-IP handling, and a
representative encrypted upload have all been verified. Existing beta devices
that move from the previous hostname must reset local registration, register
again, and mutually reverify contact safety numbers.
