# Mobile Star Target Projection Route Proof

Date: 2026-05-07

Primary contract:

- `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`

Related accepted sprint:

- `docs/contracts/mobile_core_star_target_truth_contract.md`
- `docs/_execution/2026-05-06_8_star_target_truth_proof.md`

## What Changed

- Added a live proxy POST route:
  `/v1/operators/:operator_id/locations/:location_id/target_cycles/project_manager_override`.
- The route uses the existing `ServerTargetCycleProjectionService` to consume
  current server-selected star decisions, replace the server target cycle, and
  project the active target profile.
- The route is permission checked, idempotency-keyed, and maps once-per-cycle
  manager override denial to an honest `409 manager_override_already_used`.
- The mobile selected-star writer now sends the selected-star diff first, then
  posts the projection request when a non-empty selected set remains.
- Mobile continues to mirror server truth through the existing SQLite cache
  sync; it does not become the source of truth.

## Verification

```powershell
flutter test test\proxy\selected_star_target_routes_test.dart
flutter test test\services\star_target_selection_write_service_test.dart test\services\sync\http_sync_proxy_client_test.dart
flutter test test\services\server_target_cycle_projection_service_test.dart test\baseline_manager_service_test.dart
dart analyze tool\advisor_proxy\star_target_routes.dart lib\services\star_target_selection_write_service.dart lib\services\sync\http_sync_proxy_client.dart lib\forge_flow_bootstrap.dart test\proxy\selected_star_target_routes_test.dart test\services\star_target_selection_write_service_test.dart test\services\sync\http_sync_proxy_client_test.dart tool\star_target_truth_harness\main.dart
dart run tool\star_target_truth_harness\main.dart
git diff --check
```

Result: all passed.

## Still Remaining From Doc 1

- Web/admin setting sync parity for data accuracy, operator-web timing read
  hydration, and any mobile-facing wage/role mapping settings.
- Business-scope stale-access invalidation for role/org/location changes.
- Group/region/company rollup truth.
- Operator-blocked connected-device, live-provider, and push proof gates.
