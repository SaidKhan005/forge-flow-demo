# 05 - New Codex Execution Prompt

Paste the prompt below into a fresh Codex session to implement the overhaul.

```text
Use the Forge & Flow repo workflow and Browser Use.

Objective:
Implement the Admin Hierarchy Settings Overhaul end to end. Use these docs as
the source of truth:
- docs/_execution/admin_hierarchy_settings_overhaul/README.md
- docs/_execution/admin_hierarchy_settings_overhaul/01_product_rule_and_ia.md
- docs/_execution/admin_hierarchy_settings_overhaul/02_plumbing_audit_matrix.md
- docs/_execution/admin_hierarchy_settings_overhaul/03_execution_slices.md
- docs/_execution/admin_hierarchy_settings_overhaul/04_verification_deploy_and_e2e.md
- docs/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md
- docs/_execution/admin_hierarchy_settings_deep_plumbing_audit_2026-05-08.md

Hard product rule:
Every setting resolves through the hierarchy:
business/operator default -> org-unit ancestors from root to leaf -> location.
The lowest configured scope wins. Missing lower scopes inherit from the nearest
ancestor. Every settings UI must show selected scope, inherited source,
effective value, allowed actions, disabled/gated states, and mutation
requirements before writes. Integrations are the known exception: hierarchy
prompt is used for context, but edits require location scope.

Worktree and branch rules:
1. Do not mutate the main working tree.
2. Fetch latest origin/master before starting.
3. Create separate worktrees under .codex_worktrees.
4. Use codex/ branch names.
5. Use multiple agents/worktrees in parallel only when write ownership is
   disjoint.
6. Commit each completed slice intentionally after targeted tests pass.
7. Push each slice branch, open a PR, and auto-merge only after CI/checks pass,
   review is clean, no blocked product decision remains, and branch protection
   permits the merge.
8. If auto-merge is blocked, leave the PR open with the exact blocker and keep
   moving on independent slices.

Required reading before coding:
- PROJECT_TRACKER.md
- CLAUDE.md
- docs/CODEX_PROMPT_GENERATION_STANDARD.md
- docs/contracts/core_app_architecture.md
- docs/contracts/slice_runtime_acceptance_contract.md
- docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md
- docs/frameworks/PERFORMANCE_FRAMEWORK.md
- docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md
- runbooks/preview_environment_runbook.md

Execution plan:
Start with Slice 0 shared scope seam. Then parallelize only after shared seams
are merged:
- Slice 0: AdminHierarchyScopeIntent, shared scope prompt, route handoff.
- Slice 1: Business Accounts IA, remove Click to manage, hierarchy-first detail,
  eight setup tiles, hide Support Workspace.
- Slice 2: Reconcile admin hierarchy route contracts and tests.
- Slice 3: Make location create hierarchy-aware with parent_org_unit_id.
- Slice 4: People/access/roles consolidation, invites, role grants, conflict
  details, permission explainer.
- Slice 5: Security/audit/sessions consolidation and audited support actions.
- Slice 6: Account profile and Contact email copy while preserving owner_email
  wire compatibility.
- Slice 7: Timing scoped admin surface using the existing hierarchy resolver.
- Slice 8: Data accuracy and Polling/pricing. Do not enable business/org-unit
  edits until scoped schema/resolvers/routes/tests exist.
- Slice 9: Integrations through hierarchy prompt, edit only at location scope.
- Slice 10: Support logs scoped to business/org-unit/location.
- Slice 11: Final cleanup, preview deployment, full E2E, performance, and audit.

Implementation constraints:
- Do not fake UI for backend functionality that is not routed or wired.
- Do not expose org-unit delete/suspend/archive until lifecycle schema/routes
  and audit behavior exist.
- Preserve F&F staff multi-business support; do not apply a blanket one-email
  rule to support staff.
- Separate Business Contact email metadata from authenticated team/support
  login identities.
- Keep location_manager and other read-only roles read-only.
- Mutations must include role checks, disabled states, confirmation copy,
  idempotency keys, audit reason where required, and refresh persistence.
- Keep demo/share-preview gateways from being used as live preview proof.

Testing:
- Run targeted tests per slice before commit.
- Run flutter analyze before major PRs and final merge.
- Run proxy tests for auth, hierarchy, members, roles, sessions, audit, timing,
  data accuracy, polling/pricing, integrations, health, and startup when touched.
- Run repository/migration tests for every schema change.
- Run admin/operator web widget tests for changed screens.
- Build affected web consoles in release mode against the preview proxy.
- Run the Performance Framework and write JSON evidence.

Preview and Browser Use:
- Deploy preview end to end after merged slices.
- Use data-isolated preview for the full mutation sweep when possible.
- If preview shares staging secrets, stop for exact action-time approval before
  mutating shared staging data.
- Open fresh cache-bust URLs with Browser Use.
- Test every reachable admin console surface and all supported mutating
  functionality.
- Capture visible evidence, console logs, route results, disabled/gated states,
  and performance JSON.

Final audit:
After all PRs merge and preview is deployed, audit code against every doc in
docs/_execution/admin_hierarchy_settings_overhaul/. Confirm every product rule,
slice, route, permission gate, mutation, disabled state, test, and Browser Use
item is either implemented, explicitly gated, or documented as intentionally
unsurfaced. Fix gaps before final closeout.

Final deliverables:
- Merged PRs per slice.
- Final execution note under docs/_execution with commits, PRs, preview URLs,
  database mode, test/build/perf results, Browser Use evidence, mutation
  evidence, bugs fixed, intentionally gated items, and residual risks.
- PR comments listing exact tests, preview evidence, Browser Use evidence, and
  performance JSON path.
```
