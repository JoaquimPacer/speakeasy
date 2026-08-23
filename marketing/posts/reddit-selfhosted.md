# Draft: r/selfhosted

> Unpublished draft. Kithra is pre-submission; do not post this until a clean
> host has reproduced the relay setup, the public App Store URL exists, and the
> current subreddit rules have been checked.

Angle: the self-host story leads. This is the friendliest room, so it goes first among the subreddits. Disclose you are the developer. Keep it about how it runs, not about how great it is.

Subreddit: https://www.reddit.com/r/selfhosted/
Rule to respect: promoted apps must be production ready and have docs, no VPS ads, disclose that it is yours. (Rules are in the playbook.)

Before posting: paste the real links over `[OPEN-SOURCE REPO LINK]` and `[APP STORE LINK - pending]`, and re-read the current sidebar.

---

**Title:**

I built a self-hostable, end-to-end encrypted relay for async video messages (a Marco Polo alternative). Single Go binary, `docker-compose up`.

---

**Body:**

Full disclosure up front: I built this, so this is my own project.

The itch was that my family uses Marco Polo for those little video check-ins, and Marco Polo has a WARNING privacy rating from Common Sense. No end-to-end encryption, the company can watch your videos, your data gets profiled. I wanted the same easy async video rhythm without handing a company my family's faces, and I could not find anything self-hostable that did it. So I wrote one.

It is called Kithra. Here is the part that matters for this sub.

The server is a small Go binary whose only job is to hold onto ciphertext and pass it along. The sender's iPhone encrypts the video to a verified contact device before it ever leaves the phone, so the relay cannot decrypt verified message content. To stand up your own relay:

```
docker-compose up -d
```

Ciphertext storage is the local filesystem. S3-compatible storage is not implemented. The project contains no analytics, advertising, tracking, or telemetry.

Being honest about what the server does see, because you would find out anyway: it knows who sent to whom, when, and the size of the encrypted blob. Metadata, in other words, the same shape of thing your phone company knows about your calls. It never sees the video, the audio, or a thumbnail. If that tradeoff is a dealbreaker for your threat model, I would rather you know now than feel misled later.

Stack, quickly: Go relay, native Swift iPhone client, and libsodium-backed X25519, Ed25519, and XChaCha20-Poly1305. Every video receives a fresh random content key, which limits one content-key exposure but does not provide Signal-style forward secrecy. MIT licensed. The code is all here: `[OPEN-SOURCE REPO LINK]`.

Where it actually is: the local-filesystem relay and Docker Compose deployment are implemented, but this draft must not be posted until a clean host reproduces the written setup. The native iPhone app is pre-submission and has no public App Store link (`[APP STORE LINK - pending]`). Android has only a future-client scaffold. It is 1:1 only right now, with no groups.

What I would love from this sub: tear the self-host setup apart. Tell me where the docs are thin, whether the compose file is doing anything dumb, and what would make you actually trust running this on your own box. Happy to answer anything.
