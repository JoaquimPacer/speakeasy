# Speakeasy CI

Speakeasy CI starts with checks that can run without repository secrets. Release
automation, App Store Connect uploads, APNs validation, and TestFlight delivery
must wait until the owner setup checklist has non-secret status entries and the
real secrets are stored in GitHub Actions or Xcode Cloud.

## Current Workflow

`.github/workflows/server-ci.yml` runs on pull requests and pushes to `main`
when server, Compose, or workflow files change. It also supports manual
`workflow_dispatch` runs.

The workflow is intentionally safe for the current repository state:

- If `server/go.mod` does not exist, Go formatting, tests, and vet are skipped.
- If no Compose file exists, Docker Compose validation is skipped.
- If `server/Dockerfile` does not exist, image build is skipped.
- No secrets are referenced.
- The workflow uses `pull_request`, not `pull_request_target`.
- Permissions are read-only with `contents: read`.

When the server scaffold lands, the same workflow will start running:

- `gofmt -l .`
- `go test ./...`
- `go vet ./...`
- `docker compose config`
- `docker build -t speakeasy-server:ci server`

## Server CI Expansion

Add server checks in small steps as implementation lands:

1. Keep unit tests secret-free.
2. Add SQLite migration tests with temporary local files only.
3. Add API handler tests using in-process HTTP servers.
4. Add storage tests against local filesystem fixtures.
5. Add integration tests only when they can run without APNs, S3, Cloudflare,
   or external network credentials.

Do not add required CI secrets for basic pull request validation. A contributor
PR should be able to prove server correctness without access to owner accounts.

## iOS CI Options

There is no iOS workflow yet because the native app scaffold, bundle ID, and
Apple Developer setup are not complete. The first iOS CI step should be an
unsigned simulator build/test job.

### GitHub Actions macOS

Use this when the `ios/` project exists and PR validation should stay in GitHub.
The first job should run on `macos-latest` or a pinned macOS image and use
simulator builds with code signing disabled:

```bash
xcodebuild test \
  -project ios/Speakeasy.xcodeproj \
  -scheme Speakeasy \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

Benefits:

- PR checks live beside server checks.
- Unsigned simulator tests do not need Apple secrets.
- GitHub branch protection can require one common CI surface.

Costs:

- macOS minutes are slower and scarcer than Linux minutes.
- Signing and TestFlight upload require careful secret handling later.
- Xcode image changes can break builds unless the image is pinned.

### Xcode Cloud

Use this when App Store Connect is configured and Apple-managed signing is more
valuable than keeping all CI in GitHub.

Benefits:

- Native App Store Connect and TestFlight integration.
- Apple-managed signing is less error-prone than exporting certificates into
  GitHub Actions.
- Good fit for beta distribution once the app record and bundle ID exist.

Costs:

- Separate CI surface from server checks.
- Requires Apple Developer and App Store Connect setup first.
- Less useful for external contributors who only see GitHub PR checks.

### Recommendation

Start with GitHub Actions for secret-free server checks and unsigned simulator
tests. Re-evaluate Xcode Cloud for TestFlight once the owner has completed the
Apple Developer, bundle ID, and App Store Connect checklist items in
`docs/OWNER_SETUP.md`.

## Future Secrets

Do not add these until a workflow actually consumes them:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_P8_BASE64`
- `APPLE_TEAM_ID`
- `IOS_BUNDLE_ID`
- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_KEY_P8_BASE64`
- `APNS_BUNDLE_ID`

Use GitHub Environments for deployment or release jobs so manual approval can
gate access to production-like secrets.

## Required Safety Rules

- Never commit provisioning profiles, `.p8` files, certificates, private keys,
  tunnel credentials, or `.env.local` files.
- Never print secrets in CI logs.
- Never run deployment jobs from `pull_request` events.
- Never use `pull_request_target` for code that builds or executes contributor
  changes.
- Keep beta and production deployment jobs manual until the deployment path is
  proven repeatable.
