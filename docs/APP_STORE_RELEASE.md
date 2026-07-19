# Kithra App Store Release Plan

This file tracks the fastest low-cost path from the local vertical slice to
TestFlight and then App Store review. Do not put secrets, private keys, tunnel
tokens, Apple API keys, or server passwords in this file.

## Release Target

- Public app name: Kithra.
- Bundle ID: `com.joaquimpacer.speakeasy`.
- First milestone: internal TestFlight.
- Second milestone: external TestFlight for Ohana and other invited testers.
- Public App Store review comes after TestFlight proves the beta relay,
  onboarding, invite flow, send/receive, account deletion, and review metadata.
- France is excluded from distribution. Revisit export documentation before
  enabling France because Kithra bundles industry-standard libsodium encryption.

## Hosting Decision

The relay is a long-running Go service with SQLite and encrypted blob storage.
It should run on a small VPS or a machine reached through a tunnel, not on a
serverless function host.

Recommended cheapest serious beta path:

1. Use the existing DigitalOcean VPS if it has enough spare CPU, RAM, disk, and
   bandwidth.
2. Put Kithra behind a separate hostname, for example
   `https://api.kithra.app` or `https://api.<existing-domain>`.
3. Use Docker Compose for the relay.
4. Use Cloudflare Tunnel if you want HTTPS without opening public inbound app
   ports on the VPS.

Vercel is useful for the privacy policy/support website, but not for the relay:

- Vercel Functions are not a good fit for durable SQLite and encrypted blob
  files.
- The relay will need long-lived notification connections later.
- Moving to Vercel would mean rewriting storage around external database/blob
  products, which adds more moving parts than it saves for this beta.

## Hostname

The app should talk to an HTTPS hostname, not a LAN IP. Options:

- Buy a domain and use `api.<domain>`.
- Use a subdomain of a domain already pointed at the existing website.
- Use a provider hostname for a short private test only, then move to your own
  domain before broader review.

The release iOS build currently has a configurable default relay URL:

- Debug default: `http://localhost:8080`
- Release default placeholder: `https://api.kithra.app`

Update the Release value in `ios/Kithra.xcodeproj` before archiving if the
chosen beta hostname is different.

## What "Release Server Config" Means

Release server config means the app has different defaults depending on where it
is running:

- Simulator/dev builds can default to the local relay.
- Physical local tests can still manually enter a LAN relay in Settings.
- TestFlight/App Store builds should default to the HTTPS beta relay.

This keeps App Review and testers from needing to type a local IP address.

## TestFlight Notes

Internal TestFlight does not require 100 testers. Apple allows up to 100
internal testers who are App Store Connect users.

External TestFlight does not require 10,000 testers. Apple allows up to 10,000
external testers. For a private beta, one external tester is fine.

For Ohana:

- If he should only test the app, invite him as an external TestFlight tester.
- If he needs App Store Connect access, invite him as an internal tester with an
  appropriate App Store Connect role.

## Immediate Checklist

Owner tasks:

- Choose the beta API hostname.
- Decide whether to use the existing DigitalOcean VPS or a new tiny Droplet.
- Point the hostname through DNS or Cloudflare Tunnel.
- After every first TestFlight upload for a version, open TestFlight build
  activity and confirm that it does not show `Missing Compliance` before
  inviting testers. Kithra declares `ITSAppUsesNonExemptEncryption = false`
  because it uses published industry-standard algorithms and excludes France.
- Revisit export compliance before adding France, adding proprietary
  cryptography, or changing the current crypto design. If Apple later requires
  and approves documentation, replace the exemption with the Apple-provided
  `ITSEncryptionExportComplianceCode` value.
- Keep all VPS, Cloudflare, DNS, and Apple secrets out of chat.

Codex tasks:

- Keep the Docker relay deployable with Compose.
- Add release default relay URL support in the app.
- Add account deletion.
- Draft privacy policy, support page, TestFlight notes, and App Review notes.
- Verify server tests, simulator build, physical build, and `/healthz` before
  uploading to TestFlight.

## One-Command Internal TestFlight Upload

Fastlane is configured under `ios/fastlane/`. From the repository root, ship a
new internal-only TestFlight build with:

```sh
cd ios && bundle exec fastlane beta
```

The lane reads the ignored App Store Connect Key ID from
`secrets/app-store-connect/key-id.txt`, its private key from
`secrets/app-store-connect/AuthKey_<KEY_ID>.p8`, and its Issuer ID from
`secrets/app-store-connect/issuer-id.txt`. The values can instead be supplied
with `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_API_KEY_PATH`, and
`APP_STORE_CONNECT_ISSUER_ID`.

The lane finds the latest TestFlight build for the current marketing version,
increments the build number, uses API-key-backed Xcode automatic signing,
archives the Release configuration, uploads it, and waits for App Store Connect
processing. It attaches the processed build to the `Kithra Internal` tester
group. The exported build is marked `testFlightInternalTestingOnly`, and
Fastlane is explicitly configured not to distribute externally or submit a beta
review. Public App Store submission remains a separate manual owner action.
