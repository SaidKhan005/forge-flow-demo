# Doc 1 Mobile Scope Burger Final Proof

Date: 2026-05-07

Authority:
- `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
- `docs/_execution/2026-05-07_doc1_group_region_company_rollup_truth_audit.md`
- `PROJECT_TRACKER.md`

## Requirement Checked

Mobile users with multi-location or higher-level access must get a hamburger
drawer with searchable underlying locations, not a client-side rollup. Forge &
Flow admins must be able to see all registered business locations when they log
in to the mobile app.

## Confirmed On `origin/master`

- The mobile app drawer is mounted from the app toolbar and includes the
  `business_scope_location_search` text field.
- `filterBusinessScopeLocationsForDrawer` intentionally keeps only
  `location` scopes, so operator/org-unit/global grants expand into selectable
  location rows instead of local mobile rollups.
- Search matches location label, operator id, location id, and hierarchy path.
- `BusinessScopeRouter` returns every registered location for
  `super_admin`/`ff_support` users through
  `listAllLocationScopesForAdmin`.
- `RepositoryBusinessScopeProxyGateway` expands operator-wide grants and
  org-unit grants into underlying location scopes.
- Mobile sync rebases to the selected location scope and cancels stale work
  on scope changes.

## Explicit Boundary

No group, region, or company dashboard rollup is claimed here. The accepted
behavior remains location selection until a future server rollup snapshot
contract exists.

## Verification

Passed:

```powershell
flutter test test\forge_flow_app_business_scope_drawer_test.dart test\proxy\business_scope_routes_test.dart test\services\sync\mobile_operational_sync_runtime_test.dart
```
