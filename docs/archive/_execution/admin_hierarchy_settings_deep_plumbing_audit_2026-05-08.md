# Admin Hierarchy Settings Deep Plumbing Audit

Status: audit complete, implementation not started
Branch: `codex/admin-hierarchy-settings-overhaul-plan`
Source commit inspected: `bed55889`
Created: 2026-05-08
Implementation packet:
`docs/_execution/admin_hierarchy_settings_overhaul/README.md`

## Purpose

This audit expands the admin hierarchy settings overhaul plan into an end-to-end
plumbing checklist. The target UX is simple, but the implementation crosses
schema, repositories, proxy routes, admin gateways, route handoff, operator web
parity, and preview verification. The goal of this note is to make sure no
required layer is missed.

## Non-Negotiable Rule

Every setting must resolve through this hierarchy:

`business/operator default -> org-unit ancestors from root to leaf -> location`

The lowest configured scope wins. If a lower scope has no local value, it
inherits from the nearest configured ancestor. Every settings UI must show:

- selected scope
- whether the value is local or inherited
- inherited source when inherited
- effective value
- allowed actions for the signed-in role
- mutation requirements: confirmation copy, audit reason, idempotency key, and
  route-level permission checks

Integrations are the edit-scope exception. The hierarchy prompt can help staff
find the right context, but vendor credential/OAuth edits remain location-only.

## Executive Findings

| Area | Audit result | Must not miss |
|---|---|---|
| Shared scope model | Current admin route handoff and picker are operator/location only. | Add a first-class hierarchy scope object with `business`, `org_unit`, and `location`. |
| Business scope routes | Mobile/business scope plumbing can list accessible locations, and global staff can list all locations. It does not currently return business or org-unit selectable rows. | Extend scope list payloads so support/admin users can choose business and org-unit scopes, not only locations. |
| Business account profile | Admin operator CRUD is live through `/v1/admin/operators`. UI already labels some fields as Contact email, but models/routes still use `owner_email`. | Keep DB/API compatibility, but normalize UI copy to Contact email everywhere business contact is meant. |
| Hierarchy tree | Org-unit list, org-unit create, and location move exist in the proxy/auth gateway. The admin screen shows list and move only. | Wire create org unit to the admin gateway/screen; add missing edit/delete/suspend/archive contracts before exposing those buttons. |
| Org-unit move route | Admin gateway posts to `/v1/admin/auth/org-units/:id/move`, but proxy handling inspected here only shows `POST /v1/admin/auth/org-units` and `PATCH /v1/admin/auth/locations/:id/org-unit`. | Reconcile route contract before relying on org-unit move in production UI. |
| Add location in hierarchy | Flat add-location route does not send `parent_org_unit_id`; `locations.parent_org_unit_id` is not-null after hierarchy wiring. | Extend admin location create command/proxy/repository to require or default an org-unit parent. |
| Location lifecycle | Current location admin path supports patch and hard delete. There is no separate suspend/archive lifecycle in the repository inspected here. | Decide product lifecycle semantics before showing Suspend/Archive/Delete in the hierarchy tree. |
| Data accuracy | Current schema, repo, routes, and admin screens are per operator/location. | Add hierarchy-scoped settings storage and effective resolver before business/org-unit editing can be real. |
| Polling and pricing | Current polling tier assignment model is per operator/location. | Add scoped assignment/effective resolution or keep higher scopes read-only until wired. |
| Timing | Business timing schema/repository already use `operator`, `org_unit`, and `location` scopes and resolver-precedence ordering. | Build the admin scoped timing surface and include timezone, which still lives on location/account fields. |
| People/access/roles | Role grants and invites support operator-wide, org-unit, and location scopes. Members, role policy, hierarchy, and sessions are split across screens. | Merge People/access/roles around the shared hierarchy scope prompt and permission explainer. |
| Security/audit/sessions | Audit/security actions are admin-backed; active sessions are currently in the Access screen. | Move sessions into Security/audit/sessions and keep support actions audited/gated. |
| Support workspace | Current `SupportOperatorViewAdminScreen` is a primary four-tab concept: People, Access, Security & audit, Vendors. | Remove it as a visible IA concept after its capabilities are redistributed; keep a hidden redirect/fallback only if needed. |
| Vendor integrations | Per-location admin integration routes exist and enforce `integrations.configure`; current admin mount often renders a not-wired/read-only panel when no gateway is injected. | Wire a real admin vendor gateway if lifecycle actions are desired; never fake business/org-unit edit controls. |
| Support logs | Current support log handoff filters operator/location only. | Expand a business/org-unit selected scope into covered locations for log filtering, or show a scoped aggregate route if added. |
| Performance | Some hierarchy requests are coalesced, but selected scope and screen route switching are not centralized. | Use a shared scope cache and avoid duplicate list calls when moving between tiles. |

## Layer-By-Layer Audit

### 1. Shared Hierarchy Scope

Current code:

- `lib/admin/admin_route_handoff.dart` defines `AdminOperatorLocationScopeIntent`
  with only `operatorId`, optional `locationId`, names, and a cache key.
- `lib/admin/screens/operator_picker_screen.dart` returns
  `OperatorPickerResult` with one required location.
- Business Accounts creates route intents from a primary or selected location,
  not from an arbitrary business/org-unit/location scope.

Implementation needed:

- Add `AdminHierarchyScopeIntent` or equivalent:
  - `operatorId`
  - `scopeType`: `business`, `org_unit`, `location`
  - `orgUnitId`
  - `locationId`
  - display names/path
  - inherited/effective metadata where available
  - stable cache key
- Replace or adapt all route handoff paths that currently assume
  `AdminOperatorLocationScopeIntent`.
- Build one hierarchy scope prompt used by Data accuracy, Polling and pricing,
  People/access/roles, Security/audit/sessions, Support logs, Integrations, and
  Timing.
- Keep location-only fallbacks during migration only where routes require a
  location.

Tests to add/update:

- Admin route handoff test for business, org-unit, and location scopes.
- Scope prompt widget tests for inherited/local/effective labels.
- Route switching tests confirming selected scope survives tab changes.

### 2. Business and Staff Scope Access

Current code:

- `tool/advisor_proxy/business_scope_routes.dart` exposes:
  - `GET /v1/users/:user_id/business_scopes`
  - `GET /v1/operators/:operator_id/business_scopes`
- Global roles `super_admin` and `ff_support` can list all location scopes.
- `RepositoryBusinessScopeProxyGateway` expands operator-wide and org-unit grants
  into location rows only.

Implementation needed:

- Return operator/business rows and org-unit rows in addition to location rows
  for staff/admin scope selection.
- Preserve location expansion for mobile runtime if mobile needs a concrete
  active location.
- Decide how Forge & Flow staff users differ from business owner/contact emails:
  staff should be able to access many businesses; business contact uniqueness is
  a product rule and should not block staff support accounts.
- If an email already exists, expose a read-only "where used" lookup for admin
  decision-making before invite/onboarding flows continue.

Tests to add/update:

- `test/proxy/business_scope_routes_test.dart` for operator and org-unit rows.
- Business scope repository tests for multi-business Forge & Flow staff.
- Forbidden tests for non-staff users requesting other businesses.

### 3. Business Accounts and Account Profile

Current code:

- `lib/admin/screens/operator_location_admin_screen.dart` still shows
  `Click to manage` on unselected business rows.
- The selected business card has top action buttons for Support view, Data
  accuracy, Polling & pricing, and View logs, plus Edit/Suspend.
- `_BusinessSetupCard` has Account profile, Primary location, Support workspace,
  People, Access, Data, Security & audit, Polling & pricing.
- `OperatorLocationAdminGateway` supports list/onboard/patch/suspend/reactivate
  through `/v1/admin/operators`.

Implementation needed:

- Remove `Click to manage`; selecting the row is the action.
- Make Account profile the only edit entry point for business account fields.
- Use Contact email in all UI copy for business contact fields. Keep wire field
  `owner_email` until an API/data migration is intentionally scheduled.
- Replace current Business setup tiles with exactly:
  - Account profile
  - Data accuracy
  - Polling and pricing
  - People, access, and roles
  - Security, audit, and sessions
  - Support logs
  - Integrations
  - Timing
- Remove visible Support workspace tile/button after redistributed surfaces are
  ready.

Tests to add/update:

- Business Accounts screen tests for no `Click to manage`.
- Account profile dialog tests for contact email copy.
- Business setup tile tests for the final eight tiles only.

### 4. Hierarchy CRUD and Location CRUD

Current code:

- `RepositoryAuthOperationsGateway.createOrgUnit` exists and audits
  `auth.org_unit_created`.
- `RepositoryAuthOperationsGateway.moveLocationToOrgUnit` exists and audits
  `auth.location_org_unit_moved`.
- Proxy handling exists for:
  - `GET /v1/admin/auth/org-units`
  - `POST /v1/admin/auth/org-units`
  - `PATCH /v1/admin/auth/locations/:id/org-unit`
- `HttpRolesHierarchySessionsAdminGateway.moveOrgUnit` posts to
  `/v1/admin/auth/org-units/:id/move`, but the inspected proxy allowlist does
  not show that route.
- `RolesHierarchySessionsAdminGateway` has list, move org unit, move location,
  and sessions. It does not expose create/edit/delete/suspend org unit.
- `OperatorLocationAdminGateway` has location add/patch/remove through
  `/v1/admin/locations`.
- `LocationsRepository.insertLocation` inserts no `parent_org_unit_id`, while
  hierarchy wiring makes `locations.parent_org_unit_id` not-null. Onboarding is
  safe because `OperatorsRepository.onboardOperatorAtomically` creates a root
  org unit and inserts the primary location with `parent_org_unit_id`.

Implementation needed:

- Choose canonical routes:
  - create org unit
  - move org unit
  - rename/edit org unit
  - suspend/archive/delete org unit
  - add location under selected org unit
  - move location
  - edit location
  - suspend/archive/delete location
- Extend repository/schema for lifecycle semantics if product chooses
  suspend/archive instead of hard delete.
- Extend location create command/gateway/proxy/repository with
  `parent_org_unit_id` or a safe root default.
- Replace the flat Locations list in Business Accounts with the hierarchy tree.
- Do not expose delete/suspend/archive buttons until backend semantics and audit
  behavior are real.

Tests to add/update:

- Proxy auth route tests for create/move/edit/delete org unit as implemented.
- Admin gateway tests for hierarchy CRUD.
- Repository tests for parent org-unit location creation.
- Migration tests for lifecycle columns if added.
- Screen tests for add/move/edit/delete affordances and disabled read-only
  states.

### 5. People, Access, Roles, and Permission Explainer

Current code:

- `auth_invites`, `user_roles`, and effective location triggers support
  `operator_wide`, `org_unit`, and `location`.
- Admin route handling supports users, invites, roles, role grants, sessions, and
  audit log.
- Members, role policy, hierarchy, and active sessions are split across
  `MembersAdminScreen`, `RolesHierarchySessionsAdminScreen`, and Support
  Workspace.

Implementation needed:

- Create one People/access/roles surface selected through the hierarchy prompt.
- Merge members, pending invites, role grants, role policy, and permission
  explainer into one readable flow.
- Keep role inheritance copy explicit:
  - business-level grant applies everywhere unless a more specific grant changes
    what a user can do at a lower scope
  - org-unit grant applies to that branch
  - location grant applies only to that location
- Preserve location_manager and other read-only behavior.
- Show forbidden/disabled states before mutation, with exact permission reason.

Tests to add/update:

- Role/auth behavior tests for `operator_owner`, `operator_admin`,
  `location_manager`, `ff_support`, and forbidden users.
- Invite tests for `scope_type`, `org_unit_id`, and `location_id`.
- Permission explainer widget tests for inherited and local grants.

### 6. Security, Audit, and Sessions

Current code:

- `AuditedSupportActionsAdminScreen` covers security/audit actions.
- Active sessions currently live under `RolesHierarchySessionsAdminScreen`.
- Session force logout exists in `RolesHierarchySessionsAdminGateway`.
- Audit log reads and CSV export exist in admin support action plumbing.

Implementation needed:

- Move active sessions into Security/audit/sessions.
- Keep MFA reset, password reset, force logout, erasure, export, and audit log
  under one scoped surface.
- Keep every mutation gated by role, confirmation copy, admin reason, and
  idempotency.
- Make read-only state clear for `ff_support` or non-mutating staff roles.

Tests to add/update:

- Audited support screen tests for sessions coexisting with audit/security.
- Proxy tests for session revoke and audit events.
- Forbidden/self-revoke tests.

### 7. Data Accuracy

Current code:

- `data_accuracy_settings` and `data_accuracy_service_period_settings` are keyed
  by `operator_id` and `location_id`.
- `DataAccuracyAdminGateway` describes a per-location admin surface.
- Proxy routes use operator/location pairs for settings, tier assignments, audit
  history, margin, and change requests.

Implementation needed:

- Add hierarchy-scoped storage or a compatible scoped overlay:
  - `scope_type`
  - `scope_id`
  - effective date where needed
  - audit metadata
- Add an effective resolver that can answer:
  - selected scope
  - local value
  - inherited source
  - effective value at a target location/business date/service period
- Keep existing location routes working during migration.
- For business/org-unit selection, do not pretend a single location row is a
  business-level setting.

Tests to add/update:

- Migration/repository tests for scoped data accuracy settings.
- Proxy tests for effective inherited settings and local override writes.
- Admin screen tests for inherited source labels.
- Operator web parity tests for effective value display.

### 8. Polling and Pricing

Current code:

- `forge_flow_polling_tier_assignment` is per operator/location.
- Admin routes and screens support tier definitions, assignments, margin, and
  change requests against location rows.

Implementation needed:

- Add hierarchy-scoped tier assignment/effective resolver, or keep business and
  org-unit scopes read-only until that exists.
- Preserve F&F-only mutation gates for pricing and cadence decisions.
- Show inherited tier, inherited source, local override, and effective margin.
- Make change request history scope-aware.

Tests to add/update:

- Repository/migration tests for scoped tier assignment.
- Proxy route tests for business/org-unit/location effective assignment.
- Admin screen tests for read-only inherited state and local override state.

### 9. Timing and Timezone

Current code:

- `business_timing_profiles` already has `scope_type` values:
  `operator`, `org_unit`, `location`.
- `BusinessTimingProfileResolver` expects candidates in hierarchy order and lets
  lower profiles override higher profiles field-by-field.
- `BusinessTimingProfilesRepository` lists profiles in resolver-precedence order.
- Operator web has `/v1/operator/business-timing-profiles` gateway/routes.
- Admin Business Accounts currently has a simple location timing dialog for
  timezone/rollover, not the full timing profile editor.

Implementation needed:

- Build the admin Timing tile on top of existing business timing profile
  plumbing.
- Include timezone in Timing, while respecting that timezone is currently stored
  on location/account-related data and is also used by business date logic.
- Decide whether timezone can be inherited at business/org-unit scope or whether
  only service-period profile settings inherit while timezone stays
  location-specific.
- Add admin route/gateway support if the current timing write routes are only
  operator-web/self-service.

Tests to add/update:

- Admin timing route/gateway tests.
- Resolver tests confirming lowest scope wins.
- Screen tests for timezone plus service-period editing.
- Proxy tests for role-gated admin timing mutations.

### 10. Vendor Integrations

Current code:

- `tool/advisor_proxy/admin_integrations_routes.dart` provides location-bound
  admin integration routes:
  - list per location
  - OAuth start/callback
  - API key connect
  - test connection
  - disconnect
  - sync logs
- Permission gate requires `integrations.configure`; copy explicitly says
  location_manager and roles without that key cannot configure.
- `VendorConnectionsAdminMount` shows a not-wired/read-only panel if no gateway
  is injected.
- OAuth state is operator/location/vendor-bound.

Implementation needed:

- Keep edit controls location-only.
- Use business/org-unit selection only to narrow the location list before
  opening edit controls.
- Wire a production admin `VendorConnectionsGateway` to the admin integration
  routes if lifecycle actions should be live in the consolidated UX.
- If the gateway remains absent, the UI must say not routed/read-only and avoid
  demo data.

Tests to add/update:

- Admin vendor mount tests with real gateway injection.
- Proxy integration route tests for `integrations.configure` and forbidden
  location_manager.
- OAuth state/location mismatch tests if touched.

### 11. Support Logs

Current code:

- `AdminSupportLogFilterIntent` is operator/location only.
- Business Accounts can open logs with operator-only or location-specific
  filters.

Implementation needed:

- Add support-log filter shape for business/org-unit/location.
- For org-unit scope, either expand to covered locations client-side/server-side
  or add an aggregate route filter by org-unit.
- Preserve bounded list, pagination, and refresh behavior.

Tests to add/update:

- Support log filter tests for scope cache keys.
- Proxy/log route tests for org-unit expansion if implemented server-side.
- Performance tests for bounded scoped log queries.

### 12. Support Workspace Removal

Current code:

- `SupportOperatorViewAdminScreen` is a visible four-tab surface with People,
  Access, Security & audit, and Vendors.
- Business Accounts exposes Support view buttons at business and location level.
- `kAdminSupportOperatorViewRouteId` is titled `Support workspace`.

Implementation needed:

- Remove Support Workspace as a visible route/button after replacement surfaces
  are live.
- Decide whether old deep links redirect to the new Business Accounts workspace
  with a selected scope, or remain hidden temporarily.
- Update tests that assert `Support workspace` copy.

Tests to add/update:

- Admin route tests for hidden/redirect behavior.
- Screen tests ensuring no visible Support Workspace tile/button remains.

### 13. Audit, Idempotency, and Role Gates

Current code:

- Many proxy/admin routes already require idempotency keys and admin reasons.
- Some gateway methods enforce `actorIsForgeAdmin` client-side as defense in
  depth.
- Route-level permission checks exist for auth operations and integrations.

Implementation needed:

- Keep all new mutations aligned with:
  - required permission key
  - exact disabled state in UI
  - confirmation copy for destructive or broad-scope actions
  - admin reason
  - idempotency key
  - audit event
- Add route tests for every new mutation and every forbidden role path.

Tests to add/update:

- Proxy tests for missing idempotency, missing reason, forbidden role, and happy
  path audit event.
- Flutter tests for disabled actions and confirmation copy.

### 14. Performance and UX Simplicity

Current code:

- `HttpRolesHierarchySessionsAdminGateway` coalesces in-flight hierarchy loads
  by operator.
- Separate screens still fetch their own location/operator/member/access data.
- Scope selection is not centralized.

Implementation needed:

- Centralize selected business/hierarchy scope so route switching does not
  refetch everything.
- Use one hierarchy snapshot for the Business Accounts tree and scope prompt.
- Bound lists and paginate audit/log/session data.
- Avoid repeated location list loads when moving between tiles.
- Preserve mobile responsiveness and scanability:
  - one selected business
  - one hierarchy panel
  - one setup tile grid
  - one scope prompt
  - one focused settings screen at a time

Tests to add/update:

- Flutter performance probe for route switching and duplicate requests.
- Browser Use verification with console logs and cache-bust URL.
- Scroll/filter/refresh tests for bounded lists.

## Implementation Order Recommendation

1. Add shared `AdminHierarchyScopeIntent` and scope prompt.
2. Replace Business Accounts IA: no `Click to manage`, eight setup tiles, and a
   hierarchy-first detail area.
3. Reconcile hierarchy route contracts and add missing create/move/edit
   gateway methods.
4. Fix location create so new locations always attach to an org unit.
5. Consolidate People/access/roles and Security/audit/sessions without adding
   new setting schema.
6. Wire Timing admin support, because timing already has scoped schema.
7. Add scoped Data accuracy and Polling/pricing schema/resolvers.
8. Wire location-only Integrations through the hierarchy prompt.
9. Remove/hide Support Workspace entry points.
10. Run full admin/proxy/operator web tests, Browser Use, and performance probes
    before preview deployment.

## Residual Product Decisions

- Does "delete" mean hard delete, suspend, archive, or remove from hierarchy for
  org units and locations?
- Should timezone inherit at business/org-unit scope, or stay location-only?
- Should business contact email be globally unique, operator-unique, or only
  blocked for owner/contact roles while Forge & Flow staff can access many
  businesses?
- During migration, should Support Workspace redirect to Business Accounts or
  stay as a hidden fallback?
- Should Data accuracy and Polling/pricing ship only after true scoped schema is
  added, or first as location-only with clear disabled business/org-unit states?

## Third-Pass Coverage Lens Notes

The final coverage lens pass added the following no-miss items to the main plan:

- `locations.parent_org_unit_id` is non-null after hierarchy migration, but the
  current flat admin add-location repository path does not pass a parent org
  unit.
- `org_units` has hierarchy structure but no active/suspended/archived lifecycle
  columns, so destructive delete/suspend/archive controls must not be exposed
  until lifecycle plumbing exists.
- Admin hierarchy gateway move URLs currently differ from the proxy routes
  inspected in `tool/advisor_proxy/advisor_proxy.dart`; route contracts need
  exact method/path/body tests before live UI claims.
- `operator_admins` supports one F&F staff user across multiple businesses; do
  not block that with a blanket one-email rule.
- Timing already implements the hierarchy inheritance model and should be the
  reference implementation for Data accuracy, Polling/pricing, Notifications,
  and any other future scoped setting.
- Data accuracy and polling tier assignments are still location-only, while
  usage caps have partial org-unit columns underneath. Treat those as separate
  implementation tracks.
- Notification preferences currently support operator/location, not org-unit.
- Preview DB-safe startup mode is implemented and tested, but mutation testing
  still depends on whether the preview database is data-isolated or shares
  staging data.

## Verification Matrix

Minimum targeted tests before preview deployment:

- `flutter analyze`
- `flutter test test/admin/operator_location_admin_gateway_test.dart`
- `flutter test test/admin/screens/operator_location_admin_screen_test.dart`
- `flutter test test/admin/services/roles_hierarchy_sessions_admin_gateway_test.dart`
- `flutter test test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart`
- `flutter test test/admin/services/members_admin_gateway_test.dart`
- `flutter test test/admin/screens/members_admin_screen_test.dart`
- `flutter test test/admin/services/audited_support_actions_admin_gateway_test.dart`
- `flutter test test/admin/screens/audited_support_actions_admin_screen_test.dart`
- `flutter test test/admin/vendor_connections_admin_mount_test.dart`
- `flutter test test/proxy_auth_operations_route_test.dart`
- `flutter test test/proxy_auth_operations_route_grants_test.dart`
- `flutter test test/proxy/business_scope_routes_test.dart`
- `flutter test test/proxy/data_accuracy_admin_routes_test.dart`
- `flutter test test/proxy/operator_business_timing_routes_test.dart`
- `flutter test test/phase_9_hierarchy_access_wiring_test.dart`
- Repository/migration tests for any new hierarchy-scoped settings tables.
- Browser Use pass on preview with console logs, route-by-route evidence, and
  mobile viewport checks.
- Performance probe with duplicate request, route switching, refresh, bounded
  list, and startup budgets.

## Plain-English Risk Summary

The desired UI is right, but it cannot be implemented as only a Flutter
rearrangement. The admin console currently knows how to manage businesses,
flat locations, people, roles, sessions, audit, and some hierarchy moves. It
does not yet have one shared hierarchy scope flowing through every tab, and
several settings are still location-only in the database. The safest path is to
make scope selection a real primitive first, then move the already-wired
features into the simpler IA, and only then expose business/org-unit edits for
settings whose backend actually resolves inheritance.
