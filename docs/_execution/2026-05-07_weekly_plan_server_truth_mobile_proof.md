# Weekly Plan Server Truth Mobile Proof

Date: 2026-05-07
Branch: `codex/mobile-weekly-plan-truth`
Primary contract:
`docs/contracts/mobile_core_weekly_plan_server_truth_contract.md`

## What Was Proved

- Additive Postgres schema owns `forecast_contexts`,
  `weekly_plan_snapshots`, `weekly_plan_snapshot_days`, and
  `weekly_plan_audit_events`.
- Weekly snapshots keep a `target_cycles(operator_id, cycle_id)` RESTRICT
  FK and enforce one active row per operator/location/restaurant/week.
- Replacing a weekly plan supersedes the prior active row instead of
  deleting it.
- Closed forecast contexts are immutable.
- Proxy lock routes enforce permission, scope, idempotency, and
  proxy-derived actor fields.
- Production bootstrap wires `WeeklyPlanRouter` to Postgres repositories.
- Embedded forecast context lock requests write forecast context first, then
  lock the weekly snapshot that references it.
- Mobile sync pulls weekly snapshots through the proxy and stores them in the
  existing SQLite weekly plan cache.
- Forecast context is pulled as server-owned read data without creating a
  duplicate mobile SQLite table.
- Schedule locked-authority mode shows an explicit unavailable/loading state
  and does not silently generate local plan numbers when the locked server
  snapshot is missing.

## Verification Run

```powershell
flutter test test\phase_8_weekly_plan_server_truth_postgres_test.dart test\proxy\weekly_plan_routes_test.dart test\proxy\weekly_plan_repository_gateway_test.dart
flutter test test\services\sync\weekly_plan_sync_mirror_test.dart test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart test\services\sync\mobile_operational_sync_runtime_test.dart
flutter test test\schedule_builder_widget_test.dart test\schedule_plan_read_service_test.dart test\weekly_plan_snapshot_service_test.dart
dart analyze
dart run tool\migration_cutoff_lint.dart
dart run tool\migration_drift_scanner.dart --fix --strict-docs
```

Results:

- Schema/proxy/repository binding tests: 25 passed.
- Mobile sync/runtime tests: 35 passed.
- Schedule/read/snapshot tests: 63 passed.
- `dart analyze`: clean.
- `migration_cutoff_lint`: clean.
- `migration_drift_scanner`: no migration drift and cutoff clean; strict-docs
  failed only because watched authority docs still reference older migration
  names outside this sprint's update scope.

## Not Run

- No push notification proof.
- No huge pressure suite.
- No live vendor/provider calls.
- No live connected-device E2E against staging.
- No business-scope hamburger selector work.
