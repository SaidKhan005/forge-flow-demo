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
- No local mobile rollup logic for group, region, or company scopes.

## 2026-05-08 amendment — keyed write UI surfaces landed

The closeout doc (`docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md`
§"Remaining Narrow Remediation Slices" item 2) called out that mobile read
sync was already proven but the **admin/operator-web keyed write surface
implementation was explicitly not run**. This amendment closes that gap:

- Operator Web `DataAccuracyScreen` now mounts a
  `KeyedServicePeriodAccuracyCard` when a live data-accuracy gateway is
  injected. The card lists keyed rows the operator already has and exposes
  an "Add or supersede" affordance whose dialog round-trips a draft into
  `OperatorWebHttpDataAccuracyGateway.saveServicePeriodSetting` — i.e. the
  same scoped PATCH route mobile mirrors through operational sync.
- F&F Ops Console `PerLocationDataAccuracyScreen` now exposes a
  per-row "Service period" override button that opens a separate dialog
  collecting `service_period_key`, `effective_at_business_date`,
  `covers_source`, `wage_source`, and a required reason note. The
  in-memory + HTTP `DataAccuracyAdminGateway` implementations gained
  `overrideDataAccuracyServicePeriod` /
  `listDataAccuracyServicePeriodRows`; the in-memory path captures an
  `admin.data_accuracy.service_period_override` audit event with
  `actor_kind = 'forge_admin'` and the reason note.
- The proxy keyed PATCH route now defends in depth: the route handler
  validates `service_period_key` (regex pattern), `effective_at_business_date`
  (YYYY-MM-DD), `covers_source` (enum), and `wage_source` (enum) before
  delegating to the gateway, so alternate gateway impls (test fakes,
  future per-tenant routers) cannot accept a malformed body.

### Tests added

- `test/proxy/mobile_operational_sync_routes_test.dart` —
  - service-period PATCH rejects `location_manager`,
  - rejects malformed `service_period_key` (`invalid_service_period_key`),
  - rejects malformed `effective_at_business_date`
    (`invalid_effective_at_business_date`),
  - rejects URL scope different from bearer scope.
- `test/operator_web/screens/data_accuracy_screen_test.dart` —
  - keyed card renders existing rows when a data-accuracy gateway is wired,
  - "Add" affordance round-trips a draft into `saveServicePeriodSetting`
    with the right operator/location/key/date/covers/wage payload,
  - dialog rejects invalid `service_period_key` inline and skips save.
- `test/admin/data_accuracy_admin_override_writes_audit_test.dart` —
  - service-period dialog submit captures
    `admin.data_accuracy.service_period_override` audit event with the
    right diff + reason note + `actor_kind = 'forge_admin'`,
  - gateway rejects override missing reason note,
  - gateway throws `DataAccuracyAdminForbiddenException` for non-admin
    actor.

### Files touched

- `tool/advisor_proxy/advisor_proxy.dart` — keyed PATCH body validator.
- `lib/operator_web/screens/data_accuracy_screen.dart` — keyed card mount
  + load/save orchestration.
- `lib/operator_web/widgets/keyed_service_period_accuracy_card.dart` —
  new card + dialog.
- `lib/admin/screens/per_location_data_accuracy_screen.dart` — service-period
  dialog + handler.
- `lib/admin/widgets/per_location_data_accuracy_table.dart` —
  optional `onEditServicePeriod` action.
- `lib/admin/services/data_accuracy_admin_gateway.dart` —
  `overrideDataAccuracyServicePeriod` /
  `listDataAccuracyServicePeriodRows` on both HTTP + in-memory gateways.

### Verification

```powershell
flutter test test\proxy\mobile_operational_sync_routes_test.dart
flutter test test\operator_web\screens\data_accuracy_screen_test.dart
flutter test test\admin\data_accuracy_admin_override_writes_audit_test.dart
dart analyze tool\advisor_proxy\advisor_proxy.dart `
  lib\operator_web\screens\data_accuracy_screen.dart `
  lib\operator_web\widgets\keyed_service_period_accuracy_card.dart `
  lib\admin\screens\per_location_data_accuracy_screen.dart `
  lib\admin\widgets\per_location_data_accuracy_table.dart `
  lib\admin\services\data_accuracy_admin_gateway.dart `
  test\proxy\mobile_operational_sync_routes_test.dart `
  test\operator_web\screens\data_accuracy_screen_test.dart `
  test\admin\data_accuracy_admin_override_writes_audit_test.dart
```

## Verification

Passed:

```powershell
flutter pub get
dart analyze tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart lib\operator_web\services\operator_web_data_accuracy_gateway.dart test\proxy\mobile_operational_sync_routes_test.dart test\operator_web\services\operator_web_data_accuracy_gateway_test.dart
flutter test test\proxy\mobile_operational_sync_routes_test.dart test\operator_web\services\operator_web_data_accuracy_gateway_test.dart
```
