# Operating loop: building apps across two AI models

One page on how Joaquim runs app builds using Claude Code and ChatGPT Codex together, without paying twice for the same work. Kithra is the first app through this loop; the pattern is meant to generalize to every app after it.

## The two roles
- **Claude Code (Windows)**: the orchestrator and generalist. Planning, the Go relay/server, all docs, Trello, marketing, reviewing diffs, cross-cutting infra. Instructions live in CLAUDE.md.
- **ChatGPT Codex (Mac)**: the app builder. Native Swift and Kotlin, on-Mac builds (Xcode, Fastlane), and its own computer-use checks. Instructions live in AGENTS.md.

Rule of thumb: if it needs the Mac or native app code, Codex does it. Everything around it (what to build, why, docs, launch, review) is Claude.

## The bridge is git
State lives in the repo. Claude writes a brief or a prompt, Codex does the work on a branch and commits, Claude reads the branch and reviews. Nothing important lives only in a chat window.

Three ways to hand work to Codex, from most friction to least:
1. **Paste a prompt (current):** Claude writes it, you paste into Codex in the ChatGPT app. Works, but manual.
2. **Commit the brief:** Claude writes the brief to a file, you pull on the Mac, Codex reads it there. Less pasting.
3. **Codex CLI or IDE (best):** Codex runs inside the repo with direct file access, the way Claude Code does. No paste at all. Worth trying on the Mac.

For Claude to review Codex's work, Codex pushes its branch and Claude reads it from Windows. No screen-sharing needed for code.

## Guardrails
- Branches, never straight to main. Any bad change is one `git revert` away.
- Auto-push to TestFlight is fine (internal testers only). The public App Store release is a manual approval.
- Secrets never enter git. Before open-sourcing anything, scrub the full history.

## Toward automated loops
The automation is scripts and CI (Fastlane, GitHub Actions), and it stays model-agnostic: a model is one step in the loop, never the engine. Fastlane collapses build, sign, and upload into one command, so a push can ship a build. Each brief Claude writes is reusable, so app number two starts from the loop instead of from scratch.

## Subscription use
Pay each tool for its strength and stop there. Claude for breadth, orchestration, and its plugins and skills. Codex for on-Mac native builds and its computer-use. Grok is parked (an optional research or second-opinion lane). continue.dev is optional: an in-editor model switcher, useful only if you want several models in one editor.

## Tools in the loop
- **Jump Desktop:** view the Mac's screen from Windows for the occasional check. LAN is near-instant; Tailscale extends it securely when you are away.
- **Telegram:** how prompts currently move to the Mac. The Codex CLI removes this step.
- **Trello (App Building board):** the task ledger and the single source of truth for what is done and what is next.
