# Mobile Scope Flat Location Search Proof

Date: 2026-05-07
Status: focused implementation proof PASS

## Scope

This follow-up implements the clarified Doc 1 mobile drawer rule:
higher-level access grants expand into selectable location rows. Mobile
does not render operator/group/region rollup rows, and it does not
combine locations locally.

The slice adds:

- server-side flat location projection for operator-wide and org-unit
  grants
- global F&F read-role discovery for all registered business locations
- global F&F read-role mobile sign-in before a location is selected
- a searchable mobile hamburger location drawer
- selected-location read sync support for global F&F read tokens that
  do not carry tenant operator/location claims

## Invariants

- The proxy remains the source of truth for accessible locations.
- Active scope remains local cache state only.
- Mobile still reads one selected `(operator_id, location_id)` at a
  time.
- F&F global read roles can discover/select locations, but this slice
  does not add any mobile write permission or rollup dashboard.
- Push notification proof and the huge pressure suite remain outside
  this sprint.

## Verification

```powershell
dart analyze lib\services\auth\firebase_auth_login_service.dart lib\forge_flow_app.dart lib\infrastructure\persistence\postgres\repositories\org_units_repository.dart tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\business_scope_routes.dart tool\advisor_proxy\proxy_bootstrap.dart test\auth_live_binding_test.dart test\forge_flow_app_business_scope_drawer_test.dart test\proxy\business_scope_routes_test.dart
flutter test test\auth_live_binding_test.dart
flutter test test\forge_flow_app_business_scope_drawer_test.dart
flutter test test\proxy\business_scope_routes_test.dart
dart run tool\migration_drift_scanner.dart --fix --strict-docs
dart run tool\migration_cutoff_lint.dart
git diff --check
```

## Not Run

- Connected-device proof.
- Push notification proof.
- Huge pressure suite.
- Live provider calls.
