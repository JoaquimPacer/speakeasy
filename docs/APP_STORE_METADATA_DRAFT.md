# Kithra App Store Metadata Draft

This is a working record for App Store Connect. The dated snapshot below records
values that were saved or independently confirmed after owner direction. Joaquim
must still reconfirm the age-rating UGC answer and every submission or release
decision. Preparing this file does not authorize an App Review submission or
release.

## Live App Store Connect Snapshot (through 2026-08-23)

- Version `1.0` remains in `PREPARE_FOR_SUBMISSION` with manual release.
- Public distribution and the free price are saved.
- Availability covers 174 storefronts; France is explicitly **Not Available**
  under the no-France encryption scope Joaquim completed on 2026-08-23.
- Mac and Apple Vision Pro compatibility are disabled.
- Kithra `1.0 (5)` is the processed iPhone-only candidate. App Store Connect
  reports `VALID`, `usesNonExemptEncryption=false`, and no TestFlight-group
  attachment. Build 5 is selected for version `1.0`.
- Three `1284x2778` iPhone screenshots are uploaded.
- Copyright, primary and secondary categories, content rights, the 13+ age
  rating, messaging disclosure, DSA non-trader status, and the English (U.S.)
  product copy, keywords, support URL, and privacy-policy URL are saved.
- `Sign-In Required: No`, the App Review contact, and the review notes are saved
  and were independently read back through the App Store Connect API.
- The App Privacy page was visually verified as published with no tracking. The
  live age-rating `userGeneratedContent=false` answer still requires Joaquim's
  reconfirmation. Joaquim retains approval of all legal, privacy, submission,
  and release decisions.

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
Three clean `1284x2778` iPhone screenshots were visually validated and uploaded
in the numbered order below on 2026-08-23.

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

The live age-rating declaration currently records `THIRTEEN_PLUS`,
`messagingAndChat=true`, and `userGeneratedContent=false`. Kithra has no public
feed, user discovery, unrestricted browser, gambling, purchases, ads, or
location feature. Because Kithra carries private user-created video, Joaquim
must reconfirm that Apple's `userGeneratedContent=false` answer accurately
describes private one-to-one messaging before submission.

Joaquim must still decide and document:

- Whether Kithra is child-directed and whether the saved 13+ result remains
  appropriate after the UGC answer is reconfirmed.
- Any remaining live questionnaire objectionable-content answers.
- The proposed rules and response commitments in
  `docs/COMMUNITY_GUIDELINES.md`, including the operator workflow for
  metadata-only reports at `support@jqinnovation.com`.
- Whether the current block/report controls are sufficient for V1 when the
  relay cannot inspect plaintext video.

## App Review Notes Draft

Kithra has no transferable password-based demo account. Each installation
creates device-bound keys, and reviewers can self-register a unique username.
The complete workflow requires two iPhones:

`Sign-In Required: No`, the App Review contact, and the notes were saved on
2026-08-23 and independently read back through the App Store Connect API.

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
- [x] Copyright text saved.
- [x] Support URL and privacy-policy URL saved and publicly reachable over HTTPS.
- [x] App Review contact, notes, and `Sign-In Required: No` saved and read back.
- [x] DSA non-trader status saved.
- [x] App Privacy answers published with no tracking; deployed proxy behavior
  was reconciled before publication.
- [ ] Reconfirm the saved 13+ age rating's `userGeneratedContent=false` answer,
  child-directed status, UGC rules, and report-response process.
- [x] Content-rights attestation saved as use of third-party content.
- [x] Retain Apple's standard EULA; no custom EULA is configured for V1.
- [x] English (U.S.) localization saved; additional localizations are deferred.
- [x] Public distribution and free price saved.
- [x] Availability saved for 174 storefronts; France is explicitly **Not
  Available** under the completed no-France compliance scope.
- [x] Version `1.0` configured for manual release.
- [x] Mac and Apple Vision Pro compatibility disabled for V1.
- [x] No push notifications accepted for public V1 and disclosed in review notes.
- [x] Three `1284x2778` screenshots uploaded.
- [x] English (U.S.) copy, primary/secondary categories, and keywords saved.
- [x] Build 5 selected for version `1.0`.
- [x] Final screenshot content and numbered order validated.
