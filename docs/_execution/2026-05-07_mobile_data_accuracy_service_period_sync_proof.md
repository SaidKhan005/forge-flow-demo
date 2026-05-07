# Mobile Data Accuracy Service-Period Sync Proof

Date: 2026-05-07
Status: focused implementation proof PASS

## Scope

This slice closes the mobile read-side parity gap for keyed
`data_accuracy_service_period_settings` under Doc 1's admin/web settings sync
requirement.

It is read-only for mobile. Admin/operator web remain the write authority, and
mobile mirrors the server-owned rows in memory alongside the existing legacy
`data_accuracy_settings` snapshot.

## What Was Proven

- The proxy exposes a mobile GET route for
  `/v1/operators/:operatorId/locations/:locationId/data_accuracy_service_period_settings`.
- The route is tenant scoped through the existing mobile operational sync gate.
- POST/PATCH are not routed for the keyed settings surface.
- The HTTP sync client parses keyed rows, including custom service period keys
  and the `reservation_plus_walkin` covers-source value reserved by the contract.
- The mobile sync orchestrator pulls keyed settings in the aux sweep and exposes
  them through `SyncResult` and a latest-snapshot getter.
- Legacy `data_accuracy_settings` sync remains unchanged.
- Realtime invalidation recognizes `data_accuracy_service_period_settings`.

## Commands

```powershell
dart analyze tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart test\proxy\mobile_operational_sync_routes_test.dart lib\services\sync\sync_proxy_client.dart lib\services\sync\http_sync_proxy_client.dart lib\services\sync\postgres_shift_record_to_mobile_sync.dart lib\services\sync\mobile_operational_sync_runtime.dart test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart test\services\sync\mobile_operational_sync_runtime_test.dart test\services\sync\star_target_sync_mirror_test.dart test\services\sync\weekly_plan_sync_mirror_test.dart test\_execution\spine_bridge_v2_smoke_test.dart
flutter test test\proxy\mobile_operational_sync_routes_test.dart
flutter test test\services\sync\http_sync_proxy_client_test.dart test\services\sync\postgres_shift_record_to_mobile_sync_test.dart
```

## Not Run

- Connected-device proof.
- Push notification proof.
- Huge pressure suite.
- Admin/operator-web keyed-write implementation.
