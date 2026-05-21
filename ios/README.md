# Speakeasy iOS Scaffold

This directory contains the initial native SwiftUI source scaffold for the
Speakeasy iOS MVP.

## Target Shape

Create an iOS app target in Xcode named `Kithra`, then add the files under
`Speakeasy/` to that target. The existing source folder and Swift type names can
remain `Speakeasy` for now. The current source assumes:

- SwiftUI app lifecycle.
- iOS 16 or newer for `NavigationStack`.
- AVFoundation for recording, transcoding, and playback preparation.
- Security.framework for Keychain storage.
- A future libsodium binding for X25519, Ed25519 challenge signing,
  XChaCha20-Poly1305, BLAKE2b, and random byte generation.

The public App Store name is `Kithra`. The finalized bundle identifier is
`com.joaquimpacer.speakeasy`.

## Current Limits

The scaffold does not fake cryptography. Code paths that require libsodium throw
clear errors until a binding is installed and wired into `Crypto/` and `Media/`.
The media recorder is also a stub; the transcode and temp cleanup surfaces are
present so the app can grow into the documented raw-temp -> compressed ->
encrypted-package lifecycle.
