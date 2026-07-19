# Draft: r/degoogle

Angle: de-Google your video chats. This crowd wants concrete open-source alternatives to Big Tech, and a big slice of them run GrapheneOS or LineageOS on Android. Be honest and early that it is iOS first, because they will (fairly) point out they cannot use it yet. Do not hide the limitation, own it.

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
- No phone number. You sign up with a username or an invite code, so there is no identity anchor to harvest.
- End-to-end encrypted. Your phone seals the video with the recipient's key before upload, and the relay only ever holds a blob it cannot open. Standard libsodium crypto, not homemade.
- Self-hostable. One `docker-compose up` and the relay is yours, on your box, your rules. Open source under MIT at `[OPEN-SOURCE REPO LINK]`.

The honest bit, because you would ask: the relay sees metadata (who, when, blob size), never content. Same as your carrier knows about calls. Everything that is actually revealing stays encrypted.

Now the part this sub will care about most, said straight: it is iOS first. The Swift app is in App Store review right now (`[APP STORE LINK - pending]`). The Kotlin Android client is on the roadmap but not built yet, so if you are on GrapheneOS or Lineage you cannot install it today, and I am not going to pretend otherwise. What you can do today is read the code and run the relay. When Android lands I would want it to land properly for this crowd, F-Droid included, and I would take your input on doing that right.

Curious what would make this genuinely useful for de-Googled setups, and how loud the "Android first, not iOS" objection is here. Tell me straight, I will answer.
