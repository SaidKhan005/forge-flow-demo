# Mobile Reservation Demand Settings Sync Proof

Date: 2026-05-07

Contract:
- `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
- `docs/contracts/data_accuracy_settings_contract.md`

## Scope

This slice closes the Doc 1 reservation demand settings gap by making walk-in
handling durable server-owned truth and mobile-readable cache input.

Implemented:
- Additive Postgres migration:
  `db/migrations/202605080300_phase_8_data_accuracy_walk_in_settings.sql`
- Domain/repository fields:
  `walk_in_handling_mode`
  `walk_in_manual_entries`
- Operator Web Data Accuracy walk-in card now materializes/saves into
  `DataAccuracySettings`.
- F&F admin Data Accuracy table renders walk-in mode and the override dialog can
  edit it.
- Mobile proxy payload and `DataAccuracySettingsSnapshot` include the walk-in
  fields.
- Closed-shift reservation+walk-in aggregation reads durable
  `data_accuracy_settings` when no explicit test/backfill override is supplied.

Not in scope:
- Push notification proof.
- Huge pressure suite.
- Mobile as a write authority.
- Duplicate `open_shift_snapshots_cache`.

## Verification

```powershell
dart analyze db\migrations\202605080300_phase_8_data_accuracy_walk_in_settings.sql lib\domain\models\data_accuracy_settings.dart lib\services\data_accuracy\data_accuracy_settings_repository.dart lib\services\integration\canonical_fact_to_closed_shift_input.dart lib\services\sync\sync_proxy_client.dart lib\services\sync\http_sync_proxy_client.dart lib\operator_web\screens\data_accuracy_screen.dart lib\admin\services\data_accuracy_admin_gateway.dart lib\admin\screens\per_location_data_accuracy_screen.dart lib\admin\widgets\per_location_data_accuracy_table.dart tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart test\services\data_accuracy\data_accuracy_settings_repository_test.dart test\services\integration\canonical_fact_to_closed_shift_input_test.dart test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart test\proxy\mobile_operational_sync_routes_test.dart test\proxy\data_accuracy_admin_routes_test.dart test\operator_web\screens\data_accuracy_screen_test.dart test\db\migrations\phase_8_data_accuracy_walk_in_settings_migration_test.dart
```

```powershell
flutter test test\db\migrations\phase_8_data_accuracy_walk_in_settings_migration_test.dart test\services\data_accuracy\data_accuracy_settings_repository_test.dart test\services\integration\canonical_fact_to_closed_shift_input_test.dart test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart test\proxy\mobile_operational_sync_routes_test.dart test\proxy\data_accuracy_admin_routes_test.dart test\operator_web\screens\data_accuracy_screen_test.dart test\admin\data_accuracy_admin_override_writes_audit_test.dart
```

```powershell
dart run tool\migration_drift_scanner.dart --fix --strict-docs
dart run tool\migration_cutoff_lint.dart
```

Notes:
- The focused proxy test suite emits the expected `proxy.unhandled_error` log in
  the existing "upstream gateway throw surfaces 503" case; the test passes and
  asserts the wrapped 503 response.
