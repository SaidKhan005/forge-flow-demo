# Mobile Core Business Scope Contract

Status: planning contract
Date: 2026-05-06
Owner: Phase 8 mobile core logic data wiring

## Purpose

This contract binds Doc 1 Phase 1 — the mobile business scope selector
and accessible-scope server truth.

The sprint goal is plain:

1. A user with access to multiple operators, locations, regions, or
   groups picks which location they are looking at from a hamburger
   drawer.
2. The accessible scopes available to the user are server truth, not
   client-derived from role catalogs.
3. The active scope is local cache, isolated per session, and survives
   app restarts.
4. Switching scope re-bases sync, dashboards, Variance, and History
   without bleeding rows across tenants.

## Authority

1. `PROJECT_TRACKER.md`
2. `docs/archive/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
4. `docs/contracts/auth_permission_key_catalog.md`
5. `docs/contracts/slice_runtime_acceptance_contract.md`
6. `CLAUDE.md`

## Current Code Reality

Current repo search found no `business_scope*` files anywhere in
`lib/`. The mobile app today binds to a single
`(operator_id, location_id)` pair seeded at sign-in and never offers a
switcher. Operator Web Console binds to whatever operator JWT scope was
issued on magic-link.

That means:

- A consultant with access to two restaurant groups can sign in once
  but only see one group at a time, with no in-app way to flip.
- A regional manager with three locations sees three separate sign-ins
  rather than one switcher.
- The `cutover.5` beta widening (post-Vanessa) is blocked on this
  surface for any operator with more than one location.

## Scope

This sprint includes:

- Additive proxy route returning the user's selectable locations,
  filtered by RBAC. Operator-wide, region, district, or group grants
  expand server-side into the underlying location rows.
- F&F global read roles can use the same mobile drawer to discover all
  registered business locations.
- Mobile model + local active-scope SQLite repository.
- Hamburger drawer / scope picker UI on mobile + operator-web shell.
- Cancellation + re-base of the in-flight sync runtime when scope
  changes.
- Cross-scope cache isolation (a row from operator A's location 1
  must not bleed into operator A's location 2's view).
- Fixture proof that switching scope re-bases mobile views.

This sprint excludes:

- Group / region / company rollups (group-level dashboards live in a
  separate post-V1 sprint). Higher-level grants do not create mobile
  rollup dashboards in this sprint.
- Cross-tenant ad-hoc queries on Operator Web (admin support uses the
  F&F Ops Console).
- Push notification proof.
- Live provider calls.

## Required End State

The accepted sprint proves this path:

```text
user signs in
-> proxy returns accessible scopes via /v1/users/:userId/business_scopes
-> mobile renders a searchable hamburger drawer with selectable locations
-> active scope is persisted locally per user
-> user switches scope from A to B
-> mobile cancels the in-flight sync
-> mobile re-bases sync, dashboards, and Variance to B
-> A's rows do not appear in B's view
-> app restart resumes on B (last active scope)
```

## Hard Rules

1. Accessible scopes are server truth. The mobile client never derives
   them from a local role table.
   Higher-level grants are projected by the server into location rows;
   mobile does not synthesize a rollup or merge rows locally.
2. Active scope is per-session local state. It is never sent on a
   write — every write carries server-derived `(operator_id,
   location_id)` from the JWT, and the proxy verifies the active
   scope is in the user's accessible set.
3. A scope switch cancels the in-flight sync, clears scope-specific
   in-memory caches, and re-bases the sync runtime against the new
   `(operator_id, location_id)` pair.
4. Existing mobile SQLite tables stay scoped by `(operator_id,
   location_id)`; no duplicate mobile cache tables.
5. The proxy route is operator-scoped and respects per-operator RLS.
6. The drawer surfaces only what the user actually has access to —
   never a "request access" button on V1. The drawer has search and
   only selectable location rows; non-location scope rows are not
   rendered as disabled pseudo-rollups.
7. The drawer copy reads as training, not jargon (UX writing standard).
8. The active scope persists across app restarts via existing local
   identity storage, not a new keychain entry.
9. **HP #11 carve-out (mobile is single-location by design).** The
   mobile app is intentionally a single-location operational view: a
   user with operator-, region-, or group-level access still picks one
   location and the phone reads that one location at a time. This is a
   deliberate `CLAUDE.md` Hard Promise #11 carve-out, exercised under
   HP #11's "or document why the capability is
   backend-only/gated/incomplete" clause. The rationale: higher-level
   grants are projected by the server into their underlying location
   rows (Hard Rule 1), so the hierarchy work happens server-side and
   the phone never synthesizes a tree or rollup; group / region /
   company rollup dashboards are explicitly deferred to a separate
   post-V1 sprint (see "Out of scope"). Because of this carve-out, the
   mobile settings, timing, pricing, wage, and accuracy surfaces are
   NOT required to show the selected-scope / inherited-source /
   effective-value triad that HP #11 mandates for the operator-web and
   admin consoles; surfacing the active location label is sufficient on
   mobile. Removing this carve-out (i.e., bringing the org-unit tree and
   inheritance display to mobile) is a deliberate post-V1 scope
   decision, not a bug, and requires its own contract update.

## Acceptance

Accept only when:

- Proxy `/v1/users/:userId/business_scopes` returns the correct
  accessible set for a multi-scope user, restricted by RBAC.
- Operator-wide and org-unit grants return their underlying locations,
  with no mobile rollup rows.
- F&F global read roles can list every registered business location,
  search the drawer, and select a location while the phone still reads
  one selected location at a time.
- Mobile drawer renders the list and persists active scope locally.
- Switching scope cancels in-flight sync, re-bases caches, and renders
  the new scope's data.
- Cross-scope rows do not bleed into the active view (proven with a
  fixture two-scope test).
- App restart resumes on the last active scope.
- Operator Web Console shows the same scope picker on shells that have
  access to more than one operator.
- Targeted tests, analyzer, migration lints, and drift scanner pass.
- Proof document names what was simulated and what was not run.

## Lane shape (informational)

A future sprint plan will expand this into Lanes 0–4:

- Lane 0 — proxy route + mobile model + local active-scope repository
  (V1.D is Lane 0)
- Lane 1 — sync runtime cancellation + re-base
- Lane 2 — mobile drawer UI
- Lane 3 — operator-web drawer UI
- Lane 4 — proof harness + closeout

V1.D in `2026-05-06_v1_closure_dispatch_plan.md` ships Lane 0 only.
