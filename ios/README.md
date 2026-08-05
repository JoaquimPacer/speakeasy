# Speakeasy iOS Scaffold

This directory contains the native SwiftUI source for the Speakeasy/Kithra
iPhone MVP. V1 targets iPhone only; iPad support is deferred.

## Target Shape

`Kithra.xcodeproj` contains the native app target. The public target and scheme
are named `Kithra`; the existing source folder and Swift type names can remain
`Speakeasy` for now. The current source assumes:

- SwiftUI app lifecycle.
- iPhone device family for V1.
- iOS 16 or newer for `NavigationStack`.
- UIKit system camera picker for the first record path.
- AVFoundation for transcoding and playback preparation.
- Security.framework for Keychain storage.
- Swift-Sodium 0.9.1 for X25519, Ed25519 challenge signing,
  XChaCha20-Poly1305, BLAKE2b, random byte generation, and sealed-box
  content-key wrapping.

The public App Store name is `Kithra`. The finalized bundle identifier is
`com.joaquimpacer.speakeasy`.

## Local Build

Unsigned local verification does not need Apple signing secrets:

```bash
xcodebuild build \
  -project ios/Kithra.xcodeproj \
  -scheme Kithra \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KithraDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

To run in a specific simulator from Xcode, open `ios/Kithra.xcodeproj`, choose
the shared `Kithra` scheme, and select an installed iOS Simulator runtime.

## Current Limits

The app can register a fresh local device against `http://localhost:8080`,
create and accept invite codes, refresh contacts/messages, capture or pick a
video, compress it, encrypt it locally, upload the ciphertext to the relay,
download received ciphertext, verify the encrypted package hash when present,
save a received encrypted local copy, acknowledge relay deletion, and decrypt a
short-lived playback file. Outgoing envelopes include a sender-sealed content
key so sent local history can also be played without exposing plaintext to the
relay.

Still pending: expiring challenge-response re-authentication, persistent local
message/cache indexing, APNs push, and a signed public-eligible candidate plus
its two-iPhone smoke test. Earlier internal signing/upload checks do not satisfy
that release-candidate gate.
