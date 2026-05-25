# Plans and Limits Scoped Custom Contracts

Status: Draft implementation plan
Date: 2026-05-25
Branch: codex/plans-limits-scoped-contracts

## Goal

Add business, org-unit, and location scoped custom contract support to Plans and limits without redesigning the admin console.

The first supported custom plan is Enterprise. Enterprise stays the top plan key, but a selected business scope can carry custom commercial terms:

- effective plan
- inherited source
- monthly minimum or custom monthly price
- seat ramp
- onboarding range
- advisor spend cap
- billing owner
- effective dates
- internal note or reason

Every pricing mutation must show the selected scope, inherited source, and effective value before saving.

## Current State

Admin Plans and limits already exists at `lib/admin/screens/pricing_tier_admin_screen.dart`.

- Plans tab shows the six global plans.
- Features tab edits the global feature entitlement matrix, but does not gate the app yet.
- Businesses tab uses the left hierarchy tree as the selector and shows plan, margin, presets, recent hits, and usage limits.
- Enterprise exists as a static tier key with "Custom" global catalog pricing.
- Usage caps have a two-slot hierarchy key in the database, but the admin pricing route still mostly writes root/root.
- Plan catalog and feature entitlements are global tables, not business scoped.

Operator web already has a display-only "Your plan" surface at `lib/operator_web/screens/plan_screen.dart`.

Admin Polling and Pricing is a separate internal data freshness/vendor-cost surface. It should not become the subscription contract editor.

## Backend Trace

Current plan truth:

- `operators.subscription_tier`
- six-tier CHECK migration: `db/migrations/202605240900_plans_and_limits_phase0_subscription_tier_check.sql`
- global plan catalog: `pricing_plan_catalog`
- global feature matrix: `feature_entitlements`
- usage controls: `usage_caps`
- spend logs and cap telemetry: `usage_logs`, `usage_cap_events`

Current proxy routes:

- `GET /v1/admin/pricing/operators`
- `PATCH /v1/admin/pricing/operators/{operatorId}`
- `POST /v1/admin/pricing/operators/{operatorId}/apply-template`
- `GET /v1/admin/pricing/operators/{operatorId}/spend-summary`
- `PUT /v1/admin/pricing/usage-caps`
- `DELETE /v1/admin/pricing/usage-caps`
- `GET /v1/admin/pricing/plans`
- `PATCH /v1/admin/pricing/plans/{tierKey}`
- `GET /v1/admin/pricing/entitlements`
- `PATCH /v1/admin/pricing/entitlements/{tierKey}/{featureSlug}`

Missing backend truth:

- no persisted custom contract per business, org unit, or location
- no effective pricing resolver with inheritance provenance
- no scoped contract route
- no scoped contract client model
- no scoped contract editor in the Businesses tab

## Proposed Data Model

Keep `pricing_plan_catalog` as the global default catalog.

Add `pricing_contract_overrides`:

- `id`
- `operator_id`
- `scope_type`: `business`, `org_unit`, `location`
- `org_unit_id`
- `location_id`
- `tier_key`
- `billing_owner_org_unit_id`
- `monthly_usd`
- `first_n_seats`
- `first_seat_usd`
- `additional_seat_usd`
- `onboarding_min_usd`
- `onboarding_max_usd`
- `advisor_cap_monthly_usd`
- `effective_from`
- `effective_until`
- `contract_label`
- `internal_note`
- `updated_at`
- `updated_by`

Suggested uniqueness:

- one active override per operator and scope target
- lower scopes win over higher scopes
- location beats org unit, org unit beats business, business beats global catalog

## Effective Resolver

Create a resolver that returns one object for the selected hierarchy node:

- selected scope
- inherited source
- effective tier
- effective pricing
- effective advisor cap
- override status: set here, inherited, or catalog default
- editable mutation target

This resolver is the contract between the database, proxy, admin gateway, and Businesses tab.

## Billing Rollup

Do not implement Stripe, invoices, payment methods, or actual payment collection in this slice.

Billing math should be preview/read model only:

- Business scope is the top rollup.
- Org units and locations can override terms.
- Lower scope overrides affect only their subtree.
- If a location has no override, it inherits from its parent org unit.
- If the org unit has no override, it inherits from business.
- If business has no override, it uses the global plan catalog.
- Usage costs still meter through `usage_caps` and the two-slot key.
- Rollup totals build upward by summing locations into org units, then org units into business.

Plain English example:

- Demo Diner Co. is Enterprise with a custom $2,500 monthly minimum.
- East region inherits that unless it sets its own terms.
- Toronto Yorkville can override to a $500 monthly minimum and $300 advisor cap.
- The business rollup shows Demo Diner Co. total expected revenue and advisor cap exposure, with Toronto Yorkville called out as a location-level override.

## Screens That Change

Primary:

- Admin Plans and limits, Businesses tab
  - add a compact scoped contract summary
  - show selected scope, inherited source, and effective value
  - add edit/clear custom contract actions
  - keep left hierarchy pane unchanged

Secondary:

- Admin Plans and limits, Plans tab
  - keep global plan cards
  - clarify Enterprise is the custom contract base plan

- Admin Business accounts
  - remove/retire stale `launch` plan copy if still present
  - keep subscription editing owned by Plans and limits

- Operator web Your plan
  - display effective Enterprise/custom contract copy if the session can safely project it
  - no self-serve billing changes

No functional change:

- Admin Polling and Pricing
  - remains data freshness/vendor-cost margin tooling
  - may later consume contract revenue for margin reporting, but is not the editor

## API Shape

Proposed routes:

- `GET /v1/admin/pricing/scoped-contracts/effective?operator_id=...&scope_type=...&org_unit_id=...&location_id=...`
- `PUT /v1/admin/pricing/scoped-contracts`
- `DELETE /v1/admin/pricing/scoped-contracts/{id}`

Writes must require:

- super admin role
- fresh step-up auth where existing pricing writes require it
- idempotency key
- mutation reason

## Parallel Implementation Lanes

Lane 0: Contract and audit doc

- Owns this plan.
- Defines route and DTO names.
- Keeps agents aligned.

Lane 1: Database and repository

- migration for `pricing_contract_overrides`
- repository and resolver tests
- no UI edits

Lane 2: Proxy routes

- new scoped contract routes
- request validation
- idempotency and audit behavior
- step-up route coverage
- proxy tests

Lane 3: Admin client models and gateway

- scoped contract DTOs
- HTTP gateway methods
- fake/in-memory gateway behavior
- gateway tests

Lane 4: Admin UI

- Businesses tab scoped contract summary/editor
- minimal Plans tab wording for Enterprise
- widget tests

Lane 5: Operator and ops read-only pass

- confirm "Your plan" copy
- confirm Business accounts stale plan labels
- no operator billing checkout
- no Polling and Pricing editor changes

Lane 6: QA and acceptance

- targeted Dart tests
- admin browser smoke test
- screenshot of Businesses tab before/after
- verify no plan/limit text overlaps

## Risk Gates

Do not merge until these are true:

- selected scope, inherited source, and effective value are visible before mutation
- global plan catalog still works for non-custom plans
- Enterprise can carry scoped custom terms without inventing a new tier key
- usage cap writes respect the two-slot key
- step-up and role checks cover money/limit writes
- tests cover inherited, set-here, and clear-to-inherit flows
- Polling and Pricing remains separate from subscription contracts

## Non Goals

- Stripe
- invoices
- payment methods
- operator self-serve plan changes
- app-wide feature gating from `feature_entitlements`
- rewriting the Plans and limits layout
- moving the hierarchy pane
