# Kithra (speakeasy): talking points

For Joaquim, to glance at before talking about the app. Not published anywhere. The repo behind it is mapped in [REPO_MAP.md](REPO_MAP.md). Written 2026-07-16.

## The one-liner

"It's Marco Polo without the spying: video messages only the recipient can watch, relayed through a server you can run yourself."

## The 30-second version

Marco Polo is how families send video messages, and it has a WARNING privacy rating from Common Sense Media: no end-to-end encryption, the company can access your videos, and your data gets profiled. Kithra is the alternative that shouldn't have to exist but does. You record, your phone encrypts with the recipient's key, and the server just passes along a sealed blob it cannot open. Not even I can watch what goes through my own relay. Open source, self-hostable with one Docker command, iOS first.

## Specifics that land in conversation

- Marco Polo's privacy evaluation is public: a WARNING rating from Common Sense. That's the market square nobody was occupying.
- The comparison table is the pitch: Signal has no async video, Marco Polo has no encryption, Matrix is clunky for this. Kithra is the only one with all four: end-to-end encrypted, self-hosted, open source, async video.
- The crypto is boring on purpose: libsodium, per-message ephemeral keys, forward secrecy by default. Battle-tested library, no homemade math.
- Honesty point that builds trust: the server does see metadata (who, when, blob size). It never sees content. Saying that out loud is what separates a privacy product from a privacy promise.
- App Store submission target: July 24.

## What makes it different

Everyone else asks you to trust a company. Kithra asks you to trust math you can read: the code is MIT-licensed, the encryption happens on your device, and if you don't trust my server you can run your own with `docker-compose up`. The exit is built in, which is the same philosophy I sell client websites with.

## Honest answers to fair questions

- "Why not just use Signal?" Use Signal! But it's built for live chat, not the async video-diary rhythm families use Marco Polo for, and you can't self-host it. Different square.
- "How do you make money on a free app?" I don't, directly. It's a real product in my portfolio that proves I can ship end-to-end: spec, crypto, native app, server, store review. That credibility sells the paid work.
- "Is it actually private?" The content is, and you don't have to take my word: the source is open and the encryption is a standard library. The honest limit is metadata; the relay knows who talked to whom and when, same as your phone company knows who you called.
