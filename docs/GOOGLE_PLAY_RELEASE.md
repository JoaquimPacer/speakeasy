# Kithra Google Play Release Plan

This file tracks the Android/Google Play lane. Do not put keystore passwords,
Play Console credentials, service account JSON, upload keys, or private API
keys in this repository.

## Android Target

- Public app name: Kithra.
- Android package name: `com.joaquimpacer.kithra`.
- First milestone: native Android shell that builds locally.
- Second milestone: Android vertical slice matching the iOS TestFlight flow.
- Third milestone: Google Play internal test release.

## Platform Strategy

Kithra should be native on both platforms:

- iOS: Swift/SwiftUI, AVFoundation, Keychain, Swift-Sodium.
- Android: Kotlin, CameraX, Android Keystore, libsodium binding, native media
  APIs.

The two clients should share product behavior, not source code. Keep parity by
sharing:

- The same relay API contract.
- The same crypto envelope format.
- The same invite/contact/message semantics.
- A shared cross-platform test checklist.

## Google Play Setup Needed From Owner

- Google Play Console developer account.
- App record for Kithra.
- App category, contact email, privacy policy URL, and support URL.
- Decision on countries/regions for testing and production.
- Upload signing setup in Play App Signing.

Secrets must stay out of chat and out of git:

- Upload keystore (`.jks` or `.keystore`).
- Keystore passwords and key alias passwords.
- Play service account JSON if CI upload is automated later.

## Testing Tracks

Use Google Play Internal testing first for a tiny trusted tester set. Production
release is a later milestone after Android reaches feature parity and required
policy/tester gates are satisfied.

For newer personal Play Console developer accounts, Google may require a closed
test with enough opted-in testers over a minimum duration before production
access. Track the exact requirement in Owner Setup once the account status is
known.

## Immediate Android Checklist

- [x] Install JDK and Android command-line tools on the Mac.
- [x] Install Android SDK platform tools, API 36, and build tools.
- [x] Add native Android project scaffold under `android/`.
- [x] Verify local debug build.
- [x] Verify local release `.aab` bundle build.
- [x] Add Android CI.
- [ ] Implement register/login device identity.
- [ ] Implement invite create/accept.
- [ ] Implement camera-first recording.
- [ ] Implement libsodium encryption/decryption parity.
- [ ] Implement upload/download/playback parity.
- [ ] Generate a release upload key in ignored owner-local secret storage.
- [ ] Build signed `.aab` for Play internal testing.

## Local Build Commands

```bash
cd android
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH"
./gradlew :app:assembleDebug
./gradlew :app:bundleRelease
```

Current local artifacts:

- Debug APK: `android/app/build/outputs/apk/debug/app-debug.apk`
- Release bundle: `android/app/build/outputs/bundle/release/app-release.aab`
