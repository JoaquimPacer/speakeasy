# Draft: Show HN

Angle: technical and humble. HN rewards a real builder who shows up and answers everything, and punishes hype. Neutral title, no exclamation marks, no superlatives.

Submit URL: https://news.ycombinator.com/submit
Guidelines: https://news.ycombinator.com/showhn.html

---

## Title

```
Show HN: Kithra - E2E encrypted async video messages you can self-host
```

Keep it exactly that plain. No "fastest," no "finally," no marketing. The title's job is to say what it is, nothing more.

## How to submit (mechanics)

- Put `[OPEN-SOURCE REPO LINK]` in the URL field. If the App Store link is live by then you can use `[APP STORE LINK - pending]` instead, but the repo is the better link for HN because people want to read the code. Posts with no URL get penalized.
- Leave the text field blank.
- Submit, then immediately post the comment below as the first reply in your own thread. That is where the story goes.

## First comment (post this yourself, right after submitting)

Hi HN. I built Kithra, an app for async video messages (the Marco Polo style of thing, where you send a short clip and your friend watches it later) where only the recipient can open the video.

The reason it exists: my family uses Marco Polo, and its Common Sense privacy evaluation is a WARNING rating. No end-to-end encryption, the company can access your video content, your data gets profiled. I wanted the same easy back-and-forth without that, and there was no open-source, self-hostable, end-to-end encrypted option for async video, so I wrote one.

How it works. The client (Swift, iOS) records a video and encrypts it on the device with the recipient's public key before upload. The server is a small Go binary that stores and forwards a sealed blob it cannot open. The recipient's phone downloads and decrypts. Crypto is libsodium: XChaCha20-Poly1305, with a fresh ephemeral key per message, so compromising one key does not retroactively open older messages.

What the server knows, stated plainly: metadata only. Who sent to whom, when, and the blob size. It never sees content. I think saying that out loud matters, because a privacy claim with an asterisk you have to dig for is worse than no claim.

Self-hosting is the point, not a footnote. If you do not want to trust my relay, `docker-compose up -d` and it is yours. Local filesystem storage by default, optional S3-compatible. No analytics or telemetry. No phone number to sign up, just usernames or invite codes. MIT licensed.

The honest state of it: iOS first, and the App Store build is in review (`[APP STORE LINK - pending]`, I will edit it in when it clears). Android (Kotlin) is planned, not built. It is 1:1 only right now, no groups, no web client yet. The self-host relay and all the code are up today at `[OPEN-SOURCE REPO LINK]`.

Where I would most value feedback: the client-side crypto and key handling, the metadata tradeoff and whether there is a reasonable way to shrink it, and anything about the self-host experience that would stop you running it. I am here for the day, so ask away.

## How to handle the thread

- Be present. The first 60 to 90 minutes largely decide whether this reaches the front page, and being in the thread answering is more important than the exact posting time. Block three to four hours. Do not post right before a meeting, a flight, or sleep.
- Timing: aim for Tuesday, Wednesday, or Thursday, roughly 8 to 10am Eastern, when the US technical crowd is awake.
- Answer like a person. No canned or AI-sounding replies, HN spots those instantly and turns on them. Short, specific, technical.
- When someone criticizes, find the true part first and agree with it, then respond. You are not trying to win the critic, you are trying to be reasonable in front of everyone reading. On HN that reads as strength.
- Do not ask anyone to upvote or comment. It is against the rules and it is obvious when it happens.
- If the metadata question comes up hard (it will), do not get defensive. Restate the honest limit, explain why a relay has to see routing metadata, and point to the self-host option for people who want to own even that.
