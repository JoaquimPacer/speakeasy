# Kithra Privacy Policy Draft

Last updated: 2026-08-09

Kithra is an encrypted async video messaging app. It is designed so the relay
server cannot read the contents of your videos.

## Data We Process

Kithra may process:

- Account identifiers, such as your username and server-generated user ID.
- Device identifiers, such as server-generated device IDs and public encryption
  and signing keys.
- Authentication/session tokens used to authorize relay requests.
- Contact relationship metadata created through invite codes.
- Message metadata, such as sender, recipient, timestamps, delivery status,
  encrypted blob size, and retention/expiration time.
- Encrypted video blobs while they are waiting to be downloaded by the
  recipient.
- IP addresses and basic server logs needed to operate and secure the relay.
- Block and report metadata, including a report reason and app-generated report
  details. Kithra V1 does not upload decrypted video as part of a report.

## Video Content

Kithra encrypts video messages on your device before upload. The relay receives
and stores each video payload only as an encrypted blob; it does not receive
plaintext video.

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

The relay records an expiration time for undelivered encrypted blobs, with a
current default of 7 days. The public-release candidate runs cleanup when the
relay starts and then periodically, deleting expired encrypted blobs and their
message metadata. This behavior must still be verified on the exact deployed
relay before publication.

When a recipient verifies and caches an encrypted message locally, the app
acknowledges delivery and asks the relay to delete its encrypted blob copy.
If blob deletion fails, the relay preserves the database pointer and returns an
error so deletion can be retried instead of silently reporting success.

Message metadata may remain on the relay so the app can show conversation
history, delivery status, and contact state.

## Account Deletion

You can request account deletion in the app from Settings. Account deletion
removes the relay account, device/session records, contacts, message metadata,
and pending encrypted relay blobs associated with the account. The app then
clears its protected relay session, local encrypted media, verification pins,
replay receipts, and device keys from that device. The public-release candidate
records incomplete local cleanup and retries it after a restart instead of
silently reporting success. This behavior must still receive owner approval and
pass real-device deletion and restart-recovery verification before publication.

This does not remove copies of messages already downloaded and stored on another
recipient's device.

## Contact

Proposed support page (not yet live):
`https://kithra.jqinnovation.com/support.html`

Email: `support@jqinnovation.com`

Security reports: `security@jqinnovation.com`
