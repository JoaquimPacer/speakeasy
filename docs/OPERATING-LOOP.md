# Operating Loop: Codex-Led App Delivery

Kithra uses one durable, repository-centered workflow so work can continue from
the Codex CLI, VS Code extension, desktop app, or Codex Cloud without relying on
one chat transcript.

## Roles

- **Codex:** primary implementation, diagnosis, documentation, verification,
  PR maintenance, and technical-review operator.
- **Joaquim:** sole code owner and final authority for product, privacy, legal,
  export-compliance, storefront, credentials, merge, deployment, signing,
  submission, and public-release decisions.
- **Optional reviewers:** people or other models may supply evidence and
  critiques. Their comments are advisory; Codex evaluates the reasoning and
  escalates genuine owner decisions to Joaquim.

## Durable State

Git and GitHub are the source of truth:

- `AGENTS.md` contains repository-wide operating constraints.
- `docs/BUILD_PLAN.md` records current decisions, status, and release gaps.
- `docs/OWNER_SETUP.md` records non-secret owner actions.
- `docs/CODEX_REVIEW_LOOP.md` defines reliable PR handoffs.
- PR heads, comments, and checks record the exact implementation state.

Local Codex Memories can help recall preferences and prior context, but they do
not replace checked-in rules or current repository evidence.

## Normal Loop

1. Open the repository in VS Code and continue the relevant recent Codex chat,
   or start Codex from the repository directory.
2. Give Codex a concrete outcome and any protected actions that remain
   forbidden.
3. Codex inspects current code/PR state, implements on a feature branch, runs
   applicable checks, pushes, and opens or updates a draft PR.
4. CI and a separate review pass check the exact PR head. Optional outside
   review comments are evaluated as evidence.
5. Codex addresses authorized findings and posts a structured response.
6. Joaquim explicitly chooses whether to merge or authorize the next release
   gate. Green checks alone never authorize shipping.

## Release Loop

Keep build automation separate from release authority:

1. Codex prepares and verifies unsigned code, metadata, and release tooling.
2. Joaquim separately authorizes any signing, upload, deployment, App Store
   questionnaire, submission, or release action.
3. Internal TestFlight smoke-tests the exact public-eligible candidate on two
   iPhones.
4. Joaquim submits the verified candidate to App Review.
5. App updates repeat the same path; each update still goes through App Review,
   although critical bug-fix submissions can request expedited review.

## Automation Guardrails

The current PR loop is human-supervised. Before enabling an unattended writer,
require protected `main`, read-only default workflow tokens, a least-privileged
automation identity, exact-head and unique-task checks, one-writer concurrency,
and a tested manual disable switch. Never expose signing, deployment, App Store,
merge, or secret-management authority to the unattended loop.

The reusable prompt and readiness checklist live in
`automation/codex-pr-routine.md`.
