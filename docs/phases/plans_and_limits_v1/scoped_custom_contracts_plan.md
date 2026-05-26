# Plans and Limits Scoped Custom Contracts

Status: SHIPPED to master through final QA polish (2026-05-26)
Date: 2026-05-26
Branch history: `codex/plans-limits-scoped-contracts` -> follow-up QA/copy polish through PR #1388

## Goal

Add business, org-unit, and location scoped custom contract support to Plans and limits without redesigning the admin console.

Enterprise is the custom-contract base plan. A selected hierarchy scope can carry custom commercial terms while still resolving through the same plan key:

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

## Shipped Scope

- Enterprise stays the single custom-contract plan key; no new tier key was invented.
- Custom terms can be set at business, org-unit, or location scope.
- Location overrides org unit, org unit overrides business, business overrides the global catalog.
- Missing lower-scope terms inherit from the nearest configured ancestor.
- Admin Businesses tab shows selected scope, inherited source, effective value, and set-here/inherited/catalog status.
- Admin Businesses tab supports edit, save, clear, and inherit behavior.
- Admin Plans tab keeps the six global plan cards and treats Enterprise as the custom base.
- Business Accounts stale launch-plan wording was removed; subscription editing stays owned by Plans and limits.
- Operator Web "Your plan" remains display-only and reads cleanly for Enterprise/custom contracts.
- No Stripe, invoice, payment-method, checkout, or operator self-serve billing flow was added.

## Current State

Admin Plans and limits lives at `lib/admin/screens/pricing_tier_admin_screen.dart`.

- Plans tab shows the six global plans.
- Features tab edits the global feature entitlement matrix, but does not gate the app yet.
- Businesses tab uses the left hierarchy tree as the selector and shows plan, margin, recent hits, usage limits, and scoped custom contracts.
- Enterprise global catalog pricing is "Custom".
- Usage caps retain the hierarchy-shaped pricing controls already used by the admin pricing surface.
- Plan catalog and feature entitlements remain global tables.

Operator Web has a display-only "Your plan" surface at `lib/operator_web/screens/plan_screen.dart`.

Admin Polling and Pricing remains a separate internal data freshness/vendor-cost surface. It is not the subscription contract editor.

## Backend Truth

Plan and pricing storage:

- `operators.subscription_tier`
- six-tier CHECK migration: `db/migrations/202605240900_plans_and_limits_phase0_subscription_tier_check.sql`
- global plan catalog: `pricing_plan_catalog`
- global feature matrix: `feature_entitlements`
- scoped custom contracts: `pricing_contract_overrides`
- usage controls: `usage_caps`
- spend logs and cap telemetry: `usage_logs`, `usage_cap_events`

Scoped contract migrations:

- `db/migrations/202605251000_plans_and_limits_scoped_contract_overrides.sql`
- `db/migrations/202605251020_plans_and_limits_scoped_contract_windows.sql`

Repository and resolver:

- `lib/infrastructure/persistence/postgres/repositories/pricing_contract_overrides_repository.dart`
- returns selected scope, inherited source, effective terms, override status, and mutation target
- covers set-here, inherited, catalog-default, and clear-to-inherit flows

Admin client models and gateway:

- `lib/admin/models/pricing_tier_admin_models.dart`
- `lib/admin/services/pricing_tier_admin_gateway.dart`
- fake/in-memory gateway behavior covers the scoped contract flow for local/admin tests

Proxy routes:

- `GET /v1/admin/pricing/scoped-contracts/effective?operator_id=...&scope_type=...&org_unit_id=...&location_id=...`
- `PUT /v1/admin/pricing/scoped-contracts`
- `DELETE /v1/admin/pricing/scoped-contracts/{id}`

Write gates:

- super-admin pricing write posture
- step-up auth route coverage
- idempotency key
- mutation reason
- audited save/delete events

## Resolution Rule

The effective contract for a selected hierarchy node resolves in this order:

1. Location override
2. Org-unit override
3. Business override
4. Global plan catalog

The UI must show where the value came from before a save or clear action.

Plain English example:

- Demo Diner Co. is Enterprise with a custom $2,500 monthly minimum.
- East region inherits that unless it sets its own terms.
- Toronto Yorkville can override to a $500 monthly minimum and $300 advisor cap.
- Clearing Toronto Yorkville returns it to East region if East is set, otherwise Demo Diner Co., otherwise the global catalog.

## Billing Rollup

This slice does not implement Stripe, invoices, payment methods, or actual payment collection.

Billing math is preview/display only:

- Business scope is the top rollup.
- Org units and locations can override terms.
- Lower-scope overrides affect only their subtree.
- Rollup totals build upward by summing locations into org units, then org units into the business.
- Usage costs still meter through `usage_caps` and spend telemetry.

## Screens Changed

Primary:

- Admin Plans and limits, Businesses tab
  - scoped contract summary
  - selected scope, inherited source, effective value
  - edit custom contract
  - clear custom contract
  - inherit behavior
  - left hierarchy pane unchanged

Secondary:

- Admin Plans and limits, Plans tab
  - global plan cards retained
  - Enterprise reads as the custom-contract base plan

- Admin Business Accounts
  - stale launch wording removed
  - no subscription editor added

- Operator Web Your plan
  - display-only plan/contract wording checked
  - no checkout or self-serve billing action

No functional change:

- Admin Polling and Pricing
  - remains data freshness/vendor-cost margin tooling
  - may later consume contract revenue for margin reporting, but is not the editor

## Verified Acceptance

- selected scope, inherited source, and effective value are visible before mutation
- global plan catalog still works for non-custom plans
- Enterprise carries scoped custom terms without a new tier key
- clear behavior returns the selected scope to inheritance
- step-up and role checks cover money/limit writes
- tests cover inherited, set-here, and clear-to-inherit flows
- final browser QA checked Businesses tab spacing, custom contract popup, clear/inherit behavior, Operator Web "Your plan", and Business Accounts copy
- Polling and Pricing remains separate from subscription contracts

## Still Future

- actual feature gates from `feature_entitlements` remain deferred until LMS, scoreboard, SOPs, workflows, or another gateable surface exists
- Stripe
- invoices
- payment methods
- checkout
- operator self-serve plan changes
- production/staging application of the code-ready Plans and limits migrations remains under the normal operator-approved migration queue

## Non Goals

- rewriting the Plans and limits layout
- moving the hierarchy pane
- turning Enterprise into a separate billing engine
- adding a subscription editor to Business Accounts
- adding custom contract editing to Polling and Pricing
