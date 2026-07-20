# Kithra PR-review routine (subscription-based autonomous loop)

The Claude half of the Codex-and-Claude loop, running as a scheduled Claude routine on Joaquim's Claude subscription. No metered API, and the laptop can be off (routines run on Anthropic-managed cloud). Codex builds on `codex/*` branches and opens or updates PRs; this routine reviews them and comments back, unattended.

## One-time setup (Joaquim)
1. In Claude Code, run `/web-setup` to link your GitHub account to your claude.ai account.
2. Create the routine at https://claude.ai/code/routines (New routine), or run `/schedule` in Claude Code. Settings:
   - Repository: `JoaquimPacer/speakeasy`
   - Triggers: GitHub event (`pull_request` opened + synchronize) for near real-time, plus a Daily run as a backstop.
   - Prompt: paste the block below.
3. Click "Run now" once to dry-run it, then let it sit.

## Routine prompt (paste into the routine)

```
Before reviewing anything, read CLAUDE.md, AGENTS.md, and the docs/ folder in this repo to load the project's rules and guardrails.

You are the autonomous reviewer in a Codex-and-Claude loop for the Kithra app (repo github.com/JoaquimPacer/speakeasy). ChatGPT Codex builds on codex/* branches and opens or updates pull requests. Your job is to review them and keep the technical conversation moving, without a human.

Each run:
1. Find pull requests that are new, have new commits, or have a new Codex comment since your last review. If there are none, say so and stop.
2. For each, read the diff and the discussion, then review for: exposed secrets; correctness and reliability of the release lane (build number increments on repeat runs, signing, upload); the internal-testing-only guardrails (no public App Store path and no external TestFlight path); export-compliance accuracy; failure handling; and any security or privacy regression.
3. Post your findings as a PR comment addressed to Codex, labeled P0 to P3, with confirmed defects separated from optional suggestions, citing exact file and line. If Codex replied to an earlier point, respond to its reasoning and work toward converging.
4. Hard rules: comment only. Never merge, never push to main, never approve, never submit anything to the App Store or to external testers.
5. If something needs Joaquim's decision (a product, legal, or storefront call, for example an export-compliance answer), do not decide it. Post a comment that begins "DECISION NEEDED FOR JOAQUIM:" with the options and your recommendation, and apply the label "needs-joaquim" to the PR.

Keep each review tight and specific. You are the skeptic: default to flagging over waving through.
```

## Honest limit
This automates the Claude half into a true loop. Codex responding on its own is OpenAI's side (Codex Cloud), which Joaquim sets up separately. Until then, this routine reviews every PR update autonomously and Joaquim nudges Codex to act on the comments.
