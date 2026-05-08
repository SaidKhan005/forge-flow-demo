# Admin Hierarchy UX Cleanup Plan

Status: planning audit
Created: 2026-05-08
Branch: `codex/admin-ux-implementation-lens-plan`
Source commit: `ac1193dc`
Worktree: `.codex_worktrees/admin-ux-implementation-lens-plan`

## Purpose

This plan translates the post-overhaul UX review into an implementation-ready
slice plan. It uses `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`
as the audit frame and supersedes the popup-first scope behavior described in
the earlier admin hierarchy settings overhaul docs.

The new product rule is:

1. Business Accounts is the scope command center.
2. The admin selects a business, org unit, or location in the hierarchy.
3. The admin opens a business setup function.
4. If no hierarchy row is selected, the function opens at business scope.
5. Setup screens use a shared split or two-tab workspace: hierarchy selection
   first, function content second.
6. No setup function should require a popup just to pick scope.

## Plan Index

| Doc | Purpose |
|---|---|
| [01_feature_lens_audit.md](01_feature_lens_audit.md) | Deep-pass lens findings across product, IA, data, proxy, auth, lifecycle, UX, tests, performance, and evidence. |
| [02_product_ia_decisions.md](02_product_ia_decisions.md) | Product rules, target interaction model, surface copy rules, and decision blockers. |
| [03_code_gap_matrix.md](03_code_gap_matrix.md) | File-level gap matrix with required actions by admin surface and backend seam. |
| [04_execution_slices.md](04_execution_slices.md) | Sequenced implementation slices, branch/worktree ownership, tests, and merge rules. |
| [05_verification_and_evidence.md](05_verification_and_evidence.md) | Targeted tests, Browser Use pass, performance/UX framework runs, evidence artifacts, and final audit checklist. |

## Authority Read

- `PROJECT_TRACKER.md`
- `CLAUDE.md`
- `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`
- `docs/_execution/admin_hierarchy_settings_overhaul/README.md`
- `docs/_execution/admin_hierarchy_settings_overhaul/01_product_rule_and_ia.md`
- `docs/_execution/admin_hierarchy_settings_overhaul/02_plumbing_audit_matrix.md`
- `docs/_execution/admin_hierarchy_settings_overhaul/03_execution_slices.md`
- `docs/_execution/admin_hierarchy_settings_overhaul/04_verification_deploy_and_e2e.md`
- `docs/_execution/admin_hierarchy_settings_overhaul/05_new_codex_execution_prompt.md`

## Current Audit Summary

The current implementation has a good foundation: `AdminHierarchyScopeIntent`
exists, Business Accounts already keeps selected hierarchy state, route handoff
can carry hierarchy scope, and org-unit/location hierarchy data exists in the
schema. The remaining work is not a skin-deep cleanup. Several surfaces still
use a scope popup, many tables remain location-only, and some backend contracts
are intentionally incomplete.

The largest blockers are:

- Business setup tiles still call `showDialog(AdminHierarchyScopePrompt)` before
  routing.
- `support-operator-view` has a retained builder and route constant but no route
  table entry, so handoff can fall back to Business Accounts instead of opening
  a real hidden workspace.
- Data Accuracy and Polling still build scope choices from rows only, not from
  the full hierarchy tree.
- Data Accuracy and Polling writes are still per location in schema, gateways,
  and repositories.
- The HTTP roles/hierarchy gateway still throws 501 for org-unit move.
- Business Accounts hierarchy UI can create child org units but does not expose
  location move or org-unit move controls.
- Audit rows in Data Accuracy/Polling only have actor id/kind, not display name
  and role. The security audit projection has display fields, but some backend
  projections synthesize generic names rather than joining canonical identity.
- Connected Services shows a static "Documented" catalog instead of live
  category health.
- Several admin surfaces still expose code IDs, hashes, permission keys, or raw
  control names in primary UI.

## Implementation Rule

Use `.codex_worktrees` worktrees on `codex/` branches. Run Slice 0 first and
merge it before parallelizing, because it changes shared routing/scope seams.
After Slice 0, parallel worktrees are allowed only when write ownership is
disjoint. Commit each slice after targeted tests pass. Push and open PRs per
Forge & Flow workflow. Auto-merge only after checks pass or after the operator
explicitly accepts the remaining check risk.
