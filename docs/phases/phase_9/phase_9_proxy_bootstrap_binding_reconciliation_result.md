# Phase 9 Proxy Bootstrap Binding Reconciliation Result

Status: LOCAL CODE PASSED; CORRECTED DEPLOY AUTH-OPS SMOKED.
Generated: 2026-04-28.

## Scope

Local proxy production-entrypoint reconciliation for Phase 9 auth routes. No
staging or Production1 live mutation was performed in this slice.

## Shipped

- Added `FIREBASE_WEB_API_KEY` to required proxy server-side config so
  Identity Toolkit create-user, password verification, and reset flows have the
  API key available at boot.
- Patched the staging deploy helper and unified secrets loader to derive,
  require, name-report, and write `FIREBASE_WEB_API_KEY` consistently with the
  proxy config contract.
- Added `ProxyProductionBindings` in `tool/advisor_proxy/proxy_bootstrap.dart`
  to assemble the Phase 9 production route bundle:
  auth-session ledger, permission-snapshot resolver, admin permission guard,
  auth-operations gateway, password-change gateway, and MFA/recovery gateway.
- Wired `tool/advisor_proxy/main.dart` to pass all production bindings into
  `routeRequest`.
- Added repository-backed proxy permission snapshot and admin permission guard
  implementations for live permission evaluation.
- Required `FIREBASE_PROJECT_ID` before constructing production route bindings,
  so the proxy exits before creating database pools when Firebase runtime
  config is incomplete.

## Verification

- `dart analyze tool/advisor_proxy/main.dart tool/advisor_proxy/proxy_bootstrap.dart tool/advisor_proxy/advisor_proxy.dart test/advisor_proxy_bootstrap_test.dart test/advisor_proxy_test.dart`
  reported no issues.
- `flutter test test/advisor_proxy_bootstrap_test.dart` passed 3/3.
- `flutter test test/advisor_proxy_test.dart` passed 133/133.
- Focused Phase 9 route/gateway suite passed 35/35:
  `test/proxy_auth_operations_gateway_test.dart`,
  `test/proxy_password_change_gateway_test.dart`,
  `test/proxy_permission_snapshot_loader_test.dart`,
  `test/proxy_auth_operations_route_test.dart`,
  `test/proxy_mfa_operations_gateway_test.dart`,
  `test/mfa_operations_gateway_test.dart`,
  `test/recovery_code_attempt_store_test.dart`, and
  `test/phase_9_0sigma_d_service_principals_test.dart`.
- `dart run tool/rls_policy_lint.dart` scanned 21 migration files and reported
  clean.
- `git diff --check` reported only existing CRLF normalization warnings.
- `flutter test test/deploy_staging_proxy_contract_test.dart` passed 4/4.
- PowerShell parse checks passed for `scripts/deploy_staging_proxy.ps1` and
  `scripts/use_forge_flow_secrets.ps1`.

## Remaining

- Corrected-deploy fresh invite creation passed on staging revision
  `forge-flow-staging-proxy-00013-zx8`; see
  `phase_9_corrected_deploy_invite_create_retry_result.md`.
- The scaffold-failing Firebase MFA client has been replaced with the Identity
  Toolkit REST adapter and deployed on
  `forge-flow-staging-proxy-00017-pcz`; staging TOTP begin/confirm and
  recovery-code consume passed with disposable-user cleanup.
- Cloud Armor/reCAPTCHA staging edge setup is provisioned in preview/smoke
  form; DNS/certificate and preview-log review remain.
- Production1 remains locked until explicit approval.
