# Phase 9 Corrected-Deploy Invite Create Retry Result

Status: PASSED.
Generated: 2026-04-28.

## Scope

Staging-only retry of fresh Team invite creation on the corrected Cloud Run
deploy. No Production1 mutation.

No secrets, passwords, API keys, connection strings, bearer tokens, token
hashes, or Firebase credential values are recorded here.

## Result

- Initial password sign-in with the previous local smoke credential failed
  before any invite mutation with Firebase `INVALID_LOGIN_CREDENTIALS`. Later
  maintenance on 2026-04-28 reset/reconfirmed the dedicated smoke user's
  password, updated the non-repo secrets loader, and verified password sign-in
  plus deployed proxy permission snapshot.
- The retry then used a short-lived service-account custom-token sign-in for
  the documented staging admin actor after confirming that actor exists in
  Postgres, exists in Firebase, is active, and has `team.users.invite`.
- Permission snapshot through the deployed proxy returned 200 with
  `team.users.invite=allow`.
- `POST /v1/admin/auth/invites` returned 201 on Cloud Run revision
  `forge-flow-staging-proxy-00013-zx8`.
- Staging target email:
  `ff-invite-retry-20260428165929@forgeflow.dev`.
- Invite ID returned:
  `7d349a53-4537-4d84-ac1f-4d58ab9bba64`.
- Invite expiry returned:
  `2026-05-05T16:59:29.760838Z`.

## Verification

- Postgres verification for the target email:
  `users=1`, `auth_invites=1`, `user_roles=1`,
  `auth.invite_created audit=1`.
- Row detail:
  `status=invited`, `roles_version=1`, `role_key=operator_staff`,
  invite active and unexpired, and location scoped.
- Firebase Identity Toolkit admin lookup found exactly one target user.
- Cloud Run logs show the invite request as `POST 201` at
  `2026-04-28T16:59:28.383698Z` on revision
  `forge-flow-staging-proxy-00013-zx8`, latency `5.882247510s`.
- Focused local contract checks after the live retry:
  `dart analyze lib/services/auth/auth_operations_gateway.dart lib/services/auth/proxy_auth_operations_gateway.dart lib/services/auth/repository_auth_operations_gateway.dart lib/services/auth/firebase_admin_auth_client.dart tool/advisor_proxy/advisor_proxy.dart test/proxy_auth_operations_gateway_test.dart test/proxy_auth_operations_route_test.dart`
  reported no issues, and
  `flutter test test/proxy_auth_operations_gateway_test.dart test/proxy_auth_operations_route_test.dart`
  passed 12/12.

## Remaining

- Cloud Armor/reCAPTCHA staging edge setup is provisioned in preview/smoke
  form; DNS/certificate and preview-log review remain.
- Identity Toolkit MFA binding is deployed on
  `forge-flow-staging-proxy-00017-pcz`; proxy TOTP begin/confirm and
  recovery-code consume passed with disposable-user cleanup.
- iOS/macOS verification remains pending on the GitHub macOS runner.
- Production1 remains locked until explicit approval.
