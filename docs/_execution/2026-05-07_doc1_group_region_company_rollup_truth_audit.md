# Doc 1 Group/Region/Company Rollup Truth Audit

Date: 2026-05-07
Status: audited; future server-truth slice required

## Scope

This audit covers the remaining Doc 1 business-scope item: group, region, and
company rollup truth for mobile and web surfaces.

The current accepted mobile behavior is location-level selection only. Higher
level grants expand server-side into selectable location rows, and mobile reads
one selected `(operator_id, location_id)` at a time.

## Findings

- The Doc 1 contract requires group/region/company scopes to read server rollup
  truth and explicitly forbids local mobile mixing of unrelated location caches.
- The business-scope proxy currently exposes accessible scope list routes:
  `/v1/users/:userId/business_scopes` and
  `/v1/operators/:operatorId/business_scopes`.
- The implemented route returns selectable location rows and can expand global
  Forge & Flow read roles into all registered business locations.
- The current route layer does not implement
  `/v1/operators/:operatorId/business_scopes/:scopeId/snapshot`.
- Mobile business-scope models can represent non-location scope metadata, but
  the sync runtime intentionally rebases only location scopes.
- Historical infrastructure includes org-unit hierarchy tables and rollup
  metric tables, but there is no Doc 1 mobile rollup snapshot route, no typed
  mobile rollup snapshot client, and no mobile UI that renders a group/region
  dashboard from server rollup rows.

## Decision

Do not implement a client-side rollup in the mobile app.

The remaining work must be a server-truth slice that creates or blesses a
specific group/region/company snapshot contract, then exposes that contract
through proxy routes and mobile/web readers. Until that exists, higher-level
access continues to expand into searchable location rows only.

## Future Slice Boundary

`8.business-scope-rollup-truth` should own:

- canonical server snapshot contract for company, group, and region scopes
- proxy route for `/v1/operators/:operatorId/business_scopes/:scopeId/snapshot`
- permission checks proving the caller can read the requested higher scope
- typed mobile/web client model for the server snapshot payload
- tests proving mobile does not mix local location caches
- UI copy that distinguishes a server rollup view from a selected location view
- invalidation behavior for org-unit, location, timing, and operational fact
  changes that affect the snapshot

## Commands

```powershell
rg -n "business_scopes/.*/snapshot|rollup snapshot|scope_type|org_unit|effective_locations|accessible" tool\advisor_proxy lib test db\migrations docs\_execution -g "*.dart" -g "*.sql" -g "*.md"
git diff --check
```

## Not Claimed

- No group, region, or company dashboard acceptance.
- No mobile multi-location rollup cache.
- No live provider proof.
- No connected-device proof.
- No push delivery proof.
