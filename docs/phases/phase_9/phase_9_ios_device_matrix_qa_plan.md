# Phase 9 iOS Device Matrix QA Plan

Updated: 2026-04-29.

Purpose: park the remaining human-gated iOS device-matrix item until the user
returns with an Apple device/signing lane, without disturbing the GitHub Apple
verification lane that already passed for macOS host tests and
ForgeFlow/Barrio iOS simulator builds.

## Current Automated Gate

- Workflow: `.github/workflows/apple-platform-verify.yml`.
- Passed evidence: GitHub Apple run `25087331405` on `master`.
- Coverage:
  - macOS host/toolchain tests.
  - Focused auth + MFA tests.
  - ForgeFlow iOS simulator debug build.
  - Barrio iOS simulator debug build.
- iOS floor: `15.0` per `ios/Podfile`.

## 2026-04-29 Session Status

- Local GitHub CLI is authenticated for workflow dispatch/status checks.
- Last recorded automated evidence is GitHub Apple run `25087331405` on
  `master`, passing macOS host tests and both iOS simulator flavor builds.
- Phase 9 is accepted for next-phase handoff; physical iOS QA is explicitly
  deferred by the user and will be resumed later.
- Physical-device execution was not possible from this workspace because it
  requires Apple signing access, a connected/developer-enabled iPhone, and
  staging smoke credentials outside the repo.
- Backlog state: automated lane exists; physical ForgeFlow/Barrio device matrix
  remains human/device-gated and should be run on the exact commit being signed.

## Human Prerequisites

- Apple developer account / signing access for device install.
- At least one physical iPhone that can run the app at the iOS 15.0 floor or
  newer.
- Dedicated staging smoke user credentials loaded outside the repo.
- Staging proxy URL and Firebase auth config for the same commit that passed
  the Apple workflow.
- Human approval before any live staging auth mutation beyond disposable smoke
  users.

## Physical Device Matrix

Minimum launch-blocking matrix:

| Device lane | Flavor | Required checks |
| --- | --- | --- |
| Oldest available supported iPhone | ForgeFlow | Install, first launch, email/password sign-in, secure-session restore after app restart, sign out |
| Current primary iPhone | ForgeFlow | Sign-in, TOTP challenge/enrollment path if account requires MFA, recovery-code consume smoke with disposable account |
| Current primary iPhone | Barrio | Install, first launch, email/password sign-in, secure-session restore after app restart, sign out |

Optional, if available before launch:

| Device lane | Flavor | Required checks |
| --- | --- | --- |
| Large-screen iPhone | ForgeFlow | Layout sanity for auth and Settings -> Team entry path |
| iPad | ForgeFlow or Barrio | Basic launch/sign-in only; not launch-blocking unless iPad support becomes a product requirement |

## Execution Rules

- Run the Apple workflow on the exact commit being tested before physical QA.
- Use staging only.
- Use disposable or dedicated smoke users; do not use operator production data.
- Do not paste credentials, tokens, Firebase values, device identifiers, or
  recovery-code plaintext into docs.
- Record device lane, flavor, commit SHA, workflow run, pass/fail, and blocker
  summary only.

## Sign-Off Criteria

- [ ] Apple workflow green on the tested commit.
- [ ] ForgeFlow passes the minimum physical iPhone checks.
- [ ] Barrio passes the minimum physical iPhone checks.
- [ ] Secure-session restore works after force-close/reopen.
- [ ] MFA/recovery-code smoke uses disposable staging identity and cleanup is
      confirmed.
- [ ] Any physical-device blocker is captured as a B-item before 9.10 UX work
      proceeds.
