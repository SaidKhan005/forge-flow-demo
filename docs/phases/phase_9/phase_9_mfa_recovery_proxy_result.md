# Phase 9 MFA / Recovery Proxy Result

Status: LOCAL CODE PASSED; STAGING MFA/RECOVERY DEPLOY SMOKE PASSED.
Generated: 2026-04-28.

## Scope

Local proxy and app-side route foundation for MFA enrollment and recovery-code
consume, followed by staging-only disposable-user smoke. No Production1 live
mutation was performed.

## Shipped

- Added proxy routes for:
  - `POST /v1/auth/mfa/totp/begin`
  - `POST /v1/auth/mfa/totp/confirm`
  - `POST /v1/auth/mfa/recovery/consume`
- Added `RepositoryMfaOperationsGateway` to compose MFA enrollment output,
  `mfa_factors` persistence, recovery-code consumption, and
  `auth_events_audit` rows.
- Added `MfaFactorsRepository.insertTotpEnrollment` so the TOTP factor and
  all hashed recovery-code rows persist inside one tenant transaction.
- Added durable `recovery_code_attempts` storage plus
  `PostgresRecoveryCodeAttemptStore` behind the existing attempt limiter.
- Added app-side `ProxyMfaOperationsGateway` and runtime binding when
  `FORGE_FLOW_PROXY_BASE_URI` is configured.
- Re-installed the proxy bootstrap binding so `tool/advisor_proxy/main.dart`
  now passes `RepositoryMfaOperationsGateway` into `routeRequest`.
- Replaced the production proxy's scaffold-failing MFA client with
  `IdentityToolkitFirebaseMfaClient`, a Cloud Run-safe Identity Toolkit REST
  adapter for TOTP begin/finalize/withdraw and factor lookup. The adapter
  receives the already verified request ID token from the proxy route, uses
  the project API key contract verified against staging, and keeps token values
  out of logs/responses.

## Verification

- `dart format` over touched MFA/proxy/test files completed.
- `dart analyze` over touched MFA/proxy/runtime/test files: no issues found.
- `flutter test test/identity_toolkit_firebase_mfa_client_test.dart` passed.
- `flutter test test/proxy_auth_operations_route_test.dart` passed.
- `flutter test test/mfa_operations_gateway_test.dart` passed.
- `flutter test test/proxy_mfa_operations_gateway_test.dart` passed.
- `flutter test test/recovery_code_attempt_store_test.dart` passed.
- Combined auth/MFA/service-principal focused suite passed 35/35.
- Focused post-adapter suite passed 40/40:
  `test/identity_toolkit_firebase_mfa_client_test.dart`,
  `test/mfa_live_binding_test.dart`, `test/mfa_operations_gateway_test.dart`,
  `test/proxy_auth_operations_route_test.dart`,
  `test/proxy_mfa_operations_gateway_test.dart`, and
  `test/advisor_proxy_bootstrap_test.dart`.
- Live provider smoke passed directly against staging with cleanup:
  Identity Toolkit TOTP start, finalize, lookup, and withdraw completed without
  printing token/secret/code values.
- Staging deploy smoke passed on `forge-flow-staging-proxy-00016-g57` for
  password sign-in, proxy permission snapshot, and MFA TOTP begin response
  shape.
- Staging disposable-user deploy smoke passed on
  `forge-flow-staging-proxy-00017-pcz` for proxy TOTP begin, TOTP confirm,
  recovery-code consume, durable `recovery_code_attempts` ledger verification,
  Firebase cleanup, and Postgres cleanup. No token, secret, TOTP,
  recovery-code, or password value was printed.
- `dart run tool/rls_policy_lint.dart` scanned 21 migration files and reported
  clean.
- Final local closeout gates after the staging repairs and tracker updates:
  `dart run tool/rls_policy_lint.dart` clean,
  `flutter analyze --fatal-infos` clean, focused auth/MFA/edge tests passed
  41/41, `test/ios_platform_contract_test.dart` passed 2/2, and full
  `flutter test` passed 2324/2324.

## Remaining

- Final analyzer/test sweep is green after the live staging repairs and tracker
  updates.
- Cloud Armor/reCAPTCHA staging edge is provisioned in preview/smoke form;
  DNS/certificate and preview-log review remain.
- Production1 remains locked until explicit approval.
