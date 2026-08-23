# Kithra launch and credibility playbook

> Unpublished internal plan. Do not post or quote this file as current product
> status. Re-check every external link, community rule, comparison, and product
> claim immediately before launch.

The plan for taking Kithra from a public source repository to a launch that the privacy and self-hosting crowd actually respects. Written for Joaquim and updated 2026-08-04.

Related docs: [MARKETING talking points](../docs/MARKETING.md), [REPO_MAP](../docs/REPO_MAP.md), [SECURITY](../docs/SECURITY.md), [README](../README.md). The pre-launch checklist lives in [credibility-plan.md](credibility-plan.md). The unpublished post drafts are in [posts/](posts/).

Product recap in one line: Kithra is a native iPhone app for private asynchronous video messages, backed by a self-hostable Go relay that stores ciphertext it cannot decrypt. It uses libsodium-backed primitives and a fresh random content key for each video. Those content keys limit single-key exposure; V1 does not provide Signal-style forward secrecy. Android is a later release, and the current Android directory is only a scaffold.

App Store status: PRE-SUBMISSION. Kithra is not currently in App Store review and has no public install link. Everywhere below it appears as `[APP STORE LINK - pending]`; the repository appears as `[OPEN-SOURCE REPO LINK]`. Launch timing is relative to the day Joaquim confirms the public App Store link is live, not a fixed calendar date.

---

## Part 1: two audiences that do not overlap

Kithra serves one crowd. Kithra also serves as proof for a completely different crowd. Confusing the two is the fastest way to fail with both.

### Audience A: Kithra's actual users and its early community

Who they are: privacy-conscious people, self-hosters, open-source developers, families who use Marco Polo and would leave it if they had somewhere honest to go. They read Hacker News and live in a handful of subreddits. They have seen a thousand "privacy-first" apps that turned out to be data funnels, so their default is suspicion.

What they want: to run the code themselves, to read the crypto, to hear a real person explain the honest limits (yes, the relay sees metadata). They reward transparency and punish marketing.

Where they are: Hacker News (Show HN), r/selfhosted, r/privacy, r/degoogle, the Privacy Guides forum, GitHub. Later, F-Droid-adjacent Android channels once the Kotlin client ships.

### Audience B: JQ Innovation's future clients

Who they are: local service businesses. A massage therapist, an auto shop, a dance studio. They do not care about XChaCha20-Poly1305. They will never read a threat model.

What Kithra can do for them after launch: it is evidence that the person building their website can ship a real product end to end—a spec, working cryptography, a native iPhone app, a server, and a public release. Do not claim the App Store milestone before it happens.

Where they are: not on Hacker News. They are reachable through the JQ Innovation brand on X and YouTube, the future jqinnovation.com portfolio, and word of mouth. To this audience Kithra is a short, plain-language story ("I built a private video app from scratch, here is the two-minute version"), never a technical deep dive.

### Why they need different channels

The privacy crowd treats polish and brand voice as a warning sign. The client crowd treats a wall of crypto jargon as noise. A single message tuned for both lands with neither. So the split is clean: Audience A gets the raw builder's voice on Reddit and HN, Audience B gets the founder's story on X and YouTube under the JQ Innovation name. Same product, two doors.

---

## Part 2: the handle question (decided)

Post under a real personal identity on Reddit and Hacker News. Use Joaquim's own name or one consistent personal handle, the same account everywhere, with a real posting history behind it. Reserve the JQ Innovation brand account for X and YouTube.

Why the brand account gets treated as spam on Reddit and HN:

- Hacker News says it outright in its own guidelines: do not make your username your company or project name, because "it creates a feeling of using the site for promotion and of not really participating as a person." A brand-named account launching a Show HN reads as an ad, and HN penalizes ads. (Source: https://news.ycombinator.com/showhn.html)
- Reddit communities distrust accounts that exist only to push one product. A username like "JQInnovation" or "KithraApp" with zero comment history and one promotional post is the exact pattern moderators auto-remove. A person named account that has been answering questions for two weeks is the exact pattern they leave up.
- The whole point of these communities is peer-to-peer talk between people who build things. A brand is not a peer. A founder posting as himself is.

X and YouTube run on the opposite logic. There a brand handle is expected, discoverable, and good for the portfolio. So the brand lives there, and the person lives on Reddit and HN.

---

## Part 3: credibility first, launch second

The single biggest failure mode is a cold account dropping a launch post into a skeptical subreddit on day one. It gets removed or downvoted, and you only get to launch once per community.

The fix is a genuine presence built over roughly one to two weeks before the launch post. The full checklist is in [credibility-plan.md](credibility-plan.md). The short version:

- Real posting history on the personal account: helpful comments, honest answers, disclosure that you are a developer when it is relevant. No lurking-then-launching.
- The repo is public, the README is clean, and the relay self-host path genuinely works from a clean machine. r/selfhosted's rule is explicit that promoted apps "must be production ready and have docs," so this is a hard gate, not a nice-to-have. Self-hosting the relay is not an alternate way to install the iPhone app. (Source to re-check before posting: r/selfhosted rules, retrieved via https://leadsrover.io/subreddits/r/selfhosted)
- A short demo (a 30 to 60 second screen recording of recording, sending, and opening a message) is ready, because "show me" beats "trust me" every time in these rooms.
- The honest metadata limit is written down plainly before anyone asks, because on r/privacy and HN someone will ask within the first ten minutes.

Credibility is the product here. The app is the excuse to demonstrate it.

---

## Part 4: the target communities and their current rules

Read every subreddit's own sidebar and rules the day before you post, because moderators change them and I could not fetch Reddit's live rule pages directly (Reddit blocks automated fetching, so two of the entries below are marked unverified and need your eyes on the sidebar).

### Hacker News, Show HN

- Submit URL: https://news.ycombinator.com/submit
- Rules: https://news.ycombinator.com/showhn.html
- Mechanics: put `[OPEN-SOURCE REPO LINK]` (or `[APP STORE LINK - pending]` once live) in the URL field, leave the text field blank, and make the title begin with "Show HN:". Posts without a URL get penalized. Then immediately add your own comment with the backstory.
- Bar: it must be something people can try, personally made, non-trivial, and you have to be present to discuss it. Neutral title, no hype, no exclamation marks. Do not ask anyone to upvote. (Source: https://news.ycombinator.com/showhn.html)

### r/selfhosted (the self-host angle leads here)

- URL: https://www.reddit.com/r/selfhosted/
- Verified rule: "Do not spam or promote your own projects too much. We expect you to follow this Reddit self-promotion guideline. Promoted apps must be production ready and have docs. No direct ads for web hosting or VPS. Only mention your service in comments if it's relevant and adds value." (Source: https://leadsrover.io/subreddits/r/selfhosted)
- What that means for you: the Docker Compose relay path has to work from a clean host and be documented, and you disclose you are the developer. Re-check the live rules before deciding whether this community should go first.

### r/privacy (the "why I built this" angle)

- URL: https://www.reddit.com/r/privacy/
- Status: UNVERIFIED specifics. Read the live sidebar yourself before posting. Open-source privacy tools may be discussed there, but the post must disclose the developer and state the relay metadata and forward-secrecy limits up front. Frame it as a problem and a verifiable implementation, not as a privacy guarantee.

### r/degoogle (the "de-Google your video chats" angle)

- URL: https://www.reddit.com/r/degoogle/
- Status: UNVERIFIED specifics. Read the live sidebar first. Be direct that V1 is iPhone-only. The Kotlin directory is a scaffold for a later native Android client, not something GrapheneOS or LineageOS users can install today.

### r/PrivacyGuides and the Privacy Guides forum

- Subreddit: https://www.reddit.com/r/PrivacyGuides/
- Forum: https://discuss.privacyguides.net/
- Verified rule (forum): the "Project Showcase" category is the only place a developer may promote their own project, and you must verify your identity with the Privacy Guides team before posting. They do not endorse anything not on their official recommendations page. (Source: https://discuss.privacyguides.net/t/guidelines-for-posting-about-my-privacy-focused-project/36766)
- What that means: start the identity verification early (it is a human process and takes time), and treat a Project Showcase post as a bonus, not a launch-day channel.

### One app community: r/iosapps (evaluated alongside r/SideProject)

- r/iosapps: https://www.reddit.com/r/iosapps/ . Self-promotion is allowed but capped at once per developer per 30 days, and they expect you to have some comment history first. Build a little history, then post once, well. (Source: https://leadsrover.io/subreddits/r/iosapps)
- r/SideProject: https://www.reddit.com/r/SideProject/ . Low karma gate, and you can post any day as long as you actually built it. The common removal reason is vague product posts with no build detail, so lead with how it works. (Source: https://www.soar.sh/blog/self-promotion-rules-by-subreddit-database)
- Recommendation: r/SideProject is the better fit of the two for launch week (open, forgiving, values the build story). Hold r/iosapps for a single well-timed post once the App Store link is live, since their 30-day cap means you get one shot.

---

## Part 5: launch-week sequence

Everything is anchored to the day the App Store link goes live. Call that Day 0. Pick a Tuesday, Wednesday, or Thursday for Day 0, because Show HN does best Tuesday through Thursday, roughly 8 to 10am Eastern, when the US technical audience is awake and you can sit and answer comments. The first 60 to 90 minutes of a Show HN largely decide whether it reaches the front page, so the rule is simple: do not post before a meeting, a flight, or bed. (Sources: https://syften.com/blog/hacker-news-marketing/ and https://www.markepear.dev/blog/dev-tool-hacker-news-launch)

Do not fire every channel in the same hour. Stagger them. Reddit flags identical cross-posts, each community wants a native post written for it, and you can only genuinely be present in one thread at a time. Presence is the whole game.

- T-14 to T-3: run the [credibility-plan.md](credibility-plan.md) checklist. Build history on the personal account, verify the relay self-host path from a clean machine, cut the demo video, and start Privacy Guides identity verification.
- T-2: final read of every subreddit sidebar. Confirm the repo README and docs are clean. Confirm the Docker Compose relay works one more time.
- T-1: line up the four drafts in [posts/](posts/) with the real links pasted in. Sleep.
- Day 0 morning (Tue to Thu, ~8 to 10am ET): post the Show HN with `[OPEN-SOURCE REPO LINK]` in the URL field, add your backstory comment, and then stay in the thread for three to four hours answering everything. This is the anchor event. See [posts/show-hn.md](posts/show-hn.md).
- Day 0 afternoon or Day +1: post to r/selfhosted. The self-host story is strongest and the docs are ready. See [posts/reddit-selfhosted.md](posts/reddit-selfhosted.md).
- Day +2: post to r/privacy with the "why I built this" framing. See [posts/reddit-privacy.md](posts/reddit-privacy.md).
- Day +3 or +4: post to r/degoogle with the "de-Google your video chats" framing. See [posts/reddit-degoogle.md](posts/reddit-degoogle.md).
- Day +3 to +5: one post to r/SideProject, and hold the single r/iosapps post for whenever you can be present to reply.
- Ongoing, in parallel: the JQ Innovation brand posts the build-in-public thread and demo video on X and YouTube. This is Audience B and runs on its own clock, timed loosely to the launch but not competing for your attention during the Show HN window.
- Privacy Guides Project Showcase: whenever identity verification clears.

If App Store review takes longer than expected, do not imply that self-hosting the relay installs Kithra or use internal TestFlight as a public fallback. Continue technical discussion around the source and relay only if it is useful, label the iPhone app pre-release accurately, and postpone the end-user launch sequence until the public App Store URL exists.

---

## Part 6: the virality template (from real, verifiable launches)

I looked at how comparable projects went from nothing to real traction. Four cases, all verifiable, all relevant to a solo builder with a privacy or self-hosted tool.

1. Build in public before you launch. Peter Steinberger's OpenClaw went from a weekend project to the most-starred repo on GitHub (346k+ stars) in under five months, and the turning point was showing it solving weird problems live in a public Discord so onlookers did the sharing for him. Verified real: he later joined OpenAI and the project moved to a foundation. (Sources: https://steipete.me/posts/2026/openclaw , https://en.wikipedia.org/wiki/OpenClaw , https://www.fastcompany.com/91550800/how-peter-steinberger-built-openclaw )

2. Solve your own real problem and say so in plain words. Alex Tran built Immich, the self-hosted photo backup, because he was tired of paying Google to store photos of his own kid. That specific, personal origin is the sentence people repeat, and it carried the project to 80k+ GitHub stars, largely through r/selfhosted. (Sources: https://github.com/immich-app/immich , https://linuxiac.com/immich-team-goes-full-time/ )

3. Be genuinely open source with a self-host path that works, then keep showing up on HN. Ente, an end-to-end encrypted Google Photos alternative, launched on Hacker News in 2021 and grew steadily by posting new Show HNs as it hit real milestones (the v1.0 and the full open-sourcing each got their own). People could run it and read it, so trust was not required. (Sources: https://news.ycombinator.com/item?id=28347439 , https://news.ycombinator.com/item?id=43516081 )

4. Answer every comment like a person, and name the sharp comparison. The dev-tool launches that work have the founder replying thoroughly and humbly, and the ones that spread have a one-line comparison that occupies an empty square: "Google Photos, but yours." Kithra's accurate version is "asynchronous video messages whose content the relay cannot decrypt." Re-check any Marco Polo privacy comparison against the cited source immediately before publishing. (Sources to re-check: https://www.markepear.dev/blog/dev-tool-hacker-news-launch , https://privacy.commonsense.org/evaluation/Marco-Polo-Video-Walkie-Talkie )

The repeatable pattern underneath all four: pick one empty square in the market and name it, solve a problem you personally have and tell that story, make the thing runnable and readable so nobody has to trust you, show up as a human and answer everything, and let the sharp comparison do the spreading. That is the template Kithra should run.
