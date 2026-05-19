# 03 - Execution Slices

## Parallelization Rule

Start with the shared seams. After those land, run independent UI/backend
slices in parallel only when their file ownership is disjoint.

Each slice should:

- use its own worktree under `.codex_worktrees`
- use a `codex/` branch
- commit only its intentional changes
- push and open a PR
- merge only after tests pass, review is clean, and no listed product decision
  blocks the slice

## Slice 0 - Shared Scope Seam

Ownership:

- `lib/admin/admin_route_handoff.dart`
- admin scope models
- shared scope prompt widget
- admin shell route handoff tests

Tasks:

- Add `AdminHierarchyScopeIntent` with `business`, `org_unit`, and `location`.
- Replace operator/location-only handoff where scoped settings are intended.
- Preserve route state across tile switching.
- Add labels for inherited/local/effective values.

This slice blocks most UI work.

## Slice 1 - Business Accounts IA

Ownership:

- Business Accounts screen and related widgets
- operator/location admin models only where needed for display
- Business setup tile grid

Tasks:

- Remove `Click to manage`.
- Make row selection the action.
- Replace flat locations with hierarchy-first workspace.
- Show only the eight approved setup tiles.
- Hide Support Workspace from the primary IA.

Depends on Slice 0 for scope handoff.

## Slice 2 - Hierarchy CRUD Route Contracts

Ownership:

- `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart`
- `tool/advisor_proxy/advisor_proxy.dart`
- hierarchy proxy tests
- hierarchy gateway tests

Tasks:

- Reconcile admin move routes with proxy routes.
- Wire create org unit if not already exposed in admin UI.
- Add exact method/path/body tests.
- Keep org-unit delete/suspend/archive disabled until lifecycle exists.

## Slice 3 - Hierarchy-Aware Location Create

Ownership:

- `lib/infrastructure/persistence/postgres/repositories/locations_repository.dart`
- `tool/advisor_proxy/proxy_bootstrap.dart`
- `lib/admin/services/operator_location_admin_gateway.dart`
- location admin models/tests

Tasks:

- Add parent org unit to create-location commands and routes.
- Default to root only if the product explicitly accepts that behavior.
- Update admin UI to create locations from the selected hierarchy node.
- Preserve idempotency, audit reason, role checks, and confirmation copy.

## Slice 4 - People, Access, And Roles

Ownership:

- members admin screen/gateway
- roles hierarchy sessions admin screen/gateway
- permission explainer UI
- invite conflict UX

Tasks:

- Merge members, pending invites, role grants, role policy, and explainer into
  one scoped People/access/roles surface.
- Allow business/org-unit/location scoped role grants and invites where backend
  already supports them.
- Make duplicate-email states clickable and decision-ready.
- Preserve F&F staff multi-business support.

## Slice 5 - Security, Audit, And Sessions

Ownership:

- audited support actions admin screen/gateway
- sessions UI handoff
- audit/security admin surfaces

Tasks:

- Move active sessions under Security/audit/sessions.
- Keep reset password, MFA reset, suspend/reactivate, force logout, and support
  actions gated and audited.
- Disable password reset for pending invite-only users unless the backend can
  actually send the flow.

## Slice 6 - Account Profile And Contact Email

Ownership:

- business account profile UI
- operator admin models/screens
- copy tests

Tasks:

- Make Account profile editable.
- Rename user-facing Owner email copy to Contact email.
- Preserve `owner_email` DB/API compatibility.
- Add conflict detail flow for existing email usage.

## Slice 7 - Timing

Ownership:

- admin timing UI/gateway
- business timing admin routes/tests if needed
- timing scope labels

Tasks:

- Use business timing as the reference implementation for hierarchy settings.
- Show effective values, local overrides, inherited source, and service-period
  provenance.
- Include timezone in the Timing experience.

## Slice 8 - Data Accuracy And Polling/Pricing

Ownership depends on chosen path.

Minimum safe path:

- Keep business/org-unit edit disabled.
- Show read-only rollups or location-required copy.

Full path:

- Add hierarchy-scoped schema.
- Add repositories and effective resolvers.
- Add proxy routes.
- Add migration/repository/proxy/admin tests.
- Only then enable business/org-unit edit controls.

## Slice 9 - Integrations

Ownership:

- admin vendor connections mount/gateway
- integration UI scope prompt handoff

Tasks:

- Use hierarchy prompt for navigation context.
- Require a location before edit controls.
- Keep global Connected Services separate from business setup.

## Slice 10 - Support Logs

Ownership:

- support/debug logs gateway and screen
- optional proxy scoped filter route

Tasks:

- Accept business/org-unit/location scope.
- Expand org-unit to covered locations or add aggregate route.
- Keep Health and Observability global F&F tools.

## Slice 11 - Final Integration And Cleanup

Tasks:

- Remove duplicate/dead Support Workspace entry points or redirect them.
- Run full admin/proxy/operator web tests.
- Run Browser Use and performance frameworks on preview.
- Update execution evidence.
- Final audit: compare code against every checklist in this packet.
