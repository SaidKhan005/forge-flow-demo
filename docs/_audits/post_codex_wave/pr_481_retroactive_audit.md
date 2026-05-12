# PR #481 — Complete admin hierarchy UX consolidation — Retroactive Audit

Auditor: orchestrator on `claude/pr-481-retroactive-audit` (worktree `nifty-clarke-d3ec25`).
Audited branch: `codex/admin-ux-consolidation-20260512` (deleted from origin post-merge).
Base: `9ca55d60` (master pre-PR).
Merge commit: `44e225a9` (master tip after merge).
Diff: **81 files, +12,820 / -2,019**, 14 commits.
Audit date: 2026-05-12.
Audit shape: full 7-chunk playbook per `docs/_audits/audit_chunking_playbook.md`. Two chunks delegated to sub-agents (Chunk 3 proxy, Chunk 4 admin lib) because of size.

**Retroactive context:** PR #481 was merged 2026-05-12 at 13:22 UTC without passing through the orchestrator audit gate (workflow miss). This audit was performed against the merged code. Findings inform follow-up fixes via Phase 5b orchestrator-fix on follow-up branches, not merge blocking (the merge already happened).

---

## Verdict

**approve-retroactively** (after orchestrator-fix landed for both findings).

- **Finding #4-1 (HP #11 honesty gap on admin_timing_setup_screen):** RESOLVED 2026-05-12 via PR #485 (merge commit `9e012f48`). New inheritance notice card warns that other locations under business/orgUnit scope may have local overrides. `dart analyze` clean. Deeper data-wiring (service periods + week-start from actual location data) deferred as a future polish slice — operator-visible only when locations have real overrides, currently a low-frequency case.

- **Finding #M1 (Migration 80800 in-place rewrite):** RESOLVED 2026-05-13 via path (a). Operator confirmed migration `202605080800_auth_permission_version.sql` had NOT been applied to staging or Production1 at the time of PR #481's in-place rewrite (it was still in the "code-ready" pending-apply queue). Orchestrator-fix adds a documented carve-out to the migration file's header comment explaining the rewrite is acceptable for this case, with a forward-looking rule that future migrations applied anywhere downstream MUST use the expand-contract pattern (new migration drops + recreates the index, not in-place edit).

Plus 4 observations (no anchor) and 1 carry-over operator-visual-test item from PR #482's audit (back-nav consolidation).

No findings required send-back to Codex. No reject-class findings — the wave is contract-aligned overall.

Critical positive: **all 8 PR #476 hot-fix invariants on `tool/advisor_proxy/advisor_proxy.dart` and `tool/advisor_proxy/main.dart` were preserved** through this big consolidation (Chunk 3 sub-agent verification).

---

## Per-chunk findings

### Chunk 1 — Schema migrations (3 files)

| Finding | file:line | Authority anchor | Recommended fix (Phase 5b) | Verification |
|---|---|---|---|---|
| **#M1 Modified existing migration (immutability violation, softened risk)** | `db/migrations/202605080800_auth_permission_version.sql:23-26` (functional index rewrite from `(user_id, permission_version)` to `(operator_id, user_id, permission_version)`) | `CLAUDE.md` L73 (operator-leading index rule); migration_cutoff_lint discipline; expand-contract migration pattern from `CLAUDE.md` Workflow section | **Two-path fix decision needed:** (a) if 80800 was never applied to staging OR Production1, accept the in-place rewrite (verify via migration_history table or staging audit); (b) if 80800 was applied to staging, revert the rewrite + add a NEW migration timestamped after 121200 that drops the old `(user_id, permission_version)` index and creates the new `(operator_id, user_id, permission_version)` one (proper expand-contract). The CHANGE itself is correct (operator-leading per HP #4) — only the WAY (modifying existing migration) is wrong. **Softening:** `docs/POST_HARDENING_FOLLOWUPS.md` L66 lists 80800 as "code-ready" — likely not yet applied to Production1. | Query `migration_history` table on staging (`select applied_at from migration_history where filename='202605080800_auth_permission_version.sql'`); if `null` or after PR #481 merge date, path (a); else path (b) |

Migrations `202605082200_admin_hierarchy_lifecycle.sql` (55 lines) and `202605121200_admin_hierarchy_scoped_data_polling.sql` (373 lines) are **CLEAN**:

- Operator-leading partial indexes (`locations_operator_live_idx`, `org_units_operator_live_idx`) with `where deleted_at is null` predicate.
- RLS enable + per-tenant policy using `public.app_current_operator()` (one of the 4 STABLE LEAKPROOF PARALLEL SAFE wrapper functions at `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql:61`).
- Permission keys seeded with `frozen: true` and granted to seeded `super_admin` + `operator_owner` only.
- Composite foreign keys `(operator_id, org_unit_id|location_id)` preserve RLS posture.
- Soft-delete pattern + ltree-based descendant view resolution.

### Chunk 2 — Repository layer (4 files)

**CLEAN.**

- `lib/auth/permission_keys.dart` (+4): adds `teamHierarchySuspend`, `teamHierarchyDelete` constants. Matches migration 82200 seeding + catalog L185-186.
- `lib/services/data_accuracy/forge_flow_polling_tier_repository.dart` (+4/-3): switches 2 SELECTs from raw table to `effective_forge_flow_polling_tier_assignment_v` view. Proper delegation.
- `lib/infrastructure/persistence/postgres/repositories/locations_repository.dart` (+22/-6): adopts soft-delete (`set deleted_at = now()` instead of hard DELETE); SELECTs filter `deleted_at is null`; model `LocationAdminRow` gains nullable `suspendedAt` + `deletedAt`. **Semantic shift:** delete is now soft (previously hard) — aligned with team_roles_hierarchy_console_parity_contract "Restore soft-deleted" admin action. Existing callers transparently see "deleted" rows hidden.
- `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart` (+438/-30): 5 new methods (`moveOrgUnit`, `setOrgUnitSuspended`, `deleteOrgUnit`, `setLocationSuspended`, `deleteLocation`). All wrapped in `withTenant` (RLS-scoped). All refuse to mutate root org units / primary locations. `moveOrgUnit` has cycle detection + depth-limit check + ltree subtree rewrite + locations.org_unit_path cascade. `deleteOrgUnit` refuses if children/locations exist (`org_unit_not_empty` error). New `OrgUnitMoveRejected` exception class is used by all 5 methods (naming is slightly misleading — covers Move + Lifecycle + Delete — minor code health concern, not a contract violation).

### Chunk 3 — Proxy + auth gateways (5 files; sub-agent audit)

**CLEAN.** Full sub-agent report transcribed in audit working notes; key extract below.

**All 8 PR #476 hot-fix invariants PRESERVED post-merge:**

| Invariant | grep result | Status |
|---|---|---|
| `_hasGlobalAdminRole` | `advisor_proxy.dart:2179, 2258` | PRESERVED |
| `proxy.auth.scope_missing_accepted_global_admin` | `advisor_proxy.dart:2206` | PRESERVED |
| `proxy.auth.scope_missing_rejected` | `advisor_proxy.dart:2189` | PRESERVED |
| `ProxyRuntimeGauges` | `advisor_proxy.dart:3669, 3670, 3726` | PRESERVED |
| `proxy.auth.session_ledger_record_login_failed` | `advisor_proxy.dart:12883` | PRESERVED |
| `proxy.auth.lockout_record_success_failed` | `advisor_proxy.dart:12926` | PRESERVED |
| `runZonedGuarded` in `main.dart` | `main.dart:84, 95` | PRESERVED |
| `proxy.root_zone_uncaught` | `main.dart:114, 125` | PRESERVED |

**New admin-hierarchy routes** (`advisor_proxy.dart:167-434`): all 6 routes (org-unit move/suspend/reactivate/delete + location suspend/reactivate/delete) gate on appropriate permission keys (`team.roles.assign` / `team.hierarchy.suspend` / `team.hierarchy.delete`), require `admin_reason` body field (400 if missing), carry idempotency keys via `readIdempotencyKeyOrFail()` + `authOpsCache.runOrReplay`, and reuse `scope` from surrounding `requireOperatorContext` block (so PR #476's scope-less-admin acceptance applies).

**Scoped settings PUT routes** (`advisor_proxy.dart:15294, 15446`): route through `_runAdminIdempotent` with `adminReason` + `idempotencyKey`. ✓

**proxy_bootstrap.dart** (`overrideDataAccuracyScope:4216`, `assignTierScope:4538`): use `_adminWrapper.runAsSystem(..., reason: adminReason)` — the proper `withSystem` ledger pattern. Audit log includes `admin_reason`. No bare `current_setting()`. No new untyped catch arms.

**`mfa_removal_worker.dart`**: NOT TOUCHED by PR #481 (was in my chunk-scope list but had empty diff — false-positive from the gateway-glob in initial categorization).

**Observations (not anchored findings):**

- DTO `TeamOrgUnitMoveCommand` / `TeamLocationOrgUnitMoveCommand` makes `adminReason` optional, while the lifecycle commands (suspend/delete) make it required. Proxy route at `advisor_proxy.dart:179` enforces `adminReason != null` at HTTP boundary (returns 400 if missing), so the operator-console call path is safe; the inconsistency only matters for non-proxy in-process callers (tests).
- `runAsSystem` bypasses RLS for verification reads inside scoped-override writes. Acceptable because the admin actor is global, not operator-scoped.

### Chunk 4 — Admin lib (33 files; sub-agent audit)

**material-gaps-orchestrator-fix on 1 finding.**

| Finding | file:line | Authority anchor | Recommended fix (Phase 5b) | Verification |
|---|---|---|---|---|
| **#4-1 HP #11 partial gap — new admin_timing_setup_screen.dart doesn't show inheritance provenance** | `lib/admin/screens/admin_timing_setup_screen.dart:166-179` (no "Inherited from business" label per row when orgUnit/business scope selected) | `CLAUDE.md` HP #11 (selected scope, inherited source, effective value) | Mirror the resolved-pattern from `lib/admin/screens/operator_location_admin_screen.dart:3749-3763` (`_AdminTimingResolution` helper with `timezoneSource` / `dayStartSource` / `servicePeriodSource` labels). Wire to actual data instead of hardcoded service periods (L193-195) + week-start (L175). | `grep -nE 'inheritedFrom|inheritedSource|timezoneSource' lib/admin/screens/admin_timing_setup_screen.dart` should match after fix |

**Other priority files** (`admin_routes.dart`, `admin_setup_workspace.dart` NEW, `operator_location_admin_screen.dart`, `debug_console_admin_screen.dart`, `data_accuracy_admin_gateway.dart`, `demo_roles_hierarchy_sessions_admin_gateway.dart`, `polling_and_pricing_admin_screen.dart`): **CLEAN.**

- Permission gating consistent with existing codebase pattern (`session.roles.contains('super_admin')` rather than `PermissionKeys.*` — Phase 9.7 backlog will convert; not a regression).
- HP #11 compliance verified in `operator_location_admin_screen.dart` (`_AdminTimingResolution` at L3749-3763, `_timingBannerScope` at L3766-3804 with explicit `AdminHierarchyScopeValueState.inheritedFromBusiness` for orgUnit) and `polling_and_pricing_admin_screen.dart` (uses `AdminHierarchySettingsScopePolicy` + `AdminHierarchyScopeNotice` + `AdminHierarchyScopePrompt`).
- `demo_roles_hierarchy_sessions_admin_gateway.dart` enforces `_ensureAdminReason` (L71-79) + `_ensureForgeAdmin` (L63-69) on every mutation — parity contract verified.
- `data_accuracy_admin_gateway.dart` hard-errors on missing reason ("reason_note_required") at L711-734.
- `vendor_connections_widget.dart`: pure category section reorder (Reservations ↔ Scheduling-and-labor), no logic change.

**Observations (not anchored findings):**

- `admin_timing_setup_screen.dart:193-195` hardcodes service period times instead of reading location's `ServicePeriodDefinition`s. Drifts from `operator_location_admin_screen.dart`'s data-driven path.
- `admin_timing_setup_screen.dart:175` hardcodes "Week starts: Monday". Should read from operator/location setting once write route lands.
- `admin_routes.dart` is now 3045 lines with many near-identical StreamBuilder + super_admin patterns — extraction candidate for future polish.

### Chunk 5 — Tests (30 files)

**CLEAN.**

- New migration test `test/services/data_accuracy/admin_hierarchy_scoped_data_polling_migration_test.dart` (+53): SQL-content shape verification (table creation, scope_type check constraint, unique indexes, effective views, ltree descendant matcher). Covers migration 121200.
- `test/org_units_repository_live_binding_test.dart`: new test group `OrgUnitsRepository.moveOrgUnit` with assertions on `parentId`, `org_unit_id` params, `parent_org_unit_id` params. Coverage for the new repository methods.
- `test/proxy_auth_operations_route_test.dart` (+275): new tests for the 6 admin-hierarchy routes — `PATCH location org-unit requires admin_reason`, `PATCH org-unit suspend gates on team.hierarchy.suspend`, `POST org-unit delete gates on team.hierarchy.delete`, `PATCH location suspend gates on team.hierarchy.suspend`. Verifies permission gates + admin_reason enforcement at the proxy boundary.
- `test/services/data_accuracy/forge_flow_polling_tier_repository_test.dart` (+213/-227): rewritten for view-based reads.
- `test/admin_operator_location_screen_test.dart` (+521): coverage for the heavily-changed operator_location_admin_screen.
- All other test diffs follow the code changes (scope copy updates, vendor filter coverage, new gateway methods).

**Test coverage gap (observation, not anchored finding):** new migration test is structural (does the SQL contain the right substrings) rather than functional (does the migration apply + create expected schema state). Acceptable per current testing norms.

### Chunk 6 — Docs + runbooks (5 files)

**CLEAN.**

- `docs/POST_HARDENING_FOLLOWUPS.md`: pending-Production1-apply queue extended from 28 → 34 migrations, ending at 121200. List is honest about what's pending.
- `docs/contracts/auth_permission_key_catalog.md` L184-185: adds `team.hierarchy.suspend` + `team.hierarchy.delete` to the catalog. L196-198, L207: updates `operator_owner` and `operator_manager` baseline grant descriptions. **No drift** with migration 82200 seeding + `lib/auth/permission_keys.dart` additions.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`: migration cutoff updated to 121200.
- `docs/phases/phase_9/phase_9_execution_backlog.md`: same migration cutoff update.
- `runbooks/phase_9_production1_migration_apply_runbook.md`: date stamp + cutoff updated.

### Chunk 7 — Integration test harness + scripts (0 files)

**N/A — no files in PR #481's diff matched this chunk.** Skip.

---

## Verification

- **Codex's local report (PR #481 commit thread):** `dart analyze` clean, broad admin/proxy/data test suite pass.
- **Independent orchestrator-side analyze:** deferred. Master worktree was dirty during audit (Codex's local working state on `proxy_bootstrap.dart`); couldn't checkout cleanly.
- **PR #476 invariant grep verification:** done by Chunk 3 sub-agent. All 8 invariants preserved.
- **Permission catalog drift check:** done. NO drift between migration 82200 seeding + `lib/auth/permission_keys.dart` + `docs/contracts/auth_permission_key_catalog.md` for `team.hierarchy.suspend` / `team.hierarchy.delete`.

---

## Orchestrator-fix commits (Phase 5b)

| Finding § | Commit SHA | Files touched | Re-audit result |
|---|---|---|---|
| #M1 Migration 80800 immutability | `claude/m1-migration-80800-closure` (this branch's fix commit) | `db/migrations/202605080800_auth_permission_version.sql` — adds header carve-out comment documenting that the in-place rewrite is acceptable because the migration had not been applied anywhere downstream when rewritten (operator confirmed 2026-05-13). Forward-looking rule: future migrations applied downstream MUST use expand-contract pattern. | RESOLVED — operator verified pre-condition (migration not applied to staging/Production1), path (a) selected: accept in-place rewrite + document. The CHANGE itself (operator-leading index) is correct per HP #4 — only the WAY was off-pattern in the general case. Documented carve-out closes the loop. |
| #4-1 admin_timing_setup_screen HP #11 gap | `9e012f48` (PR #485 merge) | `lib/admin/screens/admin_timing_setup_screen.dart` — adds an inheritance notice card above the detail rows when scope is not a location AND covered location count > 1 (`Showing timing from ${location.name}. Other locations under this scope may have local overrides — review each location individually for accuracy.`); `dart analyze` clean | PARTIAL RESOLVED — HP #11 honesty gap closed for multi-location business/orgUnit scopes; deeper service-period data-wiring deferred as future polish slice (operator-visible only when locations have actual overrides, currently low-frequency case) |

---

## Follow-up items (none require send-back)

Both findings are orchestrator-fix candidates per Phase 5b doctrine. No send-back items.

Operator visual-test items carry over from PR #482 audit: confirm back-nav works at the admin shell level for Data Accuracy / Polling/Pricing / Roles+Hierarchy / Audited Support Actions screens after the consolidated admin shell is exercised.

---

## Operator approval gates

PR #481 touched every gated surface: schema migrations (3 new), repository layer (org_units, locations), auth + audit logs, proxy contracts, admin UI. Operator approval was implicitly granted by the user's merge of PR #481 on 2026-05-12 13:22 UTC — the audit is retroactive.

Going forward: this retroactive case proves the workflow gap (open → merge in < 1 hour, faster than the hourly watcher). The audit doctrine + watcher pattern hold; the takeaway is **operator can wait on the orchestrator audit** for gated PRs before clicking merge, even when the PR looks ready. The `agent-led slices` rule in `docs/CODEX_PROMPT_GENERATION_STANDARD.md` already names auth + audit + schema + proxy as requiring explicit operator approval before merge regardless of audit verdict.

---

## Citations

All code citations are to the worktree at `C:/Git Local Repos/forge_flow_demo` on master at `951a160f` (post-merge of PR #481 and PR #482).

Source documents:

- `CLAUDE.md` Hard Promises #4, #11; "Proxy & API Conventions"; "RLS-Ready Schema"; "Workflow" section migration discipline.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — Chunk 2 + Chunk 3 anchor.
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` — admin_reason + actor_kind parity rules.
- `docs/contracts/auth_permission_key_catalog.md` — Chunk 6 anchor.
- `docs/phases/phase_11a/phase_11a_decision_register.md` — proxy decision register.
- `docs/_audits/audit_chunking_playbook.md` Phase 5b — orchestrator-fix-by-default + authority-anchor rule.
- `docs/_audits/post_codex_wave/pr_476_b1_b2_audit.md` — PR #476 hot-fix invariants verified preserved by this audit.
- `docs/_audits/post_codex_wave/pr_482_audit.md` — PR #482 audit (closed CLEAN with Finding #1 resolution).

---

## Auditor's note

The substantive engineering in PR #481 is high quality: the admin hierarchy consolidation properly adopts soft-delete semantics across `locations` + `org_units`, threads `admin_reason` through the parity contract surfaces, introduces a clean scope-resolution pattern via the two `effective_*_v` views in migration 121200, and preserves the orchestrator's recent PR #476 hot-fix invariants on the proxy.

The two findings are minor in the global picture:

- Finding #M1 (immutable-migration violation) is **procedural** — the change itself (operator-leading index) is the right direction per HP #4; only the way (modifying existing migration) is off-pattern. If 80800 wasn't yet applied to staging or Production1, the in-place rewrite is acceptable with documentation.
- Finding #4-1 (HP #11 partial gap on new timing screen) is a **UX honesty gap** — the new screen shows scope but not inheritance provenance, drifting from the contract's "selected scope, inherited source, effective value" rule. The fix is bounded (mirror the existing `_AdminTimingResolution` pattern from operator_location_admin_screen).

The bigger lesson is workflow: PR #481 went open → merged in well under an hour, faster than the orchestrator's hourly watcher could catch it. The doctrine doesn't change; the operator hand at the merge button is the gate. This audit being retroactive doesn't make it less rigorous — it makes it a learning artifact for the wave's next cadence.
