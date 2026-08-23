# Test Kithra With a Friend

Use these steps after the friend receives a TestFlight invitation. The two
iPhones can be in different locations.

## Before You Start

- A friend who only tests Kithra should be an **external TestFlight tester**.
- An **internal tester** is an App Store Connect user with an account role. A
  friend does not need that access just to test the app.
- External testing may not begin until Apple approves the build for external
  TestFlight testing.
- Arrange a trusted phone, FaceTime, or video call outside Kithra so both people
  can compare their safety numbers over an independent channel.

## Install And Register

1. Install **TestFlight** from the App Store.
2. Open the TestFlight invitation, tap **Accept**, then install **Kithra**.
3. Open Kithra. Leave **Relay URL** unchanged.
4. Under **Account**, enter a unique username and tap **Register**.
5. Tell the other person your Kithra username.

## Connect The Two iPhones

On the iPhone creating the invitation:

1. In Kithra, tap **Settings**.
2. Under **Contacts**, tap **Create invite**.
3. Tap **Copy** or the Share button and send the complete `SPEAK-...` code to
   the other person.

On the other iPhone:

1. In Kithra, tap **Settings**.
2. Under **Contacts**, paste the complete code into the
   `SPEAK-ABCD-1234-EF56` field.
3. Tap **Accept invite**. Kithra returns to **Videos** after it succeeds.

The invite code only creates the contact; it does not verify either person's
keys. After acceptance, Kithra independently calculates the same 60-digit
safety number on both iPhones from both current device identities. Each person
sees the list by opening the other person's **Contact Security** screen; nobody
sends a separate reference list.

## Verify Each Other Remotely

Both people must complete these steps on their own iPhone:

1. Start the trusted call outside Kithra.
2. In Kithra, tap **Videos**, then tap the other person's username.
3. Tap the orange **Verify contact** badge or the orange
   **Verify before recording** notice.
4. On **Contact Security**, confirm that both iPhones show a safety number with
   12 groups: 60 digits total.
5. Have one person read all 12 groups while the other checks them, then read
   them back. Do not send the number or a screenshot through Kithra itself.
6. If every digit matches on both iPhones, tap
   **We compared all 60 digits**, then **Mark as Verified**.
7. Confirm that Kithra shows the green **Verified** badge or
   **Verified on this device**.

Both people must mark the contact verified because verification is saved only
on the iPhone that confirms it. Stop without verifying if even one digit
differs. Refresh both contacts and confirm both phones use the same relay; if
the number still differs, treat it as an identity change. QR scanning is
optional; comparing all 60 digits is usually easier when the iPhones are in
different locations.

## When To Verify Again

Compare the complete number again after either person reinstalls Kithra, resets
local registration, uses a new device or account, changes device keys, or moves
to a different relay. Deleting or blocking and later re-adding a contact also
clears the local verification, even if unchanged identities produce the same
digits again.

## Exchange Test Videos

1. Keep Kithra open in the foreground on the receiving iPhone. This version
   does not yet send push notifications.
2. On the sending iPhone, open the verified conversation.
3. Tap the large white record button once; do not hold it. Allow camera and
   microphone access if asked.
4. Record for 3-5 seconds, then tap the button again to stop. Kithra sends the
   video automatically.
5. On the receiving iPhone, wait for the new thumbnail, then tap it and confirm
   that the video plays.
6. Repeat in the opposite direction.
7. Report whether both videos played and whether their statuses changed to
   **Delivered** and **Watched**.

## If Something Is Missing

- **Contact Security** is inside a conversation, not in Settings.
- A name shown in **Videos** is a contact username, not another app.
- If the contact is missing, open **Settings** and tap **Refresh**.
- If **Create invite** is missing, scroll to the top of Settings. It is the
  first action under **Contacts**.
