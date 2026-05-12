# Mobile Wage Role Rows Sync Proof

Date: 2026-05-07
Status: focused implementation proof PASS

## Scope

This slice closes the Doc 1 mobile Admin/Web Settings Spine gap for
wage source / wage mix details and role/job-code mapping that affect mobile
labor calculations.

The server owns `wage_role_rows`. Mobile mirrors active rows as a local
SQLite cache only. Mobile writes were not added.

## What Was Proven

- Added additive server table `public.wage_role_rows` with operator/location
  scope, wrapper-only RLS, tenant-leading indexes, and TIMESTAMPTZ audit
  columns.
- Exposed read-only mobile proxy route
  `/v1/operators/:operatorId/locations/:locationId/wage_role_rows`.
- POST/PATCH are not routed for wage role rows.
- Proxy returns active rows only, so deleted/disabled server rows disappear
  from the next full mobile cache replacement.
- HTTP client follows wage-role pagination and parses role/rate rows without
  treating the server UUID as a SQLite integer id.
- Mobile sync replaces the active restaurant's local `wage_role_rows` cache
  from the server-owned set and preserves unrelated restaurant rows.
- Aborted sweeps preserve prior local wage-role cache and latest in-memory
  state.
- Realtime invalidation recognizes `wage_role_rows` and wage/job-code topics.
- Cross-tenant wipe removes stale wage-role cache for prior scopes.
- Migration drift scanner and cutoff lint pass with the new migration as the
  current cutoff.

## Commands

```powershell
dart analyze tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart test\proxy\mobile_operational_sync_routes_test.dart lib\services\sync\sync_proxy_client.dart lib\services\sync\http_sync_proxy_client.dart lib\services\sync\postgres_shift_record_to_mobile_sync.dart lib\services\sync\mobile_operational_sync_runtime.dart lib\infrastructure\persistence\sqlite\dao\wage_role_row_dao.dart lib\infrastructure\persistence\sqlite\repositories\sqlite_wage_role_row_repository.dart test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart test\services\sync\mobile_operational_sync_runtime_test.dart test\db\migrations\phase_8_wage_role_rows_server_truth_migration_test.dart
flutter test test\proxy\mobile_operational_sync_routes_test.dart test\db\migrations\phase_8_wage_role_rows_server_truth_migration_test.dart
flutter test test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart test\services\sync\mobile_operational_sync_runtime_test.dart
dart run tool\migration_drift_scanner.dart --fix --strict-docs
dart run tool\migration_cutoff_lint.dart
```

## Not Run

- Connected-device proof.
- Push notification proof.
- Huge pressure suite.
- Live staging / Production1 migration apply.
