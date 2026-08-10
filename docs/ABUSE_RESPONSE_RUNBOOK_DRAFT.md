# Kithra Abuse-Response Runbook — Owner-Approval Draft

> **Draft only.** This runbook is not an authorization for an agent to suspend
> users, disclose data, contact law enforcement, or send substantive responses.
> Joaquim must approve the operating process and designate any backup reviewer.

## Objectives

- Make every in-app and email report visible to the operator promptly.
- Confirm receipt without promising that an automated system has resolved the
  concern.
- Preserve Kithra's end-to-end-encryption boundary and collect only the minimum
  operational metadata needed to review abuse.
- Keep consequential safety, legal, disclosure, and account-enforcement
  decisions under human control.

## Intake Channels

- In-app metadata-only reports stored by the Kithra relay.
- `support@jqinnovation.com` for user support and additional voluntary context.
- `security@jqinnovation.com` for vulnerability reports.

The relay cannot decrypt reported video. A reporter may voluntarily provide a
screenshot or description by email, but Kithra must never request a private
encryption key or recovery secret.

## Automation That Is Safe To Add

- Send a neutral receipt acknowledgement for support and abuse email.
- Create a private ticket containing the report ID and minimum metadata.
- Notify Joaquim on his phone and send a daily unresolved-report digest.
- Deduplicate repeated reports and suggest a priority for human review.
- Escalate an unanswered alert to a separately authorized backup reviewer.

Example neutral acknowledgement:

> We received your Kithra report. This automated message confirms receipt only;
> a human has not yet reviewed or resolved it. If anyone is in immediate danger,
> contact local emergency services. Do not send private encryption keys.

## Actions Requiring An Authorized Human

- Send a substantive response or make a public commitment.
- Restrict, suspend, restore, or delete a relay account.
- Decide that conduct violates Kithra's community rules.
- Disclose account or network metadata.
- Contact law enforcement or make a legally required report.
- Change report retention or destroy report records.

## Coverage And Public Wording

An auto-reply is not human review. If Joaquim may be unreachable for several
days, reliable coverage requires an expressly authorized backup reviewer with
access limited to the private abuse queue. Until that exists and is tested,
Kithra should say that reports are prioritized and reviewed as promptly as
practical, without publishing a fixed 24-hour or three-business-day promise.

## Release Readiness Checklist

- [ ] Confirm `support@jqinnovation.com` and `security@jqinnovation.com` receive
      mail on Joaquim's phone.
- [ ] Configure and test a neutral auto-acknowledgement without mail loops.
- [ ] Add a private alert or digest for in-app report records; reports must not
      remain visible only through a manual SQLite query.
- [ ] Decide whether a backup human reviewer will be authorized.
- [ ] Test report intake, acknowledgement, alerting, review notes, blocking, and
      appeal handling with synthetic non-sensitive data.
- [ ] Approve public community rules and App Review notes.
