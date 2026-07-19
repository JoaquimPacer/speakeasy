# Draft: r/privacy

Angle: why I built this, the "stop being watched" framing. r/privacy is strict and allergic to ads, so this reads as a problem and an honest answer, not a pitch. Lead with the Marco Polo privacy rating. Put the metadata honesty high up, because someone will ask in the first ten minutes.

Subreddit: https://www.reddit.com/r/privacy/
Rule status: I could not fetch the live rules for this sub, so read the sidebar yourself before posting and adjust. (Notes in the playbook.)

Before posting: paste the real links over `[OPEN-SOURCE REPO LINK]` and `[APP STORE LINK - pending]`.

---

**Title:**

Marco Polo has a WARNING privacy rating and can watch your family's videos. I got tired of it and built an open-source, end-to-end encrypted alternative.

---

**Body:**

Disclosure first: I made this, so I have a horse in the race. I will keep it factual.

My family sends short video messages back and forth on Marco Polo. Then I read its Common Sense privacy evaluation, which carries a WARNING rating: no end-to-end encryption, the company can access your video content, and your data feeds profiling. These are videos of kids and grandparents sitting on a company's servers in the clear. That bugged me enough to spend a few months fixing it for myself.

The app is Kithra. The idea is boring on purpose. You record a video, your phone encrypts it with the recipient's public key before anything is uploaded, and the server only ever holds a sealed blob. Your friend's phone downloads it and decrypts it with their private key. The relay cannot open it. Neither can I, and it is my server.

The honest limit, stated plainly because a privacy promise means nothing without it: the relay does see metadata. Who sent to whom, when, and the size of the blob. It never sees the content. That is the same thing your carrier knows about your calls, and I would rather tell you that directly than let you assume otherwise and feel lied to later.

Why you would trust any of this instead of taking my word: you do not have to. The code is open source under MIT, so you can read exactly what happens. The crypto is libsodium, a standard audited library, not something I invented in a basement (XChaCha20-Poly1305, with a fresh ephemeral key per message so an old message stays sealed even if a later key is compromised). And if you do not trust my relay at all, you can run your own with one Docker command. No phone number required either, just a username or an invite code.

Where it stands: iOS is in App Store review, and I will post the link here the second it is live (`[APP STORE LINK - pending]`). You can self-host and read everything today at `[OPEN-SOURCE REPO LINK]`. Android is planned but not done. It is 1:1 only for now.

I am posting here because this crowd will find the holes I cannot see. If the threat model is weaker than I think, I want to hear it. Pull the crypto apart, question the metadata tradeoff, tell me what would make you actually use this over just staying on Signal. I will answer everything.
