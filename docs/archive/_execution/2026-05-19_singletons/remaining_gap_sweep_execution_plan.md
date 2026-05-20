# Remaining Gap Sweep Execution Plan

Branch: `codex/remaining-gap-sweep`
Started: 2026-05-19
Base: `origin/master` after PR #1015 landed and was verified.

## Plain English Summary

- The last PR landed the Data Accuracy and star-shift fixes.
- This pass found live role-gate drift that still matters at runtime.
- Mobile Settings can still manufacture the old `operator_manager` role from permissions.
- Notifications still use old role gates, so real General Managers can miss events.
- Some proxy route allow-lists still admit phantom `operator_admin`, even though the role catalog says it was never seeded and is folded into Owner.
- Two extra findings are documented below but are not mixed into this patch because they need a product or walkthrough refresh.

## Role Split

- Orchestrator:
  - Owns branch hygiene, plan/doc updates, final integration, verification, commit, push, and PR.
  - Owns the mobile Settings projection fix unless a worker returns a clean patch first.
  - Reviews all worker output before committing.
- Worker A:
  - Owns notification role gates and fanout tests.
  - Files: `lib/domain/models/notification_event_catalog.dart`, `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart`, notification tests.
- Worker B:
  - Owns proxy operator-role allow-lists.
  - Files: `tool/advisor_proxy/operator_routes.dart`, `tool/advisor_proxy/advisor_proxy.dart`, `tool/advisor_proxy/operator_benchmark_override_cap.dart`, `tool/advisor_proxy/operator_benchmark_overrides_routes.dart`, `tool/advisor_proxy/connector_backfill_jobs_routes.dart`, `tool/advisor_proxy/vendor_lifecycle_recently_available_routes.dart`, focused proxy tests.
- Orchestrator local lane:
  - Owns `lib/forge_flow_app.dart` mobile Team actor projection and focused tests.

## Fix Plan

1. Replace mobile fallback role synthesis:
   - If permissions imply owner-level team writes, keep projecting `operator_owner`.
   - If permissions imply team visibility only, project `operator_general_manager`, not retired `operator_manager`.
   - Treat `operator_general_manager` as operator-wide for Settings/Team scope.
   - Add a focused test so permission-only sessions do not regress.

2. Replace notification gates:
   - Admin-only notifications: `operator_owner` only.
   - Manager notifications: `operator_owner`, `operator_general_manager`, `location_manager`, and `supervisor`.
   - Remove phantom `operator_admin` and retired `operator_manager` from the notification gate.
   - Update fanout and operator-web tests to prove the new role set.

3. Remove phantom `operator_admin` from live proxy allow-lists:
   - Operator write routes should admit `operator_owner` unless a route has an explicit broader current-role read posture.
   - Read-only status/progress routes should use current v2 roles, not `operator_admin`.
   - Update route comments and tests so the old role cannot silently pass.

## New Findings Documented For Later

- Admin demo fixtures still intentionally seed a v1 role catalog. This is now a cross-surface UX mismatch against Operator Web's v2 fixture, but the file explicitly says not to upgrade without a paired admin walkthrough refresh. Keep it out of this runtime patch.
- Mobile Covers Setup now writes the canonical server route, so the full-coverage write decision is landed. One UX/product edge remains: the copy says "manual override" for vendors that already send covers, but the contract only lets manual entries override automatically when the POS does not expose covers. A true per-date override-over-vendor rule needs a product decision because flipping the service-period source to `manual` globally would create missing-cover days.

## Verification

- `flutter test test/forge_flow_app_team_actor_projection_test.dart`
- `flutter test test/operator_web/screens/settings_notifications_screen_test.dart`
- `flutter test test/services/email/notification_event_fanout_test.dart`
- `flutter test test/services/notification/notification_event_fanout_production_binding_test.dart`
- Focused proxy tests touched by the operator-role allow-list patch.
- `dart analyze --fatal-infos` on changed Dart files.
- `dart run tool/advisor_proxy_size_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check`
