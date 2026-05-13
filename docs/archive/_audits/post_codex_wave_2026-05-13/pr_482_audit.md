# PR #482 — Close admin hierarchy audit gaps — Audit

Auditor: orchestrator on `claude/pr-482-audit-doc` (worktree `nifty-clarke-d3ec25`).
Audited branch: `codex/admin-ux-audit-final-fixes-20260512` at tip `02bb4076`.
Base (PR merge target): `master` at `44e225a9` (PR #481's merge).
Diff vs base: 18 files, +534 / -222.
Audit date: 2026-05-12.
Audit shape: per `docs/_audits/audit_chunking_playbook.md` light playbook (3 active chunks: proxy, admin lib, tests; no migrations, no repository layer, no docs, no integration harness in scope).

---

## Verdict

**approve-for-merge** (after operator decision on Finding #1 on 2026-05-12 + orchestrator-fix landed on this branch).

Original verdict was `material-gaps-orchestrator-fix`. Operator chose option (a): keep the Standard→Regular rename and update the contract doc inline. Orchestrator-fix applied at the commit appended to this audit branch — `docs/contracts/data_accuracy_settings_contract.md` L55 + L106 + L195 updated to use "Regular" as the operator-facing label, with a clarifying paragraph noting the `tier_key` enum value remains `standard` (persistence/contract semantics unchanged). Finding #1 closed.

Finding #3 (back-button removal observation) is not orchestrator-fixable — pending operator visual sign-off when the merged admin surfaces are exercised.

Chunk-level summary:

- **Chunk 3 (Proxy + auth gateways)** — 1 finding (contract drift on tier label rename, escalation required).
- **Chunk 4 (Admin lib)** — clean except for the same rename pattern + 1 behavioral question (back-button removal — verify in visual test, not blocking).
- **Chunk 5 (Tests)** — clean. Tests follow the code changes correctly.

Once Finding #1 is resolved by operator decision and the rename is reconciled with `docs/contracts/data_accuracy_settings_contract.md`, this PR is `approve-for-merge` subject to operator approval gates (touches proxy + admin surfaces).

---

## Per-chunk findings

### Chunk 3 — Proxy + auth gateways

Files: `tool/advisor_proxy/proxy_bootstrap.dart` (-1/+1).

| Finding | file:line | Authority anchor | Fix (or send-back rationale) | Verification |
|---|---|---|---|---|
| **#1 Contract drift — tier label rename Standard→Regular** without contract update. Codex renamed the operator-facing label for `PollingTierKey.standard` from "Standard" to "Regular" across 7 sites (1 in proxy_bootstrap, 1 in data_accuracy_admin_gateway, 4 in lib/admin widgets/screens, plus 2 tests). The `tier_key` enum value stays `standard`. The contract authority `docs/contracts/data_accuracy_settings_contract.md` L106, L195 still uses "Standard" as the operator-visible label example. The rename has no contract anchor — the contract example becomes stale. | `tool/advisor_proxy/proxy_bootstrap.dart:5100` (description string); also `lib/admin/services/data_accuracy_admin_gateway.dart:2196`, `lib/admin/screens/polling_and_pricing_admin_screen.dart:1175`, `lib/admin/widgets/per_location_tier_assignment_table.dart:331`, `lib/admin/widgets/tier_definition_edit_dialog.dart:329`, `lib/admin/widgets/tier_definitions_card.dart:184`, plus 2 test files | `data_accuracy_settings_contract.md` L106 + L195 use "Standard"; `memory/project_ux_writing_standard.md` favors plain English ("Regular" is plainer) — but the UX-writing memory is not strictly a contract | **PENDING OPERATOR DECISION** (Phase 5b "No fix without an anchor" escalation). Two options: (a) accept rename + update contract example doc to match (orchestrator-fix on the contract doc); (b) revert all 7 sites + 2 tests to "Standard" (orchestrator-fix on the PR branch). | Run `dart analyze` + relevant tests after whichever fix is chosen |

### Chunk 4 — Admin lib

Files: 11 (`admin_routes.dart`, `admin_hierarchy_settings_scope_policy.dart`, 6 screens, 1 service, 2 widgets).

| Finding | file:line | Authority anchor | Fix (or send-back rationale) | Verification |
|---|---|---|---|---|
| **#2 Standard→Regular rename in admin gateway** — same as Finding #1 covering `kDemoStandardTierDefinition` description. | `lib/admin/services/data_accuracy_admin_gateway.dart:2196` | Same as Finding #1 | Resolved with Finding #1 | — |
| **#3 (Observation, not blocking) — `onBackToBusinessAccounts` removed from 5 admin-routes callsites.** Receiver widgets (`PerLocationDataAccuracyScreen`, `PollingAndPricingAdminScreen`, etc.) still declare and use the param. Param is nullable; not passing it makes the leading back button hide. Likely intentional consolidation (PR #481 included `admin-setup-back-buttons` work — centralized shell back button). | `lib/admin/admin_routes.dart:1143, 1162, 1214, 1233, 1696, 2002` | No contract pins per-screen back button; admin shell navigation pattern is a UX judgment call | NO ORCHESTRATOR FIX — flag for visual sign-off only. If operator visual test confirms no missing back-nav, dismiss. | Operator visual test: navigate to Data Accuracy, Polling/Pricing, Roles/Hierarchy/Sessions, Audited Support Actions screens; verify back-to-business-accounts navigation still works (via shell, not per-screen) |

The remaining changes in Chunk 4 are CLEAN:

- `admin_hierarchy_settings_scope_policy.dart` (+4/-4): restriction copy updated from "edits apply to every visible location" to "create one override that covered locations inherit until a lower scope overrides it". **Authority anchor:** CLAUDE.md HP #11 (hierarchy-scoped settings: "selected scope, inherited source, effective value"). The new copy aligns with the contract. Good change.
- `admin_timing_setup_screen.dart` (+7/-9): removes disabled "Save timing" button, replaces with contextual review-only text. The admin timing screen is read-only-by-design (admin reviews timing, doesn't write). Aligned with `team_roles_hierarchy_console_parity_contract.md` which has admin paths as reviewers + audit-trail writers, not direct timing editors at this surface.
- `health_admin_screen.dart` (+42/-37), `observability_admin_screen.dart` (+42/-33): wrap the manual-prompt branch in `SingleChildScrollView` to prevent overflow on small viewports. UX polish, no behavior change.
- `operator_location_admin_screen.dart` (+52/-32): `_HierarchyScopeRow` adds `LayoutBuilder` for responsive compact actions when width < 320px. UX polish.
- `per_location_data_accuracy_screen.dart` (+1/-1): same HP #11 override-copy update.
- `polling_and_pricing_admin_screen.dart` (+19/-1): new `_vendorFilter` field + UI wiring for vendor filtering, plus HP #11 copy update. New feature with test coverage.
- `per_location_data_accuracy_table.dart` (+88/-1): new `vendorSourceFilter` parameter + filter dropdown with 4 values (`vendor_any`, `covers_vendor`, `wage_vendor`, `manual_or_forecast`). New feature with test coverage. **Authority anchor:** `team_roles_hierarchy_console_parity_contract.md` admin views the operator data → filters are within scope.
- `per_location_tier_assignment_table.dart` (+39/-0): mirror vendor-filter wiring. New feature with test coverage.

### Chunk 5 — Tests

Files: 6 test files (+238 / -96).

**CLEAN.**

All test changes are consistent with the code changes:

- `admin_hierarchy_settings_scope_policy_test.dart`: text matcher updated to match new restriction copy.
- `data_accuracy_polling_hierarchy_scope_screen_test.dart`: text matchers updated to match new scope-override copy; test name rewritten from "writes every visible location" to "writes selected hierarchy scope" (better naming).
- `data_accuracy_ux_framework_polish_test.dart`: +149/-13 — two new test cases for vendor-source filter (data accuracy table) + vendor filter (polling tier assignment). Properly covers the new filter UIs.
- `tier_definition_dialog_validation_test.dart`, `tier_definition_edit_audit_test.dart`: text matchers updated from "Standard" → "Regular" to match Finding #1's rename. These will need to flip back if Finding #1 resolves to (b) revert.
- `admin_shell_widget_test.dart`: switches from text-match `find.text('Operator: <uuid>')` to key-match `find.byKey('admin_debug_console_scope_label')` + `find.textContaining('Business:')`. Test follows a label change that landed in PR #481 (debug-console scope label format), not a #482-introduced change.

Test coverage is appropriate for the new features (vendor filters). No gap.

---

## Verification

- **`dart analyze` on Codex's branch:** Codex's report says "scoped flutter analyze: pass" and "broad admin/proxy/data suite: pass". Independent orchestrator-side verification deferred (master worktree was dirty during audit; couldn't checkout PR branch cleanly without disturbing Codex's local state). Local-side verification accepted per Phase 5b's verification rule with a follow-up: the orchestrator re-runs `dart analyze` + relevant test suites BEFORE merge.
- **Browser Use / Playwright fallback:** Codex confirmed Browser Use backend issue. Playwright fallback evidence at `build/reports/` accepted for #482 per operator's prior approval.
- **No new migrations in scope** — Chunk 1 skipped. Migration cutoff lint not relevant.
- **No repository layer changes in scope** — Chunk 2 skipped.

---

## Orchestrator-fix commits (Phase 5b)

| Finding § | Commit SHA | Files touched | Re-audit result |
|---|---|---|---|
| #1 Standard→Regular drift | (this PR — next commit on this branch) | `docs/contracts/data_accuracy_settings_contract.md` L55 + L106-114 + L195-196 (3 operator-facing label sites updated to "Regular" + clarifying paragraph that `tier_key` enum value stays `standard`) | RESOLVED — contract now matches the rename Codex shipped in PR #482's branch; `tier_key` enum value preserved so persistence + contract semantics unchanged |
| #3 Back-button observation | NO FIX — operator visual sign-off only | — | pending (visual test) |

---

## Follow-up items (none required for send-back)

This PR has no send-back items. All findings are either orchestrator-fixable (after operator decision on Finding #1) or visual-test-only (Finding #3).

---

## Operator approval gates

PR #482 touches:

- Proxy (1 line in `proxy_bootstrap.dart`)
- Admin lib (11 files)
- Tests

Per `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Agent-Led Slices" operator-approval gates, proxy touches require explicit operator approval. The proxy change here is a description string update (not contract/route behavior), so the approval cost is low. Operator gate to clear before merge: confirm Finding #1 resolution + acknowledge Finding #3 visual-test result.

---

## Citations

All code citations are to the worktree at `C:/Git Local Repos/forge_flow_demo/.codex_worktrees/admin-ux-audit-final-fixes-20260512` as of tip `02bb4076` (PR #482).

Source documents:

- `docs/contracts/data_accuracy_settings_contract.md` — Finding #1 contract anchor.
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` — Chunk 4 anchor for admin timing screen review-only intent + per-screen admin paths.
- `CLAUDE.md` HP #11 (hierarchy-scoped settings) — Chunk 4 anchor for scope-override copy updates.
- `memory/project_ux_writing_standard.md` — Plain-English UX writing standard (potential anchor for the Standard→Regular rename, but not strict contract).
- `docs/_audits/audit_chunking_playbook.md` Phase 5b — orchestrator-fix-by-default + No-fix-without-anchor rules; basis for the Finding #1 escalation.
- Codex's verification report (this conversation, 2026-05-12) — local analyze + test pass; Browser Use Playwright fallback evidence.

---

## Auditor's note

PR #482 is a small, well-targeted audit-closure PR. The substantive new code (vendor filters in two widgets + responsive layout polish in three admin screens + scope-override copy refresh aligned with HP #11) is clean and properly tested.

The single material finding (Standard→Regular rename) is borderline — the rename arguably IMPROVES operator-facing copy per `memory/project_ux_writing_standard.md`'s plain-English rule, and the `tier_key` enum value is unchanged so persistence/contract semantics are preserved. But the rename has no explicit operator decision behind it AND the contract doc's operator-visible example still says "Standard." Per Phase 5b "No fix without an anchor," I'm escalating rather than choosing a side.

Recommended path: operator picks (a) keep the rename + I update the contract doc inline (Phase 5b orchestrator-fix on the contract). Faster than (b) revert and likely the right direction given the UX-writing standard. Either way, the audit doc records the decision for traceability.
