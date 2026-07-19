# Kithra pre-launch credibility plan

A one-to-two-week checklist for building a real Reddit and Hacker News presence before the launch post goes up. The point is simple: when Kithra launches, the account posting it should look like a person who has been part of these communities, not a spam bot that showed up to sell something.

This plan is the "credibility first" half of the [LAUNCH-PLAYBOOK](LAUNCH-PLAYBOOK.md). Do it before you touch the drafts in [posts/](posts/).

## The one rule everything follows

Roughly nine out of ten of your posts and comments in these two weeks should be you being useful to other people, with no mention of Kithra. The tenth can reference what you are building, and only when it genuinely answers the question in front of you. Reddit and HN both watch for accounts whose entire history is one product. Do not be that account.

## Set up the identity (Day 1)

- Decide on the personal account you will use, the same one for Reddit and Hacker News. Real name or one consistent personal handle. Not a brand name, not "KithraApp," not "JQInnovation." The reasons are in the playbook.
- If the account is brand new, that is fine, but it needs history before launch day. If you have an older personal Reddit account with real karma, use it.
- Fill out a plain, human profile. A brand-less account that reads as a real developer is the goal.

## Build genuine history (Days 1 to 12)

Reddit:

- Spend time in r/selfhosted, r/privacy, and r/degoogle as a reader first. Learn the tone of each. They are not the same room.
- Answer questions you actually know the answer to. Self-hosting setups, iOS development, encryption basics, Docker. Aim for a steady trickle of genuinely helpful comments, not a burst.
- When it is honest and relevant, mention that you are building a private video-messaging app. Do not link it yet. You are establishing that a real developer stands behind the thing that is coming.
- Watch for the natural openings: someone asking for a Marco Polo alternative, someone asking how to get family off a data-harvesting app, someone asking about self-hosted messaging. Note them. Some may still be live on launch day.

Hacker News:

- Comment on threads about privacy, encryption, and self-hosting. Thoughtful, specific, no self-promotion.
- Get a feel for how HN argues: technical, blunt, allergic to hype. You want to be comfortable in that water before you are standing in the middle of it during your own Show HN.

## Get the product genuinely ready (Days 1 to 12, in parallel)

r/selfhosted's rule is that promoted apps must be production ready and have docs. Treat that as the gate for the whole launch.

- Repo is public at `[OPEN-SOURCE REPO LINK]`, MIT license visible, README clean and honest.
- The self-host path works from a clean machine. Actually test `docker-compose up` on a fresh box or VM, not just your dev laptop. Write down the exact steps a stranger follows.
- Docs cover: what it is, how to run the relay, how the encryption works at a high level, and the honest metadata limit (the server sees who, when, and blob size, never content). Saying that out loud is what separates a privacy product from a privacy promise, and it is what the r/privacy and HN crowds will check for first.
- A short demo is recorded: 30 to 60 seconds of recording a message, sending it, and opening it on the other phone. Screen recording is fine. This is your "show me, do not tell me."
- Screenshots ready for the App Store listing and for the Reddit posts.

## Start the slow processes early (Day 1)

- Begin Privacy Guides identity verification at https://discuss.privacyguides.net/ if you want a Project Showcase post. It is a human process and will not clear overnight.
- If you plan a TestFlight fallback in case App Store review slips, set that up now so it exists before Day 0.

## The week before launch (Days 12 to 14)

- Re-read the current sidebar rules of every subreddit you plan to post in. They change, and I could not fetch Reddit's live rule pages to confirm r/privacy and r/degoogle for you, so this read is on you.
- Load the four drafts in [posts/](posts/) with the real links pasted in place of the placeholders.
- Confirm one last time that a stranger can self-host it and that the demo video plays.
- Pick your Day 0: a Tuesday, Wednesday, or Thursday when you can sit at the keyboard for three to four hours in the morning Eastern time to answer comments.

## What "ready" looks like

You are ready to launch when all of these are true:

- The personal account has real, recent, useful history in the target communities and no spam pattern.
- The repo is public, the README is honest, and someone who is not you has successfully self-hosted it from the written steps.
- The demo video exists and is short.
- The honest metadata limit is written down before anyone asks.
- You have a Tue-to-Thu morning blocked to be fully present.

Miss any one of these and you are not ready. You only get to launch in each community once, so spend the two weeks and earn the right to be heard.
