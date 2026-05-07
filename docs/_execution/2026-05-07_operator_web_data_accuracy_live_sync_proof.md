# Operator Web Data Accuracy Live Sync Proof

Date: 2026-05-07
Status: focused implementation proof PASS

## Scope

This slice wires Operator Web's base Data Accuracy screen to server-owned
`data_accuracy_settings` instead of the demo/injected settings path.

It is not a mobile write path. Mobile remains a cache and continues to mirror
server truth through the operational sync surface.

## What Was Proven

- Operator Web reads base Data Accuracy settings through the proxy route
  `/v1/operators/:operatorId/locations/:locationId/data_accuracy_settings`.
- Operator Web saves base Data Accuracy edits through the same operator/location
  scoped route with `PATCH`.
- The proxy accepts Data Accuracy writes only from operator owner/admin roles.
- Location-manager tokens are rejected for Data Accuracy writes.
- Selected-location writes stay constrained by business-scope access.
- The Postgres gateway upserts `data_accuracy_settings` through tenant context.
- The web client uses the operator proxy client and bearer token provider; it
  does not call admin routes or become a source of truth.
- The screen still supports injected settings/save callbacks for focused widget
  tests and non-live previews.

## Commands

```powershell
dart analyze tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart lib\operator_web\services\operator_web_data_accuracy_gateway.dart lib\operator_web\services\operator_web_team_gateway_providers.dart lib\operator_web\auth\firebase_operator_web_auth_source.dart lib\operator_web\router\operator_web_router.dart lib\operator_web\screens\data_accuracy_screen.dart test\proxy\mobile_operational_sync_routes_test.dart test\operator_web\services\operator_web_data_accuracy_gateway_test.dart
flutter test test\proxy\mobile_operational_sync_routes_test.dart
flutter test test\operator_web\screens\data_accuracy_screen_test.dart
flutter test test\operator_web\services\operator_web_data_accuracy_gateway_test.dart test\operator_web\screens\data_accuracy_screen_test.dart test\proxy\mobile_operational_sync_routes_test.dart
git diff --check
```

## Not Claimed

- Keyed `data_accuracy_service_period_settings` admin/operator-web write UI.
- Wage/role editor or successful wage-role write proof.
- Timing web/admin live parity.
- Connected-device, live-provider, push, or Tier-M proof.
