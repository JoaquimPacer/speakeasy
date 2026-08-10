# Kithra App Store Metadata Draft

This is a working draft for App Store Connect. The dated snapshot below records
distribution values already saved after owner direction. Joaquim must approve
the remaining legal, privacy, age-rating, review-contact, compliance, and other
unfinished answers before any additional value is entered. Preparing this file
does not authorize an upload, App Review submission, or release.

## Live App Store Connect Snapshot (2026-08-09)

- Version `1.0` is configured for manual release.
- Public distribution and the free price are saved.
- Availability covers 174 storefronts; France is explicitly **Not Available**
  pending encryption clearance.
- Mac and Apple Vision Pro compatibility are disabled.
- Builds 1 through 4 exist, but build 4 reports non-exempt encryption as `No`
  and supports both iPhone and iPad. It is not the iPhone-only,
  questionnaire-triggering V1 candidate. No existing build is the V1 candidate,
  and no build is attached to version `1.0`.
- Screenshots, remaining product metadata, App Privacy answers, age rating,
  content-rights answer, trader status, and App Review contact information are
  incomplete. Joaquim retains approval of all legal, privacy, compliance,
  submission, and release decisions.

## Product Page Copy

- App name: `Kithra`
- Subtitle: `Encrypted video messaging`
- Primary category: `Social Networking`
- Secondary category: `Photo & Video`
- Promotional text:

  > Send one-to-one video messages encrypted on your iPhone. Verify each contact
  > with a safety number or QR code, and choose the default HTTPS relay or your
  > own HTTPS relay.

- Keywords:

  ```text
  async,video chat,end-to-end encryption,self-hosted,relay,safety number,QR,open source,one-to-one
  ```

- Description:

  > Kithra is a camera-first, one-to-one asynchronous video messenger for
  > iPhone. Record a video, send it, and catch up when it fits your schedule.
  >
  > Video content is encrypted on your iPhone before upload. The relay stores
  > ciphertext for delivery and cannot decrypt the video. It still processes
  > account, contact, routing, delivery, and security metadata as explained in
  > Kithra's Privacy Policy.
  >
  > Before messaging, verify a contact by comparing the complete 60-digit
  > safety number or scanning signed QR codes on both phones. If a device
  > identity changes, Kithra pauses sending and playback until you verify
  > again.
  >
  > Features include invite-code contacts, sent/delivered/watched status, block
  > and metadata-only report controls, in-app account deletion, configurable
  > self-hosted HTTPS relays, and open-source client and relay code. Kithra
  > contains no ads, analytics, or tracking SDKs.
  >
  > Kithra v1 is iPhone-only. Push notifications are not yet available, so the
  > app refreshes while open. V1 uses a fresh content key for each video and
  > does not claim full Signal-style forward secrecy.

Before approval, confirm that the public support and privacy pages use the same
claims and that the exact release-candidate build still behaves as described.

## Screenshot Plan

Use only consenting test content and Apple's current required iPhone sizes.

1. Conversation list with a verified test contact and delivery status.
2. Camera-first conversation screen with the encrypted history strip.
3. Mutual safety-number and signed-QR verification.
4. Invite creation and acceptance.
5. Received-video playback with sent/delivered/watched state.
6. Settings showing relay configuration, privacy/support access, and account
   deletion.

## App Privacy Working Answers

These are deliberately conservative working answers for the
developer-operated default relay. They are not legal advice and must be checked
against the deployed proxy/log-retention configuration and Apple's live
questionnaire.

| Apple data type | Linked to identity | Purpose |
| --- | --- | --- |
| User ID (username and relay user ID) | Yes | App Functionality; Security |
| Device ID (relay device ID and public keys) | Yes | App Functionality; Security |
| Photos or Videos and Audio Data (encrypted message payload) | Yes | App Functionality |
| Product Interaction (sent, delivered, watched status and timestamps) | Yes | App Functionality |
| Other User Content (report reason/details) | Yes | App Functionality; Safety |
| Other Data (contact, invite, and block relationship metadata) | Yes | App Functionality; Safety |
| IP Address/basic logs | Owner must verify | Security/Fraud Prevention if retained |
| Email Address/support correspondence | Only if Apple treats voluntary support mail as collected by the app developer | Customer Support |

- Tracking: `No`.
- Data used across other companies' apps or websites: `No`.
- The app does not request a legal name, phone number, email address, location,
  address-book contacts, purchases, health data, or financial data at
  registration.
- Plaintext video, private keys, local encrypted history, contact-verification
  pins, and temporary playback files stay on the device and are not collected
  by the developer-operated relay.
- Because encrypted video/audio is transmitted and temporarily retained, keep
  the conservative disclosure unless Apple's live questionnaire clearly
  directs otherwise.
- The bundled `PrivacyInfo.xcprivacy` required-reason declaration and App Store
  privacy labels are separate requirements.

## Age Rating And User-Generated Content

Do not choose a numeric rating from this offline draft. In Apple's live age
rating questionnaire, disclose private messaging/chat and user-generated video
content. Kithra has no public feed, user discovery, unrestricted browser,
gambling, purchases, ads, or location feature.

Joaquim must decide and document:

- Minimum intended user age and whether Kithra is child-directed.
- The live questionnaire's objectionable-content answers.
- The proposed rules and response commitments in
  `docs/COMMUNITY_GUIDELINES_DRAFT.md`, including the operator workflow for
  metadata-only reports at `support@jqinnovation.com`.
- Whether the current block/report controls are sufficient for V1 when the
  relay cannot inspect plaintext video.

## App Review Notes Draft

Kithra has no transferable password-based demo account. Each installation
creates device-bound keys, and reviewers can self-register a unique username.
The complete workflow requires two iPhones:

1. Register a different username on each device.
2. Create an invite on one device and accept it on the other.
3. On both devices, compare all 60 safety-number digits or scan each other's
   signed QR codes.
4. Record and send a video. Keep the receiving app open because V1 does not yet
   support push notifications.
5. Play the received video and observe sent/delivered/watched state.
6. Use the conversation menu to test block/report and Settings to test account
   deletion.

Before submission, Joaquim must decide whether to rely on Apple's two-device
test capability or provide a reviewer-companion plan. A pre-created username
alone cannot transfer the device-bound private identity to a review device.

## Owner-Supplied Fields

- [ ] Seller/legal entity and rights to the `Kithra` name.
- [ ] Copyright text.
- [ ] Support URL and privacy-policy URL, publicly reachable over HTTPS.
- [ ] App Review contact name, phone number, and email.
- [ ] DSA trader or non-trader status.
- [ ] App Privacy answers and deployed IP/proxy log-retention behavior.
- [ ] Minimum age, child-directed status, UGC rules, and report-response process.
- [ ] Content-rights attestation and standard or custom EULA.
- [ ] English-only versus additional localizations.
- [x] Public distribution and free price saved.
- [x] Availability saved for 174 storefronts; France is explicitly **Not
  Available** pending export-compliance resolution.
- [x] Version `1.0` configured for manual release.
- [x] Mac and Apple Vision Pro compatibility disabled for V1.
- [ ] Acceptance of no push notifications in public V1.
- [ ] Final screenshots, copy, categories, and keywords.
