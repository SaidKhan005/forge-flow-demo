# Phase 9 Password Change Orchestration Result

Status: STAGING LIVE PASSED.
Generated: 2026-04-28.

## Scope

Signed-in password-change orchestration for staging closeout. No Production1
mutation.

## Current Repo-State Note

The local workspace contains the password-change route contract, repository
gateway, app-side proxy client, and production bootstrap binding
reconciliation. `tool/advisor_proxy/main.dart` now installs the
`RepositoryPasswordChangeGateway` through the Phase 9 route binding bundle, so
the next deploy entrypoint matches this staging evidence.

## Shipped

- Added self-service proxy route `POST /v1/auth/password/change`.
- Added Flutter `PasswordChangeGateway` plus app-side proxy client.
- Added Settings -> Account -> Change password dialog for authenticated users.
- Added proxy production binding through `RepositoryPasswordChangeGateway`.
- Password-change choreography now:
  - verifies the current Firebase password through Identity Toolkit,
  - evaluates NIST password policy,
  - screens with HIBP k-anonymity through the rate-limited fetcher,
  - checks last-5 password history through Postgres,
  - updates Firebase password server-side,
  - records/prunes `password_history`,
  - updates `users.password_set_at`,
  - writes `auth.password_changed` audit,
  - writes `auth.hibp_unavailable` audit when HIBP fails open.

## Verification

- `dart analyze` over touched auth/proxy/bootstrap/Settings/tests: no issues.
- `flutter analyze --fatal-infos`: no issues.
- Focused tests passed:
  - `flutter test test/proxy_password_change_gateway_test.dart test/advisor_proxy_bootstrap_test.dart`
  - `flutter test test/advisor_proxy_test.dart --plain-name "POST /v1/auth/password/change"`
  - `flutter test test/settings_screen_widget_test.dart --plain-name "account change password submits through gateway"`

## Live Status

Live-smoked on staging through deployed Cloud Run revision
`forge-flow-staging-proxy-00013-zx8` using a disposable staging user. The smoke
set a known current password through Firebase Admin setup, changed it through
`POST /v1/auth/password/change`, then verified Firebase email/password sign-in
with the new password.

Evidence:

- `password_change_ok=true`.
- `hibp_unavailable=false`.
- New-password Firebase sign-in returned the disposable target UID.
- Postgres showed `password_set_at=true`.
- Postgres showed `password_history_count=1`.
- Postgres showed `auth.password_changed` audit count `1`.
- Cleanup soft-delete succeeded and Firebase lookup showed `disabled=true`.

## Remaining

- MFA enroll/challenge and recovery-code consume local proxy endpoints are now
  in repo; the Identity Toolkit MFA adapter is deployed on staging, and TOTP
  begin/confirm plus recovery-code consume pass with disposable-user cleanup.
- Corrected-deploy fresh invite-create retry passed on
  `forge-flow-staging-proxy-00013-zx8`; the auth-ops invite lane has no
  remaining amber.
- Cloud Armor/reCAPTCHA staging edge setup is provisioned in preview/smoke form;
  DNS/certificate and preview-log review remain.
- iOS/macOS verification remains human-gated.
- Production1 remains locked until explicit approval.
