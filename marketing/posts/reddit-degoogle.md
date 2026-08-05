# Draft: r/degoogle

> Unpublished draft. Kithra is pre-submission; do not post this until the public
> App Store URL exists and every status statement and subreddit rule is checked.

Angle: de-Google your video chats. This crowd wants concrete open-source alternatives to Big Tech, and a big slice of them run GrapheneOS or LineageOS on Android. Be honest and early that V1 is iPhone-only, because they will (fairly) point out they cannot use it yet. Do not hide the limitation, own it.

Subreddit: https://www.reddit.com/r/degoogle/
Rule status: I could not fetch the live rules for this sub, so read the sidebar yourself before posting. (Notes in the playbook.)

Before posting: paste the real links over `[OPEN-SOURCE REPO LINK]` and `[APP STORE LINK - pending]`.

---

**Title:**

De-Googling your video messages: I built an open-source, self-hostable Marco Polo alternative. No Google, no phone number, no telemetry.

---

**Body:**

I built this, so that is my bias declared.

Getting off Google and the rest usually leaves one awkward gap: the casual video-message habit. Families that would never touch a "de-Google" guide are deep into Marco Polo, which has a WARNING privacy rating from Common Sense (no encryption, the company can watch your clips, your data gets profiled). I wanted to hand my own family a swap that did not route their faces through anyone's ad machine.

So I made Kithra. What lines up with this sub:

- No Google anything. No Firebase-as-surveillance, no analytics, no telemetry, no tracking. The server collects nothing to sell.
- No phone number. Accounts use a username, and contacts connect through invite codes, so there is no phone-number identity anchor.
- End-to-end encrypted. Your iPhone encrypts each video to a verified contact key before upload, and the relay only ever holds ciphertext it cannot decrypt. The app uses libsodium-backed primitives rather than custom cryptographic algorithms.
- Self-hostable. One `docker-compose up` and the relay is yours, on your box, your rules. Open source under MIT at `[OPEN-SOURCE REPO LINK]`.

The honest bit, because you would ask: the relay sees metadata (who, when, blob size), never content. Same as your carrier knows about calls. Everything that is actually revealing stays encrypted.

Now the part this sub will care about most, said straight: V1 is iPhone-only. The app is currently pre-submission, with no public App Store link (`[APP STORE LINK - pending]`). The Kotlin directory is only a scaffold for a later Android client, so GrapheneOS and LineageOS users cannot install Kithra today. The source is public and the Go relay can be self-hosted, but self-hosting the relay does not install the iPhone app. When Android becomes a real release target, I would want it to land properly for this crowd, F-Droid included, and I would take your input on doing that right.

Curious what would make this genuinely useful for de-Googled setups, and how loud the "Android first, not iOS" objection is here. Tell me straight, I will answer.
