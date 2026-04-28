# Phase 9 In-App Auth Smoke Result

Status: PASSED.
Generated: 2026-04-28.

## Scope

Manual staging smoke for the Forge & Flow operator app using the account named
by `FIREBASE_AUTH_SMOKE_EMAIL` from the non-repo secrets loader.

No secrets, passwords, tokens, database URLs, row IDs, or token hashes are
recorded here.

## Result

The operator drove the Android app through the full low-friction auth loop:

- Firebase email/password sign-in succeeded through the deployed staging proxy.
- The app reached the authenticated state with no forced password reset and no
  broad MFA prompt.
- The session persisted across app relaunch.
- Settings -> Data -> Account -> Sign out returned the app to signed-out state.
- Forgot-password reset email was exercised after the action-link fix and the
  reset completed successfully on staging. Identity Platform
  `notification.sendEmail.callbackUri` now matches the reachable staging
  handler so reset emails do not point at the future `admin.forgeflow.app`
  host.
- Postgres verification after sign-out showed no recent active staging sessions
  for the smoke user, recently revoked sessions present, and the current smoke
  session revoked with `user_signed_out_this_session`.

## Recipient Invite Acceptance Smoke

The operator then drove a staging invited-recipient flow for
`newoundlandlimited@gmail.com`:

- The Firebase reset / invite email delivered to Gmail.
- The recipient set a first password from the email action.
- Firebase login succeeded in the Android app for the invited user's UID.
- The session persisted across relaunch.
- Logout completed after persistence.
- Postgres verification showed the `users` row moved from `invited` to
  `active`, `password_set_at`, `last_login_at`, and `last_active_at` were set,
  the latest `auth_invites` row had `accepted_at` set and was not revoked, and
  all auth-session rows for the recipient were revoked with
  `user_signed_out_this_session`.

## Live Environment

- App: Forge & Flow Android debug build.
- Proxy: deployed staging Cloud Run proxy.
- Database: staging Azure PostgreSQL only.
- Firebase: staging project only.
- Production1: not touched.

## Fixes Landed During Smoke

- Firebase runtime initializes Flutter bindings before Firebase Core.
- Auth-required app entrypoint now starts behind `AuthGate`.
- Firebase custom claims use `postgres_user_id` because Firebase reserves
  `user_id`.
- Deployed proxy uses static Cloud Run egress allowed by Azure PostgreSQL.
- Login ledger writes use the exact interactive sign-in ID token, avoiding
  scope drift between sign-in and ledger recording.
- Settings exposes a simple authenticated Account -> Sign out row.
- Sign-out revokes the auth-session ledger row before local Firebase sign-out.
- Follow-up hardening: sign-out ledger calls pass the stored session ID token to
  the proxy so logout does not depend on Firebase `currentUser` still being
  available at the instant local sign-out begins.

## Verification

- Focused analyzer and test sweeps passed during the smoke-fix loop.
- Final logout verification used counts and booleans only:
  `recent_active_sessions = 0`, revoked sessions present, current smoke session
  sign-out observed.

## Remaining Work

In-app login / persistence / logout, forgot-password reset, and recipient
invite acceptance / first-password completion are no longer the next gate.
Remaining password-reset polish is deliverability and post-reset return
routing: reduce spam placement with sender-domain setup, then add a branded
reset-complete page with a clear return path to Forge & Flow.

2026-04-28 credential maintenance note: retrying Firebase password sign-in
with the previous non-repo `FIREBASE_AUTH_SMOKE_EMAIL` /
`FIREBASE_AUTH_SMOKE_PASSWORD` returned `INVALID_LOGIN_CREDENTIALS` before any
proxy mutation. The dedicated smoke user's password was reset/reconfirmed,
`$HOME/.forge_flow/forge_flow.secrets.ps1` was updated, and password sign-in
plus deployed proxy permission snapshot now pass.

Password-change orchestration is now deployed and live-smoked on staging, the
auth-ops revoke invite, suspend/reactivate, soft-delete, admin reset, and role
grant/revoke smokes have passed, and the corrected-deploy fresh invite-create
retry passed on revision `forge-flow-staging-proxy-00013-zx8`. Later
live-closeout work provisioned the staging Cloud Armor/reCAPTCHA edge in
preview/smoke form and passed disposable-user proxy MFA confirm plus
recovery-code deployment smokes on `forge-flow-staging-proxy-00017-pcz`. DNS,
certificate, HTTPS, Cloud Armor preview-log review, and GitHub Apple
verification are now closed for live-closeout. The final local analyzer/test
stability gates are green after the later staging repairs.
