# Kithra TestFlight Notes

## Beta App Description

Kithra is a private iPhone async video messaging app. Record a short video,
send it to a contact, and watch prior messages in a camera-first conversation
view.

Kithra encrypts videos on-device before upload. The relay receives video
payloads only as encrypted blobs and processes the account, authentication, and
routing metadata disclosed in the privacy policy.

## What To Test

- Use two iPhones and register a different username on each.
- Create an invite code on one iPhone and accept it on the other.
- On both iPhones, open the contact's Security screen and either scan each
  other's signed QR code or compare all 60 safety-number digits over a trusted
  channel. Confirm messaging remains disabled until both sides verify.
- Tap a contact to open the camera-first conversation.
- Record a video, stop, and confirm it auto-sends.
- Confirm the recipient sees the message without manually refreshing while the
  app is open.
- Tap an older thumbnail and confirm playback auto-advances to newer clips.
- Delete the account from Settings when finished testing.

## Pre-Invite Checklist

- Confirm the uploaded build finished processing.
- For the current crypto scope, require the processed build to report
  `usesNonExemptEncryption=false`. Apple determined on 2026-08-23 that no
  documentation is required while Kithra uses the declared standard algorithms
  and remains unavailable in France. If the build instead reports `Missing
  Compliance`, stop and inspect that exact build; do not upload another binary.
  After the build is clear, run the following from `ios/` for that exact upload:

  ```sh
  KITHRA_INTERNAL_TESTFLIGHT_CONFIRM=I_CONFIRM_INTERNAL_TESTFLIGHT_ACTION \
    bundle exec fastlane verify_beta \
      version:<version> build_number:<build-number>
  ```
- Confirm an internal or external tester group has the processed build attached.
- Send tester invites only after the build is visible in the selected group.

Kithra 1.0 (build 2) was uploaded on July 19, 2026, processed without
`Missing Compliance`, and attached to the `Kithra Internal` group.

## App Review Notes Draft

Kithra is an encrypted async video messaging app. The app requires camera and
microphone access so users can record videos. The relay stores encrypted blobs
and metadata only; it cannot decrypt video content.

To test:

1. Launch the app on two iPhones.
2. Register a different username on each iPhone.
3. On device A, create an invite code from Settings.
4. On device B, accept the invite code.
5. On each iPhone, open the contact's Security screen. Scan the signed QR code
   shown by the other iPhone, or compare all 60 safety-number digits and confirm
   the match. This out-of-band step is required on both devices before
   messaging.
6. Tap the contact, record a video, stop recording, and wait for auto-send.
7. On the recipient iPhone, open the contact and play the received video.

Release-candidate relay URL: `https://api.jqinnovation.com` (DNS, TLS, relay
deployment, and public health verification pending)

Proposed support URL (not yet live):
`https://kithra.jqinnovation.com/support.html`

Proposed privacy policy URL (not yet live):
`https://kithra.jqinnovation.com/privacy.html`
