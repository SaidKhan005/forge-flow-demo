# Admin Hierarchy Settings Overhaul - Implementation Packet

Status: planning packet ready
Created: 2026-05-08
Canonical master plan:
`docs/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md`

## Purpose

This folder breaks the long admin hierarchy settings plan into execution-sized
documents. Use it when implementing the overhaul in parallel worktrees.

## Read Order

1. `01_product_rule_and_ia.md`
2. `02_plumbing_audit_matrix.md`
3. `03_execution_slices.md`
4. `04_verification_deploy_and_e2e.md`
5. `05_new_codex_execution_prompt.md`

The companion audit note remains:
`docs/_execution/admin_hierarchy_settings_deep_plumbing_audit_2026-05-08.md`

## Non-Negotiable Rule

Every setting that affects a business resolves through this hierarchy:

`business/operator default -> org-unit ancestors from root to leaf -> location`

The lowest configured scope wins. If a lower scope has no local value, it
inherits from the nearest configured ancestor. Every settings UI must show the
selected scope, inherited source, effective value, and allowed actions before
any mutation.

Integrations are the known edit-scope exception: the hierarchy picker can help
find the context, but vendor connection edits remain location-level.

## Implementation Strategy

- Start with a shared scope model and route handoff. Do not build per-screen
  one-offs.
- Reconcile backend route contracts before claiming UI buttons are live.
- Move already-wired capabilities into the simpler IA first.
- Add new hierarchy-scoped schemas/resolvers only where backend capability is
  actually missing.
- Keep every mutation role-gated, reasoned, idempotent, and audited.
- Use preview Browser Use plus tests as proof, not demo/share preview alone.

## Parallel Worktree Rule

Parallel work is allowed only when file ownership is disjoint. Shared seams,
such as the new hierarchy scope model, route contracts, and migrations, must be
merged before dependent UI slices rely on them.

## High-Risk Items

- Admin add-location currently lacks `parent_org_unit_id`, but hierarchy schema
  requires it.
- Admin hierarchy gateway move routes currently do not match inspected proxy
  routes.
- `org_units` has no lifecycle/status columns, so suspend/archive/delete cannot
  be full fidelity yet.
- Data accuracy, polling tier assignments, and notifications are not fully
  org-unit scoped.
- F&F staff emails must be allowed across multiple businesses through support
  access; business contact email policy is separate from staff access policy.
