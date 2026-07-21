# Kithra Privacy Policy Draft

Last updated: 2026-05-27

Kithra is an encrypted async video messaging app. It is designed so the relay
server cannot read the contents of your videos.

## Data We Process

Kithra may process:

- Account identifiers, such as your username and server-generated user ID.
- Device identifiers, such as server-generated device IDs and public encryption
  and signing keys.
- Contact relationship metadata created through invite codes.
- Message metadata, such as sender, recipient, timestamps, delivery status,
  encrypted blob size, and retention/expiration time.
- Encrypted video blobs while they are waiting to be downloaded by the
  recipient.
- IP addresses and basic server logs needed to operate and secure the relay.

## Video Content

Kithra encrypts video messages on your device before upload. The relay stores
encrypted blobs only and does not receive plaintext video.

Recipients decrypt videos on their own devices. The app keeps local encrypted
history on-device and creates short-lived plaintext playback files only when a
video is being watched.

## What We Do Not Do

Kithra does not sell personal data.

Kithra does not use advertising SDKs.

Kithra does not use third-party analytics or tracking SDKs.

Kithra does not scan or moderate plaintext video content because the relay
cannot decrypt it.

## Retention

Undelivered encrypted blobs are retained by the relay for a limited period and
then expire. The current default retention window is 7 days.

When a recipient verifies and caches an encrypted message locally, the app
acknowledges delivery and the relay deletes its encrypted blob copy.

Message metadata may remain on the relay so the app can show conversation
history, delivery status, and contact state.

## Account Deletion

You can request account deletion in the app from Settings. Account deletion
removes the relay account, device/session records, contacts, message metadata,
and pending encrypted relay blobs associated with the account. The app also
clears local encrypted media and device keys from that device.

This does not remove copies of messages already downloaded and stored on another
recipient's device.

## Contact

Support: `<support-url>`

Email: `<support-email>`
