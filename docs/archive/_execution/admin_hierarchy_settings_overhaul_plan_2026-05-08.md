# Admin Hierarchy Settings Overhaul Plan

Status: planned
Source branch: `codex/admin-hierarchy-settings-overhaul-plan`
Source commit inspected: `bed55889 fix(proxy): defer preview db startup (#375)`
Created: 2026-05-08
Deep plumbing audit: folded into this plan; companion note at
`docs/_execution/admin_hierarchy_settings_deep_plumbing_audit_2026-05-08.md`
Implementation packet:
`docs/_execution/admin_hierarchy_settings_overhaul/README.md`

## Goal

Make the admin console and operator support flow match Forge & Flow's real
business hierarchy. A staff user should choose a business, choose the hierarchy
scope they are managing, and then see simple, readable, functional settings at
that scope. The UI must stop scattering the same concepts across Business
Accounts, Support Workspace, flat location rows, Access, Security, and one-off
dialogs.

## Plan Index

Read this plan in this order during implementation:

1. Non-negotiable hierarchy rule and target IA.
2. Current product observations and existing end-to-end plumbing.
3. Deep plumbing audit and execution plan.
4. Second-pass deep audit addendum.
5. Third-pass coverage lens audit.
6. Residual product decisions.
7. New-session execution prompt.

For execution, use the separated packet under
`docs/_execution/admin_hierarchy_settings_overhaul/`. It splits this plan into
product IA, plumbing audit, execution slices, verification/deploy, and a
paste-ready Codex prompt.

## Non-Negotiable Rule

Every setting resolves through the hierarchy:

`business/operator default -> org-unit ancestors from root to leaf -> location`

The lowest configured scope wins. If a lower scope has no value, it inherits
from the nearest ancestor. Every settings surface must show:

- selected scope
- whether the value is inherited or set locally
- inherited source when inherited
- effective value
- mutation requirements such as role, audit reason, idempotency key, and
  confirmation copy

Integrations are the exception for edit scope. They should still use the
hierarchy prompt to find the right context, but edits are allowed only at the
location level because vendor credentials and OAuth state are location-bound.

## Current Product Observations

The live admin console currently has a Business Accounts tab with a left-side
business list and a repeated `Click to manage` button. Selecting a business
shows a Business setup card, a flat Locations section, and many repeated
per-location buttons. This makes the user decide from too many entry points.

The live Location hierarchy screen under Support Workspace shows the tree and
allows move actions, but it does not expose full add, delete, suspend, and edit
flows in the hierarchy itself. That is why the current screen feels like a
viewer plus partial organizer instead of the canonical business management
surface.

The share preview at
`https://forge-flow-admin-share-preview-rf7nosnoka-pd.a.run.app/?v=e89100d8`
communicates the desired direction visually, but it is still a preview shell.
The implementation needs to be grounded in existing routes, role checks,
migrations, and audit contracts.

## What Already Has End-to-End Plumbing

| Area | Existing plumbing | Current limitation |
|---|---|---|
| Business account profile | Admin routes and `OperatorLocationAdminGateway` can list, onboard, patch, suspend, and reactivate operators through `/v1/admin/operators`. Operator web has account profile routes through `/v1/operator/account`. | Admin Business setup tile is not yet the single editable account profile entry point. Owner email/contact email language needs one consistent label. |
| Basic location CRUD | Admin gateway can add, patch, and remove locations through `/v1/admin/locations`. | CRUD lives in the flat Business Accounts location rows, not inside the hierarchy manager. Suspend/archive semantics need confirmation before replacing delete. |
| Hierarchy list and moves | Postgres `org_units` uses `ltree`. Admin/operator hierarchy routes list org units and locations. Move org unit and move location routes exist. Operator web already exposes hierarchy organization patterns. | Admin hierarchy does not expose create org unit despite backend POST support, and does not expose delete/suspend/edit in-tree. Location CRUD is split across another gateway/screen. |
| Members and invites | Admin and operator web user gateways support lists, invites, reset password, MFA reset, suspend/reactivate, soft delete, force logout, and invite revoke. | Admin UX is split across People, Access, Security, and Support Workspace instead of one scoped People/access flow plus one scoped Security/audit flow. |
| Roles and grants | Role policies, role grants, custom roles, org-unit/location scope fields, and role explainer plumbing exist across proxy, repositories, and admin/operator gateways. | The UI needs one hierarchy scope prompt and clear effective access copy. Migration constraints for org-unit role scope should be re-verified before implementation. |
| Active sessions | Admin sessions route and gateway exist, and operator web has own/team session management. | Sessions currently live under Access/Support Workspace; target UX moves them into Security, audit, and sessions. |
| Audit/security support actions | Admin audit log, export, MFA reset, password reset, erasure, and audited support actions exist. | Needs to be grouped with sessions and scoped through the hierarchy prompt. |
| Vendor connections | Admin and operator web vendor connection routes exist per operator/location. OAuth state is location-bound. | This should stay location-editable only, but the UX should use hierarchy selection to find/narrow locations. |
| Support logs | Admin debug/support log routes exist and can filter by operator/location. | Business/org-unit scope needs expansion into covered locations so staff can filter by hierarchy scope. |
| Timing foundation | Business timing live docs and operator web timing profile plumbing already use the hierarchy inheritance rule. | Admin support editing is still not a simple scoped tile, and timezone needs to be included in the same Timing surface. |
| Data accuracy | Admin/operator routes and screens exist for wage source, cover source, manual entries, and service-period settings. | Current contract is per operator/location. Needs hierarchy-scoped settings storage/resolution before business and org-unit settings can be real. |
| Polling and pricing | Admin routes exist for tier definitions, assignments, margin, and change requests. | Current assignment model is per operator/location. Needs hierarchy-scoped effective assignment resolution before inherited business/org-unit settings can be real. |

## Target Information Architecture

Business Accounts becomes the front door:

1. Select a business from the list. Remove `Click to manage`; row selection is
   the interaction.
2. The detail view shows the full location hierarchy, not a flat Locations list.
3. The hierarchy panel supports add, move, edit, suspend/archive, and delete
   where backend contracts allow it.
4. Business setup becomes a concise grid of scoped actions:
   - Account profile
   - Data accuracy
   - Polling and pricing
   - People, access, and roles
   - Security, audit, and sessions
   - Support logs
   - Integrations
   - Timing
5. Support Workspace stops being a primary tab/button. Its useful capabilities
   are redistributed into the scoped actions above.

## Scope Prompt Pattern

Every scoped tile opens the same hierarchy prompt before showing settings:

- Business: applies to the whole operator unless a lower scope overrides it.
- Org unit: applies to that branch unless child org units or locations override
  it.
- Location: applies only to one location.

The prompt should show effective status in plain English:

- `Inherited from business`
- `Set at Northeast Region`
- `Overridden at Downtown`
- `Location only`

For integrations, business and org-unit selection should narrow the list of
locations, then require a location before edit controls are enabled.

## Deep Plumbing Audit

This implementation is not only a Flutter rearrangement. It crosses schema,
repositories, proxy routes, admin gateways, route handoff, operator web parity,
mobile scope assumptions, tests, and preview verification. The plan below must
be treated as the implementation checklist.

| Area | Audit result | Must not miss |
|---|---|---|
| Shared scope model | Current admin route handoff and picker are operator/location only. | Add a first-class hierarchy scope object with `business`, `org_unit`, and `location`. |
| Business scope routes | Mobile/business scope plumbing can list accessible locations, and global staff can list all locations. It does not currently return business or org-unit selectable rows. | Extend scope list payloads so support/admin users can choose business and org-unit scopes, not only locations. |
| Business account profile | Admin operator CRUD is live through `/v1/admin/operators`. UI already labels some fields as Contact email, but models/routes still use `owner_email`. | Keep DB/API compatibility, but normalize UI copy to Contact email everywhere business contact is meant. |
| Hierarchy tree | Org-unit list, org-unit create, and location move exist in proxy/auth plumbing. The admin screen shows list and move only. | Wire create org unit to the admin gateway/screen; add missing edit/delete/suspend/archive contracts before exposing those buttons. |
| Org-unit move route | Admin gateway posts to `/v1/admin/auth/org-units/:id/move`, but proxy handling inspected here only shows `POST /v1/admin/auth/org-units` and `PATCH /v1/admin/auth/locations/:id/org-unit`. | Reconcile the route contract before relying on org-unit move in production UI. |
| Add location in hierarchy | Flat add-location route does not send `parent_org_unit_id`; `locations.parent_org_unit_id` is not-null after hierarchy wiring. | Extend admin location create command/proxy/repository to require or safely default an org-unit parent. |
| Location lifecycle | Current location admin path supports patch and hard delete. There is no separate suspend/archive lifecycle in the repository inspected here. | Decide product lifecycle semantics before showing Suspend/Archive/Delete in the hierarchy tree. |
| Data accuracy | Current schema, repo, routes, and admin screens are per operator/location. | Add hierarchy-scoped settings storage and effective resolver before business/org-unit editing can be real. |
| Polling and pricing | Current polling tier assignment model is per operator/location. | Add scoped assignment/effective resolution or keep higher scopes read-only until wired. |
| Timing | Business timing schema/repository already use `operator`, `org_unit`, and `location` scopes and resolver-precedence ordering. | Build the admin scoped timing surface and include timezone, which still lives on location/account fields. |
| People/access/roles | Role grants and invites support operator-wide, org-unit, and location scopes. Members, role policy, hierarchy, and sessions are split across screens. | Merge People/access/roles around the shared hierarchy scope prompt and permission explainer. |
| Security/audit/sessions | Audit/security actions are admin-backed; active sessions are currently in the Access screen. | Move sessions into Security/audit/sessions and keep support actions audited/gated. |
| Support workspace | Current `SupportOperatorViewAdminScreen` is a primary four-tab concept: People, Access, Security & audit, Vendors. | Remove it as a visible IA concept after its capabilities are redistributed; keep a hidden redirect/fallback only if needed. |
| Vendor integrations | Per-location admin integration routes exist and enforce `integrations.configure`; current admin mount often renders a not-wired/read-only panel when no gateway is injected. | Wire a real admin vendor gateway if lifecycle actions are desired; never fake business/org-unit edit controls. |
| Support logs | Current support log handoff filters operator/location only. | Expand a business/org-unit selected scope into covered locations for log filtering, or add a scoped aggregate route. |
| Performance | Some hierarchy requests are coalesced, but selected scope and screen route switching are not centralized. | Use a shared scope cache and avoid duplicate list calls when moving between tiles. |

## Required Plumbing Checklist

### 1. Shared Hierarchy Scope

Current code:

- `lib/admin/admin_route_handoff.dart` defines
  `AdminOperatorLocationScopeIntent` with only `operatorId`, optional
  `locationId`, names, and a cache key.
- `lib/admin/screens/operator_picker_screen.dart` returns
  `OperatorPickerResult` with one required location.
- Business Accounts creates route intents from a primary or selected location,
  not from an arbitrary business/org-unit/location scope.

Implementation required:

- Add `AdminHierarchyScopeIntent` or equivalent with:
  - `operatorId`
  - `scopeType`: `business`, `org_unit`, `location`
  - `orgUnitId`
  - `locationId`
  - display names/path
  - inherited/effective metadata where available
  - stable cache key
- Replace or adapt route handoff paths that currently assume
  `AdminOperatorLocationScopeIntent`.
- Build one hierarchy scope prompt used by Data accuracy, Polling and pricing,
  People/access/roles, Security/audit/sessions, Support logs, Integrations, and
  Timing.
- Keep location-only fallbacks during migration only where routes require a
  location.

Tests:

- Admin route handoff tests for business, org-unit, and location scopes.
- Scope prompt widget tests for inherited/local/effective labels.
- Route switching tests confirming selected scope survives tab changes.

### 2. Business and Staff Scope Access

Current code:

- `tool/advisor_proxy/business_scope_routes.dart` exposes:
  - `GET /v1/users/:user_id/business_scopes`
  - `GET /v1/operators/:operator_id/business_scopes`
- Global roles `super_admin` and `ff_support` can list all location scopes.
- `RepositoryBusinessScopeProxyGateway` expands operator-wide and org-unit
  grants into location rows only.

Implementation required:

- Return operator/business rows and org-unit rows in addition to location rows
  for staff/admin scope selection.
- Preserve location expansion for mobile runtime if mobile needs a concrete
  active location.
- Define how Forge & Flow staff users differ from business owner/contact emails:
  staff should access many businesses; business contact uniqueness should not
  block staff support accounts.
- If an email already exists, expose a read-only "where used" lookup so an admin
  can decide whether to revoke, reuse, or choose another contact.

Tests:

- `test/proxy/business_scope_routes_test.dart` for operator and org-unit rows.
- Business scope repository tests for multi-business Forge & Flow staff.
- Forbidden tests for non-staff users requesting other businesses.

### 3. Business Accounts and Account Profile

Current code:

- `lib/admin/screens/operator_location_admin_screen.dart` still shows
  `Click to manage` on unselected business rows.
- The selected business card has top action buttons for Support view, Data
  accuracy, Polling & pricing, and View logs, plus Edit/Suspend.
- `_BusinessSetupCard` currently has Account profile, Primary location, Support
  workspace, People, Access, Data, Security & audit, Polling & pricing.
- `OperatorLocationAdminGateway` supports list/onboard/patch/suspend/reactivate
  through `/v1/admin/operators`.

Implementation required:

- Remove `Click to manage`; selecting the row is the action.
- Make Account profile the only edit entry point for business account fields.
- Use Contact email in all UI copy for business contact fields. Keep wire field
  `owner_email` until an API/data migration is intentionally scheduled.
- Replace Business setup tiles with exactly:
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

Tests:

- Business Accounts screen tests for no `Click to manage`.
- Account profile dialog tests for Contact email copy.
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

Implementation required:

- Choose canonical routes for:
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

Tests:

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
- Admin route handling supports users, invites, roles, role grants, sessions,
  and audit log.
- Members, role policy, hierarchy, and active sessions are split across
  `MembersAdminScreen`, `RolesHierarchySessionsAdminScreen`, and Support
  Workspace.

Implementation required:

- Create one People/access/roles surface selected through the hierarchy prompt.
- Merge members, pending invites, role grants, role policy, and permission
  explainer into one readable flow.
- Keep role inheritance copy explicit:
  - business-level grant applies everywhere unless a more specific grant changes
    what a user can do at a lower scope
  - org-unit grant applies to that branch
  - location grant applies only to that location
- Preserve location_manager and other read-only behavior.
- Show forbidden/disabled states before mutation, with the exact permission
  reason.

Tests:

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

Implementation required:

- Move active sessions into Security/audit/sessions.
- Keep MFA reset, password reset, force logout, erasure, export, and audit log
  under one scoped surface.
- Keep every mutation gated by role, confirmation copy, admin reason, and
  idempotency.
- Make read-only state clear for `ff_support` or non-mutating staff roles.

Tests:

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

Implementation required:

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

Tests:

- Migration/repository tests for scoped data accuracy settings.
- Proxy tests for effective inherited settings and local override writes.
- Admin screen tests for inherited source labels.
- Operator web parity tests for effective value display.

### 8. Polling and Pricing

Current code:

- `forge_flow_polling_tier_assignment` is per operator/location.
- Admin routes and screens support tier definitions, assignments, margin, and
  change requests against location rows.

Implementation required:

- Add hierarchy-scoped tier assignment/effective resolver, or keep business and
  org-unit scopes read-only until that exists.
- Preserve F&F-only mutation gates for pricing and cadence decisions.
- Show inherited tier, inherited source, local override, and effective margin.
- Make change request history scope-aware.

Tests:

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

Implementation required:

- Build the admin Timing tile on top of existing business timing profile
  plumbing.
- Include timezone in Timing, while respecting that timezone is currently stored
  on location/account-related data and is used by business date logic.
- Decide whether timezone can inherit at business/org-unit scope or whether only
  service-period profile settings inherit while timezone stays
  location-specific.
- Add admin route/gateway support if current timing write routes are only
  operator-web/self-service.

Tests:

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
- Permission gate requires `integrations.configure`; location_manager and roles
  without that key cannot configure.
- `VendorConnectionsAdminMount` shows a not-wired/read-only panel if no gateway
  is injected.
- OAuth state is operator/location/vendor-bound.

Implementation required:

- Keep edit controls location-only.
- Use business/org-unit selection only to narrow the location list before
  opening edit controls.
- Wire a production admin `VendorConnectionsGateway` to the admin integration
  routes if lifecycle actions should be live in the consolidated UX.
- If the gateway remains absent, the UI must say not routed/read-only and avoid
  demo data.

Tests:

- Admin vendor mount tests with real gateway injection.
- Proxy integration route tests for `integrations.configure` and forbidden
  location_manager.
- OAuth state/location mismatch tests if touched.

### 11. Support Logs

Current code:

- `AdminSupportLogFilterIntent` is operator/location only.
- Business Accounts can open logs with operator-only or location-specific
  filters.

Implementation required:

- Add support-log filter shape for business/org-unit/location.
- For org-unit scope, either expand to covered locations client-side/server-side
  or add an aggregate route filter by org-unit.
- Preserve bounded list, pagination, and refresh behavior.

Tests:

- Support log filter tests for scope cache keys.
- Proxy/log route tests for org-unit expansion if implemented server-side.
- Performance tests for bounded scoped log queries.

### 12. Support Workspace Removal

Current code:

- `SupportOperatorViewAdminScreen` is a visible four-tab surface with People,
  Access, Security & audit, and Vendors.
- Business Accounts exposes Support view buttons at business and location level.
- `kAdminSupportOperatorViewRouteId` is titled `Support workspace`.

Implementation required:

- Remove Support Workspace as a visible route/button after replacement surfaces
  are live.
- Decide whether old deep links redirect to the new Business Accounts workspace
  with a selected scope, or remain hidden temporarily.
- Update tests that assert `Support workspace` copy.

Tests:

- Admin route tests for hidden/redirect behavior.
- Screen tests ensuring no visible Support Workspace tile/button remains.

### 13. Audit, Idempotency, and Role Gates

Current code:

- Many proxy/admin routes already require idempotency keys and admin reasons.
- Some gateway methods enforce `actorIsForgeAdmin` client-side as defense in
  depth.
- Route-level permission checks exist for auth operations and integrations.

Implementation required:

- Keep all new mutations aligned with:
  - required permission key
  - exact disabled state in UI
  - confirmation copy for destructive or broad-scope actions
  - admin reason
  - idempotency key
  - audit event
- Add route tests for every new mutation and every forbidden role path.

Tests:

- Proxy tests for missing idempotency, missing reason, forbidden role, and happy
  path audit event.
- Flutter tests for disabled actions and confirmation copy.

### 14. Performance and UX Simplicity

Current code:

- `HttpRolesHierarchySessionsAdminGateway` coalesces in-flight hierarchy loads
  by operator.
- Separate screens still fetch their own location/operator/member/access data.
- Scope selection is not centralized.

Implementation required:

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

Tests:

- Flutter performance probe for route switching and duplicate requests.
- Browser Use verification with console logs and cache-bust URL.
- Scroll/filter/refresh tests for bounded lists.

## Implementation Order

1. Add shared `AdminHierarchyScopeIntent` and scope prompt.
2. Replace Business Accounts IA: no `Click to manage`, eight setup tiles, and a
   hierarchy-first detail area.
3. Reconcile hierarchy route contracts and add missing create/move/edit gateway
   methods.
4. Fix location create so new locations always attach to an org unit.
5. Consolidate People/access/roles and Security/audit/sessions without adding
   new setting schema.
6. Wire Timing admin support, because timing already has scoped schema.
7. Add scoped Data accuracy and Polling/pricing schema/resolvers.
8. Wire location-only Integrations through the hierarchy prompt.
9. Remove/hide Support Workspace entry points.
10. Run full admin/proxy/operator web tests, Browser Use, and performance probes
    before preview deployment.

## Execution Lanes

### Lane 0 - Authority and Contracts

- Keep the hard rule in `PROJECT_TRACKER.md`, `CLAUDE.md`,
  `docs/contracts/core_app_architecture.md`, and `docs/ARCHITECTURE.md`.
- Add or update a durable settings-scope contract before schema work begins.
- Define whether delete means hard delete, soft delete, archive, or suspend for
  org units and locations. Default should be suspend/archive when history or
  external integrations exist.

### Lane 1 - Shared Scope Model

- Create one shared hierarchy scope model for admin and operator web:
  `business`, `org_unit`, `location`.
- Add common copy for inherited/set/overridden/effective values.
- Add role checks that evaluate the selected scope.
- Add route payload shape for scoped mutations:
  `operator_id`, `scope_type`, `org_unit_id`, `location_id`, `audit_reason`,
  `idempotency_key`.

### Lane 2 - Backend Resolution

- Implement or centralize a settings resolver that returns the effective value
  and source scope.
- Start with timing if needed, then extend to data accuracy and polling/pricing.
- Add migrations for hierarchy-scoped settings where current tables are
  location-only.
- Keep existing location-level routes working while adding scoped endpoints or
  compatibility wrappers.

### Lane 3 - Hierarchy CRUD in Admin

- Move full hierarchy management into Business Accounts selected detail.
- Reuse existing admin/operator hierarchy patterns for list and move.
- Wire create org unit through existing backend POST support.
- Add missing backend and repository support for org-unit edit and
  suspend/archive/delete if contract-approved.
- Move location add/edit/remove into the tree using existing location admin
  routes, then extend payloads if location creation needs `org_unit_id`.
- Audit every hierarchy mutation as a Forge & Flow admin support action.

### Lane 4 - Business Setup Tiles

- Replace the old Business setup card and flat location action buttons with the
  target eight actions.
- Make Account profile directly editable for business setup fields.
- Rename owner email language to contact email wherever this surface talks about
  the business contact rather than auth ownership.
- Remove visible Support Workspace entry points after its capabilities are
  redistributed.

### Lane 5 - Surface Consolidation

- People, access, and roles:
  members, invites, role policy, permission explainer, role grants, and scoped
  access summary.
- Security, audit, and sessions:
  MFA/password/security actions, active sessions, audit log, export, and support
  action history.
- Data accuracy:
  wage source, covers source, manual entry policy, service-period overrides,
  effective source.
- Polling and pricing:
  tier assignment, margin context, change request history, effective tier.
- Timing:
  business hours, service periods, closures/overrides, timezone.
- Support logs:
  scoped support logs and request history.
- Integrations:
  location-only edit controls with hierarchy-assisted location selection.

### Lane 6 - Tests and Verification

- Add proxy route tests for scoped resolution, role enforcement, audit reason,
  idempotency, forbidden users, and inherited/effective responses.
- Add repository/migration tests for hierarchy-scoped settings and delete or
  archive semantics.
- Add Flutter admin screen tests for Business Accounts selection, hierarchy CRUD
  affordances, scope prompt copy, and redistributed tiles.
- Add operator web parity tests where the same settings are visible to
  operators.
- Run Browser Use against preview with cache-bust URLs after deployment.
- Run performance probes for startup, route switching, duplicate requests,
  refresh, scrolling, filters, and repeated navigation.

## Acceptance Criteria

- Business Accounts has no `Click to manage` button.
- Selecting a business shows a hierarchy-first management view.
- Full hierarchy operations are visible only when the backend and role checks
  support them.
- Every settings tile prompts for business/org-unit/location scope before
  showing scoped settings.
- Every settings screen shows selected scope, inherited source, and effective
  value.
- Integrations cannot be edited above location scope.
- Support Workspace is no longer a primary user-facing concept.
- People/access/roles and Security/audit/sessions are readable, grouped, and
  not duplicated.
- Mutations require the right role, disabled states, confirmation copy, audit
  reason where required, and idempotency keys.
- Location manager and other read-only users keep read-only behavior.
- Preview deployment evidence includes admin console URL, proxy URL, source
  commit, database mode, Browser Use screenshots/logs, tests, and performance
  JSON.

## Second-Pass Deep Audit Addendum

This second pass checked surfaces that are easy to miss because they sit behind
shared route handoff, demo fallbacks, invite delivery, mobile scope plumbing, or
global admin tools rather than the visible Business Accounts cards.

### Admin Route Handoff Gaps

Current code:

- `AdminRouteHandoff` carries `AdminOperatorLocationScopeIntent` only:
  `operatorId`, optional `locationId`, labels, and a cache key.
- `AdminShell._routeUsesOperatorScope` keys selected route rebuilds only for a
  subset of routes: Data accuracy, Polling/pricing, Support workspace, People,
  Access, and Security/audit.
- `_pickerResultFromScope` returns null unless a `locationId` exists, so route
  shells that use the picker cannot start from a business-wide or org-unit
  scope.
- Members intentionally keys by `operatorId` only and preserves table state even
  when the picker carries a different `locationId`.

Implementation impact:

- Replace `AdminOperatorLocationScopeIntent` with a true
  `AdminHierarchyScopeIntent` that supports `business`, `org_unit`, and
  `location`.
- Route handoff must include every target tile that should respect hierarchy
  scope: Account profile, Data accuracy, Polling/pricing, People/access/roles,
  Security/audit/sessions, Support logs, Integrations, and Timing.
- Picker output must no longer be "operator plus required location". It should
  return a selected hierarchy node and, only for location-only surfaces, require
  a location before enabling edits.
- Support logs need to move from the separate `AdminSupportLogFilterIntent`
  model into the same hierarchy-scope model so business/org-unit rollups can be
  queried consistently.

Tests to add:

- Admin shell route handoff test that preserves business/org-unit/location
  scope while moving across all target setup tiles.
- Picker tests for business-wide, org-unit, location, cancelled, and invalid
  stale-scope cases.
- Route key tests proving unrelated global admin routes do not accidentally
  inherit a business scope.

### Live Gateway and Demo Fallback Risk

Current code:

- `AdminConsoleServicesScope.*GatewayOf(context)` falls back to seeded in-memory
  gateways when a specific gateway is null.
- `main_admin.dart` wires live HTTP gateways when `ADMIN_PROXY_BASE_URI` and
  live auth are available; share preview and demo paths intentionally use
  fixture gateways.

Implementation impact:

- Preview verification must explicitly prove which surfaces are live gateway
  backed and which are fixture/share-preview backed.
- Do not treat the public share-preview console as live plumbing evidence. It is
  useful for email/share walkthroughs, but it cannot prove proxy/database route
  behavior.
- Add a live-wiring smoke that fails closed when a production/preview build is
  missing a required gateway for any target tile.

Tests to add:

- Release/live build guard that asserts demo gateways are not used when
  `ADMIN_DEMO_AUTH=false` and a live proxy base URI is supplied.
- Browser Use evidence checklist that records whether each tile response came
  from live proxy, read-only fixture, or intentionally disabled state.

### Hierarchy Route Contract Mismatches

Current code:

- Proxy auth hierarchy routes expose:
  - `GET /v1/admin/auth/org-units`
  - `POST /v1/admin/auth/org-units`
  - `PATCH /v1/admin/auth/locations/:location_id/org-unit`
- `HttpRolesHierarchySessionsAdminGateway.moveOrgUnit` calls
  `POST /v1/admin/auth/org-units/:id/move`.
- `HttpRolesHierarchySessionsAdminGateway.moveLocation` calls
  `POST /v1/admin/auth/locations/:id/move`.
- The operator-web hierarchy gateway calls the existing self-service routes:
  `GET /v1/auth/team/org-units`, `POST /v1/auth/team/org-units`, and
  `PATCH /v1/auth/team/locations/:location_id/org-unit`.

Implementation impact:

- Reconcile admin gateway paths with proxy routes before claiming hierarchy move
  is end-to-end.
- Either add the admin `POST .../move` proxy routes, or update the admin gateway
  to call the existing `PATCH .../org-unit` contract.
- Add explicit admin route tests for org-unit move if that remains a desired
  admin operation, because proxy currently shows create org-unit and move
  location support, not a verified org-unit move branch.

Tests to add:

- Proxy tests for admin hierarchy list, create org unit, move location, and
  forbidden roles.
- Admin gateway HTTP path tests pinning the exact method/path/body for each
  hierarchy mutation.
- Flutter screen tests that hide or disable any hierarchy action whose route is
  not live.

### Invite, Email, and Password Reset Gaps

Current code:

- `POST /v1/admin/auth/invites` creates an invite row through
  `AuthOperationsGateway.createInvite`.
- The admin email router only handles
  `POST /v1/admin/integrations/email/test`; it sends a sample
  `operator_invite_first_admin` email to test SendGrid.
- The invite creation route does not itself send the real invite email.
- Admin member reset password routes exist and the audited support gateway
  describes recovery email delivery through the proxy's SendGrid binding.
- Password reset requests are privacy-preserving and may return generic success
  even when a usable account does not exist.
- `AdminEmailConflictUsage` and repository conflict details already support
  showing where a duplicate email exists, but the invite dialog still requires a
  primary location and treats duplicate email review as a local validation/error
  path rather than a first-class decision workflow.

Implementation impact:

- Pending invite UX must separate three states:
  - invite row created
  - invite email sent/accepted by provider
  - invite accepted and user account active
- Add a resend/send invite email action or route if the product expects email to
  go out from the Members surface.
- Disable or explain password reset for pending invites until the user account
  exists and can receive a reset email.
- Make "account with this email already exists" clickable everywhere it appears,
  not only after a failed invite attempt. The details should show business,
  location/hierarchy scope, role/status, and whether it is a team member,
  pending invite, or Firebase-only account.
- Decide and encode the email uniqueness policy:
  - business contact email metadata may remain non-auth metadata;
  - business owner/team login emails should likely be unique per active
    business membership unless explicitly revoked/transferred;
  - Forge & Flow staff emails must be allowed to support multiple businesses
    through admin/support roles.

Tests to add:

- Invite create does not imply email sent unless the new email route returns
  accepted provider status.
- Resend invite happy path, provider failure, missing SendGrid config, and
  idempotent retry tests.
- Password-reset disabled/explained state for pending invite rows.
- Email conflict detail rendering for team member, pending invite,
  Firebase-only account, multiple business usages, and no-details fallback.

### Pricing, Usage Caps, and Feature Flags

Current code:

- The global `Plans and limits` screen uses `/v1/admin/pricing/*`.
- `usage_caps` has newer `billing_owner_org_unit_id` and
  `scoped_org_unit_id` database columns, but `UsageCapRow` and the admin screen
  still model caps primarily by `operatorId`, `locationId`, usage class, staff,
  and workflow.
- `Polling & pricing` is a separate per-location operational pricing/tier
  assignment surface.
- Feature flags support global, operator, and location scopes, not org-unit
  scope.

Implementation impact:

- Do not merge global `Plans and limits` with operational
  `Polling & pricing` without naming the distinction in the UI.
- If every setting inherits by hierarchy, usage caps need Dart model, gateway,
  proxy, and UI support for `billing_owner_org_unit_id` and
  `scoped_org_unit_id`, not only the database columns.
- Feature flags need a product decision: either they stay an internal Forge &
  Flow launch-control surface with global/operator/location scope, or they join
  the hierarchy rule and get org-unit support.
- Polling/pricing assignments remain location-only until schema/resolver work
  adds business/org-unit inheritance.

Tests to add:

- Pricing model serialization tests for org-unit scoped cap rows after model
  expansion.
- Proxy tests for usage cap upsert/read by business root, org unit, and
  location if hierarchy support is added.
- Feature flag scope tests documenting either "no org-unit by design" or the
  new org-unit behavior.

### Data Accuracy and Operational Settings

Current code:

- Data accuracy repositories and admin gateways are keyed on
  `(operator_id, location_id)`.
- Polling tier assignment repositories are keyed on
  `(operator_id, location_id)`.
- Business timing already has the strongest hierarchy plumbing:
  operator/org-unit/location scope kinds and inheritance summaries.
- Operator web screens correctly show "choose a location" fallback for
  location-only surfaces when the management scope is business-wide or org-unit.

Implementation impact:

- Data accuracy and polling/pricing should show business/org-unit prompt
  choices only when the backend can return effective/inherited values for those
  scopes.
- Until then, business/org-unit choices should be readable rollups or disabled
  with plain copy, not fake editable forms.
- Timing should be the first full hierarchy-scoped settings tile because its
  backend model already matches the rule.

Tests to add:

- Effective value/source scope tests for timing.
- Disabled business/org-unit edit-state tests for data accuracy and
  polling/pricing until scoped schema lands.
- Migration/repository tests before enabling editable business/org-unit values
  for data accuracy or polling/pricing.

### Integrations, Vendor Connections, and Email Provider Settings

Current code:

- Admin `Connected services` is global provider/key management.
- Operator/admin vendor connection management is location-scoped.
- Email test route is global provider health, not a real operator invite send.

Implementation impact:

- Keep "Integrations" in the Business setup widget focused on location-level
  vendor connections.
- Keep global provider credentials and SendGrid test under internal Forge &
  Flow admin/system setup, not the selected business hierarchy workspace.
- The scope prompt for Integrations can show business/org-unit choices for
  navigation context, but edit must require choosing a location.

Tests to add:

- Integrations tile requires a location before showing editable vendor
  connection controls.
- Global connected-services routes remain super-admin only and are not confused
  with per-location vendor connections.

### Mobile and Operator Web Scope Parity

Current code:

- Mobile `BusinessScope` supports `operator`, `org_unit`, and `location`, but
  the app drawer filters to selectable locations only.
- `BusinessScopeRouter` returns all location scopes for global admin/support
  reads, and requires a concrete operator/location scope for ordinary users.
- Operator web now has a management scope picker with business-wide,
  org-unit, and location options, but many post-onboarding screens still require
  a location for edits.
- Operator web notifications support `operator` and `location` scope only; no
  org-unit notification preference support is currently surfaced.
- Live operator-web TOS acceptance still has an explicit unsupported path in
  the Firebase auth source, so onboarding/TOS should be verified separately
  before calling that flow fully live.

Implementation impact:

- Mobile remains location-operational by design unless a separate mobile
  hierarchy management experience is planned.
- F&F staff access to many businesses should be admin/support-console behavior,
  not mobile drawer behavior.
- Operator web can share the hierarchy rule for read/effective display, but
  location-only operational screens should continue to require location scope.
- Add explicit parity notes so admin, operator web, and mobile do not appear to
  support the same edit breadth when they do not.

Tests to add:

- Mobile drawer tests proving only selectable location scopes appear.
- Operator web management scope tests for business/org-unit/location fallback
  and "requires location" states.
- Notification preference tests documenting current operator/location-only
  behavior or adding org-unit support if product requires it.
- Live TOS acceptance route test before relying on operator-web TOS completion
  in preview.

### Support Logs, Health, and Observability

Current code:

- Debug/support logs filter by optional operator/location.
- Health and observability are global support tools, not settings screens.
- Observability rows can include optional location IDs, but the route is not a
  hierarchy settings editor.

Implementation impact:

- Support logs should accept selected hierarchy scope and translate it into
  operator/location/org-unit filters or rollups.
- Health and system metrics should remain global admin routes, but selected
  business support context may deep-link into filtered logs or metrics when
  useful.
- Do not put health/observability inside Business setup; keep them as F&F
  operational tools.

Tests to add:

- Support logs scoped query tests for business-wide, org-unit, and location.
- Browser Use checks that Health/System metrics remain reachable but not mixed
  into business settings IA.

## Third-Pass Coverage Lens Audit

This pass looked for lenses not fully covered by the first two audits. The goal
was to catch hidden plumbing, data lifecycle, route, deploy, and test gaps before
the implementation starts.

| Lens | Code checked | Finding | Implementation impact |
|---|---|---|---|
| Database/RLS inheritance cache | `db/migrations/202604280002_phase_9_0sigma_c_org_units.sql`, `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql` | Org-unit hierarchy and inherited effective-location access are real. `locations.parent_org_unit_id` is non-null after the hierarchy migration and location paths are derived by trigger. | Any create-location path must choose a parent org unit. Business/org-unit access reads should use the effective access cache, but settings inheritance still needs its own effective-settings resolver. |
| Org-unit lifecycle | Same org-unit migrations | `org_units` has no status, suspended, archived, or soft-delete column. Deletes cascade through child org units and dependent access rows. | Do not expose org-unit delete/suspend/archive as UI buttons until lifecycle schema, route behavior, audit events, and undo/recovery policy are defined. Prefer archive/suspend over destructive delete. |
| Location lifecycle | `lib/infrastructure/persistence/postgres/repositories/locations_repository.dart`, `tool/advisor_proxy/proxy_bootstrap.dart` | Existing admin location path supports patch and hard delete. Flat `insertLocation` does not pass `parent_org_unit_id`, which conflicts with the current hierarchy schema. | Replace flat add-location with hierarchy-aware create. Add parent org unit to command, proxy route, repository, model, tests, and UI. Decide whether delete remains hard delete or becomes suspend/archive. |
| Role/invite scope storage | `lib/infrastructure/persistence/postgres/repositories/user_roles_repository.dart`, `lib/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart` | Role grants and invites already support `operator_wide`, `org_unit`, and `location` scopes. Pending invite rows can return org-unit/location labels. | The People/access/roles surface can be truly hierarchy scoped, but the admin invite dialog and route handoff must stop requiring a primary location when creating business/org-unit scoped invites. |
| Forge & Flow staff multi-business access | `lib/infrastructure/persistence/postgres/repositories/operator_admins_repository.dart`, auth foundation tests | `operator_admins` uses `(user_id, operator_id)` membership, so the same F&F staff user can support multiple operators. | Do not enforce global one-email-per-business for F&F staff support accounts. Separate business contact email policy from authenticated owner/team membership policy. |
| Business contact email | `operators.owner_email` migrations, `OperatorsRepository`, admin models/screens | Database and API still use `owner_email`; UI copy is moving toward Contact email. No unique operator-wide owner-email constraint was found in the inspected migrations. | Keep wire compatibility as `owner_email`, but present it as Contact email. If product wants owner/member uniqueness, enforce it in auth membership/invite flow with conflict details, not by blocking F&F staff support rows. |
| Timing inheritance | `BusinessTimingProfilesRepository`, `BusinessTimingProfileResolver`, `repository_operator_write_gateways.dart` | Timing is the strongest implementation of the desired rule: operator/org-unit/location profiles resolve in hierarchy order, with lower profiles overriding higher ones. | Make Timing the reference implementation for every other settings surface. Admin Timing should include timezone copy/fields even though timezone currently lives on location/account data. |
| Data accuracy settings | `db/migrations/202605050000_phase_8_data_accuracy_settings.sql`, `DataAccuracySettingsRepository` | Data accuracy is still `(operator_id, location_id)` only, with RLS tied to `app_current_location()`. | Business/org-unit Data accuracy choices must be disabled/read-only rollups until scoped schema and effective resolution exist. Do not fake business-level edits in the UI. |
| Polling/pricing | `ForgeFlowPollingTierRepository`, `UsageCapsRepository` | Polling tier assignments are location-only. Usage caps already carry `billing_owner_org_unit_id` and `scoped_org_unit_id`, but the admin path still resolves both to the operator root. | Polling/pricing needs two tracks: expose usage-cap hierarchy scope where already backed, and add scoped polling-tier assignment/resolution before business/org-unit editing is real. |
| Notification preferences | `db/migrations/202605070400_phase_8_notification_preferences.sql`, `notification_preferences_routes.dart` | Notifications support operator and location scope only; org-unit scope is not in the DB check constraint or route validation. | If notifications are part of People/security settings, document operator/location-only behavior or add org-unit scope through migration, repository, route, and UI tests. |
| Admin hierarchy route contract | `tool/advisor_proxy/advisor_proxy.dart`, `roles_hierarchy_sessions_admin_gateway.dart` | Proxy exposes `GET/POST /v1/admin/auth/org-units` and `PATCH /v1/admin/auth/locations/:id/org-unit`; admin gateway calls `POST /v1/admin/auth/org-units/:id/move` and `POST /v1/admin/auth/locations/:id/move`. | Reconcile method/path/body before using admin move buttons as live functionality evidence. Add proxy and gateway path tests. |
| Preview/deploy/runtime | `tool/advisor_proxy/main.dart`, `scripts/deploy_preview_stack.ps1`, `runbooks/preview_environment_runbook.md`, `test/proxy/main_bootstrap_test.dart` | Preview DB-safe startup mode exists and is tested: `PROXY_DEFER_STARTUP_DATABASE=true` skips startup DB probes and background consumers while keeping route-level DB access. | Use this in runtime-isolated preview deploys near the staging DB connection ceiling. Full mutation E2E should prefer data-isolated preview or explicit approval when shared staging secrets are used. |
| Test matrix | `test/admin`, `test/proxy`, `test/operator_web`, repository and migration tests | There is broad coverage, but no single acceptance test ties the desired IA, hierarchy CRUD, scoped settings, and live proxy contracts together. | Add a slice-level acceptance matrix that runs unit/widget/proxy/repository tests plus Browser Use on preview after each merge. |

### Additional Coverage Requirements

- Add a failing test for admin add-location against the post-hierarchy schema:
  creation must include `parent_org_unit_id` or use an explicit root default.
- Add a route-contract test proving admin hierarchy gateway methods match proxy
  routes exactly.
- Add org-unit lifecycle tests only after the product chooses archive/suspend
  semantics. Until then, hierarchy UI should not show destructive org-unit
  delete.
- Add a scoped-settings resolver test pattern copied from business timing for
  every setting that becomes hierarchy editable.
- Add live-wiring guards so share/demo gateways cannot be mistaken for preview
  proof in release or preview builds.

### Coverage Lenses Now Accounted For

- Product IA and scanability.
- Admin route handoff and shared scope model.
- Database schema, RLS, triggers, and inherited access cache.
- Repository write semantics and hard-delete risk.
- Proxy route contracts and idempotency/audit requirements.
- Admin Flutter gateways and demo fallback risk.
- Operator web and mobile parity boundaries.
- Email/invite delivery and password reset states.
- Forge & Flow staff multi-business support.
- Preview deploy/runtime modes and DB connection safety.
- Test, Browser Use, and performance verification.

## Residual Decisions Before Implementation

- Confirm exact lifecycle wording: `active`, `suspended`, `archived`, or
  `deleted` for org units and locations.
- Confirm whether active sessions appear only in Security/audit/sessions. This
  plan puts them there to avoid duplicate mental models.
- Confirm whether contact email uniqueness is global per business account owner
  or allows Forge & Flow staff/support accounts to access multiple businesses.
- Confirm if support-operator view remains as a hidden/deep-link fallback during
  migration or redirects immediately to the new Business Accounts workspace.
- Confirm whether Data accuracy and Polling/pricing should wait for true
  hierarchy-scoped schema/resolvers or ship first as location-only with disabled
  business/org-unit edit states.

## New-Session Execution Prompt

Use this prompt to start implementation in a fresh Codex session:

```text
Use the Forge & Flow repo workflow and Browser Use.

Objective:
Implement the full Admin Hierarchy Settings Overhaul from
docs/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md. Treat the
plan as the source of truth. Preserve the non-negotiable hierarchy rule:
business/operator defaults are inherited by org-unit descendants and locations;
lower scope overrides higher scope; every setting must either support this rule
or explicitly document why it is location-only, backend-only, or intentionally
unsurfaced.

Worktree and branch:
1. Do not mutate the main working tree.
2. Fetch latest origin/master and create separate worktrees under
   .codex_worktrees.
3. Use branch names under codex/.
4. Use multiple agents/worktrees in parallel where write scopes are disjoint.
5. Commit each slice intentionally after tests for that slice pass.
6. Push branches, open PRs, and merge completed slices only after checks pass and
   no unresolved product decision blocks the slice.

Required reading:
- PROJECT_TRACKER.md
- CLAUDE.md
- docs/ARCHITECTURE.md
- docs/contracts/core_app_architecture.md
- docs/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md
- docs/_execution/admin_hierarchy_settings_deep_plumbing_audit_2026-05-08.md
- docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md if present, otherwise
  docs/UX_ADJUSTMENT_FRAMEWORK.md
- docs/frameworks/PERFORMANCE_FRAMEWORK.md if present, otherwise
  docs/PERFORMANCE_FRAMEWORK.md
- docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md if present, otherwise
  docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md
- runbooks/preview_environment_runbook.md

Execution slices:
1. Shared scope model:
   Add AdminHierarchyScopeIntent and a reusable business/org-unit/location scope
   prompt. Replace operator/location-only route handoff.
2. Business Accounts IA:
   Remove Click to manage, make row selection the interaction, show hierarchy
   first, and replace the flat location view with the hierarchy workspace.
3. Hierarchy route contracts:
   Reconcile admin gateway methods with proxy hierarchy routes. Add parent org
   unit to location create. Do not expose org-unit delete/suspend/archive until
   lifecycle schema and tests exist.
4. People/access/roles:
   Merge members, invites, role grants, role policy, permission explainer, and
   sessions handoff into the scoped People/access/roles flow. Keep F&F staff
   multi-business access valid.
5. Security/audit/sessions:
   Move sessions and audited support actions into one scoped surface with reason,
   confirmation copy, role checks, and idempotency.
6. Account profile/contact email:
   Rename business-facing Owner email copy to Contact email while preserving
   existing owner_email wire/API compatibility. Add clickable conflict details
   for duplicate/existing email states.
7. Timing:
   Use business timing as the reference hierarchy implementation. Add admin
   scoped timing, inherited/effective labels, and timezone handling.
8. Data accuracy and polling/pricing:
   Keep business/org-unit edit disabled/read-only until scoped schema/resolvers
   are implemented. If implementing hierarchy edit, add migrations,
   repositories, proxy routes, effective resolvers, and tests first.
9. Integrations:
   Use the hierarchy prompt to find context, but require location scope before
   showing editable vendor connection controls.
10. Support logs:
   Translate business/org-unit selection into scoped filters or covered
   locations. Keep Health/Observability as global F&F tools, not business
   setup tiles.
11. Demo/live guardrails:
   Prevent demo/share gateways from being mistaken for live preview wiring in
   release/preview builds.

Testing and verification:
- Run targeted Dart/Flutter tests per slice.
- Run proxy route tests for auth, hierarchy, members, roles, sessions, audit,
  data accuracy, timing, polling/pricing, integrations, health, and startup if
  touched.
- Run repository/migration tests for every schema change.
- Run flutter analyze.
- Run relevant admin/operator web widget tests.
- Build admin/operator web release bundles against the preview proxy when UI
  slices are ready.
- Use Browser Use on fresh cache-bust preview URLs to test every reachable
  admin console surface, including all safe mutations and every required
  disabled/gated state.
- Run the Performance Framework with JSON evidence and fix duplicate fetches,
  route switching regressions, startup regressions, unbounded lists, and polling
  issues before final merge.

Deploy:
- Follow docs/frameworks/deployFramework.md if present; otherwise follow the
  preview environment runbook.
- For runtime-isolated preview sharing staging Postgres, use
  -DeferProxyStartupDatabase and /readyz for startup liveness.
- Do not deploy production. Do not mutate shared staging data unless explicit
  action-time approval exists or the preview is data-isolated.

Final closeout:
- Update execution notes with source commits, PRs, preview URLs, database mode,
  route-by-route Browser Use evidence, bugs fixed, intentionally gated items,
  tests/builds/perf JSON, and residual risks.
- After all slices are merged, do a final audit comparing the code to this plan
  and verify the web console end to end, including mutating functionality that
  is approved and safe in the chosen preview database mode.
```
