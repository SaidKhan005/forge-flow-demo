# Phase 9 Maintenance Stability Sweep Result

Status: PASSED.
Generated: 2026-04-28.

## Scope

Maintenance-only stabilization before any new feature addition. No Production1
mutation.

User directive: hold the feature queue until this phase is stable. `9.0Σ.f-k`
and later feature additions remain paused while any maintenance regression,
smoke blocker, or live-closeout gate is open.

## Fixed

- Removed the last known local red test by updating
  `test/labor_model_boh_sales_test.dart` to pass explicit
  `historicalWeeklyAvgCovers` into the live preview notifier. This matches the
  current honest-demand contract: the notifier no longer invents default demand
  when no demand source is supplied.
- Fixed stale wrapper drift in
  `lib/services/auth/invited_user_activation_ledger_writer.dart` by removing
  the obsolete `authorizationIdToken` forwarding after the
  `AuthSessionLedgerWriter` seam narrowed.
- Reset/reconfirmed the dedicated staging smoke user's Firebase password,
  updated `$HOME/.forge_flow/forge_flow.secrets.ps1`, and verified password
  sign-in plus deployed proxy permission snapshot. No secret values were
  recorded.
- Cleared `docs/KNOWN_FAILING_TESTS.md`; there are no open known-failing tests
  after this sweep.
- Later live-closeout maintenance moved staging proxy sensitive runtime config
  to Secret Manager-backed env refs, added a narrow
  `auth_events_audit.actor_kind` live repair migration, and verified the
  disposable-user MFA/recovery smoke and cleanup path on staging.

## Verification

- `flutter analyze --fatal-infos`: no issues.
- `flutter test`: 2323/2323 passed.
- `dart run tool/rls_policy_lint.dart`: clean.
- Focused post-doc check:
  `flutter test test/labor_model_boh_sales_test.dart test/proxy_auth_operations_gateway_test.dart test/proxy_auth_operations_route_test.dart test/advisor_proxy_bootstrap_test.dart`
  passed 23/23.
- `git diff --check`: only CRLF normalization warnings.
- Staging auth-smoke password path:
  password sign-in succeeded, deployed proxy permission snapshot returned 80
  permissions, `team.users.view=allow`, and `team.users.invite=allow`.
- Final post-live-closeout refresh:
  `dart run tool/rls_policy_lint.dart` clean,
  `flutter analyze --fatal-infos` clean, focused auth/MFA/edge tests passed
  41/41, GitHub Apple verification passed after the iOS 15 floor fix, full
  `flutter test` passed 2324/2324, and `git diff --check` reported only CRLF
  normalization warnings.

## Remaining Human-Gated Work

- DNS/certificate propagation and HTTPS smoke for `staging-api.feflow.org`
  passed after staging Cloud Armor/reCAPTCHA edge bootstrap.
- GitHub-hosted iOS/macOS verification passed via
  `.github/workflows/apple-platform-verify.yml` on run `25078391954`.
- Final analyzer/test sweep is green after the live staging repairs, iOS floor
  fix, and tracker updates.
- Production1 remains locked until explicit approval.

Feature work stays paused until these gates are explicitly cleared.
