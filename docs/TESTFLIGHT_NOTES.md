# Kithra TestFlight Notes

## Beta App Description

Kithra is a private async video messaging app. Record a short video, send it to
a contact, and watch prior messages in a camera-first conversation view.

Kithra encrypts videos on-device before upload. The relay stores encrypted blobs
and routing metadata only.

## What To Test

- Register a new username.
- Create an invite code on one device and accept it on another.
- Tap a contact to open the camera-first conversation.
- Record a video, stop, and confirm it auto-sends.
- Confirm the recipient sees the message without manually refreshing while the
  app is open.
- Tap an older thumbnail and confirm playback auto-advances to newer clips.
- Delete the account from Settings when finished testing.

## Pre-Invite Checklist

- Confirm the uploaded build finished processing.
- Open TestFlight build activity and clear `Missing Compliance` if present.
- Confirm an internal or external tester group has the processed build attached.
- Send tester invites only after the build is visible in the selected group.

## App Review Notes Draft

Kithra is an encrypted async video messaging app. The app requires camera and
microphone access so users can record videos. The relay stores encrypted blobs
and metadata only; it cannot decrypt video content.

To test:

1. Launch the app and register a username.
2. Use two devices or a device plus simulator.
3. On device A, create an invite code from Settings.
4. On device B, accept the invite code.
5. Tap the contact, record a video, stop recording, and wait for auto-send.
6. On the recipient device, open the contact and play the received video.

Beta relay URL: `<https-relay-url>`

Support URL: `<support-url>`

Privacy Policy URL: `<privacy-policy-url>`
