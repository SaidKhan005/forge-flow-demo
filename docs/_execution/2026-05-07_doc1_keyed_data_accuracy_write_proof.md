# Doc 1 Keyed Data Accuracy Write Proof

Date: 2026-05-07

Authority:
- `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
- `docs/contracts/integration_spine_architecture_contract.md`
- `docs/contracts/data_accuracy_settings_contract.md`

## Scope

This slice closes the backend/operator-web write path for
`public.data_accuracy_service_period_settings`, keyed by
`operator_id`, `location_id`, `service_period_key`, and
`effective_at_business_date`.

The write remains server-owned:
- Mobile continues to read through operational sync.
- Operator Web writes through the scoped proxy route.
- No duplicate `open_shift_snapshots_cache` table was created.
- Mobile does not become the source of truth.

## Implemented

- `PATCH /v1/operators/:operatorId/locations/:locationId/data_accuracy_service_period_settings`
  now routes through `MobileOperationalSyncProxyGateway`.
- `RepositoryMobileOperationalSyncProxyGateway` validates keyed body fields
  and upserts the canonical Postgres table.
- `OperatorWebHttpDataAccuracyGateway` can load and save service-period
  settings over the same operator-scoped path.
- Route tests prove POST remains rejected while PATCH writes under
  owner/admin scope.
- Operator Web gateway tests pin GET/PATCH path, token, idempotency key,
  and keyed wire payload shape.

## Explicitly Not In This Slice

- No mobile-side write surface for service-period data accuracy settings.
- No arbitrary custom service-period editor UI in Operator Web.
- No local mobile rollup logic for group, region, or company scopes.

## Verification

Passed:

```powershell
flutter pub get
dart analyze tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart lib\operator_web\services\operator_web_data_accuracy_gateway.dart test\proxy\mobile_operational_sync_routes_test.dart test\operator_web\services\operator_web_data_accuracy_gateway_test.dart
flutter test test\proxy\mobile_operational_sync_routes_test.dart test\operator_web\services\operator_web_data_accuracy_gateway_test.dart
```
