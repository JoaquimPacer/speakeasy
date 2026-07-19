# Kithra launch and credibility playbook

The plan for taking Kithra from a private repo to a launch that the privacy and self-hosting crowd actually respects. Written for Joaquim, 2026-07-19.

Related docs: [MARKETING talking points](../docs/MARKETING.md), [REPO_MAP](../docs/REPO_MAP.md), [SECURITY](../docs/SECURITY.md), [README](../README.md). The pre-launch checklist lives in [credibility-plan.md](credibility-plan.md). The ready-to-post drafts are in [posts/](posts/).

Product recap in one line: Kithra is Marco Polo without the spying. Async video messages that only the recipient can open, relayed through a Go server anyone can run with one Docker command. iOS first, Android later. MIT licensed. The crypto is libsodium (XChaCha20-Poly1305, per-message ephemeral keys), and the relay only ever handles a sealed blob it cannot read.

App Store link status: NOT live yet. Everywhere below it appears as `[APP STORE LINK - pending]`. The open-source repo appears as `[OPEN-SOURCE REPO LINK]`. Submission target is July 24, so the whole sequence hangs off the day that link goes live.

---

## Part 1: two audiences that do not overlap

Kithra serves one crowd. Kithra also serves as proof for a completely different crowd. Confusing the two is the fastest way to fail with both.

### Audience A: Kithra's actual users and its early community

Who they are: privacy-conscious people, self-hosters, open-source developers, families who use Marco Polo and would leave it if they had somewhere honest to go. They read Hacker News and live in a handful of subreddits. They have seen a thousand "privacy-first" apps that turned out to be data funnels, so their default is suspicion.

What they want: to run the code themselves, to read the crypto, to hear a real person explain the honest limits (yes, the relay sees metadata). They reward transparency and punish marketing.

Where they are: Hacker News (Show HN), r/selfhosted, r/privacy, r/degoogle, the Privacy Guides forum, GitHub. Later, F-Droid-adjacent Android channels once the Kotlin client ships.

### Audience B: JQ Innovation's future clients

Who they are: local service businesses. A massage therapist, an auto shop, a dance studio. They do not care about XChaCha20-Poly1305. They will never read a threat model.

What Kithra does for them: it is evidence. It proves that the person building their website can ship a real product end to end: a spec, working cryptography, a native iOS app, a server, and an App Store review. That is a credibility signal money cannot buy, and it makes the paid work easier to sell.

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
- The repo is public, the README is clean, and the self-host path genuinely works from a clean machine. r/selfhosted's rule is explicit that promoted apps "must be production ready and have docs," so this is a hard gate, not a nice-to-have. (Source: r/selfhosted rules, retrieved via https://leadsrover.io/subreddits/r/selfhosted)
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
- What that means for you: the docker-compose path has to actually work and be documented, and you disclose you are the developer. This is the friendliest room for Kithra, so it goes first among the subreddits.

### r/privacy (the "why I built this" angle)

- URL: https://www.reddit.com/r/privacy/
- Status: UNVERIFIED specifics. I could not fetch the live rules and no aggregator listed them, so read the sidebar yourself before posting. What is well established: r/privacy is strict about anything that smells like an ad. Open-source privacy tools do get discussed there, but the post has to read as "here is a problem and an honest, verifiable answer," with the developer disclosed and the honest limits stated up front. Frame it as the Marco Polo problem, not as a product pitch.

### r/degoogle (the "de-Google your video chats" angle)

- URL: https://www.reddit.com/r/degoogle/
- Status: UNVERIFIED specifics. Same caveat, read the sidebar first. Known character of the community: they welcome concrete open-source alternatives to Big Tech services and remove low-effort or pure-ad posts. Be honest that it is iOS first, because a large slice of this crowd runs GrapheneOS or LineageOS on Android and will (fairly) point out that they cannot use it yet. Say the Kotlin client is planned.

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

- T-14 to T-3: run the [credibility-plan.md](credibility-plan.md) checklist. Build history on the personal account, make the repo public, verify the self-host path from a clean machine, cut the demo video, and start Privacy Guides identity verification.
- T-2: final read of every subreddit sidebar. Confirm the repo README and docs are clean. Confirm docker-compose up works one more time.
- T-1: line up the four drafts in [posts/](posts/) with the real links pasted in. Sleep.
- Day 0 morning (Tue to Thu, ~8 to 10am ET): post the Show HN with `[OPEN-SOURCE REPO LINK]` in the URL field, add your backstory comment, and then stay in the thread for three to four hours answering everything. This is the anchor event. See [posts/show-hn.md](posts/show-hn.md).
- Day 0 afternoon or Day +1: post to r/selfhosted. The self-host story is strongest and the docs are ready. See [posts/reddit-selfhosted.md](posts/reddit-selfhosted.md).
- Day +2: post to r/privacy with the "why I built this" framing. See [posts/reddit-privacy.md](posts/reddit-privacy.md).
- Day +3 or +4: post to r/degoogle with the "de-Google your video chats" framing. See [posts/reddit-degoogle.md](posts/reddit-degoogle.md).
- Day +3 to +5: one post to r/SideProject, and hold the single r/iosapps post for whenever you can be present to reply.
- Ongoing, in parallel: the JQ Innovation brand posts the build-in-public thread and demo video on X and YouTube. This is Audience B and runs on its own clock, timed loosely to the launch but not competing for your attention during the Show HN window.
- Privacy Guides Project Showcase: whenever identity verification clears.

Fallback if App Store review slips past July 24: the self-host path means people can still run Kithra without the App Store. If the iOS link is not live on your chosen Day 0, you can still launch on the repo and a TestFlight or self-host build, lead everywhere with "self-host it today, iOS App Store link coming this week," and swap the App Store link in the moment it clears. Do not hold the whole launch hostage to Apple's review queue, but do be honest that the polished iOS install is a few days out.

---

## Part 6: the virality template (from real, verifiable launches)

I looked at how comparable projects went from nothing to real traction. Four cases, all verifiable, all relevant to a solo builder with a privacy or self-hosted tool.

1. Build in public before you launch. Peter Steinberger's OpenClaw went from a weekend project to the most-starred repo on GitHub (346k+ stars) in under five months, and the turning point was showing it solving weird problems live in a public Discord so onlookers did the sharing for him. Verified real: he later joined OpenAI and the project moved to a foundation. (Sources: https://steipete.me/posts/2026/openclaw , https://en.wikipedia.org/wiki/OpenClaw , https://www.fastcompany.com/91550800/how-peter-steinberger-built-openclaw )

2. Solve your own real problem and say so in plain words. Alex Tran built Immich, the self-hosted photo backup, because he was tired of paying Google to store photos of his own kid. That specific, personal origin is the sentence people repeat, and it carried the project to 80k+ GitHub stars, largely through r/selfhosted. (Sources: https://github.com/immich-app/immich , https://linuxiac.com/immich-team-goes-full-time/ )

3. Be genuinely open source with a self-host path that works, then keep showing up on HN. Ente, an end-to-end encrypted Google Photos alternative, launched on Hacker News in 2021 and grew steadily by posting new Show HNs as it hit real milestones (the v1.0 and the full open-sourcing each got their own). People could run it and read it, so trust was not required. (Sources: https://news.ycombinator.com/item?id=28347439 , https://news.ycombinator.com/item?id=43516081 )

4. Answer every comment like a person, and name the sharp comparison. The dev-tool launches that work have the founder replying thoroughly and humbly (one cited fly.io launch had the founder answer 53 comments), and the ones that spread have a one-line comparison that occupies an empty square: "Google Photos, but yours." Kithra already has its version of that in the README table: "Marco Polo, but only your friend can open it," backed by Marco Polo's actual WARNING privacy rating. (Sources: https://www.markepear.dev/blog/dev-tool-hacker-news-launch , https://privacy.commonsense.org/evaluation/Marco-Polo-Video-Walkie-Talkie )

The repeatable pattern underneath all four: pick one empty square in the market and name it, solve a problem you personally have and tell that story, make the thing runnable and readable so nobody has to trust you, show up as a human and answer everything, and let the sharp comparison do the spreading. That is the template Kithra should run.
