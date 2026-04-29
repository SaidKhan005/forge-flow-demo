# Phase 9 Auth Ops Proxy Contract Result

Status: FRAMEWORK PASSED.
Generated: 2026-04-28.

## Scope

Local/framework slice only. No live Firebase Admin calls, no Postgres writes,
no Cloud Armor/reCAPTCHA dashboard mutation, no Production1 mutation.

## Shipped

- Proxy route contract for Team/user-management auth operations:
  invite create/revoke, suspend/reactivate, soft-delete, admin password-reset,
  and role-grant create/revoke.
- Every route verifies the Firebase bearer token first, runs
  `ProxyAdminPermissionGuard`, validates a narrow JSON body, and delegates to
  `AuthOperationsGateway`.
- Flutter app-side `ProxyAuthOperationsGateway` client for the same route
  contract. The app sends a bearer token and idempotency key; it never receives
  Firebase Admin credentials or Postgres credentials.
- Runtime binding now exposes the auth-ops gateway whenever
  `FORGE_FLOW_PROXY_BASE_URI` is configured.
- Settings -> Team can submit the first invite action through
  `AuthOperationsGateway` once a `PermissionContext` snapshot is installed.
- Sign-out ledger calls now pass the stored session token to the proxy before
  Firebase local sign-out, avoiding `no_id_token` during logout.

## UX Notes

- Forgot password remains low friction and account-safe.
- Login stays persistent and does not force password reset.
- MFA remains admin-role-focused; this slice does not add broad tier-based MFA.
- Team invite failure surfaces a short retry message instead of crashing the
  Settings surface.

## Superseded Follow-Up

The production auth-ops binding and live permission-snapshot bridge landed in
the next slice on 2026-04-28. See
`docs/archive/phases/phase_9/phase_9_auth_ops_binding_result.md`.

## Remaining

- Invite acceptance and password-change orchestration have since been
  live-smoked on staging; see the Phase 9 auth-ops binding and password-change
  result docs.
- MFA enroll/challenge and recovery-code consume local proxy endpoints are now
  in repo; the later Identity Toolkit MFA adapter is deployed on staging, and
  TOTP begin/confirm plus recovery-code consume pass with disposable-user
  cleanup.
- Cloud Armor/reCAPTCHA staging edge setup is provisioned in preview/smoke
  form; DNS/certificate, preview-log review, and iOS/macOS GitHub runner
  verification remain.

## Verification

- `dart analyze` over touched auth, proxy, Settings, and tests: no issues.
- Focused Flutter sweep:
  `flutter test test/proxy_auth_operations_gateway_test.dart test/proxy_auth_session_ledger_writer_test.dart test/auth_live_binding_test.dart test/settings_screen_widget_test.dart test/advisor_proxy_test.dart`
  -> 233/233 passed.
- `git diff --check` clean.
