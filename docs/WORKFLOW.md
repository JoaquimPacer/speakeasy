# Speakeasy Workflow

This file explains how owner setup, development, secrets, CI, and long-running
agent work fit together. It is the operator map; `docs/BUILD_PLAN.md` remains
the implementation roadmap.

## Document Map

- `docs/BUILD_PLAN.md` tracks product decisions, current status, roadmap, and
  what a new agent should read before changing code.
- `docs/OWNER_SETUP.md` tracks account setup using non-secret status notes.
- `docs/CI.md` tracks GitHub Actions, Xcode Cloud, and release automation.
- `docs/DEPLOYMENT.md` tracks local relay, laptop beta relay, tunnel, and VPS
  deployment.
- `docs/SPEC.md`, `docs/API.md`, and `docs/SECURITY.md` define product,
  protocol, API, and security behavior.

## Secret Model

Default rule: do not store long-lived secrets in git history. `.gitignore`
prevents accidental commits; it is not encryption or access control.

Owner convenience exception: this project allows owner-local secrets under the
ignored repo path `secrets/` so the workspace can sync across the owner's
Windows machines with OneDrive. This is a conscious tradeoff: OneDrive and the
owner's Microsoft account become part of the trust boundary. It is acceptable
for local owner copies of Apple keys, Cloudflare tokens, and similar setup
material, but these files must never be committed or used as the team-sharing
mechanism.

Reasons:

- Ignored files are still readable by local tools, scripts, extensions, backup
  jobs, screen-sharing sessions, and agents running in the workspace.
- A zipped project folder, copied workspace, or support bundle can include
  ignored files by mistake.
- Collaborators do not receive ignored files when they clone the repo, so
  `secrets/` is for the owner only.
- Shared credentials are hard to rotate per person and hard to audit.
- A deploy credential usually has broader power than any one contributor should
  need.

Safe locations:

- Ignored repo-local path `secrets/`: owner-local synced convenience storage.
- Password manager or encrypted vault: higher-security owner copies of Apple
  `.p8` files, recovery material, SSH keys, Cloudflare tokens, and
  payment/account records.
- GitHub Actions secrets or Xcode Cloud secrets: CI-only values used by build,
  upload, or deployment jobs.
- Deployment host secret files: production or beta `.env.local` files under the
  service account on that host, outside the git checkout.
- Local `.env.local`: local-only development values, never production owner
  credentials.

For App Store Connect, the owner-local synced path is:

```text
C:\Users\f927g\OneDrive\Documents\GitHub\Speakeasy\secrets\app-store-connect\AuthKey_<KEY_ID>.p8
```

Only the CI secret values should be copied into GitHub Actions or Xcode Cloud
when a workflow actually needs them.

## Access Model

The repository should contain code, docs, workflow definitions, and non-secret
configuration names. The ignored `secrets/` folder may exist in the working
copy, but it is owner-local workspace state, not project source.

Human collaborators get access by:

- GitHub repo permissions for source code.
- App Store Connect user invitations with the narrowest useful role.
- Developer portal access only when they truly need signing, identifiers,
  certificates, or provisioning.

Automation gets access by:

- GitHub Actions secrets or Xcode Cloud secrets.
- Separate deploy keys or service credentials per workflow where practical.
- Manual approvals through GitHub Environments or App Store Connect review
  gates for release-like jobs.

A team API key is team-scoped because it can act across the App Store Connect
team. It is not a file every teammate should share. Treat it as a deploy
credential owned by the automation, not as a source file.

## Multi-Machine Workflow

Use GitHub, not OneDrive, as the source of truth for code.

Do not keep active git repositories under OneDrive, iCloud Drive, Dropbox, or
similar file-sync folders when doing real development. Git repositories contain
many small files and a constantly changing `.git/` database. Xcode also creates
large, noisy build state. Cloud sync tools can be slow, conflict-prone, or
confused by that shape.

Recommended layout:

```text
Windows desktop: C:\Users\f927g\src\speakeasy
Windows laptop:  C:\Users\f927g\src\speakeasy
MacBook:         ~/Developer/speakeasy
```

Sync code by committing and pushing branches:

```bash
git status
git switch -c codex/some-work
git add .
git commit -m "Describe the checkpoint"
git push -u origin codex/some-work
```

Then on another machine:

```bash
git clone https://github.com/JoaquimPacer/speakeasy.git
cd speakeasy
git fetch origin
git switch codex/some-work
```

For quick machine handoff, commit a checkpoint branch even if the work is not
ready for `main`. The branch is the portable workspace. A pull request can stay
draft until it is reviewed.

Use OneDrive for:

- Documents, screenshots, exports, and owner-only setup files.
- Optional owner-local encrypted backups of secrets.

Avoid OneDrive for:

- Active git working copies.
- Xcode projects while building.
- `DerivedData`, Docker volumes, dependency caches, or generated build output.

If owner-local secrets need to be available on multiple machines, prefer a
password manager or a separate OneDrive secrets folder outside the active git
clone. If `secrets/` exists inside a clone, keep it ignored and owner-only.

## App Store Connect API Key Flow

Owner action:

1. Request App Store Connect API access.
2. Generate a team key named `Kithra CI Upload`.
3. Use the least powerful role that supports the workflow. `Developer` can be
   enough for upload-only automation; use `App Manager` when automation also
   needs to manage app/version/TestFlight metadata or choose builds.
4. Download the `.p8` once.
5. Store the `.p8` at
   `secrets/app-store-connect/AuthKey_<KEY_ID>.p8` in the local working copy.
6. Add CI secrets only after the upload workflow exists.

Apple team API keys apply across the App Store Connect team, not just one app,
and the key name/access level cannot be edited after generation. If the scope is
wrong, revoke it and generate a replacement.

Expected secret names:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_P8_BASE64`
- `APPLE_TEAM_ID`
- `IOS_BUNDLE_ID`

`IOS_BUNDLE_ID` can also be a non-secret CI variable with value
`com.joaquimpacer.speakeasy`.

## What Agents Can Do Without More Owner Access

Agents can usually run for a long stretch when the task only needs repo-local
work:

- Implement server and iOS code.
- Add or update docs.
- Add tests.
- Build Docker/local relay workflows.
- Create GitHub Actions workflow files that do not consume secrets yet.
- Draft privacy policy, support content, TestFlight notes, and App Review
  answers.
- Prepare scripts that reference secret names without containing secret values.

## What Still Requires Owner Action

An owner still needs to handle:

- Apple Account sign-in, payment, agreements, and 2FA.
- Creating or downloading Apple private keys, certificates, and provisioning
  material.
- Adding CI secrets in GitHub Actions or Xcode Cloud.
- Domain registrar and DNS account access.
- Cloudflare, tunnel, VPS, or payment account setup.
- Final App Store submission choices and legal confirmations.

After owner action, record only non-secret status in `docs/OWNER_SETUP.md`.

## Long-Running Work Readiness

Before leaving an agent to work independently for hours, make sure these are
true:

1. The target task is written in `docs/BUILD_PLAN.md`, an issue, or the chat.
2. Required account setup is complete or explicitly out of scope.
3. Any needed secrets are already in GitHub Actions, Xcode Cloud, ignored
   `secrets/`, a password manager, or a deployment host, referenced by name
   only.
4. The agent can verify progress with local commands, simulator builds, tests,
   or CI.
5. The success criteria are specific enough to tell done from not done.

Good long-run prompt:

```text
Read AGENTS.md, CLAUDE.md, docs/BUILD_PLAN.md, docs/WORKFLOW.md,
docs/OWNER_SETUP.md, and git status. Continue the next unchecked implementation
task. Do not ask for secrets in chat. Use existing secret names only, preserve
the documented security constraints, run verification, and report blockers.
```

## Fast Track To Unattended Work

The shortest path to useful unattended work is:

1. Keep APNs deferred until the local send/receive flow works.
2. Get local verification working: Go toolchain or Docker-based Go test/build,
   Docker Compose config, and a repeatable relay start command.
3. Choose CI provider. Default is GitHub Actions for secret-free server checks
   and unsigned iOS simulator checks; use Xcode Cloud later for TestFlight if it
   reduces signing friction.
4. Add CI secrets only when a workflow consumes them. Do not block local
   implementation on CI upload secrets.
5. Build the local vertical slice from `docs/BUILD_PLAN.md`: register, invite,
   record, compress, encrypt, upload, download, verify, local-cache
   acknowledge, relay-delete.
6. After the local vertical slice works, set up beta relay hosting and then APNs.

Current practical blockers to long unattended implementation:

- Go is needed for direct Windows server tests unless tests run through Docker.
- Xcode/macOS is needed for real iOS build/simulator verification.
- Docker must be able to build images and run Compose without local config
  permission errors.
- GitHub/Xcode CI secrets are needed only after upload/signing workflows exist.
