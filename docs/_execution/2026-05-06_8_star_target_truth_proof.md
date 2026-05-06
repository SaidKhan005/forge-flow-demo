# 8.star-target-server-truth Proof

Date: 2026-05-06

Primary contract:

- `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`

Sprint plan:

- `docs/_execution/2026-05-06_mobile_core_star_target_truth_sprint_plan.md`

## Covered In This Sprint

- Additive server truth schema for selected stars, target cycles, active target
  profiles, profile versions, and star/target audit events.
- Postgres repositories for selected-star decisions, target-cycle replacement,
  once-per-cycle manager override guard, active profile projection, version
  snapshots, and audit writes.
- Proxy selected-star select/clear routes with auth scope, permission gate,
  idempotency, and audit-backed repository writes.
- Proxy read routes for selected stars, target cycles, active profiles, and
  profile versions.
- Server target-cycle projection service that consumes server-selected stars and
  writes active target profile truth.
- Mobile sync mirrors selected stars, target cycles, active profiles, and target
  profile versions into existing SQLite cache tables.
- Mobile Baseline Manager routes selection changes through the proxy seam when
  Firebase/proxy live bindings are wired, and surfaces permission/unavailable
  failures without mutating the local cache.

## Proof Commands

```powershell
flutter test test\phase_8_star_target_truth_postgres_test.dart test\proxy\selected_star_target_routes_test.dart test\services\server_target_cycle_projection_service_test.dart test\services\star_target_selection_write_service_test.dart test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart test\services\sync\mobile_operational_sync_runtime_test.dart test\services\sync\star_target_sync_mirror_test.dart test\baseline_manager_service_test.dart test\baseline_manager_screen_test.dart
flutter test test\target_cycle_policy_test.dart test\tool\migration_cutoff_lint_test.dart test\tool\migration_drift_scanner_test.dart
dart analyze db\migrations\202605061900_phase_8_star_target_truth.sql lib\infrastructure\persistence\postgres\repositories\selected_star_shift_repository.dart lib\infrastructure\persistence\postgres\repositories\target_cycle_repository.dart lib\infrastructure\persistence\postgres\repositories\active_target_profile_repository.dart lib\services\server_target_cycle_projection_service.dart lib\services\star_target_selection_write_service.dart lib\services\sync\star_target_sync_resources.dart lib\services\sync\http_sync_proxy_client.dart lib\services\sync\postgres_shift_record_to_mobile_sync.dart lib\services\sync\mobile_operational_sync_runtime.dart lib\services\baseline_manager_service.dart lib\screens\baseline_manager_screen.dart tool\advisor_proxy\star_target_routes.dart tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart test\phase_8_star_target_truth_postgres_test.dart test\proxy\selected_star_target_routes_test.dart test\services\server_target_cycle_projection_service_test.dart test\services\star_target_selection_write_service_test.dart test\services\sync\star_target_sync_mirror_test.dart test\services\sync\http_sync_proxy_client_test.dart test\baseline_manager_service_test.dart test\baseline_manager_screen_test.dart
dart run tool\star_target_truth_harness\main.dart
```

## Result

- Main focused Flutter proof batch: passed, 126 tests.
- Policy and migration lint batch: passed, 40 tests.
- Targeted analyzer batch: passed, no issues found.
- Fixture harness: passed.

## Out Of Scope

- Weekly plan snapshot server truth.
- Business scope hamburger selector.
- Group, region, and company rollups.
- Push notification proof.
- Live vendor credential proof.
- Huge pressure suite.
