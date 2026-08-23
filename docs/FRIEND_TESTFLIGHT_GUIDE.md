# Test Kithra With a Friend

Use these steps after the friend receives a TestFlight invitation. The two
iPhones can be in different locations.

## Before You Start

- A friend who only tests Kithra should be an **external TestFlight tester**.
- An **internal tester** is an App Store Connect user with an account role. A
  friend does not need that access just to test the app.
- External testing may not begin until Apple approves the build for external
  TestFlight testing.
- Arrange a trusted phone, FaceTime, or video call so both people can compare
  their safety numbers.

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

## Verify Each Other Remotely

Both people must complete these steps on their own iPhone:

1. Start the trusted call.
2. In Kithra, tap **Videos**, then tap the other person's username.
3. Tap the orange **Verify contact** badge or the orange
   **Verify before recording** notice.
4. On **Contact Security**, read and compare all 12 groups: 60 digits total.
5. If every digit matches on both iPhones, tap
   **We compared all 60 digits**, then **Mark as Verified**.
6. Confirm that Kithra says **Contact verified**.

Both people must mark the contact verified. Stop without verifying if even one
digit differs. QR scanning is optional; comparing all 60 digits is usually
easier when the iPhones are in different locations.

## Exchange Test Videos

1. Keep Kithra open in the foreground on the receiving iPhone. This version
   does not yet send push notifications.
2. On the sending iPhone, open the verified conversation.
3. Tap the large white record button and allow camera and microphone access if
   asked.
4. Record for 3-5 seconds, then tap the stop button. Kithra sends the video
   automatically.
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
