# Kithra Support Page Draft

Publication status: Draft. DNS, TLS, deployment, and public reachability for
`kithra.jqinnovation.com` have not yet been verified.

Kithra is a private async video messaging app.

## Getting Started

1. Open Kithra.
2. Register a username.
3. Create an invite code or accept one from a contact.
4. Tap a contact to open the camera-first conversation.
5. Tap record, tap stop, and Kithra sends the encrypted video automatically.

## Privacy

Videos are encrypted on your device before upload. The relay cannot view the
plaintext content of your videos.

## Account Deletion

Open Settings, then choose Delete account. A successful request removes your
relay account, device and session records, contacts, message metadata, and
associated relay ciphertext, and then clears the relay session, local encrypted
media, verification records, replay receipts, and device keys from that device.
If relay or local cleanup cannot finish, Kithra preserves recovery state and
asks you to retry instead of reporting the deletion complete. This does not
remove message copies already downloaded to a contact's device.

## Current Capabilities

- Kithra V1 supports 1:1 video messaging on iPhone. iPad support is planned for
  a later release.
- Push notifications are not enabled yet, so the app refreshes while open.
- The relay service must be online for sending and receiving.

## Contact

Email: `support@jqinnovation.com`

Security reports: `security@jqinnovation.com`

Proposed privacy policy URL (not yet live):
`https://kithra.jqinnovation.com/privacy.html`
