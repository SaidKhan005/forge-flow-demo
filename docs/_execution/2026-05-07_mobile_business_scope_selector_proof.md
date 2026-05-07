# Mobile Business Scope Selector Proof

Date: 2026-05-07
Status: focused implementation proof PASS

## Scope

This proof closes Doc 1 Phase 1 mobile scope foundation for the
location-level V1 path:

- server route for accessible business scopes
- mobile business-scope model
- local active-scope SQLite repository
- hamburger drawer in the mobile shell
- sync cancellation and rebase on scope switch
- cross-scope cache wipe before the fresh sync sweep

The route supports the canonical contract path
`/v1/users/:userId/business_scopes` and the earlier Doc 1 dispatch
wording `/v1/operators/:operatorId/business_scopes`.

## What Was Proven

- The proxy returns accessible scopes from a server gateway and rejects
  a different user id.
- The proxy allows mobile read sync to rebase to another accessible
  location under the same operator.
- The local active scope round-trips per user in SQLite.
- `HttpSyncProxyClient.fetchAccessibleBusinessScopes` calls the
  user-scoped route and parses location scopes.
- `MobileOperationalSyncRunner` uses the active location scope for
  pull paths instead of mutating `AuthSession`.
- `cancelInFlightSync()` aborts the active sweep before auxiliary pulls.
- The existing auth scope-change wipe and sign-out abort tests still
  pass.
- Existing selected-star and weekly-plan route tests still pass.

## Commands

```powershell
dart analyze
dart analyze tool\advisor_proxy\business_scope_routes.dart tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart tool\advisor_proxy\main.dart lib\domain\models\business_scope.dart lib\services\scope\business_scope_repository.dart lib\infrastructure\persistence\sqlite\repositories\sqlite_active_scope_repository.dart lib\services\sync\http_sync_proxy_client.dart lib\state\restaurant_scope_notifier.dart lib\services\sync\mobile_operational_sync_runtime.dart lib\forge_flow_bootstrap.dart lib\forge_flow_app.dart test\proxy\business_scope_routes_test.dart test\services\scope\business_scope_repository_test.dart test\services\sync\mobile_operational_sync_runtime_test.dart test\services\sync\http_sync_proxy_client_test.dart
flutter test test\proxy\business_scope_routes_test.dart
flutter test test\services\scope\business_scope_repository_test.dart
flutter test test\services\sync\mobile_operational_sync_runtime_test.dart
flutter test test\services\sync\http_sync_proxy_client_test.dart
flutter test test\proxy\selected_star_target_routes_test.dart
flutter test test\proxy\weekly_plan_routes_test.dart
dart run tool\migration_drift_scanner.dart --fix --strict-docs
dart run tool\migration_cutoff_lint.dart
```

## Not Run

- Connected-device proof.
- Push notification proof.
- Huge pressure suite.
- Group, region, or company rollup dashboards.
- Live provider calls.

## Remaining Follow-Up

Operator Web needs the same drawer affordance in its shell. Group and
region rows are returned as scopes, but V1 intentionally keeps those
non-switchable on mobile until server rollup truth exists.
