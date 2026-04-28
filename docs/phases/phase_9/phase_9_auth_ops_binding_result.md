# Phase 9 Auth Ops Binding Result

Status: STAGING LIVE PASSED.
Generated: 2026-04-28.

## Scope

Staging-only production auth-ops binding. No Production1 mutation.

## Current Repo-State Note

The local workspace now contains the auth-op/password/MFA route contracts,
repository gateway implementations, app-side proxy clients, and production
bootstrap binding reconciliation. `tool/advisor_proxy/main.dart` installs the
Phase 9 route binding bundle into `routeRequest`: auth-session ledger,
permission-snapshot resolver, admin permission guard, auth-operations gateway,
password-change gateway, and MFA/recovery gateway. The later live-closeout
pass replaced the MFA scaffold with the Identity Toolkit REST adapter; staging
TOTP begin/confirm and recovery-code consume now pass with disposable-user
cleanup.

## Shipped

- Proxy boot now binds `RepositoryAuthOperationsGateway` with:
  - Firebase Admin Identity Toolkit client.
  - Postgres repositories for `users`, `roles`, `user_roles`,
    `auth_invites`, and `auth_events_audit`.
  - Tenant Postgres pool for permission reads.
  - Admin Postgres pool for audited auth-operation writes.
- Proxy boot now also binds `RepositoryPasswordChangeGateway` for signed-in
  password changes through Firebase current-password verification, policy /
  HIBP / history checks, Firebase password update, password-history write, and
  audit rows.
- Proxy boot now binds the production permission-snapshot resolver/guard so
  live Settings users can see Team actions from server-resolved permissions.
- Flutter runtime now installs `ProxyPermissionContextLoader` when
  `FORGE_FLOW_PROXY_BASE_URI` is configured, so Settings -> Team is driven by
  the live permission snapshot instead of test-only injection.
- Added `FIREBASE_WEB_API_KEY` config plumbing for Firebase Admin password
  reset / create-user flows. The deploy script derives it from
  `android/app/src/forgeflow/google-services.json` when local env omits it.
- Follow-up local contract check on 2026-04-28 fixed the staging deploy helper
  so future proxy deploys require and write `FIREBASE_WEB_API_KEY` instead of
  relying on a manually preserved Cloud Run env value.
- Fixed the Firebase Admin disable-user call to send the Identity Toolkit
  `disableUser` field, so soft-delete/suspend cleanup disables the Firebase
  account instead of only updating Postgres.
- Added migration
  `db/migrations/202604280012_phase_9_auth_ops_cloud_foundation_grants.sql`
  so audited `forge_admin` auth-ops can write `users`, while tenant runtime
  keeps only the narrow `users` SELECT/UPDATE grant and read-only access to
  operator/location/admin identity rows.

## Live Staging Verification

- Deployed Cloud Run revision:
  `forge-flow-staging-proxy-00010-dgd`.
- Public readiness:
  `GET /readyz` returned 200.
- Startup diagnostics report:
  `firebase_verifier: firebase`, `auth_session_ledger: postgres`,
  `auth_operations: postgres`, `permission_snapshot: postgres`.
- Applied the auth-ops cloud-foundation grant migration on staging only.
- Cleared staging-only Firebase orphan state for `ukhan@mun.ca` from the
  earlier failed retries before the clean invite run.
- Live permission snapshot for admin actor `saidumarkhan005@gmail.com`
  returned 200 with `team.users.view=allow` and `team.users.invite=allow`.
- Live invite smoke for `ukhan@mun.ca` returned 201 through
  `/v1/admin/auth/invites`.
- Postgres verification for `ukhan@mun.ca`:
  `users=1`, `auth_invites=1`, `user_roles=1`, `auth_events_audit=1`.
- Row detail:
  `status=invited`, `roles_version=1`, `role_key=operator_staff`,
  `scope_type=location`, location scoped, invite active and unexpired.
- Firebase verification:
  exactly one Firebase user exists for `ukhan@mun.ca`, with uid present and
  custom attributes present.
- Cloud Run logs show the final invite request as `POST 201`.
- Follow-up closeout deployed corrected Cloud Run revision
  `forge-flow-staging-proxy-00013-zx8`; `GET /readyz` returned 200.
- Password-change live smoke passed on the corrected revision for a disposable
  staging user: new-password Firebase sign-in worked, `password_set_at=true`,
  `password_history_count=1`, `auth.password_changed` audit count `1`, and
  cleanup soft-delete left Firebase `disabled=true`.
- Remaining auth-ops live smokes passed on the corrected revision using the
  disposable staging target `92e0e6de-0816-492d-937b-94fd6ba6f39a` and invite
  `2aae3565-a983-4110-be70-f5c2a0db5a93`: revoke invite,
  suspend/reactivate, admin reset, role grant/revoke, and soft-delete all
  returned success.
- Postgres after the corrected auth-ops smoke showed invite revoked, user
  status `deleted`, `soft_deleted=true`, `roles_version=5`, expected lifecycle
  and role audit counts, and the latest role grant revoked.
- Firebase lookup after corrected soft-delete showed the disposable target
  `disabled=true`.
- Corrected-deploy fresh invite-create retry passed on revision
  `forge-flow-staging-proxy-00013-zx8` for
  `ff-invite-retry-20260428165929@forgeflow.dev`: proxy returned 201,
  Postgres showed the expected invited user, invite, role grant, and
  `auth.invite_created` audit row, Firebase lookup found the target user, and
  Cloud Run logs show `POST 201` at `2026-04-28T16:59:28.383698Z`.

## Verification

- `dart analyze` over auth/proxy/bootstrap/Settings/touched tests:
  no issues found.
- Password-change focused checks:
  `flutter test test/proxy_password_change_gateway_test.dart
  test/advisor_proxy_bootstrap_test.dart`,
  `flutter test test/advisor_proxy_test.dart --plain-name
  "POST /v1/auth/password/change"`, and
  `flutter test test/settings_screen_widget_test.dart --plain-name
  "account change password submits through gateway"` passed.
- Focused pressure suite:
  `flutter test test/advisor_proxy_bootstrap_test.dart
  test/advisor_proxy_test.dart test/proxy_auth_operations_gateway_test.dart
  test/proxy_permission_snapshot_loader_test.dart
  test/operator_scoped_repository_test.dart test/auth_live_binding_test.dart
  test/settings_screen_widget_test.dart test/role_admin_live_binding_test.dart
  test/user_lifecycle_live_binding_test.dart`
  -> 305/305 passed.

## Recipient Acceptance Closeout

Invite acceptance / first-password completion is now live-smoked on staging
with `newoundlandlimited@gmail.com`: email delivered, first password set,
login/persistence/logout completed, invite accepted, user activated, and all
recipient auth-session rows revoked after logout.

## Remaining

- MFA enroll/challenge and recovery-code consume local proxy endpoints are now
  in repo; the Identity Toolkit MFA adapter is deployed on staging, and TOTP
  begin/confirm plus recovery-code consume pass with disposable-user cleanup.
- Cloud Armor/reCAPTCHA staging edge setup is provisioned in preview/smoke
  form; DNS/certificate and preview-log review remain.
- iOS/macOS verification remains pending on the GitHub macOS runner.
- Production1 remains locked until explicit approval.
