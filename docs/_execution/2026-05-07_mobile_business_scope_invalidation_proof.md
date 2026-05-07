# Mobile Business Scope Invalidation Proof

Date: 2026-05-07
Status: focused implementation proof PASS

## Scope

This proof extends the mobile business-scope selector slice with stale-access
invalidation for Doc 1's mobile core logic contract.

The slice keeps mobile as a cache/read model and does not add group, region, or
company rollup behavior. Non-location scopes remain visible as business
structure context, but they are not selected as the active mobile data scope
until server rollup truth exists.

## What Was Proven

- Mobile listens for realtime frames that can change accessible business scopes:
  restaurant users, user roles, roles, role permissions, org units, locations,
  and user effective locations.
- A scope-affecting realtime frame for the current operator forces the mobile
  shell to reload accessible scopes instead of trusting the once-per-session
  cache.
- If the previous active location is no longer accessible, the notifier selects
  another accessible location, persists it, activates the restaurant mirror, and
  publishes the existing scope-change bus.
- If no selectable location scope remains, the notifier clears the persisted
  active scope and runtime restaurant override instead of leaving the revoked
  location active.
- The operational sync host treats the same business-scope invalidation frames
  as sync invalidations, so role/org/location changes can trigger a fresh pull.

## Commands

```powershell
flutter test test\state\restaurant_scope_notifier_test.dart test\services\scope\business_scope_repository_test.dart
flutter test test\services\sync\mobile_operational_sync_runtime_test.dart
dart analyze lib\services\scope\business_scope_repository.dart lib\state\restaurant_scope_notifier.dart lib\services\sync\mobile_operational_sync_runtime.dart lib\forge_flow_app.dart test\state\restaurant_scope_notifier_test.dart test\services\scope\business_scope_repository_test.dart
git diff --check
```

## Not Run

- Connected-device proof.
- Push notification proof.
- Huge pressure suite.
- Group, region, or company rollup dashboards.
